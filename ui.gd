class_name Ui
extends RefCounted
## Thème et petits constructeurs d'interface partagés.

const C_BG := Color("#0e1015")
const C_CARD := Color("#171a22")
const C_FIELD := Color("#10131a")
const C_BORDER := Color("#262b37")
const C_ACCENT := Color("#7c6cff")
const C_ACCENT2 := Color("#22d3ee")
const C_TEXT := Color("#e7eaf0")
const C_MUTED := Color("#8a92a6")
const C_OK := Color("#34d399")
const C_DANGER := Color("#f87171")

static func theme() -> Theme:
	var t := Theme.new()
	var f := SystemFont.new()
	f.font_names = PackedStringArray(["Inter", "Cantarell", "Noto Sans", "Ubuntu", "DejaVu Sans"])
	t.default_font = f
	t.default_font_size = 15
	t.set_color("font_color", "Label", C_TEXT)

	var bn := sb(Color("#222735"), 9, 14, 9)
	var bh := sb(Color("#2b3142"), 9, 14, 9)
	var bp := sb(Color("#1b1f2a"), 9, 14, 9)
	for ty in ["Button", "OptionButton"]:
		t.set_stylebox("normal", ty, bn)
		t.set_stylebox("hover", ty, bh)
		t.set_stylebox("pressed", ty, bp)
		t.set_stylebox("hover_pressed", ty, bh)
		t.set_stylebox("disabled", ty, bn)
		t.set_stylebox("focus", ty, StyleBoxEmpty.new())
		for c in ["font_color", "font_hover_color", "font_focus_color"]:
			t.set_color(c, ty, C_TEXT)
		t.set_color("font_pressed_color", ty, Color.WHITE)
		t.set_color("font_hover_pressed_color", ty, Color.WHITE)

	# Onglets : transparents, l'actif en accent
	t.set_type_variation("Tab", "Button")
	t.set_stylebox("normal", "Tab", sb(Color(0, 0, 0, 0), 9, 10, 9))
	t.set_stylebox("hover", "Tab", sb(Color("#1d2230"), 9, 10, 9))
	t.set_stylebox("pressed", "Tab", sb(C_ACCENT, 9, 10, 9))
	t.set_stylebox("hover_pressed", "Tab", sb(C_ACCENT.lightened(0.08), 9, 10, 9))
	t.set_color("font_color", "Tab", C_MUTED)

	# Bouton principal / bouton d'arrêt
	t.set_type_variation("Primary", "Button")
	t.set_stylebox("normal", "Primary", sb(C_ACCENT, 10, 16, 12))
	t.set_stylebox("hover", "Primary", sb(C_ACCENT.lightened(0.1), 10, 16, 12))
	t.set_stylebox("pressed", "Primary", sb(C_ACCENT.darkened(0.15), 10, 16, 12))
	t.set_color("font_color", "Primary", Color.WHITE)
	t.set_color("font_hover_color", "Primary", Color.WHITE)
	t.set_font_size("font_size", "Primary", 16)
	t.set_type_variation("Danger", "Button")
	t.set_stylebox("normal", "Danger", sb(Color("#3a1f26"), 10, 16, 12, C_DANGER))
	t.set_stylebox("hover", "Danger", sb(Color("#4a2430"), 10, 16, 12, C_DANGER))
	t.set_stylebox("pressed", "Danger", sb(Color("#2c171c"), 10, 16, 12, C_DANGER))
	t.set_color("font_color", "Danger", C_DANGER)
	t.set_color("font_hover_color", "Danger", Color("#fecaca"))
	t.set_font_size("font_size", "Danger", 16)

	# Cartes de mode (accueil)
	t.set_type_variation("ModeCard", "Button")
	t.set_stylebox("normal", "ModeCard", sb(C_CARD, 14, 16, 14, C_BORDER))
	t.set_stylebox("hover", "ModeCard", sb(Color("#1d2130"), 14, 16, 14, C_ACCENT))
	t.set_stylebox("pressed", "ModeCard", sb(Color("#241f45"), 14, 16, 14, C_ACCENT))
	t.set_stylebox("hover_pressed", "ModeCard", sb(Color("#241f45"), 14, 16, 14, C_ACCENT))

	t.set_type_variation("IconBtn", "Button")
	t.set_stylebox("normal", "IconBtn", sb(Color("#1d2130"), 12, 0, 0))
	t.set_stylebox("hover", "IconBtn", sb(Color("#272c3c"), 12, 0, 0))
	t.set_stylebox("pressed", "IconBtn", sb(C_ACCENT, 12, 0, 0))
	t.set_stylebox("hover_pressed", "IconBtn", sb(C_ACCENT.lightened(0.08), 12, 0, 0))
	t.set_type_variation("Round", "Button")
	t.set_stylebox("normal", "Round", sb(C_ACCENT, 40, 0, 0))
	t.set_stylebox("hover", "Round", sb(C_ACCENT.lightened(0.1), 40, 0, 0))
	t.set_stylebox("pressed", "Round", sb(C_ACCENT.darkened(0.15), 40, 0, 0))
	t.set_type_variation("RoundOn", "Button")
	t.set_stylebox("normal", "RoundOn", sb(Color("#3a1f26"), 40, 0, 0, C_DANGER))
	t.set_stylebox("hover", "RoundOn", sb(Color("#4a2430"), 40, 0, 0, C_DANGER))
	t.set_stylebox("pressed", "RoundOn", sb(Color("#2c171c"), 40, 0, 0, C_DANGER))
	t.set_type_variation("Chip", "Button")
	t.set_stylebox("normal", "Chip", sb(Color(C_ACCENT2, 0.10), 10, 9, 3))
	t.set_stylebox("hover", "Chip", sb(Color(C_ACCENT2, 0.2), 10, 9, 3))
	t.set_stylebox("pressed", "Chip", sb(Color(C_ACCENT2, 0.3), 10, 9, 3))
	for k in ["font_color", "font_hover_color", "font_pressed_color"]:
		t.set_color(k, "Chip", C_ACCENT2)
	t.set_font_size("font_size", "Chip", 13)

	t.set_type_variation("Toggle", "Button")
	t.set_stylebox("normal", "Toggle", sb(Color("#1d2130"), 10, 12, 5, C_BORDER))
	t.set_stylebox("hover", "Toggle", sb(Color("#272c3c"), 10, 12, 5, C_BORDER))
	t.set_stylebox("pressed", "Toggle", sb(C_ACCENT, 10, 12, 5))
	t.set_stylebox("hover_pressed", "Toggle", sb(C_ACCENT.lightened(0.08), 10, 12, 5))
	t.set_color("font_color", "Toggle", C_MUTED)
	t.set_font_size("font_size", "Toggle", 13)
	t.set_type_variation("Pad", "Button")
	t.set_stylebox("normal", "Pad", sb(Color("#1b1f2b"), 10, 6, 14, C_BORDER))
	t.set_stylebox("hover", "Pad", sb(Color("#232838"), 10, 6, 14, C_ACCENT))
	t.set_stylebox("pressed", "Pad", sb(Color("#2d2656"), 10, 6, 14, C_ACCENT))
	t.set_font_size("font_size", "Pad", 13)

	# Champs texte
	t.set_stylebox("normal", "LineEdit", sb(C_FIELD, 9, 12, 10, C_BORDER))
	t.set_stylebox("focus", "LineEdit", sb(C_FIELD, 9, 12, 10, C_ACCENT))
	t.set_color("font_color", "LineEdit", C_TEXT)
	t.set_color("font_placeholder_color", "LineEdit", C_MUTED)
	t.set_color("caret_color", "LineEdit", C_ACCENT2)

	# Curseurs
	var track := sb(C_BORDER, 4, 0, 3)
	var fill := sb(C_ACCENT, 4, 0, 3)
	t.set_stylebox("slider", "HSlider", track)
	t.set_stylebox("grabber_area", "HSlider", fill)
	t.set_stylebox("grabber_area_highlight", "HSlider", sb(C_ACCENT.lightened(0.1), 4, 0, 3))
	t.set_icon("grabber", "HSlider", circle(18, Color.WHITE))
	t.set_icon("grabber_highlight", "HSlider", circle(18, C_ACCENT2))

	# Interrupteurs
	for s in ["normal", "hover", "pressed", "hover_pressed", "focus"]:
		t.set_stylebox(s, "CheckButton", StyleBoxEmpty.new())
	for c in ["font_color", "font_hover_color", "font_pressed_color", "font_hover_pressed_color", "font_focus_color"]:
		t.set_color(c, "CheckButton", C_TEXT)

	# Cartes, barres de défilement
	t.set_stylebox("panel", "PanelContainer", sb(C_CARD, 14, 16, 14, C_BORDER))
	var grab := sb(C_BORDER, 4, 3, 3)
	t.set_stylebox("scroll", "VScrollBar", sb(Color(0, 0, 0, 0), 4, 3, 3))
	for s in ["grabber", "grabber_highlight", "grabber_pressed"]:
		t.set_stylebox(s, "VScrollBar", grab)
	t.set_color("font_color", "TooltipLabel", C_TEXT)
	t.set_stylebox("panel", "TooltipPanel", sb(C_CARD, 6, 8, 5, C_BORDER))
	return t


