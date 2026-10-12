/*
Package alert is what a scheduled scan checks once it is kept: whether the disk
the place is on is past a limit the person set (report.threshold_of's, the same
the command line's --warn-used, --fail-used and --min-free check), whether the
place grew much faster than it has been, and whether, at the rate the disk has
been filling, it will be full within the days the person asked to hear about.
The rates come from the scans of the same place that history kept.

Everything here but notify is pure, so the tests need neither a disk nor a
desktop: they check rules against made-up history.
*/
package leita_alert

import "core:slice"
import "core:strings"

import "../history"
import "../report"

// Condition is a thing a scan can find wrong.
Condition :: enum u8 {
	Warn_Used, // the disk is at least Rules.warn_used percent used
	Fail_Used, // the disk is at least Rules.fail_used percent used
	Low_Free, // less than Rules.min_free is free
	Growth, // the place grew much faster than it has been
	Filling, // the forecast says the disk is full within Rules.full_within days
	Scan_Failed, // the place could not be scanned
}

Conditions :: bit_set[Condition;u8]

// CONDITION_KEYS name each Condition as the run log, the alert log and a
// webhook do.
CONDITION_KEYS := [Condition]string {
	.Warn_Used   = "warn_used",
	.Fail_Used   = "fail_used",
	.Low_Free    = "low_free",
	.Growth      = "growth",
	.Filling     = "filling",
	.Scan_Failed = "scan_failed",
}

// Rules are what a scan is checked against, each off at zero (or false).
Rules :: struct {
	warn_used:   int, // percent used
	fail_used:   int, // percent used
	min_free:    u64, // bytes
	full_within: int, // days
	growth:      bool,
}

/*
Alert is one thing found wrong, and what it measured: the disk's percent used,
free and total bytes; for Filling the days left; for Growth the bytes grown
since the last scan; and the limit crossed, in percent, bytes or days.
*/
Alert :: struct {
	kind:         Condition,
	used_percent: f64,
	free, total:  u64,
	days:         f64,
	grew:         u64,
	limit:        f64,
}

// DAY is a day in seconds.
DAY :: 24 * 60 * 60

/*
check is what rules find wrong with the newest of snapshots, the scans of one
place newest first as history.list gives them, the one just kept among them,
in the temp allocator. A disk of unknown size is past no limit and forecasts
nothing; growth needs no disk.
*/
check :: proc(rules: Rules, snapshots: []history.Snapshot) -> []Alert {
	out := make([dynamic]Alert, context.temp_allocator)
	if len(snapshots) == 0 {
		return out[:]
	}
	newest := snapshots[0]
	disk := newest.disk
	space: Maybe(report.Space)
	if disk.total > 0 && disk.free <= disk.total {
		space = report.Space{disk.total, disk.free}
	}
	th, configured, known := report.threshold_of(
		space,
		rules.warn_used,
		rules.fail_used,
		rules.min_free,
		context.temp_allocator,
	)
	measure := Alert {
		used_percent = th.used_percent,
		free         = disk.free,
		total        = disk.total,
	}
	if configured && known {
		// threshold_of folds the three into a verdict; each limit crossed is
		// its own alert, so the person hears which.
		switch {
		case rules.fail_used > 0 && th.used_percent >= f64(rules.fail_used):
			a := measure
			a.kind, a.limit = .Fail_Used, f64(rules.fail_used)
			append(&out, a)
		case rules.warn_used > 0 && th.used_percent >= f64(rules.warn_used):
			a := measure
			a.kind, a.limit = .Warn_Used, f64(rules.warn_used)
			append(&out, a)
		}
		if rules.min_free > 0 && disk.free < rules.min_free {
			a := measure
			a.kind, a.limit = .Low_Free, f64(rules.min_free)
			append(&out, a)
		}
	}
	if rules.growth {
		if grew, ok := unusual_growth(snapshots); ok {
			a := measure
			a.kind, a.grew = .Growth, grew
			append(&out, a)
		}
	}
	if rules.full_within > 0 {
		if days, ok := forecast(snapshots); ok && days <= f64(rules.full_within) {
			a := measure
			a.kind, a.days, a.limit = .Filling, days, f64(rules.full_within)
			append(&out, a)
		}
	}
	return out[:]
}

// conditions is what alerts found wrong, as a set to compare one run's with the
// last's.
conditions :: proc(alerts: []Alert) -> (out: Conditions) {
	for a in alerts {
		out += {a.kind}
	}
	return
}

// keys is ks as the run log keeps them: their CONDITION_KEYS joined by ",", in
// the temp allocator.
keys :: proc(ks: Conditions) -> string {
	names := make([dynamic]string, context.temp_allocator)
	for k in ks {
		append(&names, CONDITION_KEYS[k])
	}
	return strings.join(names[:], ",", context.temp_allocator)
}

// conditions_of reads what keys wrote, leaving out a key it does not know.
conditions_of :: proc(s: string) -> (out: Conditions) {
	rest := s
	for key in strings.split_iterator(&rest, ",") {
		if k, ok := condition_of(key); ok {
			out += {k}
		}
	}
	return
}

