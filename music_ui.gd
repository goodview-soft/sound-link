extends Node
## Carte « Musique » du host : pilote music.py (127.0.0.1:4245).

const API := "http://127.0.0.1:4245/"
var _url: LineEdit
var _pick: OptionButton
var _play: Button
var _status: Label
var _ids: Array = []
var _sig := ""
var _get := HTTPRequest.new()
var _post := HTTPRequest.new()
var _t := 0.0


func build(card: VBoxContainer) -> void:
	add_child(_get)
	add_child(_post)
	_get.timeout = 3.0
	_get.request_completed.connect(_on_state)
	var r := HBoxContainer.new()
	card.add_child(r)
	_url = LineEdit.new()
	_url.placeholder_text = "Lien YouTube"
	_url.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	r.add_child(_url)
	var dl := Button.new()
	dl.text = "Télécharger"
	r.add_child(dl)
	dl.pressed.connect(func() -> void:
		if _url.text.strip_edges() != "":
			_send("url=" + _url.text.strip_edges().uri_encode())
			_url.text = "")
	_pick = OptionButton.new()
	_pick.clip_text = true
	_pick.item_selected.connect(func(i: int) -> void:
		if i >= 0 and i < _ids.size():
			_send("sel=" + str(_ids[i]).uri_encode()))
	card.add_child(_pick)
	_play = Button.new()
	_play.text = "Lancer (F9)"
	_play.pressed.connect(func() -> void: _send("toggle=1"))
	card.add_child(_play)
	for o in [["Écrire les paroles dans le chat du jeu (Entrée, ligne, Entrée)", "write"], ["Maintenir la touche radio (MAJ) pendant la musique", "ptt"], ["Je l'entends aussi sur mes enceintes", "local"]]:
		var c := CheckButton.new()
		c.text = o[0]
		c.button_pressed = true
		c.toggled.connect(func(on: bool) -> void: _send("%s=%d" % [o[1], int(on)]))
		card.add_child(c)
	_status = Label.new()
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.add_theme_color_override("font_color", Color("#8a92a6"))
	card.add_child(_status)


func _send(q: String) -> void:
	var h := HTTPRequest.new()
	add_child(h)
	h.request_completed.connect(func(_a, _b, _c, _d) -> void: h.queue_free())
	h.request("%s?%s" % [API, q], [], HTTPClient.METHOD_POST)


func _process(delta: float) -> void:
	_t -= delta
	if _t <= 0.0 and _get.get_http_client_status() == HTTPClient.STATUS_DISCONNECTED:
		_t = 1.0
		_get.request(API)


func _on_state(result: int, code: int, _h: PackedStringArray, body: PackedByteArray) -> void:
	if result != HTTPRequest.RESULT_SUCCESS or code != 200:
		_status.text = "Moteur musique indisponible (lancer via sound-link.sh)."
		return
	var m = JSON.parse_string(body.get_string_from_utf8())
	if typeof(m) != TYPE_DICTIONARY:
		return
	var tr: Array = m.get("tracks", [])
	var sig := str(tr.size()) + str(m.get("sel", ""))
	if sig != _sig:
		_sig = sig
		_pick.clear()
		_ids.clear()
		for x in tr:
			_pick.add_item(str(x["title"]) + ("" if x.get("lrc", false) else "  (sans paroles)"))
			_ids.append(str(x["id"]))
			if str(x["id"]) == str(m.get("sel", "")):
				_pick.select(_ids.size() - 1)
	_status.text = str(m.get("status", ""))
	_play.text = "Arrêter (F9)" if str(m.get("playing", "")) != "" else "Lancer (F9)"
