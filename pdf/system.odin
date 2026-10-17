package pdf

import "core:os"

// System fonts: text is set in what the machine has. Each list is tried in
// order, the first that loads taken; the first list's font is the one text is
// drawn in, and the rest are its fallbacks, for the scripts it lacks. Whether a
// font may be embedded is read from its OS/2 fsType (OpenType spec, OS/2 table;
// the bits face_init checks): add_font refuses one that forbids it, whatever its
// source.
//
// A machine with none of the first list gets Liberation Sans, which this
// package carries: Latin, Greek and Cyrillic, regular and bold, so a PDF is
// never refused for want of a font. A stock Fedora may be one (ASSUMPTION: its
// default Noto Sans is google-noto-sans-vf-fonts' variable NotoSans[wght].ttf
// under /usr/share/fonts/google-noto-vf, not a name listed here). Other scripts
// still come from the machine.
// Liberation Sans 2.1.5, from liberation-fonts-ttf-2.1.5.tar.gz (sha256
// 7191c669bf38899f73a2094ed00f7b800553364f90e2637010a69c0e268f25d0) of
// github.com/liberationfonts/liberation-fonts's release, under the SIL Open
// Font License 1.1 (fonts/LICENSE), which lets a program carry it so long as
// the licence goes with it: the window lists it among its notices.

// BUILTIN_REGULAR and BUILTIN_BOLD are the faces carried, 410,712 and 414,456
// bytes; a PDF embeds only the glyphs it draws.
@(private)
BUILTIN_REGULAR := #load("fonts/LiberationSans-Regular.ttf")
@(private)
BUILTIN_BOLD := #load("fonts/LiberationSans-Bold.ttf")

@(private)
SYSTEM_FONTS :: [][]string {
	// The font text is drawn in: a sans-serif.
	{
		"/usr/share/fonts/liberation/LiberationSans-Regular.ttf",
		"/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf",
		"/usr/share/fonts/liberation-sans/LiberationSans-Regular.ttf",
		"/usr/share/fonts/TTF/LiberationSans-Regular.ttf",
		"/usr/share/fonts/noto/NotoSans-Regular.ttf",
		"/usr/share/fonts/truetype/noto/NotoSans-Regular.ttf",
		"/usr/share/fonts/TTF/DejaVuSans.ttf",
		"/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
		"C:/Windows/Fonts/arial.ttf",
		"C:/Windows/Fonts/segoeui.ttf",
		"/System/Library/Fonts/Supplemental/Arial.ttf",
		"/Library/Fonts/Arial.ttf",
	},
	// A CJK font.
	{
		"/usr/share/fonts/noto-cjk/NotoSansCJK-Regular.ttc",
		"/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc",
		"/usr/share/fonts/google-noto-cjk/NotoSansCJK-Regular.ttc",
		"/usr/share/fonts/noto-cjk/NotoSansCJKjp-Regular.otf",
		"/usr/share/fonts/truetype/droid/DroidSansFallbackFull.ttf",
		"/usr/share/fonts/wenquanyi/wqy-microhei/wqy-microhei.ttc",
		"C:/Windows/Fonts/msgothic.ttc",
		"C:/Windows/Fonts/msyh.ttc",
		"/System/Library/Fonts/Supplemental/Arial Unicode.ttf",
		"/Library/Fonts/Arial Unicode.ttf",
	},
	{
		"/usr/share/fonts/noto/NotoSansArabic-Regular.ttf",
		"/usr/share/fonts/truetype/noto/NotoSansArabic-Regular.ttf",
	},
	{
		"/usr/share/fonts/noto/NotoSansHebrew-Regular.ttf",
		"/usr/share/fonts/truetype/noto/NotoSansHebrew-Regular.ttf",
	},
	{
		"/usr/share/fonts/noto/NotoSansDevanagari-Regular.ttf",
		"/usr/share/fonts/truetype/noto/NotoSansDevanagari-Regular.ttf",
	},
	{
		"/usr/share/fonts/noto/NotoSansThai-Regular.ttf",
		"/usr/share/fonts/truetype/noto/NotoSansThai-Regular.ttf",
	},
	{"/usr/share/fonts/noto/NotoSansSymbols2-Regular.ttf", "C:/Windows/Fonts/seguisym.ttf"},
}

