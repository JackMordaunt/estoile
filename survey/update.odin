package survey

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"

import "jm:timefmt"

import "../changes"
import "../gui/query"
import "../scan"
import "../walk"

/*
How a Fill with a baseline read its place: whole, or by updating the last tree of it
from what the system says changed since.
*/
Fill_Kind :: enum u8 {
	Full,
	Updated,
}

/*
RESTAT is the least a file of a copied directory holds for an update to ask its size
again, on macOS and Linux (walk.RESTATS; Windows keeps the size copied): history's
KEPT_MIN, so every file history keeps is current there. Neither a probe nor FSEvents
sees a file written while held open (walk.Update); on a home directory such files (a
VM's disk image, logs, a database's write-ahead log) left an update 10.1 GB short
(2026-10-13). A smaller file written in place, in a directory that did not change,
keeps its old size until the next whole scan; over a day of a home directory that was
8.7 MiB in 110.8 GiB (measured 2026-10-12, 162 files).
*/
RESTAT :: query.KEPT_MIN

/*
Read the place, from its baseline when that can be trusted, and keep the result as
the next baseline. A place is read whole when f.whole asks, it has no baseline, the
baseline is of another place or cannot be read, or the system cannot say what changed
(changes.since says why); f.why says which. Only a walk's or the MFT's tree is
kept: a made-up disk is always read whole, and fill_run never brings one here.
*/
@(private)
fill_from_baseline :: proc(f: ^Fill) {
	place := scan.location(f.target, context.allocator)
	defer delete(place)

	base: scan.Tree
	cursor: changes.Cursor
	why := "asked to read it whole"
	loaded: bool
	if !f.whole {
		f.taken, _ = os.modification_time_by_path(f.baseline)
		cursor, why, loaded = baseline_load(f.baseline, place, &base)
	}
	if loaded {
		defer scan.tree_destroy(&base)
		set, next, err := changes.since(place, cursor)
		defer changes.change_set_destroy(&set)
		switch {
		case err != nil:
			why = "no room to read what changed"
		case set.rescan:
			why = set.why
		case:
			// An update fails as a walk does, short of room or called off, and
			// what it read is left as a walk's would be.
			f.walk_err = apply(f, place, &base, set)
			f.how = .Updated
			if f.walk_err == .None {
				f.saved = baseline_save(f.baseline, place, f.tree, next)
			}
			return
		}
	}

	f.how = .Full
	f.why = why
	now, have := changes.now(place)
	switch f.engine {
	case .Mft:
		fill_mft(f)
	case .Walk:
		fill_walk(f)
	case .Synthetic, .None:
	}
	if !have {
		f.why = "the system cannot say what changes in this place"
		return
	}
	if f.mft_err == nil && f.walk_err == nil && f.tree_err == nil {
		f.saved = baseline_save(f.baseline, place, f.tree, now)
	}
}

/*
Read `place` into f.tree from `base`, reading again what `set` says changed: each
directory named shallow listed, each named deep walked, and with a probe every
directory asked. A path the base does not have marks the nearest directory above it
that it does, which then finds what is new.
*/
@(private)
apply :: proc(f: ^Fill, place: string, base: ^scan.Tree, set: changes.Change_Set) -> walk.Error {
	ix, ix_err := scan.index_make(base)
	if ix_err != nil {
		return .Out_Of_Memory
	}
	defer scan.index_destroy(&ix)
	u := walk.Update {
		base   = base,
		index  = ix,
		probe  = set.probe,
		since  = set.since,
		restat = RESTAT,
	}
	defer delete(u.marks)
	for path in set.shallow {
		if n := locate(base, ix, place, path); n != scan.NO_NODE && u.marks[n] != .Deep {
			u.marks[n] = .List
		}
	}
	for path in set.deep {
		n, exact := locate_exact(base, ix, place, path)
		if n == scan.NO_NODE {
			continue
		}
		// Not in the base: new, so the directory above it finds it and walks it.
		u.marks[n] = .Deep if exact else max(u.marks[n], walk.Mark.List)
	}
	err := walk.update(place, &u, f.tree, f.wcfg)
	f.reread = u.read
	return err
}

/*
how_read says in words how a fill with a baseline read its place, in the temp
allocator: "updated: N directories read again since <time>", or "read whole: <why>".
An update with no time to give, as a run the monitor recorded before it kept the
count and the time, is "updated from the last scan".
*/
how_read :: proc(updated: bool, why: string, reread: u64 = 0, taken := time.Time{}) -> string {
	switch {
	case updated && taken == {}:
		return "updated from the last scan"
	case updated:
		return fmt.tprintf(
			"updated: %d %s read again since %s",
			reread,
			"directory" if reread == 1 else "directories",
			timefmt.local(taken, "%Y-%m-%d %H:%M", context.temp_allocator),
		)
	case why != "":
		return fmt.tprintf("read whole: %s", why)
	}
	return "read whole"
}

// The directory of `base` that `path` names, or the nearest above it that the base
// has; NO_NODE for a path outside the place.
@(private)
locate :: proc(base: ^scan.Tree, ix: scan.Index, place, path: string) -> u32 {
	n, _ := locate_exact(base, ix, place, path)
	return n
}

@(private)
locate_exact :: proc(
	base: ^scan.Tree,
	ix: scan.Index,
	place, path: string,
) -> (
	n: u32,
	exact: bool,
) {
	rest, inside := changes.under(place, path)
	if !inside {
		return scan.NO_NODE, false
	}
	fold := ODIN_OS == .Windows || ODIN_OS == .Darwin
	n = base.root
	exact = true
	for name in strings.split_iterator(&rest, scan.SEPARATOR) {
		if name == "" {
			continue
		}
		child := scan.child_named(base, ix, n, name, fold)
		if child == scan.NO_NODE {
			exact = false
			break
		}
		n = child
	}
	// A path that names a file changed what its directory holds.
	if .Directory not_in scan.node_flags(scan.node(base, n)) && n != base.root {
		n = scan.node(base, n).parent
		exact = false
	}
	return n, exact
}
