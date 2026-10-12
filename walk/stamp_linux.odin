#+build linux
package walk

import "core:sys/linux"

/*
Whether the directory at `path` changed at or after `since`, nanoseconds since the
epoch: whether its entries may differ from when it was last read. Adding, removing or
renaming an entry moves a directory's modification time; its change time moves with
anything done to it and, unlike the modification time, utimensat cannot set it back
(inode(7)), so the later of the two is what counts.
A directory that cannot be asked counts as changed, so it is read rather than trusted.
*/
@(private)
changed_since :: proc(path: string, since: i64) -> bool {
	buf: Path
	cpath, ok := terminate(path, &buf)
	if !ok {
		return true
	}
	st: linux.Statx
	if linux.statx(linux.AT_FDCWD, cpath, {}, {.MTIME, .CTIME}, &st) != .NONE {
		return true
	}
	stamp :: proc(ts: linux.Statx_Timestamp) -> i64 {
		return ts.sec * 1_000_000_000 + i64(ts.nsec)
	}
	return max(stamp(st.mtime), stamp(st.ctime)) >= since
}

// What the file at `path` occupies now, as a walk would charge it, and whether it is
// still there to ask.
@(private)
disk_of :: proc(path: string) -> (disk: u64, ok: bool) {
	buf: Path
	cpath, terminated := terminate(path, &buf)
	if !terminated {
		return 0, false
	}
	st: linux.Statx
	if linux.statx(linux.AT_FDCWD, cpath, {.SYMLINK_NOFOLLOW}, {.BLOCKS}, &st) != .NONE {
		return 0, false
	}
	return st.blocks * 512, true
}
