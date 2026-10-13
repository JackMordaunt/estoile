#+build linux
package survey

import "core:fmt"
import "core:log"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:sys/linux"
import "core:testing"
import "core:thread"
import "core:time"

import "../changes"
import "../journal"
import "../scan"

/*
The recorder end to end, as root: it records a filesystem while a place on it is
read whole, changed, and updated, and the update reads again exactly the directories
changed and comes to the tree a whole read does. Opt-in, since it needs root and a
filesystem fanotify can mark (not a btrfs subvolume): LEITA_JOURNAL_ROOT=1, and
LEITA_JOURNAL_MOUNT the mount point to record, /mnt/e unless set.
*/
@(test)
test_the_recorder_names_exactly_what_changed :: proc(t: ^testing.T) {
	if os.get_env("LEITA_JOURNAL_ROOT", context.temp_allocator) != "1" || linux.geteuid() != 0 {
		log.info("skipped: set LEITA_JOURNAL_ROOT=1 and run as root")
		return
	}
	mount := os.get_env("LEITA_JOURNAL_MOUNT", context.temp_allocator)
	if mount == "" {
		mount = "/mnt/e"
	}
	root := recorded_fixture(t, mount)
	defer os.remove_all(root)
	logs, _ := filepath.join(
		{os.temp_directory(context.temp_allocator) or_else "/tmp", "leita_journal_logs"},
		context.temp_allocator,
	)
	os.remove_all(logs)
	defer os.remove_all(logs)
	journal.logs_here = logs
	defer journal.logs_here = ""

	Recording :: struct {
		cfg:     journal.Config,
		problem: string,
	}
	stop: bool
	rec := Recording {
		cfg = {logs = logs, only = {mount}, stop = &stop},
	}
	recorder := thread.create_and_start_with_poly_data(&rec, proc(r: ^Recording) {
			r.problem = journal.run(r.cfg)
		}, init_context = context)
	testing.expect(t, recorder != nil, "the recorder did not start")
	defer thread.destroy(recorder)
	stopped := false
	defer if !stopped {
		sync.atomic_store(&stop, true)
		thread.join(recorder)
	}
	// What made the fixture lands before the first read's window.
	time.sleep(2500 * time.Millisecond)
	fsid, _ := journal.fsid_of(root)
	testing.expectf(t, os.exists(journal.log_path(fsid)), "no log for %s: %s", mount, rec.problem)

	file := fmt.tprintf("%s.tree", logs)
	defer os.remove(file)
	first, how, why := fill_once(t, root, file)
	scan.tree_destroy(&first)
	testing.expectf(t, how == .Full, "the first read was not whole: %s", why)

	change_fixture(t, root)
	time.sleep(2500 * time.Millisecond)

	base: scan.Tree
	cursor, base_why, loaded := baseline_load(file, root, &base)
	testing.expectf(t, loaded, "the baseline was not kept: %s", base_why)
	defer scan.tree_destroy(&base)
	set, _, err := changes.since(root, cursor)
	defer changes.change_set_destroy(&set)
	testing.expect_value(t, err, changes.Error.None)
	testing.expect(t, set.by_hash, "the update did not use the log")
	named := named_dirs(&base, set)
	want := []string{"", "append", "deep/x/y", "gone", "still", "sub"}
	testing.expectf(t, slice.equal(named, want), "named %v, want %v", named, want)

	got, again, again_by := fill_once_by(t, root, file)
	defer scan.tree_destroy(&got)
	testing.expect_value(t, again, Fill_Kind.Updated)
	testing.expect_value(t, again_by, Read_Source.Recorded)
	whole := read_tree(t, root)
	defer scan.tree_destroy(&whole)
	expect_same(t, &got, &whole)

	sync.atomic_store(&stop, true)
	thread.join(recorder)
	stopped = true
	testing.expectf(t, rec.problem == "", "the recorder failed: %s", rec.problem)
	stale: scan.Tree
	cursor, _, _ = baseline_load(file, root, &stale)
	scan.tree_destroy(&stale)
	after, _, _ := changes.since(root, cursor)
	defer changes.change_set_destroy(&after)
	testing.expect(t, after.probe && !after.by_hash, "a stopped recorder's log was trusted")
}

