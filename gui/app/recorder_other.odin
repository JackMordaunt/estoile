#+build !linux
package leita_app

import "../command"
import "../query"

// set_recording does nothing off Linux, where the update reads the system's own
// change journal (FSEvents, the USN journal: package changes); the dialog never
// offers it there.
set_recording :: proc(d: ^Desk, c: command.Recording) {
	_ = c
	monitor_settle(d, "")
}

// recorder_refresh has nothing to ask off Linux.
@(private)
recorder_refresh :: proc(d: ^Desk) {
	_ = d
}

// recorder_answer leaves the recorder unshown off Linux.
@(private)
recorder_answer :: proc(d: ^Desk, r: ^query.Monitor_Result) {
	_, _ = d, r
}
