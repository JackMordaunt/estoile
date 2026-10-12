#+build darwin
package changes

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"
import "core:time"

@(private = "file")
fresh :: proc(t: ^testing.T, name: string) -> string {
	dir, dir_err := os.temp_directory(context.temp_allocator)
	testing.expect(t, dir_err == nil, "no temp directory")
	root := fmt.tprintf("%s/leita_changes_%s", strings.trim_right(dir, "/"), name)
	os.remove_all(root)
	testing.expect(t, os.make_directory(root) == nil, "could not make the root")
	return root
}

@(private = "file")
put :: proc(t: ^testing.T, path: string, size: int) {
	body := make([]byte, size, context.temp_allocator)
	slice.fill(body, 'x')
	testing.expectf(t, os.write_entire_file(path, body) == nil, "could not write %s", path)
}

/*
FSEvents names the directories whose entries changed after the cursor, spelt from
the place as given: the temp directory is under /var, which the kernel and so every
event spells /private/var. fseventsd hands events on after a short delay, so the
history is asked again until it has them, for up to ten seconds.
*/
@(test)
test_the_event_history_names_the_directories_that_changed :: proc(t: ^testing.T) {
	root := fresh(t, "fsevents")
	defer os.remove_all(root)
	sub := fmt.tprintf("%s/sub", root)
	still := fmt.tprintf("%s/still", root)
	testing.expect(t, os.make_directory(sub) == nil, "could not make sub")
	testing.expect(t, os.make_directory(still) == nil, "could not make still")
	put(t, fmt.tprintf("%s/k.txt", still), 100)
	time.sleep(2 * time.Second) // let what made the fixture reach the history first

	c, ok := now(root)
	if !testing.expect(t, ok, "no cursor: the temp directory's volume keeps no event history") {
		return
	}
	put(t, fmt.tprintf("%s/new.txt", sub), 5000)

	found: bool
	set: Change_Set
	defer change_set_destroy(&set)
	start := time.tick_now()
	for !found && time.tick_since(start) < 10 * time.Second {
		change_set_destroy(&set)
		err: Error
		set, _, err = since(root, c)
		testing.expect_value(t, err, Error.None)
		if !testing.expectf(t, !set.rescan, "rescan: %s", set.why) {
			return
		}
		found = slice.contains(set.shallow[:], sub)
		if !found {
			time.sleep(250 * time.Millisecond)
		}
	}
	testing.expectf(t, found, "sub is not named: %v", set.shallow)
	testing.expectf(t, !slice.contains(set.shallow[:], still), "still is named: %v", set.shallow)
}

// A cursor of another kind, or from another event store, rescans.
@(test)
test_an_event_cursor_that_cannot_be_trusted_rescans :: proc(t: ^testing.T) {
	root := fresh(t, "fsevents_bad")
	defer os.remove_all(root)
	c, ok := now(root)
	if !testing.expect(t, ok, "no cursor: the temp directory's volume keeps no event history") {
		return
	}
	other := c
	other.volume[0] += 1
	for bad in ([]Cursor{{}, other}) {
		set, _, err := since(root, bad)
		testing.expect_value(t, err, Error.None)
		testing.expectf(t, set.rescan && set.why != "", "%v: no rescan", bad)
	}
}
