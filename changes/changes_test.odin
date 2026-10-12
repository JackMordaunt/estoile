package changes

import "core:testing"

// A path is under a place at a separator, never part way through a name.
@(test)
test_under_splits_at_a_separator :: proc(t: ^testing.T) {
	when ODIN_OS == .Windows {
		place :: `C:\Users\me`
		S     :: `\`
	} else {
		place :: "/home/me"
		S     :: "/"
	}
	cases := []struct {
		path: string,
		rest: string,
		ok:   bool,
	} {
		{place, "", true},
		{place + S, "", true},
		{place + S + "a" + S + "b", "a" + S + "b", true},
		{place + "x" + S + "a", "", false},
		{"elsewhere", "", false},
	}
	for c in cases {
		rest, ok := under(place, c.path)
		testing.expectf(t, ok == c.ok && rest == c.rest, "%q: %q %v", c.path, rest, ok)
	}
	// A root place holds everything on it.
	when ODIN_OS == .Windows {
		rest, ok := under(`C:\`, `C:\a`)
	} else {
		rest, ok := under("/", "/a")
	}
	testing.expectf(t, ok && rest == "a", "under the root: %q %v", rest, ok)
}

// Windows and macOS compare paths with letters folded, as their filesystems do.
@(test)
test_under_folds_case_where_the_filesystem_does :: proc(t: ^testing.T) {
	folds := ODIN_OS == .Windows || ODIN_OS == .Darwin
	rest, ok := under("/Place", "/place/a")
	testing.expect_value(t, ok, folds)
	testing.expect_value(t, rest, "a" if folds else "")
}
