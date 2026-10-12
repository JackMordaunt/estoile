/*
Threshold is what a monitoring tool reads instead of the full report: whether
the scanned volume's space is fine, worth a warning, or past the line a script
should fail on, and why. Checked here rather than in main so the one answer
both sides of the command line, --report and the plain exit code, build it from.
*/
package report

import "core:fmt"
import "core:strings"

import "../human"

// Verdict is how a Threshold came out.
Verdict :: enum {
	Ok,
	Warn,
	Fail,
}

// VERDICT_KEYS is how a Verdict is named in JSON (SCHEMA.md).
VERDICT_KEYS := [Verdict]string {
	.Ok   = "ok",
	.Warn = "warn",
	.Fail = "fail",
}

/*
Threshold is the limits a scan was checked against and what came of it. Every
limit that was not asked for is nil; used_percent and reasons are only
meaningful when known is true (threshold_of says why otherwise).
*/
Threshold :: struct {
	warn_used:    Maybe(int), // --warn-used, percent used
	fail_used:    Maybe(int), // --fail-used, percent used
	min_free:     Maybe(u64), // --min-free, bytes
	used_percent: f64, // what the volume actually is, 0 to 100
	verdict:      Verdict,
	// Why: one line per limit crossed, in the order above; empty for Ok.
	reasons:      []string,
}

/*
threshold_of checks space against warn_used and fail_used (percent used, 0 for
neither) and min_free (bytes, 0 for none). configured is false when none of
the three were given, so a caller can tell "nothing to check" from "checked and
fine". known is false when configured is true but space itself is not, so a
caller never reports Ok for a limit it could not actually evaluate; th is then
zeroed but for the limits named.

min_free has no warning tier of its own: running low on free space is a single
line a volume is either past or not, where percent used has room for a
warning before things are dire, so --warn-used and --fail-used are the pair
and --min-free stands alone, folded into Fail.
*/
threshold_of :: proc(
	space: Maybe(Space),
	warn_used, fail_used: int,
	min_free: u64,
	allocator := context.allocator,
) -> (
	th: Threshold,
	configured: bool,
	known: bool,
) {
	if warn_used > 0 {
		th.warn_used = warn_used
	}
	if fail_used > 0 {
		th.fail_used = fail_used
	}
	if min_free > 0 {
		th.min_free = min_free
	}
	configured = warn_used > 0 || fail_used > 0 || min_free > 0
	if !configured {
		return
	}
	sp, has_space := space.?
	if !has_space || sp.total == 0 {
		return
	}
	known = true
	th.used_percent = 100 * f64(sp.total - sp.free) / f64(sp.total)

	// strings.clone, not fmt.aprintf straight into allocator: debug.Allocator
	// (jm:debug) flagged a SIZE_MISMATCH on the delete in destroy when this used
	// fmt.aprintf directly, so the result is cloned to an allocation sized to
	// match what destroy later frees.
	reasons := make([dynamic]string, allocator)
	warned, failed := false, false
	if fail_used > 0 && th.used_percent >= f64(fail_used) {
		append(
			&reasons,
			strings.clone(
				fmt.tprintf(
					"%.1f%% used, at or past --fail-used %d%%",
					th.used_percent,
					fail_used,
				),
				allocator,
			),
		)
		failed = true
	}
	if warn_used > 0 && th.used_percent >= f64(warn_used) {
		append(
			&reasons,
			strings.clone(
				fmt.tprintf(
					"%.1f%% used, at or past --warn-used %d%%",
					th.used_percent,
					warn_used,
				),
				allocator,
			),
		)
		warned = true
	}
	if min_free > 0 && sp.free < min_free {
		append(
			&reasons,
			strings.clone(
				fmt.tprintf(
					"%s free, under --min-free %s",
					human.bytes(sp.free),
					human.bytes(min_free),
				),
				allocator,
			),
		)
		failed = true
	}
	switch {
	case failed:
		th.verdict = .Fail
	case warned:
		th.verdict = .Warn
	case:
		th.verdict = .Ok
	}
	shrink(&reasons)
	th.reasons = reasons[:]
	return
}
