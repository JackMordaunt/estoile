package leita_view

import "core:testing"

import "jm:ui"
import "jm:ui/ops"
import "jm:ui/render"

import "../query"

// The status strip in a probe, the host's progress made up by hand.

@(private = "file")
Status_Rig :: struct {
	m: Model,
	h: render.Headless,
}

@(private = "file")
status_open :: proc(s: ^Status_Rig) {
	model_init(&s.m, "/top")
	s.m.settings_read = true
	fonts := []ops.Font_Ref {
		{0, ui.default_font(), 400},
		{1, ui.default_font(), 500},
		{2, ui.default_font(), 600},
		{3, ui.default_font(), 400},
	}
	render.headless_init(&s.h, view, &s.m, {1000, 700}, fonts)
}

@(private = "file")
status_close :: proc(s: ^Status_Rig) {
	render.headless_destroy(&s.h)
	model_destroy(&s.m)
}

// deliver delivers prog as the scan's progress and runs frames until it has
// laid out: a row lays out what it holds by the sizes they had the frame before.
@(private = "file")
deliver :: proc(s: ^Status_Rig, prog: query.Progress_Result) {
	ui.probe_deliver(&s.h.p, query.Progress{}, prog)
	ui.probe_advance(&s.h.p, 3, 1.0 / 60)
}

// The chart's switch is as far down the window whatever the status says: a scan
// with nothing to say, one finished with how it read its place, one refused a
// folder mid-scan, and one with two warnings at once.
@(test)
the_chart_holds_still_as_the_status_changes :: proc(t: ^testing.T) {
	s: Status_Rig
	status_open(&s)
	defer status_close(&s)
	p := &s.h.p
	base := query.Progress_Result{generation = 1, target = "/top", nodes = 10, bytes = 1024}

	scanning := base
	scanning.state = .Scanning
	deliver(&s, scanning)
	was := ui.probe_bounds(p, "Sunburst")
	testing.expect(t, was.h > 0, "the chart's switch is drawn")

	updated := base
	updated.state = .Done
	updated.kept, updated.updated, updated.reread, updated.since = true, true, 3, 1_700_000_000
	deliver(&s, updated)
	testing.expect(t, ui.probe_tagged(p, "· read again where changed"), "how the scan read is on the counters line")
	testing.expect_value(t, ui.probe_bounds(p, "Sunburst"), was)

	refused := scanning
	refused.unread = 3
	deliver(&s, refused)
	testing.expect(t, ui.probe_tagged(p, "3 folders could not be read."), "the refused folders are counted")
	testing.expect_value(t, ui.probe_bounds(p, "Sunburst"), was)

	both := updated
	both.updated, both.why = false, "too much has happened on the volume"
	both.unread, both.slow = 2, true
	deliver(&s, both)
	testing.expect(t, ui.probe_tagged(p, "2 folders could not be read."), "the most pressing message shows")
	testing.expect(t, ui.probe_tagged(p, "+2 more"), "the rest are counted")
	testing.expect(t, ui.probe_tagged(p, "· read whole"), "a whole read is on the counters line")
	testing.expect_value(t, ui.probe_bounds(p, "Sunburst"), was)

	deliver(&s, scanning)
	testing.expect_value(t, ui.probe_bounds(p, "Sunburst"), was)
}

// A failed scan's banner stands where the chart was, not above it.
@(test)
a_failed_scan_shows_its_banner_in_the_charts_place :: proc(t: ^testing.T) {
	s: Status_Rig
	status_open(&s)
	defer status_close(&s)
	p := &s.h.p
	deliver(&s, {generation = 1, state = .Scanning, target = "/top"})
	testing.expect(t, ui.probe_bounds(p, "Sunburst").h > 0, "the chart's switch is drawn")
	deliver(&s, {generation = 1, state = .Failed, target = "/top", problem = "no such directory"})
	testing.expect(t, ui.probe_tagged(p, "no such directory"), "the banner says why")
	testing.expect_value(t, ui.probe_bounds(p, "Sunburst").h, 0)
}
