package leita_view

import "core:testing"

import "jm:ui"
import "jm:ui/ops"
import "jm:ui/primer"
import "jm:ui/render"

@(private = "file")
about_frame :: proc(gtx: ^ui.Ctx, user: rawptr) {
	m := (^Model)(user)
	scheme := primer.theme_scheme(.Light)
	primer.use(&scheme, .Light)
	primer.use_fonts(FONTS)
	if ui.row(gtx, gap = 8) {
		about_button(gtx, m)
	}
	about_dialog(gtx, m)
}

// The toolbar's info button opens About, which names the product, its version
// and its maker and links to its page; Close closes it.
@(test)
about_names_the_product_and_its_maker :: proc(t: ^testing.T) {
	m: Model
	defer model_destroy(&m)
	fonts := []ops.Font_Ref {
		{0, ui.default_font(), 400},
		{1, ui.default_font(), 500},
		{2, ui.default_font(), 600},
		{3, ui.default_font(), 400},
	}
	h: render.Headless
	render.headless_init(&h, about_frame, &m, {900, 700}, fonts)
	defer render.headless_destroy(&h)

	testing.expect(t, !ui.probe_tagged(&h.p, "© Librium LLC"), "closed to begin with")
	testing.expect(t, ui.probe_click(&h.p, "About leita"))
	ui.probe_advance(&h.p, 10, 1.0 / 60)
	testing.expect(t, m.about_open)
	testing.expect(t, ui.probe_tagged(&h.p, "© Librium LLC"), "the maker")
	testing.expect(t, ui.probe_tagged(&h.p, "mordaunt.dev/leita"), "the product's page")
	testing.expect(t, ui.probe_click_top(&h.p, "Close"))
	ui.probe_advance(&h.p, 10, 1.0 / 60)
	testing.expect(t, !m.about_open, "Close closed it")
}
