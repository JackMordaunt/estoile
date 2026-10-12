package leita_monitor

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:testing"
import "core:time"

import "../history"
import "../schedule"
import "../settings"

// A test's machine: a data folder of its own, a place to watch in it, and a
// scheduler that records what it is asked rather than doing it.
@(private = "file")
Bench :: struct {
	dir:      string,
	place:    string,
	c:        Context,
	commands: [dynamic]string,
	out:      strings.Builder,
}

@(private = "file")
join :: proc(parts: ..string) -> string {
	path, _ := filepath.join(parts, context.temp_allocator)
	return path
}

@(private = "file")
record_command :: proc(argv: []string, user: rawptr) -> schedule.Outcome {
	b := (^Bench)(user)
	append(&b.commands, strings.join(argv, " ", context.temp_allocator))
	return {ok = true}
}

@(private = "file")
bench_open :: proc(t: ^testing.T, b: ^Bench) {
	dir, err := os.make_directory_temp("", "leita-monitor-*", context.temp_allocator)
	testing.expect(t, err == nil)
	b.dir = dir
	b.place = join(dir, "watched")
	testing.expect(t, os.make_directory_all(join(b.place, "photos")) == nil)
	body := make([]byte, 2 << 20, context.temp_allocator)
	slice.fill(body, 'x')
	testing.expect(t, os.write_entire_file(join(b.place, "photos", "big.raw"), body) == nil)
	kept := join(dir, "data", "history.db")
	b.commands = make([dynamic]string, context.temp_allocator)
	b.out = strings.builder_make(context.temp_allocator)
	host := schedule.Host {
		run    = record_command,
		user   = b,
		system = .Systemd,
	}
	host.units = join(dir, "units")
	b.c = Context {
		paths    = paths_beside(kept, context.temp_allocator),
		host     = host,
		argv     = slice.clone(
			[]string{"/usr/bin/leita", "monitor", "run"},
			context.temp_allocator,
		),
		unlocked = true,
		now      = time.unix(1_800_000_000, 0),
	}
}

// run_monitor runs the monitor command args, and returns its exit code and
// what it said.
@(private = "file")
run_monitor :: proc(b: ^Bench, args: ..string) -> (int, string) {
	strings.builder_reset(&b.out)
	code := dispatch(b.c, args, strings.to_writer(&b.out))
	return code, strings.clone(strings.to_string(b.out), context.temp_allocator)
}

@(private = "file")
snapshot_count :: proc(t: ^testing.T, b: ^Bench) -> int {
	hs: history.Store
	testing.expect(t, history.open(&hs, b.c.paths.history) == nil)
	defer history.close(&hs)
	place := place_of(b.place)
	when ODIN_OS == .Darwin {
		// macOS's temp folder is under /var, a link to /private/var, which a
		// scan resolves (scratch in gui/app/app_test.odin meets the same).
		info, _ := os.stat(place, context.temp_allocator)
		place = info.fullpath
	}
	snaps, _ := history.list(&hs, place)
	return len(snaps)
}

@(test)
a_place_is_due_once_its_period_is_nearly_up :: proc(t: ^testing.T) {
	hour :: 60 * 60
	testing.expect(t, due(.Weekly, 0, 1000), "never scanned is due")
	testing.expect(t, due(.Hourly, 10 * hour, 11 * hour - 4 * 60), "a run five minutes early")
	testing.expect(t, !due(.Hourly, 10 * hour, 10 * hour + 30 * 60))
	testing.expect(t, !due(.Daily, 0 + 1, 20 * hour))
	testing.expect(t, due(.Daily, 1, 24 * hour - 5 * 60))
	testing.expect(t, !due(.Weekly, 1, 6 * 24 * hour))
	testing.expect(t, due(.Weekly, 1, 7 * 24 * hour))
}

@(test)
a_place_is_added_listed_and_removed :: proc(t: ^testing.T) {
	b: Bench
	bench_open(t, &b)
	defer os.remove_all(b.dir)

	code, out := run_monitor(&b, "add", b.place, "--every", "hourly")
	testing.expect_value(t, code, 0)
	testing.expect(t, strings.contains(out, "watching "), out)
	testing.expect(t, strings.contains(out, "monitoring is off"), out)

	code, out = run_monitor(&b, "list")
	testing.expect_value(t, code, 0)
	testing.expect(t, strings.contains(out, "hourly\n  not scanned yet"), out)

	code, out = run_monitor(&b, "add", b.place, "--every", "fortnightly")
	testing.expect_value(t, code, EXIT_FAILED)
	code, out = run_monitor(&b, "add", join(b.dir, "missing"))
	testing.expect_value(t, code, EXIT_FAILED)
	testing.expect(t, strings.contains(out, "is not there"), out)

	code, out = run_monitor(&b, "remove", b.place)
	testing.expect_value(t, code, 0)
	code, out = run_monitor(&b, "remove", b.place)
	testing.expect_value(t, code, EXIT_FAILED)
	testing.expect(t, strings.contains(out, "is not watched"), out)
}

