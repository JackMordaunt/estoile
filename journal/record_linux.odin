#+build linux
package journal

import "base:intrinsics"
import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:sys/linux"
import "core:time"

// fanotify(7)'s values (include/uapi/linux/fanotify.h), which core:sys/linux lacks.
@(private = "file")
FAN_CLASS_NOTIF :: 0x0
@(private = "file")
FAN_CLOEXEC :: 0x1
@(private = "file")
FAN_NONBLOCK :: 0x2
@(private = "file")
FAN_REPORT_FID :: 0x200
@(private = "file")
FAN_REPORT_DIR_FID :: 0x400
@(private = "file")
FAN_REPORT_NAME :: 0x800
@(private = "file")
FAN_MARK_ADD :: 0x1
@(private = "file")
FAN_MARK_REMOVE :: 0x2
@(private = "file")
FAN_MARK_FILESYSTEM :: 0x100
@(private = "file")
FAN_MODIFY :: u64(0x2)
@(private = "file")
FAN_ATTRIB :: u64(0x4)
@(private = "file")
FAN_CLOSE_WRITE :: u64(0x8)
@(private = "file")
FAN_MOVED_FROM :: u64(0x40)
@(private = "file")
FAN_MOVED_TO :: u64(0x80)
@(private = "file")
FAN_CREATE :: u64(0x100)
@(private = "file")
FAN_DELETE :: u64(0x200)
@(private = "file")
FAN_Q_OVERFLOW :: u64(0x4000)
@(private = "file")
FAN_ONDIR :: u64(0x40000000)
@(private = "file")
FAN_EVENT_INFO_TYPE_FID :: 1
@(private = "file")
FAN_EVENT_INFO_TYPE_DFID_NAME :: 2
@(private = "file")
FAN_EVENT_INFO_TYPE_DFID :: 3

/*
MASK is what the recorder asks to hear of: every change to what a directory holds,
a file's contents and its attributes. A write through mmap sent no FAN_MODIFY on
ext4 under Linux 7.0.14 (2026-10-13); FAN_CLOSE_WRITE caught it when the file was
closed. FAN_Q_OVERFLOW is not asked for: fanotify_mark refused a mask holding it
with EINVAL on the same kernel, and fanotify(7) has the kernel queue it whatever
the mask.
*/
@(private = "file")
MASK ::
	FAN_CREATE |
	FAN_DELETE |
	FAN_MOVED_FROM |
	FAN_MOVED_TO |
	FAN_MODIFY |
	FAN_CLOSE_WRITE |
	FAN_ATTRIB |
	FAN_ONDIR

// The layout of struct fanotify_event_metadata.
@(private = "file")
Event_Metadata :: struct {
	event_len:    u32,
	vers:         u8,
	reserved:     u8,
	metadata_len: u16,
	mask:         u64,
	fd:           i32,
	pid:          i32,
}

// How often pending directories are resolved and recorded.
@(private = "file")
FLUSH_EVERY :: time.Second

// How long the recorder waits for an event before looking at the clock.
@(private = "file")
WAIT_MS :: 250

// How often the recorder drops records older than RETENTION.
@(private = "file")
COMPACT_EVERY :: 24 * time.Hour

/*
What the recorder is to do: write its logs in `logs`, mark only the filesystems
mounted at the points in `only` when it names any (a test's), and stop once `stop`
is set.
*/
Config :: struct {
	logs: string,
	only: []string,
	stop: ^bool,
}

// A filesystem the recorder records, and the log it writes.
@(private = "file")
Recorded_Filesystem :: struct {
	mount_id: int,
	device:   string,
	point:    string,
	fstype:   string,
	fsid:     [2]i32,
	dir:      linux.Fd, // the mount point, open: handles resolve through it
	log:      ^os.File,
	path:     string,
	buf:      [dynamic]byte, // records to append at the next write
}

