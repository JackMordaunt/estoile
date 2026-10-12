package leita_monitor

import "core:flags"
import "core:fmt"
import "core:io"
import "core:os"
import "core:strings"
import "core:time"

import "jm:timefmt"

import "../history"
import "../human"
import "../licence"
import "../schedule"
import "../settings"

/*
The monitor's command line, which both binaries answer as their first argument
`monitor`: leita monitor ..., and Leita monitor ... for the window's, so the
scheduler's entry runs whichever binary turned monitoring on.
*/

USAGE :: `Usage: leita monitor [command]

Monitoring scans the places you watch on a schedule, gently, while leita is
closed, and keeps each scan so change tracking has a steady record. It runs
only while turned on, through the system's scheduler; nothing stays running.

  run [--all]        scan each watched place that is due, then exit; what the
                     scheduler runs every hour, and the default command
  list               whether monitoring is on, and each place's last run
  add PATH [--every hourly|daily|weekly]
                     watch PATH, daily unless --every says
  remove PATH        stop watching PATH
  on                 turn monitoring on: hand it to the system's scheduler
  off                turn monitoring off: remove it from the scheduler
`

// Context is what the command line works with: where its files are, the
// scheduler, the command the scheduler is to run, and whether the paid
// features are unlocked.
Context :: struct {
	paths:    Paths,
	host:     schedule.Host,
	argv:     []string, // what the scheduler runs: this binary, monitor, run
	unlocked: bool,
	now:      time.Time,
}

// LOCKED says why a paid command was refused.
LOCKED :: "error: monitoring needs a licence now the 30-day trial has ended; add one in Leita, the window, under the key in its toolbar"

// dispatch carries out the monitor command args names, saying how it went on w,
// and returns the exit code.
dispatch :: proc(c: Context, args: []string, w: io.Writer) -> int {
	verb := args[0] if len(args) > 0 else "run"
	rest := args[1:] if len(args) > 0 else nil
	switch verb {
	case "run":
		Run_Flags :: struct {
			all: bool `usage:"Scan every watched place, due or not."`,
		}
		f: Run_Flags
		if code, ok := parse(&f, rest); !ok {
			return code
		}
		if !c.unlocked {
			fmt.wprintln(w, LOCKED)
			return EXIT_FAILED
		}
		return run({paths = c.paths, now = c.now, all = f.all}, w)
	case "list":
		return list(c, w)
	case "add":
		Add_Flags :: struct {
			path:  string `args:"pos=0,required" usage:"The directory or drive to watch."`,
			every: string `usage:"How often to scan it: hourly, daily or weekly."`,
		}
		f := Add_Flags {
			every = "daily",
		}
		if code, ok := parse(&f, rest); !ok {
			return code
		}
		if !c.unlocked {
			fmt.wprintln(w, LOCKED)
			return EXIT_FAILED
		}
		every, ok := settings.frequency_named(f.every)
		if !ok {
			fmt.wprintfln(w, "error: --every is hourly, daily or weekly, not %q", f.every)
			return EXIT_FAILED
		}
		return add(c, f.path, every, w)
	case "remove":
		Remove_Flags :: struct {
			path: string `args:"pos=0,required" usage:"The place to stop watching."`,
		}
		f: Remove_Flags
		if code, ok := parse(&f, rest); !ok {
			return code
		}
		return remove(c, f.path, w)
	case "on":
		if !c.unlocked {
			fmt.wprintln(w, LOCKED)
			return EXIT_FAILED
		}
		return switch_on(c, w)
	case "off":
		return switch_off(c, w)
	case "-h", "--help", "help":
		fmt.wprint(w, USAGE)
		return 0
	}
	fmt.wprintf(w, "error: no monitor command %q\n\n%s", verb, USAGE)
	return EXIT_FAILED
}

// parse reads args into f, saying what is wrong; it fails with the exit code to
// return, 0 for a request for help.
@(private)
parse :: proc(f: ^$T, args: []string) -> (code: int, ok: bool) {
	err := flags.parse(f, args, .Unix)
	if err == nil {
		return 0, true
	}
	flags.print_errors(T, err, "leita monitor", .Unix)
	_, help := err.(flags.Help_Request)
	return 0 if help else EXIT_FAILED, false
}

// open_settings opens the settings store, saying why not on w.
@(private)
open_settings :: proc(c: Context, st: ^settings.Store, w: io.Writer) -> bool {
	if err := settings.open(st, c.paths.settings); err != nil {
		fmt.wprintfln(w, "error: cannot open %s: %s", c.paths.settings, history.describe(err))
		return false
	}
	return true
}

