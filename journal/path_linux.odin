#+build linux
package journal

import "core:fmt"
import "core:strings"
import "core:sys/linux"

/*
canonical is path as the recorder spells the directories it records: opened, then
read back through /proc/self/fd, so links are followed and the spelling is the
kernel's. In allocator; not ok when path cannot be opened.
*/
canonical :: proc(path: string, allocator := context.allocator) -> (out: string, ok: bool) {
	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	fd, err := linux.open(cpath, {.PATH, .CLOEXEC})
	if err != .NONE {
		return "", false
	}
	defer linux.close(fd)
	return fd_path(fd, allocator)
}

// fd_path is the path the open file fd names, in allocator.
@(private)
fd_path :: proc(fd: linux.Fd, allocator := context.allocator) -> (out: string, ok: bool) {
	link := fmt.ctprintf("/proc/self/fd/%d", int(fd))
	buf: [PATH_MAX]u8
	n, err := linux.readlink(link, buf[:])
	if err != .NONE || n <= 0 || n >= len(buf) {
		return "", false
	}
	return strings.clone(string(buf[:n]), allocator), true
}

// PATH_MAX is the longest path the kernel hands back (limits.h).
@(private)
PATH_MAX :: 4096

// fsid_of is the id statfs(2) gives the filesystem path is on, which names its log.
fsid_of :: proc(path: string) -> (fsid: [2]i32, ok: bool) {
	st: linux.Stat_FS
	if linux.statfs(strings.clone_to_cstring(path, context.temp_allocator), &st) != .NONE {
		return {}, false
	}
	return st.fsid, true
}
