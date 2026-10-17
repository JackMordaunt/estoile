package report

import "core:strings"
import "core:testing"

// A machine with no font installed still exports a PDF, set in the face pdf
// carries, accented and Cyrillic names and all.
@(test)
a_pdf_needs_no_installed_font :: proc(t: ^testing.T) {
	files := []Entry {
		{path = "/data/Größe/café.bin", bytes = 2 << 20},
		{path = "/data/Привет.txt", bytes = 1 << 20},
	}
	r := Report {
		version       = "test",
		target        = "/data",
		bytes         = 3 << 20,
		files         = 2,
		largest_files = files,
	}
	sb := strings.builder_make(context.temp_allocator)
	err := write_pdf(strings.to_writer(&sb), &r, .A4, installed = false)
	if !testing.expect_value(t, err, Error.None) {
		return
	}
	one := strings.to_string(sb)
	testing.expect(t, strings.has_prefix(one, "%PDF-1.7") && strings.has_suffix(one, "%%EOF\n"))
	testing.expect(t, strings.contains(one, "LiberationSans"), "not set in the carried face")
}
