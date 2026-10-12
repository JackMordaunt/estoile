#+build linux
package leita_files

import "core:fmt"
import "core:os"
import "core:testing"

// open_default hands the path to xdg-open whole, spaces and all, and says
// whether it went well: a stand-in xdg-open, first on PATH, writes down what
// it was given and exits as told.
@(test)
open_hands_the_path_to_xdg_open :: proc(t: ^testing.T) {
	base, _ := os.temp_directory(context.temp_allocator)
	bin := fmt.tprintf("%s/leita_open_bin", base)
	os.remove_all(bin)
	testing.expect(t, os.make_directory(bin) == nil)
	defer os.remove_all(bin)
	given := fmt.tprintf("%s/given", bin)
	script := fmt.tprintf(
		"#!/bin/sh\nprintf '%%s' \"$1\" > '%s'\nexit \"$(cat '%s/exit')\"\n",
		given,
		bin,
	)
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/xdg-open", bin), script) == nil)
	testing.expect(
		t,
		os.chmod(fmt.tprintf("%s/xdg-open", bin), {.Read_User, .Write_User, .Execute_User}) == nil,
	)

	path := os.get_env("PATH", context.temp_allocator)
	testing.expect(t, os.set_env("PATH", fmt.tprintf("%s:%s", bin, path)) == nil)
	defer os.set_env("PATH", path)

	opened := "/home/someone/Pictures/a photo.jpg"
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/exit", bin), "0") == nil)
	testing.expect(t, open_default(opened), "xdg-open went well")
	got, _ := os.read_entire_file(given, context.temp_allocator)
	testing.expect_value(t, string(got), opened)

	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/exit", bin), "4") == nil)
	testing.expect(t, !open_default(opened), "xdg-open failed")
}
