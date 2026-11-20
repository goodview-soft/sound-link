extends Control
const DevIcon := preload("res://dev_icon.gd")
## Vue « plan technique » : mon appareil en haut, les autres en dessous, reliés par des flèches
## orthogonales animées (qui envoie du son à qui). Toucher un appareil : signal clicked(id).

signal clicked(id: String)
signal link(id: String, kind: String)  # glisser un câble : kind "in" (j'écoute id) ou "out" (id m'écoute)
signal unlink(id: String, kind: String)
signal share(kind: String, on: bool)  # son / micro posés sur le câble

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
const ROW := 132.0
const TOP := 56.0

var me := {"name": "", "status": "", "ll": 0.0, "lr": 0.0, "state": 0, "cap": "", "can_snd": true, "type": "c"}
var nodes: Array = []  # {id, name, snd, mic, listen, talk, mute, sub, sub_on, sub_lbl}
var selected := ""
var font: Font
var t := 0.0
var rects := {}
var ports: Array = []  # {id, kind, pos}
var btns: Array = []  # {rect, act, id, kind}
var drag := {}
var cables: Array = []  # {id, kind, pts}
var hover := {}
var spec := PackedFloat32Array()
var spec_show := PackedFloat32Array()
var spec_peak := PackedFloat32Array()
var mpos := Vector2.ZERO


func _ready() -> void:
	font = ThemeDB.fallback_font
	mouse_default_cursor_shape = Control.CURSOR_ARROW
	clip_contents = true


func _process(d: float) -> void:
	t += d
	custom_minimum_size.y = TOP + 40.0 + NH + 70.0 + ceilf(nodes.size() / 2.0) * ROW + 30.0
	queue_redraw()


func _port_at(p: Vector2, r := 11.0) -> Dictionary:
	for pt in ports:
		if (pt["pos"] as Vector2).distance_to(p) <= r:
			return pt
	return {}


func _gui_input(ev: InputEvent) -> void:
	if ev is InputEventMouseButton and ev.button_index == MOUSE_BUTTON_LEFT:
		if ev.pressed:
			for bt in btns:
				if (bt["rect"] as Rect2).has_point(ev.position):
					if bt["act"] == "share":
						share.emit(bt["kind"], me["cap"] != bt["kind"])
					else:
						unlink.emit(bt["id"], bt["kind"])
					return
			var pt := _port_at(ev.position)
			if not pt.is_empty() and not pt["used"]:
				drag = {"id": pt["id"], "kind": pt["kind"]}
				mpos = ev.position
				return
			for id in rects:
				if (rects[id] as Rect2).has_point(ev.position):
					clicked.emit(id)
					return
		elif not drag.is_empty():
			var tgt := _port_at(ev.position, 16.0)
			if not tgt.is_empty() and tgt["kind"] == drag["kind"] and tgt["id"] != drag["id"] and not tgt["used"] \
					and (tgt["id"] == "__me" or drag["id"] == "__me"):
				link.emit(drag["id"] if drag["id"] != "__me" else tgt["id"], drag["kind"])
			drag = {}
	elif ev is InputEventMouseMotion:
		mpos = ev.position
		var over := not _port_at(ev.position).is_empty()
		for bt in btns:
			if (bt["rect"] as Rect2).has_point(ev.position):
				over = true
		for id in rects:
			if (rects[id] as Rect2).has_point(ev.position):
				over = true
		mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND if over else Control.CURSOR_ARROW
		hover = {}
		if drag.is_empty() and not over:
			for cb in cables:
				var pts: PackedVector2Array = cb["pts"]
				for i in pts.size() - 1:
					var cp := Geometry2D.get_closest_point_to_segment(ev.position, pts[i], pts[i + 1])
					if cp.distance_to(ev.position) < 9.0:
						hover = {"id": cb["id"], "kind": cb["kind"]}


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


