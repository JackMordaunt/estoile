#+build !linux
package walk

import "core:mem"

import "../scan"

// Only the Linux reader searches btrfs extents, so elsewhere a walk has nothing to search.
@(private)
Btrfs_Search :: struct {}

@(private)
btrfs_search_init :: proc(s: ^Btrfs_Search, t: ^scan.Tree, allocator: mem.Allocator) {}

@(private)
btrfs_search_destroy :: proc(s: ^Btrfs_Search) {}
