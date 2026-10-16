package reclaim

import "core:slice"
import "core:strings"
import "core:testing"

import "../home"

// ANN is the made-up user the trees below belong to.
@(private)
ANN :: home.User{"/home/ann", "1000"}

// A tree made in memory: each entry's parent is its index's slot in the tree.
@(private)
Fake :: struct {
	name:      [dynamic]string,
	directory: [dynamic]bool,
	bytes:     [dynamic]u64,
	parent:    [dynamic]u32,
}

@(private)
fake_add :: proc(t: ^Fake, parent: u32, name: string, directory: bool, bytes: u64 = 0) -> u32 {
	append(&t.name, name)
	append(&t.directory, directory)
	append(&t.bytes, bytes)
	append(&t.parent, parent)
	return u32(len(t.name) - 1)
}

// fake_path makes each directory along path under from, returning the last.
@(private)
fake_path :: proc(t: ^Fake, from: u32, path: string) -> u32 {
	at := from
	for name in strings.split(path, "/", context.temp_allocator) {
		found := false
		for p, ii in t.parent {
			if p == at && u32(ii) != at && t.name[ii] == name {
				at, found = u32(ii), true
				break
			}
		}
		if !found {
			at = fake_add(t, at, name, true)
		}
	}
	return at
}

// fake_has is whether every directory along path exists under from.
@(private)
fake_has :: proc(t: ^Fake, from: u32, path: string) -> bool {
	at := from
	for name in strings.split(path, "/", context.temp_allocator) {
		found := false
		for p, ii in t.parent {
			if p == at && u32(ii) != at && t.name[ii] == name {
				at, found = u32(ii), true
				break
			}
		}
		if !found {
			return false
		}
	}
	return true
}

@(private)
fake_source :: proc(t: ^Fake) -> Source {
	return {
		data = t,
		name = proc(data: rawptr, node: u32) -> string {return (^Fake)(data).name[node]},
		directory = proc(data: rawptr, node: u32) -> bool {return (^Fake)(data).directory[node]},
		bytes = proc(data: rawptr, node: u32) -> u64 {return (^Fake)(data).bytes[node]},
		children = proc(data: rawptr, node: u32, into: ^[dynamic]u32) {
			t := (^Fake)(data)
			for p, ii in t.parent {
				if p == node && u32(ii) != node {
					append(into, u32(ii))
				}
			}
		},
	}
}

@(private)
fake_destroy :: proc(t: ^Fake) {
	delete(t.name)
	delete(t.directory)
	delete(t.bytes)
	delete(t.parent)
}

@(private)
found_paths :: proc(found: []Candidate) -> []string {
	out := make([]string, len(found), context.temp_allocator)
	for c, ii in found {
		out[ii] = c.path
	}
	slice.sort(out)
	return out
}

@(private)
candidates_destroy :: proc(found: []Candidate) {
	for c in found {
		delete(c.path)
	}
	delete(found)
}

