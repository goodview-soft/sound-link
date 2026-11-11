class_name Overlay
extends Window
## Fenêtre transparente toujours au-dessus, en haut à droite de l'écran : traductions des messages du chat.
## Visible par-dessus un jeu en fenêtré ou plein écran sans bordure (pas en plein écran exclusif).

const SHOW_SECS := 14.0
const MAX_ITEMS := 6

var _box := VBoxContainer.new()


func _init() -> void:
	title = "Sound Link overlay"
	borderless = true
	always_on_top = true
	transparent = true
	transparent_bg = true
	unfocusable = true
	mouse_passthrough = true
	exclusive = false
	size = Vector2i(460, 460)
	visible = false


func _ready() -> void:
	theme = Ui.theme()
	_box.add_theme_constant_override("separation", 6)
	_box.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_box)
	var r := DisplayServer.screen_get_usable_rect()
	position = Vector2i(r.end.x - size.x - 16, r.position.y + 16)


func push(who: String, lang: String, original: String, french: String) -> void:
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", Ui.sb(Color(0.05, 0.06, 0.09, 0.84), 10, 12, 8))
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 2)
	p.add_child(v)
	var h := Ui.label("%s  ·  %s → FR" % [who if who != "" else "Chat", lang.to_upper()], v)
	h.add_theme_font_size_override("font_size", 12)
	h.add_theme_color_override("font_color", Ui.C_ACCENT2)
	var m := Ui.label(french, v)
	m.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	m.add_theme_font_size_override("font_size", 18)
	var o := Ui.label(original, v)
	o.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	o.add_theme_font_size_override("font_size", 12)
	o.add_theme_color_override("font_color", Ui.C_MUTED)
	_box.add_child(p)
	while _box.get_child_count() > MAX_ITEMS:
		_box.get_child(0).free()
	visible = true
	get_tree().create_timer(SHOW_SECS).timeout.connect(func() -> void:
		if not is_instance_valid(p):
			return
		var tw := p.create_tween()
		tw.tween_property(p, "modulate:a", 0.0, 0.6)
		tw.finished.connect(func() -> void:
			if is_instance_valid(p):
				p.free()
			if is_instance_valid(self) and _box.get_child_count() == 0:
				visible = false))
