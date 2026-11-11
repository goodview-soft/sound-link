class_name HostPage
extends VBoxContainer
## Page Host : partage d'une fenêtre (X11) avec aperçu dans l'appli.
## La capture est faite par share.py (ffmpeg), lancé par sound-link.sh ou, à défaut, par l'appli.

const API_PORT := 4245
const FRAME_PORT := 4246
const QUALITIES := [480, 720, 1080]
const CFG := "user://regions.cfg"
const HINT := "Les clients pourront voir cette fenêtre."

var _view := HTTPRequest.new()
var _win: OptionButton
var _ids: Array[String] = []
var _share: Button
var _status: Label
var _quality := 1
var _preview: RegionPreview
var _pick_lbl: Label
var _players_box: VBoxContainer
var _chat_box: VBoxContainer
var _chat_scroll: ScrollContainer
var _chat_sig := ""
var _ocr_t := 0.0
var _cfg := ConfigFile.new()
var _overlay: Overlay
var _ov_on := false
var _ov_primed := false
var _ov_done := {}
var _tex: ImageTexture
var _sharing := false
var _busy := false
var _seq := -1
var _retry := 0.0
var _pid := -1


func _ready() -> void:
	add_theme_constant_override("separation", 16)
	_view.timeout = 6.0
	add_child(_view)
	_view.request_completed.connect(_on_frame)

	var c := Ui.card(self, "Partager une fenêtre")
	var r1 := HBoxContainer.new()
	r1.add_theme_constant_override("separation", 8)
	c.add_child(r1)
	_win = OptionButton.new()
	_win.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_win.clip_text = true
	r1.add_child(_win)
	Ui.icon_btn("refresh", r1).pressed.connect(refresh)
	var r2 := HBoxContainer.new()
	r2.add_theme_constant_override("separation", 8)
	c.add_child(r2)
	_share = Ui.button("Partager", r2)
	_share.theme_type_variation = "Toggle"
	_share.toggle_mode = true
	_share.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_share.toggled.connect(func(on: bool) -> void: _start() if on else stop())
	var q := OptionButton.new()
	for h in QUALITIES:
		q.add_item("%dp" % h)
	q.select(_quality)
	q.item_selected.connect(func(i: int) -> void: _quality = i)
	r2.add_child(q)
	_status = Ui.hint(HINT, c)

	var p := Ui.card(self, "Aperçu")
	_preview = RegionPreview.new()
	_preview.custom_minimum_size = Vector2(0, 220)
	_preview.mouse_default_cursor_shape = Control.CURSOR_CROSS
	_preview.region_set.connect(_on_region)
	p.add_child(_preview)
	var rb := HBoxContainer.new()
	rb.add_theme_constant_override("separation", 8)
	p.add_child(rb)
	for kind in ["players", "chat"]:
		var b := Ui.button("Cadre joueurs" if kind == "players" else "Cadre chat", rb)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.pressed.connect(func() -> void:
			_preview.pick = kind
			_pick_lbl.text = "Trace un rectangle sur l'aperçu (%s)." % ("noms des joueurs qui parlent" if kind == "players" else "chat du jeu"))
	Ui.icon_btn("refresh", rb).pressed.connect(func() -> void:
		_preview.regions = {"players": Rect2(), "chat": Rect2()}
		_preview.queue_redraw()
		_save_regions()
		_send_regions(true))
	_pick_lbl = Ui.hint("Choisis un cadre puis trace-le sur l'aperçu. Qualité 1080p conseillée pour lire le texte.", p)

	var pc := Ui.card(self, "Joueurs qui parlent")
	_players_box = VBoxContainer.new()
	_players_box.add_theme_constant_override("separation", 4)
	pc.add_child(_players_box)
	var cc := Ui.card(self, "Chat récupéré")
	var ob := Ui.button("Traduction en jeu (overlay haut droite)", cc)
	ob.theme_type_variation = "Toggle"
	ob.toggle_mode = true
	ob.tooltip_text = "Affiche les messages traduits en français par-dessus le jeu"
	ob.toggled.connect(func(on: bool) -> void:
		_ov_on = on
		_ov_primed = false
		if on and _overlay == null:
			_overlay = Overlay.new()
			add_child(_overlay)
			_overlay.push("Sound Link", "en", "Overlay active", "Overlay actif : les messages traduits s'afficheront ici.")
		elif not on and _overlay:
			_overlay.queue_free()
			_overlay = null)
	_chat_scroll = ScrollContainer.new()
	_chat_scroll.custom_minimum_size = Vector2(0, 260)
	_chat_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	cc.add_child(_chat_scroll)
	_chat_box = VBoxContainer.new()
	_chat_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_chat_box.add_theme_constant_override("separation", 4)
	_chat_scroll.add_child(_chat_box)
	_load_regions()
	_spawn_engine()
	refresh()


