package leita_settings

import "core:os"
import "core:path/filepath"
import "core:testing"

@(test)
a_setting_never_written_reads_as_absent :: proc(t: ^testing.T) {
	st: Store
	testing.expect(t, open(&st, ":memory:") == nil)
	defer close(&st)

	testing.expect(t, set(&st, LANGUAGE, "de") == nil)
	v, found := get(&st, THEME, context.temp_allocator)
	testing.expect(t, !found, "another key's value is not this one's")
	testing.expect_value(t, v, "")
	language, ok := get(&st, LANGUAGE, context.temp_allocator)
	testing.expect(t, ok)
	testing.expect_value(t, language, "de")
}

@(test)
a_setting_set_again_replaces_the_one_before :: proc(t: ^testing.T) {
	st: Store
	testing.expect(t, open(&st, ":memory:") == nil)
	defer close(&st)

	testing.expect(t, set(&st, THEME, "dark") == nil)
	testing.expect(t, set(&st, LANGUAGE, "de") == nil)
	testing.expect(t, set(&st, THEME, "light") == nil)

	theme, ok := get(&st, THEME, context.temp_allocator)
	testing.expect(t, ok)
	testing.expect_value(t, theme, "light")
	language, _ := get(&st, LANGUAGE, context.temp_allocator)
	testing.expect_value(t, language, "de")
}

@(test)
settings_outlast_the_connection_that_wrote_them :: proc(t: ^testing.T) {
	dir, derr := os.make_directory_temp("", "leita-settings-*", context.temp_allocator)
	testing.expect(t, derr == nil)
	defer os.remove_all(dir)
	path, _ := filepath.join({dir, "data", FILE}, context.temp_allocator)

	{
		st: Store
		testing.expect(t, open(&st, path) == nil, "it makes its folder")
		testing.expect(t, set(&st, LANGUAGE, "ja") == nil)
		close(&st)
	}
	st: Store
	testing.expect(t, open(&st, path) == nil)
	defer close(&st)
	language, ok := get(&st, LANGUAGE, context.temp_allocator)
	testing.expect(t, ok)
	testing.expect_value(t, language, "ja")
}
