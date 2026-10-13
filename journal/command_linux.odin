#+build linux
package journal

import "core:c/libc"
import "core:fmt"
import "core:io"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:sys/linux"
import "core:time"

import "jm:sh"

import "../human"
import "../term"

// NEEDS_ROOT says how to turn the recorder on without root.
NEEDS_ROOT ::
	"the recorder is a system service, so this needs root: run sudo leita journal on, " +
	"or turn on Record changes in Leita's Monitoring"

// dispatch carries out the journal command args names, saying how it went on w.
@(private)
dispatch :: proc(style: term.Style, args: []string, w: io.Writer) -> int {
	verb := args[0] if len(args) > 0 else "status"
	switch verb {
	case "on":
		if linux.geteuid() != 0 {
			errorf(style, w, NEEDS_ROOT)
			return EXIT_FAILED
		}
		if problem := switch_on(); problem != "" {
			errorf(style, w, "%s", problem)
			return EXIT_FAILED
		}
		fmt.wprintfln(w, "recording changes: %s runs %s journal run", SERVICE, BINARY_PATH)
		return EXIT_OK
	case "off":
		if linux.geteuid() != 0 {
			errorf(
				style,
				w,
				"the recorder is a system service, so this needs root: run sudo leita journal off",
			)
			return EXIT_FAILED
		}
		if problem := switch_off(); problem != "" {
			errorf(style, w, "%s", problem)
			return EXIT_FAILED
		}
		fmt.wprintln(
			w,
			"not recording changes: the recorder, its service and its logs are removed",
		)
		return EXIT_OK
	case "status":
		say_status(style, w)
		return EXIT_OK
	case "run":
		return run_until_signalled(style, w)
	case "-h", "--help", "help":
		print_usage(style, w)
		return EXIT_OK
	}
	errorf(style, w, "no journal command %q", verb)
	fmt.wprintln(w)
	print_usage(style, w)
	return EXIT_FAILED
}

// stopping is set by SIGTERM or SIGINT, for the recorder to stop at.
@(private = "file")
stopping: bool

@(private = "file")
on_signal :: proc "c" (_: libc.int) {
	sync.atomic_store(&stopping, true)
}

// run_until_signalled records into DIR until the service is stopped.
@(private = "file")
run_until_signalled :: proc(style: term.Style, w: io.Writer) -> int {
	libc.signal(libc.SIGTERM, on_signal)
	libc.signal(libc.SIGINT, on_signal)
	if problem := run({logs = DIR, stop = &stopping}); problem != "" {
		errorf(style, w, "%s", problem)
		return EXIT_FAILED
	}
	return EXIT_OK
}

/*
switch_on copies this binary to BINARY_PATH, root's and not writable by anyone
else, writes the service that runs it and starts it, restarting one already
running so a newer copy takes over. It says why it could not, or "".
*/
@(private = "file")
switch_on :: proc() -> string {
	exe, exe_err := os.get_executable_path(context.temp_allocator)
	if exe_err != nil {
		return fmt.tprintf("cannot find this program: %v", exe_err)
	}
	dir_perm := os.Permissions_Read_All + os.Permissions_Execute_All + {.Write_User}
	for d in ([]string{BINARY_DIR, DIR}) {
		if err := os.make_directory_all(d, dir_perm); err != nil && err != .Exist {
			return fmt.tprintf("cannot make %s: %v", d, err)
		}
	}
	if exe != BINARY_PATH {
		fresh := BINARY_PATH + ".new"
		if err := os.copy_file(fresh, exe); err != nil {
			return fmt.tprintf("cannot copy %s to %s: %v", exe, fresh, err)
		}
		if err := os.change_mode(fresh, dir_perm); err != nil {
			os.remove(fresh)
			return fmt.tprintf("cannot make %s executable: %v", fresh, err)
		}
		if err := os.rename(fresh, BINARY_PATH); err != nil {
			os.remove(fresh)
			return fmt.tprintf("cannot put %s in place: %v", BINARY_PATH, err)
		}
	}
	if err := os.write_entire_file(UNIT_PATH, unit_text(), Permissions_Log); err != nil {
		return fmt.tprintf("cannot write %s: %v", UNIT_PATH, err)
	}
	steps := [][]string {
		{"systemctl", "daemon-reload"},
		{"systemctl", "enable", SERVICE},
		{"systemctl", "restart", SERVICE},
	}
	for step in steps {
		if r := sh.exec(step, {}, context.temp_allocator); !r.ok {
			return sh.error(r, context.temp_allocator)
		}
	}
	return ""
}

