package leita_view

import "core:testing"

import "jm:ui"
import "jm:ui/ops"
import "jm:ui/primer"
import "jm:ui/render"

import "../query"

// The search view in a probe, the host's answers made up by hand.

@(private = "file")
Search_Rig :: struct {
	m: Model,
	h: render.Headless,
}

@(private = "file")
searching_open :: proc(s: ^Search_Rig) {
	model_init(&s.m, "/top")
	s.m.settings_read = true
	fonts := []ops.Font_Ref {
		{0, ui.default_font(), 400},
		{1, ui.default_font(), 500},
		{2, ui.default_font(), 600},
		{3, ui.default_font(), 400},
	}
	render.headless_init(&s.h, view, &s.m, {1000, 700}, fonts)
	ui.probe_deliver(
		&s.h.p,
		query.Progress{},
		query.Progress_Result{generation = 1, state = .Scanning, target = "/top"},
	)
	settle(&s.h.p)
}

// settle runs frames until a change has laid out: a row lays out what it holds
// by the sizes they had the frame before.
@(private = "file")
settle :: proc(p: ^ui.Probe) {
	ui.probe_frame(p)
	ui.probe_frame(p)
}

@(private = "file")
searching_close :: proc(s: ^Search_Rig) {
	render.headless_destroy(&s.h)
	model_destroy(&s.m)
}

/*
	/top/src/          node 1
	/top/src/main.odin node 2
	/top/main/         node 4
*/
@(private = "file")
found := query.Search_Result {
	generation = 1,
	term       = "main",
	total      = 2,
	hits       = {
		{
			node = 4,
			parent = 0,
			path = "/top/main",
			name_at = 5,
			marks = {{5, 9}},
			bytes = 4096,
			directory = true,
		},
		{
			node = 2,
			parent = 1,
			path = "/top/src/main.odin",
			name_at = 9,
			marks = {{9, 13}},
			bytes = 100,
		},
	},
}

@(test)
the_magnifier_turns_the_location_into_a_search_and_escape_back :: proc(t: ^testing.T) {
	s: Search_Rig
	searching_open(&s)
	defer searching_close(&s)
	p := &s.h.p

	testing.expect(t, ui.probe_click(p, "Search"), "the magnifier is beside the location")
	settle(p)
	settle(p)
	testing.expect(t, s.m.searching)
	testing.expect_value(t, ui.probe_focus_name(p), "Search")

	// Typing asks the host; until it answers, a skeleton.
	ui.probe_type(p, "main")
	settle(p)
	q := query.Search {
		generation = 1,
		term       = "main",
	}
	testing.expect(t, ui.probe_needs_q(p, q), "the term is asked for")
	ui.probe_deliver(p, q, found)
	settle(p)
	testing.expect(t, ui.probe_tagged(p, "main"), "the folder is listed")
	testing.expect(t, ui.probe_tagged(p, "main.odin"), "the file is listed")
	testing.expect(t, ui.probe_tagged(p, "2 matches"))
	testing.expect(t, !ui.probe_tagged(p, "Sunburst chart"), "the charts give way")

	// A new term keeps what the last found until it is answered.
	ui.probe_type(p, "x")
	settle(p)
	testing.expect(t, ui.probe_needs_q(p, query.Search{generation = 1, term = "mainx"}))
	testing.expect(t, ui.probe_tagged(p, "main.odin"), "the last answer is held")
	ui.probe_deliver(
		p,
		query.Search{generation = 1, term = "mainx"},
		query.Search_Result{generation = 1, term = "mainx", complete = true},
	)
	settle(p)
	testing.expect(t, ui.probe_tagged(p, "Nothing matches “mainx”"))

	ui.probe_key(p, .Escape)
	settle(p)
	testing.expect(t, !s.m.searching, "Escape puts the location back")
	testing.expect_value(t, ui.text_string(&s.m.search), "")

	// Ctrl+F opens it again, empty.
	ui.probe_key(p, .F, {.Ctrl})
	settle(p)
	testing.expect(t, s.m.searching)
	testing.expect_value(t, ui.text_string(&s.m.search), "")
}

@(test)
a_hit_opens_its_folder_and_the_grid_shows_the_same :: proc(t: ^testing.T) {
	s: Search_Rig
	searching_open(&s)
	defer searching_close(&s)
	p := &s.h.p

	open_search(&s.m)
	settle(p)
	settle(p)
	ui.probe_type(p, "main")
	settle(p)
	ui.probe_deliver(p, query.Search{generation = 1, term = "main"}, found)
	settle(p)

	// The grid lays the same hits out as tiles.
	testing.expect(t, ui.probe_click(p, "Grid"))
	settle(p)
	testing.expect(t, s.m.search_grid)
	testing.expect(t, ui.probe_tagged(p, "main.odin"))
	tile := ui.probe_bounds(p, "main.odin")
	testing.expectf(t, tile.w < 200 && tile.h > 100, "a tile, not a row: %v", tile)

	// A file opens the folder it is in, and the search gives way.
	testing.expect(t, ui.probe_click(p, "main.odin"))
	settle(p)
	testing.expect(t, !s.m.searching)
	testing.expect_value(t, s.m.dir, u32(1))
}

@(test)
icons_say_what_an_entry_is :: proc(t: ^testing.T) {
	testing.expect_value(t, icon_of("x", .Folder), primer.Icon.File_Directory_Fill)
	testing.expect_value(t, icon_of("song.FLAC", .Multimedia), primer.Icon.Unmute)
	testing.expect_value(t, icon_of("film.mkv", .Multimedia), primer.Icon.Video)
	testing.expect_value(t, icon_of("disk.iso", .Archive), primer.Icon.Database)
	testing.expect_value(t, icon_of("a.tar.gz", .Archive), primer.Icon.File_Zip)
	testing.expect_value(t, icon_of("README.md", .Text), primer.Icon.Markdown)
	testing.expect_value(t, icon_of("main.odin", .Text), primer.Icon.File_Code)
	testing.expect(t, thumbnailed("Photo.JPG"))
	testing.expect(t, !thumbnailed("photo.heic"), "Blend2D does not read it")
}
