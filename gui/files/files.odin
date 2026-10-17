/*
Package files is what leita's window does to what it found, through the platform:
show an entry in the system's file manager, move it to the Trash, rename it. Each
acts on a path and reports an Error; deciding whether to ask is the caller's.

Targets are Linux, macOS and Windows. On Linux the Trash is the freedesktop.org one
in the user's home; the file manager is asked over D-Bus through the freedesktop.org
FileManager1 interface, with xdg-open on the folder as the fallback. On macOS both go
through the Finder: NSFileManager's Trash, and open -R to show an entry.
*/
package leita_files

import "base:runtime"

import "core:fmt"
import "core:io"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:thread"
import "core:time"
import "core:unicode"

import "jm:timefmt"

Error :: enum u8 {
	None,
	Exists, // something already has that name
	Missing, // the entry is no longer there
	Denied,
	Cross_Device, // the Trash is on another filesystem
	Bad_Name,
	Not_Directory, // asked to delete a tree at something that is not a directory
	Partly, // some of a tree could not be deleted, so the tree is still there
	Unsupported,
	Other,
}

describe :: proc(e: Error) -> string {
	switch e {
	case .None:
		return ""
	case .Exists:
		return "something already has that name"
	case .Missing:
		return "it is no longer there"
	case .Denied:
		return "permission was denied"
	case .Cross_Device:
		return "it is on another filesystem than the Trash"
	case .Bad_Name:
		return "that is not a name a file can have"
	case .Not_Directory:
		return "it is not a directory"
	case .Partly:
		return "some of it could not be deleted"
	case .Unsupported:
		return "this system cannot do that"
	case .Other:
	}
	return "the system refused"
}

// Name_Fault is why a name cannot be a file's new name, which the window words.
Name_Fault :: enum u8 {
	None,
	Empty,
	Dot, // . or .., which name a folder itself
	Slash,
	Nul,
	Reserved, // one of \ : * ? " < > | on Windows
}

// name_fault is why name cannot be a file's new name, or None if it can.
name_fault :: proc(name: string) -> Name_Fault {
	switch {
	case strings.trim_space(name) == "":
		return .Empty
	case name == "." || name == "..":
		return .Dot
	case strings.contains_rune(name, '/'):
		return .Slash
	case strings.contains_rune(name, 0):
		return .Nul
	}
	when ODIN_OS == .Windows {
		if strings.contains_any(name, `\:*?"<>|`) {
			return .Reserved
		}
	}
	return .None
}

/*
delete_tree deletes the directory at path and everything in it, for good. It says
how many entries it could not delete, not counting a folder kept only because it
holds one, and how many bytes what it did delete gave back. Anything left is
Partly: the tree is still there, and only freed is gone. It is for what Reclaim
proved can be made again, and it is careful in the ways deletion has to be:

  - path must be a directory itself, not a link to one: a link is refused, so
    deleting never reaches through it to what it points at;
  - inside, a link is deleted as a link, never followed;
  - a directory is made writable by its owner before it is emptied, since some
    caches (Go's module cache) are made read-only, and given its mode back if it
    could not be deleted after all;
  - an entry that cannot be deleted is counted and passed over, and the rest
    still go.
*/
delete_tree :: proc(path: string) -> (failed: int, freed: u64, err: Error) {
	info, serr := os.stat_do_not_follow_links(path, context.temp_allocator)
	switch {
	case serr != nil:
		return 0, 0, .Missing
	case info.type != .Directory, is_link(path):
		return 0, 0, .Not_Directory
	}
	failed, freed = remove_tree(path)
	return failed, freed, .Partly if failed > 0 else .None
}

when ODIN_OS != .Windows {
	// is_link is false wherever lstat has already said whether path is a link.
	// Windows asks for itself (platform_windows.odin).
	@(private)
	is_link :: proc(path: string) -> bool {
		return false
	}
}

/*
remove_tree deletes the directory at path and everything in it: how many entries it could not delete, as delete_tree counts them, and the bytes
the ones it did gave back. A directory that stays is given back the mode it had, so
a failed delete does not leave a read-only cache writable.
*/
@(private)
remove_tree :: proc(path: string) -> (failed: int, freed: u64) {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	info, serr := os.stat_do_not_follow_links(path, context.temp_allocator)
	if serr != nil {
		return 1, 0
	}
	writable := info.mode + {.Read_User, .Write_User, .Execute_User}
	opened := writable != info.mode && os.change_mode(path, writable) == nil
	defer if opened && os.exists(path) {
		_ = os.change_mode(path, info.mode)
	}
	entries, err := os.read_all_directory_by_path(path, context.temp_allocator)
	if err != nil {
		return 1, 0
	}
	for e in entries {
		// The listing does not follow links, so a link is a link here.
		if e.type == .Directory {
			f, b := remove_tree(e.fullpath)
			failed, freed = failed + f, freed + b
			continue
		}
		bytes := held_alone(e.fullpath)
		if os.remove(e.fullpath) == nil {
			freed += bytes
		} else {
			failed += 1
		}
	}
	if failed > 0 {
		// Kept because it holds what is counted already.
		return
	}
	if os.remove(path) != nil {
		return 1, freed
	}
	return 0, freed
}

// rename gives the entry at path the new name in the same folder, refusing with
// Exists rather than replacing whatever already has it.
rename :: proc(path, name: string, allocator := context.allocator) -> (to: string, err: Error) {
	if name_fault(name) != .None {
		return "", .Bad_Name
	}
	dir := path[:max(strings.last_index_any(path, SEPARATORS), 0)]
	to = strings.concatenate({dir, SEPARATOR, name}, allocator)
	if err = rename_noreplace(path, to); err != .None {
		delete(to, allocator)
		return "", err
	}
	return to, .None
}

