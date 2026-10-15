#+build linux
package walk

import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"
import "core:sys/linux"
import "core:testing"

import "../scan"

/*
A directory's entries are asked about in inode order, whatever order the
directory lists them in, so a cold read goes through the inode table once rather
than seeking for each. The tree records them in the order they are asked about.

The test only tells the orders apart where the filesystem lists entries in some
other order. tmpfs, where the temp directory usually is, lists the newest first.
*/
@(test)
test_entries_are_read_in_inode_order :: proc(t: ^testing.T) {
	dir, dir_err := os.temp_directory(context.temp_allocator)
	testing.expect(t, dir_err == nil, "no temp directory")
	root := fmt.tprintf("%s/leita_walk_inodes", dir)
	os.remove_all(root)
	defer os.remove_all(root)
	testing.expect(t, os.make_directory(root) == nil, "could not make the root")
	for i in 0 ..< 40 {
		path := fmt.tprintf("%s/f%02d", root, (i * 7) % 40)
		testing.expectf(
			t,
			os.write_entire_file(path, []byte{'x'}) == nil,
			"could not write %s",
			path,
		)
	}

	tree: scan.Tree
	testing.expect_value(t, scan.tree_init(&tree, 1), scan.Error.None)
	defer scan.tree_destroy(&tree)
	testing.expect_value(t, read(root, &tree, Config{}), Error.None)

	last: u64
	count := 0
	for i in 0 ..< tree.count {
		n := scan.node(&tree, i)
		if i == tree.root || .Used not_in n.flags {
			continue
		}
		path := strings.clone_to_cstring(
			fmt.tprintf("%s/%s", root, scan.name_of(&tree, i)),
			context.temp_allocator,
		)
		st: linux.Statx
		testing.expect(t, linux.statx(linux.AT_FDCWD, path, {}, {.INO}, &st) == .NONE)
		testing.expectf(
			t,
			u64(st.ino) > last,
			"%s (inode %d) was read after inode %d",
			scan.name_of(&tree, i),
			st.ino,
			last,
		)
		last = u64(st.ino)
		count += 1
	}
	testing.expect_value(t, count, 40)
}

/*
A directory another filesystem is mounted on is recorded as a mount and not walked,
so a scan of / leaves /proc and /sys alone. Nothing unprivileged can mount a
filesystem for the test, so it reads /dev, where systemd mounts pts, shm and mqueue,
each its own device; this machine has those and hugepages (2026-10-15). It skips
where /proc/self/mounts names nothing directly beneath /dev.
*/
@(test)
test_a_directory_on_another_device_is_a_mount :: proc(t: ^testing.T) {
	ROOT :: "/dev"
	text, read_err := os.read_entire_file("/proc/self/mounts", context.temp_allocator)
	if read_err != nil {
		log.warnf("skipped: /proc/self/mounts would not open: %v", read_err)
		return
	}
	mounted: [dynamic]string
	mounted.allocator = context.temp_allocator
	lines := string(text)
	for line in strings.split_lines_iterator(&lines) {
		fields := strings.fields(line, context.temp_allocator)
		if len(fields) < 2 {
			continue
		}
		// Only those directly beneath it, whose names the tree holds as they are;
		// mount points with escaped spaces are left out rather than unescaped.
		if !strings.has_prefix(fields[1], ROOT + "/") {
			continue
		}
		name := fields[1][len(ROOT) + 1:]
		if name != "" && !strings.contains_any(name, "/\\") {
			append(&mounted, name)
		}
	}
	if len(mounted) == 0 {
		log.warnf("skipped: nothing is mounted directly beneath %s", ROOT)
		return
	}

	tree: scan.Tree
	testing.expect_value(t, scan.tree_init(&tree, 1), scan.Error.None)
	defer scan.tree_destroy(&tree)
	testing.expect_value(t, read(ROOT, &tree, Config{}), Error.None)

	children := make([]int, tree.count, context.temp_allocator)
	for i in 0 ..< tree.count {
		n := scan.node(&tree, i)
		if i != tree.root && .Used in n.flags {
			children[n.parent] += 1
		}
	}
	for name in mounted {
		found := false
		for i in 0 ..< tree.count {
			n := scan.node(&tree, i)
			if i == tree.root || .Used not_in n.flags || n.parent != tree.root {
				continue
			}
			if scan.name_of(&tree, i) != name {
				continue
			}
			found = true
			testing.expectf(t, .Mount in n.flags, "%s/%s is not marked a mount", ROOT, name)
			testing.expectf(
				t,
				children[i] == 0,
				"%s/%s was walked: %d entries beneath it",
				ROOT,
				name,
				children[i],
			)
		}
		testing.expectf(t, found, "%s/%s is not in the tree", ROOT, name)
	}
}
