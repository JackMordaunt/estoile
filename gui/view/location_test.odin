package leita_view

import "core:strings"
import "core:testing"

import "jm:ui"
import "jm:ui/ops"
import "jm:ui/primer"
import "jm:ui/render"

import "../command"

@(private = "file")
Location_Rig :: struct {
	m: Model,
	h: render.Headless,
}

@(private = "file")
location_open :: proc(r: ^Location_Rig) {
	model_init(&r.m, "")
	r.m.settings_read = true
	fonts := []ops.Font_Ref {
		{0, ui.default_font(), 400},
		{1, ui.default_font(), 500},
		{2, ui.default_font(), 600},
		{3, ui.default_font(), 400},
	}
	render.headless_init(&r.h, view, &r.m, {1000, 700}, fonts)
	ui.probe_frame(&r.h.p)
	ui.probe_frame(&r.h.p)
}

@(private = "file")
location_close :: proc(r: ^Location_Rig) {
	render.headless_destroy(&r.h)
	model_destroy(&r.m)
}

// A path longer than a command can carry is not sent, which would scan an
// ancestor of it: the field stays, and the status says why, until a path that
// fits is entered.
@(test)
a_path_too_long_to_send_is_refused_in_the_field :: proc(t: ^testing.T) {
	r: Location_Rig
	location_open(&r)
	defer location_close(&r)
	p := &r.h.p

	defer free_all(context.temp_allocator)
	long := strings.repeat("/dir", command.MAX_PATH / 4 + 1, context.temp_allocator)
	ui.text_set(&r.m.path, long)
	r.m.editing, r.m.edit_focus = true, true
	ui.probe_advance(p, 5, 1.0 / 60)
	ui.probe_key(p, .Enter)
	ui.probe_frame(p)
	testing.expect(t, sent(p, command.Scan) == nil, "nothing is scanned")
	testing.expect(t, r.m.path_long, "the path is said to be too long")
	testing.expect(t, r.m.editing, "the field stays to be corrected")
	testing.expect(t, ui.probe_tagged(p, "that path is too long to scan"), "the status says so")

	ui.text_set(&r.m.path, "/top")
	ui.probe_advance(p, 5, 1.0 / 60)
	ui.probe_key(p, .Enter)
	scan, scanned := sent(p, command.Scan).?
	testing.expect(t, scanned, "a path that fits is scanned")
	testing.expect_value(t, command.text_of(&scan.path), "/top")
	testing.expect(t, !r.m.path_long, "and the warning goes")

}

// A frame leaves the theme it drew in behind it unset: primer's scheme is
// thread-local, tests share threads, and the Model that holds the scheme is the
// test's own stack, so a scheme left installed is read dead by the next test on
// that thread (ASan: stack-use-after-return in primer.color, 2026-10-17).
@(test)
a_frame_leaves_no_scheme_behind :: proc(t: ^testing.T) {
	r: Location_Rig
	location_open(&r)
	defer location_close(&r)
	r.m.dark = true
	ui.probe_frame(&r.h.p)
	testing.expect(t, primer.scheme() != &r.m.scheme, "the scheme is not the Model's")
	testing.expect_value(t, primer.theme(), primer.Theme.Light)
}
