#+build linux
package walk

import "core:mem"
import "core:slice"
import "core:sys/linux"

import "../scan"

/*
Read one directory with the calls the work actually needs.

core:os describes every entry in full: an fd opened and closed around it, a statx on
that fd, and the entry's path read back through /proc/self/fd. Four syscalls, where
one statx against the directory answers everything the tree records. Walking 14,478
entries cost 64,235 calls that way against du's 21,511 for the same tree, and the
procfs readlink was over half of it.

getdents also names each entry's type, so only a regular file is asked about again,
along with the rare entry whose filesystem left the type out. A directory and a
symlink are never charged, so their statx bought nothing but the syscall; on
~/Source, 86,466 of 639,221 statx calls (13.5%) were spent on directories that way
(2026-10-12). statx reports allocated blocks as readily as length, so the on-disk
figure stays exact for the entries still asked, rather than the length rounded up to
a guessed block: a sparse or compressed file is charged what it occupies.
*/
@(private)
read_dir :: proc(d: Dir, w: ^Worker) -> (nodes, bytes: u64, ok: bool) {
	path: Path
	cpath, path_ok := terminate(d.path, &path)
	if !path_ok {
		return 0, 0, false
	}
	// Not NOFOLLOW: the queue holds directories, and symlinks only when the caller
	// asked for those to be followed, so refusing a link here would refuse exactly
	// the ones it was told to walk. DIRECTORY still rejects a link onto a file.
	fd, open_errno := linux.open(cpath, {.DIRECTORY, .CLOEXEC})
	if open_errno != .NONE {
		return 0, 0, false
	}
	defer linux.close(fd)

	// The device and filesystem this directory lies on: handed down by the parent
	// that asked about it, or, for the root and a followed link, asked of the open
	// directory here.
	device, filesystem := d.device, d.filesystem
	if device == 0 {
		st: linux.Statx
		if linux.statx(fd, "", {.EMPTY_PATH}, {}, &st) == .NONE {
			device = statx_device(st)
		}
		filesystem = filesystem_of(fd)
	}

	// Every name first, then every statx in inode order (see Scratch).
	s := &w.scratch
	clear(&s.names)
	clear(&s.listed)
	// Sized so a directory of any ordinary size comes back in one call. core:os
	// starts at 512 bytes and grows only when the kernel refuses, which cost it
	// roughly twice the getdents calls for the same tree.
	buf: [32 * mem.Kilobyte]u8
	for {
		n, errno := linux.getdents(fd, buf[:])
		if errno != .NONE {
			return 0, 0, false
		}
		if n == 0 {
			break
		}
		offset := 0
		for entry in linux.dirent_iterate_buf(buf[:n], &offset) {
			name := linux.dirent_name(entry)
			if name == "." || name == ".." {
				continue
			}
			// Kept terminated, so statx can be handed the name where it lies.
			at := len(s.names)
			if _, err := append(&s.names, name); err != nil {
				w.err = .Out_Of_Memory
				return 0, 0, false
			}
			if _, err := append(&s.names, 0); err != nil {
				w.err = .Out_Of_Memory
				return 0, 0, false
			}
			if _, err := append(&s.listed, Dirent{u64(entry.ino), at, len(name), entry.type});
			   err != nil {
				w.err = .Out_Of_Memory
				return 0, 0, false
			}
		}
	}
	slice.sort_by_key(s.listed[:], proc(l: Dirent) -> u64 {return l.ino})

	// One claim and one copy for the whole directory. Doing both per entry put a
	// shared counter and every worker's arena mutex on the profile: the arenas sit
	// side by side, so neighbours fought over one cache line (2026-10-12). The names
	// are already contiguous in the scratch buffer, separators included.
	count := len(s.listed)
	first: u32
	span: scan.Name_Span
	if count > 0 {
		claimed, claim_err := scan.claim(&w.writer, u32(count))
		if claim_err != nil {
			w.err = .Out_Of_Memory
			return 0, 0, false
		}
		copied, names_ok := scan.intern_span(&w.writer, s.names[:])
		if !names_ok {
			w.err = .Out_Of_Memory
			return 0, 0, false
		}
		first, span = claimed, copied
	}

	for l, i in s.listed {
		name := string(s.names[l.at:][:l.len])
		e := Entry {
			name      = name,
			directory = l.type == .DIR,
			symlink   = l.type == .LNK,
		}
		// Only a regular file can be charged anything, only an entry whose type
		// getdents left out (.UNKNOWN) needs asking what it even is, and only a
		// directory can be another filesystem's mount point. A symlink and the
		// other special types (FIFO, socket, device, whiteout) are none of these,
		// so record charges them nothing whether or not they are stat'd; skipping
		// the call for them changes no result, only the syscall count.
		//
		// NO_AUTOMOUNT, so asking about an automount point does not mount it
		// (AT_NO_AUTOMOUNT in statx(2)).
		child_device, child_filesystem := device, filesystem
		if l.type == .REG || l.type == .UNKNOWN || l.type == .DIR {
			mask := linux.Statx_Mask{.TYPE, .BLOCKS, .NLINK}
			if l.type == .DIR {
				mask = {.TYPE}
			}
			flags := linux.FD_Flags{.SYMLINK_NOFOLLOW, .NO_AUTOMOUNT}
			st: linux.Statx
			if linux.statx(fd, cstring(&s.names[l.at]), flags, mask, &st) == .NONE {
				// Some filesystems leave the type out of a directory entry. Those
				// are the only ones that have to be told apart here.
				if l.type == .UNKNOWN {
					e.directory = linux.S_ISDIR(st.mode)
					e.symlink = linux.S_ISLNK(st.mode)
				}
				if e.directory {
					child_device = statx_device(st)
					if device != 0 && child_device != device {
						e.mount, child_filesystem = stops_at(fd, &s.names[l.at], st, filesystem)
					}
				} else if !e.symlink {
					// Blocks are counted in 512 byte units whatever the
					// filesystem builds them from.
					e.disk = st.blocks * 512
					e.links = st.nlink
					e.id = {
						device = statx_device(st),
						inode  = u64(l.ino),
					}
				}
			}
		}
		index := first + u32(i)
		stored := scan.name_at(span, l.at, l.len)
		descend, charged, recorded := record_at(w, index, d.index, e, stored)
		if !recorded {
			return nodes, bytes, false
		}
		if descend {
			child, join_err := join(d.path, name, w.allocator)
			if join_err != nil {
				w.err = .Out_Of_Memory
				return nodes, bytes, false
			}
			// A followed link may lead anywhere, so its directory learns its own
			// device and filesystem when read.
			next := Dir {
				index = index,
				path  = child,
			}
			if e.directory {
				next.device, next.filesystem = child_device, child_filesystem
			}
			append(&w.found, next)
		}
		nodes += 1
		bytes += charged
	}
	return nodes, bytes, true
}