// The home of a made-up user, scanned from the root of the filesystem.
@(private)
home_tree :: proc(t: ^Fake) -> (root: u32) {
	root = fake_add(t, 0, "/", true)
	home := fake_path(t, root, "home/ann")

	// Proved by a marker beside them.
	web := fake_path(t, home, "src/web")
	fake_add(t, web, "package.json", false, 1)
	fake_add(t, fake_path(t, web, "node_modules"), "left-pad.js", false, 100)
	rust := fake_path(t, home, "src/tool")
	fake_add(t, rust, "Cargo.toml", false, 1)
	fake_path(t, rust, "target/debug")
	fake_path(t, home, "src/py/pkg/__pycache__")

	// Named like build output, without the proof.
	fake_path(t, home, "src/notes/build")
	fake_path(t, home, "photos/target")
	dist := fake_path(t, home, "src/site")
	fake_add(t, dist, "package.json", false, 1)
	fake_path(t, dist, "dist")
	fake_path(t, home, "src/lone/.venv")

	// A match is not looked inside: the nested node_modules is part of it.
	fake_path(t, web, "node_modules/react/node_modules")

	// Never inside .git or a system directory.
	fake_path(t, home, "src/web/.git/node_modules")
	fake_path(t, home, "src/web/.git/hooks/__pycache__")
	fake_path(t, root, "usr/lib/python3/__pycache__")

	// Where they are under home.
	fake_path(t, home, ".cache/chromium")
	fake_path(t, home, ".cache/pip")
	fake_add(t, fake_path(t, home, ".cache"), "a-file-in-cache", false, 5)
	fake_path(t, home, "go/pkg/mod/github.com")
	fake_path(t, home, TRASH + "/files")

	// The macOS places, matched by path on every platform.
	fake_path(t, home, "Library/Caches/com.apple.Safari")
	fake_path(t, home, "Library/Caches/Homebrew/downloads")
	fake_add(t, fake_path(t, home, "Library/Caches"), "a-file-in-caches", false, 5)
	fake_path(t, home, "Library/Developer/Xcode/DerivedData/App-abc/Build")
	fake_path(t, home, "Library/Developer/Xcode/iOS DeviceSupport/17.0")
	fake_path(t, home, "Library/Developer/Xcode/watchOS DeviceSupport/10.0")
	fake_path(t, home, "Library/Developer/CoreSimulator/Caches/dyld")
	swift := fake_path(t, home, "src/swift")
	fake_add(t, swift, "Package.swift", false, 1)
	fake_path(t, swift, ".build/debug")
	fake_path(t, home, "src/odin/.odin-cache/abc")

	// What Reclaim must leave alone under a macOS home, whatever its size: iOS
	// backups, Xcode archives, the simulators' disks, applications' sandboxed data
	// and Docker's or OrbStack's virtual disks.
	fake_path(t, home, "Library/Application Support/MobileSync/Backup/dev1")
	fake_path(t, home, "Library/Developer/Xcode/Archives/2025")
	fake_path(t, home, "Library/Developer/CoreSimulator/Devices/ABC/data")
	fake_path(t, home, "Library/Containers/com.apple.mail/Data/Library/Caches")
	docker := fake_path(t, home, "Library/Containers/com.docker.docker/Data/vms/0/data")
	fake_add(t, docker, "Docker.raw", false, 1 << 30)
	fake_path(t, home, "Library/Group Containers/group.com.apple.notes/Caches")
	fake_path(t, home, ".orbstack/data")
	// A .build without its manifest is someone's work.
	fake_path(t, home, "src/notes/.build")
	return
}

@(test)
only_what_proves_itself_regenerable_is_found :: proc(t: ^testing.T) {
	tree: Fake
	defer fake_destroy(&tree)
	root := home_tree(&tree)
	found := find(fake_source(&tree), root, "/", ANN)
	defer candidates_destroy(found)

	want := []string {
		"/home/ann/.cache/chromium",
		"/home/ann/.cache/pip",
		"/home/ann/" + TRASH,
		"/home/ann/Library/Caches/Homebrew",
		"/home/ann/Library/Caches/com.apple.Safari",
		"/home/ann/Library/Developer/CoreSimulator/Caches",
		"/home/ann/Library/Developer/Xcode/DerivedData",
		"/home/ann/Library/Developer/Xcode/iOS DeviceSupport",
		"/home/ann/Library/Developer/Xcode/watchOS DeviceSupport",
		"/home/ann/go/pkg/mod",
		"/home/ann/src/odin/.odin-cache",
		"/home/ann/src/py/pkg/__pycache__",
		"/home/ann/src/swift/.build",
		"/home/ann/src/tool/target",
		"/home/ann/src/web/node_modules",
	}
	slice.sort(want)
	got := found_paths(found)
	testing.expectf(t, slice.equal(got, want), "found\n%v\nwant\n%v", got, want)
}

@(test)
each_candidate_says_what_it_is :: proc(t: ^testing.T) {
	tree: Fake
	defer fake_destroy(&tree)
	root := home_tree(&tree)
	found := find(fake_source(&tree), root, "/", ANN)
	defer candidates_destroy(found)
	testing.expect_value(t, len(found), 15)
	for c in found {
		want: Category
		switch {
		case strings.has_suffix(c.path, "node_modules"):
			want = .Dependencies
		case strings.has_suffix(c.path, "target"),
		     strings.has_suffix(c.path, ".build"),
		     strings.has_suffix(c.path, ".odin-cache"),
		     strings.has_suffix(c.path, "DerivedData"):
			want = .Build_Output
		case strings.has_suffix(c.path, "__pycache__"):
			want = .Python
		case strings.contains(c.path, ".cache/"), strings.contains(c.path, "Caches"):
			want = .App_Cache
		case strings.has_suffix(c.path, "DeviceSupport"):
			want = .Device_Support
		case strings.has_suffix(c.path, "go/pkg/mod"):
			want = .Package_Cache
		case strings.has_suffix(c.path, "Trash"):
			want = .Trash
		}
		testing.expectf(t, c.category == want, "%s is %v, not %v", c.path, c.category, want)
	}
}