// A filesystem the recorder does not record, and why.
@(private = "file")
Skipped_Filesystem :: struct {
	point:  string,
	fstype: string,
	why:    string,
}

@(private = "file")
Recorder :: struct {
	cfg:       Config,
	fan:       linux.Fd,
	mountinfo: linux.Fd,
	own:       u64, // the log folder's hash: its own writes are not recorded
	recorded:  [dynamic]Recorded_Filesystem,
	skipped:   [dynamic]Skipped_Filesystem,
	tried:     map[int]struct{}, // mount ids already judged
	judged:    map[string]struct{}, // devices already recorded or skipped
	pending:   map[string]struct{}, // fsid and file handle of each directory heard of
	events:    []byte,
}

/*
run records changes until cfg.stop is set, then writes a Stop to every log. It
returns "" once stopped, or why it could not start, in the caller's temp allocator:
fanotify needs root, or CAP_SYS_ADMIN and CAP_DAC_READ_SEARCH (fanotify_init(2),
open_by_handle_at(2)).
*/
run :: proc(cfg: Config) -> (problem: string) {
	// A run lasts as long as the machine is up: what each pass makes in the temp
	// allocator is let go at the end of it, in an arena of the run's own, so the
	// caller's temporaries stay its own.
	said := context.temp_allocator
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil {
		return "no memory to record changes with"
	}
	defer virtual.arena_destroy(&arena)
	context.temp_allocator = virtual.arena_allocator(&arena)

	r := Recorder {
		cfg    = cfg,
		events = make([]byte, 256 * 1024),
	}
	defer recorder_destroy(&r)
	perm := os.Permissions_Read_All + os.Permissions_Execute_All + {.Write_User}
	if err := os.make_directory_all(cfg.logs, perm); err != nil && err != .Exist {
		return fmt.aprintf("cannot make %s: %v", cfg.logs, err, allocator = said)
	}
	if own, ok := canonical(cfg.logs, context.temp_allocator); ok {
		r.own = hash_path(own)
	}
	fan := intrinsics.syscall(
		linux.SYS_fanotify_init,
		uintptr(
			FAN_CLASS_NOTIF |
			FAN_CLOEXEC |
			FAN_NONBLOCK |
			FAN_REPORT_FID |
			FAN_REPORT_DIR_FID |
			FAN_REPORT_NAME,
		),
		0,
	)
	if errno := linux.Errno(-int(fan)); int(fan) < 0 {
		return fmt.aprintf("fanotify_init: %v (it needs root)", errno, allocator = said)
	}
	r.fan = linux.Fd(fan)
	info, info_err := linux.open("/proc/self/mountinfo", {.CLOEXEC})
	if info_err != .NONE {
		return fmt.aprintf("cannot open /proc/self/mountinfo: %v", info_err, allocator = said)
	}
	r.mountinfo = info
	// With nothing to record yet it runs all the same, for a filesystem mounted
	// later; the status says why each was not recorded.
	sync_mounts(&r)
	loop(&r)
	for &fs in r.recorded {
		stop_recording(&fs)
	}
	write_status(&r)
	return ""
}

// loop reads events until told to stop: resolving each second, a heartbeat each
// HEARTBEAT, a compaction each day, and the mounts again whenever they change.
@(private = "file")
loop :: proc(r: ^Recorder) {
	last_flush, last_beat, last_compact := time.now(), time.now(), time.now()
	for !sync.atomic_load(r.cfg.stop) {
		fds := [2]linux.Poll_Fd{{fd = r.fan, events = {.IN}}, {fd = r.mountinfo, events = {.PRI}}}
		n, _ := linux.poll(fds[:], WAIT_MS)
		if n > 0 && .IN in fds[0].revents {
			read_events(r)
		}
		if n > 0 && fds[1].revents & {.PRI, .ERR} != {} {
			flush(r)
			sync_mounts(r)
		}
		now := time.now()
		if time.diff(last_flush, now) >= FLUSH_EVERY {
			flush(r)
			last_flush = now
		}
		if time.diff(last_beat, now) >= HEARTBEAT {
			flush(r)
			mark_all(r, .Heartbeat)
			last_beat = now
		}
		if time.diff(last_compact, now) >= COMPACT_EVERY {
			for &fs in r.recorded {
				compact_log(&fs)
			}
			last_compact = now
		}
		free_all(context.temp_allocator)
	}
	read_events(r)
	flush(r)
}

