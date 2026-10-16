#+build linux, darwin, freebsd, openbsd, netbsd
package home

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"

// user is the person at the keyboard, as the package doc has it, in allocator.
user :: proc(allocator := context.allocator) -> User {
	if name := os.get_env("SUDO_USER", context.temp_allocator); name != "" {
		cname := strings.clone_to_cstring(name, context.temp_allocator)
		if pw := posix.getpwnam(cname); pw != nil && pw.pw_dir != nil {
			return {
				dir = strings.clone(string(pw.pw_dir), allocator),
				uid = strings.clone(fmt.tprint(u32(pw.pw_uid)), allocator),
			}
		}
	}
	uid := strings.clone(fmt.tprint(u32(posix.getuid())), allocator)
	if dir := os.get_env("HOME", allocator); dir != "" {
		return {dir, uid}
	}
	if pw := posix.getpwuid(posix.getuid()); pw != nil && pw.pw_dir != nil {
		return {strings.clone(string(pw.pw_dir), allocator), uid}
	}
	return {"", uid}
}

// user_destroy frees what user made.
user_destroy :: proc(u: ^User, allocator := context.allocator) {
	delete(u.dir, allocator)
	delete(u.uid, allocator)
}
