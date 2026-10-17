#+build !windows
package home

import "core:os"
import "core:strings"
import "core:testing"

// HOME points the user elsewhere, as a test's fixture home or a shell does,
// unless sudo says who the person really is.
@(test)
home_points_the_user_elsewhere :: proc(t: ^testing.T) {
	was := strings.clone(os.get_env("HOME", context.temp_allocator), context.temp_allocator)
	sudo := strings.clone(
		os.get_env("SUDO_USER", context.temp_allocator),
		context.temp_allocator,
	)
	testing.expect(t, os.set_env("HOME", "/tmp/elsewhere") == nil)
	os.unset_env("SUDO_USER")
	defer {
		os.set_env("HOME", was)
		if sudo != "" {
			os.set_env("SUDO_USER", sudo)
		}
	}
	u := user()
	defer user_destroy(&u)
	testing.expect_value(t, u.dir, "/tmp/elsewhere")
	testing.expect(t, u.uid != "", "the process's own id")

	// The person sudo names comes first: root's entry is in every passwd.
	testing.expect(t, os.set_env("SUDO_USER", "root") == nil)
	r := user()
	defer user_destroy(&r)
	testing.expect_value(t, r.uid, "0")
	testing.expect(t, r.dir != "/tmp/elsewhere" && r.dir != "", "root's own directory")
}
