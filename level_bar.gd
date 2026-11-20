extends Control
## Barre de niveau lissée (0..1) avec pic qui retombe.

var value := 0.0
var shown := 0.0
var peak := 0.0
var col := Color("#5eead4")


func _init() -> void:
	custom_minimum_size.y = 8
	size_flags_horizontal = SIZE_EXPAND_FILL
	size_flags_vertical = SIZE_SHRINK_CENTER
	mouse_filter = MOUSE_FILTER_IGNORE


func _process(d: float) -> void:
	shown = lerpf(shown, value, minf(1.0, d * 14.0))
	peak = maxf(shown, peak - d * 0.6)
	queue_redraw()


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color("#1b2030"))
	draw_rect(Rect2(0, 0, size.x * clampf(shown, 0.0, 1.0), size.y), col)
	draw_rect(Rect2(size.x * clampf(peak, 0.0, 1.0) - 2, 0, 2, size.y), Color("#e7eaf0"))
