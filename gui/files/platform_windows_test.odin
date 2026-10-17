#+build windows
package leita_files

import "core:testing"

// A path the shell has nothing at is Missing before it is asked, so it never
// meets the bin's prompt.
@(test)
trash_of_a_missing_path_is_missing :: proc(t: ^testing.T) {
	testing.expect_value(t, trash(`C:\leita-no-such-folder\no-such-file.txt`), Error.Missing)
}
