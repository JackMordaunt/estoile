package leita_view

import "core:path/filepath"
import "core:strings"

import "jm:ui"
import "jm:ui/design"
import "jm:ui/ops"
import "jm:ui/primer"
import tok "jm:ui/primer/tokens"

import "../../human"
import "../../kinds"
import "../query"

/*
Searching the scan.

The magnifier beside the location bar, or Ctrl+F, turns the bar into a search
field. Whatever is typed there is searched for across everything the scan has
found, as fzf finds things (query.Search), and while there is a term the charts
and the side column give way to what it found: a list, or a grid, of the entries
that match, best first, each with its icon, its name and the folder it is in,
the characters that matched marked, and its size. Escape, the field's clear
button, or leaving it empty puts the location back.

The host answers each term once it has searched the scan for it, and again as
the scan finds more; until a new term is answered, what the last one found stays,
so typing never blanks the list. A click on a folder opens it in the charts, on
a file opens the folder holding it; a right click offers what the charts' rows
do.

Each entry's icon says what it is, by its name (package kinds); a picture the
host can read shows itself instead, as a thumbnail it makes for the entries on
screen only (query.Thumb).
*/

// ROW_HEIGHT is a list row's height: a name over the folder it is in.
ROW_HEIGHT :: f32(48)

// ROW_ICON is the icon's size in a list row.
ROW_ICON :: f32(32)

// TILE_WIDTH is the narrowest a grid tile is, TILE_HEIGHT its height, and
// TILE_ICON its icon's size. Tiles share out the width across them.
TILE_WIDTH  :: f32(136)
TILE_HEIGHT :: f32(160)
TILE_ICON   :: f32(72)

// THUMB_PX is the thumbnail asked for, in pixels: the grid's icon at twice the
// points, for a sharp one on a dense screen. A list row draws it smaller.
THUMB_PX :: 160

// search_term is what the search field holds, trimmed: "" when the location
// bar is not searching.
search_term :: proc(m: ^Model) -> string {
	if !m.searching {
		return ""
	}
	return strings.trim_space(ui.text_string(&m.search))
}

// open_search turns the location bar into the search field, with focus.
open_search :: proc(m: ^Model) {
	m.searching, m.search_focus = true, true
}

// close_search puts the location bar back, forgetting the term.
close_search :: proc(m: ^Model) {
	m.searching, m.search_focus = false, false
	ui.text_set(&m.search, "")
	m.search_list = {}
}

// search_button is the magnifier beside the location bar.
@(private)
search_button :: proc(gtx: ^ui.Ctx, m: ^Model) {
	if primer.icon_button(gtx, .Search, tr(.Search), .Invisible) {
		open_search(m)
	}
}

// search_field is the location bar searching: Escape, its clear button, or
// focus leaving it empty, puts the location back.
@(private)
search_field :: proc(gtx: ^ui.Ctx, m: ^Model) {
	field := primer.text_input(
		gtx,
		&m.search,
		placeholder = tr(.Search_Placeholder),
		leading = .Search,
		action = .X,
		action_name = tr(.Search_Close),
		block = true,
		name = tr(.Search),
	)
	if m.search_focus {
		if field.focused {
			m.search_focus = false
		} else {
			ui.focus_request(gtx, field.id)
		}
	}
	if field.changed {
		m.search_list = {} // a new term: its best are at the top
	}
	for e in ui.events(gtx, field.id) {
		if e.kind == .Key && e.key == .Escape {
			close_search(m)
			return
		}
	}
	if field.action || !field.focused && !m.search_focus && search_term(m) == "" {
		close_search(m)
	}
}

