package leita_schedule

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

/*
On macOS the entry is a launchd agent in ~/Library/LaunchAgents, loaded into the
person's GUI domain with launchctl bootstrap. StartInterval runs it every hour;
launchd.plist(5) says of StartInterval that a job due while the system slept is
started when it wakes, and launchd(8) runs one instance of a job at a time.
ProcessType Background, Nice and LowPriorityIO keep the scan out of the way.
launchd.plist(5) gives each key, and launchctl(1) the bootstrap and bootout
subcommands.
*/

// AGENT_LABEL is the agent's label, and its file's name before .plist.
AGENT_LABEL :: "dev.mordaunt.leita.monitor"

// INTERVAL is how often the agent runs, in seconds.
INTERVAL :: 60 * 60

// agent_plist is the agent that runs argv every INTERVAL seconds.
agent_plist :: proc(argv: []string, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_string(&b, `<?xml version="1.0" encoding="UTF-8"?>` + "\n")
	strings.write_string(
		&b,
		`<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">` +
		"\n",
	)
	strings.write_string(&b, "<plist version=\"1.0\">\n<dict>\n")
	fmt.sbprintf(&b, "\t<key>Label</key>\n\t<string>%s</string>\n", AGENT_LABEL)
	strings.write_string(&b, "\t<key>ProgramArguments</key>\n\t<array>\n")
	for arg in argv {
		fmt.sbprintf(&b, "\t\t<string>%s</string>\n", escape_xml(arg))
	}
	strings.write_string(&b, "\t</array>\n")
	fmt.sbprintf(&b, "\t<key>StartInterval</key>\n\t<integer>%d</integer>\n", INTERVAL)
	strings.write_string(&b, "\t<key>RunAtLoad</key>\n\t<false/>\n")
	strings.write_string(&b, "\t<key>ProcessType</key>\n\t<string>Background</string>\n")
	strings.write_string(&b, "\t<key>Nice</key>\n\t<integer>10</integer>\n")
	strings.write_string(&b, "\t<key>LowPriorityIO</key>\n\t<true/>\n")
	strings.write_string(&b, "</dict>\n</plist>\n")
	return strings.to_string(b)
}

// agent_path is the agent's file.
@(private)
agent_path :: proc(h: Host) -> string {
	path, _ := filepath.join({h.agents, AGENT_LABEL + ".plist"}, context.temp_allocator)
	return path
}

// domain is the person's GUI domain, as launchctl names it.
@(private)
domain :: proc(h: Host) -> string {
	return fmt.tprintf("gui/%s", h.uid)
}

// install_agent writes the agent and loads it, unloading one loaded before.
@(private)
install_agent :: proc(h: Host, argv: []string) -> string {
	if err := os.make_directory_all(h.agents); err != nil && err != .Exist {
		return fmt.tprintf("cannot make %s: %v", h.agents, err)
	}
	path := agent_path(h)
	// launchctl(1): bootstrap fails for a job already loaded, which runs what
	// its file said when it was, so any loaded before goes first.
	h.run({"launchctl", "bootout", fmt.tprintf("%s/%s", domain(h), AGENT_LABEL)}, h.user)
	if err := os.write_entire_file(path, agent_plist(argv)); err != nil {
		return fmt.tprintf("cannot write %s: %v", path, err)
	}
	if r := h.run({"launchctl", "bootstrap", domain(h), path}, h.user); !r.ok {
		os.remove(path)
		return r.err
	}
	return ""
}

// remove_agent unloads the agent and deletes its file, if it is there.
@(private)
remove_agent :: proc(h: Host) -> string {
	path := agent_path(h)
	if !os.exists(path) {
		return ""
	}
	h.run({"launchctl", "bootout", fmt.tprintf("%s/%s", domain(h), AGENT_LABEL)}, h.user)
	if err := os.remove(path); err != nil && err != .Not_Exist {
		return fmt.tprintf("cannot delete %s: %v", path, err)
	}
	return ""
}
