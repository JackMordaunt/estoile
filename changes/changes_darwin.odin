#+build darwin
package changes

import "base:runtime"
import "core:strings"
import "core:sys/posix"
import "core:time"

/*
macOS: the volume's FSEvents history.

fseventsd keeps a log of which directories changed on each volume, on the volume
itself (.fseventsd), so it outlives the process asking and a reboot (Apple, File
System Events Programming Guide: "The File System Events API ... persistent"). Every event has
an id from one counter; a stream opened with `sinceWhen` set to an id replays every
event after it for the paths asked about, then says HistoryDone. Events name
directories, not files, unless asked otherwise, which is what an update reads again.
No privilege is needed beyond reading the place.

The cursor is the current event id, taken before anything is read, and the UUID of
the volume's event store: a store that was wiped and begun again has another, and
its ids say nothing about the old one's.

fseventsd takes a change from the kernel some time after it is made, 10 ms to 1.2 s
after a file's close(2) on an M1 Pro under macOS 15.7 (2026-10-13), and only then
gives it an id and puts it in the history. A replay that starts sooner does not name
it. Keeping the stream open 1 s after HistoryDone caught 15 of 21 such events, and
FSEventStreamFlushSync 2 of 19, so neither is done. The current id taken before the
replay was below such an event's id every time, and 1,291 chained updates over
55,000 writes lost none, so the next update replays it: a change made that close
before an update is read by the next one, as one made while the update runs is. The
cost is such a change shown one update late; no margin on the cursor is needed.

The stream reports that it could not keep up, or that events were dropped, as
MustScanSubDirs on a directory, which is read again whole; on the place or above it,
the place is scanned whole. A changed root, a wrapped counter, a cursor more than
REPLAY_MOST events back, or a history that does not finish within HISTORY_WAIT does
the same.
*/
HISTORY_WAIT :: 30 * time.Second

/*
REPLAY_MOST is the most events since the cursor that `since` replays. A replay
filters every event on the volume since the cursor, not only the place's, at about
0.45 µs an event, so a busy volume's day can cost more than the update saves. On an
M1 Pro (2026-10-13) 7.16M events took 3.0 s to replay, and `leita ~` read 2.57M
entries whole in 12.6 s and updated them in 0.78 s. 4M events is about 2 s of replay,
the update then near 3 s against 12.6 s; past that the saving shrinks while the
replay grows with the volume, not the place, so the place is read whole.
*/
REPLAY_MOST :: 4_000_000

// A cursor for `place` as it is now, to take before scanning it whole. Not ok on a
// volume with no event store, a network share or a read-only image.
now :: proc(place: string) -> (c: Cursor, ok: bool) {
	store, has_store := store_of(place)
	if !has_store {
		return {}, false
	}
	return {
			source = .Fsevents,
			volume = store,
			position = i64(FSEventsGetCurrentEventId()),
			full = now_ns(),
		},
		true
}