/*
search_answer is what the host found for the term, or, until it answers that,
for the last term it did answer in this scan; nil before any.
*/
@(private)
search_answer :: proc(gtx: ^ui.Ctx, m: ^Model, term: string) -> ^query.Search_Result {
	q := query.Search {
		generation = m.generation,
		term       = term,
	}
	if r, _ := ui.need(gtx, q, query.Search_Result); r != nil && r.generation == m.generation {
		if m.search_held != term || m.search_scan != m.generation {
			delete(m.search_held)
			m.search_held = strings.clone(term)
			m.search_scan = m.generation
		}
		return r
	}
	if m.search_held == "" || m.search_scan != m.generation {
		return nil
	}
	held := query.Search {
		generation = m.generation,
		term       = m.search_held,
	}
	if r, _ := ui.need(gtx, held, query.Search_Result); r != nil && r.generation == m.generation {
		return r
	}
	return nil
}

// Results is what a list or grid of hits draws from, item by item.
@(private)
Results :: struct {
	m:       ^Model,
	r:       ^query.Search_Result,
	columns: int,
	tile:    f32, // a tile's width
}

// search_results is the window's main content while there is a term: what was
// found, how much, and the switch between a list and a grid.
@(private)
search_results :: proc(gtx: ^ui.Ctx, m: ^Model, term: string) {
	ui.column(gtx, gap = 8, align = .Fill)
	r := search_answer(gtx, m, term)
	if ui.inset(gtx, {right = PAD}) {
		// Justified rather than flexible: the summary changes width as the
		// scan goes on, and a flexible share is the last frame's.
		if ui.row(gtx, gap = 8, align = .Center, justify = .Space_Between) {
			if ui.row(gtx, gap = 8, align = .Center) {
				if r != nil && !r.complete {
					primer.spinner(gtx, .Small, label = tr(.Search_Scanning))
				}
				primer.text(gtx, search_summary(gtx, r), color = primer.color(.Fg_Color_Muted))
			}
			layouts := [?]primer.Segment {
				{label = tr(.Layout_List), icon = .List_Unordered},
				{label = tr(.Layout_Grid), icon = .Apps},
			}
			at := 1 if m.search_grid else 0
			if primer.segmented_control(
				gtx,
				layouts[:],
				&at,
				name = tr(.Search_Layout),
				size = .Small,
				hide_labels = true,
			) {
				m.search_grid = at == 1
				m.search_list = {}
			}
		}
	}
	if r == nil {
		for i in 0 ..< 6 {
			primer.skeleton_box(gtx, height = ROW_HEIGHT - 8, delay = .Short, key = u64(i + 1))
		}
		return
	}
	if len(r.hits) == 0 {
		if r.complete && r.term == term {
			if ui.inset(gtx, {top = 24}) {
				primer.text(
					gtx,
					trf(gtx, .Search_None, term),
					.Large,
					color = primer.color(.Fg_Color_Muted),
				)
			}
		}
		return
	}
	ui.flexible(gtx, 1)
	results := Results {
		m = m,
		r = r,
	}
	if !m.search_grid {
		ui.list(gtx, &m.search_list, len(r.hits), hit_row, &results)
		return
	}
	width := gtx.constraints.max.x - PAD
	if !ui.is_finite(width) {
		width = 4 * TILE_WIDTH
	}
	results.columns = max(int(width / TILE_WIDTH), 1)
	results.tile = width / f32(results.columns)
	rows := (len(r.hits) + results.columns - 1) / results.columns
	ui.list(gtx, &m.search_list, rows, tile_row, &results)
}

// search_summary is how many entries matched, in a line.
@(private)
search_summary :: proc(gtx: ^ui.Ctx, r: ^query.Search_Result) -> string {
	switch {
	case r == nil || r.total == 0:
		return "" // what is missing is said where the hits would be
	case r.total > len(r.hits):
		return trf(gtx, .Search_Best, len(r.hits), r.total)
	case:
		return trf(gtx, .Search_Matches, r.total)
	}
}

