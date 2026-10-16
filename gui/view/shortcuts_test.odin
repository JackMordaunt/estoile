package leita_view

import "core:testing"

import "jm:ui"
import "jm:ui/ops"
import "jm:ui/render"

import "../command"
import "../query"

@(private = "file")
Shortcut_Rig :: struct {
	m: Model,
	h: render.Headless,
}

@(private = "file")
shortcuts_open :: proc(r: ^Shortcut_Rig, prog: query.Progress_Result) {
	model_init(&r.m, "/top")
	r.m.settings_read = true
	fonts := []ops.Font_Ref {
		{0, ui.default_font(), 400},
		{1, ui.default_font(), 500},
		{2, ui.default_font(), 600},
		{3, ui.default_font(), 400},
	}
	render.headless_init(&r.h, view, &r.m, {1000, 700}, fonts)
	ui.probe_deliver(&r.h.p, query.Progress{}, prog)
	ui.probe_frame(&r.h.p)
	ui.probe_frame(&r.h.p)
}

@(private = "file")
shortcuts_close :: proc(r: ^Shortcut_Rig) {
	render.headless_destroy(&r.h)
	model_destroy(&r.m)
}

// The platform's command key with R scans the place again once a scan has
// finished, as the gear's Rescan does, and does nothing while one runs.
@(test)
the_command_key_with_r_scans_the_place_again :: proc(t: ^testing.T) {
	r: Shortcut_Rig
	shortcuts_open(&r, {generation = 1, state = .Done, target = "/top"})
	defer shortcuts_close(&r)
	p := &r.h.p

	ui.probe_key(p, .R, {ui.SHORTCUT})
	scan, scanned := sent(p, command.Scan).?
	testing.expect(t, scanned, "the shortcut scans again")
	testing.expect_value(t, command.text_of(&scan.path), "/top")

	ui.probe_deliver(p, query.Progress{}, query.Progress_Result{generation = 2, state = .Scanning, target = "/top"})
	ui.probe_frame(p)
	ui.probe_key(p, .R, {ui.SHORTCUT})
	testing.expect(t, sent(p, command.Scan) == nil, "nothing while a scan runs")
}

// The window is named after the place scanned, by the folder's own name, and
// renamed as a scan of another place starts.
@(test)
the_window_is_named_after_the_place :: proc(t: ^testing.T) {
	r: Shortcut_Rig
	shortcuts_open(&r, {generation = 1, state = .Scanning, target = "/top"})
	defer shortcuts_close(&r)
	p := &r.h.p

	when ODIN_OS == .Darwin {
		testing.expect_value(t, window_title("/top"), "top")
	} else {
		testing.expect_value(t, window_title("/top"), "top — Leita")
	}
	testing.expect_value(t, ui.probe_title(p), window_title("/top"))

	ui.probe_deliver(p, query.Progress{}, query.Progress_Result{generation = 2, state = .Scanning, target = "/"})
	ui.probe_frame(p)
	testing.expect_value(t, ui.probe_title(p), window_title("/"))
	ui.probe_frame(p)
	testing.expect(t, ui.probe_title(p) == window_title("/"), "named once, kept across frames")
}
