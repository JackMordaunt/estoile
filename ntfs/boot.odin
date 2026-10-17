package ntfs

import "core:math/bits"

Boot_Sector :: struct {
	bytes_per_sector:    u32,
	sectors_per_cluster: u32,
	bytes_per_cluster:   u32,
	total_sectors:       u64,
	mft_lcn:             u64, // first cluster of $MFT
	mft_mirror_lcn:      u64,
	record_size:         u32, // bytes per FILE record, normally 1024
	index_block_size:    u32, // bytes per directory index block, normally 4096
	serial:              u64,
}

/*
Parse the first sector of an NTFS volume. `b` must hold at least 512 bytes.

Sectors-per-cluster and clusters-per-record are single bytes. A sectors-per-cluster
byte above 0x80 means 2^(256-v) sectors (0xF4 is 2^12 sectors, a 2 MiB cluster).
0x80 is not above 0x80, so it is the literal 128: 128 sectors of 512 bytes is the
64 KiB cluster, which is what Windows writes for one. A clusters-per-record byte at
or above 0x80 is a size in bytes, so 0xF6 is 2^10 = 1024. A shift of 32 or more does
not fit in these fields. Shifted anyway, a count of 128 is taken mod 32 and becomes
1, so that boot sector is rejected instead.
*/
parse_boot_sector :: proc(b: []byte) -> (bs: Boot_Sector, err: Error) {
	if len(b) < 512 {
		return {}, .Bad_Boot_Sector
	}
	if string(b[3:11]) != "NTFS    " {
		return {}, .Not_Ntfs
	}
	if b[0x1FE] != 0x55 || b[0x1FF] != 0xAA {
		return {}, .Bad_Boot_Sector
	}

	bs.bytes_per_sector = u32(rd16(b, 0x0B))
	spc, spc_ok := decode_shift_byte(b[0x0D])
	if !spc_ok {
		return {}, .Bad_Boot_Sector
	}
	bs.sectors_per_cluster = spc
	bs.total_sectors = rd64(b, 0x28)
	bs.mft_lcn = rd64(b, 0x30)
	bs.mft_mirror_lcn = rd64(b, 0x38)
	bs.serial = rd64(b, 0x48)

	if bs.bytes_per_sector < 256 || bs.bytes_per_sector > 4096 || !is_pow2(bs.bytes_per_sector) {
		return {}, .Bad_Boot_Sector
	}
	if bs.sectors_per_cluster == 0 || !is_pow2(bs.sectors_per_cluster) {
		return {}, .Bad_Boot_Sector
	}
	// 512 * 2^23 is 2^32. Wrapped, that is a cluster size of 0, and the record-size
	// checks still pass, so the multiply has to be refused on its own.
	product, wrapped := bits.overflowing_mul(bs.bytes_per_sector, bs.sectors_per_cluster)
	if wrapped {
		return {}, .Bad_Boot_Sector
	}
	bs.bytes_per_cluster = product

	record, record_ok := decode_size_byte(b[0x40], bs.bytes_per_cluster)
	index, index_ok := decode_size_byte(b[0x44], bs.bytes_per_cluster)
	if !record_ok || !index_ok {
		return {}, .Bad_Boot_Sector
	}
	bs.record_size = record
	bs.index_block_size = index

	// A record must be a whole number of sectors so it can be read directly from the
	// volume, and at least two fixup blocks so the update sequence array has something
	// to protect.
	if bs.record_size < 512 ||
	   !is_pow2(bs.record_size) ||
	   bs.record_size % bs.bytes_per_sector != 0 {
		return {}, .Bad_Boot_Sector
	}
	if bs.mft_lcn == 0 || bs.total_sectors == 0 {
		return {}, .Bad_Boot_Sector
	}
	// Cluster numbers run from 0. An LCN at or past the volume's cluster count names
	// a cluster the volume does not have, and the MFT read would start off the end.
	if bs.mft_lcn >= bs.total_sectors / u64(bs.sectors_per_cluster) {
		return {}, .Bad_Boot_Sector
	}
	return bs, .None
}

// Sectors per cluster. v <= 0x80 is the literal count, so 0x80 is 128 sectors and not
// a shift of 128. A byte above that is 2^(256-v); a shift of 32 or more does not fit
// in the u32 and is refused rather than shifted.
@(private)
decode_shift_byte :: proc "contextless" (v: byte) -> (n: u32, ok: bool) {
	if v <= 0x80 {
		return u32(v), true
	}
	shift := 256 - uint(v)
	if shift >= 32 {
		return 0, false
	}
	return u32(1) << shift, true
}

// Clusters-per-record fields. Below 0x80 the byte is a cluster count; at or above it
// the byte is a size in bytes, 2^(256-v), so 0x80 itself is 2^128 and not a count.
// A shift of 32 or more, or a cluster count whose byte size wraps, is refused.
@(private)
decode_size_byte :: proc "contextless" (v: byte, bytes_per_cluster: u32) -> (n: u32, ok: bool) {
	if v < 0x80 {
		product, wrapped := bits.overflowing_mul(u32(v), bytes_per_cluster)
		if wrapped {
			return 0, false
		}
		return product, true
	}
	shift := 256 - uint(v)
	if shift >= 32 {
		return 0, false
	}
	return u32(1) << shift, true
}

@(private)
is_pow2 :: proc "contextless" (v: u32) -> bool {
	return v != 0 && bits.count_ones(v) == 1
}
