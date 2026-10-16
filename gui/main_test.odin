package main

import "core:testing"

// A flag, help and version among them, makes Leita leita; a path, or nothing,
// opens the window. Two paths go to leita, which says what is wrong with them.
@(test)
a_flag_makes_leita_the_command_line :: proc(t: ^testing.T) {
	testing.expect_value(t, launch({}), Launch.Window)
	testing.expect_value(t, launch({"/tmp"}), Launch.Window)
	testing.expect_value(t, launch({"-h"}), Launch.Terminal)
	testing.expect_value(t, launch({"--version"}), Launch.Terminal)
	testing.expect_value(t, launch({"/tmp", "--report", "-", "--format", "json"}), Launch.Terminal)
	testing.expect_value(t, launch({"--no-history", "/tmp"}), Launch.Terminal)
	testing.expect_value(t, launch({"monitor", "-h"}), Launch.Terminal)
	testing.expect_value(t, launch({"journal"}), Launch.Terminal)
	testing.expect_value(t, launch({"a", "b"}), Launch.Terminal)
}
