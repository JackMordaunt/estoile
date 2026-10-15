/*
What btrfs charges the files under each path for, as compsize prints it, beside
the st_blocks sum a walk takes. A prototype for checking package btrfs against
compsize: run both as root on the same paths and compare.

	btrfs-du [-v] path...

-v prints each file too: its own disk, uncompressed and referenced sizes, the part
of its disk no file before it was charged for, and whether it shares extents with
one. Every size is in bytes.
*/
package main

import "core:fmt"
import "core:os"

import "../../btrfs"

main :: proc() {
	verbose := false
	paths: [dynamic]string
	defer delete(paths)
	for arg in os.args[1:] {
		if arg == "-v" {
			verbose = true
		} else {
			append(&paths, arg)
		}
	}
	if len(paths) == 0 {
		fmt.eprintln("usage: btrfs-du [-v] path...")
		os.exit(2)
	}
	u: btrfs.Usage
	defer btrfs.usage_destroy(&u)
	if verbose {
		fmt.printfln(
			"%12s %12s %12s %12s %12s %-6s %s",
			"disk",
			"uncompressed",
			"referenced",
			"charged",
			"st_blocks",
			"shared",
			"path",
		)
	}
	for path in paths {
		err := btrfs.measure(path, &u, verbose ? print_file : nil)
		if err != .None {
			fmt.eprintfln("%s: %v", path, err)
			os.exit(1)
		}
	}
	fmt.printfln(
		"Processed %d files, %d regular extents (%d refs), %d inline.",
		u.files,
		u.extents,
		u.refs,
		u.inline,
	)
	fmt.printfln(
		"%-10s %-8s %-12s %-12s %-12s",
		"Type",
		"Perc",
		"Disk Usage",
		"Uncompressed",
		"Referenced",
	)
	print_row("TOTAL", btrfs.total(u))
	for s, c in u.by {
		if s.disk != 0 || s.uncompressed != 0 || s.referenced != 0 {
			print_row(NAMES[c], s)
		}
	}
	fmt.printfln("st_blocks  %d", u.blocks)
}

// compsize's names for how an extent is stored, from comp_types and print_stats
// in compsize.c (kilobyte/compsize at d79eacf).
@(rodata)
NAMES := [btrfs.Compression]string {
	.None     = "none",
	.Zlib     = "zlib",
	.Lzo      = "lzo",
	.Zstd     = "zstd",
	.Prealloc = "prealloc",
}

print_row :: proc(name: string, s: btrfs.Sizes) {
	perc := s.uncompressed == 0 ? 0 : s.disk * 100 / s.uncompressed
	fmt.printfln(
		"%-10s %3d%%     %-12d %-12d %-12d",
		name,
		perc,
		s.disk,
		s.uncompressed,
		s.referenced,
	)
}

print_file :: proc(path: string, f: ^btrfs.File, blocks: u64, _: rawptr) {
	fmt.printfln(
		"%12d %12d %12d %12d %12d %-6v %s",
		f.disk,
		f.uncompressed,
		f.referenced,
		f.charged,
		blocks,
		f.shared,
		path,
	)
}