static func sb(col: Color, radius: int, pad_h: int, pad_v: int, border := Color(0, 0, 0, 0)) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = col
	s.set_corner_radius_all(radius)
	s.content_margin_left = pad_h
	s.content_margin_right = pad_h
	s.content_margin_top = pad_v
	s.content_margin_bottom = pad_v
	if border.a > 0:
		s.border_color = border
		s.set_border_width_all(1)
	s.anti_aliasing = true
	return s


static func circle(d: int, col: Color) -> ImageTexture:
	var img := Image.create(d, d, false, Image.FORMAT_RGBA8)
	var c := (d - 1) / 2.0
	for y in d:
		for x in d:
			var a := clampf(c - Vector2(x - c, y - c).length() + 0.5, 0.0, 1.0)
			img.set_pixel(x, y, Color(col, a))
	return ImageTexture.create_from_image(img)


static func card(parent: Node, title := "") -> VBoxContainer:
	var p := PanelContainer.new()
	parent.add_child(p)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 10)
	p.add_child(v)
	if title != "":
		var l := label(title.to_upper(), v)
		l.add_theme_font_size_override("font_size", 12)
		l.add_theme_color_override("font_color", C_MUTED)
	return v


static func label(t: String, parent: Node) -> Label:
	var l := Label.new()
	l.text = t
	parent.add_child(l)
	return l


