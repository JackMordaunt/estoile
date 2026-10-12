#+build linux, darwin, freebsd, openbsd, netbsd
package leita_monitor

import "core:c"
import "core:strings"
import "core:sys/posix"

when ODIN_OS == .Darwin {
	foreign import libc "system:System"
} else {
	foreign import libc "system:c"
}

// flock(2): its operations are the same on Linux, macOS and the BSDs.
@(private)
foreign libc {
	flock :: proc "c" (fd: posix.FD, operation: c.int) -> c.int ---
}

@(private)
LOCK_EX :: 2
@(private)
LOCK_NB :: 4

// Lock is the lock taken, held until unlock or the process ends.
Lock :: struct {
	fd: posix.FD,
}

// lock takes the lock on the file at path, making it if it is missing, without
// waiting: flock, which belongs to the open file, so another open of it, in
// this process or another, is refused until this one closes, which the system
// does when the process ends, as flock(2) has it.
lock :: proc(path: string) -> (l: Lock, result: Lock_Result) {
	fd := posix.open(
	strings.clone_to_cstring(path, context.temp_allocator),
	// Close on exec: a process started meanwhile, here or by a thread beside
	// this one, would otherwise hold the open file, and the lock, past unlock.
	{.RDWR, .CREAT, .CLOEXEC},
	{.IRUSR, .IWUSR},
	)
	if fd < 0 {
		return {fd = -1}, .Failed
	}
	if flock(fd, LOCK_EX | LOCK_NB) == 0 {
		return {fd}, .Taken
	}
	errno := posix.errno()
	posix.close(fd)
	return {fd = -1}, .Held if errno == .EWOULDBLOCK else .Failed
}

// unlock lets the lock go.
unlock :: proc(l: ^Lock) {
	if l.fd >= 0 {
		posix.close(l.fd)
	}
	l.fd = -1
}
