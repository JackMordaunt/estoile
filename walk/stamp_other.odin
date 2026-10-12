#+build !linux
package walk

// Probing directories is Linux's answer to having no change journal leita reads;
// Windows has the USN journal and macOS FSEvents, so a probe here says every
// directory changed, and the update reads them all, as a walk would.
@(private)
changed_since :: proc(path: string, since: i64) -> bool {
	return true
}

@(private)
disk_of :: proc(path: string) -> (disk: u64, ok: bool) {
	return 0, false
}