/*
The place the integration test records, on mount:

	a.txt, sub/b.txt, still/k.txt, deep/x/y/z.txt, gone/g.txt, moving/m.txt,
	append/ap.txt (3,000 bytes)
*/
@(private = "file")
recorded_fixture :: proc(t: ^testing.T, mount: string) -> string {
	root, _ := filepath.join({mount, "leita_journal_test"}, context.temp_allocator)
	os.remove_all(root)
	for d in ([]string{"", "sub", "still", "deep/x/y", "gone", "moving", "append"}) {
		testing.expect(t, os.make_directory_all(at(root, d)) == nil, "could not make the fixture")
	}
	files := []string {
		"a.txt",
		"sub/b.txt",
		"still/k.txt",
		"deep/x/y/z.txt",
		"gone/g.txt",
		"moving/m.txt",
	}
	for f in files {
		put(t, at(root, f), 1000)
	}
	put(t, at(root, "append/ap.txt"), 3000)
	return root
}

/*
change_fixture changes the place: a file made in sub, a directory made in it with a
file in that, 2 KiB appended to append/ap.txt in place (which a probe of folder
times misses), gone/g.txt deleted, moving renamed into still, and z.txt's mode
changed. The directories of the base that changed are the place's own, sub, append,
gone, still and deep/x/y.
*/
@(private = "file")
change_fixture :: proc(t: ^testing.T, root: string) {
	put(t, at(root, "sub/new.txt"), 7000)
	testing.expect(t, os.make_directory(at(root, "sub/fresh")) == nil, "no fresh")
	put(t, at(root, "sub/fresh/f.txt"), 9000)
	f, err := os.open(at(root, "append/ap.txt"), {.Write, .Append})
	testing.expect(t, err == nil, "could not open ap.txt")
	more: [2048]byte
	os.write(f, more[:])
	os.close(f)
	testing.expect(t, os.remove(at(root, "gone/g.txt")) == nil, "could not delete g.txt")
	testing.expect(t, os.rename(at(root, "moving"), at(root, "still/moved")) == nil, "no rename")
	testing.expect(t, os.change_mode(at(root, "deep/x/y/z.txt"), {.Read_User}) == nil, "no chmod")
}

@(private = "file")
at :: proc(root, rel: string) -> string {
	if rel == "" {
		return root
	}
	return strings.concatenate({root, "/", rel}, context.temp_allocator)
}

// The directories of base, by path under its root ("" for the root), whose hash
// the set names; sorted.
@(private = "file")
named_dirs :: proc(base: ^scan.Tree, set: changes.Change_Set) -> []string {
	root := scan.path(base, base.root, context.temp_allocator)
	out := make([dynamic]string, context.temp_allocator)
	for i in 0 ..< scan.slots(base) {
		n := scan.node(base, i)
		if .Directory not_in scan.node_flags(n) {
			continue
		}
		rel := strings.trim_prefix(scan.path(base, i, context.temp_allocator), root)
		rel = strings.trim_prefix(rel, "/")
		spelt :=
			set.root if rel == "" else strings.concatenate({set.root, "/", rel}, context.temp_allocator)
		if journal.hash_path(spelt) in set.hashes {
			append(&out, rel)
		}
	}
	slice.sort(out[:])
	return out[:]
}

@(private = "file")
fill_once :: proc(t: ^testing.T, root, file: string) -> (scan.Tree, Fill_Kind, string) {
	tree, how, _, why := fill_with(t, root, file)
	return tree, how, why
}

@(private = "file")
fill_once_by :: proc(t: ^testing.T, root, file: string) -> (scan.Tree, Fill_Kind, Read_Source) {
	tree, how, by, _ := fill_with(t, root, file)
	return tree, how, by
}

@(private = "file")
fill_with :: proc(
	t: ^testing.T,
	root, file: string,
) -> (
	scan.Tree,
	Fill_Kind,
	Read_Source,
	string,
) {
	target, choice, err := scan.resolve(root)
	testing.expect_value(t, err, scan.Error.None)
	defer scan.target_destroy(&target)
	tree: scan.Tree
	testing.expect_value(t, scan.tree_init(&tree, 2), scan.Error.None)
	f := Fill {
		target = target,
		engine = choice.engine,
		wcfg = {workers = 2},
		tree = &tree,
		baseline = file,
	}
	defer fill_destroy(&f)
	fill_run(&f)
	testing.expectf(t, problem(&f) == "", "the fill failed: %s", problem(&f))
	testing.expect(t, f.saved, "the result was not kept")
	return tree, f.how, f.by, f.why
}
