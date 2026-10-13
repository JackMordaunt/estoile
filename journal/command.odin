package journal

import "core:fmt"
import "core:io"
import "core:os"
import "core:strings"
import "core:terminal"

import "../term"

/*
The recorder's command line, which both binaries answer as their first argument
`journal`: leita journal ..., and Leita journal ... for the window's, so the window
can ask for it under pkexec.
*/

USAGE :: `leita journal — record which folders change, so a scan reads only those.

  leita journal on          install the recorder as a system service and start it;
                            needs root: run it under sudo
  leita journal off         stop the recorder and remove it, its service and its logs
  leita journal status      whether the recorder runs, which filesystems it records
                            and which it cannot, and how fresh each log is
  leita journal run         record changes until stopped: what the service runs

Linux keeps no record of what changed while nothing was listening, so without the
recorder a scan asks every folder when it last changed. Nothing is recorded until
leita journal on. The logs, in /var/lib/leita/journal, hold a hash of each folder
that changed and when, not its name. btrfs subvolumes are not recorded yet.
On macOS and Windows the system records changes itself, and this does nothing.
`

// The recorder's service, the copy of leita it runs, and where those live.
SERVICE     :: "leita-journal.service"
UNIT_PATH   :: "/etc/systemd/system/" + SERVICE
BINARY_DIR  :: "/usr/local/libexec/leita"
BINARY_PATH :: BINARY_DIR + "/leita"

// Exit codes: done, or not.
EXIT_OK     :: 0
EXIT_FAILED :: 1

/*
unit_text is the recorder's system service. It runs a root-owned copy of leita,
since a system service must not run a program its user can rewrite, with only the
two capabilities fanotify needs: CAP_SYS_ADMIN to mark a filesystem
(fanotify_mark(2)) and CAP_DAC_READ_SEARCH to open a directory by its handle
(open_by_handle_at(2)). The rest of the system is read-only to it but its own
folder.
*/
unit_text :: proc(allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_string(&b, "[Unit]\nDescription=leita: record which folders change\n\n")
	strings.write_string(&b, "[Service]\nType=simple\n")
	fmt.sbprintf(&b, "ExecStart=%s journal run\n", BINARY_PATH)
	strings.write_string(&b, "Restart=on-failure\n")
	strings.write_string(&b, "CapabilityBoundingSet=CAP_SYS_ADMIN CAP_DAC_READ_SEARCH\n")
	strings.write_string(&b, "AmbientCapabilities=CAP_SYS_ADMIN CAP_DAC_READ_SEARCH\n")
	strings.write_string(&b, "NoNewPrivileges=yes\nProtectSystem=strict\n")
	fmt.sbprintf(&b, "ReadWritePaths=%s\n", STATE_DIR)
	strings.write_string(
		&b,
		"# Not ProtectHome: the recorder opens the folders that change to name them,\n" +
		"# and most of them are under /home.\n",
	)
	strings.write_string(&b, "\n[Install]\nWantedBy=multi-user.target\n")
	return strings.to_string(b)
}

/*
run_command_line runs the recorder's command line on this machine, as either binary
does when its first argument is journal. It says how it went on standard output and
returns the exit code.
*/
run_command_line :: proc(args: []string) -> int {
	mode, _ := term.parse_mode(os.get_env("LEITA_COLOR", context.temp_allocator))
	style := term.detect(terminal.is_terminal(os.stdout), mode)
	return dispatch(style, args, os.to_writer(os.stdout))
}

// print_usage writes USAGE on w: plain, byte for byte; for a person, with weight.
@(private)
print_usage :: proc(style: term.Style, w: io.Writer) {
	b := strings.builder_make(context.temp_allocator)
	term.write_usage(&b, style, "leita journal", USAGE)
	fmt.wprint(w, strings.to_string(b))
}

// errorf says what went wrong on w, the prefix in bold for a person.
@(private)
errorf :: proc(style: term.Style, w: io.Writer, format: string, args: ..any) {
	fmt.wprintfln(w, "%s %s", term.painted(style, {.Bold}, "error:"), fmt.tprintf(format, ..args))
}
