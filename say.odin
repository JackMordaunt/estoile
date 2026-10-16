package main

import "core:fmt"
import "core:strings"

import "scan"
import "term"

/*
How the command line says things. Everything it prints goes through here, so
one decision covers it: style is what the summary on standard output may
carry and estyle what standard error may, plain unless a person is watching
that stream, so a pipe, a script, an agent and every test read the words
alone. run sets both once, from --color, LEITA_COLOR and the streams
themselves; a test never does, and gets the zero value, plain.
*/
style, estyle: term.Style

// LABEL is the column the summary's labels are padded to, so their values
// line up: "tree       106 slots".
LABEL :: 10

bold :: proc(text: string) -> string {
	return term.painted(style, {.Bold}, text)
}

dim :: proc(text: string) -> string {
	return term.painted(style, {.Dim}, text)
}

// label writes one line of the summary: name in bold, padded to LABEL, then
// what it says.
label :: proc(name: string, format: string, args: ..any) {
	pad := strings.repeat(" ", max(LABEL - len(name), 0) + 1, context.temp_allocator)
	fmt.printfln("%s%s%s", bold(name), pad, fmt.tprintf(format, ..args))
}

// say_heading opens a list: its name in bold, the count dim beside it.
say_heading :: proc(name: string, count: int) {
	fmt.println()
	fmt.printfln("%s %s", bold(name), dim(fmt.tprintf("(%d)", count)))
}

// say_error says what went wrong on standard error, the prefix in bold.
say_error :: proc(format: string, args: ..any) {
	fmt.eprintfln("%s %s", term.painted(estyle, {.Bold}, "error:"), fmt.tprintf(format, ..args))
}

// say_note says what a person should know, on standard error so a report on
// standard output stays whole.
say_note :: proc(format: string, args: ..any) {
	fmt.eprintfln("%s %s", term.painted(estyle, {.Bold}, "note:"), fmt.tprintf(format, ..args))
}

/*
say_unread says how many directories the scan could not open, on standard error as
a warning rather than a failure: the tree is short of them, not wrong. On macOS a
refusal for want of permission is commonly a folder the system guards under the home
directory, such as Library/Mail, which Full Disk Access for the terminal lifts.
*/
say_unread :: proc(t: ^scan.Tree) {
	count, denied := scan.unread(t)
	if count == 0 {
		return
	}
	hint := ""
	if ODIN_OS == .Darwin && denied {
		hint = "; grant Full Disk Access to your terminal in System Settings › Privacy & Security › Full Disk Access"
	}
	say_note("%d %s could not be read%s", count, "folder" if count == 1 else "folders", hint)
}
