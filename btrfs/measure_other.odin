#+build !linux
package btrfs

// Measure the files under path. Only Linux has btrfs.
measure :: proc(path: string, u: ^Usage, visit: Visit = nil, data: rawptr = nil) -> Error {
	return .Unsupported
}