/*
What changed in `place` since `c`: the directories under it that events name, spelt
from `place`, and the new cursor, taken before the history was asked for.
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
	if c.source != .Fsevents {
		return rescan("no event history cursor was kept for this place"), {}, .None
	}
	store, has_store := store_of(place)
	if !has_store {
		return rescan("the place's volume keeps no event history"), {}, .None
	}
	if store != c.volume {
		return rescan("the volume's event history was begun anew"), {}, .None
	}
	canonical, resolved := real_path(place)
	if !resolved {
		return rescan("the place could not be resolved"), {}, .None
	}
	next = c
	next.position = i64(FSEventsGetCurrentEventId())
	if too_much_to_replay(u64(c.position), u64(next.position)) {
		why :: "too much has happened on the volume since the place was last read"
		return rescan(why), {}, .None
	}

	h := History {
		place     = place,
		canonical = canonical,
		allocator = allocator,
	}
	h.changed = Change_Set {
		shallow = make([dynamic]string, allocator),
		deep    = make([dynamic]string, allocator),
	}
	if !replay(&h, u64(c.position)) && h.why == "" {
		h.why = "the event history did not finish"
	}
	if h.why != "" {
		change_set_destroy(&h.changed)
		return rescan(h.why), {}, .None
	}
	if h.oom {
		change_set_destroy(&h.changed)
		return {}, {}, .Out_Of_Memory
	}
	return h.changed, next, .None
}

// Whether more than REPLAY_MOST events lie between the cursor's id and the current
// one. A current id below the cursor's is left to the replay, which says the counter
// wrapped.
@(private)
too_much_to_replay :: proc(from, current: u64) -> bool {
	return current > from && current - from > REPLAY_MOST
}

// One replay's state, which the stream's callback fills.
@(private = "file")
History :: struct {
	place:     string,
	canonical: string,
	changed:   Change_Set,
	why:       string, // set when the place must be scanned whole
	done:      bool,
	oom:       bool,
	allocator: runtime.Allocator,
}

/*
Open a stream on the place from event `from`, run it on this thread's run loop until
it says the history is done, and close it. Whether it finished.
*/
@(private = "file")
replay :: proc(h: ^History, from: u64) -> bool {
	path := CFStringCreateWithBytes(
		nil,
		raw_data(h.canonical),
		len(h.canonical),
		K_CF_STRING_ENCODING_UTF8,
		false,
	)
	if path == nil {
		return false
	}
	defer CFRelease(path)
	values := [1]rawptr{path}
	paths := CFArrayCreate(nil, &values[0], 1, &kCFTypeArrayCallBacks)
	if paths == nil {
		return false
	}
	defer CFRelease(paths)

	ctx := Stream_Context {
		info = h,
	}
	stream := FSEventStreamCreate(
		nil,
		on_events,
		&ctx,
		paths,
		from,
		0,
		K_FS_EVENT_STREAM_CREATE_FLAG_NO_DEFER | K_FS_EVENT_STREAM_CREATE_FLAG_WATCH_ROOT,
	)
	if stream == nil {
		return false
	}
	defer FSEventStreamRelease(stream)
	FSEventStreamScheduleWithRunLoop(stream, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode)
	defer FSEventStreamInvalidate(stream)
	if !FSEventStreamStart(stream) {
		return false
	}
	defer FSEventStreamStop(stream)

	deadline := time.tick_now()
	for !h.done && h.why == "" && time.tick_since(deadline) < HISTORY_WAIT {
		CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.1, true)
	}
	return h.done
}

@(private = "file")
on_events :: proc "c" (
	stream: rawptr,
	info: rawptr,
	count: uint,
	paths: [^]cstring,
	flags: [^]u32,
	ids: [^]u64,
) {
	h := (^History)(info)
	context = runtime.default_context()
	context.allocator = h.allocator
	for i in 0 ..< count {
		f := flags[i]
		if f & K_FS_EVENT_STREAM_EVENT_FLAG_HISTORY_DONE != 0 {
			h.done = true
			continue
		}
		if f & K_FS_EVENT_STREAM_EVENT_FLAG_EVENT_IDS_WRAPPED != 0 {
			h.why = "the event counter wrapped"
			continue
		}
		if f & K_FS_EVENT_STREAM_EVENT_FLAG_ROOT_CHANGED != 0 {
			h.why = "the place was moved or deleted"
			continue
		}
		path := strings.trim_right(string(paths[i]), "/")
		if path == "" {
			path = "/"
		}
		rest, inside := under(h.canonical, path)
		whole := f & (K_FS_EVENT_STREAM_EVENT_FLAG_MUST_SCAN_SUB_DIRS | MOUNTED) != 0
		if !inside {
			// Above the place: only a whole-tree event there reaches into it.
			if whole {
				if _, below := under(path, h.canonical); below {
					h.why = "events under the place were dropped"
				}
			}
			continue
		}
		if whole && rest == "" {
			h.why = "events under the place were dropped"
			continue
		}
		spelt: string
		err: runtime.Allocator_Error
		if rest == "" {
			spelt, err = strings.clone(h.place)
		} else {
			spelt, err = strings.concatenate({strings.trim_right(h.place, "/"), "/", rest})
		}
		if err != nil {
			h.oom = true
			continue
		}
		if whole {
			append(&h.changed.deep, spelt)
		} else {
			append(&h.changed.shallow, spelt)
		}
	}
}

