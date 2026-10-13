#+build !linux
package journal

import "core:fmt"
import "core:io"

import "../term"

// OWN is what leita journal says where the system records changes itself.
OWN :: "this system records which folders change itself; leita reads that, and needs no recorder"

// dispatch says, for every command, that there is nothing to do here.
@(private)
dispatch :: proc(style: term.Style, args: []string, w: io.Writer) -> int {
	_ = style
	_ = args
	fmt.wprintln(w, OWN)
	return EXIT_OK
}
