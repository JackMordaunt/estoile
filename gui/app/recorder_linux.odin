#+build linux
package leita_app

import "core:strings"

import "jm:sh"

import "../../journal"
import "../command"
import "../query"

/*
set_recording turns the recorder of changes on or off as c asks, by running this
binary's `journal on` or `journal off` under pkexec, which asks for the
administrator's rights it needs. The desk waits for it, as it waits for the
scheduler when monitoring is turned on.
*/
set_recording :: proc(d: ^Desk, c: command.Recording) {
	argv := []string{"pkexec", d.monitoring.argv[0], "journal", "on" if c.on else "off"}
	r := sh.exec(argv, {}, context.temp_allocator)
	why := ""
	switch {
	case r.ok:
		monitor_settle(d, "")
		return
	case r.err == nil && r.code == PKEXEC_DISMISSED:
		why = "the request for administrator rights was dismissed"
	case r.err == nil && r.code == PKEXEC_REFUSED:
		why = "administrator rights were not given"
	case strings.trim_space(r.stdout) != "":
		why = strings.trim_space(r.stdout)
	case:
		why = sh.error(r, context.temp_allocator)
	}
	monitor_settle(d, say(d, .Record_Changes_Failed, why))
}

// pkexec's exit codes when the rights it asked for were not given (pkexec(1)).
@(private = "file")
PKEXEC_DISMISSED :: 126
@(private = "file")
PKEXEC_REFUSED :: 127

// recorder_answer says in r whether the recorder is installed and running.
@(private)
recorder_answer :: proc(r: ^query.Monitor_Result) {
	r.recorder_shown = true
	r.recorder_on = journal.installed()
	r.recorder_running = r.recorder_on && journal.active()
}
