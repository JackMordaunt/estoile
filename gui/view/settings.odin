package leita_view

import "jm:i18n"
import "jm:ui"

import "../query"

/*
The window opens as the person left it: the language they picked and the theme
they chose, which the host keeps between runs (gui/app/settings.odin). The view
asks once; until the answer comes, and for anything never chosen, it keeps its
defaults, the system's language and the light theme. Each choice is sent to the
host as it is made (language_button, the theme toggle).
*/

// recall_settings puts what the person chose in an earlier run in use, once.
@(private)
recall_settings :: proc(gtx: ^ui.Ctx, m: ^Model) {
	if m.settings_read {
		return
	}
	r, _ := ui.need(gtx, query.Settings{}, query.Settings_Result)
	if r == nil {
		return
	}
	m.settings_read = true
	if r.language != "" {
		if locale, ok := i18n.locale_match(r.language); ok {
			set_language(m, locale)
		}
	}
	switch r.theme {
	case .Light:
		m.dark = false
	case .Dark:
		m.dark = true
	case .Unset:
	}
}
