package search

import "core:slice"
import "core:strings"
import "core:sync"

import "../scan"

/*
A search is one term over one scan's tree, kept up to date as the tree grows.

Each pass looks at the nodes the tree has gained since the last pass, and at any
an earlier pass had to leave: a slot claimed but not yet written, or a node whose
directories are not all settled. A pass is cut into chunks a thread each, so a
tree of millions is searched on every core, and every chunk checks the pass's
cancel flag as it goes, so a new term never waits for an old one.

A node matches when the term is in its path below the top of the scan, in order.
That test runs on every node, so it is made cheap: how much of the term each
directory's path takes is worked out once per directory and kept (memo), and a
node only carries that on through its own name. Only a node that matches is
scored, against its name alone when the name holds the whole term, else against
its path. Paths are what a person reads, but the top of the scan is left out of
what is matched: it is the same for every entry, and would match everything.

What a search keeps between passes is the best `limit` hits and how many there
were. Nothing here allocates per node.
*/

// CHUNK is how many nodes a thread takes at a time.
CHUNK :: 1 << 15

// UNKNOWN marks a directory whose share of the term is not worked out yet.
@(private)
UNKNOWN :: max(u8)

// Hit is one node that matches, and how well. Better hits sort first.
Hit :: struct {
	node:   u32,
	score:  i32,
	length: u32, // the name's, in bytes: the shorter of two equal scores wins
}

// better is the order hits are ranked in: by score, then the shorter name, then
// the order the scan found them, so a ranking never depends on which thread
// found what.
better :: proc(a, b: Hit) -> bool {
	if a.score != b.score {
		return a.score > b.score
	}
	if a.length != b.length {
		return a.length < b.length
	}
	return a.node < b.node
}

Search :: struct {
	tree:    ^scan.Tree, // the scan's, borrowed //review:ignore odin-destroy-incomplete borrowed: the scan owns its tree
	pattern: Pattern,
	limit:   int,
	root:    u32, // the top of the scan, once a pass has seen it
	rooted:  bool,
	// By node: how many of the term's characters its path takes, matching
	// greedily from the top down (advance); UNKNOWN until worked out. Read and
	// written by every chunk at once: a value is the same whoever works it out.
	memo:    [dynamic]u8,
	bound:   u32, // nodes below this have been looked at, bar those in retry
	retry:   [dynamic]u32,
	top:     [dynamic]Hit, // the best, at most limit, best first
	total:   int, // every hit so far, not only those kept
	final:   bool, // a pass over the finished tree has run: there is no more
}

// search_init readies s to search tree for term, keeping the best limit hits.
search_init :: proc(s: ^Search, tree: ^scan.Tree, term: string, limit: int) {
	assert(limit > 0, "a search that keeps nothing")
	s^ = {
		tree    = tree,
		pattern = pattern_make(term),
		limit   = limit,
	}
}

search_destroy :: proc(s: ^Search) {
	delete(s.memo)
	delete(s.retry)
	delete(s.top)
	s^ = {}
}

// Pass is one look at what the tree has gained, cut into chunks.
Pass :: struct {
	search:  ^Search, //review:ignore odin-destroy-incomplete borrowed: a search outlives its passes
	from:    u32,
	to:      u32,
	retry:   []u32, // nodes an earlier pass left, looked at again
	final:   bool, // the tree is finished: a node not there now never will be
	cancel:  b32, // atomic: stop where each chunk next checks
	left:    int, // atomic: chunks not yet run
	// Atomic: a score the search's limit-th best is known to reach, from the
	// hits it kept before and those each chunk has kept so far. A match that
	// could not reach it is counted but not scored.
	floor:   i32,
	chunks:  []Chunk,
	// Called once, by whichever thread finishes the last chunk.
	on_done: proc(p: ^Pass),
	user:    rawptr,
}

