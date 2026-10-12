package walk

import "core:fmt"
import "core:os"
import "core:slice"
import "core:testing"
import "core:time"

import "../scan"

/*
A place to update.

	<root>/a.txt               100 bytes
	<root>/sub/b.txt           5000 bytes
	<root>/sub/deep/c.txt      1 byte
	<root>/still/k.txt         3000 bytes
*/
@(private = "file")
place :: proc(t: ^testing.T, name: string) -> string {
	dir, dir_err := os.temp_directory(context.temp_allocator)
	testing.expect(t, dir_err == nil, "no temp directory")
	root := fmt.tprintf("%s/leita_update_%s", dir, name)
	os.remove_all(root)
	for sub in ([]string{"", "/sub", "/sub/deep", "/still"}) {
		testing.expect(t, os.make_directory(fmt.tprintf("%s%s", root, sub)) == nil, "no directory")
	}
	put(t, fmt.tprintf("%s/a.txt", root), 100)
	put(t, fmt.tprintf("%s/sub/b.txt", root), 5000)
	put(t, fmt.tprintf("%s/sub/deep/c.txt", root), 1)
	put(t, fmt.tprintf("%s/still/k.txt", root), 3000)
	return root
}

// Write a file of `size` bytes, for any platform. read_windows_test.odin's
// write_file is Windows' alone.
@(private = "file")
put :: proc(t: ^testing.T, path: string, size: int) {
	body := make([]byte, size, context.temp_allocator)
	slice.fill(body, 'x')
	testing.expectf(t, os.write_entire_file(path, body) == nil, "could not write %s", path)
}

// Grow still/k.txt where it is. No test here marks still, or probes with a restat
// small enough to catch it, so an update must keep the base's size for it.
@(private = "file")
grow_unseen :: proc(t: ^testing.T, root: string) {
	put(t, fmt.tprintf("%s/still/k.txt", root), 40_000)
}

@(private = "file")
read_tree :: proc(t: ^testing.T, root: string) -> scan.Tree {
	tree: scan.Tree
	testing.expect_value(t, scan.tree_init(&tree, 2), scan.Error.None)
	testing.expect_value(t, read(root, &tree, Config{workers = 2}), Error.None)
	return tree
}

// The node of `tree` at `path` under its root, or NO_NODE.
@(private = "file")
at :: proc(tree: ^scan.Tree, path: ..string) -> u32 {
	ix, _ := scan.index_make(tree, context.temp_allocator)
	cur := tree.root
	for name in path {
		cur = scan.child_named(tree, ix, cur, name)
		if cur == scan.NO_NODE {
			break
		}
	}
	return cur
}

// What a tree says is there: each node's path, and what it charges.
@(private = "file")
shape :: proc(tree: ^scan.Tree) -> map[string]u64 {
	out := make(map[string]u64, context.temp_allocator)
	for i in 0 ..< scan.slots(tree) {
		n := scan.node(tree, i)
		f := scan.node_flags(n)
		if .Used not_in f {
			continue
		}
		charged := n.disk if .Extra_Name not_in f && .Directory not_in f else 0
		out[scan.path(tree, i, context.temp_allocator)] = charged
	}
	return out
}

/*
Expect `got` to hold, path for path and byte for byte, what `want` does. Given the
base, still/k.txt is the exception: grow_unseen changed it where nothing looks, so
`got` must hold the base's size for it, which is what shows still was copied rather
than read again.
*/
@(private = "file")
expect_same_shape :: proc(t: ^testing.T, got, want: ^scan.Tree, base: ^scan.Tree = nil) {
	g, w := shape(got), shape(want)
	stale := scan.path(want, at(want, "still", "k.txt"), context.temp_allocator)
	if base != nil {
		was := shape(base)[stale]
		testing.expectf(t, g[stale] == was, "k.txt charged %d, the base %d", g[stale], was)
		testing.expectf(t, g[stale] != w[stale], "k.txt was read again: %d", g[stale])
	}
	testing.expectf(t, len(g) == len(w), "%d nodes, a walk has %d", len(g), len(w))
	for path, bytes in w {
		if base != nil && path == stale {
			continue
		}
		have, found := g[path]
		testing.expectf(t, found, "%s is missing", path)
		testing.expectf(t, !found || have == bytes, "%s charged %d, a walk %d", path, have, bytes)
	}
	for path in g {
		testing.expectf(t, path in w, "%s is not on disk", path)
	}
}

// Changes made to the directories marked are found, and the result is the tree a
// fresh walk reads, but for what was changed where nothing was marked.
@(test)
test_an_update_reads_what_changed :: proc(t: ^testing.T) {
	root := place(t, "changed")
	defer os.remove_all(root)
	base := read_tree(t, root)
	defer scan.tree_destroy(&base)

	put(t, fmt.tprintf("%s/sub/new.txt", root), 7000)
	testing.expect(t, os.make_directory(fmt.tprintf("%s/sub/fresh", root)) == nil, "no fresh")
	put(t, fmt.tprintf("%s/sub/fresh/f.txt", root), 9000)
	testing.expect(t, os.remove(fmt.tprintf("%s/sub/deep/c.txt", root)) == nil, "c.txt stayed")
	grow_unseen(t, root)

	u := Update {
		base = &base,
	}
	defer delete(u.marks)
	u.marks[at(&base, "sub")] = .List
	u.marks[at(&base, "sub", "deep")] = .List

	got: scan.Tree
	testing.expect_value(t, scan.tree_init(&got, 2), scan.Error.None)
	defer scan.tree_destroy(&got)
	testing.expect_value(t, update(root, &u, &got, Config{workers = 2}), Error.None)

	want := read_tree(t, root)
	defer scan.tree_destroy(&want)
	expect_same_shape(t, &got, &want, &base)
}

