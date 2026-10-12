package scan

import "core:strings"

// NO_NODE ends a list of children in an Index.
NO_NODE :: max(u32)

/*
The children of every directory in a finished tree, for whoever has to find a node by
its path rather than by its number: an update matching what changed on disk against
the tree it changes.

A reader records a child's parent and nothing else, so the lists are built once over
the whole tree, two numbers a node. A node joins its parent's list when it is used,
settled and not a root, whatever else it is, so an extra name of a file is listed too.
*/
Index :: struct {
	first: []u32, // by node: its most recently listed child, or NO_NODE
	next:  []u32, // by node: the sibling listed before it, or NO_NODE
}

index_make :: proc(t: ^Tree, allocator := context.allocator) -> (ix: Index, err: Error) {
	count := slots(t)
	first, first_err := make([]u32, count, allocator)
	if first_err != nil {
		return {}, .Out_Of_Memory
	}
	next, next_err := make([]u32, count, allocator)
	if next_err != nil {
		delete(first, allocator)
		return {}, .Out_Of_Memory
	}
	for i in 0 ..< count {
		first[i] = NO_NODE
		next[i] = NO_NODE
	}
	for i in 0 ..< count {
		n := node(t, i)
		f := node_flags(n)
		if .Used not_in f || .Settled not_in f || n.parent == i || n.parent >= count {
			continue
		}
		next[i] = first[n.parent]
		first[n.parent] = i
	}
	return {first, next}, .None
}

index_destroy :: proc(ix: ^Index, allocator := context.allocator) {
	delete(ix.first, allocator)
	delete(ix.next, allocator)
	ix^ = {}
}

/*
The child of `dir` called `name`, or NO_NODE.

`fold` also takes a name that differs only in the case of its ASCII letters, for a
path from a filesystem that ignores case, where what reports a change and what read
the tree may not have spelt a name alike. An exact match wins over a folded one.
*/
child_named :: proc(t: ^Tree, ix: Index, dir: u32, name: string, fold := false) -> u32 {
	if dir >= u32(len(ix.first)) {
		return NO_NODE
	}
	folded := NO_NODE
	for c := ix.first[dir]; c != NO_NODE; c = ix.next[c] {
		have := name_of(t, c)
		if have == name {
			return c
		}
		if fold && folded == NO_NODE && strings.equal_fold(have, name) {
			folded = c
		}
	}
	return folded
}
