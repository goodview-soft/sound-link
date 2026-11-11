class_name AppIcon
extends Control
## Pictogrammes vectoriels dessinés sur une grille 24×24.
var kind := ""
var color := Color("#e7eaf0")
var scale_f := 1.0
var _o := Vector2.ZERO
var _u := 1.0

func _init(k: String, sz := 22.0, c := Color("#e7eaf0")) -> void:
	kind = k
	color = c
	if sz > 0:
		custom_minimum_size = Vector2(sz, sz)
	mouse_filter = MOUSE_FILTER_IGNORE
	size_flags_vertical = SIZE_SHRINK_CENTER

func set_kind(k: String, c := Color(0, 0, 0, 0)) -> void:
	kind = k
	if c.a > 0:
		color = c
	queue_redraw()

func _p(x: float, y: float) -> Vector2:
	return _o + Vector2(x, y) * _u

func _line(pts: Array, w: float) -> void:
	var v := PackedVector2Array()
	for q in pts:
		v.append(_p(q.x, q.y))
	draw_polyline(v, color, w, true)

func _draw() -> void:
	var sz := minf(size.x, size.y) * scale_f
	_o = (size - Vector2(sz, sz)) / 2.0
	_u = sz / 24.0
	var w := maxf(1.5, 2.0 * _u)
	var c := color
	match kind:
		"back":
			_line([Vector2(15, 5), Vector2(8, 12), Vector2(15, 19)], w)
		"play":
			draw_colored_polygon(PackedVector2Array([_p(8, 5), _p(19, 12), _p(8, 19)]), c)
		"stop":
			draw_rect(Rect2(_p(7, 7), Vector2(10, 10) * _u), c)
		"speaker", "speaker_off":
			draw_colored_polygon(PackedVector2Array([_p(3, 9), _p(7, 9), _p(12, 5), _p(12, 19), _p(7, 15), _p(3, 15)]), c)
			if kind == "speaker":
				draw_arc(_p(12, 12), 4.5 * _u, -0.9, 0.9, 12, c, w, true)
				draw_arc(_p(12, 12), 8.5 * _u, -0.9, 0.9, 16, c, w, true)
			else:
				_line([Vector2(15, 9), Vector2(21, 15)], w)
				_line([Vector2(21, 9), Vector2(15, 15)], w)
		"mic", "mic_off":
			draw_circle(_p(12, 7), 3.5 * _u, c)
			draw_rect(Rect2(_p(8.5, 7), Vector2(7, 5) * _u), c)
			draw_circle(_p(12, 12), 3.5 * _u, c)
			draw_arc(_p(12, 11), 6.5 * _u, 0.0, PI, 16, c, w, true)
			_line([Vector2(12, 17.5), Vector2(12, 21)], w)
			_line([Vector2(8.5, 21), Vector2(15.5, 21)], w)
			if kind == "mic_off":
				draw_line(_p(4, 3), _p(20, 21), Color("#0e1015"), w * 2.2, true)
				draw_line(_p(4, 3), _p(20, 21), c, w, true)
		"broadcast":
			draw_circle(_p(12, 12), 2.6 * _u, c)
			for r in [5.5, 9.5]:
				draw_arc(_p(12, 12), r * _u, -0.75, 0.75, 14, c, w, true)
				draw_arc(_p(12, 12), r * _u, PI - 0.75, PI + 0.75, 14, c, w, true)
		"headphones":
			draw_arc(_p(12, 13), 8.5 * _u, PI, TAU, 24, c, w, true)
			draw_rect(Rect2(_p(2.5, 13), Vector2(4.5, 7.5) * _u), c)
			draw_rect(Rect2(_p(17, 13), Vector2(4.5, 7.5) * _u), c)
		"qr":
			for q in [Vector2(3, 3), Vector2(14, 3), Vector2(3, 14)]:
				draw_rect(Rect2(_p(q.x, q.y), Vector2(7, 7) * _u), c, false, w)
				draw_rect(Rect2(_p(q.x + 2.5, q.y + 2.5), Vector2(2, 2) * _u), c)
			draw_rect(Rect2(_p(14, 14), Vector2(3, 3) * _u), c)
			draw_rect(Rect2(_p(18, 18), Vector2(3, 3) * _u), c)
		"folder":
			var pts := PackedVector2Array([_p(3, 6), _p(9, 6), _p(11, 8), _p(21, 8), _p(21, 19), _p(3, 19)])
			pts.append(pts[0])
			draw_polyline(pts, c, w, true)
		"refresh":
			draw_arc(_p(12, 12), 7 * _u, -0.3, PI * 1.55, 24, c, w, true)
			draw_colored_polygon(PackedVector2Array([_p(19.5, 6), _p(20, 12), _p(14.5, 10)]), c)
