#+build !windows
package leita_files

import "core:os"

// symlink_directory makes path a link to the directory target. Windows has its
// own in link_windows_test.odin.
symlink_directory :: proc(target, path: string) -> bool {
	return os.symlink(target, path) == nil
}
