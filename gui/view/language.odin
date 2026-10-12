package leita_view

import "base:runtime"

import "jm:i18n"
import "jm:ui"
import "jm:ui/primer"

import "../msg"

/*
The window's language. The toolbar's globe opens a menu of the languages leita
offers, each by its own name, since a reader looks for theirs that way; a choice
switches the whole window from the next frame. The window opens in the system's
language (msg.system_locale), and a choice lasts until leita closes: the view
keeps nothing between runs.

Every string the view draws comes through tr and trf, which read the language
in use this frame on this thread, as primer.use's scheme is read: view sets it
from the Model before it draws. A part drawn without view, as a test draws one,
reads English.
*/

@(private, thread_local)
words: ^msg.Strings

// english is what tr reads where view has set no language.
@(private)
english: msg.Strings

@(private, init)
english_init :: proc "contextless" () {
	context = runtime.default_context()
	msg.init(&english, .English)
}

// tr is key's text in the language in use: a string that lives as long as the
// program.
@(private)
tr :: proc(key: msg.Msg) -> string {
	return msg.tr(words if words != nil else &english, key)
}

// trf is key's text in the language in use with args filled in, in the frame's
// allocator. An int is written in the language's digits, and as argument 0 picks
// the plural form.
@(private)
trf :: proc(gtx: ^ui.Ctx, key: msg.Msg, args: ..i18n.Arg) -> string {
	return msg.trf(words if words != nil else &english, key, ..args, allocator = gtx.allocator)
}

// language_button is the toolbar's globe and the menu of languages it opens.
@(private)
language_button :: proc(gtx: ^ui.Ctx, m: ^Model) {
	// The menu hangs from the globe, drawn after it in one stack, as
	// primer.action_menu_button asks of its menu.
	ui.stack(gtx)
	if primer.icon_button(gtx, .Globe, tr(.Language), .Invisible, expanded = m.language_open) {
		m.language_open = !m.language_open
	}
	menu := primer.action_menu_open(
		gtx,
		&m.language_open,
		ui.last_widget(gtx),
		selection = .Single,
		align = .End,
		name = tr(.Language),
	)
	defer primer.action_menu_close(&menu)
	if !menu.visible {
		return
	}
	for locale in msg.OFFERED {
		if primer.action_menu_item(
			&menu,
			i18n.locale_name(locale),
			selected = locale == m.locale,
		) {
			set_language(m, locale)
		}
	}
}

// set_language puts locale in use from the next frame.
set_language :: proc(m: ^Model, locale: i18n.Locale) {
	m.locale = locale
	if m.strings != nil {
		msg.use(m.strings, locale)
		m.locale = msg.locale(m.strings)
	}
}