// hit_row is a list's row i: icon, name over folder, and size.
@(private)
hit_row :: proc(gtx: ^ui.Ctx, i: int, user: rawptr) {
	res := (^Results)(user)
	m := res.m
	h := res.r.hits[i]
	ui.inset(gtx, {right = PAD})
	p := ui.widget_open(gtx, key = u64(h.node) + 1)
	width := gtx.constraints.max.x
	if !ui.is_finite(width) {
		width = 640
	}
	box := ops.Rect{0, 0, width, ROW_HEIGHT}
	c := design.control(gtx, p.id, box, .Live)
	paint_hover(gtx, c, box)

	name, folder := hit_parts(h)
	entry_icon(gtx, h, {8, (ROW_HEIGHT - ROW_ICON) / 2}, ROW_ICON)
	size_st := primer.text_style(.Small)
	size := design.layout_style(
		gtx,
		human.bytes(h.bytes),
		size_st,
		primer.font_for(gtx, size_st.weight),
	)
	size_at := width - 12 - size.width
	design.draw_paragraph(
		gtx,
		size,
		{size_at, (ROW_HEIGHT - size.height) / 2},
		primer.color(.Fg_Color_Default),
	)
	x := 8 + ROW_ICON + 12
	room := size_at - 16 - x
	marked_line(
		gtx,
		name,
		h.marks,
		h.name_at,
		{x, 5},
		room,
		primer.text_style(.Medium),
		.Fg_Color_Default,
	)
	marked_line(
		gtx,
		folder,
		h.marks,
		0,
		{x, 27},
		room,
		primer.text_style(.Small),
		.Fg_Color_Muted,
		keep_end = true,
	)

	hit_close(gtx, m, &p, c, h, name, folder, box)
}

// tile_row is a grid's row i: as many tiles as fit across.
@(private)
tile_row :: proc(gtx: ^ui.Ctx, i: int, user: rawptr) {
	res := (^Results)(user)
	ui.row(gtx, gap = 0, align = .Start)
	for col in 0 ..< res.columns {
		at := i * res.columns + col
		if at >= len(res.r.hits) {
			break
		}
		hit_tile(gtx, res.m, res.r.hits[at], res.tile)
	}
}

// hit_tile is a grid's tile, width across: the icon large, then the name, the
// folder it is in and its size, each centred under it.
@(private)
hit_tile :: proc(gtx: ^ui.Ctx, m: ^Model, h: query.Hit, width: f32) {
	p := ui.widget_open(gtx, key = u64(h.node) + 1)
	box := ops.Rect{4, 4, width - 8, TILE_HEIGHT - 8}
	c := design.control(gtx, p.id, box, .Live)
	paint_hover(gtx, c, box)

	name, folder := hit_parts(h)
	entry_icon(gtx, h, {(width - TILE_ICON) / 2, 14}, TILE_ICON)
	room := width - 24
	y := 22 + TILE_ICON
	// Each line centred, unless it fills the tile.
	centred :: proc(gtx: ^ui.Ctx, s: string, st: tok.Type_Style, room: f32) -> f32 {
		para := design.layout_style(gtx, s, st, primer.font_for(gtx, st.weight))
		return max((room - para.width) / 2, 0)
	}
	st := primer.text_style(.Small)
	at := centred(gtx, name, st, room)
	marked_line(gtx, name, h.marks, h.name_at, {12 + at, y}, room - at, st, .Fg_Color_Default)
	y += st.line_height
	at = centred(gtx, folder, st, room)
	marked_line(
		gtx,
		folder,
		h.marks,
		0,
		{12 + at, y},
		room - at,
		st,
		.Fg_Color_Muted,
		keep_end = true,
	)
	y += st.line_height + 2
	bytes := human.bytes(h.bytes)
	marked_line(
		gtx,
		bytes,
		nil,
		0,
		{12 + centred(gtx, bytes, st, room), y},
		room,
		st,
		.Fg_Color_Muted,
	)

	hit_close(gtx, m, &p, c, h, name, folder, box)
}

