extends Control
## Icône oreille (m'écoute) ou bouche (m'envoie du son), barrée en rouge si off.

var ear := false
var col := Color.WHITE
var off := false


static func draw_icon(ci: CanvasItem, c: Vector2, is_ear: bool, color: Color, is_off: bool) -> void:
	if is_ear:
		ci.draw_arc(c + Vector2(0, -2), 7, deg_to_rad(150), deg_to_rad(400), 18, color, 2.2, true)
		ci.draw_arc(c + Vector2(1, -1), 3.2, deg_to_rad(180), deg_to_rad(380), 10, color, 2.0, true)
		ci.draw_line(c + Vector2(-5, 3), c + Vector2(-1, 8), color, 2.2, true)
		ci.draw_line(c + Vector2(-1, 8), c + Vector2(3, 8), color, 2.2, true)
	else:
		ci.draw_arc(c, 9, deg_to_rad(15), deg_to_rad(165), 14, color, 2.4, true)
		ci.draw_line(c + Vector2(-8, 0), c + Vector2(8, 0), color, 2.0, true)
		ci.draw_arc(c + Vector2(0, -1), 6, deg_to_rad(200), deg_to_rad(340), 10, color, 2.0, true)
	if is_off:
		ci.draw_line(c + Vector2(-9, 9), c + Vector2(9, -9), Color("#f87171"), 2.6, true)


func _init() -> void:
	custom_minimum_size = Vector2(26, 26)
	mouse_filter = MOUSE_FILTER_IGNORE


func _draw() -> void:
	draw_icon(self, size / 2, ear, col, off)
