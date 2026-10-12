package leita_alert

import "core:fmt"
import "core:math"

import "../gui/msg"
import "../human"

/*
say is a in words, in the language s is in, for a person: a notification's
body, a line in the window's list of alerts. place is the place watched;
problem is why its scan failed, for Scan_Failed. In the temp allocator.
*/
say :: proc(s: ^msg.Strings, a: Alert, place: string, problem := "") -> string {
	percent :: proc(v: f64) -> string {
		return fmt.tprintf("%.1f%%", v)
	}
	switch a.kind {
	case .Warn_Used:
		return msg.trf(
			s,
			.Alert_Warn_Used,
			place,
			percent(a.used_percent),
			fmt.tprintf("%.0f%%", a.limit),
		)
	case .Fail_Used:
		return msg.trf(
			s,
			.Alert_Fail_Used,
			place,
			percent(a.used_percent),
			fmt.tprintf("%.0f%%", a.limit),
		)
	case .Low_Free:
		return msg.trf(s, .Alert_Low_Free, place, human.bytes(a.free), human.bytes(u64(a.limit)))
	case .Growth:
		return msg.trf(s, .Alert_Growth, place, human.bytes(a.grew))
	case .Filling:
		if a.days < 1 {
			return msg.trf(s, .Alert_Filling_Today, place)
		}
		return msg.trf(s, .Alert_Filling, int(math.round(a.days)), place)
	case .Scan_Failed:
		return msg.trf(s, .Alert_Scan_Failed, place, problem)
	}
	return ""
}
