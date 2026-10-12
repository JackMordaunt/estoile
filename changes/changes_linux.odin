#+build linux
package changes

import "core:strings"
import "core:sys/linux"
import "core:time"

/*
Linux keeps no history of changes that a run started later can read. fanotify
reports a whole filesystem's changes, directory and name, but only to a listener
that is running when they happen, and a filesystem mark needs CAP_SYS_ADMIN
(fanotify_init(2), fanotify_mark(2)); inotify needs no privilege but a watch per
directory, and also reports only while it runs (inotify(7)). A scheduled run that is not
resident between runs has nothing to ask, so the answer here is a probe: the cursor
is the time the place was last read, and the update asks each directory whether it
changed since (walk.Update.probe).

SLACK is taken off that time, for a filesystem that stamps coarsely (FAT keeps
two-second times) or a clock that read a little ahead of the one stamping.

A probe cannot see a file written in place in a directory that did not change, other
than the large ones it re-stats; STALE_AFTER bounds how long such drift can build up
before the place is scanned whole again.
*/
SLACK       :: 2 * time.Second
STALE_AFTER :: 7 * 24 * time.Hour

// A cursor for `place` as it is now, to take before scanning it whole.
now :: proc(place: string) -> (c: Cursor, ok: bool) {
	dev, found := device_of(place)
	if !found {
		return {}, false
	}
	at := now_ns()
	c = Cursor {
		source   = .Probe,
		position = at,
		full     = at,
	}
	c.volume[0] = dev
	return c, true
}

/*
What to read again in `place` since `c`. Never a list: a probe, or a rescan when the
place is on another device than it was, the clock went back, or the last whole scan
is older than STALE_AFTER. The new cursor carries the last whole scan's time on.
*/
since :: proc(
	place: string,
	c: Cursor,
	allocator := context.allocator,
) -> (
	changed: Change_Set,
	next: Cursor,
	err: Error,
) {
	if c.source != .Probe {
		return rescan("no cursor was kept for this place"), {}, .None
	}
	dev, found := device_of(place)
	if !found {
		return rescan("the place could not be asked which device it is on"), {}, .None
	}
	if c.volume[0] != dev {
		return rescan("the place is on another device than when it was read"), {}, .None
	}
	at := now_ns()
	if at < c.position {
		return rescan("the clock reads earlier than when the place was read"), {}, .None
	}
	if at - c.full > i64(STALE_AFTER) {
		return rescan("the place was last scanned whole over 7 days ago"), {}, .None
	}
	next = c
	next.position = at
	changed = Change_Set {
		probe   = true,
		since   = c.position - i64(SLACK),
		shallow = make([dynamic]string, allocator),
		deep    = make([dynamic]string, allocator),
	}
	return changed, next, .None
}

@(private = "file")
device_of :: proc(place: string) -> (dev: u64, ok: bool) {
	cpath := strings.clone_to_cstring(place, context.temp_allocator)
	st: linux.Statx
	if linux.statx(linux.AT_FDCWD, cpath, {}, {.INO}, &st) != .NONE {
		return 0, false
	}
	return u64(st.dev_major) << 32 | u64(st.dev_minor), true
}
