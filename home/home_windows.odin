#+build windows
package home

import "core:os"

// user is the person at the keyboard: their profile directory, which USERPROFILE
// names, or HOME where a shell sets it instead. No user id: Reclaim looks for a
// per-user Trash by id only in a macOS volume's .Trashes.
user :: proc(allocator := context.allocator) -> User {
	dir := os.get_env("USERPROFILE", allocator)
	if dir == "" {
		dir = os.get_env("HOME", allocator)
	}
	return {dir, ""}
}

// user_destroy frees what user made.
user_destroy :: proc(u: ^User, allocator := context.allocator) {
	delete(u.dir, allocator)
	delete(u.uid, allocator)
}
