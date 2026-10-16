#+build linux, darwin
package survey

import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:testing"

import "../changes"
import "../scan"

/*
A baseline kept from a scan that could not open a directory does not pass that
directory off as empty: the next fill, updating from it, reads the directory again
and finds what it holds once it can be opened.

	<root>/a.txt               100 bytes
	<root>/locked/big.bin      1 MiB, behind a mode 000 directory

Root opens anything, so the test skips there. On macOS the chmod itself is named by
FSEvents and relists the directory, which reaches the same answer by another road
(2026-10-16: this test passed with walk.job_of's Unread check removed, while
walk/unix_test.odin's update test failed), so that test is the one that pins the
update with no change named at all.
*/
@(test)
test_a_baseline_does_not_keep_an_unread_directory_as_empty :: proc(t: ^testing.T) {
	if posix.geteuid() == 0 {
		log.info("skipped: root can open any directory")
		return
	}
	dir, dir_err := os.temp_directory(context.temp_allocator)
	testing.expect(t, dir_err == nil, "no temp directory")
	root := fmt.tprintf("%s/leita_survey_unread", strings.trim_right(dir, "/"))
	locked := fmt.tprintf("%s/locked", root)
	os.chmod(locked, {.Read_User, .Write_User, .Execute_User})
	os.remove_all(root)
	defer os.remove_all(root)
	testing.expect(t, os.make_directory(root) == nil, "could not make the root")
	testing.expect(t, os.make_directory(locked) == nil, "could not make locked")
	put(t, fmt.tprintf("%s/a.txt", root), 100)
	put(t, fmt.tprintf("%s/big.bin", locked), 1 << 20)
	testing.expect(t, os.chmod(locked, {}) == nil, "could not lock the directory")
	defer os.chmod(locked, {.Read_User, .Write_User, .Execute_User})

	file := fmt.tprintf("%s/../leita_survey_unread.tree", root)
	defer os.remove(file)
	target, choice, err := scan.resolve(root)
	testing.expect_value(t, err, scan.Error.None)
	defer scan.target_destroy(&target)
	if _, has_events := changes.now(root); !has_events {
		log.info("skipped: the volume keeps no change history, so no baseline is kept")
		return
	}

	run  :: proc(t: ^testing.T, target: scan.Target, engine: scan.Engine, file: string) -> Fill {
		tree := new(scan.Tree)
		testing.expect_value(t, scan.tree_init(tree, 2), scan.Error.None)
		f := Fill {
			target = target,
			engine = engine,
			wcfg = {workers = 2},
			tree = tree,
			baseline = file,
		}
		fill_run(&f)
		testing.expectf(t, problem(&f) == "", "the fill failed: %s", problem(&f))
		testing.expect(t, f.saved, "the result was not kept")
		return f
	}
	done :: proc(f: ^Fill) {
		fill_destroy(f)
		scan.tree_destroy(f.tree)
		free(f.tree)
	}

	first := run(t, target, choice.engine, file)
	defer done(&first)
	count, denied := scan.unread(first.tree)
	testing.expect_value(t, count, 1)
	testing.expect(t, denied, "a mode 000 directory was not refused for permission")
	// Spelt as the tree spells it: the temp directory may be reached through a link.
	big := fmt.tprintf("%s/locked/big.bin", scan.location(target, context.temp_allocator))
	testing.expect(t, big not_in seen(first.tree), "a locked directory's file was read")

	testing.expect(
		t,
		os.chmod(locked, {.Read_User, .Write_User, .Execute_User}) == nil,
		"no unlock",
	)
	second := run(t, target, choice.engine, file)
	defer done(&second)
	testing.expectf(t, second.how == .Updated, "read whole again: %s", second.why)
	again, _ := scan.unread(second.tree)
	testing.expect_value(t, again, 0)
	got, found := seen(second.tree)[big]
	testing.expect(t, found, "the update kept the directory empty")
	testing.expectf(t, got.disk >= 1 << 20, "big.bin charged %d", got.disk)
}
