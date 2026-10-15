package btrfs

Error :: enum {
	None,
	// The path is not on btrfs, or the kernel has no TREE_SEARCH_V2.
	Not_Btrfs,
	// TREE_SEARCH_V2 needs CAP_SYS_ADMIN: the caller falls back to the walk.
	Not_Permitted,
	Not_Found,
	Io,
	Malformed,
	Out_Of_Memory,
	// Not Linux.
	Unsupported,
}

// Visit is handed each regular file measured, with what st_blocks claims for it.
Visit :: #type proc(path: string, f: ^File, blocks: u64, data: rawptr)