// Chunk is one thread's share of a pass, and what it found.
Chunk :: struct {
	pass:  ^Pass,
	first: int, // the pass's items from first, up to but not including last
	last:  int,
	top:   [dynamic]Hit,
	total: int,
	retry: [dynamic]u32,
	// The worst of the best limit, once there are that many: nothing that
	// cannot beat it is kept, or scored if it plainly could not.
	floor: Maybe(Hit),
}

/*
pass_begin readies a pass over the nodes below `below` that s has not looked at,
and the ones it left; nil when there is nothing to look at, or the top of the
scan is not in yet. final says the tree is finished. The caller runs every chunk
(pass_run, on any threads) and then, on the thread that owns s, pass_end. Until
then s is the pass's: nothing else may change it.
*/
pass_begin :: proc(s: ^Search, below: u32, final: bool) -> ^Pass {
	t := s.tree
	upto := min(below, scan.slots(t))
	if !s.rooted {
		root := sync.atomic_load(&t.root)
		if root >= upto || .Used not_in scan.node_flags(scan.node(t, root)) {
			return nil
		}
		s.root, s.rooted = root, true
	}
	from := s.bound
	if from >= upto && len(s.retry) == 0 && (!final || s.final) {
		return nil
	}
	if from < upto {
		old := len(s.memo)
		resize(&s.memo, int(upto))
		slice.fill(s.memo[old:], UNKNOWN)
		s.memo[s.root] = 0
	}
	p := new(Pass)
	p^ = {
		search = s,
		from   = from,
		to     = max(upto, from),
		final  = final,
	}
	p.floor = NONE
	if len(s.top) == s.limit {
		p.floor = s.top[s.limit - 1].score
	}
	p.retry = slice.clone(s.retry[:])
	clear(&s.retry)
	items := int(p.to - p.from) + len(p.retry)
	count := max((items + CHUNK - 1) / CHUNK, 1)
	p.chunks = make([]Chunk, count)
	for &c, i in p.chunks {
		c.pass, c.first, c.last = p, i * CHUNK, min((i + 1) * CHUNK, items)
	}
	p.left = count
	return p
}

// pass_cancel calls the pass off; its chunks stop where they next check.
pass_cancel :: proc(p: ^Pass) {
	sync.atomic_store(&p.cancel, true)
}

// pass_cancelled is whether the pass was called off.
pass_cancelled :: proc(p: ^Pass) -> bool {
	return bool(sync.atomic_load(&p.cancel))
}

// pass_running is whether any chunk of the pass has yet to finish.
pass_running :: proc(p: ^Pass) -> bool {
	return sync.atomic_load(&p.left) > 0
}

// pass_run runs one chunk, on any thread, then calls the pass's on_done if it
// was the last to finish.
pass_run :: proc(c: ^Chunk) {
	p := c.pass
	if !pass_cancelled(p) {
		scratch := new(Scratch)
		look(c, scratch)
		free(scratch)
	}
	if sync.atomic_sub(&p.left, 1) == 1 && p.on_done != nil {
		p.on_done(p)
	}
}

/*
pass_end takes what a finished pass found into s and frees the pass. A pass
called off leaves s as it was before it began, but for the memo, which holds
only what is true. Every chunk must have finished.
*/
pass_end :: proc(s: ^Search, p: ^Pass) {
	assert(!pass_running(p), "a pass ended with chunks still running")
	if pass_cancelled(p) {
		append(&s.retry, ..p.retry)
	} else {
		s.bound = p.to
		s.final ||= p.final
		for &c in p.chunks {
			s.total += c.total
			append(&s.top, ..c.top[:])
			append(&s.retry, ..c.retry[:])
		}
		rank(s)
	}
	pass_free(p)
}

// pass_free frees a pass without taking what it found, for a search going away.
pass_free :: proc(p: ^Pass) {
	for &c in p.chunks {
		delete(c.top)
		delete(c.retry)
	}
	delete(p.chunks)
	delete(p.retry)
	free(p)
}

// search_step runs a whole pass on this thread: for tests, and for a caller
// with no threads to spare.
search_step :: proc(s: ^Search, upto: u32, final: bool) -> bool {
	p := pass_begin(s, upto, final)
	if p == nil {
		return false
	}
	for &c in p.chunks {
		pass_run(&c)
	}
	pass_end(s, p)
	return true
}

