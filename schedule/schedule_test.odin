package leita_schedule

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "core:unicode/utf16"

// A test's system: folders of its own under a temporary directory, and a
// runner that records each command rather than running it, answering as told.
@(private = "file")
Fake :: struct {
	dir:      string,
	commands: [dynamic]string,
	// What a schtasks /Create was given to read, as it read it.
	task:     string,
	// Whether a schtasks /Query finds the task, as Task Scheduler would.
	has_task: bool,
	linger:   string, // what loginctl says of lingering
	refuse:   string, // a command that starts with this fails
}

@(private = "file")
fake_run :: proc(argv: []string, user: rawptr) -> Outcome {
	f := (^Fake)(user)
	line := strings.join(argv, " ", context.temp_allocator)
	append(&f.commands, line)
	if f.refuse != "" && strings.has_prefix(line, f.refuse) {
		return {err = "refused"}
	}
	switch {
	case strings.has_prefix(line, "loginctl show-user"):
		return {ok = true, out = f.linger}
	case strings.has_prefix(line, "schtasks /Create"):
		data, _ := os.read_entire_file(argv[3], context.temp_allocator)
		f.task = from_utf16(data)
		f.has_task = true
	case strings.has_prefix(line, "schtasks /Query"):
		return {ok = f.has_task}
	case strings.has_prefix(line, "schtasks /Delete"):
		f.has_task = false
	}
	return {ok = true}
}

@(private = "file")
from_utf16 :: proc(data: []byte) -> string {
	if len(data) < 2 || data[0] != 0xff || data[1] != 0xfe {
		return ""
	}
	units := make([]u16, (len(data) - 2) / 2, context.temp_allocator)
	for &u, i in units {
		u = u16(data[2 + 2 * i]) | u16(data[3 + 2 * i]) << 8
	}
	out := make([]byte, 4 * len(units), context.temp_allocator)
	n := utf16.decode_to_utf8(out, units)
	return string(out[:n])
}

@(private = "file")
fake_host :: proc(t: ^testing.T, f: ^Fake, system: System) -> Host {
	dir, err := os.make_directory_temp("", "leita-schedule-*", context.temp_allocator)
	testing.expect(t, err == nil)
	f.dir = dir
	f.commands = make([dynamic]string, context.temp_allocator)
	h := Host {
		run    = fake_run,
		user   = f,
		system = system,
		uid    = "501",
		login  = "ann",
	}
	h.units, _ = filepath.join({dir, "config", "systemd", "user"}, context.temp_allocator)
	h.agents, _ = filepath.join({dir, "Library", "LaunchAgents"}, context.temp_allocator)
	h.temp = dir
	return h
}

@(private = "file")
ARGV :: []string{"/opt/leita dev/bin/leita", "monitor", "run"}

@(test)
a_systemd_timer_runs_the_monitor_hourly_and_catches_up :: proc(t: ^testing.T) {
	f: Fake
	h := fake_host(t, &f, .Systemd)
	defer os.remove_all(f.dir)
	f.linger = "Linger=no\n"

	testing.expect(t, !installed(h))
	problem, logged_in_only := install(h, ARGV)
	testing.expect_value(t, problem, "")
	testing.expect(t, logged_in_only, "ann does not linger")
	testing.expect(t, installed(h))

	service_path, timer_path := unit_paths(h)
	service, _ := os.read_entire_file(service_path, context.temp_allocator)
	testing.expect_value(
		t,
		string(service),
		"[Unit]\nDescription=leita: scan the watched places\n\n" +
		"[Service]\nType=oneshot\nExecStart=\"/opt/leita dev/bin/leita\" monitor run\n" +
		"Nice=10\nIOSchedulingClass=idle\n",
	)
	timer, _ := os.read_entire_file(timer_path, context.temp_allocator)
	testing.expect_value(
		t,
		string(timer),
		"[Unit]\nDescription=leita: scan the watched places when due\n\n" +
		"[Timer]\nOnCalendar=hourly\nPersistent=true\nRandomizedDelaySec=5min\n\n" +
		"[Install]\nWantedBy=timers.target\n",
	)
	testing.expect_value(t, len(f.commands), 3)
	testing.expect_value(t, f.commands[0], "systemctl --user daemon-reload")
	testing.expect_value(t, f.commands[1], "systemctl --user enable --now leita-monitor.timer")
	testing.expect_value(t, f.commands[2], "loginctl show-user ann -p Linger")

	clear(&f.commands)
	testing.expect_value(t, remove(h), "")
	testing.expect(t, !installed(h))
	testing.expect_value(t, f.commands[0], "systemctl --user disable --now leita-monitor.timer")
	testing.expect_value(t, remove(h), "") // what is gone is removed
}

