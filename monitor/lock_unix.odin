#+build linux, darwin, freebsd, openbsd, netbsd
package leita_monitor

import "core:c"
import "core:strings"
import "core:time"
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
	// A process being started by a thread beside this one holds a copy of
	// every open file from its fork until its exec closes the close-on-exec
	// ones, the lock's among them; a lock let go an instant ago reads as
	// held for that window. A few short retries outlast it; a run that is
	// truly still going holds the lock for far longer.
	errno: posix.Errno
	for _ in 0 ..< HELD_RETRIES {
		if flock(fd, LOCK_EX | LOCK_NB) == 0 {
			return {fd}, .Taken
		}
		errno = posix.errno()
		if errno != .EWOULDBLOCK {
			break
		}
		time.sleep(HELD_RETRY_WAIT)
	}
	posix.close(fd)
	return {fd = -1}, .Held if errno == .EWOULDBLOCK else .Failed
}

// HELD_RETRIES and HELD_RETRY_WAIT bound how long lock waits out a fork window
// before reporting the lock held: 100 ms in all.
@(private = "file")
HELD_RETRIES :: 10
@(private = "file")
HELD_RETRY_WAIT :: 10 * time.Millisecond

// unlock lets the lock go.
unlock :: proc(l: ^Lock) {
	if l.fd >= 0 {
		posix.close(l.fd)
	}
	l.fd = -1
}
