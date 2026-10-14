package search

import "core:log"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"

import "../scan"
import "../synth"

// --- the matcher -----------------------------------------------------------------

@(private = "file")
score_of :: proc(term, text: string) -> (i32, bool) {
	p := pattern_make(term)
	s := new(Scratch)
	defer free(s)
	return score(&p, text, s)
}

// highlight is text with each stretch score matched in brackets, for reading a
// highlight at a glance.
@(private = "file")
highlight :: proc(term, text: string) -> string {
	p := pattern_make(term)
	s := new(Scratch)
	defer free(s)
	if _, ok := score(&p, text, s); !ok {
		return "no match"
	}
	sb := strings.builder_make(context.temp_allocator)
	at := 0
	for sp in spans(&p, s, 0, context.temp_allocator) {
		strings.write_string(&sb, text[at:sp.from])
		strings.write_byte(&sb, '[')
		strings.write_string(&sb, text[sp.from:sp.to])
		strings.write_byte(&sb, ']')
		at = sp.to
	}
	strings.write_string(&sb, text[at:])
	return strings.to_string(sb)
}

// ranks is whether a beats b for term, both matching, logging why not.
@(private = "file")
ranks :: proc(term, a, b: string) -> bool {
	sa, oka := score_of(term, a)
	sb, okb := score_of(term, b)
	if !oka || !okb || sa <= sb {
		log.errorf("%q: %q (%d, %v) should beat %q (%d, %v)", term, a, sa, oka, b, sb, okb)
		return false
	}
	return true
}

@(test)
a_term_must_appear_in_order :: proc(t: ^testing.T) {
	_, ok := score_of("rpt", "report.pdf")
	testing.expect(t, ok)
	_, ok = score_of("tpr", "report.pdf")
	testing.expect(t, !ok, "out of order")
	_, ok = score_of("reportx", "report.pdf")
	testing.expect(t, !ok, "a character the text lacks")
	_, ok = score_of("ab", "a")
	testing.expect(t, !ok, "a term longer than the text")
}

@(test)
fzf_ranks_runs_word_starts_and_case_changes :: proc(t: ^testing.T) {
	// A run of matches beats the same characters spread out.
	testing.expect(t, ranks("abc", "abc.txt", "a_b_c.txt"))
	testing.expect(t, ranks("photo", "photos", "p-h-o-t-o"))
	// The start of a word beats the middle of one.
	testing.expect(t, ranks("rep", "report.pdf", "prepare.txt"))
	testing.expect(t, ranks("doc", "my-docs", "pseudocode"))
	// A case change starts a word too.
	testing.expect(t, ranks("fb", "FooBar.odin", "foobar.odin"))
	// Earlier in a run of equals is no better or worse: the shorter gap wins.
	testing.expect(t, ranks("ab", "a-b", "a---b"))
}

@(test)
highlights_are_the_matched_stretches :: proc(t: ^testing.T) {
	testing.expect_value(t, highlight("fbb", "foo bar baz"), "[f]oo [b]ar [b]az")
	testing.expect_value(t, highlight("repo", "my-report.txt"), "my-[repo]rt.txt")
	// The best placing, not the first: the run at the word start, not the r in
	// "dir".
	testing.expect_value(t, highlight("rep", "dir/report"), "dir/[rep]ort")
	testing.expect_value(t, highlight("odin", "main.odin"), "main.[odin]")
}

@(test)
case_is_smart_and_unicode_folds :: proc(t: ^testing.T) {
	// Lower case finds either; a capital asks for exactly that.
	testing.expect_value(t, highlight("rep", "Report"), "[Rep]ort")
	testing.expect_value(t, highlight("Rep", "report"), "no match")
	testing.expect_value(t, highlight("Rep", "Report"), "[Rep]ort")
	// Non-ASCII folds as ASCII does, and spans are bytes.
	testing.expect_value(t, highlight("über", "Über alles.txt"), "[Über] alles.txt")
	testing.expect_value(
		t,
		highlight("фото", "Фотографии"),
		"[Фото]графии",
	)
	testing.expect_value(
		t,
		highlight("写真", "写真フォルダ/写真.jpg"),
		"写真フォルダ/[写真].jpg",
	)
	// A slash finds either separator.
	testing.expect_value(t, highlight("a/b", `a\b`), `[a\b]`)
}

