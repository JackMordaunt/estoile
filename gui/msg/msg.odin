/*
Package msg is everything leita's window says, in every language it offers: the
Msg enum names each message, and locales/<tag>.txt holds each language's text,
embedded in the binary by #load and parsed by jm:i18n when the language is put
to use. English is the source language and the fallback for any message a
translation leaves out.

A line of a locale's text is `key = text`, the key the member's name in lower
case; `key.one = text` is one plural form (zero, one, two, few, many, other) and
a bare key the other form. {0} to {9} are arguments, {{ a literal brace. A
message whose argument 0 is a count is plural, and picks its form by it.

To add a message, add its member here and its line to locales/en.txt; msg_test
fails until every other locale translates it.

Both halves of the window read it: the view for what it draws, and the host for
the notices and problems it words.
*/
package leita_msg

import "jm:i18n"

Msg :: enum u16 {
	Language,
}

// OFFERED are the languages the window offers, in the order its menu lists
// them: English first, then by how many read each.
@(rodata)
OFFERED := [?]i18n.Locale{.English}

// SOURCES is each offered language's text; a language without one is not
// offered.
@(rodata)
SOURCES := #partial [i18n.Locale]string {
	.English = #load("locales/en.txt", string),
}

// Strings is the text the window shows: English, loaded once as the base, and
// the language in use, whose gaps load fills from it. Nothing is allocated.
Strings :: struct {
	base:   i18n.Table(Msg),
	active: i18n.Table(Msg),
}

// init loads English and then locale.
init :: proc(s: ^Strings, locale: i18n.Locale) {
	i18n.load(&s.base, .English, SOURCES[.English])
	use(s, locale)
}

// use puts locale in use; one not offered falls back to English.
use :: proc(s: ^Strings, locale: i18n.Locale) {
	chosen := offered(locale) ? locale : .English
	i18n.load(&s.active, chosen, SOURCES[chosen], &s.base)
}

// offered is whether the window has locale's text.
offered :: proc(locale: i18n.Locale) -> bool {
	return SOURCES[locale] != ""
}

// locale is the language in use.
locale :: proc(s: ^Strings) -> i18n.Locale {
	return i18n.table_locale(&s.active)
}

// tr is key's text, with no arguments: a string that lives as long as the
// program.
tr :: proc(s: ^Strings, key: Msg) -> string {
	return i18n.text(&s.active, key)
}

// trf is key's text with args filled in, in allocator: the frame's, in the
// view. An int argument is written in the language's digits and grouping.
trf :: proc(
	s: ^Strings,
	key: Msg,
	args: ..i18n.Arg,
	allocator := context.temp_allocator,
) -> string {
	return i18n.format(&s.active, key, ..args, allocator = allocator)
}
