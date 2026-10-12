/*
Package monitor is leita's monitoring, a paid feature: scans of the places the
person watches, run while the window is closed, each kept in history so change
tracking has a steady record. There is no process of its own: the system's
scheduler runs `leita monitor run` every hour (package schedule), and each run
scans the watched places that are due, at the gentle pace, keeps each in the
history store the window reads, records how it went in settings.db, and exits.

Nothing runs unless the person turned monitoring on, and turning it off removes
the scheduler's entry (command.odin). The window and the command line share
what is watched through settings.db, so either can change it.
*/
package leita_monitor

import "core:fmt"
import "core:io"
import "core:os"
import "core:strings"
import "core:time"

import "jm:sqlite3"

import "../history"
import "../human"
import "../licence"
import "../settings"

// Paths are the files a run reads and writes.
Paths :: struct {
	settings: string, // settings.db: what is watched, and the runs
	history:  string, // history.db: the scans kept
	lock:     string, // held while a run runs
	licence:  string, // the licence, beside history.db
}

// paths_beside are the files beside the history store at kept, in allocator.
paths_beside :: proc(kept: string, allocator := context.allocator) -> Paths {
	return {
		settings = licence.path_beside(kept, allocator, settings.FILE),
		history = strings.clone(kept, allocator),
		lock = licence.path_beside(kept, allocator, LOCK_FILE),
		licence = licence.path_beside(kept, allocator),
	}
}

// PERIODS are how long each schedule leaves between scans of a place, in
// seconds.
PERIODS := [settings.Frequency]i64 {
	.Hourly = 60 * 60,
	.Daily  = 24 * 60 * 60,
	.Weekly = 7 * 24 * 60 * 60,
}

// SLACK is how early a place may be scanned before its period is up. The
// scheduler starts each run up to five minutes past the hour (schedule.SPREAD,
// and the task's RandomDelay), so an hourly place is due every run, and a daily
// one at about the same hour each day, with room for a run that starts late.
SLACK :: 15 * 60

// due is whether a place scanned every every, last at last (Unix seconds, 0
// for never), is due at now.
due :: proc(every: settings.Frequency, last, now: i64) -> bool {
	return last == 0 || now - last >= PERIODS[every] - SLACK
}

// Options are what a run is asked to do.
Options :: struct {
	paths: Paths,
	now:   time.Time,
	all:   bool, // scan every watched place, due or not
}

// EXIT_FAILED is what a run exits with when a place could not be scanned or
// kept, so the scheduler's own record says so.
EXIT_FAILED :: 1

/*
run scans each watched place that is due, keeps each scan in history, and
records how each went, saying so on w a line a place. It does nothing while
monitoring is off, or while another run holds the lock. It exits EXIT_FAILED
when a place failed, else 0.
*/
run :: proc(opt: Options, w: io.Writer) -> int {
	st: settings.Store
	if err := settings.open(&st, opt.paths.settings); err != nil {
		fmt.wprintfln(w, "error: cannot open %s: %s", opt.paths.settings, history.describe(err))
		return EXIT_FAILED
	}
	defer settings.close(&st)
	if !settings.monitoring(&st) {
		fmt.wprintln(w, "monitoring is off: nothing to do")
		return 0
	}
	l, taken := lock(opt.paths.lock)
	switch taken {
	case .Held:
		fmt.wprintln(w, "another run is still going: standing aside")
		return 0
	case .Failed:
		fmt.wprintfln(w, "error: cannot lock %s", opt.paths.lock)
		return EXIT_FAILED
	case .Taken:
	}
	defer unlock(&l)

	watches, err := settings.watches(&st, context.temp_allocator)
	if err != nil {
		fmt.wprintfln(w, "error: cannot read what is watched: %s", history.describe(err))
		return EXIT_FAILED
	}
	now := time.to_unix_seconds(opt.now)
	code := 0
	for watch in watches {
		last, has_last := settings.last_run(&st, watch.place, context.temp_allocator)
		if !opt.all && !due(watch.every, last.started if has_last else 0, now) {
			continue
		}
		r := scan_one(opt, watch)
		if _, rerr := settings.record(&st, r); rerr != nil {
			fmt.wprintfln(
				w,
				"error: cannot record the run of %s: %s",
				watch.place,
				history.describe(rerr),
			)
			code = EXIT_FAILED
		}
		if r.problem != "" {
			fmt.wprintfln(w, "%s: failed: %s", watch.place, r.problem)
			code = EXIT_FAILED
			continue
		}
		fmt.wprintfln(
			w,
			"%s: %s in %.1f s, %s",
			watch.place,
			human.bytes(r.bytes),
			r.seconds,
			how_read(r),
		)
	}
	return code
}

// scan_one scans the watched place and keeps the scan in history, and says how
// it went.
@(private)
scan_one :: proc(opt: Options, watch: settings.Watch) -> (r: settings.Run) {
	r.place = watch.place
	r.started = time.to_unix_seconds(opt.now)
	s, problem := survey_place(
		watch.place,
		history.baseline_path(opt.paths.history, watch.place, context.temp_allocator),
	)
	if s == nil {
		r.problem = problem
		return
	}
	defer place_scan_destroy(s)
	r.seconds = time.duration_seconds(s.duration)
	r.bytes = bytes(s)
	r.updated = s.updated
	r.why = s.why
	if sp, ok := s.space.?; ok {
		r.disk_total, r.disk_free = sp.total, sp.free
	}
	r.problem = keep(opt.paths.history, s)
	return
}

// keep keeps the scan in the history store at path, and says why it could not,
// or "".
@(private)
keep :: proc(path: string, s: ^Place_Scan) -> string {
	// The store makes its errors in the allocator it was opened in.
	context.allocator = context.temp_allocator
	hs: history.Store
	if err := history.open(&hs, path); err != nil {
		return fmt.tprintf("cannot open %s: %s", path, history.describe(err))
	}
	defer history.close(&hs)
	if _, err := history.keep(&hs, s.place, &s.tree, &s.roll, s.top, s.tree.nodes_done);
	   err != nil {
		return fmt.tprintf("cannot keep the scan: %s", history.describe(err))
	}
	return ""
}

// how_read says how a run read its place: updated from the last tree, or
// whole and why, in the temp allocator.
how_read :: proc(r: settings.Run) -> string {
	switch {
	case r.updated:
		return "updated from the last scan"
	case r.why != "":
		return fmt.tprintf("read whole: %s", r.why)
	}
	return "read whole"
}

/*
forget stops watching place and deletes what was kept for its next run, its
baseline, and says whether it was watched. The scans kept in history stay.
*/
forget :: proc(
	st: ^settings.Store,
	paths: Paths,
	place: string,
) -> (
	found: bool,
	err: sqlite3.Error,
) {
	found = settings.unwatch(st, place) or_return
	if found {
		os.remove(history.baseline_path(paths.history, place, context.temp_allocator))
	}
	return
}
