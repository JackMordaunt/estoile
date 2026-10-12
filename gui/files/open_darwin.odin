#+build darwin
package leita_files

// open_default runs open(1) on path, which macOS's open(1) manual says opens a
// file as if double-clicked in the Finder, and says whether it exited 0.
open_default :: proc(path: string) -> bool {
	return run({"open", path})
}