@(test)
latin_accents_fold_as_fzf_folds_them :: proc(t: ^testing.T) {
	// The name's accents fold to the term's letters, and spans keep the bytes
	// of the accented letters: é is two bytes and one character.
	testing.expect_value(t, highlight("resume", "Résumé.pdf"), "[Résumé].pdf")
	testing.expect_value(t, highlight("resume", "resume.pdf"), "[resume].pdf")
	testing.expect_value(t, highlight("sme", "Résumé.pdf"), "Ré[s]u[mé].pdf")
	testing.expect_value(t, highlight("pdf", "Résumé.pdf"), "Résumé.[pdf]")
	// The term's accents fold too, so either spelling finds either.
	testing.expect_value(t, highlight("résumé", "Resume.pdf"), "[Resume].pdf")
	testing.expect_value(t, highlight("résumé", "Résumé.pdf"), "[Résumé].pdf")
	testing.expect_value(t, highlight("nono", "Núñez/Ñoño.txt"), "Núñez/[Ñoño].txt")
	testing.expect_value(t, highlight("oresund", "Øresund"), "[Øresund]")
	// ß is one character, s, as fzf has it: a fold keeps every position.
	testing.expect_value(t, highlight("strase", "Straße"), "[Straße]")
	// Case survives the fold: a capital in the term still asks for one.
	testing.expect_value(t, highlight("Ecole", "École"), "[École]")
	testing.expect_value(t, highlight("Ecole", "école"), "no match")
	// The cheap test agrees with the score, through the ASCII byte path.
	p := pattern_make("resume")
	testing.expect(t, p.ascii, "an accented term folds to ASCII")
	testing.expect(t, matches(&p, "Résumé.pdf"))
	testing.expect(t, matches(&p, "CV/RÉSUMÉ"))
	testing.expect(t, !matches(&p, "Résumé"[:4]))
	// A folded name scores as its ASCII spelling: an accented letter is the
	// same class as its base.
	a, oka := score_of("resume", "Résumé.pdf")
	b, okb := score_of("resume", "resume.pdf")
	testing.expect(t, oka && okb)
	testing.expect_value(t, a, b)
	// r at the start, 16 + 9 * 2; the five after it in its run, 16 + 9 each.
	testing.expect_value(t, a, 159)
}

// The byte path over ASCII scores as it did before accents folded: these are
// worked by hand from the constants.
@(test)
ascii_scores_are_unchanged :: proc(t: ^testing.T) {
	// r at the start, 16 + 9 * 2; e and p in its run, 16 + 9 each.
	v, ok := score_of("rep", "report.pdf")
	testing.expect(t, ok)
	testing.expect_value(t, v, 84)
	// f at the start, 16 + 9 * 2; a gap of three, -3 - 1 - 1; b after a space,
	// 16 + 8.
	v, ok = score_of("fb", "foo bar")
	testing.expect(t, ok)
	testing.expect_value(t, v, 53)
}

@(test)
an_empty_term_matches_everything_and_marks_nothing :: proc(t: ^testing.T) {
	p := pattern_make("")
	testing.expect_value(t, p.count, 0)
	p = pattern_make("ab")
	testing.expect_value(t, p.count, 2)
	v, ok := score_of("", "anything")
	testing.expect(t, ok)
	testing.expect_value(t, v, 0)
	testing.expect_value(t, highlight("", "anything"), "anything")
	// Spaces are dropped: a term is the characters typed.
	testing.expect_value(t, highlight("my doc", "mydoc.txt"), "[mydoc].txt")
}

@(test)
a_long_text_is_scored_on_its_end :: proc(t: ^testing.T) {
	long := strings.concatenate(
		{strings.repeat("x", 2 * MAX_TEXT, context.temp_allocator), "/needle.txt"},
		context.temp_allocator,
	)
	marks := highlight("needle", long)
	testing.expect(t, strings.has_suffix(marks, "/[needle].txt"), marks)
}

// TEST_LIMIT is how many hits the tests' searches keep: fewer than the window's, so
// trimming to it is exercised by a made-up disk.
@(private = "file")
TEST_LIMIT :: 100

// --- the index over a tree ---------------------------------------------------------

/*
A tree written by hand:

	0  /top/
	1  /top/src/
	2  /top/src/main.odin
	3  /top/src/domain.c
	4  /top/main/
	5  /top/main/notes.txt
	6  /top/readme
*/
@(private = "file")
Small :: struct {
	tree: scan.Tree,
	w:    scan.Writer,
}

