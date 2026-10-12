package leita_app

import "core:fmt"

import "jm:i18n"

import "../../settings"
import "../command"
import "../query"

/*
What the person chose, kept between runs in the settings store beside the
history store: the language picked from the toolbar's menu and the theme. The
window asks for them once (query.Settings) and opens as they were left; each
choice it sends is written at once.

A store that cannot be opened leaves the window at its defaults for the session:
nothing else depends on it.
*/

// settings_open opens the store at path, or leaves settings unkept for "".
settings_open :: proc(d: ^Desk, path: string) {
	if path == "" {
		return
	}
	st := new(settings.Store)
	if err := settings.open(st, path); err != nil {
		fmt.eprintln("leita: settings will not be kept:", path, err)
		free(st)
		return
	}
	d.settings = st
}

settings_close :: proc(d: ^Desk) {
	if d.settings != nil {
		settings.close(d.settings)
		free(d.settings)
		d.settings = nil
	}
}

settings_answer :: proc(d: ^Desk) -> query.Settings_Result {
	r: query.Settings_Result
	if d.settings == nil {
		return r
	}
	if tag, ok := settings.get(d.settings, settings.LANGUAGE, context.temp_allocator); ok {
		r.language = tag
	}
	if theme, ok := settings.get(d.settings, settings.THEME, context.temp_allocator); ok {
		switch theme {
		case "light":
			r.theme = .Light
		case "dark":
			r.theme = .Dark
		}
	}
	return r
}

// remember_language keeps the language the person picked.
remember_language :: proc(d: ^Desk, c: command.Language) {
	if d.settings == nil || !c.chosen || int(c.locale) >= len(i18n.Locale) {
		return
	}
	keep_setting(d, settings.LANGUAGE, i18n.locale_tag(i18n.Locale(c.locale)))
}

// remember_theme keeps the theme the person picked.
remember_theme :: proc(d: ^Desk, c: command.Theme) {
	if d.settings == nil {
		return
	}
	keep_setting(d, settings.THEME, "dark" if c.dark else "light")
}

@(private = "file")
keep_setting :: proc(d: ^Desk, key, value: string) {
	if err := settings.set(d.settings, key, value); err != nil {
		fmt.eprintln("leita: could not keep the setting", key, err)
	}
}