// The device a statx answer lies on, as one number.
@(private)
statx_device :: proc(st: linux.Statx) -> u64 {
	return u64(st.dev_major) << 32 | u64(st.dev_minor)
}

/*
Whether a directory on another device than the one listing it is somewhere the walk
stops, and the filesystem it lies on. A directory is only asked this when its device
changes, which a scan of this machine's / did 13 times (2026-10-15), so the open and
the statfs stay off the path almost every directory takes.

The rule is the same filesystem, not the same device. Another filesystem mounted
here, /proc, /sys, a tmpfs /run or /tmp, another disk, a network or FUSE mount, is
a mount: recorded, not walked, as the macOS and Windows readers treat one (e.mount
in read_darwin.odin and read_windows.odin). A btrfs subvolume has a device of its
own but draws on the same pool, so it is walked:
/home and /var/log are subvolumes of / on this machine (2026-10-15), and stopping
at them hid their usage. Its statfs fsid will not do to tell, since btrfs folds the
subvolume's id into it (/ gave 32afd77a847e028d and /home ...028c); the pool's own
UUID, from BTRFS_IOC_FS_INFO, is the same for every subvolume.

A read-only btrfs subvolume is stopped at as a mount is: snapper's snapshots under
/.snapshots are each a whole copy of the system, and walking them would charge the
disk for every one. A bind mount of the same filesystem is walked as the directory
it appears to be, so its files count wherever else they are also reached. An
automount point is a mount without being opened, which would mount it.
*/
@(private)
stops_at :: proc(
	dir: linux.Fd,
	name: ^u8,
	st: linux.Statx,
	parent: u128,
) -> (
	mount: bool,
	filesystem: u128,
) {
	if .AUTOMOUNT in st.attributes {
		return true, 0
	}
	// O_PATH needs no permission on the directory itself (open(2)), so a mount
	// this user cannot read, such as a /boot of mode 0700, is still told apart.
	path, path_errno := linux.openat(dir, cstring(name), {.PATH, .DIRECTORY, .NOFOLLOW, .CLOEXEC})
	if path_errno != .NONE {
		// Gone since it was listed; recorded as the directory it appeared to be.
		return false, parent
	}
	fs: linux.Stat_FS
	statfs_errno := linux.fstatfs(path, &fs)
	linux.close(path)
	if statfs_errno != .NONE {
		return false, parent
	}
	if fs.type != .BTRFS_SUPER_MAGIC {
		filesystem = statfs_id(fs)
		return filesystem != parent, filesystem
	}
	// The pool's UUID and the subvolume's flags need a descriptor opened for
	// reading. A btrfs directory this user cannot open is walked as any unreadable
	// directory is, which reads nothing beneath it.
	fd, errno := linux.openat(dir, cstring(name), {.DIRECTORY, .NOFOLLOW, .CLOEXEC})
	if errno != .NONE {
		return false, parent
	}
	defer linux.close(fd)
	filesystem = btrfs_pool(fd, fs)
	if filesystem != parent {
		return true, filesystem
	}
	flags: u64
	got := linux.ioctl(fd, BTRFS_IOC_SUBVOL_GETFLAGS, uintptr(&flags))
	return int(got) >= 0 && flags & BTRFS_SUBVOL_RDONLY != 0, filesystem
}