@(private = "file")
recorder_destroy :: proc(r: ^Recorder) {
	for &fs in r.recorded {
		forget(&fs)
	}
	delete(r.recorded)
	for s in r.skipped {
		delete(s.point)
		delete(s.fstype)
		delete(s.why)
	}
	delete(r.skipped)
	delete(r.tried)
	for k in r.judged {
		delete(k)
	}
	delete(r.judged)
	for k in r.pending {
		delete(k)
	}
	delete(r.pending)
	delete(r.events)
	if r.fan > 0 {
		linux.close(r.fan)
	}
	if r.mountinfo > 0 {
		linux.close(r.mountinfo)
	}
}

@(private = "file")
forget :: proc(fs: ^Recorded_Filesystem) {
	if fs.log != nil {
		os.close(fs.log)
	}
	if fs.dir > 0 {
		linux.close(fs.dir)
	}
	delete(fs.device)
	delete(fs.point)
	delete(fs.fstype)
	delete(fs.path)
	delete(fs.buf)
	fs^ = {}
}

/*
read_events reads what the kernel has queued, keeping each directory an event
names once: its parent's handle for an entry made, gone, moved or changed, and a
directory's own handle for a change to its attributes.
*/
@(private = "file")
read_events :: proc(r: ^Recorder) {
	// The descriptor does not block: a read with nothing queued, or one a signal
	// cut short, returns, and the loop polls again.
	for {
		n, err := linux.read(r.fan, r.events)
		if err != .NONE || n <= 0 {
			return
		}
		at := 0
		for at + size_of(Event_Metadata) <= n {
			md := (^Event_Metadata)(&r.events[at])
			if md.event_len < size_of(Event_Metadata) || at + int(md.event_len) > n {
				break
			}
			take_event(r, r.events[at:at + int(md.event_len)], md)
			at += int(md.event_len)
		}
		// One read drains a queue that fits the buffer; poll says if more came.
		if n < len(r.events) / 2 {
			return
		}
	}
}

@(private = "file")
take_event :: proc(r: ^Recorder, event: []byte, md: ^Event_Metadata) {
	if md.mask & FAN_Q_OVERFLOW != 0 {
		flush(r)
		mark_all(r, .Overflow)
		return
	}
	at := int(md.metadata_len)
	for at + 4 <= len(event) {
		kind := event[at]
		size := int(u16(event[at + 2]) | u16(event[at + 3]) << 8)
		if size < 4 || at + size > len(event) {
			return
		}
		info := event[at:at + size]
		at += size
		dir := kind == FAN_EVENT_INFO_TYPE_DFID_NAME || kind == FAN_EVENT_INFO_TYPE_DFID
		own := kind == FAN_EVENT_INFO_TYPE_FID && md.mask & FAN_ONDIR != 0
		if !(dir || own) || len(info) < 4 + 8 + 8 {
			continue
		}
		// struct fanotify_event_info_fid (include/uapi/linux/fanotify.h): the
		// 4-byte header, the 8-byte fsid, then struct file_handle
		// (open_by_handle_at(2)), whose first u32 is how many bytes of handle
		// follow its 8-byte head.
		hbytes := int(
			u32(info[12]) | u32(info[13]) << 8 | u32(info[14]) << 16 | u32(info[15]) << 24,
		)
		end := 12 + 8 + hbytes
		if end > len(info) {
			continue
		}
		key := string(info[4:end])
		if key not_in r.pending {
			r.pending[strings.clone(key)] = {}
		}
	}
}

