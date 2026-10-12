package survey

import "core:encoding/endian"
import "core:os"
import "core:strings"

import "../changes"
import "../scan"

/*
A baseline is the whole of a place's last tree, kept in a file between runs with the
cursor taken before it was read, so the next run can apply what changed since rather
than read the place again. History keeps far less, entries of at least a megabyte, so
it cannot serve: an update needs every file to copy.

The file is written whole to a temporary name and renamed over the old one, so a run
that stops part way leaves the last good baseline, never a torn one. It is written
for this machine, little-endian:

	magic        "LEITABL1"
	cursor       source u8, volume 2 x u64, journal u64, position i64, full i64
	place        u32 length, then its bytes
	nodes        u32 count, u32 root
	each node    u32 parent, u8 flags, u64 disk, u16 name length, name bytes

Nodes are numbered afresh, used ones only, so a parent names the new number.
Roughly 15 bytes and the name a node: a home directory of 2.6 million is 70 to 80 MB.
*/

@(private)
BASELINE_MAGIC :: "LEITABL1"

/*
Keep `t`, a finished scan of `place`, in the file at `path` with `cursor`. Whether
it was kept: a baseline that cannot be written is no reason to fail the scan, only
to read the place whole next time.
*/
baseline_save :: proc(path, place: string, t: ^scan.Tree, cursor: changes.Cursor) -> bool {
	count := scan.slots(t)
	if t.root >= count {
		return false
	}
	renumber := make([]u32, count)
	defer delete(renumber)
	used: u32
	for i in 0 ..< count {
		f := scan.node_flags(scan.node(t, i))
		renumber[i] = scan.NO_NODE
		if .Used in f && .Settled in f {
			renumber[i] = used
			used += 1
		}
	}
	if renumber[t.root] == scan.NO_NODE {
		return false
	}

	out := make([dynamic]u8)
	defer delete(out)
	append(&out, BASELINE_MAGIC)
	put_u8(&out, u8(cursor.source))
	put_u64(&out, cursor.volume[0])
	put_u64(&out, cursor.volume[1])
	put_u64(&out, cursor.journal)
	put_u64(&out, u64(cursor.position))
	put_u64(&out, u64(cursor.full))
	put_u32(&out, u32(len(place)))
	append(&out, place)
	put_u32(&out, used)
	put_u32(&out, renumber[t.root])
	for i in 0 ..< count {
		if renumber[i] == scan.NO_NODE {
			continue
		}
		n := scan.node(t, i)
		parent := renumber[n.parent] if n.parent < count else scan.NO_NODE
		if parent == scan.NO_NODE {
			parent = renumber[i] // an orphan, or the root: it holds itself
		}
		name := scan.name_of(t, i)
		put_u32(&out, parent)
		put_u8(
			&out,
			transmute(u8)(scan.node_flags(n) & {.Directory, .Reparse, .Extra_Name, .Mount}),
		)
		put_u64(&out, n.disk)
		put_u16(&out, u16(len(name)))
		append(&out, name)
	}

	temporary := strings.concatenate({path, ".new"}, context.temp_allocator)
	if dir, _ := os.split_path(path); dir != "" {
		_ = os.make_directory_all(dir)
	}
	if os.write_entire_file(temporary, out[:]) != nil {
		os.remove(temporary)
		return false
	}
	if os.rename(temporary, path) != nil {
		os.remove(temporary)
		return false
	}
	return true
}

/*
Read the baseline at `path` into `t`, which must be fresh, with the cursor kept with
it. Not ok, with why, when there is none, it is of another place, or it cannot be
read whole: any of which means the place is read whole.
*/
baseline_load :: proc(
	path, place: string,
	t: ^scan.Tree,
) -> (
	cursor: changes.Cursor,
	why: string,
	ok: bool,
) {
	data, read_err := os.read_entire_file(path, context.allocator)
	if read_err != nil {
		return {}, "no earlier scan of this place was kept whole", false
	}
	defer delete(data)
	r := Reader{data, 0, true}
	if string(take(&r, len(BASELINE_MAGIC))) != BASELINE_MAGIC {
		return {}, "the scan kept of this place is of another version", false
	}
	cursor.source = changes.Source(take_u8(&r))
	cursor.volume[0] = take_u64(&r)
	cursor.volume[1] = take_u64(&r)
	cursor.journal = take_u64(&r)
	cursor.position = i64(take_u64(&r))
	cursor.full = i64(take_u64(&r))
	kept_place := string(take(&r, int(take_u32(&r))))
	if !r.ok || kept_place != place {
		return {}, "the scan kept is of another place", false
	}
	count := take_u32(&r)
	root := take_u32(&r)
	if !r.ok || count == 0 || root >= count {
		return {}, "the scan kept of this place could not be read", false
	}
	if scan.tree_init(t, 1) != nil || scan.reserve(t, count) != nil {
		scan.tree_destroy(t)
		return {}, "no room to read the scan kept of this place", false
	}
	w := scan.writer(t, 0)
	for i in 0 ..< count {
		parent := take_u32(&r)
		flags := transmute(scan.Node_Flags)take_u8(&r)
		disk := take_u64(&r)
		name := string(take(&r, int(take_u16(&r))))
		if !r.ok || parent >= count {
			scan.tree_destroy(t)
			return {}, "the scan kept of this place is cut short", false
		}
		n := scan.node(t, i)
		n.parent = parent
		n.disk = disk
		n.name = scan.intern(&w, name)
		scan.node_publish(n, flags | {.Used, .Settled})
	}
	t.root = root
	return cursor, "", true
}

@(private = "file")
Reader :: struct {
	data: []u8,
	at:   int,
	ok:   bool,
}

@(private = "file")
take :: proc(r: ^Reader, n: int) -> []u8 {
	if !r.ok || n < 0 || r.at + n > len(r.data) {
		r.ok = false
		return nil
	}
	defer r.at += n
	return r.data[r.at:][:n]
}

@(private = "file")
take_u8 :: proc(r: ^Reader) -> u8 {
	b := take(r, 1)
	return b[0] if r.ok else 0
}

@(private = "file")
take_u16 :: proc(r: ^Reader) -> u16 {
	v, _ := endian.get_u16(take(r, 2), .Little)
	return v
}

@(private = "file")
take_u32 :: proc(r: ^Reader) -> u32 {
	v, _ := endian.get_u32(take(r, 4), .Little)
	return v
}

@(private = "file")
take_u64 :: proc(r: ^Reader) -> u64 {
	v, _ := endian.get_u64(take(r, 8), .Little)
	return v
}

@(private = "file")
put_u8 :: proc(out: ^[dynamic]u8, v: u8) {
	append(out, v)
}

@(private = "file")
put_u16 :: proc(out: ^[dynamic]u8, v: u16) {
	b: [2]u8
	endian.put_u16(b[:], .Little, v)
	append(out, ..b[:])
}

@(private = "file")
put_u32 :: proc(out: ^[dynamic]u8, v: u32) {
	b: [4]u8
	endian.put_u32(b[:], .Little, v)
	append(out, ..b[:])
}

@(private = "file")
put_u64 :: proc(out: ^[dynamic]u8, v: u64) {
	b: [8]u8
	endian.put_u64(b[:], .Little, v)
	append(out, ..b[:])
}
