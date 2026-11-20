extends Control
## Icône oreille (m'écoute) ou bouche (m'envoie du son), barrée en rouge si off.

signal picked
var dev_type := ""  # "p" téléphone, "c" ordinateur, "e" enceinte : si défini, dessine l'appareil
var selected := false
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


## Silhouette d'appareil : p téléphone, c ordinateur, e enceinte (centrée en c, ~22 px).
static func draw_device(ci: CanvasItem, c: Vector2, type: String, col: Color) -> void:
	match type:
		"p":
			ci.draw_rect(Rect2(c + Vector2(-6, -10), Vector2(12, 20)), col, false, 1.8)
			ci.draw_line(c + Vector2(-2, 7), c + Vector2(2, 7), col, 1.6)
		"e":
			ci.draw_rect(Rect2(c + Vector2(-7, -10), Vector2(14, 20)), col, false, 1.8)
			ci.draw_arc(c + Vector2(0, 4), 3.5, 0, TAU, 14, col, 1.6, true)
			ci.draw_circle(c + Vector2(0, -5), 1.6, col)
		_:
			ci.draw_rect(Rect2(c + Vector2(-10, -8), Vector2(20, 13)), col, false, 1.8)
			ci.draw_line(c + Vector2(0, 5), c + Vector2(0, 9), col, 1.8)
			ci.draw_line(c + Vector2(-5, 9), c + Vector2(5, 9), col, 1.8)


func _gui_input(ev: InputEvent) -> void:
	if dev_type != "" and ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_LEFT:
		picked.emit()


func _init() -> void:
	custom_minimum_size = Vector2(26, 26)
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	mouse_filter = MOUSE_FILTER_PASS


func _draw() -> void:
	if dev_type != "":
		if selected:
			draw_rect(Rect2(Vector2.ZERO, size), Color("#ffb347"), false, 2.0)
		draw_device(self, size / 2, dev_type, Color("#ffb347") if selected else Color("#7d8497"))
	else:
		draw_icon(self, size / 2, ear, col, off)
