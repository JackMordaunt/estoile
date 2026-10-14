#+build !js
package survey

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

import "../scan"
import "../walk"

/*
Time the rollup that follows a folded walk, when LEITA_ROLLUP is set. Off
otherwise, so `just test` stays quick.

The places are the ones the 2026-10-12 fd benchmark measured: /usr, ~/Source, ~.
*/
@(test)
bench_the_rollup_after_a_folded_walk :: proc(t: ^testing.T) {
	if os.get_env("LEITA_ROLLUP", context.temp_allocator) == "" {
		return
	}
	context.allocator = runtime.heap_allocator()
	home := os.get_env("HOME", context.allocator)
	source := strings.concatenate({home, "/Source"}, context.allocator)
	defer delete(source)
	defer delete(home)
	places := [3]string{"/usr", source, home}
	for place in places {
		if !os.exists(place) {
			fmt.printfln("rollup bench skip %s: not there", place)
			continue
		}
		time_folded(t, place)
	}
}

@(private = "file")
time_folded :: proc(t: ^testing.T, place: string) {
	target, _, err := scan.resolve(place)
	testing.expect_value(t, err, scan.Error.None)
	defer scan.target_destroy(&target)
	wcfg := walk.Config {
		media = target.media,
		pace  = .Full,
		fold  = true,
	}
	tree: scan.Tree
	testing.expect_value(t, scan.tree_init(&tree, walk.width(wcfg)), scan.Error.None)
	defer scan.tree_destroy(&tree)
	root := scan.location(target)
	defer delete(root)

	read_at := time.tick_now()
	testing.expect_value(t, walk.read(root, &tree, wcfg), walk.Error.None)
	read_ms := time.duration_milliseconds(time.tick_since(read_at))
	testing.expect(t, tree.folded != nil && tree.folded.complete, "the walk did not fold")

	count := int(scan.slots(&tree))
	roll: Rollup
	defer rollup_destroy(&roll)
	roll.linked = true
	fold_at := time.tick_now()
	rollup_advance(&roll, &tree)
	fold_ms := time.duration_milliseconds(time.tick_since(fold_at))
	root_total := total(&roll, tree.root)

	got := make([]u64, count)
	defer delete(got)
	for i in 0 ..< u32(count) {
		got[i] = total(&roll, i)
	}

	saved := tree.folded
	tree.folded = nil
	defer tree.folded = saved
	for i in 0 ..< u32(count) {
		scan.node(&tree, i).dir = 0
	}
	plain: Rollup
	defer rollup_destroy(&plain)
	plain.linked = true
	plain_at := time.tick_now()
	rollup_advance(&plain, &tree)
	plain_ms := time.duration_milliseconds(time.tick_since(plain_at))

	same := true
	for i in 0 ..< u32(count) {
		if total(&plain, i) != got[i] {
			same = false
			break
		}
	}
	fmt.printfln(
		"%s: %d nodes, walk %.0f ms, folded rollup %.1f ms, serial rollup %.1f ms, match %v, root %d",
		place,
		count,
		read_ms,
		fold_ms,
		plain_ms,
		same,
		root_total,
	)
	testing.expect(t, same)
	testing.expect_value(t, roll.pending, 0)
	testing.expect_value(t, plain.pending, 0)
}