## Visage 2D : oreilles (ondes quand ça écoute) et bouche (s'ouvre quand ça parle).
func _face(c: Vector2, talk: bool, amp: float, hearing: bool, muted: bool, col: Color) -> void:
	var r := 17.0
	draw_circle(c, r, Color(0.08, 0.16, 0.32))
	draw_arc(c, r, 0, TAU, 32, col, 1.8, true)
	for sd in [-1.0, 1.0]:
		var ec := c + Vector2(sd * (r + 3), 1)
		draw_arc(ec, 5.5, 0, TAU, 14, col, 1.6, true)
		if hearing:
			for k in 2:
				var ph := fposmod(t * 1.6 + k * 0.5, 1.0)
				var rr := 8.0 + ph * 8.0
				var a0 := 0.0 if sd > 0 else PI
				draw_arc(ec, rr, a0 - 0.8, a0 + 0.8, 10, Color(col, 1.0 - ph), 1.6, true)
	var blink := fposmod(t, 3.4) > 3.25
	for sd in [-1.0, 1.0]:
		var ep := c + Vector2(sd * 6.5, -4)
		if blink:
			draw_line(ep + Vector2(-2, 0), ep + Vector2(2, 0), col, 1.5)
		else:
			draw_circle(ep, 2.0, TEXT)
	var mp := c + Vector2(0, 8)
	if talk:
		var h := 1.5 + amp * 5.5
		draw_set_transform(mp, 0, Vector2(1.0, h / 4.0))
		draw_circle(Vector2.ZERO, 4.0, col)
		draw_set_transform(Vector2.ZERO)
	else:
		draw_line(mp + Vector2(-4, 0), mp + Vector2(4, 0), col, 1.8, true)
	if muted:
		draw_line(mp + Vector2(-6, 5), mp + Vector2(6, -5), RED, 2.2, true)


func _pill(r: Rect2, label: String, on: bool, col: Color) -> void:
	draw_rect(r, col.darkened(0.55) if on else BG)
	draw_rect(r, col if on else DIM, false, 1.5)
	var fs := font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, 11)
	_txt(label, Vector2(r.position.x + (r.size.x - fs.x) / 2, r.position.y + 13), 11, TEXT if on else MUTED)


func _port(id: String, kind: String, pos: Vector2, used: bool) -> void:
	var col := OK if kind == "in" else AMBER
	ports.append({"id": id, "kind": kind, "pos": pos, "used": used})
	draw_circle(pos, 7.0, BG)
	if used:
		draw_circle(pos, 4.5, col)
	else:
		draw_arc(pos, 6.0, 0, TAU, 20, col, 1.8, true)
	if not drag.is_empty() and drag["kind"] == kind and drag["id"] != id and not used and (id == "__me" or drag["id"] == "__me"):
		draw_arc(pos, 9.0 + sin(t * 8.0) * 2.0, 0, TAU, 24, col, 2.0, true)


func _x_btn(c: Vector2, id: String, kind: String) -> void:
	draw_circle(c, 8.0, BG)
	draw_arc(c, 8.0, 0, TAU, 16, RED, 1.5, true)
	draw_line(c + Vector2(-3, -3), c + Vector2(3, 3), RED, 1.5, true)
	draw_line(c + Vector2(-3, 3), c + Vector2(3, -3), RED, 1.5, true)
	btns.append({"rect": Rect2(c - Vector2(9, 9), Vector2(18, 18)), "act": "unlink", "id": id, "kind": kind})


