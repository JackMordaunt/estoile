package survey

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:testing"
import "core:time"

import "../scan"
import "../walk"

/*
What an update saves over reading a place whole, measure, when LEITA_BENCH asks: a
directory to read (one this writes a directory of its own into, and removes), or a
number of directories to make up under the temp directory, ten files each. Off
otherwise, so `just test` stays quick.

Three runs a pace, each warm from the one before: a whole read to keep the
baseline, a whole read without one, which is what a scheduled scan costs today, and
an update after one file is added. Gentle first, the pace the monitoring design
(card 41) gives a scheduled scan by default.
*/
@(test)
bench_an_update_against_a_whole_read :: proc(t: ^testing.T) {
	asked := os.get_env("LEITA_BENCH", context.temp_allocator)
	if asked == "" {
		return
	}
	place := asked
	made := false
	if dirs, is_count := strconv.parse_int(asked); is_count {
		place = place_make(t, dirs)
		made = true
	}
	defer if made {
		os.remove_all(place)
	}
	tmp, _ := os.temp_directory(context.temp_allocator)
	file := fmt.tprintf("%s%sleita-bench.tree", strings.trim_right(tmp, `\/`), scan.SEPARATOR)
	defer os.remove(file)
	target, choice, err := scan.resolve(place)
	testing.expect_value(t, err, scan.Error.None)
	defer scan.target_destroy(&target)

	// The heap, not the test runner's tracking allocator (mem.Tracking_Allocator,
	// which guards its map with a mutex), so the allocator is not what is measure.
	context.allocator = runtime.heap_allocator()
	for pace in ([]walk.Pace{.Gentle, .Full}) {
		os.remove(file)
		keep, _, nodes := measure(t, target, choice.engine, file, pace)
		whole, _, _ := measure(t, target, choice.engine, "", pace)
		changed := fmt.tprintf(
			"%s%sleita-bench-change",
			strings.trim_right(place, `\/`),
			scan.SEPARATOR,
		)
		testing.expect(t, os.make_directory(changed) == nil, "could not make a change")
		put(t, fmt.tprintf("%s%snew.txt", changed, scan.SEPARATOR), 4096)
		update, how, _ := measure(t, target, choice.engine, file, pace)
		os.remove_all(changed)
		testing.expect_value(t, how, Fill_Kind.Updated)
		fmt.printfln(
			"bench %s, %v pace, %d nodes: whole read keeping a baseline %.0f ms, whole read %.0f ms, update %.0f ms (%.1fx)",
			place,
			pace,
			nodes,
			time.duration_milliseconds(keep),
			time.duration_milliseconds(whole),
			time.duration_milliseconds(update),
			time.duration_seconds(whole) / max(time.duration_seconds(update), 1e-9),
		)
	}
}

@(private = "file")
measure :: proc(
	t: ^testing.T,
	target: scan.Target,
	engine: scan.Engine,
	file: string,
	pace: walk.Pace,
) -> (
	time.Duration,
	Fill_Kind,
	u64,
) {
	tree: scan.Tree
	testing.expect_value(t, scan.tree_init(&tree, 32), scan.Error.None)
	defer scan.tree_destroy(&tree)
	f := Fill {
		target = target,
		engine = engine,
		wcfg = {media = target.media, pace = pace},
		tree = &tree,
		baseline = file,
	}
	defer fill_destroy(&f)
	start := time.tick_now()
	fill_run(&f)
	took := time.tick_since(start)
	testing.expectf(t, problem(&f) == "", "%s", problem(&f))
	return took, f.how, u64(scan.slots(&tree))
}

// A place of `dirs` directories in a hundred groups, ten small files each, made
// up under the temp directory, then left 3 s, past changes.SLACK's 2 s on Linux,
// so a probe started after it reads none of it again.
@(private = "file")
place_make :: proc(t: ^testing.T, dirs: int) -> string {
	tmp, _ := os.temp_directory(context.temp_allocator)
	root := fmt.tprintf("%s%sleita-bench", strings.trim_right(tmp, `\/`), scan.SEPARATOR)
	os.remove_all(root)
	testing.expect(t, os.make_directory(root) == nil, "could not make the place")
	for d in 0 ..< dirs {
		runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
		group := fmt.tprintf("%s%sg%02d", root, scan.SEPARATOR, d % 100)
		if d < 100 {
			testing.expect(t, os.make_directory(group) == nil, "could not make a group")
		}
		dir := fmt.tprintf("%s%sd%d", group, scan.SEPARATOR, d)
		testing.expect(t, os.make_directory(dir) == nil, "could not make a directory")
		for f in 0 ..< 10 {
			put(t, fmt.tprintf("%s%sf%d", dir, scan.SEPARATOR, f), 100 + f * 1000)
		}
	}
	time.sleep(3 * time.Second)
	return root
}