/*
flush resolves each directory heard of since the last flush once, through its
filesystem's mount point, and appends a Changed record of its path's hash to that
filesystem's log. A directory gone since is not recorded: its parent was, when it
went.
*/
@(private = "file")
flush :: proc(r: ^Recorder) {
	now := time.to_unix_nanoseconds(time.now())
	for key in r.pending {
		defer delete(key)
		fs := find(r, key[:8])
		if fs == nil {
			continue
		}
		handle := raw_data(key[8:])
		fd := intrinsics.syscall(
			linux.SYS_open_by_handle_at,
			uintptr(fs.dir),
			uintptr(handle),
			uintptr(transmute(u32)linux.Open_Flags{.PATH, .CLOEXEC}),
		)
		if int(fd) < 0 {
			continue
		}
		path, ok := fd_path(linux.Fd(fd), context.temp_allocator)
		linux.close(linux.Fd(fd))
		if !ok || strings.has_suffix(path, " (deleted)") {
			continue
		}
		if h := hash_path(path); h != r.own {
			append_record(fs, {.Changed, now, h})
		}
	}
	clear(&r.pending)
	for &fs in r.recorded {
		write_log(&fs)
	}
}

// find is the recorded filesystem whose fsid is the 8 bytes given, or nil.
@(private = "file")
find :: proc(r: ^Recorder, fsid: string) -> ^Recorded_Filesystem {
	for &fs in r.recorded {
		id := transmute([8]byte)fs.fsid
		if string(id[:]) == fsid {
			return &fs
		}
	}
	return nil
}

// mark_all appends a record of kind to every log, and writes it.
@(private = "file")
mark_all :: proc(r: ^Recorder, kind: Kind) {
	now := time.to_unix_nanoseconds(time.now())
	for &fs in r.recorded {
		append_record(&fs, {kind, now, 0})
		write_log(&fs)
	}
}

@(private = "file")
append_record :: proc(fs: ^Recorded_Filesystem, rec: Record) {
	buf: [RECORD_SIZE]byte
	record_put(buf[:], rec)
	append(&fs.buf, ..buf[:])
}

@(private = "file")
write_log :: proc(fs: ^Recorded_Filesystem) {
	if len(fs.buf) == 0 || fs.log == nil {
		return
	}
	os.write(fs.log, fs.buf[:])
	clear(&fs.buf)
}

/*
sync_mounts reads the mounts again: a filesystem recorded whose mount is gone gets
a Stop, since what happens to it unmounted is not seen, and each mount not judged
before is marked if it can be.
*/
@(private = "file")
sync_mounts :: proc(r: ^Recorder) {
	text := read_mountinfo(r.mountinfo)
	mounts := mounts_parse(text, context.temp_allocator)
	for i := len(r.recorded) - 1; i >= 0; i -= 1 {
		fs := &r.recorded[i]
		if !has_mount(mounts, fs.mount_id) {
			stop_recording(fs)
			forget(fs)
			ordered_remove(&r.recorded, i)
		}
	}
	for m in mounts {
		if m.id in r.tried {
			continue
		}
		r.tried[m.id] = {}
		if len(r.cfg.only) > 0 && !listed(r.cfg.only, m.point) {
			continue
		}
		try_mount(r, m, mounts)
	}
	write_status(r)
}

@(private = "file")
has_mount :: proc(mounts: []Mount, id: int) -> bool {
	for m in mounts {
		if m.id == id {
			return true
		}
	}
	return false
}

@(private = "file")
listed :: proc(list: []string, s: string) -> bool {
	for x in list {
		if x == s {
			return true
		}
	}
	return false
}

