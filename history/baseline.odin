package leita_history

import "core:fmt"
import "core:hash"
import "core:path/filepath"

/*
baseline_path is where a scan of place keeps its whole tree between runs, for
survey.Fill.baseline: a file named for place's FNV-1a hash in a baselines folder
beside the store at store (default_path), "" when store is "". A baseline is not
history, which keeps only entries of at least KEPT_MIN, and is replaced on every
run rather than added to. In allocator.
*/
baseline_path :: proc(store, place: string, allocator := context.allocator) -> string {
	if store == "" {
		return ""
	}
	name := fmt.tprintf("%016x.tree", hash.fnv64a(transmute([]u8)place))
	path, _ := filepath.join(
		{filepath.dir(store), "baselines", name},
		allocator,
	)
	return path
}