/*
switch_off stops the service and removes everything switch_on made: the service,
the copy of leita, and the logs, which a recorder started again would not trust.
*/
@(private = "file")
switch_off :: proc() -> string {
	if os.exists(UNIT_PATH) {
		sh.exec({"systemctl", "disable", "--now", SERVICE}, {}, context.temp_allocator)
		if err := os.remove(UNIT_PATH); err != nil && err != .Not_Exist {
			return fmt.tprintf("cannot delete %s: %v", UNIT_PATH, err)
		}
		sh.exec({"systemctl", "daemon-reload"}, {}, context.temp_allocator)
		sh.exec({"systemctl", "reset-failed", SERVICE}, {}, context.temp_allocator)
	}
	for path in ([]string{BINARY_PATH, BINARY_DIR}) {
		if err := os.remove(path); err != nil && err != .Not_Exist {
			return fmt.tprintf("cannot delete %s: %v", path, err)
		}
	}
	if err := os.remove_all(DIR); err != nil && err != .Not_Exist {
		return fmt.tprintf("cannot delete %s: %v", DIR, err)
	}
	// The folder above the logs is leita's own, and goes too once empty.
	os.remove(STATE_DIR)
	return ""
}

// installed is whether the recorder's service is written.
installed :: proc() -> bool {
	return os.exists(UNIT_PATH)
}

// active is whether systemd says the recorder's service is running.
active :: proc() -> bool {
	r := sh.exec({"systemctl", "is-active", SERVICE}, {}, context.temp_allocator)
	return r.ok && strings.trim_space(r.stdout) == "active"
}

/*
say_status says whether the recorder is installed and running, which filesystems
it records, with each log's size and how long ago it last wrote, and which it
cannot record and why, from the status it writes beside its logs.
*/
@(private = "file")
say_status :: proc(style: term.Style, w: io.Writer) {
	switch {
	case !installed():
		fmt.wprintln(w, "not recording changes; sudo leita journal on starts the recorder")
	case active():
		fmt.wprintfln(w, "recording changes, through %s", SERVICE)
	case:
		fmt.wprintfln(
			w,
			"%s is installed but not running: systemctl status %s says why",
			SERVICE,
			SERVICE,
		)
	}
	status_path, _ := filepath.join({DIR, STATUS}, context.temp_allocator)
	data, err := os.read_entire_file(status_path, context.temp_allocator)
	if err != nil {
		return
	}
	text := string(data)
	now := time.to_unix_nanoseconds(time.now())
	for line in strings.split_lines_iterator(&text) {
		f := strings.split(line, "\t", context.temp_allocator)
		if len(f) < 4 {
			continue
		}
		switch f[0] {
		case "recorded":
			log, _ := filepath.join({DIR, f[3]}, context.temp_allocator)
			size, last, ok := log_tail(log)
			age := "nothing yet"
			if ok {
				age = fmt.tprintf("last written %ds ago", (now - last.time) / i64(time.Second))
			}
			fmt.wprintfln(
				w,
				"  %s  %s, %s, log %s, %s",
				term.painted(style, {.Bold}, f[1]),
				f[2],
				"recorded",
				human.bytes(u64(size)),
				age,
			)
		case "skipped":
			fmt.wprintfln(
				w,
				"  %s  %s, not recorded: %s",
				term.painted(style, {.Bold}, f[1]),
				f[2],
				f[3],
			)
		}
	}
}

// log_tail is the size of the log at path and its last whole record.
@(private = "file")
log_tail :: proc(path: string) -> (size: i64, last: Record, ok: bool) {
	f, err := os.open(path)
	if err != nil {
		return 0, {}, false
	}
	defer os.close(f)
	size, _ = os.file_size(f)
	head: [len(MAGIC) + 2 + PATH_MAX]byte
	n, _ := os.read_at(f, head[:], 0)
	_, at, header_ok := header_read(head[:max(n, 0)])
	count := (size - i64(at)) / RECORD_SIZE
	if !header_ok || count <= 0 {
		return size, {}, false
	}
	buf: [RECORD_SIZE]byte
	if !read_full(f, buf[:], i64(at) + (count - 1) * RECORD_SIZE) {
		return size, {}, false
	}
	return size, record_get(buf[:]), true
}
