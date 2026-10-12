package leita_msg

import win "core:sys/windows"

foreign import kernel32 "system:Kernel32.lib"

@(default_calling_convention = "system")
foreign kernel32 {
	GetUserDefaultLocaleName :: proc(name: [^]u16, size: i32) -> i32 ---
}

// user_locale is the user's locale's BCP 47 tag ("pt-BR"), in the temp
// allocator; "" when Windows will not say.
user_locale :: proc() -> string {
	buf: [win.LOCALE_NAME_MAX_LENGTH]u16
	n := GetUserDefaultLocaleName(&buf[0], i32(len(buf)))
	if n <= 1 {
		return ""
	}
	tag, err := win.utf16_to_utf8(buf[:n - 1], context.temp_allocator)
	return tag if err == nil else ""
}
