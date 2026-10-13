package walk

import "base:runtime"

import "../scan"

/*
What an update does with one directory of the tree it updates. A directory with no
mark is Keep.
*/
Mark :: enum u8 {
	Keep, // unchanged: its entries are copied, unless Update.probe finds otherwise
	List, // its own entries changed: read it again, and keep what below it did not
	Deep, // anything below it may have changed: read all of it again
}

/*
How to bring an earlier tree of the same place up to date: which of its directories
changed, as a change journal or a probe of them found.

`probe` is for a platform with no journal to ask. Every directory not marked is then
asked when it last changed, and one changed at or after `since`, in nanoseconds since
the epoch, is read again rather than copied. An entry a directory gains, loses or
renames moves the directory's modification time.

A file written in place moves only its own modification time (POSIX sys/stat.h,
stat(2)), and a journal may not name it either: FSEvents names a written file's
directory only once the file is closed (macOS 15.7, 2026-10-13: a file appended to
and fsynced while held open gave no event until close), so a disk image, a log or a
database's write-ahead log held open keeps growing unseen. Every copied directory's files of
at least `restat` bytes are therefore asked their size again, probe or journal,
where the platform can ask (not Windows: stamp_other.odin); 0 asks none.
*/
Update :: struct {
	base:   ^scan.Tree,
	marks:  map[u32]Mark, // by node of base
	probe:  bool,
	since:  i64,
	restat: u64,
	// base's children, built by `update` if left empty. A caller that has built it
	// already, to find what changed in base, passes it and keeps it.
	index:  scan.Index,
}

/*
Read `root` into `t` as `u.base` says it was, reading again only what changed.

`u.base` is a finished tree of the same place, read before. A directory it marks
List is read from disk; one it marks Deep is walked; any other is copied from it,
entries, sizes and all, and its subdirectories are dealt with by their own marks. A
directory that a read finds and the base does not have is walked; one the base has
under the same name keeps its own mark. The result is the tree a walk would have
read, as far as the marks were right.

A name the base has keeps the base's choice of which name of a hard-linked file to
charge. A file linked anew since the base, to a name the update copies, is charged
twice: an update cannot see a link it does not read.
*/
update :: proc(root: string, u: ^Update, t: ^scan.Tree, cfg := Config{}) -> Error {
	if u.base.root >= scan.slots(u.base) {
		return read(root, t, cfg)
	}
	built := u.index.first == nil
	if built {
		ix, ix_err := scan.index_make(u.base)
		if ix_err != nil {
			return .Out_Of_Memory
		}
		u.index = ix
	}
	defer if built {
		scan.index_destroy(&u.index)
	}

	first, ok := claim_root(root, t)
	if !ok {
		return .Out_Of_Memory
	}
	return run(
		{index = first, path = root, base = u.base.root, job = job_of(u, u.base.root)},
		t,
		cfg,
		u,
	)
}

// The job a directory of the base is given by its mark.
@(private)
job_of :: proc(u: ^Update, base: u32) -> Job {
	switch u.marks[base] {
	case .Keep:
		return .Copy
	case .List:
		return .List
	case .Deep:
		return .Walk
	}
	return .Walk
}

// Whether a node of the base stands for a directory that is read through: a
// directory nothing else is mounted on, or a link the walk was told to follow.
@(private)
descends :: proc(flags: scan.Node_Flags, follow: bool) -> bool {
	if .Directory in flags {
		return .Mount not_in flags
	}
	return .Reparse in flags && follow
}

/*
Copy a directory's entries from the base, unchanged.

Under a probe it is first asked whether it changed, and read instead if it did or
cannot say. Under a probe or a journal its files of at least `restat` bytes are
asked their sizes, a file that is gone dropped, since neither sees a file written
while held open (Update). The copies run on the workers, so these stats do too: on
a home directory of 2.57M entries that was 17,617 files, 45 ms warm and 1.9 s cold
from one thread (2026-10-13).
*/
@(private)
copy_dir :: proc(d: Dir, w: ^Worker) -> (nodes, bytes: u64, ok: bool) {
	u := w.update
	if u.probe && changed_since(d.path, u.since) {
		return list_dir(d, w)
	}
	base := u.base
	// Every slot at once: one atomic add on the tree's counter a directory rather
	// than one a node. A slot left over by a file a probe found gone stays unused, as
	// a slot a reader claimed and never wrote does.
	count: u32
	for c := u.index.first[d.base]; c != scan.NO_NODE; c = u.index.next[c] {
		count += 1
	}
	if count == 0 {
		return 0, 0, true
	}
	slot, claim_err := scan.claim(&w.writer, count)
	if claim_err != nil {
		w.err = .Out_Of_Memory
		return 0, 0, false
	}
	for c := u.index.first[d.base]; c != scan.NO_NODE; c = u.index.next[c] {
		b := scan.node(base, c)
		flags := scan.node_flags(b) & {.Directory, .Reparse, .Extra_Name, .Mount}
		name := scan.name_of(base, c)
		disk := b.disk
		file := flags & {.Directory, .Reparse} == {}
		if file && disk >= u.restat && u.restat > 0 {
			runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
			path, err := join(d.path, name, context.temp_allocator)
			if err != nil {
				w.err = .Out_Of_Memory
				return nodes, bytes, false
			}
			now, found := disk_of(path, disk)
			if !found {
				continue
			}
			disk = now
		}

		n := scan.node(w.writer.tree, slot)
		n.parent = d.index
		n.name = scan.intern(&w.writer, name)
		n.disk = disk
		scan.node_publish(n, flags | {.Used, .Settled})
		nodes += 1
		if file && .Extra_Name not_in flags {
			bytes += disk
		}

		if descends(flags, w.follow) {
			child, join_err := join(d.path, name, w.allocator)
			if join_err != nil {
				w.err = .Out_Of_Memory
				return nodes, bytes, false
			}
			append(&w.found, Dir{index = slot, path = child, base = c, job = job_of(u, c)})
		}
		slot += 1
	}
	return nodes, bytes, true
}

/*
Read a directory whose entries changed, as a walk would, then give each directory
it holds the job its namesake in the base has. One the base does not have is new,
and walked whole.
*/
@(private)
list_dir :: proc(d: Dir, w: ^Worker) -> (nodes, bytes: u64, ok: bool) {
	u := w.update
	clear(&w.siblings)
	for c := u.index.first[d.base]; c != scan.NO_NODE; c = u.index.next[c] {
		w.siblings[scan.name_of(u.base, c)] = c
	}
	from := len(w.found)
	w.listing = true
	nodes, bytes, ok = read_dir(d, w)
	w.listing = false

	for &f in w.found[from:] {
		f.job = .Walk
		name := scan.name_of(w.writer.tree, f.index)
		was, known := w.siblings[name]
		if known && descends(scan.node_flags(scan.node(u.base, was)), w.follow) {
			f.base = was
			f.job = job_of(u, was)
		}
	}
	return
}

/*
For a file with more than one name that a List job reads: whether the base charged
it under this name, and whether the base had this name as a file at all.
*/
@(private)
kept_choice :: proc(w: ^Worker, name: string) -> (charged, known: bool) {
	if !w.listing {
		return false, false
	}
	was, found := w.siblings[name]
	if !found {
		return false, false
	}
	flags := scan.node_flags(scan.node(w.update.base, was))
	if flags & {.Directory, .Reparse} != {} {
		return false, false
	}
	return .Extra_Name not_in flags, true
}
