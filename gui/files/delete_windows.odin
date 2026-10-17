#+build windows
package leita_files

import "base:runtime"

import "core:os"

/*
remove_tree deletes the directory at path and everything in it: how many entries
it could not delete, as delete_tree counts them, and the bytes the ones it did gave
back. A directory that stays is given back the mode it had, so a failed delete does
not leave a read-only cache writable. It goes by path, and is_link tells a link or
junction from a directory, as the listing's own type does not (is_link). A volume
mounted in a folder is a reparse point tagged IO_REPARSE_TAG_MOUNT_POINT, the tag a
junction has ("Reparse Point Tags" in Microsoft's file system documentation), so
is_link passes it over as it does a junction.
*/
@(private)
remove_tree :: proc(path: string) -> (failed: int, freed: u64, err: Error) {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	info, serr := os.stat_do_not_follow_links(path, context.temp_allocator)
	if serr != nil {
		return 1, 0, .None
	}
	writable := info.mode + {.Read_User, .Write_User, .Execute_User}
	opened := writable != info.mode && os.change_mode(path, writable) == nil
	defer if opened && os.exists(path) {
		_ = os.change_mode(path, info.mode)
	}
	entries, lerr := os.read_all_directory_by_path(path, context.temp_allocator)
	if lerr != nil {
		return 1, 0, .None
	}
	for e in entries {
		if e.type == .Directory && !is_link(e.fullpath) {
			f, b, _ := remove_tree(e.fullpath)
			failed, freed = failed + f, freed + b
			continue
		}
		bytes := held_alone(e.fullpath)
		if os.remove(e.fullpath) == nil {
			freed += bytes
		} else {
			failed += 1
		}
	}
	if failed > 0 {
		// Kept because it holds what is counted already.
		return
	}
	if os.remove(path) != nil {
		return 1, freed, .None
	}
	return 0, freed, .None
}

// held_alone is the space deleting the entry at path gives back, as far as its
// length says: os.File_Info carries no allocated size (core/os/stat.odin).
@(private)
held_alone :: proc(path: string) -> u64 {
	info, err := os.stat_do_not_follow_links(path, context.temp_allocator)
	if err != nil || info.type != .Regular {
		return 0
	}
	return u64(max(info.size, 0))
}
