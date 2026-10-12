#+build windows
package leita_files

import win32 "core:sys/windows"

// open_default opens path with the shell's "open" verb, as a double click in
// Explorer does. ShellExecuteW's documentation (shellapi.h, Win32) gives a
// value above 32 for success and an error code at or below it.
open_default :: proc(path: string) -> bool {
	verb := win32.utf8_to_wstring("open", context.temp_allocator)
	file := win32.utf8_to_wstring(path, context.temp_allocator)
	done := win32.ShellExecuteW(nil, verb, file, nil, nil, win32.SW_SHOWNORMAL)
	return uintptr(done) > 32
}