func _draw() -> void:
	rects.clear()
	ports.clear()
	btns.clear()
	cables.clear()
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
	var lvl := (float(me["ll"]) + float(me["lr"])) * 0.5
	var me_talk: bool = me["cap"] != ""
	var me_hear := false
	for nd in nodes:
		me_hear = me_hear or (nd["listen"] and nd["talk"])
	_face(Vector2(mr.position.x + 38, mr.position.y + 38), me_talk, clampf(lvl * 1.5, 0.15, 1.0) if me_talk else 0.0, me_hear, false, AMBER)
	DevIcon.draw_device(self, Vector2(mr.end.x - 18, mr.position.y + 20), me["type"], AMBER)
	_txt("CET APPAREIL", Vector2(mr.position.x + 74, mr.position.y + 15), 10, AMBER)
	_txt(str(me["name"]), Vector2(mr.position.x + 74, mr.position.y + 36), 15, TEXT, mw - 110)
	_txt(str(me["status"]), Vector2(mr.position.x + 74, mr.position.y + 54), 11, OK if live else MUTED, mw - 84)
	for k in 2:
		var lv: float = me["ll"] if k == 0 else me["lr"]
		var by := mr.end.y - 12 + k * 5.0
		draw_rect(Rect2(mr.position.x + 74, by, mw - 84, 3), Color(0.2, 0.3, 0.5, 0.5))
		draw_rect(Rect2(mr.position.x + 74, by, (mw - 84) * clampf(lv, 0, 1), 3), OK)
	var any_in := false
	var any_out := false
	for nd in nodes:
		any_in = any_in or nd["listen"]
		any_out = any_out or nd["sub"] or nd["invited"]
	var me_in := Vector2(cx - 12, mr.end.y)
	var me_out := Vector2(cx + 12, mr.end.y)

	if nodes.is_empty():
		_txt("Aucun autre appareil détecté", Vector2(0, mr.end.y + 60), 14, MUTED, W, HORIZONTAL_ALIGNMENT_CENTER)
		return
	_txt("Tirez un câble depuis un point ○ vers le même point de l'autre appareil", Vector2(0, size.y - 10), 11, DIM, W, HORIZONTAL_ALIGNMENT_CENTER)

	# --- Appareils (2 colonnes)
	var base_y := mr.end.y + 70.0
	var colx := [cx - NW / 2 - 22.0, cx + NW / 2 + 22.0]
	for n in nodes.size():
		var nd: Dictionary = nodes[n]
		var col: int = n % 2
		var row: int = n / 2
		var nx: float = colx[col]
		var ny := base_y + row * ROW
		var r := Rect2(nx - NW / 2, ny, NW, NH)
		rects[nd["id"]] = r
		var gy := ny - 38.0
		var ay := ny - 18.0
		var p_in := Vector2(nx - 12, ny)   # il m'envoie (vert)
		var p_out := Vector2(nx + 12, ny)  # je lui envoie (ambre)
		var can_link: bool = not str(nd["id"]).begins_with("sub:")
		if nd["listen"]:
			var pts := PackedVector2Array([me_in, Vector2(me_in.x, gy), Vector2(p_in.x, gy), p_in])
			_edge(pts, RED if nd["mute"] else OK, nd["talk"], true)
			cables.append({"id": nd["id"], "kind": "in", "pts": pts})
			if hover.get("id", "") == nd["id"] and hover.get("kind", "") == "in":
				draw_polyline(pts, Color(1, 1, 1, 0.35), 5.0, true)
			var lbl: String = "son" if nd["snd"] else ("micro" if nd["mic"] else "")
			if lbl != "":
				_txt(lbl, Vector2((me_in.x + p_in.x) / 2 - 10, gy - 5), 10, OK)
			_x_btn(Vector2(p_in.x, ny - 10), nd["id"], "in")
		if nd["sub"] or nd["invited"]:
			var pts2 := PackedVector2Array([me_out, Vector2(me_out.x, ay), Vector2(p_out.x, ay), p_out])
			_edge(pts2, AMBER if nd["sub"] else DIM.lightened(0.2), nd["sub_on"], false)
			cables.append({"id": nd["id"], "kind": "out", "pts": pts2})
			if hover.get("id", "") == nd["id"] and hover.get("kind", "") == "out":
				draw_polyline(pts2, Color(1, 1, 1, 0.35), 5.0, true)
			var mid := (me_out.x + p_out.x) / 2
			var pw := 42.0
			var tot := pw * 2 + 4.0 if me["can_snd"] else pw
			var px := mid - tot / 2
			if me["can_snd"]:
				var rs := Rect2(px, ay - 9, pw, 18)
				_pill(rs, "SON", me["cap"] == "snd", AMBER)
				btns.append({"rect": rs, "act": "share", "kind": "snd", "id": ""})
				px += pw + 4.0
			var rm := Rect2(px, ay - 9, pw, 18)
			_pill(rm, "MIC", me["cap"] == "mic", AMBER)
			btns.append({"rect": rm, "act": "share", "kind": "mic", "id": ""})
			if can_link:
				_x_btn(Vector2(p_out.x, ny - 10), nd["id"], "out")
		if can_link:
			_port(nd["id"], "in", p_in, nd["listen"])
			_port(nd["id"], "out", p_out, nd["sub"] or nd["invited"])
		# noeud
		var linked: bool = nd["listen"] or nd["sub"] or nd["invited"]
		draw_rect(r, Color(0.06, 0.12, 0.24, 0.9) if linked else Color(0.05, 0.1, 0.2, 0.55), true)
		var bc: Color = AMBER if selected == nd["id"] else (LINE if linked else DIM)
		if linked:
			draw_rect(r, bc, false, 2.0 if selected == nd["id"] else 1.5)
		else:
			_dashed_rect(r, bc, 1.5)
		_corner_ticks(r, bc)
		var fcol: Color = TEXT if linked else DIM
		var amp := absf(sin(t * 13.0 + n * 1.7)) * 0.7 + 0.3
		_face(Vector2(r.position.x + 34, r.position.y + 36), nd["talk"], amp, nd["sub_on"], nd["listen"] and nd["mute"], OK if nd["talk"] else (fcol if linked else DIM))
		DevIcon.draw_device(self, Vector2(r.end.x - 15, r.position.y + 17), nd["type"], MUTED if linked else DIM)
		_txt(str(nd["name"]), Vector2(r.position.x + 66, r.position.y + 28), 14, TEXT if linked else MUTED, NW - 100)
		var what: PackedStringArray = []
		if nd["snd"]:
			what.append("son")
		if nd["mic"]:
			what.append("micro")
		_txt("partage : " + (", ".join(what) if not what.is_empty() else "rien"), Vector2(r.position.x + 66, r.position.y + 46), 10, MUTED, NW - 76)
		var st := "vous écoute" if nd["sub"] else ("invité…" if nd["invited"] else "")
		if nd["listen"]:
			st = "échange" if nd["sub"] else "écouté"
		if nd["listen"] and nd["mute"]:
			st += " · MUET"
		_txt(st, Vector2(r.position.x + 66, r.position.y + 63), 10, OK if (nd["talk"] or nd["sub_on"]) else DIM, NW - 76)

	_port("__me", "in", me_in, any_in)
	_port("__me", "out", me_out, any_out)
	if not drag.is_empty():
		var from := Vector2.ZERO
		for pt in ports:
			if pt["id"] == drag["id"] and pt["kind"] == drag["kind"]:
				from = pt["pos"]
		var dc := OK if drag["kind"] == "in" else AMBER
		draw_dashed_line(from, mpos, dc, 2.0, 6.0)
		draw_circle(mpos, 4.0, dc)
	if not hover.is_empty() and drag.is_empty():
		_spectrum_tip(nodes)


