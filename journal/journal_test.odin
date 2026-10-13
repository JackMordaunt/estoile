package journal

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "core:time"

// SEC is a second in ns, the unit the tests' records are written in.
@(private = "file")
SEC :: i64(time.Second)

// T0 is when the tests' logs begin, ns since the epoch.
@(private = "file")
T0 :: i64(1_760_000_000) * SEC

// A log file holding the header for mount and records, in a folder of its own.
@(private = "file")
log_file :: proc(t: ^testing.T, name, mount: string, records: []Record) -> string {
	dir, _ := os.temp_directory(context.temp_allocator)
	path, _ := filepath.join(
		{dir, fmt.tprintf("leita_journal_%s.log", name)},
		context.temp_allocator,
	)
	b := make([dynamic]byte, context.temp_allocator)
	append(&b, ..header_make(mount, context.temp_allocator))
	buf: [RECORD_SIZE]byte
	for r in records {
		record_put(buf[:], r)
		append(&b, ..buf[:])
	}
	testing.expect(t, os.write_entire_file(path, b[:]) == nil, "could not write the log")
	return path
}

// Heartbeats every HEARTBEAT from `from` up to and including `to`, ns.
@(private = "file")
beats :: proc(from, to: i64) -> []Record {
	out := make([dynamic]Record, context.temp_allocator)
	for at := from; at <= to; at += i64(HEARTBEAT) {
		append(&out, Record{.Heartbeat, at, 0})
	}
	return out[:]
}

@(private = "file")
joined :: proc(parts: ..[]Record) -> []Record {
	out := make([dynamic]Record, context.temp_allocator)
	for p in parts {
		append(&out, ..p)
	}
	return out[:]
}

// A path's hash is FNV-1a 64 of its bytes, and a child's follows from its parent's.
@(test)
test_a_path_hashes_as_fnv1a :: proc(t: ^testing.T) {
	testing.expect_value(t, hash_path(""), u64(0xcbf29ce484222325))
	testing.expect_value(t, hash_path("a"), u64(0xaf63dc4c8601ec8c))
	testing.expect_value(t, hash_child(hash_path("/mnt/e"), "jt"), hash_path("/mnt/e/jt"))
	testing.expect_value(t, hash_child(hash_path("/"), "home", false), hash_path("/home"))
}

// A header and a record read back as written; a header cut short is refused.
@(test)
test_a_log_reads_back_what_was_written :: proc(t: ^testing.T) {
	head := header_make("/mnt/e", context.temp_allocator)
	mount, size, ok := header_read(head)
	testing.expect(t, ok, "the header did not read back")
	testing.expect_value(t, mount, "/mnt/e")
	testing.expect_value(t, size, len(head))
	_, _, ok = header_read(head[:len(head) - 1])
	testing.expect(t, !ok, "a short header was read")
	_, _, ok = header_read(transmute([]byte)string("LEITAJL0\x00\x00"))
	testing.expect(t, !ok, "another magic was read")

	buf: [RECORD_SIZE]byte
	r := Record{.Changed, -5, 0xfedc_ba98_7654_3210}
	record_put(buf[:], r)
	testing.expect_value(t, record_get(buf[:]), r)
}

// A log with a heartbeat before the window and every 10 s through it covers it,
// and names the directories that changed in it, not those before.
@(test)
test_a_log_with_no_break_covers_the_window :: proc(t: ^testing.T) {
	records := joined(
		{{.Start, T0, 7}, {.Changed, T0 + 1 * SEC, 1}},
		beats(T0 + 10 * SEC, T0 + 40 * SEC),
		{{.Changed, T0 + 41 * SEC, 2}, {.Changed, T0 + 42 * SEC, 3}},
		beats(T0 + 50 * SEC, T0 + 60 * SEC),
	)
	path := log_file(t, "covered", "/mnt/e", records)
	defer os.remove(path)
	w, why := window(path, T0 + 25 * SEC, T0 + 65 * SEC)
	defer window_destroy(&w)
	testing.expectf(t, why == "", "not covered: %s", why)
	testing.expect_value(t, w.mount, "/mnt/e")
	testing.expect_value(t, w.end, T0 + 60 * SEC)
	testing.expect_value(t, len(w.hashes), 2)
	testing.expect(t, 2 in w.hashes && 3 in w.hashes, "a change in the window is missing")
	testing.expect(t, 1 not_in w.hashes, "a change before the window was named")

	// A window that starts at the Start is covered too.
	w2, why2 := window(path, T0, T0 + 65 * SEC)
	defer window_destroy(&w2)
	testing.expectf(t, why2 == "", "from the start, not covered: %s", why2)
	testing.expect(t, 1 in w2.hashes, "the change after the start is missing")
}

