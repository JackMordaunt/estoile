package leita_view

import "base:runtime"

import "jm:i18n"
import "jm:ui"
import "jm:ui/primer"

import "../command"
import "../msg"

/*
The window's language. Language in the settings menu opens a submenu of the languages leita
offers, each by its own name, since a reader looks for theirs that way; a choice
switches the whole window from the next frame. The window opens in the system's
language (msg.system_locale), or the one the person picked in an earlier run,
which the host keeps (settings.odin).

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

// current is the language in use on this thread: the frame's, or English.
@(private)
current :: proc() -> ^msg.Strings {
	return words if words != nil else &english
}

// tr is key's text in the language in use: a string that lives as long as the
// program.
@(private)
tr :: proc(key: msg.Msg) -> string {
	return msg.tr(current(), key)
}

// trf is key's text in the language in use with args filled in, in the frame's
// allocator. An int is written in the language's digits, and as argument 0 picks
// the plural form.
@(private)
trf :: proc(gtx: ^ui.Ctx, key: msg.Msg, args: ..i18n.Arg) -> string {
	return msg.trf(current(), key, ..args, allocator = gtx.allocator)
}

// language_item is the settings menu's Language and the submenu of languages
// it opens. The submenu is drawn after every other item of the menu, as
// primer.action_menu_submenu_open asks (jm/ui/primer/menus.odin), so
// settings_menu calls language_menu.
@(private)
language_item :: proc(menu: ^primer.Action_Menu, m: ^Model) {
	primer.action_menu_item(menu, tr(.Language), leading = .Globe, submenu = &m.language_open)
}

// language_menu is the submenu of languages that language_item opens.
@(private)
language_menu :: proc(gtx: ^ui.Ctx, parent: ^primer.Action_Menu, m: ^Model) {
	menu := primer.action_menu_submenu_open(parent, &m.language_open, selection = .Single)
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
			// Picked, so the host keeps it for the next run.
			ui.command(
				gtx,
				command.Command(command.Language{locale = u8(m.locale), chosen = true}),
			)
			m.locale_told = m.locale
		}
	}
}

// tell_language sends the host the window's language, on the first frame and
// on every change (the host's set_language, gui/app/words.odin).
@(private)
tell_language :: proc(gtx: ^ui.Ctx, m: ^Model) {
	if told, ok := m.locale_told.?; ok && told == m.locale {
		return
	}
	ui.command(gtx, command.Command(command.Language{locale = u8(m.locale)}))
	m.locale_told = m.locale
}

// set_language puts locale in use from the next frame.
set_language :: proc(m: ^Model, locale: i18n.Locale) {
	m.locale = locale
	if m.strings != nil {
		msg.use(m.strings, locale)
		m.locale = msg.locale(m.strings)
	}
}