// rank sorts the hits best first and keeps the best limit.
@(private)
rank :: proc(s: ^Search) {
	slice.sort_by(s.top[:], better)
	if len(s.top) > s.limit {
		resize(&s.top, s.limit)
	}
}

// look is one chunk's work: each of its nodes tested, and scored if it matches.
@(private)
look :: proc(c: ^Chunk, scratch: ^Scratch) {
	p := c.pass
	s := p.search
	span := int(p.to - p.from)
	for item in c.first ..< c.last {
		if (item - c.first) & 4095 == 0 && pass_cancelled(p) {
			return
		}
		i := item < span ? p.from + u32(item) : p.retry[item - span]
		least := sync.atomic_load(&p.floor)
		if f, full := c.floor.?; full {
			least = max(least, f.score)
		}
		hit, state := test(s, i, p.to, least, scratch)
		switch state {
		case .Miss:
		case .Hit:
			c.total += 1
			keep(c, s.limit, hit)
		case .Outranked:
			c.total += 1
		case .Later:
			if !p.final {
				append(&c.retry, i)
			}
		}
	}
}

// keep adds hit to the chunk's best, trimming them to limit when they run to
// twice that, so sorting stays rare.
@(private)
keep :: proc(c: ^Chunk, limit: int, hit: Hit) {
	if floor, full := c.floor.?; full && !better(hit, floor) {
		return
	}
	append(&c.top, hit)
	if len(c.top) >= 2 * limit {
		slice.sort_by(c.top[:], better)
		resize(&c.top, limit)
		c.floor = c.top[limit - 1]
		// Every chunk's floor is one the whole search reaches.
		p := c.pass
		for {
			was := sync.atomic_load(&p.floor)
			if was >= c.floor.?.score {
				break
			}
			if _, ok := sync.atomic_compare_exchange_weak(&p.floor, was, c.floor.?.score); ok {
				break
			}
		}
	}
}

// ceiling is the most a match of count characters could score: each earning the
// largest bonus there is, the first twice over, and no gaps.
@(private)
ceiling :: proc(count: int) -> i32 {
	return i32(count) * SCORE_MATCH + i32(count + 1) * BONUS_MOST
}

@(private)
Outcome :: enum u8 {
	Miss,
	Hit,
	Outranked, // a hit, but one that could not beat the floor it was given
	Later, // not yet in the tree, or its directories are not all settled
}

// test is whether node i matches, and how well. A match that could not score
// least is not scored.
@(private)
test :: proc(s: ^Search, i, bound: u32, least: i32, scratch: ^Scratch) -> (Hit, Outcome) {
	t := s.tree
	flags := scan.node_flags(scan.node(t, i))
	if .Used not_in flags {
		return {}, .Later
	}
	if i == s.root {
		return {}, .Miss // the top is where the search is, not something in it
	}
	taken, known := taken_by(s, i, bound)
	if !known {
		return {}, .Later
	}
	pat := &s.pattern
	if int(taken) < pat.count {
		return {}, .Miss
	}
	name := scan.name_of(t, i)
	hit := Hit {
		node   = i,
		length = u32(len(name)),
	}
	if matches(pat, name) {
		if BONUS_NAME + ceiling(pat.count) < least {
			return {}, .Outranked
		}
		v, _ := score(pat, name, scratch)
		hit.score = v + BONUS_NAME
		return hit, .Hit
	}
	// Most paths that match only along their directories are outranked by
	// names that match: building and scoring their paths is most of a search's
	// cost when names are not.
	if ceiling(pat.count) < least {
		return {}, .Outranked
	}
	path, ok := relative_path(s, i, bound, scratch.path[:], scratch.chain[:])
	if !ok {
		return {}, .Later
	}
	v, matched := score(pat, path, scratch)
	if !matched {
		// Only a path cut short to fit can lose a match the memo saw.
		return {}, .Miss
	}
	hit.score = v
	return hit, .Hit
}

