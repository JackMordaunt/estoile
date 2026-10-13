#+build darwin
package walk

import "core:c"

foreign import libc "system:System"

// FSEvents is macOS's change journal, so a probe here says every directory changed,
// and the update reads them all, as a walk would.
@(private)
changed_since :: proc(path: string, since: i64) -> bool {
	return true
}

/*
What the file at `path` holds on disk now, asked as read_dir asks it: the allocated
size of all its forks, the link itself for a symlink. Not found when it is gone or
cannot be asked, and then dropped, as a read would not find it either.
*/
@(private)
disk_of :: proc(path: string, was: u64) -> (disk: u64, found: bool) {
	buf: Path
	cpath, terminated := terminate(path, &buf)
	if !terminated {
		return 0, false
	}
	request := Attr_List {
		bitmapcount = ATTR_BIT_MAP_COUNT,
		fileattr    = ATTR_FILE_ALLOCSIZE,
	}
	// A u32 length, then the off_t, packed at four-byte alignment (getattrlist(2)).
	reply: struct #packed {
		length:    u32,
		allocated: i64,
	}
	if getattrlist(cpath, &request, &reply, size_of(reply), FSOPT_NOFOLLOW) != 0 {
		return 0, false
	}
	if reply.length < size_of(reply) {
		return 0, false
	}
	return u64(max(reply.allocated, 0)), true
}

@(private = "file")
FSOPT_NOFOLLOW :: 0x00000001

@(private = "file", default_calling_convention = "c")
foreign libc {
	getattrlist :: proc(path: cstring, al: ^Attr_List, buf: rawptr, n: uint, opt: c.uint) -> c.int ---
}