// Scanning a project directly, below home, still finds its output, and the home
// places are only where home is.
@(test)
a_scan_below_home_finds_by_rule_alone :: proc(t: ^testing.T) {
	tree: Fake
	defer fake_destroy(&tree)
	web := fake_add(&tree, 0, "web", true)
	fake_add(&tree, web, "package.json", false, 1)
	fake_path(&tree, web, "node_modules")
	fake_path(&tree, web, ".cache/x")
	found := find(fake_source(&tree), web, "/home/ann/src/web", ANN)
	defer candidates_destroy(found)
	testing.expect(t, slice.equal(found_paths(found), []string{"/home/ann/src/web/node_modules"}))
}

@(test)
nothing_under_a_system_directory_even_from_its_top :: proc(t: ^testing.T) {
	tree: Fake
	defer fake_destroy(&tree)
	lib := fake_add(&tree, 0, "lib", true)
	fake_path(&tree, lib, "python3/__pycache__")
	found := find(fake_source(&tree), lib, "/usr/lib", ANN)
	defer candidates_destroy(found)
	testing.expect_value(t, len(found), 0)
	testing.expect(t, under_system("/usr"))
	testing.expect(t, under_system("/usr/lib"))
	testing.expect(t, !under_system("/usrdata"))
	testing.expect(t, !under_system("/home/ann"))
}

// What macOS keeps under home that is not made again is never offered, whatever
// it holds: a sandboxed application's own Caches is not the user's.
@(test)
nothing_macos_keeps_for_good_is_offered :: proc(t: ^testing.T) {
	tree: Fake
	defer fake_destroy(&tree)
	root := home_tree(&tree)
	found := find(fake_source(&tree), root, "/", ANN)
	defer candidates_destroy(found)
	testing.expect_value(t, len(found), 15)
	kept := []string {
		"Library/Application Support",
		"Library/Developer/Xcode/Archives",
		"Library/Developer/CoreSimulator/Devices",
		"Library/Containers",
		"Library/Group Containers",
		".orbstack",
		"src/notes/.build",
	}
	home := fake_path(&tree, root, "home/ann")
	for k in kept {
		testing.expectf(t, fake_has(&tree, home, k), "%s is in the tree to be kept", k)
		full := strings.concatenate({"/home/ann/", k}, context.temp_allocator)
		for c in found {
			testing.expectf(t, !strings.has_prefix(c.path, full), "%s offered under %s", c.path, k)
		}
	}
}

// The user's Trash on another volume is theirs by id; the other users' and the
// volume's own files are not, and a scan of the volume itself reaches it.
@(test)
the_users_trash_on_another_volume_is_found :: proc(t: ^testing.T) {
	tree: Fake
	defer fake_destroy(&tree)
	root := fake_add(&tree, 0, "/", true)
	fake_path(&tree, root, "Volumes/Backup/.Trashes/1000/old")
	fake_path(&tree, root, "Volumes/Backup/.Trashes/501/theirs")
	fake_path(&tree, root, "Volumes/Backup/Photos/1000")
	fake_path(&tree, root, "Volumes/.Trashes/1000")
	found := find(fake_source(&tree), root, "/", ANN)
	defer candidates_destroy(found)
	want := []string{"/Volumes/Backup/.Trashes/1000"}
	got := found_paths(found)
	testing.expectf(t, slice.equal(got, want), "found\n%v\nwant\n%v", got, want)
	if len(found) == 1 {
		testing.expect_value(t, found[0].category, Category.Trash)
	}

	volume := fake_path(&tree, root, "Volumes/Backup")
	below := find(fake_source(&tree), volume, "/Volumes/Backup", ANN)
	defer candidates_destroy(below)
	testing.expect(t, slice.equal(found_paths(below), want))

	none := find(fake_source(&tree), root, "/", home.User{"/home/ann", ""})
	defer candidates_destroy(none)
	testing.expect_value(t, len(none), 0)
}
