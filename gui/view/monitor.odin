package leita_view

import "core:fmt"

import "jm:ui"
import "jm:ui/primer"

import "../../human"
import "../../version"
import "../command"
import "../msg"
import "../query"

/*
Monitoring, a paid feature. The toolbar's pulse opens a dialog with one switch,
Scheduled scans, that hands the monitor to the system's scheduler or takes it
back, then the places watched, each with how often it is scanned and how its
last scan went, and a field to watch another, which opens holding the place
scanned now. Once the trial is over without a licence, the dialog says so and
only lets monitoring be turned off and places removed.
*/

// monitor_button is the toolbar's pulse, which opens the Monitoring dialog.
@(private)
monitor_button :: proc(gtx: ^ui.Ctx, m: ^Model, prog: ^query.Progress_Result) {
	if primer.icon_button(gtx, .Pulse, tr(.Monitoring), .Invisible) {
		m.monitor_open = true
		m.monitor_answered = false
		if ui.text_string(&m.watch_text) == "" && prog != nil {
			ui.text_set(&m.watch_text, prog.target)
		}
	}
}

// EVERY_WORDS name each schedule, in query.Frequency's order, which is the select's.
@(private, rodata)
EVERY_WORDS := [query.Frequency]msg.Msg {
	.Hourly = .Every_Hourly,
	.Daily  = .Every_Daily,
	.Weekly = .Every_Weekly,
}

// monitor_dialog is the Monitoring dialog, while it is open.
@(private)
monitor_dialog :: proc(gtx: ^ui.Ctx, m: ^Model) {
	if !m.monitor_open {
		return
	}
	r, _ := ui.need(gtx, query.Monitor{}, query.Monitor_Result)
	if r == nil {
		return
	}
	if sent, ok := m.monitor_sent.?; ok && r.changed != sent {
		m.monitor_sent = nil
		m.monitor_answered = true
		if r.problem == "" {
			ui.text_set(&m.watch_text, "")
		}
	}
	locked := !unlocked(gtx)
	waiting := m.monitor_sent != nil
	close := false
	buttons := [1]primer.Dialog_Button{{content = tr(.Close), clicked = &close}}
	if primer.dialog(gtx, &m.monitor_open, tr(.Monitoring), footer = buttons[:], width = .XLarge) {
		ui.column(gtx, gap = 16, align = .Fill)
		if locked {
			primer.inline_message(gtx, tr(.Monitoring_Locked), .Warning)
		}
		if ui.row(gtx, gap = 12, align = .Center) {
			ui.flexible(gtx, 1)
			if ui.column(gtx, gap = 4) {
				primer.text(gtx, tr(.Scheduled_Scans), weight = .Semibold)
				primer.text(
					gtx,
					trf(gtx, .Monitoring_Explain, version.NAME),
					.Small,
					color = primer.color(.Fg_Color_Muted),
				)
			}
			on := r.on
			if primer.toggle_switch(
				gtx,
				&on,
				name = tr(.Scheduled_Scans),
				label_on = tr(.On),
				label_off = tr(.Off),
				state = .Disabled if waiting || (locked && !r.on) else .Live,
			) {
				send_monitor(gtx, m, r, command.Monitoring{on = on})
			}
		}
		if r.on {
			primer.text(
				gtx,
				trf(gtx, .Monitoring_Through, r.scheduler),
				.Small,
				color = primer.color(.Fg_Color_Muted),
			)
		}
		if m.monitor_answered && r.problem != "" {
			primer.inline_message(gtx, r.problem, .Critical)
		}
		if r.note != "" {
			primer.inline_message(gtx, r.note, .Warning)
		}
		primer.heading(gtx, tr(.Watched_Places), level = 2, variant = .Small)
		if len(r.watched) == 0 {
			primer.text(gtx, tr(.Watched_None), color = primer.color(.Fg_Color_Muted))
		}
		for w, i in r.watched {
			watched_row(gtx, m, r, w, i)
		}
		watch_field(gtx, m, r, locked)
	}
	if close {
		m.monitor_open = false
	}
}

// watched_row is one place watched: its path, how often it is scanned, a button
// to stop watching it, and how its last scan went.
@(private)
watched_row :: proc(
	gtx: ^ui.Ctx,
	m: ^Model,
	r: ^query.Monitor_Result,
	w: query.Watched_Place,
	i: int,
) {
	s := ui.scope_open(gtx, u64(i + 1))
	defer ui.scope_close(&s)
	ui.column(gtx, gap = 4, align = .Fill)
	if ui.row(gtx, gap = 8, align = .Center) {
		ui.flexible(gtx, 1)
		primer.truncate(gtx, w.place, title = w.place, max_width = ui.INF, weight = .Semibold)
		options := make([]primer.Select_Option, len(query.Frequency), gtx.allocator)
		for e in query.Frequency {
			options[int(e)] = {
				label = tr(EVERY_WORDS[e]),
			}
		}
		at := int(w.every)
		if primer.select(
			gtx,
			options,
			&at,
			size = .Small,
			name = trf(gtx, .Schedule_Of, w.place),
		) {
			send_monitor(
				gtx,
				m,
				r,
				command.Watch{path = command.text_make(w.place), every = u8(at)},
			)
		}
		if primer.icon_button(
			gtx,
			.Trash,
			trf(gtx, .Stop_Watching, w.place),
			.Invisible,
			size = .Small,
		) {
			send_monitor(gtx, m, r, command.Unwatch{path = command.text_make(w.place)})
		}
	}
	primer.text(gtx, last_run_text(gtx, w), .Small, color = primer.color(.Fg_Color_Muted))
}

// last_run_text says how a place's last scan went.
@(private)
last_run_text :: proc(gtx: ^ui.Ctx, w: query.Watched_Place) -> string {
	switch {
	case !w.scanned:
		return tr(.Not_Scanned_Yet)
	case w.problem != "":
		return trf(gtx, .Last_Scan_Failed, taken_text(w.started, gtx.allocator), w.problem)
	}
	return trf(
		gtx,
		.Last_Scanned,
		taken_text(w.started, gtx.allocator),
		human.bytes(w.bytes),
		fmt.aprintf("%.1f", w.seconds, allocator = gtx.allocator),
	)
}

// watch_field is the field that names another place to watch, daily.
@(private)
watch_field :: proc(gtx: ^ui.Ctx, m: ^Model, r: ^query.Monitor_Result, locked: bool) {
	ui.row(gtx, gap = 8, align = .Center)
	ui.flexible(gtx, 1)
	typed := ui.text_string(&m.watch_text)
	edit := primer.text_input(
		gtx,
		&m.watch_text,
		placeholder = tr(.Watch_Placeholder),
		block = true,
		name = tr(.Watch_Place),
		state = .Disabled if locked else .Live,
	)
	add := primer.button(
		gtx,
		tr(.Watch),
		leading = .Plus,
		state = .Disabled if locked || typed == "" else .Live,
	)
	if (add || edit.submitted) && !locked && typed != "" && len(typed) <= command.MAX_PATH {
		send_monitor(
			gtx,
			m,
			r,
			command.Watch{path = command.text_make(typed), every = u8(query.Frequency.Daily)},
		)
	}
}

// send_monitor sends a change to monitoring, and waits for the host to say how
// it went.
@(private)
send_monitor :: proc(gtx: ^ui.Ctx, m: ^Model, r: ^query.Monitor_Result, c: command.Command) {
	m.monitor_sent = r.changed
	ui.command(gtx, c)
}
