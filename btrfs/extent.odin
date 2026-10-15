package btrfs

import "core:encoding/endian"

/*
What btrfs charges a file for, read from its extent items rather than from
st_blocks, which on btrfs counts the bytes a file refers to: a compressed file is
charged its uncompressed size, and a reflinked copy or a snapshot is charged again
for extents it shares. This is compsize's accounting
(https://github.com/kilobyte/compsize), the file extent items of an inode taken
one at a time, each distinct extent charged once, where it is first met.

Three sizes, as compsize names them. Disk is what the extents occupy on disk,
compressed. Uncompressed is the same extents' size before compression.
Referenced is what the file's ranges point at, an extent counted once for every
range that points into it, holes left out.
*/
Sizes :: struct {
	disk:         u64,
	uncompressed: u64,
	referenced:   u64,
}

// How an extent is stored: btrfs_compression_type, with preallocated extents kept
// apart as compsize keeps them.
Compression :: enum u8 {
	None,
	Zlib,
	Lzo,
	Zstd,
	Prealloc,
}

/*
Usage is what a run over many files has charged so far: the sizes by how each
extent is stored, and the counts compsize prints. Seen holds every extent already
charged, by its first byte on disk, so a second reference to it, from a reflink, a
snapshot or another range of the same file, adds only to referenced.
*/
Usage :: struct {
	by:      [Compression]Sizes,
	files:   u64,
	extents: u64,
	refs:    u64,
	inline:  u64,
	// What st_blocks claims for the same files, in bytes: the naive sum a walk takes.
	blocks:  u64,
	seen:    map[u64]struct{},
}

/*
File is one file's share. Its own sizes count each distinct extent it refers to
once, what compsize reports for that file alone. Charged is the part of its disk
no file before it in the run had already been charged for; shared is set when
some of its extents had been.
*/
File :: struct {
	using sizes: Sizes,
	charged:     u64,
	shared:      bool,
	own:         map[u64]struct{},
}

usage_destroy :: proc(u: ^Usage) {
	delete(u.seen)
}

file_destroy :: proc(f: ^File) {
	delete(f.own)
}

total :: proc(u: Usage) -> (s: Sizes) {
	for c in u.by {
		s.disk += c.disk
		s.uncompressed += c.uncompressed
		s.referenced += c.referenced
	}
	return
}

// struct btrfs_file_extent_item in linux/btrfs_tree.h, packed: a 21 byte header
// (generation, ram_bytes, compression, encryption, other_encoding, type), then, unless
// the extent is inline, where it lies on disk.
@(private)
ITEM_INLINE_HEADER :: 21
@(private)
ITEM_SIZE :: 53
@(private)
EXTENT_INLINE :: 0
@(private)
EXTENT_PREALLOC :: 2

Item_Error :: enum {
	None,
	Short,
	Compression,
	Out_Of_Memory,
}

/*
Charge one file extent item, as the tree search hands it back, to the file and to
the run. A hole, an extent whose disk_bytenr is 0, is charged nothing.
*/
charge :: proc(item: []u8, u: ^Usage, f: ^File) -> Item_Error {
	if len(item) < ITEM_INLINE_HEADER {
		return .Short
	}
	ram, _ := endian.get_u64(item[8:16], .Little)
	kind := item[20]
	stored := item[16]
	if stored > u8(Compression.Zstd) {
		return .Compression
	}
	c := Compression(stored)
	if kind == EXTENT_INLINE {
		// The data lies in the item itself, after the header. It belongs to this
		// file alone.
		disk := u64(len(item) - ITEM_INLINE_HEADER)
		u.by[c].disk += disk
		u.by[c].uncompressed += ram
		u.by[c].referenced += ram
		u.inline += 1
		f.disk += disk
		f.uncompressed += ram
		f.referenced += ram
		f.charged += disk
		return .None
	}
	if len(item) < ITEM_SIZE {
		return .Short
	}
	if kind == EXTENT_PREALLOC {
		c = .Prealloc
	}
	at, _ := endian.get_u64(item[21:29], .Little)
	disk, _ := endian.get_u64(item[29:37], .Little)
	refers, _ := endian.get_u64(item[45:53], .Little)
	if at == 0 {
		return .None
	}
	u.refs += 1
	u.by[c].referenced += refers
	f.referenced += refers
	new_here := at not_in f.own
	if new_here {
		if _, _, _, err := map_entry(&f.own, at); err != nil {
			return .Out_Of_Memory
		}
		f.disk += disk
		f.uncompressed += ram
	}
	if at in u.seen {
		// Charged already: to an earlier file, which is sharing, or to this one
		// through an earlier range, which is not.
		if new_here {
			f.shared = true
		}
		return .None
	}
	if _, _, _, err := map_entry(&u.seen, at); err != nil {
		return .Out_Of_Memory
	}
	u.by[c].disk += disk
	u.by[c].uncompressed += ram
	u.extents += 1
	f.charged += disk
	return .None
}
