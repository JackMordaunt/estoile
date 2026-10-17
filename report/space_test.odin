package report

import "core:os"
import "core:testing"

import "../scan"
import "../survey"

/*
An MFT fill that read no table, as an update from a baseline reads none, still
says what its volume holds and has free: without it a monitor on an elevated
Windows run checked its disk limits on the whole read alone.
*/
@(test)
an_mft_update_asks_the_volume_for_its_space :: proc(t: ^testing.T) {
	dir, dir_err := os.temp_directory(context.temp_allocator)
	testing.expect(t, dir_err == nil, "no temp directory")
	target, _, err := scan.resolve(dir)
	testing.expect_value(t, err, scan.Error.None)
	defer scan.target_destroy(&target)
	f := survey.Fill {
		target = target,
		engine = .Mft,
	}
	space, known := space_of(&f).?
	testing.expect(t, known, "no space for an MFT fill without a table")
	testing.expect(t, space.total > 0 && space.free <= space.total, "a volume's space is whole")
}