// Whatever breaks the record of a window says so, and names nothing.
@(test)
test_a_break_in_the_log_is_not_covered :: proc(t: ^testing.T) {
	Case :: struct {
		name:    string,
		records: []Record,
		from:    i64,
	}
	now := T0 + 65 * SEC
	cases := []Case {
		{
			"gap",
			joined(beats(T0, T0 + 20 * SEC), beats(T0 + 45 * SEC, T0 + 60 * SEC)),
			T0 + 5 * SEC,
		},
		{
			"overflow",
			joined(
				beats(T0, T0 + 30 * SEC),
				{{.Overflow, T0 + 31 * SEC, 0}},
				beats(T0 + 40 * SEC, T0 + 60 * SEC),
			),
			T0 + 5 * SEC,
		},
		{
			"restart",
			joined(
				beats(T0, T0 + 30 * SEC),
				{{.Start, T0 + 32 * SEC, 9}},
				beats(T0 + 40 * SEC, T0 + 60 * SEC),
			),
			T0 + 5 * SEC,
		},
		{"stopped", joined(beats(T0, T0 + 30 * SEC), {{.Stop, T0 + 31 * SEC, 0}}), T0 + 5 * SEC},
		{"old", beats(T0, T0 + 30 * SEC), T0 + 5 * SEC},
		{"late", beats(T0 + 10 * SEC, T0 + 60 * SEC), T0 + 5 * SEC},
		{
			"stop before",
			joined(
				beats(T0, T0 + 20 * SEC),
				{{.Stop, T0 + 21 * SEC, 0}},
				{{.Start, T0 + 30 * SEC, 3}},
				beats(T0 + 40 * SEC, T0 + 60 * SEC),
			),
			T0 + 25 * SEC,
		},
		{
			"clock back",
			joined(
				beats(T0, T0 + 30 * SEC),
				{{.Changed, T0 + 25 * SEC, 1}},
				beats(T0 + 40 * SEC, T0 + 60 * SEC),
			),
			T0 + 5 * SEC,
		},
	}
	for c in cases {
		path := log_file(
			t,
			strings.concatenate({"break_", c.name}, context.temp_allocator),
			"/",
			c.records,
		)
		w, why := window(path, c.from, now)
		testing.expectf(t, why != "", "%s: covered", c.name)
		testing.expectf(t, len(w.hashes) == 0, "%s: named %d directories", c.name, len(w.hashes))
		window_destroy(&w)
		os.remove(path)
	}
	_, why := window("/no/such/leita/log", T0, now)
	testing.expect(t, why != "", "a log that is not there covered the window")
}

// Records after the window belong to the next one; a record cut short at the end,
// as a write stopped in the middle leaves, is not read.
@(test)
test_a_window_ends_at_its_last_record :: proc(t: ^testing.T) {
	records := joined(
		beats(T0, T0 + 30 * SEC),
		{{.Changed, T0 + 31 * SEC, 5}},
		beats(T0 + 40 * SEC, T0 + 50 * SEC),
	)
	path := log_file(t, "end", "/", records)
	defer os.remove(path)
	w, why := window(path, T0 + 5 * SEC, T0 + 35 * SEC)
	defer window_destroy(&w)
	testing.expectf(t, why == "", "not covered: %s", why)
	testing.expect_value(t, w.end, T0 + 31 * SEC)
	testing.expect(t, 5 in w.hashes, "the last change was not named")

	data, _ := os.read_entire_file(path, context.temp_allocator)
	torn := make([]byte, len(data) + 9, context.temp_allocator)
	copy(torn, data)
	testing.expect(t, os.write_entire_file(path, torn) == nil)
	w2, why2 := window(path, T0 + 5 * SEC, T0 + 55 * SEC)
	defer window_destroy(&w2)
	testing.expectf(t, why2 == "", "a torn last record broke the log: %s", why2)
	testing.expect_value(t, w2.end, T0 + 50 * SEC)
}

// Compaction drops what is older than it is asked to keep, and leaves a log that
// reads as before for what it kept.
@(test)
test_compaction_drops_old_records :: proc(t: ^testing.T) {
	records := joined(
		{{.Start, T0, 1}, {.Changed, T0 + SEC, 8}},
		beats(T0 + 10 * SEC, T0 + 60 * SEC),
	)
	path := log_file(t, "compact", "/mnt/e", records)
	defer os.remove(path)
	dropped, err := compact(path, T0 + 30 * SEC)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, dropped, 4)
	data, _ := os.read_entire_file(path, context.temp_allocator)
	mount, at, ok := header_read(data)
	testing.expect(t, ok && mount == "/mnt/e", "the header was not kept")
	testing.expect_value(t, (len(data) - at) / RECORD_SIZE, 4)
	testing.expect_value(t, record_get(data[at:]).time, T0 + 30 * SEC)
	w, why := window(path, T0 + 5 * SEC, T0 + 65 * SEC)
	defer window_destroy(&w)
	testing.expect(t, why != "", "a window older than the log was covered")
	w2, why2 := window(path, T0 + 35 * SEC, T0 + 65 * SEC)
	defer window_destroy(&w2)
	testing.expectf(t, why2 == "", "what was kept is not covered: %s", why2)
}

// mountinfo reads with its escapes undone; what is never recorded is said, quietly
// or with why. A mount made read-only over a writable filesystem, as the service's
// ProtectSystem=strict makes every mount it sees, is still recorded.
@(test)
test_mounts_are_read_and_judged :: proc(t: ^testing.T) {
	text :=
		"36 1 8:1 / / ro,relatime shared:1 - ext4 /dev/sda1 rw\n" +
		"40 36 0:22 / /proc rw - proc proc rw\n" +
		"41 36 8:2 / /mnt/my\\040disk ro,relatime - xfs /dev/sda2 ro\n" +
		"42 36 0:50 / /net rw master:2 - nfs4 srv:/x rw\n" +
		"43 36 0:30 /@home /home rw - btrfs /dev/sdb rw\n" +
		"garbage\n"
	mounts := mounts_parse(text)
	defer mounts_destroy(mounts)
	testing.expect_value(t, len(mounts), 5)
	testing.expect_value(t, mounts[2].point, "/mnt/my disk")
	testing.expect_value(t, mounts[4].root, "/@home")
	testing.expect_value(t, mounts[0].device, "8:1")
	want := []struct {
		try: bool,
		why: string,
	} {
		{true, ""},
		{false, ""},
		{false, "the filesystem is read-only"},
		{false, "a network filesystem, which another machine can change"},
		{true, ""},
	}
	for m, i in mounts {
		try, why := judge(m)
		testing.expectf(t, try == want[i].try, "%s: try %v", m.point, try)
		testing.expectf(t, why == want[i].why, "%s: why %q", m.point, why)
	}
}