@(private = "file")
put :: proc(s: ^Small, i, parent: u32, name: string, flags: scan.Node_Flags) {
	n := scan.node(&s.tree, i)
	n.parent = parent
	n.name = scan.intern(&s.w, name)
	n.disk = 1
	scan.node_publish(n, flags)
}

@(private = "file")
small_make :: proc(t: ^testing.T, s: ^Small, upto := 7) {
	testing.expect(t, scan.tree_init(&s.tree) == nil)
	s.w = scan.writer(&s.tree)
	testing.expect(t, scan.reserve(&s.tree, 7) == nil)
	D :: scan.Node_Flags{.Used, .Settled, .Directory}
	F :: scan.Node_Flags{.Used, .Settled}
	rows := [?]struct {
		parent: u32,
		name:   string,
		flags:  scan.Node_Flags,
	} {
		{0, "/top", D},
		{0, "src", D},
		{1, "main.odin", F},
		{1, "domain.c", F},
		{0, "main", D},
		{4, "notes.txt", F},
		{0, "readme", F},
	}
	for r, i in rows[:upto] {
		put(s, u32(i), r.parent, r.name, r.flags)
	}
}

@(private = "file")
names_of :: proc(s: ^Search) -> []string {
	out := make([]string, len(s.top), context.temp_allocator)
	for h, i in s.top {
		out[i] = scan.name_of(s.tree, h.node)
	}
	return out
}

@(private = "file")
expect_names :: proc(t: ^testing.T, s: ^Search, want: []string, loc := #caller_location) {
	got := names_of(s)
	same := len(got) == len(want)
	for w, i in want {
		same = same && got[i] == w
	}
	testing.expectf(t, same, "hits %v, want %v", got, want, loc = loc)
}

@(test)
a_name_that_matches_ranks_above_a_path_that_does :: proc(t: ^testing.T) {
	sm: Small
	small_make(t, &sm)
	defer scan.tree_destroy(&sm.tree)
	s: Search
	search_init(&s, &sm.tree, "main", TEST_LIMIT)
	defer search_destroy(&s)
	testing.expect(t, search_step(&s, scan.slots(&sm.tree), true))
	// main/ and main.odin by their names; domain.c holds m-a-i-n in its name;
	// notes.txt only by the directory it is in. The top is never a hit.
	expect_names(t, &s, {"main", "main.odin", "domain.c", "notes.txt"})
	testing.expect_value(t, s.total, 4)

	scratch := new(Scratch)
	defer free(scratch)
	f := describe(&s, s.top[3].node, scratch, context.temp_allocator)
	// Joined with scan.SEPARATOR below the top, which keeps its own spelling.
	S :: scan.SEPARATOR
	testing.expect_value(t, f.path, "/top" + S + "main" + S + "notes.txt")
	testing.expect_value(t, f.path[f.name_at:], "notes.txt")
	testing.expect_value(t, len(f.spans), 1)
	testing.expect_value(t, f.path[f.spans[0].from:f.spans[0].to], "main")
	f = describe(&s, s.top[2].node, scratch, context.temp_allocator)
	testing.expect_value(t, f.path[f.spans[0].from:f.spans[0].to], "main")
	testing.expect_value(t, f.path[f.name_at:], "domain.c")
}

@(test)
a_path_term_crosses_separators :: proc(t: ^testing.T) {
	sm: Small
	small_make(t, &sm)
	defer scan.tree_destroy(&sm.tree)
	s: Search
	search_init(&s, &sm.tree, "src/m", TEST_LIMIT)
	defer search_destroy(&s)
	search_step(&s, scan.slots(&sm.tree), true)
	expect_names(t, &s, {"main.odin", "domain.c"})
	// The top's own name is not searched: "top" is in every path.
	search_destroy(&s)
	search_init(&s, &sm.tree, "top", TEST_LIMIT)
	search_step(&s, scan.slots(&sm.tree), true)
	testing.expect_value(t, s.total, 0)
}