static func hint(t: String, parent: Node) -> Label:
	var l := label(t, parent)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.add_theme_color_override("font_color", C_MUTED)
	l.add_theme_font_size_override("font_size", 13)
	return l


static func button(t: String, parent: Node) -> Button:
	var b := Button.new()
	b.text = t
	parent.add_child(b)
	return b


static func icon_btn(kind: String, parent: Node, sz := 40.0) -> Button:
	var b := Button.new()
	b.theme_type_variation = "IconBtn"
	b.custom_minimum_size = Vector2(sz, sz)
	b.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var ic := AppIcon.new(kind, 0)
	ic.scale_f = 0.55
	ic.set_anchors_preset(Control.PRESET_FULL_RECT)
	b.add_child(ic)
	b.set_meta("icon", ic)
	if parent:
		parent.add_child(b)
	return b


static func caption(parent: Node) -> Label:
	var l := label("", parent)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.add_theme_color_override("font_color", C_MUTED)
	l.add_theme_font_size_override("font_size", 13)
	return l


static func tile(parent: Node, kind: String, title: String, cb: Callable) -> void:
	var b := Button.new()
	b.theme_type_variation = "ModeCard"
	b.custom_minimum_size.y = 148
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	parent.add_child(b)
	var v := VBoxContainer.new()
	v.set_anchors_preset(Control.PRESET_FULL_RECT)
	v.alignment = BoxContainer.ALIGNMENT_CENTER
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.add_theme_constant_override("separation", 12)
	b.add_child(v)
	var ic := AppIcon.new(kind, 46, C_ACCENT2)
	ic.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	v.add_child(ic)
	var l := label(title, v)
	l.add_theme_font_size_override("font_size", 18)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	b.pressed.connect(cb)
