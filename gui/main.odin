/*
Leita: see what is using the disk, as the scan finds it.

	Leita                  scan the home directory
	Leita PATH             scan a directory, drive or image
	Leita monitor ...      monitoring's command line, as leita monitor

The window is jm:ui in Primer. Its pieces are gui's packages:

	query    the reads the window may need, and their results   (leaf)
	command  what the window may ask the application to do      (leaf)
	app      the host: the pipeline, the desk and the reader     (io)
	view     the window: shapes in, commands out                 (ui)

This is the window around app.
*/
package main

import "core:debug/trace"
import "core:os"

@(require) import "jm:debug"
import "jm:ui/shell"

import "../history"
import "../monitor"
import "../version"
import "app"
@(require) import "leaks"
import "msg"
import "view"

main :: proc() {
	when ODIN_DEBUG {
		da: debug.Allocator
		debug.init(&da, context.allocator)
		defer debug.destroy(&da)
		defer debug.report(&da)
		context.allocator = debug.allocator(&da)
	}
	context.assertion_failure_proc = trace.assertion_failure_proc

	// Leita monitor ... is monitoring's command line, as leita monitor is, so the
	// scheduler can run whichever binary turned monitoring on.
	if len(os.args) > 1 && os.args[1] == "monitor" {
		code := monitor.run_command_line(os.args[2:])
		free_all(context.temp_allocator)
		os.exit(code)
	}

	path :=
		os.args[1] if len(os.args) > 1 else (os.user_home_dir(context.temp_allocator) or_else "/")

	h := new(app.Host)
	defer free(h)
	// Each finished scan is kept, to compare the next with.
	kept := history.default_path()
	defer delete(kept)
	app.init(h, path, shell.wake, kept)

	m: view.Model
	view.model_init(&m, path, msg.system_locale())
	defer view.model_destroy(&m)

	faces := view.fonts()
	defer delete(faces)
	scripts := view.fallbacks(faces)
	defer delete(scripts)

	shell.run(
		{
			title = version.NAME + " " + version.VERSION,
			width = 1280,
			height = 820,
			min_width = 640,
			min_height = 420,
			ui = view.view,
			user = &m,
			fonts = faces,
			fallbacks = scripts,
			clear = {255, 255, 255, 255},
			data = app.data_host(h),
		},
	)
	app.stop(h)
	free_all(context.temp_allocator)
}
