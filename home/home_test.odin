#+build !windows
package home

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:testing"

// HOME points the user elsewhere, as a test's fixture home or a shell does,
// unless sudo, to a process running as root, says who the person really is.
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
	testing.expect_value(t, u.uid, fmt.tprint(u32(posix.getuid())))

	// The person sudo names comes first as root: root's entry is in every passwd.
	testing.expect(t, os.set_env("SUDO_USER", "root") == nil)
	r := user_as(0)
	defer user_destroy(&r)
	testing.expect_value(t, r.uid, "0")
	testing.expect(t, r.dir != "/tmp/elsewhere" && r.dir != "", "root's own directory")

	// To a process not running as root, SUDO_USER is anyone's to set.
	n := user_as(1000)
	defer user_destroy(&n)
	testing.expect_value(t, n.dir, "/tmp/elsewhere")
	testing.expect_value(t, n.uid, u.uid)
	if posix.geteuid() != 0 {
		p := user()
		defer user_destroy(&p)
		testing.expect_value(t, p.dir, "/tmp/elsewhere")
	}
}