// read_mountinfo is the whole of /proc/self/mountinfo, read from its start through
// fd, which then waits for the next change; in the temp allocator.
@(private = "file")
read_mountinfo :: proc(fd: linux.Fd) -> string {
	out := make([dynamic]byte, context.temp_allocator)
	buf: [16 * 1024]byte
	at := i64(0)
	for {
		n, err := linux.pread(fd, buf[:], at)
		if err != .NONE || n <= 0 {
			break
		}
		append(&out, ..buf[:n])
		at += i64(n)
	}
	return string(out[:])
}

/*
try_mount marks the filesystem mounted at m, unless it is not one to record, was
recorded or skipped already through another mount, or has a mount of its whole
elsewhere that is tried instead. A mount of one folder of a filesystem is not
recorded: the recorder could not spell paths outside that folder. Each filesystem
is listed in the status once, by the first mount of it tried.
*/
@(private = "file")
try_mount :: proc(r: ^Recorder, m: Mount, mounts: []Mount) {
	try, why := judge(m)
	if !try {
		if why != "" {
			skip(r, m, why)
		}
		return
	}
	if m.device in r.judged {
		return
	}
	if m.root != "/" {
		for other in mounts {
			if other.device == m.device && other.root == "/" {
				return
			}
		}
	}
	point := strings.clone_to_cstring(m.point, context.temp_allocator)
	if errno := fan_mark(r.fan, FAN_MARK_ADD | FAN_MARK_FILESYSTEM, point); errno != .NONE {
		skip(r, m, mark_problem(m, errno))
		return
	}
	if m.root != "/" {
		fan_mark(r.fan, FAN_MARK_REMOVE | FAN_MARK_FILESYSTEM, point)
		skip(r, m, "only one folder of it is mounted")
		return
	}
	fs, problem := start_recording(r, m)
	if problem != "" {
		fan_mark(r.fan, FAN_MARK_REMOVE | FAN_MARK_FILESYSTEM, point)
		skip(r, m, problem)
		return
	}
	r.judged[strings.clone(m.device)] = {}
	append(&r.recorded, fs)
}

@(private = "file")
fan_mark :: proc(fan: linux.Fd, flags: uint, path: cstring) -> linux.Errno {
	when size_of(uintptr) == 8 {
		ret := intrinsics.syscall(
			linux.SYS_fanotify_mark,
			uintptr(fan),
			uintptr(flags),
			uintptr(MASK),
			transmute(uintptr)int(linux.AT_FDCWD),
			uintptr(rawptr(path)),
		)
	} else {
		ret := intrinsics.syscall(
			linux.SYS_fanotify_mark,
			uintptr(fan),
			uintptr(flags),
			uintptr(MASK & 0xffff_ffff),
			uintptr(MASK >> 32),
			transmute(uintptr)int(linux.AT_FDCWD),
			uintptr(rawptr(path)),
		)
	}
	if int(ret) < 0 {
		return linux.Errno(-int(ret))
	}
	return .NONE
}

// mark_problem says why a filesystem could not be marked, for the status.
@(private = "file")
mark_problem :: proc(m: Mount, errno: linux.Errno) -> string {
	#partial switch errno {
	case .EXDEV:
		if m.fstype == "btrfs" {
			return "a btrfs subvolume, which fanotify cannot mark whole (EXDEV); not recorded yet"
		}
		return "fanotify cannot mark it whole (EXDEV)"
	case .ENODEV, .EOPNOTSUPP:
		return "it cannot say which folder changed"
	}
	return fmt.tprintf("fanotify_mark: %v", errno)
}

@(private = "file")
skip :: proc(r: ^Recorder, m: Mount, why: string) {
	if m.device in r.judged {
		return
	}
	r.judged[strings.clone(m.device)] = {}
	append(
		&r.skipped,
		Skipped_Filesystem {
			point = strings.clone(m.point),
			fstype = strings.clone(m.fstype),
			why = strings.clone(why),
		},
	)
}