// reports_folder is where the window saves what it exports: the user's
// Documents folder, or their home where that is missing; "" for neither.
reports_folder :: proc(allocator := context.allocator) -> string {
	if docs := documents(context.temp_allocator); docs != "" && os.is_dir(docs) {
		return strings.clone(docs, allocator)
	}
	home, err := os.user_home_dir(allocator)
	return home if err == nil else ""
}

/*
create_new makes a file in dir that was not there, named stem and ext, else
stem-2 and ext, stem-3 and on, and opens it to write. It never replaces a file,
even one made after it looked: the create claims the name or fails.
*/
create_new :: proc(
	dir, stem, ext: string,
	allocator := context.allocator,
) -> (
	path: string,
	file: ^os.File,
	err: Error,
) {
	for n in 1 ..= 999 {
		buf: [512]u8
		name :=
			fmt.bprintf(buf[:], "%s%s", stem, ext) if n == 1 else fmt.bprintf(buf[:], "%s-%d%s", stem, n, ext)
		path = strings.concatenate({dir, SEPARATOR, name}, allocator)
		f, open_err := os.open(path, {.Write, .Create, .Excl}, os.Permissions_Default_File)
		if open_err == nil {
			return path, f, .None
		}
		delete(path, allocator)
		if open_err == os.General_Error.Exist {
			continue
		}
		return "", nil, open_error(open_err)
	}
	return "", nil, .Exists
}

/*
create_at opens the file at path to write, making it or emptying what was there:
for a path the person chose in a save dialog, which asks them before it names a
file that exists (ui.pick_save says which backend asks how).
*/
create_at :: proc(path: string) -> (file: ^os.File, err: Error) {
	f, open_err := os.open(path, {.Write, .Create, .Trunc}, os.Permissions_Default_File)
	if open_err != nil {
		return nil, open_error(open_err)
	}
	return f, .None
}

// open_error is the Error an open of a file to write failed with.
@(private)
open_error :: proc(err: os.Error) -> Error {
	switch {
	case err == os.General_Error.Exist:
		return .Exists
	case err == os.General_Error.Not_Exist:
		return .Missing
	case err == io.Error.Permission_Denied:
		return .Denied
	}
	return .Other
}

/*
report_stem is what a report of target made at now is called, less its
extension: leita-report-<target's last name>-<local date and minute>. The name is
kept to letters, digits, dots, dashes and underscores, anything else a dash: none
of those is reserved in a name on Linux, macOS or Windows, and the prefix keeps
it from being one of the names Windows reserves (CON, NUL). A target with no last
name, a volume's top, is "root". The window suggests it in the save dialog, and
the host names a report it saves without one so.
*/
report_stem :: proc(target: string, now: time.Time) -> string {
	base := filepath.base(strings.trim_right(target, `/\`))
	sb := strings.builder_make(context.temp_allocator)
	dash := false
	for r in base {
		if unicode.is_letter(r) || unicode.is_digit(r) || r == '.' || r == '_' || r == '-' {
			strings.write_rune(&sb, r)
			dash = false
		} else if !dash {
			strings.write_byte(&sb, '-')
			dash = true
		}
		if strings.builder_len(sb) >= 48 {
			break
		}
	}
	name := strings.trim(strings.to_string(sb), "-.")
	if name == "" {
		name = "root"
	}
	return strings.concatenate(
		{"leita-report-", name, "-", timefmt.local(now, "%Y-%m-%d-%H%M", context.temp_allocator)},
		context.temp_allocator,
	)
}

/*
locate shows path in the system's file manager, selected. It hands the asking to a
thread of its own and returns at once: a file manager that is slow to start must
not hold up the caller, and none of them says whether it found the entry.
*/
locate :: proc(path: string) {
	run_in_background(path, reveal)
}

// Job is work on a path that runs on a thread of its own, holding its own copy of
// the path.
@(private)
Job :: struct {
	path: string,
	work: proc(path: string),
}

/*
run_in_background runs work on a copy of path on a new thread. The thread is given the
caller's context, so the copy is freed by the allocator that made it: a thread
started without one frees through the system heap, which aborts on memory a
debug or tracking allocator handed out. A detached thread cleans up after itself;
otherwise the caller joins and destroys the thread returned.
*/
@(private)
run_in_background :: proc(
	path: string,
	work: proc(path: string),
	detach := true,
) -> ^thread.Thread {
	job := new(Job)
	job^ = {strings.clone(path), work}
	t := thread.create_and_start_with_poly_data(
		job,
		job_main,
		init_context = context,
		self_cleanup = detach,
	)
	if t == nil {
		delete(job.path)
		free(job)
	}
	return nil if detach else t
}

@(private)
job_main :: proc(job: ^Job) {
	// Given a context, the thread owns its temp allocator and frees it here.
	defer if context.temp_allocator.procedure == runtime.default_temp_allocator_proc {
		runtime.default_temp_allocator_destroy(auto_cast context.temp_allocator.data)
	}
	defer free(job)
	defer delete(job.path)
	job.work(job.path)
}

// run starts command and waits for it, reporting whether it ran and exited 0.
@(private)
run :: proc(command: []string) -> bool {
	process, err := os.process_start({command = command})
	if err != nil {
		return false
	}
	state, _ := os.process_wait(process)
	return state.exit_code == 0
}
