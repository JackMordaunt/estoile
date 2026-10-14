package walk

import "core:mem"
import "core:sync"

import "../scan"

/*
Directory totals, added up while the walk still has each directory in hand.

rollup_advance charges every node up its whole ancestor chain after the walk, one
thread, which on a home directory was 82 ms after the walk had already returned
(2026-10-14). A directory's children are recorded by the one worker that reads it,
and a child cannot start until that read has returned and handed the child to the
queue, so the worker can leave the directory's own file bytes and the count of
child directories before any of them runs. The last child to finish adds the
directory's total to its parent. When the walk returns, the totals are done and
the rollup copies them.

Blocks never move, so workers write different nodes of one block with no lock. The
lock is taken only to allocate a block, and the pointer is published after the
block is initialised. A directory's child list is written by its own worker alone.
*/
@(private)
FOLD_SHIFT :: 16
@(private)
FOLD_BLOCK :: 1 << FOLD_SHIFT
@(private)
FOLD_BLOCKS :: 8192 // scan.Tree's block cap; a node past it cannot be named

@(private)
Fold_Block :: struct {
	total:   [FOLD_BLOCK]u64, // subtree bytes; workers add with atomics
	kids:    [FOLD_BLOCK]u32, // child directories not yet finished
	head:    [FOLD_BLOCK]u32, // first child, or NO_NODE
	next:    [FOLD_BLOCK]u32, // previous sibling, or NO_NODE
	depth:   [FOLD_BLOCK]u8, // edges from the root; the rollup stops at 64
	charged: [FOLD_BLOCK]u8, // 1 once the node was published
}

@(private)
Fold :: struct {
	mu:        sync.Mutex,
	blocks:    [FOLD_BLOCKS]^Fold_Block,
	bad:       b32, // a worker ran out of room; the totals are not finished
	deep:      b32, // a node past the rollup's 64-ancestor cap
	allocator: mem.Allocator,
}

@(private)
fold_start :: proc(allocator: mem.Allocator, root: u32) -> (f: ^Fold, ok: bool) {
	raw, err := mem.alloc(size_of(Fold), align_of(Fold), allocator)
	if err != nil {
		return nil, false
	}
	f = (^Fold)(raw)
	f.allocator = allocator
	if !fold_root(f, root) {
		fold_release(f)
		return nil, false
	}
	return f, true
}

// fold_release frees the blocks. A Folded already published onto the tree is
// left there; it is freed with the tree.
@(private)
fold_release :: proc(f: ^Fold) {
	if f == nil {
		return
	}
	for p in f.blocks {
		if p != nil {
			free(p, f.allocator)
		}
	}
	free(f, f.allocator)
}

@(private)
fold_root :: proc(f: ^Fold, root: u32) -> bool {
	b, off, ok := fold_block(f, root)
	if !ok {
		return false
	}
	b.charged[off] = 1
	return true
}

@(private)
fold_block :: proc(f: ^Fold, i: u32) -> (b: ^Fold_Block, off: int, ok: bool) {
	bi := int(i >> FOLD_SHIFT)
	off = int(i & (FOLD_BLOCK - 1))
	if bi >= FOLD_BLOCKS {
		return nil, 0, false
	}
	if p := sync.atomic_load(&f.blocks[bi]); p != nil {
		return p, off, true
	}
	sync.mutex_lock(&f.mu)
	defer sync.mutex_unlock(&f.mu)
	if f.blocks[bi] != nil {
		return f.blocks[bi], off, true
	}
	raw, err := mem.alloc(size_of(Fold_Block), align_of(Fold_Block), f.allocator)
	if err != nil {
		return nil, 0, false
	}
	p := (^Fold_Block)(raw)
	for n in 0 ..< FOLD_BLOCK {
		p.head[n] = scan.NO_NODE
		p.next[n] = scan.NO_NODE
	}
	sync.atomic_store(&f.blocks[bi], p)
	return p, off, true
}

// The block for i, if a node in its range was folded. Nil when none was.
@(private)
fold_got :: proc(f: ^Fold, i: u32) -> (b: ^Fold_Block, off: int, ok: bool) {
	bi := int(i >> FOLD_SHIFT)
	off = int(i & (FOLD_BLOCK - 1))
	if bi >= FOLD_BLOCKS {
		return nil, 0, false
	}
	p := f.blocks[bi]
	if p == nil {
		return nil, 0, false
	}
	return p, off, true
}