// condition_of is the Condition key names, and whether there is one.
condition_of :: proc(key: string) -> (Condition, bool) {
	for name, k in CONDITION_KEYS {
		if name == key {
			return k, true
		}
	}
	return {}, false
}

// FORECAST_MOST is how many of the newest snapshots a forecast draws its line
// through, and FORECAST_LEAST how few it will.
FORECAST_MOST  :: 10
FORECAST_LEAST :: 3

// FORECAST_SPAN is the least time, in seconds, the snapshots must span: points
// minutes apart say more about one busy hour than about the disk.
FORECAST_SPAN :: 60 * 60

/*
forecast is how many days from the newest snapshot until its disk is full, at
the rate it has been filling: the least-squares line through used space (total
less free) against time, over the newest FORECAST_MOST snapshots that carry the
disk. snapshots is newest first. There is none when fewer than FORECAST_LEAST
carry the disk, when they span less than FORECAST_SPAN, or when used space is
flat or falling. Zero when the line says the disk is already full.
*/
forecast :: proc(snapshots: []history.Snapshot) -> (days: f64, ok: bool) {
	points: [FORECAST_MOST][2]f64 // seconds before the newest, bytes used
	n := 0
	newest: history.Snapshot
	for s in snapshots {
		if n == FORECAST_MOST {
			break
		}
		if s.disk.total == 0 || s.disk.free > s.disk.total {
			continue
		}
		if n == 0 {
			newest = s
		}
		points[n] = {f64(s.taken - newest.taken), f64(s.disk.total - s.disk.free)}
		n += 1
	}
	if n < FORECAST_LEAST || -points[n - 1][0] < FORECAST_SPAN {
		return 0, false
	}
	mean_t, mean_u: f64
	for p in points[:n] {
		mean_t += p[0]
		mean_u += p[1]
	}
	mean_t /= f64(n)
	mean_u /= f64(n)
	spread, together: f64
	for p in points[:n] {
		spread += (p[0] - mean_t) * (p[0] - mean_t)
		together += (p[0] - mean_t) * (p[1] - mean_u)
	}
	slope := together / spread // bytes a second
	if slope <= 0 {
		return 0, false
	}
	used_now := mean_u + slope * (0 - mean_t)
	left := f64(newest.disk.total) - used_now
	return max(left / slope / DAY, 0), true
}

// GROWTH_FACTOR is how many times faster than its usual rate a place must have
// grown since its last scan to be unusual.
GROWTH_FACTOR :: 3

// GROWTH_EARLIER is how many earlier intervals between scans the usual rate is
// the median of, at least, and GROWTH_MOST at most.
GROWTH_EARLIER :: 3
GROWTH_MOST    :: 10

// GROWTH_FLOOR is the least a place must grow, in bytes, to be unusual, and
// GROWTH_SHARE the least share of its disk, whichever is more: a few megabytes
// are many times nothing, and worth no one's attention.
GROWTH_FLOOR :: 1 << 30
GROWTH_SHARE :: 0.01

// GROWTH_GAP is the shortest interval, in seconds, a rate is taken over: two
// scans minutes apart make any change look fast.
GROWTH_GAP :: 30 * 60

/*
unusual_growth says how much the place grew between the two newest snapshots,
and whether that was unusual: at least GROWTH_FACTOR times the median rate, in
bytes a day, of the GROWTH_EARLIER to GROWTH_MOST intervals before it, and at
least GROWTH_FLOOR or GROWTH_SHARE of the disk. A falling or flat median counts
as no growth at all, so a place that never grew is unusual once it grows by the
floor. snapshots is newest first.
*/
unusual_growth :: proc(snapshots: []history.Snapshot) -> (grew: u64, unusual: bool) {
	if len(snapshots) < GROWTH_EARLIER + 2 {
		return 0, false
	}
	a, b := snapshots[0], snapshots[1]
	if a.bytes <= b.bytes || a.taken - b.taken < GROWTH_GAP {
		return 0, false
	}
	grew = a.bytes - b.bytes
	floor := max(u64(GROWTH_FLOOR), u64(GROWTH_SHARE * f64(a.disk.total)))
	if grew < floor {
		return grew, false
	}
	rates := make([dynamic]f64, context.temp_allocator)
	for i in 1 ..< len(snapshots) - 1 {
		if len(rates) == GROWTH_MOST {
			break
		}
		newer, older := snapshots[i], snapshots[i + 1]
		if newer.taken - older.taken < GROWTH_GAP {
			continue
		}
		append(&rates, rate(newer, older))
	}
	if len(rates) < GROWTH_EARLIER {
		return grew, false
	}
	slice.sort(rates[:])
	usual := max(rates[len(rates) / 2], 0)
	return grew, rate(a, b) > GROWTH_FACTOR * usual
}

// rate is how fast the place grew from older to newer, in bytes a day.
@(private)
rate :: proc(newer, older: history.Snapshot) -> f64 {
	return (f64(newer.bytes) - f64(older.bytes)) / (f64(newer.taken - older.taken) / DAY)
}
