package leita_view

import "core:testing"

import "jm:i18n"

// Spans and dates are said in words, a count picking the plural form.
@(test)
spans_and_dates_are_said_in_words :: proc(t: ^testing.T) {
	day :: 24 * 60 * 60
	defer free_all(context.temp_allocator)
	testing.expect_value(t, ago(60), "today")
	testing.expect_value(t, ago(day + 60), "yesterday")
	testing.expect_value(t, ago(3 * day), "3 days ago")
	testing.expect_value(t, ago(90 * day), "3 months ago")
	testing.expect_value(t, ago(400 * day), "13 months ago")
	testing.expect_value(t, ago(800 * day), "2 years ago")
	testing.expect_value(t, date_text(30, .September, "23:59", .Date_Time), "30 Sep 23:59")
	testing.expect_value(t, date_text(1, .January, "2025", .Date_Year), "1 Jan 2025")
}

// Choosing a language puts its text in use for the frames that follow, each
// count taking the form its language's rules give it; a language not offered
// is English.
@(test)
set_language_switches_the_text_in_use :: proc(t: ^testing.T) {
	day :: 24 * 60 * 60
	m: Model
	model_init(&m, "/")
	defer model_destroy(&m)
	defer free_all(context.temp_allocator)
	words = m.strings
	defer words = nil

	set_language(&m, .Russian)
	testing.expect_value(t, m.locale, i18n.Locale.Russian)
	testing.expect(t, tr(.Done) != "Done", "Russian in use")
	one, few, many := ago(21 * day), ago(22 * day), ago(25 * day)
	testing.expectf(
		t,
		one[2:] != few[2:] && few[2:] != many[2:],
		"three forms: %q %q %q",
		one,
		few,
		many,
	)

	set_language(&m, .Chinese_Traditional)
	testing.expect_value(t, m.locale, i18n.Locale.English)
	testing.expect_value(t, tr(.Done), "Done")
}
