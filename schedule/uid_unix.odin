#+build linux, darwin, freebsd, openbsd, netbsd
package leita_schedule

import "core:fmt"
import "core:strings"
import "core:sys/posix"

// user_id is this process's user id, as launchctl's gui/<uid> domain names it.
user_id :: proc(allocator := context.allocator) -> string {
	// Cloned, so it is freed at the size it was made at.
	return strings.clone(fmt.tprint(u32(posix.getuid())), allocator)
}
