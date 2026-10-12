#+build linux
package leita_files

// open_default opens path as the desktop opens it, with xdg-open(1): a file
// in its default application, a folder in the file manager. It waits for
// xdg-open and says whether it exited 0.
open_default :: proc(path: string) -> bool {
	return run({"xdg-open", path})
}
