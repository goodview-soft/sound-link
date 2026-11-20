extends Control
## Vue « plan technique » : mon appareil en haut, les autres en dessous, reliés par des flèches
## orthogonales animées (qui envoie du son à qui). Toucher un appareil : signal clicked(id).

signal clicked(id: String)

const BG := Color("#0a1830")
const GRID := Color(0.25, 0.5, 0.85, 0.10)
const GRID_BIG := Color(0.25, 0.5, 0.85, 0.22)
const LINE := Color("#4f8fe0")
const DIM := Color("#38558a")
const TEXT := Color("#dbe8ff")
const MUTED := Color("#7f98c4")
const OK := Color("#5eead4")
const AMBER := Color("#ffb347")
const RED := Color("#f87171")
const NW := 176.0
const NH := 70.0
const ROW := 120.0
const TOP := 56.0

var me := {"name": "", "status": "", "ll": 0.0, "lr": 0.0, "state": 0}
var nodes: Array = []  # {id, name, snd, mic, listen, talk, mute, sub, sub_on, sub_lbl}
var selected := ""
var font: Font
var t := 0.0
var rects := {}


func _ready() -> void:
	font = ThemeDB.fallback_font
	mouse_default_cursor_shape = Control.CURSOR_ARROW
	clip_contents = true


func _process(d: float) -> void:
	t += d
	custom_minimum_size.y = TOP + 40.0 + NH + 70.0 + ceilf(nodes.size() / 2.0) * ROW + 30.0
	queue_redraw()


func _gui_input(ev: InputEvent) -> void:
	if ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_LEFT:
		for id in rects:
			if (rects[id] as Rect2).has_point(ev.position):
				clicked.emit(id)
				return
	elif ev is InputEventMouseMotion:
		var over := false
		for id in rects:
			if (rects[id] as Rect2).has_point(ev.position):
				over = true
		mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND if over else Control.CURSOR_ARROW


func _txt(s: String, p: Vector2, size: int, col: Color, w := -1.0, align := HORIZONTAL_ALIGNMENT_LEFT) -> void:
	draw_string(font, p, s, align, w, size, col)


func _dashed_rect(r: Rect2, col: Color, w: float) -> void:
	var a := r.position
	var b := r.position + Vector2(r.size.x, 0)
	var c := r.end
	var d := r.position + Vector2(0, r.size.y)
	for seg in [[a, b], [b, c], [c, d], [d, a]]:
		draw_dashed_line(seg[0], seg[1], col, w, 6.0)


func _corner_ticks(r: Rect2, col: Color) -> void:
	for p in [r.position, r.position + Vector2(r.size.x, 0), r.end, r.position + Vector2(0, r.size.y)]:
		draw_circle(p, 2.5, col)


## Point à la distance dist le long d'une polyligne.
func _along(pts: PackedVector2Array, dist: float) -> Vector2:
	for i in pts.size() - 1:
		var l := pts[i].distance_to(pts[i + 1])
		if dist <= l:
			return pts[i].lerp(pts[i + 1], dist / maxf(l, 0.001))
		dist -= l
	return pts[pts.size() - 1]


func _poly_len(pts: PackedVector2Array) -> float:
	var s := 0.0
	for i in pts.size() - 1:
		s += pts[i].distance_to(pts[i + 1])
	return s


func _edge(pts: PackedVector2Array, col: Color, active: bool, reverse: bool) -> void:
	if not active:
		for i in pts.size() - 1:
			draw_dashed_line(pts[i], pts[i + 1], col, 1.5, 5.0)
	else:
		draw_polyline(pts, col, 2.0, true)
	var total := _poly_len(pts)
	var dots := int(total / 46.0) + 1
	for k in dots:
		var f := fposmod(t * 0.55 + float(k) / dots, 1.0) if active else 0.0
		if not active:
			break
		var dpos := total * (1.0 - f if reverse else f)
		draw_circle(_along(pts, dpos), 3.2, col.lightened(0.35))
	# pointe de flèche à l'extrémité
	var end := pts[0] if reverse else pts[pts.size() - 1]
	var prev := pts[1] if reverse else pts[pts.size() - 2]
	var dir := (end - prev).normalized()
	var n := Vector2(-dir.y, dir.x)
	draw_colored_polygon(PackedVector2Array([end, end - dir * 9 + n * 5, end - dir * 9 - n * 5]), col)


