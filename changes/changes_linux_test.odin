#+build linux
package changes

import "core:os"
import "core:testing"

// A cursor taken now asks for a probe from just before it, and carries on when the
// place was last scanned whole.
@(test)
test_a_linux_cursor_asks_for_a_probe :: proc(t: ^testing.T) {
	place, _ := os.temp_directory(context.temp_allocator)
	c, ok := now(place)
	testing.expect(t, ok, "no cursor for the temp directory")
	set, next, err := since(place, c)
	defer change_set_destroy(&set)
	testing.expect_value(t, err, Error.None)
	testing.expectf(t, !set.rescan, "rescan: %s", set.why)
	testing.expect(t, set.probe, "no probe")
	testing.expect_value(t, set.since, c.position - i64(SLACK))
	testing.expect(t, next.position >= c.position, "the cursor went back")
	testing.expect_value(t, next.full, c.full)
}

// What leaves a cursor unusable says so, and why.
@(test)
test_a_linux_cursor_that_cannot_be_trusted_rescans :: proc(t: ^testing.T) {
	place, _ := os.temp_directory(context.temp_allocator)
	c, ok := now(place)
	testing.expect(t, ok, "no cursor for the temp directory")

	moved := c
	moved.volume[0] += 1
	stale := c
	stale.full -= i64(STALE_AFTER) + 1
	ahead := c
	ahead.position += i64(STALE_AFTER)
	for bad in ([]Cursor{{}, moved, stale, ahead}) {
		set, _, err := since(place, bad)
		testing.expect_value(t, err, Error.None)
		testing.expectf(t, set.rescan && set.why != "", "%v: no rescan", bad)
	}
}