func _process(_delta: float) -> void:
	var now := Time.get_ticks_msec() / 1000.0
	if _sharing and not _busy and now >= _retry:
		_busy = true
		_view.request("http://127.0.0.1:%d/?after=%d" % [FRAME_PORT, _seq])
	if _sharing and now >= _ocr_t:
		_ocr_t = now + 1.0
		_call("/ocr", HTTPClient.METHOD_GET, _on_ocr)


## Lance share.py nous-mêmes sauf dans flatpak, où sound-link.sh l'a déjà démarré hors du bac à sable.
func _spawn_engine() -> void:
	if FileAccess.file_exists("/.flatpak-info") or OS.has_feature("mobile"):
		return
	var src := FileAccess.open("res://share.py", FileAccess.READ)
	if src == null:
		return
	var dst := FileAccess.open("user://share.py", FileAccess.WRITE)
	dst.store_string(src.get_as_text())
	dst.close()
	_pid = OS.create_process("python3", [OS.get_user_data_dir().path_join("share.py"), str(API_PORT)])


## Appel à l'API locale de share.py (requête jetable).
func _call(path: String, method := HTTPClient.METHOD_GET, done := Callable()) -> void:
	var h := HTTPRequest.new()
	h.timeout = 5.0
	add_child(h)
	h.request_completed.connect(func(res: int, code: int, _hd: PackedStringArray, body: PackedByteArray) -> void:
		h.queue_free()
		if done.is_valid():
			done.call(res == HTTPRequest.RESULT_SUCCESS and code == 200, body))
	h.request("http://127.0.0.1:%d%s" % [API_PORT, path], PackedStringArray(), method, "")


func refresh() -> void:
	_call("/windows", HTTPClient.METHOD_GET, func(ok: bool, body: PackedByteArray) -> void:
		var list: Variant = JSON.parse_string(body.get_string_from_utf8()) if ok else null
		if not (list is Array):
			_status.text = "Moteur de capture indisponible : lance l'appli avec sound-link.sh."
			return
		_win.clear()
		_ids.clear()
		for w in list:
			_win.add_item(str(w["title"]))
			_ids.append(str(w["id"]))
		_status.text = HINT if not _ids.is_empty() else "Aucune fenêtre trouvée.")


func _start() -> void:
	if _win.selected < 0 or _win.selected >= _ids.size():
		_share.set_pressed_no_signal(false)
		refresh()
		return
	var title := _win.get_item_text(_win.selected)
	_call("/share?win=%s&h=%d" % [_ids[_win.selected], QUALITIES[_quality]], HTTPClient.METHOD_POST,
		func(ok: bool, _b: PackedByteArray) -> void:
			if not ok:
				_sharing = false
				_share.set_pressed_no_signal(false)
				_status.text = "Moteur de capture indisponible.")
	_status.text = "● Partage de « %s »" % title
	_send_regions(false)
	_seq = -1
	_retry = 0.0
	_sharing = true


func stop() -> void:
	if _sharing:
		_sharing = false
		_view.cancel_request()
		_busy = false
		_call("/share?stop=1", HTTPClient.METHOD_POST)
	_share.set_pressed_no_signal(false)
	_status.text = HINT
	_preview.texture = null
	_preview.queue_redraw()
	_tex = null


func _on_frame(res: int, code: int, hdrs: PackedStringArray, body: PackedByteArray) -> void:
	_busy = false
	if not _sharing:
		return
	if res != HTTPRequest.RESULT_SUCCESS or code == 404:
		_retry = Time.get_ticks_msec() / 1000.0 + 1.0  # le moteur démarre encore : on réessaie
		_seq = -1
		return
	for hd in hdrs:
		if hd.to_lower().begins_with("x-seq:"):
			_seq = int(hd.get_slice(":", 1).strip_edges())
	if code != 200 or body.is_empty():
		return
	var img := Image.new()
	if img.load_jpg_from_buffer(body) != OK:
		return
	if _tex == null or _tex.get_size() != Vector2(img.get_size()):
		_tex = ImageTexture.create_from_image(img)
		_preview.texture = _tex
	else:
		_tex.update(img)
	_preview.queue_redraw()
	_preview.custom_minimum_size.y = clampf(_preview.size.x * img.get_height() / maxf(img.get_width(), 1.0), 120.0, 700.0)


