#+build windows
package leita_files

import "core:os"
import "core:strings"
import win32 "core:sys/windows"

SEPARATOR  :: `\`
SEPARATORS :: `\/`

// rename_noreplace renames from to to, failing with Exists rather than replacing
// whatever is at to: MoveFileExW without MOVEFILE_REPLACE_EXISTING never replaces,
// and without MOVEFILE_COPY_ALLOWED never copies between volumes.
rename_noreplace :: proc(from, to: string) -> Error {
	f := win32.utf8_to_wstring(from, context.temp_allocator)
	t := win32.utf8_to_wstring(to, context.temp_allocator)
	if !win32.MoveFileExW(f, t, 0) {
		return win32_error(win32.GetLastError())
	}
	return .None
}

/*
trash moves path to the Recycle Bin through the shell, as Explorer does, and
reports success only once path is gone. FOF_NO_UI is not passed, since it includes
FOF_NOCONFIRMATION, which shellapi.h says assumes yes for every prompt that can be
bypassed. FOF_WANTNUKEWARNING is passed instead: shellapi.h says it warns when a
delete would destroy the object rather than recycle it. A refusal, a failure or a
path still in place is Not_Recycled.
*/
trash :: proc(path: string) -> Error {
	if !present(path) {
		return .Missing
	}
	wide := win32.utf8_to_utf16(path, context.temp_allocator)
	from := make([]u16, len(wide) + 2, context.temp_allocator) // the list ends in two NULs
	copy(from, wide)
	op := win32.SHFILEOPSTRUCTW {
		wFunc  = win32.FO_DELETE,
		pFrom  = cstring16(raw_data(from)),
		fFlags = win32.FOF_ALLOWUNDO |
		win32.FOF_SILENT |
		win32.FOF_NOERRORUI |
		win32.FOF_NOCONFIRMMKDIR |
		win32.FOF_WANTNUKEWARNING,
	}
	code := win32.SHFileOperationW(&op)
	return trash_outcome(i32(code), bool(op.fAnyOperationsAborted), !present(path))
}

// present says whether anything, a link itself included, is at path.
@(private = "file")
present :: proc(path: string) -> bool {
	_, err := os.stat_do_not_follow_links(path, context.temp_allocator)
	return err == nil
}

/*
is_link says whether path is a symbolic link or a junction, as the listing
delete_tree walks says of what it holds. core:os's lstat cannot be asked: it
reads a link through a handle opened on the link and then drops its reparse tag
(core/os/stat_windows.odin), so it calls a link to a directory a directory, and
delete_tree given one emptied what it points at. The entry's own find data
carries the tag.
*/
@(private)
is_link :: proc(path: string) -> bool {
	data: win32.WIN32_FIND_DATAW
	h := win32.FindFirstFileW(win32.utf8_to_wstring(path, context.temp_allocator), &data)
	if h == win32.INVALID_HANDLE_VALUE {
		return false
	}
	win32.FindClose(h)
	if data.dwFileAttributes & win32.FILE_ATTRIBUTE_REPARSE_POINT == 0 {
		return false
	}
	tag := data.dwReserved0
	return tag == win32.IO_REPARSE_TAG_SYMLINK || tag == win32.IO_REPARSE_TAG_MOUNT_POINT
}

// reveal opens Explorer with path selected.
@(private)
reveal :: proc(path: string) {
	run({"explorer.exe", strings.concatenate({"/select,", path}, context.temp_allocator)})
}

@(private = "file")
win32_error :: proc(code: win32.DWORD) -> Error {
	switch code {
	case win32.ERROR_ALREADY_EXISTS, win32.ERROR_FILE_EXISTS:
		return .Exists
	case win32.ERROR_FILE_NOT_FOUND, win32.ERROR_PATH_NOT_FOUND:
		return .Missing
	case win32.ERROR_ACCESS_DENIED:
		return .Denied
	case 17:
		// ERROR_NOT_SAME_DEVICE, which core:sys/windows does not name
		return .Cross_Device
	}
	return .Other
}

// documents is the user's Documents folder as the shell knows it, wherever it
// was moved to; "" when the shell cannot say.
@(private)
documents :: proc(allocator := context.allocator) -> string {
	wide: win32.LPWSTR
	id := win32.FOLDERID_Documents
	if win32.SHGetKnownFolderPath(&id, 0, nil, &wide) != 0 {
		return ""
	}
	defer win32.CoTaskMemFree(wide)
	path, err := win32.wstring_to_utf8(win32.wstring(wide), -1, allocator)
	return path if err == nil else ""
}