// The place as the kernel spells it, which is how events name it: /var is
// /private/var. In the temp allocator.
@(private = "file")
real_path :: proc(place: string) -> (string, bool) {
	buf: [posix.PATH_MAX]byte
	got := posix.realpath(strings.clone_to_cstring(place, context.temp_allocator), &buf[0])
	if got == nil {
		return "", false
	}
	return strings.clone_from_cstring(got, context.temp_allocator), true
}

// The UUID of the event store of the volume `place` is on.
@(private = "file")
store_of :: proc(place: string) -> (store: [2]u64, ok: bool) {
	st: posix.stat_t
	if posix.stat(strings.clone_to_cstring(place, context.temp_allocator), &st) != .OK {
		return {}, false
	}
	uuid := FSEventsCopyUUIDForDevice(i32(st.st_dev))
	if uuid == nil {
		return {}, false
	}
	defer CFRelease(uuid)
	return transmute([2]u64)CFUUIDGetUUIDBytes(uuid).bytes, true
}

@(private = "file")
K_CF_STRING_ENCODING_UTF8 :: 0x08000100
@(private = "file")
K_FS_EVENT_STREAM_CREATE_FLAG_NO_DEFER :: 0x02
@(private = "file")
K_FS_EVENT_STREAM_CREATE_FLAG_WATCH_ROOT :: 0x04
@(private = "file")
K_FS_EVENT_STREAM_EVENT_FLAG_MUST_SCAN_SUB_DIRS :: 0x01
@(private = "file")
K_FS_EVENT_STREAM_EVENT_FLAG_EVENT_IDS_WRAPPED :: 0x08
@(private = "file")
K_FS_EVENT_STREAM_EVENT_FLAG_HISTORY_DONE :: 0x10
@(private = "file")
K_FS_EVENT_STREAM_EVENT_FLAG_ROOT_CHANGED :: 0x20
// kFSEventStreamEventFlagMount and Unmount: another volume came or went at a path.
@(private = "file")
MOUNTED :: 0x40 | 0x80

@(private = "file")
Stream_Context :: struct {
	version:          int,
	info:             rawptr,
	retain:           rawptr,
	release:          rawptr,
	copy_description: rawptr,
}

// CFUUIDBytes, a struct of sixteen bytes, as C returns one.
@(private = "file")
Uuid_Bytes :: struct {
	bytes: [16]u8,
}

@(private = "file")
Callback :: proc "c" (
	stream: rawptr,
	info: rawptr,
	count: uint,
	paths: [^]cstring,
	flags: [^]u32,
	ids: [^]u64,
)

foreign import core_services "system:CoreServices.framework"
foreign import core_foundation "system:CoreFoundation.framework"

@(default_calling_convention = "c", private = "file")
foreign core_services {
	FSEventsGetCurrentEventId        :: proc() -> u64 ---
	FSEventsCopyUUIDForDevice        :: proc(dev: i32) -> rawptr ---
	FSEventStreamCreate              :: proc(allocator: rawptr, callback: Callback, ctx: ^Stream_Context, paths: rawptr, since_when: u64, latency: f64, flags: u32) -> rawptr ---
	FSEventStreamScheduleWithRunLoop :: proc(stream: rawptr, run_loop: rawptr, mode: rawptr) ---
	FSEventStreamStart               :: proc(stream: rawptr) -> b8 ---
	FSEventStreamStop                :: proc(stream: rawptr) ---
	FSEventStreamInvalidate          :: proc(stream: rawptr) ---
	FSEventStreamRelease             :: proc(stream: rawptr) ---
}

@(default_calling_convention = "c", private = "file")
foreign core_foundation {
	kCFTypeArrayCallBacks: [5]rawptr
	kCFRunLoopDefaultMode: rawptr
	CFStringCreateWithBytes :: proc(allocator: rawptr, bytes: [^]u8, count: int, encoding: u32, external: b8) -> rawptr ---
	CFArrayCreate           :: proc(allocator: rawptr, values: [^]rawptr, count: int, callbacks: ^[5]rawptr) -> rawptr ---
	CFRelease               :: proc(cf: rawptr) ---
	CFRunLoopGetCurrent     :: proc() -> rawptr ---
	CFRunLoopRunInMode      :: proc(mode: rawptr, seconds: f64, return_after_source_handled: b8) -> i32 ---
	CFUUIDGetUUIDBytes      :: proc(uuid: rawptr) -> Uuid_Bytes ---
}
