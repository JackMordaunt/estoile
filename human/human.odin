/*
Package human writes numbers for a person to read: sizes in binary units and counts
with their thousands marked. The command line and the window say sizes the same way
because both say them through here.
*/
package human

import "core:fmt"
import "core:strconv"
import "core:strings"

// bytes is n bytes in binary units, to one decimal place past a KiB.
bytes :: proc(n: u64, allocator := context.temp_allocator) -> string {
	sb := strings.builder_make(allocator)
	write_bytes(&sb, n)
	return strings.to_string(sb)
}

// write_bytes writes n bytes to sb as bytes says them, for a caller saying a
// great many sizes at once rather than making a string of each.
write_bytes :: proc(sb: ^strings.Builder, n: u64) {
	units := [?]string{"B", "KiB", "MiB", "GiB", "TiB", "PiB"}
	v := f64(n)
	i := 0
	for v >= 1024 && i < len(units) - 1 {
		v /= 1024
		i += 1
	}
	if i == 0 {
		fmt.sbprintf(sb, "%d B", n)
		return
	}
	fmt.sbprintf(sb, "%.1f %s", v, units[i])
}

/*
parse_bytes reads s as bytes writes them, for a flag such as --min-free that
takes a size rather than printing one: a number, optionally fractional, then an
optional unit (B, K, KB, KiB, M, MB, MiB, G, GB, GiB, T, TB, TiB, P, PB, PiB;
case-insensitive; none means bytes). K/M/G/T/P and their "B" and "iB" spellings
all mean the binary unit, matching bytes above; leita has no use for the
decimal one. ok is false for anything else, including a negative number or an
empty string.
*/
parse_bytes :: proc(s: string) -> (n: u64, ok: bool) {
	trimmed := strings.trim_space(s)
	if trimmed == "" {
		return 0, false
	}
	i := 0
	for i < len(trimmed) && (trimmed[i] == '.' || (trimmed[i] >= '0' && trimmed[i] <= '9')) {
		i += 1
	}
	if i == 0 {
		return 0, false
	}
	value, value_ok := strconv.parse_f64(trimmed[:i])
	if !value_ok || value < 0 {
		return 0, false
	}
	KiB :: 1024.0
	MiB :: 1024.0 * KiB
	GiB :: 1024.0 * MiB
	TiB :: 1024.0 * GiB
	PiB :: 1024.0 * TiB
	unit := strings.trim_space(trimmed[i:])
	factor: f64
	switch strings.to_upper(unit, context.temp_allocator) {
	case "", "B":
		factor = 1
	case "K", "KB", "KIB":
		factor = KiB
	case "M", "MB", "MIB":
		factor = MiB
	case "G", "GB", "GIB":
		factor = GiB
	case "T", "TB", "TIB":
		factor = TiB
	case "P", "PB", "PIB":
		factor = PiB
	case:
		return 0, false
	}
	return u64(value * factor), true
}

// count is n with its thousands separated by commas.
count :: proc(n: u64, allocator := context.temp_allocator) -> string {
	digits := fmt.tprintf("%d", n)
	sb := strings.builder_make(allocator)
	for r, i in digits {
		if i > 0 && (len(digits) - i) % 3 == 0 {
			strings.write_byte(&sb, ',')
		}
		strings.write_rune(&sb, r)
	}
	return strings.to_string(sb)
}