/*
What tells one filesystem from another: the pool's UUID on btrfs, whose statfs fsid
differs from one subvolume to the next, and the statfs fsid and type elsewhere. 0
when statfs fails.
*/
@(private)
filesystem_of :: proc(fd: linux.Fd) -> u128 {
	fs: linux.Stat_FS
	if linux.fstatfs(fd, &fs) != .NONE {
		return 0
	}
	if fs.type == .BTRFS_SUPER_MAGIC {
		return btrfs_pool(fd, fs)
	}
	return statfs_id(fs)
}

@(private)
statfs_id :: proc(fs: linux.Stat_FS) -> u128 {
	return u128(u32(fs.fsid[0])) | u128(u32(fs.fsid[1])) << 32 | u128(u32(fs.type)) << 64
}

// The UUID of the btrfs pool `fd` lies on, or the statfs identity where the kernel
// will not say. `fd` must be opened for reading: ioctl is not among the calls
// open(2) lists as allowed on an O_PATH one.
@(private)
btrfs_pool :: proc(fd: linux.Fd, fs: linux.Stat_FS) -> u128 {
	info: Btrfs_Fs_Info
	if int(linux.ioctl(fd, BTRFS_IOC_FS_INFO, uintptr(&info))) < 0 {
		return statfs_id(fs)
	}
	return transmute(u128)info.fsid
}

// From linux/btrfs.h: _IOR(0x94, 25, __u64) and _IOR(0x94, 31, struct
// btrfs_ioctl_fs_info_args), neither of which needs privilege.
@(private)
BTRFS_IOC_SUBVOL_GETFLAGS :: 0x80089419
@(private)
BTRFS_IOC_FS_INFO :: 0x8400941f
@(private)
BTRFS_SUBVOL_RDONLY :: 1 << 1

// struct btrfs_ioctl_fs_info_args, 1024 bytes; only the UUID is read.
@(private)
Btrfs_Fs_Info :: struct {
	max_id:          u64,
	num_devices:     u64,
	fsid:            [16]u8,
	nodesize:        u32,
	sectorsize:      u32,
	clone_alignment: u32,
	csum_type:       u16,
	csum_size:       u16,
	flags:           u64,
	generation:      u64,
	metadata_uuid:   [16]u8,
	reserved:        [944]u8,
}
#assert(size_of(Btrfs_Fs_Info) == 1024)

/*
Scratch is what one worker reuses from one directory to the next: the names a
directory holds, each terminated, and where each lies with its inode number.

A directory is listed whole before any entry is asked about, so the entries can be
asked about in inode order. getdents hands entries back in the order the directory
keeps them, which on an indexed ext4 directory is the order of their names'
hashes, unrelated to where their inodes lie. Asked in inode order, a cold read
can take the inode table's blocks in turn rather than jumping between them. btrfs
keys its inode items by inode number too, so the order suits its tree as well. The
cold-cache gain is expected, not yet measured: measuring it needs the caches
dropped, which needs root. With the
table already cached it changes nothing measurable: /usr on btrfs, 442,612 entries,
read in 133 to 189 ms with the sort and without (2026-10-08).
*/
@(private)
Scratch :: struct {
	names:  [dynamic]u8,
	listed: [dynamic]Dirent,
}

// Dirent is one directory entry as getdents described it: its inode, where its
// name lies in Scratch.names, and its type if the filesystem says.
@(private)
Dirent :: struct {
	ino:  u64,
	at:   int,
	len:  int,
	type: linux.Dirent_Type,
}

@(private)
scratch_make :: proc(allocator: mem.Allocator) -> Scratch {
	return {names = make([dynamic]u8, allocator), listed = make([dynamic]Dirent, allocator)}
}

@(private)
scratch_destroy :: proc(s: ^Scratch) {
	delete(s.names)
	delete(s.listed)
}