// place_of is path as a place is watched: absolute, in the temp allocator.
place_of :: proc(path: string) -> string {
	abs, err := os.get_absolute_path(path, context.temp_allocator)
	if err != nil {
		return path
	}
	if len(abs) > 1 {
		abs = strings.trim_right(abs, `/\`)
		if len(abs) == 2 && abs[1] == ':' {
			abs = strings.concatenate({abs, `\`}, context.temp_allocator)
		}
	}
	return abs
}

@(private)
add :: proc(c: Context, path: string, every: settings.Frequency, w: io.Writer) -> int {
	st: settings.Store
	if !open_settings(c, &st, w) {
		return EXIT_FAILED
	}
	defer settings.close(&st)
	place := place_of(path)
	if !os.exists(place) {
		fmt.wprintfln(w, "error: %s is not there", place)
		return EXIT_FAILED
	}
	if err := settings.watch(
		&st,
		{place = place, every = every, added = time.to_unix_seconds(c.now)},
	); err != nil {
		fmt.wprintfln(w, "error: cannot watch %s: %s", place, history.describe(err))
		return EXIT_FAILED
	}
	fmt.wprintfln(w, "watching %s, %s", place, settings.FREQUENCY_NAMES[every])
	if !settings.monitoring(&st) {
		fmt.wprintln(w, "note: monitoring is off; leita monitor on turns it on")
	}
	return 0
}

@(private)
remove :: proc(c: Context, path: string, w: io.Writer) -> int {
	st: settings.Store
	if !open_settings(c, &st, w) {
		return EXIT_FAILED
	}
	defer settings.close(&st)
	// The place as given first, so one no longer there can still be removed.
	for place in ([]string{path, place_of(path)}) {
		found, err := settings.unwatch(&st, place)
		if err != nil {
			fmt.wprintfln(w, "error: cannot stop watching %s: %s", place, history.describe(err))
			return EXIT_FAILED
		}
		if found {
			fmt.wprintfln(w, "no longer watching %s", place)
			return 0
		}
	}
	fmt.wprintfln(w, "error: %s is not watched", path)
	return EXIT_FAILED
}

// switch_on hands the monitor to the scheduler, then turns monitoring on.
switch_on :: proc(c: Context, w: io.Writer) -> int {
	st: settings.Store
	if !open_settings(c, &st, w) {
		return EXIT_FAILED
	}
	defer settings.close(&st)
	problem, logged_in_only := schedule.install(c.host, c.argv)
	if problem != "" {
		fmt.wprintfln(w, "error: cannot add the %s: %s", schedule.describe(c.host), problem)
		return EXIT_FAILED
	}
	if err := settings.set_monitoring(&st, true); err != nil {
		schedule.remove(c.host)
		fmt.wprintfln(w, "error: cannot turn monitoring on: %s", history.describe(err))
		return EXIT_FAILED
	}
	fmt.wprintfln(w, "monitoring is on: the %s runs it every hour", schedule.describe(c.host))
	if logged_in_only {
		fmt.wprintfln(
			w,
			"note: it runs only while %s is logged in; to run it always: loginctl enable-linger %s",
			c.host.login,
			c.host.login,
		)
	}
	return 0
}

// switch_off turns monitoring off, then takes the monitor out of the scheduler.
switch_off :: proc(c: Context, w: io.Writer) -> int {
	st: settings.Store
	if !open_settings(c, &st, w) {
		return EXIT_FAILED
	}
	defer settings.close(&st)
	if err := settings.set_monitoring(&st, false); err != nil {
		fmt.wprintfln(w, "error: cannot turn monitoring off: %s", history.describe(err))
		return EXIT_FAILED
	}
	if problem := schedule.remove(c.host); problem != "" {
		fmt.wprintfln(w, "error: cannot remove the %s: %s", schedule.describe(c.host), problem)
		return EXIT_FAILED
	}
	fmt.wprintln(w, "monitoring is off, and nothing is scheduled")
	return 0
}

@(private)
list :: proc(c: Context, w: io.Writer) -> int {
	st: settings.Store
	if !open_settings(c, &st, w) {
		return EXIT_FAILED
	}
	defer settings.close(&st)
	switch {
	case settings.monitoring(&st):
		fmt.wprintfln(w, "monitoring is on, through the %s", schedule.describe(c.host))
	case:
		fmt.wprintln(w, "monitoring is off")
	}
	watches, err := settings.watches(&st, context.temp_allocator)
	if err != nil {
		fmt.wprintfln(w, "error: cannot read what is watched: %s", history.describe(err))
		return EXIT_FAILED
	}
	if len(watches) == 0 {
		fmt.wprintln(w, "no place is watched; leita monitor add PATH watches one")
		return 0
	}
	for watch in watches {
		fmt.wprintfln(w, "%s  %s", watch.place, settings.FREQUENCY_NAMES[watch.every])
		last, ok := settings.last_run(&st, watch.place, context.temp_allocator)
		switch {
		case !ok:
			fmt.wprintln(w, "  not scanned yet")
		case last.problem != "":
			fmt.wprintfln(w, "  %s  failed: %s", when_(last.started), last.problem)
		case:
			fmt.wprintfln(w, "  %s  %s", when_(last.started), human.bytes(last.bytes))
		}
	}
	return 0
}

// when_ is a run's start on the local clock, in the temp allocator.
@(private)
when_ :: proc(unix: i64) -> string {
	return timefmt.local(time.unix(unix, 0), "%Y-%m-%d %H:%M", context.temp_allocator)
}

/*
run_command_line runs the monitor's command line on this machine, as either
binary does
when its first argument is monitor: the stores beside the history store, the
system's scheduler, and this binary as what the scheduler runs. It says how it
went on standard output and returns the exit code.
*/
run_command_line :: proc(args: []string) -> int {
	kept := history.default_path(context.temp_allocator)
	if kept == "" {
		fmt.eprintln("error: no folder to keep leita's data in")
		return EXIT_FAILED
	}
	exe, err := os.get_executable_path(context.temp_allocator)
	if err != nil {
		exe = os.args[0]
	}
	host := schedule.host_default(context.temp_allocator)
	paths := paths_beside(kept, context.temp_allocator)
	licensee := licence.licensee_kept(paths.licence)
	first := licence.first_use(licence.path_beside(kept, context.temp_allocator, "first-use"))
	c := Context {
		paths    = paths,
		host     = host,
		argv     = {exe, "monitor", "run"},
		unlocked = licence.unlocked(licensee != "", first),
		now      = time.now(),
	}
	return dispatch(c, args, os.to_writer(os.stdout))
}