// hit_close finishes a row or a tile: it takes the pointer, says what it is,
// and does what a click or a right click asks.
@(private)
hit_close :: proc(
	gtx: ^ui.Ctx,
	m: ^Model,
	p: ^ui.Placement,
	c: design.Control,
	h: query.Hit,
	name, folder: string,
	box: ops.Rect,
) {
	design.listen(gtx, c.st, p.id, box, design.CLICK_KINDS, .Pointer)
	ops.tag(gtx.scene, p.id, name)
	ui.semantics(
		gtx,
		p,
		{role = .List_Item, label = trf(gtx, .Search_Hit, name, human.bytes(h.bytes), folder)},
	)
	ui.widget_close(gtx, p, {size = {box.x * 2 + box.w, box.y * 2 + box.h}})
	row_menu(
		gtx,
		m,
		.Search,
		ui.last_widget(gtx),
		{node = h.node, name = name, directory = h.directory},
	)
	if c.clicked {
		// A folder opens; a file opens where it is.
		open(m, h.node if h.directory else h.parent)
	}
}

// paint_hover is a hit's background as the pointer or focus is on it.
@(private)
paint_hover :: proc(gtx: ^ui.Ctx, c: design.Control, box: ops.Rect) {
	shape := ops.Round_Rect{box, tok.BORDER_RADIUS_MEDIUM}
	if c.hovered || c.pressed {
		ops.fill(gtx.scene, shape, primer.color(.Control_Transparent_Bg_Color_Hover))
	}
	design.paint_focus_visible_ring(
		gtx,
		c,
		box,
		design.corners_all(tok.BORDER_RADIUS_MEDIUM),
		primer.focus_outline(-2),
	)
}

// hit_parts are a hit's name and the folder holding it, as its path spells
// them.
@(private)
hit_parts :: proc(h: query.Hit) -> (name, folder: string) {
	at := min(int(h.name_at), len(h.path))
	name = h.path[at:]
	folder = h.path[:at]
	// The separator between them belongs to neither, unless it is the root.
	if len(folder) > 1 && (folder[len(folder) - 1] == '/' || folder[len(folder) - 1] == '\\') {
		folder = folder[:len(folder) - 1]
	}
	return
}

/*
marked_line draws s on one line at at, within room, with the stretches of marks
that fall in it marked: the marks are offsets into a path, of which s starts at
base. A line too long for room ends in an ellipsis, or, with keep_end, as a
folder is, keeps its end and fades out at its start.
*/
@(private)
marked_line :: proc(
	gtx: ^ui.Ctx,
	s: string,
	marks: []query.Mark,
	base: u32,
	at: ops.Point,
	room: f32,
	st: tok.Type_Style,
	ink: tok.Role,
	keep_end := false,
) {
	if room <= 0 || s == "" {
		return
	}
	font := primer.font_for(gtx, st.weight)
	para: ui.Paragraph
	x := at.x
	if keep_end {
		para = design.layout_style(gtx, s, st, font)
		if para.width > room {
			x = at.x + room - para.width
		}
	} else {
		para = design.layout_style(gtx, s, st, font, width = room, max_lines = 1)
	}
	ops.clip_push(gtx.scene, ops.Rect{at.x, at.y - 2, room, para.height + 4})
	defer ops.clip_pop(gtx.scene)
	pos := ops.Point{x, at.y}
	design.draw_paragraph(gtx, para, pos, primer.color(ink))
	mark_bg := primer.color(.Bg_Color_Accent_Muted)
	mark_fg := primer.color(.Fg_Color_Accent)
	for mk in marks {
		lo := int(mk.from) - int(base)
		hi := int(mk.to) - int(base)
		if hi <= 0 || lo >= len(s) {
			continue
		}
		for r in ui.paragraph_selection_rects(para, max(lo, 0), min(hi, len(s)), gtx.allocator) {
			rect := ops.Rect{pos.x + r.x, pos.y + r.y, r.w, r.h}
			ops.fill(gtx.scene, ops.Round_Rect{rect, 3}, mark_bg)
			ops.clip_push(gtx.scene, rect)
			ui.paragraph_draw(gtx.scene, para, pos, mark_fg)
			ops.clip_pop(gtx.scene)
		}
	}
	if keep_end && para.width > room {
		bg := primer.color(.Bg_Color_Default)
		clear := bg
		clear[3] = 0
		stops := make([]ops.Gradient_Stop, 2, gtx.allocator)
		stops[0], stops[1] = {0, bg}, {1, clear}
		edge := ops.Rect{at.x, at.y - 2, LOCATION_FADE, para.height + 4}
		ops.fill(
			gtx.scene,
			edge,
			ops.Linear_Gradient{{edge.x, 0}, {edge.x + LOCATION_FADE, 0}, stops},
		)
	}
}