func _draw() -> void:
	rects.clear()
	var W := size.x
	draw_rect(Rect2(Vector2.ZERO, size), BG)
	var x := 0.0
	var i := 0
	while x < W:
		draw_line(Vector2(x, 0), Vector2(x, size.y), GRID_BIG if i % 5 == 0 else GRID, 1.0)
		x += 24.0
		i += 1
	var y := 0.0
	i = 0
	while y < size.y:
		draw_line(Vector2(0, y), Vector2(W, y), GRID_BIG if i % 5 == 0 else GRID, 1.0)
		y += 24.0
		i += 1
	_txt("SCHÉMA RÉSEAU", Vector2(12, 18), 11, DIM)
	var cx := W / 2.0

	# --- Mon appareil
	var mw := 210.0
	var mr := Rect2(cx - mw / 2, TOP, mw, NH + 10)
	var live: bool = me["state"] == 2
	draw_rect(mr, Color(0.06, 0.12, 0.24, 0.9))
	draw_rect(mr, AMBER, false, 2.0)
	_corner_ticks(mr, AMBER)
	_txt("CET APPAREIL", Vector2(mr.position.x + 10, mr.position.y + 15), 10, AMBER)
	_txt(str(me["name"]), Vector2(mr.position.x + 10, mr.position.y + 36), 17, TEXT, mw - 20)
	_txt(str(me["status"]), Vector2(mr.position.x + 10, mr.position.y + 54), 12, OK if live else MUTED, mw - 20)
	for k in 2:
		var lv: float = me["ll"] if k == 0 else me["lr"]
		var by := mr.end.y - 12 + k * 5.0
		draw_rect(Rect2(mr.position.x + 10, by, mw - 20, 3), Color(0.2, 0.3, 0.5, 0.5))
		draw_rect(Rect2(mr.position.x + 10, by, (mw - 20) * clampf(lv, 0, 1), 3), OK)
	rects["__me"] = Rect2()
	var me_bottom := Vector2(cx, mr.end.y)

	if nodes.is_empty():
		_txt("Aucun autre appareil détecté", Vector2(0, mr.end.y + 60), 14, MUTED, W, HORIZONTAL_ALIGNMENT_CENTER)
		return
	_txt("Touchez un appareil pour l'écouter · retouchez pour couper", Vector2(0, size.y - 10), 11, DIM, W, HORIZONTAL_ALIGNMENT_CENTER)

	# --- Appareils (2 colonnes)
	var base_y := mr.end.y + 64.0
	var colx := [cx - NW / 2 - 14.0, cx + NW / 2 + 14.0]
	for n in nodes.size():
		var nd: Dictionary = nodes[n]
		var col: int = n % 2
		var row: int = n / 2
		var nx: float = colx[col]
		var ny := base_y + row * ROW
		var r := Rect2(nx - NW / 2, ny, NW, NH)
		rects[nd["id"]] = r
		var bus_y := ny - 26.0
		# arêtes : bus horizontal -> haut du noeud ; rail vertical dans la gouttière centrale
		var rail := cx
		var items := []
		if nd["listen"]:
			items.append({"off": -6.0, "reverse": true, "act": nd["talk"], "col": RED if nd["mute"] else OK, "lbl": "son" if nd["snd"] else ("micro" if nd["mic"] else ""), "left": true})
		if nd["sub"]:
			items.append({"off": 6.0, "reverse": false, "act": nd["sub_on"], "col": AMBER, "lbl": nd["sub_lbl"], "left": false})
		for e in items:
			var o: float = e["off"]
			var pts := PackedVector2Array([Vector2(rail + o, me_bottom.y), Vector2(rail + o, bus_y + o * 0.5), Vector2(nx + o * 1.5, bus_y + o * 0.5), Vector2(nx + o * 1.5, ny)])
			_edge(pts, e["col"] if e["act"] else DIM.lightened(0.15), e["act"], e["reverse"])
			if e["lbl"] != "":
				var lx: float = nx + o * 1.5 + (-8.0 if e["left"] else 8.0)
				_txt(e["lbl"], Vector2(lx - (font.get_string_size(e["lbl"], HORIZONTAL_ALIGNMENT_LEFT, -1, 10).x if e["left"] else 0.0), ny - 6 + (0 if e["left"] else 0)), 10, e["col"])
		# noeud
		var linked: bool = nd["listen"] or nd["sub"]
		draw_rect(r, Color(0.06, 0.12, 0.24, 0.9) if linked else Color(0.05, 0.1, 0.2, 0.55))
		var bc: Color = AMBER if selected == nd["id"] else (LINE if linked else DIM)
		if linked:
			draw_rect(r, bc, false, 2.0 if selected == nd["id"] else 1.5)
		else:
			_dashed_rect(r, bc, 1.5)
		_corner_ticks(r, bc)
		_txt(str(nd["name"]), Vector2(r.position.x + 10, r.position.y + 24), 15, TEXT if linked else MUTED, NW - 20)
		var what: PackedStringArray = []
		if nd["snd"]:
			what.append("son")
		if nd["mic"]:
			what.append("micro")
		_txt("partage : " + (", ".join(what) if not what.is_empty() else "rien"), Vector2(r.position.x + 10, r.position.y + 42), 11, MUTED, NW - 20)
		var st := "écouté" if nd["listen"] else ("vous écoute" if nd["sub"] else "toucher pour écouter")
		if nd["listen"] and nd["sub"]:
			st = "échange"
		_txt(st, Vector2(r.position.x + 10, r.position.y + 60), 11, OK if (nd["talk"] or nd["sub_on"]) else DIM)
		if nd["listen"] and nd["mute"]:
			_txt("MUET", Vector2(r.end.x - 44, r.position.y + 60), 10, RED)