func _on_region(_kind: String, _r: Rect2) -> void:
	_pick_lbl.text = "Cadre enregistré."
	_save_regions()
	_send_regions(false)


func _save_regions() -> void:
	for k in _preview.regions:
		_cfg.set_value("regions", k, _preview.regions[k])
	_cfg.save(CFG)


func _load_regions() -> void:
	if _cfg.load(CFG) == OK:
		for k in _preview.regions:
			_preview.regions[k] = _cfg.get_value("regions", k, Rect2())


func _send_regions(clear: bool) -> void:
	var q := ""
	for k in _preview.regions:
		var r: Rect2 = _preview.regions[k]
		q += "&%s=%s" % [k, ("%f,%f,%f,%f" % [r.position.x, r.position.y, r.size.x, r.size.y]) if r.size.x > 0.0 else ""]
	_call("/regions?x=1%s%s" % [q, "&clear=1" if clear else ""], HTTPClient.METHOD_POST)


func _on_ocr(ok: bool, body: PackedByteArray) -> void:
	var j: Variant = JSON.parse_string(body.get_string_from_utf8()) if ok else null
	if not (j is Dictionary):
		return
	for ch in _players_box.get_children():
		ch.queue_free()
	var speaking: Array = j.get("speaking", [])
	for name in j.get("players", []):
		var on: bool = name in speaking
		var l := Ui.label(("● " if on else "○ ") + str(name), _players_box)
		l.add_theme_color_override("font_color", Ui.C_OK if on else Ui.C_MUTED)
	if _players_box.get_child_count() == 0:
		Ui.hint("Aucun joueur détecté (trace le cadre « joueurs »).", _players_box)
	var lines: Array = j.get("chat", [])
	_overlay_feed(lines)
	var tr_n := 0
	for m in lines:
		if str(m.get("tr", "")) != "":
			tr_n += 1
	var sig := "%d:%s:%d" % [lines.size(), str(lines[-1]["id"]) if not lines.is_empty() else "", tr_n]
	if sig == _chat_sig:
		return
	_chat_sig = sig
	for ch in _chat_box.get_children():
		ch.queue_free()
	for m in lines:
		var r := RichTextLabel.new()
		r.bbcode_enabled = true
		r.fit_content = true
		r.scroll_active = false
		r.add_theme_font_size_override("normal_font_size", 14)
		r.add_theme_font_size_override("bold_font_size", 14)
		var who := str(m.get("name", ""))
		var t := ""
		if who != "":
			t = "[color=#22d3ee][b]%s[/b][/color]  " % _bb(who)
		t += _bb(str(m.get("msg", "")))
		if str(m.get("tr", "")) != "":
			t += "\n[color=#7c6cff]→ %s[/color]" % _bb(str(m["tr"]))
		r.text = t
		_chat_box.add_child(r)
	if lines.is_empty():
		Ui.hint("Rien pour l'instant (trace le cadre « chat »).", _chat_box)
	await get_tree().process_frame
	_chat_scroll.scroll_vertical = int(_chat_scroll.get_v_scroll_bar().max_value)


func _bb(t: String) -> String:
	return t.replace("[", "[lb]")


## Envoie à l'overlay les nouveaux messages une fois traduits (les messages déjà là à l'activation sont ignorés).
func _overlay_feed(lines: Array) -> void:
	if not _ov_on or _overlay == null:
		return
	for m in lines:
		var id := int(m["id"])
		if _ov_done.has(id):
			continue
		if not _ov_primed:
			_ov_done[id] = true
		elif str(m.get("tr", "")) != "":
			_ov_done[id] = true
			_overlay.push(str(m.get("name", "")), str(m.get("lang", "")), str(m.get("msg", "")), str(m["tr"]))
		elif m.get("done", false):
			_ov_done[id] = true  # déjà en français ou non traduisible
	_ov_primed = true


func _exit_tree() -> void:
	stop()
	if _pid > 0:
		OS.kill(_pid)