@(test)
a_pass_takes_only_what_is_new_and_what_was_left :: proc(t: ^testing.T) {
	sm: Small
	small_make(t, &sm, upto = 4) // the first four written; the rest claimed, empty
	defer scan.tree_destroy(&sm.tree)
	s: Search
	search_init(&s, &sm.tree, "ma", TEST_LIMIT)
	defer search_destroy(&s)
	testing.expect(t, search_step(&s, scan.slots(&sm.tree), false))
	expect_names(t, &s, {"main.odin", "domain.c"})
	testing.expect(t, slice.equal(s.retry[:], []u32{4, 5, 6}), "the empty slots, for later")
	testing.expect(t, !s.final)

	// The rest arrive; a child before its directory is settled waits for it.
	put(&sm, 5, 4, "notes.txt", {.Used, .Settled})
	put(&sm, 4, 0, "main", {.Used, .Directory})
	search_step(&s, scan.slots(&sm.tree), false)
	expect_names(t, &s, {"main.odin", "domain.c"})
	// main/ unsettled, notes.txt under it, and readme's slot still empty.
	testing.expect(t, slice.equal(s.retry[:], []u32{4, 5, 6}))

	put(&sm, 4, 0, "main", {.Used, .Settled, .Directory})
	put(&sm, 6, 0, "readme", {.Used, .Settled})
	search_step(&s, scan.slots(&sm.tree), true)
	expect_names(t, &s, {"main", "main.odin", "domain.c", "notes.txt"})
	testing.expect_value(t, s.total, 4)
	testing.expect_value(t, len(s.retry), 0)
	testing.expect(t, s.final)
	testing.expect(t, !search_step(&s, scan.slots(&sm.tree), true), "nothing left to look at")
}

@(test)
a_cancelled_pass_changes_nothing :: proc(t: ^testing.T) {
	sm: Small
	small_make(t, &sm)
	defer scan.tree_destroy(&sm.tree)
	s: Search
	search_init(&s, &sm.tree, "main", TEST_LIMIT)
	defer search_destroy(&s)
	p := pass_begin(&s, scan.slots(&sm.tree), true)
	done := 0
	p.user = &done
	p.on_done = proc(p: ^Pass) {(^int)(p.user)^ += 1}
	pass_cancel(p)
	for &c in p.chunks {
		pass_run(&c)
	}
	testing.expect_value(t, done, 1)
	testing.expect(t, !pass_running(p))
	pass_end(&s, p)
	testing.expect_value(t, s.total, 0)
	testing.expect_value(t, s.bound, u32(0))
	testing.expect(t, !s.final)
	// The next pass looks at it all.
	search_step(&s, scan.slots(&sm.tree), true)
	testing.expect_value(t, s.total, 4)
}

// The made-up disk, searched pass after pass while it is read, ends with the
// same hits as one search of the finished disk.
@(test)
passes_during_a_scan_find_what_one_after_it_does :: proc(t: ^testing.T) {
	tree: scan.Tree
	testing.expect(t, scan.tree_init(&tree) == nil)
	defer scan.tree_destroy(&tree)
	Reading :: struct {
		tree: ^scan.Tree,
		done: b32,
	}
	r := Reading {
		tree = &tree,
	}
	reader := thread.create_and_start_with_poly_data(&r, proc(r: ^Reading) {
		synth.read("/", r.tree, {day = 3})
		sync.atomic_store(&r.done, true)
	})

	live: Search
	search_init(&live, &tree, "cache", TEST_LIMIT)
	defer search_destroy(&live)
	passes := 0
	for !sync.atomic_load(&r.done) {
		if search_step(&live, scan.slots(&tree), false) {
			passes += 1
		}
	}
	thread.join(reader)
	thread.destroy(reader)
	search_step(&live, scan.slots(&tree), true)
	testing.expect(t, live.final)
	testing.expect(t, passes > 1, "the scan was searched while it ran")

	after: Search
	search_init(&after, &tree, "cache", TEST_LIMIT)
	defer search_destroy(&after)
	search_step(&after, scan.slots(&tree), true)
	testing.expect(t, after.total > 100)
	testing.expect_value(t, live.total, after.total)
	testing.expect_value(t, len(live.top), len(after.top))
	same := len(live.top) == len(after.top)
	for h, i in after.top {
		same = same && live.top[i] == h
	}
	testing.expect(t, same, "the same hits, in the same order")
}

// The ceiling a search skips scoring under is never below a real score, or a
// hit that should rank would be counted and dropped.
@(test)
no_match_scores_above_the_ceiling :: proc(t: ^testing.T) {
	texts := []string {
		"a",
		"Cache",
		"Code Cache",
		"src/main.odin",
		"x/y/z",
		"FooBar",
		"a-b-c",
		"写真",
	}
	terms := []string{"a", "c", "ca", "cache", "src/m", "xyz", "fb", "abc", "写"}
	for text in texts {
		for term in terms {
			p := pattern_make(term)
			if v, ok := score_of(term, text); ok {
				testing.expectf(t, v <= ceiling(p.count), "%q in %q scored %d", term, text, v)
			}
		}
	}
}