@(test)
on_hands_the_monitor_to_the_scheduler_and_off_takes_it_back :: proc(t: ^testing.T) {
	b: Bench
	bench_open(t, &b)
	defer os.remove_all(b.dir)

	code, out := run_monitor(&b, "on")
	testing.expect_value(t, code, 0)
	testing.expect(t, strings.contains(out, "monitoring is on"), out)
	testing.expect(t, schedule.installed(b.c.host))
	service, _ := os.read_entire_file(
		join(b.c.host.units, "leita-monitor.service"),
		context.temp_allocator,
	)
	testing.expect(t, strings.contains(string(service), "ExecStart=/usr/bin/leita monitor run\n"))
	_, out = run_monitor(&b, "list")
	testing.expect(t, strings.has_prefix(out, "monitoring is on"), out)

	code, out = run_monitor(&b, "off")
	testing.expect_value(t, code, 0)
	testing.expect(t, !schedule.installed(b.c.host))
	_, out = run_monitor(&b, "list")
	testing.expect(t, strings.has_prefix(out, "monitoring is off"), out)
}

@(test)
a_run_scans_what_is_due_and_keeps_it_in_history :: proc(t: ^testing.T) {
	b: Bench
	bench_open(t, &b)
	defer os.remove_all(b.dir)
	_, _ = run_monitor(&b, "add", b.place, "--every", "daily")

	code, out := run_monitor(&b, "run")
	testing.expect_value(t, code, 0)
	testing.expect(t, strings.contains(out, "monitoring is off"), out)
	testing.expect_value(t, snapshot_count(t, &b), 0)

	_, _ = run_monitor(&b, "on")
	code, out = run_monitor(&b, "run")
	testing.expect_value(t, code, 0)
	testing.expect(t, strings.contains(out, "2.0 MiB"), out)
	testing.expect_value(t, snapshot_count(t, &b), 1)

	// Not due again within the day, unless every place is asked for.
	b.c.now = time.time_add(b.c.now, 3 * time.Hour)
	_, out = run_monitor(&b, "run")
	testing.expect_value(t, out, "")
	testing.expect_value(t, snapshot_count(t, &b), 1)
	_, out = run_monitor(&b, "run", "--all")
	testing.expectf(t, snapshot_count(t, &b) == 2, "after --all: %s", out)
	b.c.now = time.time_add(b.c.now, 24 * time.Hour)
	_, out = run_monitor(&b, "run")
	testing.expectf(t, snapshot_count(t, &b) == 3, "a day later: %s", out)

	st: settings.Store
	testing.expect(t, settings.open(&st, b.c.paths.settings) == nil)
	defer settings.close(&st)
	runs, _ := settings.runs(&st, place_of(b.place), allocator = context.temp_allocator)
	testing.expect_value(t, len(runs), 3)
	testing.expect(t, runs[0].bytes >= 2 << 20)
	testing.expect_value(t, runs[0].problem, "")
	_, out = run_monitor(&b, "list")
	testing.expect(t, strings.contains(out, "2.0 MiB"), out)

	// The first run read the place whole and kept it as the baseline the next
	// update from; stopping watching it deletes the baseline, not the history.
	testing.expect(t, !runs[2].updated)
	baseline := history.baseline_path(b.c.paths.history, place_of(b.place), context.temp_allocator)
	testing.expect(t, os.exists(baseline), "the baseline is kept")
	code, _ = run_monitor(&b, "remove", b.place)
	testing.expect_value(t, code, 0)
	testing.expect(t, !os.exists(baseline), "and goes with the place")
	testing.expect_value(t, snapshot_count(t, &b), 3)
}

@(test)
a_place_that_cannot_be_scanned_fails_the_run_and_says_why :: proc(t: ^testing.T) {
	b: Bench
	bench_open(t, &b)
	defer os.remove_all(b.dir)
	_, _ = run_monitor(&b, "add", b.place)
	_, _ = run_monitor(&b, "on")
	testing.expect(t, os.remove_all(b.place) == nil)

	code, out := run_monitor(&b, "run")
	testing.expect_value(t, code, EXIT_FAILED)
	testing.expect(t, strings.contains(out, "failed: cannot scan"), out)
	_, out = run_monitor(&b, "list")
	testing.expect(t, strings.contains(out, "failed: cannot scan"), out)
}

@(test)
monitoring_is_refused_once_the_trial_is_over_but_can_still_be_turned_off :: proc(t: ^testing.T) {
	b: Bench
	bench_open(t, &b)
	defer os.remove_all(b.dir)
	b.c.unlocked = false
	for args in ([][]string{{"run"}, {"add", b.place}, {"on"}}) {
		code, out := run_monitor(&b, ..args)
		testing.expect_value(t, code, EXIT_FAILED)
		testing.expect(t, strings.contains(out, "needs a licence"), out)
	}
	code, _ := run_monitor(&b, "off")
	testing.expect_value(t, code, 0)
	code, _ = run_monitor(&b, "list")
	testing.expect_value(t, code, 0)
}

@(test)
a_run_holds_a_lock_another_run_stands_aside_for :: proc(t: ^testing.T) {
	dir, err := os.make_directory_temp("", "leita-lock-*", context.temp_allocator)
	testing.expect(t, err == nil)
	defer os.remove_all(dir)
	path := fmt.tprintf("%s/%s", dir, LOCK_FILE)

	l, taken := lock(path)
	testing.expect_value(t, taken, Lock_Result.Taken)
	unlock(&l)
	l, taken = lock(path)
	testing.expect_value(t, taken, Lock_Result.Taken)
	// A second open of the file is refused while the first holds it.
	_, again := lock(path)
	testing.expect_value(t, again, Lock_Result.Held)
	unlock(&l)
	l, taken = lock(path)
	testing.expect_value(t, taken, Lock_Result.Taken)
	unlock(&l)
	_, taken = lock(fmt.tprintf("%s/missing/%s", dir, LOCK_FILE))
	testing.expect_value(t, taken, Lock_Result.Failed)
}
