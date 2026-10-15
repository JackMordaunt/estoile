package btrfs

import "core:encoding/endian"
import "core:testing"

// A file extent item as the tree search returns it: inline when at is never asked
// for, so the data follows the header.
@(private = "file")
item :: proc(kind, compression: u8, ram: u64, at, disk, refers: u64, inline_len := 0) -> []u8 {
	size := ITEM_SIZE if kind != EXTENT_INLINE else ITEM_INLINE_HEADER + inline_len
	b := make([]u8, size, context.temp_allocator)
	endian.put_u64(b[8:16], .Little, ram)
	b[16] = compression
	b[20] = kind
	if kind != EXTENT_INLINE {
		endian.put_u64(b[21:29], .Little, at)
		endian.put_u64(b[29:37], .Little, disk)
		endian.put_u64(b[45:53], .Little, refers)
	}
	return b
}

@(private = "file")
EXTENT_REGULAR :: 1

// An inline extent is charged what the item holds on disk and its uncompressed
// length otherwise, to its file alone.
@(test)
test_inline_is_charged_to_its_file :: proc(t: ^testing.T) {
	u: Usage
	defer usage_destroy(&u)
	f: File
	defer file_destroy(&f)
	testing.expect_value(
		t,
		charge(item(EXTENT_INLINE, 3, 3000, 0, 0, 0, 120), &u, &f),
		Item_Error.None,
	)
	testing.expect_value(t, u.by[.Zstd], Sizes{120, 3000, 3000})
	testing.expect_value(t, f.sizes, Sizes{120, 3000, 3000})
	testing.expect_value(t, f.charged, 120)
	testing.expect_value(t, u.inline, 1)
}

/*
A compressed extent is charged its compressed size once. A reflinked copy refers
to it again: the copy's own sizes include it and it is marked shared, but the run
charges nothing more than its referenced bytes.
*/
@(test)
test_shared_extent_is_charged_once :: proc(t: ^testing.T) {
	u: Usage
	defer usage_destroy(&u)
	a, b: File
	defer file_destroy(&a)
	defer file_destroy(&b)
	x := item(EXTENT_REGULAR, 3, 131072, 1 << 20, 4096, 131072)
	testing.expect_value(t, charge(x, &u, &a), Item_Error.None)
	testing.expect_value(t, charge(x, &u, &b), Item_Error.None)
	testing.expect_value(t, u.by[.Zstd], Sizes{4096, 131072, 262144})
	testing.expect_value(t, u.extents, 1)
	testing.expect_value(t, u.refs, 2)
	testing.expect_value(t, a.sizes, Sizes{4096, 131072, 131072})
	testing.expect_value(t, b.sizes, Sizes{4096, 131072, 131072})
	testing.expect_value(t, a.charged, 4096)
	testing.expect_value(t, b.charged, 0)
	testing.expect(t, !a.shared, "the first file to meet an extent does not share it")
	testing.expect(t, b.shared, "a reflinked copy shares its extent")
}

// An extent split by an overwrite is referred to twice by one file, which is
// charged for it once and does not share it.
@(test)
test_split_extent_is_not_shared :: proc(t: ^testing.T) {
	u: Usage
	defer usage_destroy(&u)
	f: File
	defer file_destroy(&f)
	testing.expect_value(
		t,
		charge(item(EXTENT_REGULAR, 0, 8192, 1 << 20, 8192, 4096), &u, &f),
		Item_Error.None,
	)
	testing.expect_value(
		t,
		charge(item(EXTENT_REGULAR, 0, 4096, 2 << 20, 4096, 4096), &u, &f),
		Item_Error.None,
	)
	testing.expect_value(
		t,
		charge(item(EXTENT_REGULAR, 0, 8192, 1 << 20, 8192, 4096), &u, &f),
		Item_Error.None,
	)
	testing.expect_value(t, f.sizes, Sizes{12288, 12288, 12288})
	testing.expect_value(t, f.charged, 12288)
	testing.expect(t, !f.shared, "a file does not share an extent with itself")
}

// A hole is charged nothing; a preallocated extent is kept apart; a short item is
// refused.
@(test)
test_holes_prealloc_and_short_items :: proc(t: ^testing.T) {
	u: Usage
	defer usage_destroy(&u)
	f: File
	defer file_destroy(&f)
	testing.expect_value(
		t,
		charge(item(EXTENT_REGULAR, 0, 1 << 20, 0, 0, 1 << 20), &u, &f),
		Item_Error.None,
	)
	testing.expect_value(t, total(u), Sizes{})
	testing.expect_value(t, u.refs, 0)
	testing.expect_value(
		t,
		charge(item(EXTENT_PREALLOC, 0, 4096, 1 << 20, 4096, 4096), &u, &f),
		Item_Error.None,
	)
	testing.expect_value(t, u.by[.Prealloc], Sizes{4096, 4096, 4096})
	testing.expect_value(
		t,
		charge(item(EXTENT_REGULAR, 0, 0, 0, 0, 0)[:30], &u, &f),
		Item_Error.Short,
	)
	testing.expect_value(
		t,
		charge(item(EXTENT_REGULAR, 9, 4096, 3 << 20, 4096, 4096), &u, &f),
		Item_Error.Compression,
	)
}
