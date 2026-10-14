package scan

import "core:mem"

/*
Totals a walk folded while it read, so the rollup afterwards copies directories
instead of charging every node.

`head` and `next` are the child lists, in the same shape the rollup keeps, except
`head` is indexed by the directory's node rather than by the directory number the
rollup assigns. `dirs` is every container whose total is final: directories, and a
followed link that held something. `charged` is one bit a node, set for each node
the walk published. Owned by the tree, freed with it; a rollup copies what it keeps.
*/
Folded :: struct {
	total:    []u64, // by node: a container's subtree, in bytes; unused otherwise
	head:     []u32, // by node: its first child, or NO_NODE
	next:     []u32, // by node: the sibling before it, or NO_NODE
	charged:  []u64, // one bit a node
	dirs:     []u32, // containers, each once
	complete: bool, // the walk finished, so this is the whole tree
}

folded_destroy :: proc(g: ^Folded, allocator: mem.Allocator) {
	if g == nil {
		return
	}
	delete(g.total, allocator)
	delete(g.head, allocator)
	delete(g.next, allocator)
	delete(g.charged, allocator)
	delete(g.dirs, allocator)
	free(g, allocator)
}
