#+build linux
package leita_files

import "core:os"

/*
open_default opens path as the desktop opens it, a file in its default
application and a folder in the file manager, and says whether that went well.

It asks gio(1) first, and falls back to xdg-open only on a system without gio.
On Hyprland on 2026-10-12, xdg-open (xdg-utils 1.2.1) found no branch for the
desktop, ran the desktop file's command itself and waited for it: a text file's
default, nvim.desktop, ran with no terminal, so nothing showed and xdg-open
never returned. gio open on the same machine returned in 11 ms, leaving the
application it started running.
*/
open_default :: proc(path: string) -> bool {
	process, err := os.process_start({command = {"gio", "open", path}})
	if err != nil {
		return run({"xdg-open", path})
	}
	state, _ := os.process_wait(process)
	return state.exit_code == 0
}
