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

/*
A directory on the same filesystem is walked and one on another is not. A btrfs
subvolume has a device of its own but lies in the same pool, so it is walked,
while a read-only one, as snapper's snapshots are, is stopped at as a mount is.
btrfs lets the owner of a directory make a subvolume in it and mark it read-only, so
the test builds both beside the working directory, under build/. Where that is not
btrfs it checks only that the same filesystem is walked and /proc is not.
*/
@(test)
test_the_walk_stays_on_one_filesystem_but_not_one_device :: proc(t: ^testing.T) {
	cwd, cwd_err := os.get_working_directory(context.temp_allocator)
	testing.expect(t, cwd_err == nil, "no working directory")
	root := fmt.tprintf("%s/build/leita_walk_subvolumes", cwd)
	defer remove_subvolumes(root)
	remove_subvolumes(root)
	testing.expect(t, os.make_directory_all(root) == nil, "could not make the root")

	// On any filesystem: a directory on the same one is walked, and /proc, which
	// is always its own, is not.
	testing.expect(t, os.make_directory(fmt.tprintf("%s/plain", root)) == nil)
	dir, dir_errno := linux.open(
		strings.clone_to_cstring(root, context.temp_allocator),
		{.DIRECTORY, .CLOEXEC},
	)
	testing.expect_value(t, dir_errno, linux.Errno.NONE)
	defer linux.close(dir)
	here := filesystem_of(dir)
	testing.expect(t, here != 0, "the root's filesystem is unknown")
	plain: linux.Statx
	testing.expect_value(
		t,
		linux.statx(dir, "plain", {.NO_AUTOMOUNT}, {}, &plain),
		linux.Errno.NONE,
	)
	stop, on := stops_at(dir, raw_data(string("plain")), plain, here)
	testing.expect(t, !stop, "a directory on the same filesystem is stopped at")
	testing.expect(t, on == here, "a directory on the same filesystem names another")
	slash, slash_errno := linux.open("/", {.DIRECTORY, .CLOEXEC})
	testing.expect_value(t, slash_errno, linux.Errno.NONE)
	defer linux.close(slash)
	procfs: linux.Statx
	testing.expect_value(
		t,
		linux.statx(slash, "proc", {.NO_AUTOMOUNT}, {}, &procfs),
		linux.Errno.NONE,
	)
	stop, on = stops_at(slash, raw_data(string("proc")), procfs, here)
	testing.expect(t, stop, "/proc is not stopped at")
	testing.expect(t, on != here, "/proc is named the root's filesystem")

	// The subvolumes this makes are btrfs ones.
	fs: linux.Stat_FS
	testing.expect_value(t, linux.fstatfs(dir, &fs), linux.Errno.NONE)
	if fs.type != .BTRFS_SUPER_MAGIC {
		log.warnf("subvolumes not checked: %s is on %v, not btrfs", root, fs.type)
		return
	}
	testing.expect(t, make_subvolume(root, "sub"), "could not make a subvolume")
	testing.expect(t, make_subvolume(root, "ro"), "could not make a second subvolume")
	for name in ([]string{"plain/a", "sub/b", "ro/c"}) {
		path := fmt.tprintf("%s/%s", root, name)
		testing.expectf(
			t,
			os.write_entire_file(path, []byte{'x'}) == nil,
			"could not write %s",
			path,
		)
	}
	testing.expect(
		t,
		set_read_only(fmt.tprintf("%s/ro", root), true),
		"could not mark ro read-only",
	)

	tree: scan.Tree
	testing.expect_value(t, scan.tree_init(&tree, 1), scan.Error.None)
	defer scan.tree_destroy(&tree)
	testing.expect_value(t, read(root, &tree, Config{}), Error.None)

	children := make([]int, tree.count, context.temp_allocator)
	for i in 0 ..< tree.count {
		n := scan.node(&tree, i)
		if i != tree.root && .Used in n.flags {
			children[n.parent] += 1
		}
	}
	seen := 0
	for i in 0 ..< tree.count {
		n := scan.node(&tree, i)
		if i == tree.root || .Used not_in n.flags || n.parent != tree.root {
			continue
		}
		switch scan.name_of(&tree, i) {
		case "plain", "sub":
			seen += 1
			testing.expectf(
				t,
				.Mount not_in n.flags,
				"%s is marked a mount",
				scan.name_of(&tree, i),
			)
			testing.expectf(
				t,
				children[i] == 1,
				"%s holds %d entries, not 1",
				scan.name_of(&tree, i),
				children[i],
			)
		case "ro":
			seen += 1
			testing.expect(t, .Mount in n.flags, "the read-only subvolume is not marked a mount")
			testing.expectf(
				t,
				children[i] == 0,
				"the read-only subvolume was walked: %d entries",
				children[i],
			)
		}
	}
	testing.expect_value(t, seen, 3)
}

// From linux/btrfs.h: _IOW(0x94, 14, struct btrfs_ioctl_vol_args) and
// _IOW(0x94, 26, __u64).
@(private = "file")
BTRFS_IOC_SUBVOL_CREATE :: 0x5000940e
@(private = "file")
BTRFS_IOC_SUBVOL_SETFLAGS :: 0x4008941a

// Make a btrfs subvolume called `name` in `dir`; false where dir is not btrfs.
@(private = "file")
make_subvolume :: proc(dir: string, name: string) -> bool {
	fd, errno := linux.open(
		strings.clone_to_cstring(dir, context.temp_allocator),
		{.DIRECTORY, .CLOEXEC},
	)
	if errno != .NONE {
		return false
	}
	defer linux.close(fd)
	// struct btrfs_ioctl_vol_args: an fd, then the name in the rest of 4096 bytes.
	args: struct {
		fd:   i64,
		name: [4088]u8,
	}
	copy(args.name[:len(args.name) - 1], name)
	return int(linux.ioctl(fd, BTRFS_IOC_SUBVOL_CREATE, uintptr(&args))) >= 0
}

@(private = "file")
set_read_only :: proc(path: string, on: bool) -> bool {
	fd, errno := linux.open(
		strings.clone_to_cstring(path, context.temp_allocator),
		{.DIRECTORY, .CLOEXEC},
	)
	if errno != .NONE {
		return false
	}
	defer linux.close(fd)
	flags: u64 = on ? BTRFS_SUBVOL_RDONLY : 0
	return int(linux.ioctl(fd, BTRFS_IOC_SUBVOL_SETFLAGS, uintptr(&flags))) >= 0
}

// A read-only subvolume refuses to have its files removed, so it is made writable
// first; an empty subvolume is then removed as a directory is.
@(private = "file")
remove_subvolumes :: proc(root: string) {
	set_read_only(fmt.tprintf("%s/ro", root), false)
	os.remove_all(root)
}
