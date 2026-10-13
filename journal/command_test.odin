package journal

import "core:fmt"
import "core:strings"
import "core:testing"

// The service runs the root-owned copy with only fanotify's capabilities, and may
// write only its own folder.
@(test)
test_the_service_is_confined :: proc(t: ^testing.T) {
	unit := unit_text()
	lines := []string {
		"ExecStart=/usr/local/libexec/leita/leita journal run",
		"Restart=on-failure",
		"CapabilityBoundingSet=CAP_SYS_ADMIN CAP_DAC_READ_SEARCH",
		"AmbientCapabilities=CAP_SYS_ADMIN CAP_DAC_READ_SEARCH",
		"NoNewPrivileges=yes",
		"ProtectSystem=strict",
		"ReadWritePaths=/var/lib/leita",
		"WantedBy=multi-user.target",
	}
	for line in lines {
		testing.expectf(
			t,
			strings.contains(unit, fmt.tprintf("%s\n", line)),
			"no %q in:\n%s",
			line,
			unit,
		)
	}
	testing.expect(t, !strings.contains(unit, "ProtectHome="), "ProtectHome hides /home")
}