/*
start_recording opens the log of the filesystem mounted at m, marked already, and
appends a Start with a new generation. A log whose paths were spelt from another
mount point is begun again: its hashes would not match this one's.
*/
@(private = "file")
start_recording :: proc(r: ^Recorder, m: Mount) -> (fs: Recorded_Filesystem, problem: string) {
	dir, err := linux.open(
		strings.clone_to_cstring(m.point, context.temp_allocator),
		{.DIRECTORY, .CLOEXEC},
	)
	if err != .NONE {
		return {}, fmt.tprintf("cannot open it: %v", err)
	}
	st: linux.Stat_FS
	if e := linux.fstatfs(dir, &st); e != .NONE {
		linux.close(dir)
		return {}, fmt.tprintf("statfs: %v", e)
	}
	fs = Recorded_Filesystem {
		mount_id = m.id,
		device   = strings.clone(m.device),
		point    = strings.clone(m.point),
		fstype   = strings.clone(m.fstype),
		fsid     = st.fsid,
		dir      = dir,
	}
	fs.path, _ = filepath.join({r.cfg.logs, log_name(st.fsid)})
	if !ensure_header(&fs) {
		forget(&fs)
		return {}, "its log cannot be written"
	}
	compact_log(&fs)
	if fs.log == nil {
		forget(&fs)
		return {}, "its log cannot be written"
	}
	gen: [8]byte
	linux.getrandom(gen[:], {})
	append_record(&fs, {.Start, time.to_unix_nanoseconds(time.now()), transmute(u64)gen})
	write_log(&fs)
	return fs, ""
}

/*
ensure_header makes sure fs's log begins with a header for its mount point: written
anew when there is none, or when it names another.
*/
@(private = "file")
ensure_header :: proc(fs: ^Recorded_Filesystem) -> bool {
	head: [len(MAGIC) + 2 + PATH_MAX]byte
	n := 0
	if f, err := os.open(fs.path); err == nil {
		n, _ = os.read_at(f, head[:], 0)
		os.close(f)
	}
	if mount, _, ok := header_read(head[:max(n, 0)]); ok && mount == fs.point {
		return true
	}
	return(
		os.write_entire_file(
			fs.path,
			header_make(fs.point, context.temp_allocator),
			Permissions_Log,
		) ==
		nil \
	)
}

// compact_log drops fs's records older than RETENTION, then opens its log to append.
@(private = "file")
compact_log :: proc(fs: ^Recorded_Filesystem) {
	if fs.log != nil {
		os.close(fs.log)
		fs.log = nil
	}
	before := time.to_unix_nanoseconds(time.now()) - i64(RETENTION)
	compact(fs.path, before)
	fs.log, _ = os.open(fs.path, {.Write, .Append}, Permissions_Log)
}

// stop_recording appends a Stop to fs's log: what happens next is not seen.
@(private = "file")
stop_recording :: proc(fs: ^Recorded_Filesystem) {
	append_record(fs, {.Stop, time.to_unix_nanoseconds(time.now()), 0})
	write_log(fs)
}

// STATUS is the file in the log folder that says what is recorded and what not.
STATUS :: "status"

/*
write_status writes which filesystems are recorded, and which are not and why, to
STATUS in the log folder: a line each, tab-separated, "recorded", the mount point,
the type and the log's name, or "skipped", the mount point, the type and why.
*/
@(private = "file")
write_status :: proc(r: ^Recorder) {
	b := strings.builder_make(context.temp_allocator)
	for fs in r.recorded {
		fmt.sbprintf(&b, "recorded\t%s\t%s\t%s\n", fs.point, fs.fstype, filepath.base(fs.path))
	}
	for s in r.skipped {
		fmt.sbprintf(&b, "skipped\t%s\t%s\t%s\n", s.point, s.fstype, s.why)
	}
	path, _ := filepath.join({r.cfg.logs, STATUS}, context.temp_allocator)
	fresh := fmt.tprintf("%s.new", path)
	if os.write_entire_file(fresh, strings.to_string(b), Permissions_Log) == nil {
		os.rename(fresh, path)
	}
}
