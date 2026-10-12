package leita_msg

import "core:os"
import "core:slice"
import "core:strings"

import "jm:i18n"

/*
system_locale is the language the window opens in: the first of the system's
preferred languages it offers, else English.

The preference read is GNU gettext's LANGUAGE list, then the first of LC_ALL,
LC_MESSAGES and LANG that is set, the order POSIX gives them (XBD 8.2); "C" and
"POSIX" name no language. On Windows, the user's locale follows
(GetUserDefaultLocaleName). Nothing else is asked of macOS, so there a window
started without LANG opens in English.
*/
system_locale :: proc() -> i18n.Locale {
	tags := make([dynamic]string, context.temp_allocator)
	posix := ""
	for name in ([3]string{"LC_ALL", "LC_MESSAGES", "LANG"}) {
		if value := os.get_env(name, context.temp_allocator); value != "" {
			posix = value
			break
		}
	}
	if posix != "C" && posix != "POSIX" && !strings.has_prefix(posix, "C.") {
		list := os.get_env("LANGUAGE", context.temp_allocator)
		for tag in strings.split_iterator(&list, ":") {
			append(&tags, tag)
		}
		append(&tags, posix)
	}
	when ODIN_OS == .Windows {
		append(&tags, user_locale())
	}
	return pick_locale(tags[:], OFFERED[:])
}

// pick_locale is the first of tags, BCP 47 or POSIX, naming one of offer,
// else English.
pick_locale :: proc(tags: []string, offer: []i18n.Locale) -> i18n.Locale {
	for tag in tags {
		if locale, ok := i18n.locale_match(tag); ok && slice.contains(offer, locale) {
			return locale
		}
	}
	return .English
}
