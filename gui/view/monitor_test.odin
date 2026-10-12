package leita_view

import "core:testing"

import "jm:ui"
import "jm:ui/ops"
import "jm:ui/render"

import "../command"
import "../query"

@(private = "file")
Monitor_Rig :: struct {
	m: Model,
	h: render.Headless,
}

// monitor_open opens the window on a scan with the Monitoring dialog up, the
// host saying scans are not scheduled.
@(private = "file")
monitor_open :: proc(s: ^Monitor_Rig) {
	model_init(&s.m, "/top")
	s.m.settings_read = true
	s.m.monitor_open = true
	fonts := []ops.Font_Ref {
		{0, ui.default_font(), 400},
		{1, ui.default_font(), 500},
		{2, ui.default_font(), 600},
		{3, ui.default_font(), 400},
	}
	render.headless_init(&s.h, view, &s.m, {1000, 700}, fonts)
	ui.probe_deliver(
		&s.h.p,
		query.Progress{},
		query.Progress_Result{generation = 1, state = .Scanning, target = "/top"},
	)
	monitor_answer(s, {on = false, scheduler = "systemd"})
}

// monitor_answer is the host answering the Monitoring dialog with r, laid out.
@(private = "file")
monitor_answer :: proc(s: ^Monitor_Rig, r: query.Monitor_Result) {
	ui.probe_deliver(&s.h.p, query.Monitor{}, r)
	ui.probe_frame(&s.h.p)
	ui.probe_frame(&s.h.p)
}

@(private = "file")
monitor_close :: proc(s: ^Monitor_Rig) {
	render.headless_destroy(&s.h)
	model_destroy(&s.m)
}

// The switch's status word: what the dialog says scheduled scans are.
@(private = "file")
say_switch :: proc(p: ^ui.Probe) -> string {
	if ui.probe_tagged(p, "On") {
		return "On"
	}
	if ui.probe_tagged(p, "Off") {
		return "Off"
	}
	return ""
}

// A click on Scheduled scans sends the change and shows it at once; the switch
// holds it, taking no second flip, until the host answers, then shows the
// host's value, which is the same when the change was made and the old one
// when it was refused.
@(test)
scheduled_scans_switch_holds_the_click_until_the_host_answers :: proc(t: ^testing.T) {
	s: Monitor_Rig
	monitor_open(&s)
	defer monitor_close(&s)
	p := &s.h.p

	testing.expect_value(t, say_switch(p), "Off")
	testing.expect(t, ui.probe_click_top(p, "Scheduled scans"), "the switch is clicked")
	c, ok := sent(p, command.Monitoring).?
	testing.expect(t, ok, "the click sends Monitoring")
	testing.expect(t, c.on, "turned on")
	ui.probe_advance(p, 30, 1.0 / 60)
	testing.expect_value(t, say_switch(p), "On")

	// A second click while the host works sends nothing and changes nothing.
	testing.expect(t, ui.probe_click_top(p, "Scheduled scans"))
	_, again := sent(p, command.Monitoring).?
	testing.expect(t, !again, "no second Monitoring while one is in flight")
	ui.probe_advance(p, 30, 1.0 / 60)
	testing.expect_value(t, say_switch(p), "On")

	// Made: the switch stays as clicked, and takes the next flip.
	monitor_answer(&s, {on = true, scheduler = "systemd", changed = 1})
	testing.expect_value(t, say_switch(p), "On")
	testing.expect(t, ui.probe_click_top(p, "Scheduled scans"))
	c, ok = sent(p, command.Monitoring).?
	testing.expect(t, ok && !c.on, "the next click turns it off")
	ui.probe_advance(p, 30, 1.0 / 60)
	testing.expect_value(t, say_switch(p), "Off")

	// Refused: the switch goes back to what the host has.
	monitor_answer(&s, {on = true, scheduler = "systemd", changed = 2, problem = "no"})
	testing.expect_value(t, say_switch(p), "On")
	testing.expect(t, ui.probe_tagged(p, "no"), "the refusal is shown")
}
