extends Window
## Petit overlay façon Discord en bas de l'écran : pastilles des appareils connectés,
## anneau vert quand l'appareil parle. Transparent, toujours au-dessus, insensible à la souris.

const DevIcon := preload("res://dev_icon.gd")
const C_BG := Color(0.08, 0.09, 0.12, 0.88)
const C_TEXT := Color("#e7eaf0")
const C_OK := Color("#5eead4")
const C_ACCENT := Color("#ffb347")
const C_MUTED := Color("#7d8497")
const H := 44.0
const PAD := 10.0
const ICON := 22.0

var items: Array = []  # [{name, talk, mute}]
var font: Font
var canvas: Control


func _init() -> void:
	visible = false
	force_native = true
	transparent = true
	transparent_bg = true
	borderless = true
	always_on_top = true
	unfocusable = true
	mouse_passthrough = true
	exclusive = false
	title = "Sound Link overlay"


func _ready() -> void:
	font = ThemeDB.fallback_font
	canvas = Control.new()
	canvas.set_anchors_preset(Control.PRESET_FULL_RECT)
	canvas.mouse_filter = Control.MOUSE_FILTER_IGNORE
	canvas.draw.connect(_draw_items)
	add_child(canvas)


func _chip_w(it: Dictionary) -> float:
	return H + font.get_string_size(it["name"], HORIZONTAL_ALIGNMENT_LEFT, 160, 15).x + 14.0 + 2 * ICON + 22.0


func set_items(list: Array) -> void:
	items = list
	if items.is_empty():
		visible = false
		return
	var w := 0.0
	for it in items:
		w = maxf(w, _chip_w(it))
	var sz := Vector2i(int(w + PAD * 2), int((H + 6.0) * items.size() - 6.0 + PAD * 2))
	var scr := DisplayServer.screen_get_usable_rect(DisplayServer.window_get_current_screen(0))
	size = sz
	position = Vector2i(scr.position.x + 12, scr.position.y + scr.size.y - sz.y - 12)  # en bas à gauche
	visible = true
	canvas.queue_redraw()


func _icon(c: Vector2, ear: bool, col: Color, off: bool) -> void:
	DevIcon.draw_icon(canvas, c, ear, col, off)


func _draw_items() -> void:
	var y := PAD
	for it in items:
		var w := _chip_w(it)
		var r := Rect2(PAD, y, w, H)
		var sb := StyleBoxFlat.new()
		sb.bg_color = C_BG
		sb.set_corner_radius_all(int(H / 2))
		canvas.draw_style_box(sb, r)
		var c := Vector2(PAD + H / 2, y + H / 2)
		var col: Color = C_OK if it["talk"] else C_MUTED
		canvas.draw_circle(c, H / 2 - 6, Color(0.16, 0.18, 0.24))
		canvas.draw_arc(c, H / 2 - 5, 0, TAU, 40, col, 3.0 if it["talk"] else 1.5, true)
		var ini: String = it["name"].substr(0, 1).to_upper()
		var fs := font.get_string_size(ini, HORIZONTAL_ALIGNMENT_LEFT, -1, 17)
		canvas.draw_string(font, c + Vector2(-fs.x / 2, 6), ini, HORIZONTAL_ALIGNMENT_LEFT, -1, 17, C_TEXT)
		canvas.draw_string(font, Vector2(PAD + H, y + H / 2 + 5), it["name"], HORIZONTAL_ALIGNMENT_LEFT, 160, 15, C_MUTED if it["mute"] else C_TEXT)
		var ix := PAD + w - 14.0 - ICON * 0.5
		var cy := y + H / 2
		if it["mouth"]:
			_icon(Vector2(ix, cy), false, C_OK if it["talk"] else C_MUTED, it["mute"])
		ix -= ICON + 8.0
		if it["ear"]:
			_icon(Vector2(ix, cy), true, C_OK if it["ear_on"] else C_MUTED, not it["ear_on"])
		y += H + 6.0
