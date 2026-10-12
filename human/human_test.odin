package human

import "core:testing"

@(test)
sizes_and_counts_read_as_a_person_says_them :: proc(t: ^testing.T) {
	testing.expect_value(t, bytes(512), "512 B")
	testing.expect_value(t, bytes(1536), "1.5 KiB")
	testing.expect_value(t, bytes(5 << 30), "5.0 GiB")
	testing.expect_value(t, count(7), "7")
	testing.expect_value(t, count(1000), "1,000")
	testing.expect_value(t, count(1234567), "1,234,567")
}

@(test)
parse_bytes_reads_a_size_a_flag_was_given :: proc(t: ^testing.T) {
	case_ok :: proc(t: ^testing.T, s: string, want: u64) {
		n, ok := parse_bytes(s)
		testing.expectf(t, ok, "%q did not parse", s)
		testing.expectf(t, n == want, "%q parsed to %d, want %d", s, n, want)
	}
	case_ok(t, "0", 0)
	case_ok(t, "512", 512)
	case_ok(t, "20GiB", 20 << 30)
	case_ok(t, "20gib", 20 << 30)
	case_ok(t, "20GB", 20 << 30)
	case_ok(t, "20G", 20 << 30)
	case_ok(t, "1.5TiB", u64(1.5 * f64(1 << 40)))
	case_ok(t, " 5 MiB ", 5 << 20)
	case_ok(t, "1PiB", 1 << 50)

	bad := []string{"", "GiB", "abc", "-5GiB", "5XiB", "5 GiB extra"}
	for s in bad {
		_, ok := parse_bytes(s)
		testing.expectf(t, !ok, "%q should not parse", s)
	}
}