func _spectrum_tip(list: Array) -> void:
	var nm := ""
	for nd in list:
		if nd["id"] == hover["id"]:
			nm = nd["name"]
	var title := ("%s → moi" % nm) if hover["kind"] == "in" else ("moi → %s" % nm)
	var col := OK if hover["kind"] == "in" else AMBER
	var nb := 28
	if spec_show.size() != nb:
		spec_show.resize(nb)
		spec_peak.resize(nb)
	for i in nb:
		var v := spec[i] if spec.size() == nb else 0.0
		spec_show[i] = lerpf(spec_show[i], v, 0.5)
		spec_peak[i] = maxf(spec_show[i], spec_peak[i] - 0.015)
	var w := 232.0
	var h := 112.0
	var pos := Vector2(clampf(mpos.x + 16, 4, size.x - w - 4), clampf(mpos.y + 16, 4, size.y - h - 4))
	var r := Rect2(pos, Vector2(w, h))
	draw_rect(r, Color(0.04, 0.09, 0.19, 0.96))
	draw_rect(r, col, false, 1.5)
	_txt(title, pos + Vector2(10, 18), 12, TEXT, w - 20)
	var bx := pos.x + 10
	var bw := (w - 20) / nb
	var base := pos.y + h - 20
	var hh := h - 54
	for i in nb:
		var bh := spec_show[i] * hh
		draw_rect(Rect2(bx + i * bw, base - bh, maxf(bw - 1.5, 1.0), bh), col.lerp(Color.WHITE, spec_show[i] * 0.3))
		draw_rect(Rect2(bx + i * bw, base - spec_peak[i] * hh - 2, maxf(bw - 1.5, 1.0), 1.5), TEXT)
	draw_line(Vector2(bx, base + 1), Vector2(pos.x + w - 10, base + 1), DIM, 1.0)
	_txt("60 Hz", Vector2(bx, pos.y + h - 6), 9, MUTED)
	_txt("1 kHz", Vector2(bx + (w - 20) * 0.5 - 12, pos.y + h - 6), 9, MUTED)
	_txt("10 kHz", Vector2(pos.x + w - 40, pos.y + h - 6), 9, MUTED)
	if spec.is_empty():
		_txt("aucun signal", Vector2(pos.x, pos.y + h / 2 + 6), 12, MUTED, w, HORIZONTAL_ALIGNMENT_CENTER)
