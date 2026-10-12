#+build windows
package leita_files

import win32 "core:sys/windows"

// symlink_directory makes path a link to the directory target, which core:os's
// symlink refuses on Windows as unsupported (core/os/file_windows.odin). It needs
// Developer Mode or an elevated process, as a CI runner is.
symlink_directory :: proc(target, path: string) -> bool {
	flags :=
		win32.SYMBOLIC_LINK_FLAG_DIRECTORY | win32.SYMBOLIC_LINK_FLAG_ALLOW_UNPRIVILEGED_CREATE
	link := win32.utf8_to_wstring(path, context.temp_allocator)
	to := win32.utf8_to_wstring(target, context.temp_allocator)
	return bool(win32.CreateSymbolicLinkW(link, to, flags))
}
