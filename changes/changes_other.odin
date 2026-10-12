#+build !darwin
#+build !linux
#+build !windows
package changes

// No change history that leita knows how to read: every update is a whole scan.
now :: proc(place: string) -> (c: Cursor, ok: bool) {
	return {}, false
}

since :: proc(
	place: string,
	c: Cursor,
	allocator := context.allocator,
) -> (
	changed: Change_Set,
	next: Cursor,
	err: Error,
) {
	return rescan("this platform keeps no change history leita reads"), {}, .None
}
