package leita_view

import "core:fmt"

import "jm:ui"
import "jm:ui/primer"

import "../../version"
import mark "../mark"
import "../query"

/*
About: the toolbar's info button opens a dialog that says what this is and
whose: the mark and the name, the version, the business that makes it, what
it is for, the licence it runs under as the licence dialog says it, and where
to read more.
*/

// BUSINESS is who makes and sells leita, as LICENSE.md names the Licensor.
BUSINESS :: "Librium LLC"

// HOME_URL is the product's page.
HOME_URL :: "https://mordaunt.dev/leita"

// ABOUT_MARK_SIZE is the mark's size in the About dialog.
ABOUT_MARK_SIZE :: 72

// about_button is the toolbar's info button, which opens About.
@(private)
about_button :: proc(gtx: ^ui.Ctx, m: ^Model) {
	if primer.icon_button(
		gtx,
		.Info,
		fmt.aprintf("About %s", version.NAME, allocator = gtx.allocator),
		.Invisible,
	) {
		m.about_open = true
	}
}

// about_dialog is About, over everything while it is open.
@(private)
about_dialog :: proc(gtx: ^ui.Ctx, m: ^Model) {
	if !m.about_open {
		return
	}
	close := false
	buttons := [1]primer.Dialog_Button{{content = "Close", clicked = &close}}
	if primer.dialog(
		gtx,
		&m.about_open,
		fmt.aprintf("About %s", version.NAME, allocator = gtx.allocator),
		footer = buttons[:],
		width = .Medium,
	) {
		ui.column(gtx, gap = 12, align = .Start)
		if ui.row(gtx, gap = 16, align = .Center) {
			about_mark(gtx)
			if ui.column(gtx, gap = 2) {
				title(gtx, version.NAME)
				primer.text(
					gtx,
					fmt.aprintf("Version %s", version.VERSION, allocator = gtx.allocator),
					.Small,
					color = primer.color(.Fg_Color_Muted),
				)
			}
		}
		primer.text(gtx, "Instant disk search, with reports.", weight = .Semibold)
		primer.text(
			gtx,
			"See what fills any drive as it scans, track what changed since the last scan, free space safely, and hand on reports.",
		)
		if line := licence_line(gtx); line != "" {
			primer.text(gtx, line, .Small, color = primer.color(.Fg_Color_Muted))
		}
		if primer.link(gtx, "mordaunt.dev/leita") {
			ui.open_url(gtx, HOME_URL)
		}
		primer.text(
			gtx,
			fmt.aprintf("© %s", BUSINESS, allocator = gtx.allocator),
			.Small,
			color = primer.color(.Fg_Color_Muted),
		)
	}
	if close {
		m.about_open = false
	}
}

// about_mark is the mark at ABOUT_MARK_SIZE, in the scheme's ink, its find in sea.
@(private)
about_mark :: proc(gtx: ^ui.Ctx, loc := #caller_location) {
	p := ui.widget_open(gtx, loc = loc)
	mark.draw(gtx, {0, 0}, ABOUT_MARK_SIZE, primer.color(.Fg_Color_Default), mark.SEA)
	ui.widget_close(gtx, &p, {size = {ABOUT_MARK_SIZE, ABOUT_MARK_SIZE}})
}

// licence_line is the licence leita runs under, in a line, as the licence
// dialog says it: whose, or free for personal use and how long the trial has
// left; "" until the host says.
@(private)
licence_line :: proc(gtx: ^ui.Ctx) -> string {
	r, _ := ui.need(gtx, query.Licence{}, query.Licence_Result)
	switch {
	case r == nil:
		return ""
	case r.licensed:
		return licensed_to(gtx, r)
	case r.trial_left > 0:
		return fmt.aprintf(
			"Free for personal use. %s",
			trial_left(gtx, r),
			allocator = gtx.allocator,
		)
	}
	return "Free for personal use."
}