// THUMBNAILS are the pictures the host is asked to make a thumbnail of, by
// extension: those jm/examples/files/fs/fs.odin's is_image hands Blend2D.
@(private, rodata)
THUMBNAILS := [?]string{".png", ".jpg", ".jpeg", ".bmp", ".qoi"}

/*
entry_icon draws a hit's icon in a square size across at at: a picture's
thumbnail once the host has made it, else an icon for what the entry is, in the
colour the charts give its kind.
*/
@(private)
entry_icon :: proc(gtx: ^ui.Ctx, h: query.Hit, at: ops.Point, size: f32) {
	name := h.path[min(int(h.name_at), len(h.path)):]
	if !h.directory && thumbnailed(name) {
		thumb, _ := ui.need(gtx, query.Thumb{path = h.path, px = THUMB_PX}, query.Thumb_Result)
		if thumb != nil && thumb.image != "" {
			id := ops.add_image(gtx.scene, thumb.image)
			ops.image(gtx.scene, id, ops.Rect{at.x, at.y, size, size})
			return
		}
	}
	kind := kinds.of(name, h.directory)
	ic := icon_of(name, kind)
	colour := primer.color(.Fg_Color_Accent) if kind == .Folder else kind_colour(kind)
	if kind == .Other {
		colour = primer.color(.Fg_Color_Muted)
	}
	// A touch inside the square, so an icon with margins of its own sits as
	// large as a thumbnail that fills it.
	inner := size * 0.84
	primer.icon(gtx, ic, {at.x + (size - inner) / 2, at.y + (size - inner) / 2}, inner, colour)
}

@(private)
thumbnailed :: proc(name: string) -> bool {
	ext := filepath.ext(name)
	for t in THUMBNAILS {
		if strings.equal_fold(ext, t) {
			return true
		}
	}
	return false
}

// AUDIO are the multimedia files that are sound, not pictures that move.
@(private, rodata)
AUDIO := [?]string{".mp3", ".flac", ".wav", ".ogg", ".opus", ".m4a", ".aac"}

// DISK_IMAGES are the archives that are a whole disk or machine.
@(private, rodata)
DISK_IMAGES := [?]string{".iso", ".img", ".dmg", ".qcow2", ".vdi", ".vmdk", ".vhd", ".vhdx"}

// icon_of is the icon for an entry called name of kind, a kind narrowed by
// its extension where an icon says more.
@(private)
icon_of :: proc(name: string, kind: kinds.Kind) -> primer.Icon {
	ext := filepath.ext(name)
	one_of :: proc(ext: string, set: []string) -> bool {
		for e in set {
			if strings.equal_fold(ext, e) {
				return true
			}
		}
		return false
	}
	switch kind {
	case .Folder:
		return .File_Directory_Fill
	case .Cache:
		return .Cache
	case .Multimedia:
		return .Unmute if one_of(ext, AUDIO[:]) else .Video
	case .Image:
		return .Image
	case .Archive:
		return .Database if one_of(ext, DISK_IMAGES[:]) else .File_Zip
	case .Document:
		return .Book
	case .Text:
		switch {
		case strings.equal_fold(ext, ".md"):
			return .Markdown
		case strings.equal_fold(ext, ".log"):
			return .Log
		case one_of(ext, {".txt", ".csv"}):
			return .File
		}
		return .File_Code
	case .Binary:
		return .File_Binary
	case .Other:
	}
	return .File
}