@(test)
a_timer_systemd_refuses_is_not_left_behind :: proc(t: ^testing.T) {
	f: Fake
	h := fake_host(t, &f, .Systemd)
	defer os.remove_all(f.dir)
	f.refuse = "systemctl --user enable"

	problem, _ := install(h, ARGV)
	testing.expect_value(t, problem, "refused")
	testing.expect(t, !installed(h))
	service, _ := unit_paths(h)
	testing.expect(t, !os.exists(service))
}

@(test)
a_task_repeats_hourly_catches_up_once_and_never_stacks :: proc(t: ^testing.T) {
	f: Fake
	h := fake_host(t, &f, .Task_Scheduler)
	defer os.remove_all(f.dir)

	testing.expect(t, !installed(h))
	clear(&f.commands)
	argv := []string{`C:\Program Files\leita\leita.exe`, "monitor", "run"}
	problem, _ := install(h, argv)
	testing.expect_value(t, problem, "")
	testing.expect(t, installed(h))
	testing.expect(t, !os.exists(task_path(h)), "the XML is gone once read")

	want := []string {
		`<?xml version="1.0" encoding="UTF-16"?>`,
		`<URI>\leita\monitor</URI>`,
		"<Interval>PT1H</Interval>",
		"<StartWhenAvailable>true</StartWhenAvailable>",
		"<MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>",
		"<LogonType>InteractiveToken</LogonType>",
		"<RunLevel>LeastPrivilege</RunLevel>",
		`<Command>&quot;C:\Program Files\leita\leita.exe&quot;</Command>`,
		"<Arguments>monitor run</Arguments>",
	}
	for w in want {
		testing.expectf(t, strings.contains(f.task, w), "missing %q in\n%s", w, f.task)
	}
	testing.expect(
		t,
		strings.has_prefix(f.commands[0], `schtasks /Create /XML `) &&
		strings.has_suffix(f.commands[0], `/TN leita\monitor /F`),
		f.commands[0],
	)

	testing.expect_value(t, remove(h), "")
	testing.expect(t, !installed(h))
	clear(&f.commands)
	testing.expect_value(t, remove(h), "")
	testing.expect_value(t, len(f.commands), 1)
	testing.expect_value(t, f.commands[0], `schtasks /Query /TN leita\monitor`)
}

@(test)
a_launchd_agent_runs_hourly_in_the_background :: proc(t: ^testing.T) {
	f: Fake
	h := fake_host(t, &f, .Launchd)
	defer os.remove_all(f.dir)

	problem, _ := install(h, {"/Applications/Leita.app/Contents/MacOS/Leita", "monitor", "run"})
	testing.expect_value(t, problem, "")
	testing.expect(t, installed(h))
	plist, _ := os.read_entire_file(agent_path(h), context.temp_allocator)
	want := []string {
		"<string>dev.mordaunt.leita.monitor</string>",
		"<string>/Applications/Leita.app/Contents/MacOS/Leita</string>\n\t\t<string>monitor</string>\n\t\t<string>run</string>",
		"<key>StartInterval</key>\n\t<integer>3600</integer>",
		"<key>LowPriorityIO</key>\n\t<true/>",
	}
	for w in want {
		testing.expectf(t, strings.contains(string(plist), w), "missing %q in\n%s", w, plist)
	}
	testing.expect_value(t, f.commands[0], "launchctl bootout gui/501/dev.mordaunt.leita.monitor")
	testing.expect_value(
		t,
		f.commands[1],
		strings.concatenate(
			{"launchctl bootstrap gui/501 ", agent_path(h)},
			context.temp_allocator,
		),
	)
	testing.expect_value(t, remove(h), "")
	testing.expect(t, !installed(h))
}

@(test)
a_command_line_survives_each_scheduler :: proc(t: ^testing.T) {
	testing.expect_value(t, systemd_quote("/usr/bin/leita"), "/usr/bin/leita")
	testing.expect_value(t, systemd_quote("/mnt/My Disk"), `"/mnt/My Disk"`)
	testing.expect_value(t, systemd_quote(`a"b\c`), `"a\"b\\c"`)
	testing.expect_value(t, systemd_quote("100%$HOME"), "100%%$$HOME")
	testing.expect_value(t, systemd_quote(""), `""`)

	testing.expect_value(t, windows_quote(`C:\leita\leita.exe`), `C:\leita\leita.exe`)
	testing.expect_value(t, windows_quote(`C:\Program Files\`), `"C:\Program Files\\"`)
	testing.expect_value(t, windows_quote(`say "hi"`), `"say \"hi\""`)
	testing.expect_value(t, windows_quote(""), `""`)

	testing.expect_value(t, escape_xml(`<a & 'b'>`), "&lt;a &amp; &apos;b&apos;&gt;")
}
