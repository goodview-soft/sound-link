class_name RegionPreview
extends Control
## Aperçu de la fenêtre partagée où l'on trace deux cadres (joueurs, chat), en coordonnées 0..1 de l'image.

signal region_set(kind: String, rect: Rect2)

const COLORS := {"players": Color("#22d3ee"), "chat": Color("#7c6cff")}
const NAMES := {"players": "Joueurs", "chat": "Chat"}

var texture: Texture2D
var regions := {"players": Rect2(), "chat": Rect2()}
var pick := ""
var _drag := false
var _a := Vector2.ZERO
var _b := Vector2.ZERO


func _img_rect() -> Rect2:
	if texture == null:
		return Rect2(Vector2.ZERO, size)
	var ts := texture.get_size()
	var s := ts * minf(size.x / ts.x, size.y / ts.y)
	return Rect2((size - s) / 2.0, s)


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color("#0b0d12"))
	if texture:
		draw_texture_rect(texture, _img_rect(), false)
	var ir := _img_rect()
	for kind in regions:
		var r: Rect2 = regions[kind]
		if r.size.x > 0.0:
			var px := Rect2(ir.position + r.position * ir.size, r.size * ir.size)
			draw_rect(px, COLORS[kind], false, 2.0)
			draw_string(ThemeDB.fallback_font, px.position + Vector2(4, 15), NAMES[kind], HORIZONTAL_ALIGNMENT_LEFT, -1, 13, COLORS[kind])
	if _drag:
		draw_rect(Rect2(_a, _b - _a).abs(), COLORS[pick], false, 2.0)


func _gui_input(e: InputEvent) -> void:
	if pick == "":
		return
	if e is InputEventMouseButton and e.button_index == MOUSE_BUTTON_LEFT:
		if e.pressed:
			_drag = true
			_a = e.position
			_b = e.position
		elif _drag:
			_drag = false
			var ir := _img_rect()
			var px := Rect2(_a, _b - _a).abs().intersection(ir)
			if px.size.x > 8.0 and px.size.y > 8.0:
				var r := Rect2((px.position - ir.position) / ir.size, px.size / ir.size)
				regions[pick] = r
				region_set.emit(pick, r)
			pick = ""
		queue_redraw()
	elif e is InputEventMouseMotion and _drag:
		_b = e.position
		queue_redraw()