/*
taken_by is how many of the term's characters the path to node i takes, from the
memo where it can be, working out and keeping the rest on the way up. known is
false when some node on the way is not settled, or its holder is past bound:
the answer could still change.
*/
@(private)
taken_by :: proc(s: ^Search, i, bound: u32) -> (taken: u8, known: bool) {
	t := s.tree
	chain: [64]u32
	depth := 0
	cur := i
	base: u8
	orphan := false
	for {
		if v := sync.atomic_load(&s.memo[cur]); v != UNKNOWN {
			base = v
			break
		}
		n := scan.node(t, cur)
		flags := scan.node_flags(n)
		if .Used not_in flags || .Settled not_in flags {
			return 0, false
		}
		chain[depth] = cur
		depth += 1
		if n.parent == cur || depth == len(chain) {
			// An orphan, or a chain too deep to follow: its path starts at
			// its own name, as scan.path spells it.
			orphan = true
			break
		}
		if n.parent >= bound {
			return 0, false
		}
		cur = n.parent
	}
	pat := &s.pattern
	k := int(base)
	for d := depth - 1; d >= 0; d -= 1 {
		node := chain[d]
		// A separator before every name but the first under the top.
		first := d == depth - 1 && (orphan || cur == s.root)
		if !first && k < pat.count && pat.runes[k] == '/' {
			k += 1
		}
		k = advance(pat, k, scan.name_of(t, node))
		sync.atomic_store(&s.memo[node], u8(k))
	}
	return u8(k), true
}

/*
relative_path is node i's path below the top of the scan, its names joined by the
platform's separator, written into buf; ok is false when a node on the way has
gone unsettled past bound. A path too long for buf keeps its end.
*/
@(private)
relative_path :: proc(s: ^Search, i, bound: u32, buf: []u8, chain: []u32) -> (string, bool) {
	t := s.tree
	depth := 0
	cur := i
	for cur != s.root && depth < len(chain) {
		chain[depth] = cur
		depth += 1
		n := scan.node(t, cur)
		if n.parent == cur {
			break
		}
		if n.parent >= bound {
			return "", false
		}
		cur = n.parent
	}
	// Written back to front, so a path that overflows keeps its name.
	at := len(buf)
	for d in 0 ..< depth {
		name := scan.name_of(t, chain[d])
		if d > 0 {
			if at == 0 {
				break
			}
			at -= 1
			buf[at] = scan.SEPARATOR[0]
		}
		if len(name) > at {
			copy(buf[:at], name[len(name) - at:])
			at = 0
			break
		}
		at -= len(name)
		copy(buf[at:], name)
	}
	return string(buf[at:]), true
}

// Found is a hit as a person reads it: its whole path, where its name starts in
// that, and the stretches of the path the term matched.
Found :: struct {
	path:    string,
	name_at: int,
	spans:   []Span,
}

/*
describe is node i of a search as it is shown: the path from the top of the
filesystem, as scan.path spells it, and where in it the term matched, worked out
again for this one node. It runs on the thread that owns s, between passes.
*/
describe :: proc(s: ^Search, i: u32, scratch: ^Scratch, allocator := context.allocator) -> Found {
	t := s.tree
	full := scan.path(t, i, allocator)
	f := Found {
		path = full,
	}
	name := scan.name_of(t, i)
	f.name_at = len(full) - len(name)
	if !strings.has_suffix(full, name) {
		f.name_at = len(full)
	}
	pat := &s.pattern
	if matches(pat, name) {
		if _, ok := score(pat, name, scratch); ok {
			f.spans = spans(pat, scratch, f.name_at, allocator)
		}
		return f
	}
	rel, ok := relative_path(s, i, scan.slots(t), scratch.path[:], scratch.chain[:])
	if !ok || !strings.has_suffix(full, rel) {
		return f
	}
	if _, matched := score(pat, rel, scratch); matched {
		f.spans = spans(pat, scratch, len(full) - len(rel), allocator)
	}
	return f
}
