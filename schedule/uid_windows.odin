#+build windows
package leita_schedule

// user_id is "" on Windows, where Task Scheduler runs a task as the user who
// made it.
user_id :: proc(allocator := context.allocator) -> string {
	return ""
}
