package leita_view

import "core:testing"

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
