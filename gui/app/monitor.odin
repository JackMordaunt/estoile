package leita_app

import "core:os"
import "core:strings"
import "core:time"

import "../../licence"
import "../../monitor"
import "../../schedule"
import "../../settings"
import "../command"
import "../query"

/*
Monitoring, on the desk: what the Monitoring dialog shows and changes. What is
watched and how each run went live in the settings store the monitor's runs
write (package monitor), so the window reads them afresh for every answer and
shows a run that finished while it was open the next time it answers.

Turning monitoring on hands the monitor to the system's scheduler as this
binary, `Leita monitor run`, which the window's main answers as the command
line's does; turning it off takes it back. Both are refused while the paid
features are locked but for turning it off, which always works.
*/

// Monitoring is the desk's part in monitoring: the scheduler it hands the
// monitor to, what that is to run, and how the last change asked for went.
Monitoring :: struct {
	host:      schedule.Host,
	own_host:  bool, // host was made by monitor_open, to be freed
	argv:      []string,
	scheduler: string, // the host's describe, kept
	changed:   u32,
	problem:   string,
	note:      string,
}

// monitor_open readies monitoring: on the system's scheduler running this
// binary, unless the caller gives a scheduler of its own and what it runs.
monitor_open :: proc(d: ^Desk, scheduler: ^schedule.Host, argv: []string) {
	mo := &d.monitoring
	if scheduler != nil {
		mo.host = scheduler^
	} else {
		mo.host = schedule.host_default()
		mo.own_host = true
	}
	exe := ""
	if len(argv) > 0 {
		exe = strings.clone(argv[0])
	} else if path, err := os.get_executable_path(context.allocator); err == nil {
		exe = path
	} else {
		exe = strings.clone(os.args[0])
	}
	mo.argv = make([]string, 3)
	mo.argv[0], mo.argv[1], mo.argv[2] = exe, "monitor", "run"
	mo.scheduler = strings.clone(schedule.describe(mo.host))
}

monitor_close :: proc(d: ^Desk) {
	mo := &d.monitoring
	if mo.own_host {
		schedule.host_destroy(&mo.host)
	}
	if len(mo.argv) > 0 {
		delete(mo.argv[0])
	}
	delete(mo.argv)
	delete(mo.scheduler)
	delete(mo.problem)
	delete(mo.note)
	mo^ = {}
}

// monitor_settle ends a change, with why it was refused, "" when it was made,
// and a note for the person, "" for none.
@(private = "file")
monitor_settle :: proc(d: ^Desk, problem: string, note := "") {
	mo := &d.monitoring
	delete(mo.problem)
	delete(mo.note)
	mo.problem = strings.clone(problem)
	mo.note = strings.clone(note)
	mo.changed += 1
}

// unlocked is whether the paid features work: under a licence, or in the trial.
@(private = "file")
unlocked :: proc(d: ^Desk) -> bool {
	return licence.unlocked(d.licensed, d.first_use)
}

// set_monitoring turns monitoring on or off as c asks.
set_monitoring :: proc(d: ^Desk, c: command.Monitoring) {
	if d.settings == nil {
		monitor_settle(d, say(d, .Monitor_Unkept))
		return
	}
	mo := &d.monitoring
	if !c.on {
		if err := settings.set_monitoring(d.settings, false); err != nil {
			monitor_settle(d, say(d, .Monitor_Unkept))
			return
		}
		if problem := schedule.remove(mo.host); problem != "" {
			monitor_settle(d, say(d, .Monitor_Cannot_Unschedule, mo.scheduler, problem))
			return
		}
		monitor_settle(d, "")
		return
	}
	if !unlocked(d) {
		monitor_settle(d, say(d, .Monitoring_Locked))
		return
	}
	problem, logged_in_only := schedule.install(mo.host, mo.argv)
	if problem != "" {
		monitor_settle(d, say(d, .Monitor_Cannot_Schedule, mo.scheduler, problem))
		return
	}
	if err := settings.set_monitoring(d.settings, true); err != nil {
		schedule.remove(mo.host)
		monitor_settle(d, say(d, .Monitor_Unkept))
		return
	}
	monitor_settle(d, "", say(d, .Monitor_Logged_In_Only, mo.host.login) if logged_in_only else "")
}

// watch has the monitor watch the place c names.
watch :: proc(d: ^Desk, c: ^command.Watch) {
	if d.settings == nil {
		monitor_settle(d, say(d, .Monitor_Unkept))
		return
	}
	if !unlocked(d) {
		monitor_settle(d, say(d, .Monitoring_Locked))
		return
	}
	path := strings.trim_space(command.text_of(&c.path))
	place := monitor.place_of(path)
	if path == "" || !os.exists(place) {
		monitor_settle(d, say(d, .Monitor_Not_There, path))
		return
	}
	every := settings.Frequency(c.every) if int(c.every) < len(settings.Frequency) else .Daily
	w := settings.Watch {
		place = place,
		every = every,
		added = time.to_unix_seconds(time.now()),
	}
	if err := settings.watch(d.settings, w); err != nil {
		monitor_settle(d, say(d, .Monitor_Unkept))
		return
	}
	monitor_settle(d, "")
}

// unwatch stops the monitor watching the place c names.
unwatch :: proc(d: ^Desk, c: ^command.Unwatch) {
	if d.settings == nil {
		monitor_settle(d, say(d, .Monitor_Unkept))
		return
	}
	if _, err := settings.unwatch(d.settings, command.text_of(&c.path)); err != nil {
		monitor_settle(d, say(d, .Monitor_Unkept))
		return
	}
	monitor_settle(d, "")
}

// monitor_answer is monitoring as the store has it now, in the temp allocator.
monitor_answer :: proc(d: ^Desk) -> query.Monitor_Result {
	mo := &d.monitoring
	r := query.Monitor_Result {
		scheduler = mo.scheduler,
		changed   = mo.changed,
		problem   = mo.problem,
		note      = mo.note,
	}
	if d.settings == nil {
		return r
	}
	r.on = settings.monitoring(d.settings)
	watches, err := settings.watches(d.settings, context.temp_allocator)
	if err != nil {
		return r
	}
	out := make([]query.Watched_Place, len(watches), context.temp_allocator)
	for w, i in watches {
		out[i] = {
			place = w.place,
			every = query.Frequency(w.every),
		}
		if last, ok := settings.last_run(d.settings, w.place, context.temp_allocator); ok {
			out[i].scanned = true
			out[i].started = last.started
			out[i].seconds = last.seconds
			out[i].bytes = last.bytes
			out[i].problem = last.problem
		}
	}
	r.watched = out
	return r
}
