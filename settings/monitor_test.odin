package leita_settings

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:testing"

@(test)
monitoring_is_off_until_turned_on :: proc(t: ^testing.T) {
	st: Store
	testing.expect(t, open(&st, ":memory:") == nil)
	defer close(&st)

	testing.expect(t, !monitoring(&st), "nothing chosen is off")
	testing.expect(t, set_monitoring(&st, true) == nil)
	testing.expect(t, monitoring(&st))
	testing.expect(t, set_monitoring(&st, false) == nil)
	testing.expect(t, !monitoring(&st))
}

@(test)
a_place_watched_again_takes_its_new_schedule :: proc(t: ^testing.T) {
	st: Store
	testing.expect(t, open(&st, ":memory:") == nil)
	defer close(&st)

	testing.expect(t, watch(&st, {place = "/srv", every = .Daily, added = 10}) == nil)
	testing.expect(t, watch(&st, {place = "/home", every = .Hourly, added = 20}) == nil)
	testing.expect(t, watch(&st, {place = "/srv", every = .Weekly, added = 30}) == nil)

	ws, err := watches(&st, context.temp_allocator)
	testing.expect(t, err == nil)
	testing.expect_value(t, len(ws), 2)
	testing.expect_value(t, ws[0].place, "/srv")
	testing.expect_value(t, ws[0].every, Frequency.Weekly)
	testing.expect_value(t, ws[0].added, 10)
	testing.expect_value(t, ws[1].place, "/home")

	found, uerr := unwatch(&st, "/srv")
	testing.expect(t, uerr == nil && found)
	found, _ = unwatch(&st, "/srv")
	testing.expect(t, !found, "already gone")
	ws, _ = watches(&st, context.temp_allocator)
	testing.expect_value(t, len(ws), 1)
}

@(test)
runs_are_kept_newest_first_up_to_a_limit :: proc(t: ^testing.T) {
	st: Store
	testing.expect(t, open(&st, ":memory:") == nil)
	defer close(&st)

	for i in 0 ..< RUNS_KEPT + 5 {
		_, err := record(
			&st,
			{place = "/srv", started = i64(100 + i), seconds = 1.5, bytes = u64(i)},
		)
		testing.expect(t, err == nil)
	}
	_, _ = record(&st, {place = "/home", started = 1, problem = "gone"})

	rs, err := runs(&st, "/srv", allocator = context.temp_allocator)
	testing.expect(t, err == nil)
	testing.expect_value(t, len(rs), RUNS_KEPT)
	testing.expect_value(t, rs[0].started, i64(100 + RUNS_KEPT + 4))
	testing.expect_value(t, rs[0].seconds, 1.5)

	last, ok := last_run(&st, "/home", context.temp_allocator)
	testing.expect(t, ok)
	testing.expect_value(t, last.problem, "gone")
	_, ok = last_run(&st, "/nowhere", context.temp_allocator)
	testing.expect(t, !ok)

	// Unwatching a place forgets its runs.
	_, _ = unwatch(&st, "/srv")
	rs, _ = runs(&st, "/srv", allocator = context.temp_allocator)
	testing.expect_value(t, len(rs), 0)
}

@(test)
a_store_opened_again_keeps_its_watches :: proc(t: ^testing.T) {
	dir, derr := os.make_directory_temp("", "leita-settings-*", context.temp_allocator)
	testing.expect(t, derr == nil)
	defer os.remove_all(dir)
	path, _ := filepath.join({dir, FILE}, context.temp_allocator)

	for i in 0 ..< 3 {
		st: Store
		testing.expectf(t, open(&st, path) == nil, "open %d", i)
		testing.expect(t, watch(&st, {place = fmt.tprintf("/p%d", i), every = .Hourly}) == nil)
		close(&st)
	}
	st: Store
	testing.expect(t, open(&st, path) == nil)
	defer close(&st)
	ws, _ := watches(&st, context.temp_allocator)
	testing.expect_value(t, len(ws), 3)
	for w, i in ws {
		testing.expect_value(t, w.place, fmt.tprintf("/p%d", i))
		testing.expect_value(t, w.every, Frequency.Hourly)
	}
}
