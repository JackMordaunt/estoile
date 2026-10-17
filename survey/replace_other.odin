#+build !windows
package survey

import "core:os"

// Rename `from` over `to`; rename(2) replaces it whatever else has it open.
@(private)
replace :: proc(from, to: string) -> bool {
	return os.rename(from, to) == nil
}