// add_system_fonts adds a sans-serif font found on this machine and, as its
// fallbacks, whichever fonts for other scripts are there too, and returns the
// first: Liberation Sans, carried, where no sans-serif of SYSTEM_FONTS is
// installed. Fonts are read whole and kept until destroy:
// NotoSansCJK-Regular.ttc is 19,484,784 bytes on Arch (noto-fonts-cjk,
// 2025-02). false only if the carried face would not load, which pdf_test's
// a_machine_without_fonts_sets_text_in_the_carried_face rules out.
//
// Given bold, it also adds the bold face of the sans-serif chosen, with the
// same fallbacks, and sets bold to it; to the regular face where SYSTEM_BOLD
// names none beside it, or that one is not installed.
//
// installed false looks at none of the machine's fonts, as on one that has
// none, for tests.
add_system_fonts :: proc(doc: ^Document, bold: ^Font = nil, installed := true) -> (Font, bool) {
	lists := SYSTEM_FONTS if installed else nil
	sans: []string
	if len(lists) > 0 {
		sans = lists[0]
	}
	primary, heavy := add_sans(doc, sans, bold != nil)
	if primary < 0 {
		return -1, false
	}
	for paths in lists[min(1, len(lists)):] {
		for path in paths {
			if !os.exists(path) {
				continue
			}
			font, err := add_font_file(doc, path)
			if err != .None {
				continue
			}
			add_fallback(doc, primary, font)
			if heavy >= 0 {
				add_fallback(doc, heavy, font)
			}
			break
		}
	}
	if bold != nil {
		bold^ = heavy if heavy >= 0 else primary
	}
	return primary, true
}

// add_sans adds the first of paths installed, and its bold face from
// SYSTEM_BOLD when asked for and there; Liberation Sans, carried, when none
// of paths is. -1 for a face not added.
@(private)
add_sans :: proc(doc: ^Document, paths: []string, with_bold: bool) -> (regular, bold: Font) {
	regular, bold = -1, -1
	for path, i in paths {
		if !os.exists(path) {
			continue
		}
		font, err := add_font_file(doc, path)
		if err != .None {
			continue
		}
		regular = font
		if bolds := SYSTEM_BOLD; with_bold && i < len(bolds) && os.exists(bolds[i]) {
			if b, berr := add_font_file(doc, bolds[i]); berr == .None {
				bold = b
			}
		}
		return
	}
	if f, err := add_font(doc, BUILTIN_REGULAR); err == .None {
		regular = f
	}
	if with_bold {
		if f, err := add_font(doc, BUILTIN_BOLD); err == .None {
			bold = f
		}
	}
	return
}

// SYSTEM_BOLD is the bold face of each sans-serif in SYSTEM_FONTS' first list,
// at the same index.
@(private)
SYSTEM_BOLD :: []string {
	"/usr/share/fonts/liberation/LiberationSans-Bold.ttf",
	"/usr/share/fonts/truetype/liberation/LiberationSans-Bold.ttf",
	"/usr/share/fonts/liberation-sans/LiberationSans-Bold.ttf",
	"/usr/share/fonts/TTF/LiberationSans-Bold.ttf",
	"/usr/share/fonts/noto/NotoSans-Bold.ttf",
	"/usr/share/fonts/truetype/noto/NotoSans-Bold.ttf",
	"/usr/share/fonts/TTF/DejaVuSans-Bold.ttf",
	"/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
	"C:/Windows/Fonts/arialbd.ttf",
	"C:/Windows/Fonts/segoeuib.ttf",
	"/System/Library/Fonts/Supplemental/Arial Bold.ttf",
	"/Library/Fonts/Arial Bold.ttf",
}
