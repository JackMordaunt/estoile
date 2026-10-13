package journal

import "core:strconv"
import "core:strings"

/*
One line of /proc/self/mountinfo (proc_pid_mountinfo(5)): the mount's id, the
device as major:minor, the folder of the filesystem mounted (root), where it is
mounted (point), its type, and the filesystem's own options (super). judge reads
those and not the mount's: a mount made read-only over a writable filesystem, as
ProtectSystem=strict in the service makes them (systemd.exec(5)), is still
recorded. Shown on Linux 7.0.14 by remounting / and /mnt/e read-only in a mount
namespace of the recorder's own (2026-10-13).
*/
Mount :: struct {
	id:     int,
	device: string,
	root:   string,
	point:  string,
	fstype: string,
	super:  string,
}

/*
mounts_parse reads the text of /proc/self/mountinfo, its strings in allocator with
the kernel's octal escapes (\040 for a space) undone. A line it cannot read is left
out.
*/
mounts_parse :: proc(text: string, allocator := context.allocator) -> []Mount {
	out := make([dynamic]Mount, allocator)
	text := text
	for line in strings.split_lines_iterator(&text) {
		fields := strings.fields(line, context.temp_allocator)
		dash := -1
		for f, i in fields {
			if f == "-" {
				dash = i
				break
			}
		}
		if len(fields) < 6 || dash < 6 || dash + 3 >= len(fields) {
			continue
		}
		id, id_ok := strconv.parse_int(fields[0], 10)
		if !id_ok {
			continue
		}
		append(
			&out,
			Mount {
				id = id,
				device = strings.clone(fields[2], allocator),
				root = unescape(fields[3], allocator),
				point = unescape(fields[4], allocator),
				fstype = strings.clone(fields[dash + 1], allocator),
				super = strings.clone(fields[dash + 3], allocator),
			},
		)
	}
	return out[:]
}

mounts_destroy :: proc(mounts: []Mount, allocator := context.allocator) {
	for m in mounts {
		delete(m.device, allocator)
		delete(m.root, allocator)
		delete(m.point, allocator)
		delete(m.fstype, allocator)
		delete(m.super, allocator)
	}
	delete(mounts, allocator)
}

// unescape undoes mountinfo's three-digit octal escapes, in allocator.
@(private)
unescape :: proc(s: string, allocator := context.allocator) -> string {
	b := strings.builder_make(0, len(s), allocator)
	for i := 0; i < len(s); i += 1 {
		if s[i] == '\\' && i + 3 < len(s) && is_octal(s[i + 1:i + 4]) {
			strings.write_byte(
				&b,
				(s[i + 1] - '0') << 6 | (s[i + 2] - '0') << 3 | (s[i + 3] - '0'),
			)
			i += 3
			continue
		}
		strings.write_byte(&b, s[i])
	}
	return strings.to_string(b)
}

@(private)
is_octal :: proc(s: string) -> bool {
	for c in transmute([]byte)s {
		if c < '0' || c > '7' {
			return false
		}
	}
	return true
}

// Filesystems with no disk behind them, or whose contents are made up or never
// change: never recorded, and not listed as skipped.
@(private, rodata)
PSEUDO := [?]string {
	"autofs",
	"binfmt_misc",
	"bpf",
	"cgroup",
	"cgroup2",
	"configfs",
	"debugfs",
	"devpts",
	"devtmpfs",
	"efivarfs",
	"erofs",
	"fusectl",
	"hugetlbfs",
	"iso9660",
	"mqueue",
	"nsfs",
	"overlay",
	"proc",
	"pstore",
	"ramfs",
	"rpc_pipefs",
	"securityfs",
	"selinuxfs",
	"squashfs",
	"sysfs",
	"tmpfs",
	"tracefs",
}

// Filesystems another machine can change, which no mark here would see.
@(private, rodata)
NETWORK := [?]string {
	"9p",
	"ceph",
	"cifs",
	"fuse.sshfs",
	"glusterfs",
	"nfs",
	"nfs4",
	"smb3",
	"smbfs",
	"virtiofs",
}

/*
judge is whether the recorder should try to mark m's filesystem: every local one
that can change. When it should not, why says so for the status, or is "" for a
filesystem not worth listing (proc, tmpfs and the like).
*/
judge :: proc(m: Mount) -> (try: bool, why: string) {
	for t in PSEUDO {
		if m.fstype == t {
			return false, ""
		}
	}
	for t in NETWORK {
		if m.fstype == t {
			return false, "a network filesystem, which another machine can change"
		}
	}
	options := m.super
	for o in strings.split_iterator(&options, ",") {
		if o == "ro" {
			return false, "the filesystem is read-only"
		}
	}
	return true, ""
}