// A directory not marked is copied rather than read: a change in it is not seen,
// which is what makes an update cheap, and why the marks must be right.
@(test)
test_an_update_copies_what_is_not_marked :: proc(t: ^testing.T) {
	root := place(t, "copied")
	defer os.remove_all(root)
	base := read_tree(t, root)
	defer scan.tree_destroy(&base)
	put(t, fmt.tprintf("%s/still/unseen.txt", root), 4000)

	u := Update {
		base = &base,
	}
	got: scan.Tree
	testing.expect_value(t, scan.tree_init(&got, 1), scan.Error.None)
	defer scan.tree_destroy(&got)
	testing.expect_value(t, update(root, &u, &got), Error.None)

	expect_same_shape(t, &got, &base)
	testing.expect_value(t, at(&got, "still", "unseen.txt"), scan.NO_NODE)
	testing.expect(t, at(&got, "still", "k.txt") != scan.NO_NODE, "k.txt was not copied")
}

// Deep reads everything below it, base or no base, and nothing beside it.
@(test)
test_a_deep_mark_walks_the_whole_subtree :: proc(t: ^testing.T) {
	root := place(t, "deep")
	defer os.remove_all(root)
	base := read_tree(t, root)
	defer scan.tree_destroy(&base)
	put(t, fmt.tprintf("%s/sub/deep/d.txt", root), 2000)
	grow_unseen(t, root)

	u := Update {
		base = &base,
	}
	defer delete(u.marks)
	u.marks[at(&base, "sub")] = .Deep
	got: scan.Tree
	testing.expect_value(t, scan.tree_init(&got, 1), scan.Error.None)
	defer scan.tree_destroy(&got)
	testing.expect_value(t, update(root, &u, &got), Error.None)

	want := read_tree(t, root)
	defer scan.tree_destroy(&want)
	expect_same_shape(t, &got, &want, &base)
}

// A probe reads the directories changed since, and the large files of those it
// copies, and nothing else: a small file written in place is missed, as designed.
@(test)
test_a_probe_finds_changed_directories :: proc(t: ^testing.T) {
	when ODIN_OS != .Linux {
		return
	}
	root := place(t, "probe")
	defer os.remove_all(root)
	put(t, fmt.tprintf("%s/still/big.bin", root), 1 << 17)
	base := read_tree(t, root)
	defer scan.tree_destroy(&base)

	// Linux stamps a change with its coarse clock (current_time in fs/inode.c), a
	// jiffy at most behind time.now, so each change is kept 50 ms clear of `since`.
	time.sleep(50 * time.Millisecond)
	since := time.to_unix_nanoseconds(time.now())
	time.sleep(50 * time.Millisecond)
	put(t, fmt.tprintf("%s/sub/new.txt", root), 7000)
	put(t, fmt.tprintf("%s/still/big.bin", root), 1 << 18) // in place: still is unchanged
	grow_unseen(t, root)

	u := Update {
		base   = &base,
		probe  = true,
		since  = since,
		restat = 1 << 16,
	}
	got: scan.Tree
	testing.expect_value(t, scan.tree_init(&got, 2), scan.Error.None)
	defer scan.tree_destroy(&got)
	testing.expect_value(t, update(root, &u, &got, Config{workers = 2}), Error.None)

	want := read_tree(t, root)
	defer scan.tree_destroy(&want)
	expect_same_shape(t, &got, &want, &base)
}

// A hard-linked file keeps the name the base charged it under when the other
// name's directory is read again, so its bytes are charged once, not twice.
@(test)
test_a_relisted_link_is_charged_once :: proc(t: ^testing.T) {
	when ODIN_OS != .Linux && ODIN_OS != .Darwin {
		return
	}
	root := place(t, "links")
	defer os.remove_all(root)
	testing.expect(
		t,
		os.link(fmt.tprintf("%s/sub/b.txt", root), fmt.tprintf("%s/still/b2.txt", root)) == nil,
		"could not link",
	)
	base := read_tree(t, root)
	defer scan.tree_destroy(&base)

	u := Update {
		base = &base,
	}
	defer delete(u.marks)
	u.marks[at(&base, "still")] = .List
	got: scan.Tree
	testing.expect_value(t, scan.tree_init(&got, 1), scan.Error.None)
	defer scan.tree_destroy(&got)
	testing.expect_value(t, update(root, &u, &got), Error.None)

	expect_same_shape(t, &got, &base)
	total :: proc(tree: ^scan.Tree) -> (sum: u64) {
		for _, bytes in shape(tree) {
			sum += bytes
		}
		return
	}
	testing.expect_value(t, total(&got), total(&base))
}