// Record index under parent. The worker reading parent is the only one that
// writes parent's list, and it finishes the list before any child runs.
@(private)
fold_link :: proc(w: ^Worker, parent, index: u32, flags: scan.Node_Flags) -> bool {
	f := w.fold
	cb, co, cok := fold_block(f, index)
	if !cok {
		fold_fail(w)
		return false
	}
	cb.charged[co] = 1
	if .Extra_Name in flags {
		return true
	}
	pb, po, pok := fold_block(f, parent)
	if !pok {
		fold_fail(w)
		return false
	}
	cb.next[co] = pb.head[po]
	pb.head[po] = index
	depth := pb.depth[po]
	if depth < 255 {
		depth += 1
	}
	cb.depth[co] = depth
	if depth > 64 {
		// rollup_advance stops climbing after 64 ancestors. Past that a subtree
		// total and the chain walk disagree, so the rollup keeps the chain walk.
		sync.atomic_store(&f.deep, true)
	}
	if .Directory in flags {
		if _, err := append(&w.dirs, index); err != nil {
			fold_fail(w)
			return false
		}
	}
	return true
}

// The directory's entries are recorded and its child directories are queued,
// none of them started. file_bytes is what its own files charged.
@(private)
fold_settle :: proc(w: ^Worker, index: u32, file_bytes: u64) -> bool {
	f := w.fold
	n := scan.node(w.writer.tree, index)
	flags := scan.node_flags(n)
	total := file_bytes
	if .Directory in flags {
		total += n.disk
	}
	b, off, ok := fold_block(f, index)
	if !ok {
		fold_fail(w)
		return false
	}
	sync.atomic_store(&b.total[off], total)
	kids := u32(len(w.found))
	sync.atomic_store(&b.kids[off], kids)
	// The root is not linked by a parent, so it is listed here. A followed link
	// is not a directory; it is listed only when something under it was charged,
	// which is when the chain walk would have numbered it.
	held := file_bytes > 0 || len(w.found) > 0
	if n.parent == index || (.Directory not_in flags && held) {
		if _, err := append(&w.dirs, index); err != nil {
			fold_fail(w)
			return false
		}
	}
	if kids == 0 {
		fold_bubble(f, w.writer.tree, index)
	}
	return !bool(sync.atomic_load(&f.bad))
}

@(private)
fold_bubble :: proc(f: ^Fold, t: ^scan.Tree, index: u32) {
	cur := index
	for {
		n := scan.node(t, cur)
		parent := n.parent
		if parent == cur || parent >= scan.slots(t) {
			return
		}
		// The blocks exist: a node is linked before it can run, and this only runs
		// after it has settled. A missing one means the totals cannot be finished.
		cb, co, cok := fold_got(f, cur)
		pb, po, pok := fold_got(f, parent)
		if !cok || !pok {
			sync.atomic_store(&f.bad, true)
			return
		}
		sync.atomic_add(&pb.total[po], sync.atomic_load(&cb.total[co]))
		// atomic_sub reports the value before it subtracted. 1 means this child
		// took the count from 1 to 0, so it is the last and the parent's total,
		// which now includes this add, is finished.
		if sync.atomic_sub(&pb.kids[po], 1) != 1 {
			return
		}
		cur = parent
	}
}

@(private)
fold_fail :: proc(w: ^Worker) {
	sync.atomic_store(&w.fold.bad, true)
	w.err = .Out_Of_Memory
}

// Copy the folded totals onto the tree, for the rollup to install. Nothing is
// published when the walk stopped short or a node was too deep for the chain
// walk: the rollup then charges as it always has, and the answer stays the same.
@(private)
fold_publish :: proc(f: ^Fold, t: ^scan.Tree, workers: []Worker) -> bool {
	if f == nil || bool(sync.atomic_load(&f.bad)) || bool(sync.atomic_load(&f.deep)) {
		return true
	}
	count := int(scan.slots(t))
	g, gerr := new(scan.Folded, f.allocator)
	if gerr != nil {
		return false
	}
	ok := false
	defer if !ok {
		scan.folded_destroy(g, f.allocator)
	}
	total, terr := make([]u64, count, f.allocator)
	if terr != nil {
		return false
	}
	g.total = total
	head, herr := make([]u32, count, f.allocator)
	if herr != nil {
		return false
	}
	g.head = head
	next, nerr := make([]u32, count, f.allocator)
	if nerr != nil {
		return false
	}
	g.next = next
	words := (count + 63) / 64
	charged, cerr := make([]u64, words, f.allocator)
	if cerr != nil {
		return false
	}
	g.charged = charged

	ndirs := 0
	for w in workers {
		ndirs += len(w.dirs)
	}
	dirs, derr := make([]u32, ndirs, f.allocator)
	if derr != nil {
		return false
	}
	g.dirs = dirs
	at := 0
	for w in workers {
		at += copy(dirs[at:], w.dirs[:])
	}

	for i in 0 ..< count {
		head[i] = scan.NO_NODE
		next[i] = scan.NO_NODE
	}
	for i in 0 ..< u32(count) {
		b, off, have := fold_got(f, i)
		if !have {
			continue
		}
		head[i] = b.head[off]
		next[i] = b.next[off]
		total[i] = b.total[off]
		if b.charged[off] != 0 {
			charged[i >> 6] |= 1 << uint(i & 63)
		}
	}
	g.complete = true
	t.folded = g
	ok = true
	return true
}
