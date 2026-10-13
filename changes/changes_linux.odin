#+build linux
package changes

import "core:strings"
import "core:sys/linux"
import "core:time"

import "../journal"

/*
Linux keeps no history of changes that a run started later can read. fanotify
reports a whole filesystem's changes, directory and name, but only to a listener
that is running when they happen, and a filesystem mark needs CAP_SYS_ADMIN
(fanotify_init(2), fanotify_mark(2)); inotify needs no privilege but a watch per
directory, and also reports only while it runs (inotify(7)). A scheduled run that is not
resident between runs has nothing to ask of the system, so the cursor is the time the
place was last read, and the answer comes from one of two places.

Where leita's recorder runs (package journal: `leita journal on`, root, off until
asked) and its log covers the whole time since the cursor, the log names the
directories that changed, and only those are read again. Otherwise, with no
recorder, a filesystem whose mark failed (a btrfs subvolume, under Linux 7.0.14:
package journal), or a break in its log, the answer is a probe: the update asks each
directory whether it changed since (walk.Update.probe). The cursor is the same either
way, so a baseline kept with one serves the other.

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
What to read again in `place` since `c`: the directories the recorder's log says
changed, when it covers the time since, or else a probe; or a rescan when the place
is on another device than it was, the clock went back, or the last whole scan is
older than STALE_AFTER. The new cursor carries the last whole scan's time on.
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
	if set, end, ok := recorded(place, c.position - i64(SLACK), at, allocator); ok {
		next.position = end
		return set, next, .None
	}
	next.position = at
	changed = Change_Set {
		probe   = true,
		since   = c.position - i64(SLACK),
		shallow = make([dynamic]string, allocator),
		deep    = make([dynamic]string, allocator),
	}
	return changed, next, .None
}

/*
recorded is what the recorder's log says changed in `place` from `from` to `to`, ns
since the epoch, when it covers that time without a break: the hashes of the
directories that changed, and when the log's record of the time ends, which is where
the next window begins. Not ok when there is no log for the place's filesystem, it
does not cover the time, or it spells paths from a mount the place is not under.
*/
@(private = "file")
recorded :: proc(
	place: string,
	from, to: i64,
	allocator := context.allocator,
) -> (
	set: Change_Set,
	end: i64,
	ok: bool,
) {
	fsid := journal.fsid_of(place) or_return
	root := journal.canonical(place, allocator) or_return
	w, why := journal.window(journal.log_path(fsid), from, to, allocator)
	defer delete(w.mount, allocator)
	if _, inside := under(w.mount, root); why != "" || !inside {
		delete(root, allocator)
		delete(w.hashes)
		return {}, 0, false
	}
	set = Change_Set {
		by_hash = true,
		root    = root,
		hashes  = w.hashes,
		shallow = make([dynamic]string, allocator),
		deep    = make([dynamic]string, allocator),
	}
	return set, w.end, true
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
