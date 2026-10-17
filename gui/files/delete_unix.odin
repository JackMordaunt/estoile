#+build linux, darwin
package leita_files

import "core:strings"
import "core:sys/posix"

/*
held_alone is the space deleting the entry at path gives back, as the scan charged
it: a regular file's blocks, counted in 512 byte units whatever the filesystem
builds them from, and nothing for anything else, which the walk charges nothing. A
file with another name keeps its blocks until the last name goes, so it gives back
nothing until it is down to one; a tree holding both names frees them once, as the
scan charged them once.
*/
@(private)
held_alone :: proc(path: string) -> u64 {
	st: posix.stat_t
	if posix.lstat(strings.clone_to_cstring(path, context.temp_allocator), &st) != .OK {
		return 0
	}
	if !posix.S_ISREG(st.st_mode) || st.st_nlink > 1 {
		return 0
	}
	return u64(st.st_blocks) * 512
}
