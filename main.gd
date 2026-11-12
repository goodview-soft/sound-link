extends Control
## Sound Link : le host capture une source audio (ex. « Monitor of ... » = sortie du PC)
## et l'envoie en UDP (PCM 16 bits stéréo) aux clients, qui règlent volume et balance.
## Un client (ex. téléphone) peut renvoyer son micro (PCM 16 bits mono, préfixe "MIC1") :
## le host le joue dans le micro virtuel « Sound-Link-Micro » créé par sound-link.sh.

const PORT := 4242
const FRAMES_PER_PACKET := 480
const TIMEOUT := 3.0
const MAX_QUEUE := 8
const PREBUFFER := 4
const CFG_PATH := "user://settings.cfg"
const MIC_TAG := "MIC1"
const VSINK := "soundlink_sink"
const VERSION: String = preload("res://version.gd").VERSION
const UPDATE_URL := "https://github.com/goodview-soft/sound-link/releases/latest/download/version.json"
const DISC_PORT := 4243
const BEACON := "SOUNDLINK1"
const RELEASES_URL := "https://github.com/goodview-soft/sound-link/releases/latest"

var udp := PacketPeerUDP.new()
var mode := ""
var running := false
var cfg := ConfigFile.new()

# Capture (source du host, ou micro du client)
var capture: AudioEffectCapture
var mic_player: AudioStreamPlayer

# Host
var clients := {}
var seq := 0
var host_gain := 1.0
var vsink_ok := false
var bus_id := 0

# Client
var rx: RxStream
var hello_t := 0.0
var volume := 1.0
var balance := 0.0
var muted := false
var send_mic := false
var mic_gain := 1.0
var mic_seq := 0

var level_l := 0.0
var level_r := 0.0

# UI
const C_BG := Color("#0e1015")
const C_CARD := Color("#171a22")
const C_FIELD := Color("#10131a")
const C_BORDER := Color("#262b37")
const C_ACCENT := Color("#7c6cff")
const C_ACCENT2 := Color("#22d3ee")
const C_TEXT := Color("#e7eaf0")
const C_MUTED := Color("#8a92a6")
const C_OK := Color("#34d399")
const C_DANGER := Color("#f87171")
var host_box: VBoxContainer
var client_box: VBoxContainer
var dev_opt: OptionButton
var host_btn: Button
var host_status: Label
var vsink_lbl: Label
var no_client_lbl: Label
var clients_list: VBoxContainer
var ip_edit: LineEdit
var name_edit: LineEdit
var client_btn: Button
var client_status: Label
var bal_slider: HSlider
var mic_box: VBoxContainer
var meter: LevelMeter
var pill_dot: Label
var pill_txt: Label
var upd_card: PanelContainer
var home_box: VBoxContainer
var head_box: HBoxContainer
var app_box: VBoxContainer
var conn_lbl: Label
var found_lbl: Label
var disc := PacketPeerUDP.new()
var beacon_t := 0.0
var upd_lbl: Label
var upd_btn: Button
var upd_http: HTTPRequest
var upd_info := {}


# ---------------------------------------------------------------- Réception d'un flux

class RxStream:
	## Paquet : [hdr octets] seq u32, rate u32, PCM s16 (stéréo ou mono).
	var player: AudioStreamPlayer
	var playback: AudioStreamGeneratorPlayback
	var queue: Array[PackedByteArray] = []
	var rate := 0
	var buffering := true
	var skips := 0
	var last_seq := -1
	var lost := 0
	var last_rx := -100.0
	var prebuffer := 4
	var max_queue := 8
	var stereo: bool
	var hdr: int
	var parent: Node
	var bus: String

	func _init(p: Node, is_stereo: bool, header: int, bus_name := "Master") -> void:
		parent = p
		stereo = is_stereo
		hdr = header
		bus = bus_name

	func receive(pkt: PackedByteArray, now: float) -> void:
		if pkt.size() < hdr + 12:
			return
		var s := pkt.decode_u32(hdr)
		if last_seq >= 0 and s <= last_seq and last_seq - s < 100:
			return  # paquet en retard
		if last_seq >= 0 and s > last_seq + 1:
			lost += s - last_seq - 1
		last_seq = s
		last_rx = now
		var r := pkt.decode_u32(hdr + 4)
		if r != rate:
			_setup(r)
		queue.append(pkt)
		while queue.size() > max_queue:
			queue.pop_front()  # dérive d'horloge : on garde la latence basse

	## Pousse l'audio dans le générateur, renvoie les crêtes (L, R).
	func pump(gl: float, gr: float) -> Vector2:
		if playback == null:
			return Vector2.ZERO
		if playback.get_skips() != skips:  # coupure -> on reconstitue un petit tampon
			skips = playback.get_skips()
			buffering = true
		if buffering:
			if queue.size() < prebuffer:
				return Vector2.ZERO
			buffering = false
		var step := 4 if stereo else 2
		var pl := 0.0
		var pr := 0.0
		while not queue.is_empty():
			var pkt: PackedByteArray = queue[0]
			var n := (pkt.size() - hdr - 8) / step
			if playback.get_frames_available() < n:
				break
			queue.pop_front()
			var buf := PackedVector2Array()
			buf.resize(n)
			var o := hdr + 8
			for i in n:
				var l := pkt.decode_s16(o) * gl
				var r := (pkt.decode_s16(o + 2) if stereo else pkt.decode_s16(o)) * gr
				buf[i] = Vector2(l, r)
				pl = maxf(pl, absf(l))
				pr = maxf(pr, absf(r))
				o += step
			playback.push_buffer(buf)
		return Vector2(pl, pr)

	func latency_ms() -> int:
		if playback == null or rate <= 0:
			return 0
		var frames := queue.size() * 480 + int(0.1 * rate) - playback.get_frames_available()
		return int(frames * 1000.0 / rate)

	func _setup(r: int) -> void:
		free_player()
		var gen := AudioStreamGenerator.new()
		if "mix_rate_mode" in gen:
			gen.set("mix_rate_mode", 2)  # MIX_RATE_CUSTOM
		gen.mix_rate = r
		gen.buffer_length = 0.1
		player = AudioStreamPlayer.new()
		player.stream = gen
		player.bus = bus
		parent.add_child(player)
		player.play()
		playback = player.get_stream_playback()
		rate = r
		queue.clear()
		buffering = true
		skips = 0

	func free_player() -> void:
		if player:
			player.queue_free()
		player = null
		playback = null


# ---------------------------------------------------------------- Spectre d'un bus

class Spectrum extends Control:
	const BANDS := 28
	const F_MIN := 60.0
	const F_MAX := 10000.0
	var bus_name := ""
	var levels := PackedFloat32Array()
	var peaks := PackedFloat32Array()

	func _init(b: String, h := 46.0) -> void:
		bus_name = b
		custom_minimum_size.y = h
		size_flags_horizontal = SIZE_EXPAND_FILL
		levels.resize(BANDS)
		peaks.resize(BANDS)

	func _process(_d: float) -> void:
		var inst: AudioEffectSpectrumAnalyzerInstance = null
		var idx := AudioServer.get_bus_index(bus_name)
		if idx >= 0:
			for e in AudioServer.get_bus_effect_count(idx):
				if AudioServer.get_bus_effect(idx, e) is AudioEffectSpectrumAnalyzer:
					inst = AudioServer.get_bus_effect_instance(idx, e)
		for i in BANDS:
			var v := 0.0
			if inst:
				var a := F_MIN * pow(F_MAX / F_MIN, float(i) / BANDS)
				var b := F_MIN * pow(F_MAX / F_MIN, float(i + 1) / BANDS)
				var m := inst.get_magnitude_for_frequency_range(a, b).length()
				v = clampf((linear_to_db(m) + 72.0) / 60.0, 0.0, 1.0)
			levels[i] = maxf(v, levels[i] * 0.85)
		queue_redraw()

	func _draw() -> void:
		draw_style_box(_bg(), Rect2(Vector2.ZERO, size))
		var w := (size.x - 8) / BANDS
		var hmax := size.y - 8
		for i in BANDS:
			var t := float(i) / (BANDS - 1)
			var base := Color("#22d3ee").lerp(Color("#7c6cff"), t) if t < 0.6 else Color("#7c6cff").lerp(Color("#f472b6"), (t - 0.6) / 0.4)
			var x := 4 + i * w + 1
			draw_rect(Rect2(x, 4, maxf(w - 2, 1), hmax), Color(base, 0.06))
			var h := levels[i] * hmax
			if h >= 1.0:
				draw_rect(Rect2(x, 4 + hmax - h, maxf(w - 2, 1), h), base.lerp(Color.WHITE, levels[i] * 0.25))
			peaks[i] = maxf(levels[i], peaks[i] - 0.008)
			if peaks[i] > 0.02:
				draw_rect(Rect2(x, 4 + hmax - peaks[i] * hmax - 2, maxf(w - 2, 1), 2), Color(1, 1, 1, 0.7))

	func _bg() -> StyleBoxFlat:
		var s := StyleBoxFlat.new()
		s.bg_color = Color("#0b0d12")
		s.set_corner_radius_all(8)
		return s


class ModeIcon extends Control:
	## Pastille ronde avec un pictogramme Wi-Fi dessiné.
	var hover := false:
		set(v):
			hover = v
			queue_redraw()

	func _init() -> void:
		custom_minimum_size = Vector2(52, 52)
		size_flags_vertical = SIZE_SHRINK_CENTER
		mouse_filter = MOUSE_FILTER_IGNORE

	func _draw() -> void:
		var c := size / 2.0
		var acc := Color("#7c6cff")
		draw_circle(c, 26, Color(acc, 0.28 if hover else 0.16))
		draw_arc(c, 25.5, 0, TAU, 48, Color(acc, 0.7), 1.5, true)
		var fg := Color("#e7eaf0")
		var o := c + Vector2(0, 8)
		for r in [7.0, 13.0, 19.0]:
			draw_arc(o, r, deg_to_rad(-135), deg_to_rad(-45), 20, fg, 2.5, true)
		draw_circle(o, 2.6, fg)


class LevelMeter extends Control:
	## Vumètre à LEDs, deux canaux.
	const SEG := 30
	var l := 0.0
	var r := 0.0

	func _init() -> void:
		custom_minimum_size.y = 30
		size_flags_horizontal = SIZE_EXPAND_FILL

	func set_levels(a: float, b: float) -> void:
		l = a
		r = b
		queue_redraw()

	func _draw() -> void:
		var h := (size.y - 6) / 2.0
		_bar(0, l, h)
		_bar(h + 6, r, h)

	func _bar(y: float, v: float, h: float) -> void:
		var w := size.x / SEG
		for i in SEG:
			var t := float(i) / SEG
			var c := Color("#34d399") if t < 0.65 else (Color("#fbbf24") if t < 0.85 else Color("#f87171"))
			if t >= v:
				c = Color(c, 0.12)
			draw_rect(Rect2(i * w + 1, y, w - 2, h), c)


# ---------------------------------------------------------------- Vie de l'appli

func _ready() -> void:
	cfg.load(CFG_PATH)
	host_gain = cfg.get_value("host", "gain", 1.0)
	volume = cfg.get_value("client", "volume", 1.0)
	balance = cfg.get_value("client", "balance", 0.0)
	send_mic = cfg.get_value("client", "send_mic", false)
	mic_gain = cfg.get_value("client", "mic_gain", 1.0)
	_build_ui()
	_set_mode(cfg.get_value("app", "mode", "client"))
	_check_update()


func _exit_tree() -> void:
	_stop()
	_save()


func _save() -> void:
	cfg.set_value("app", "mode", mode)
	cfg.set_value("host", "gain", host_gain)
	cfg.set_value("client", "volume", volume)
	cfg.set_value("client", "balance", balance)
	cfg.set_value("client", "ip", ip_edit.text)
	cfg.set_value("client", "name", name_edit.text)
	cfg.set_value("client", "send_mic", send_mic)
	cfg.set_value("client", "mic_gain", mic_gain)
	cfg.save(CFG_PATH)


# ---------------------------------------------------------------- UI

func _build_ui() -> void:
	theme = _make_theme()
	var bg := ColorRect.new()
	bg.color = C_BG
	bg.set_anchors_preset(PRESET_FULL_RECT)
	add_child(bg)
	var scroll := ScrollContainer.new()
	scroll.set_anchors_preset(PRESET_FULL_RECT)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(scroll)
	var margin := MarginContainer.new()
	margin.size_flags_horizontal = SIZE_EXPAND_FILL
	for s in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + s, 18)
	scroll.add_child(margin)
	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 14)
	margin.add_child(root)

	# --- En-tête des pages Host / Client : retour, titre, état
	var head := HBoxContainer.new()
	head_box = head
	head.visible = false
	head.add_theme_constant_override("separation", 10)
	root.add_child(head)
	var back := _button("‹", head)
	back.theme_type_variation = "Tab"
	back.add_theme_font_size_override("font_size", 24)
	back.pressed.connect(_go_home)
	conn_lbl = _label("", head)
	conn_lbl.size_flags_horizontal = SIZE_EXPAND_FILL
	conn_lbl.add_theme_font_size_override("font_size", 24)
	var pill := PanelContainer.new()
	pill.add_theme_stylebox_override("panel", _sb(C_FIELD, 20, 12, 6, C_BORDER))
	pill.size_flags_vertical = SIZE_SHRINK_CENTER
	head.add_child(pill)
	var ph := HBoxContainer.new()
	pill.add_child(ph)
	pill_dot = _label("●", ph)
	pill_txt = _label("", ph)
	pill_txt.add_theme_font_size_override("font_size", 13)

	home_box = VBoxContainer.new()
	home_box.add_theme_constant_override("separation", 14)
	root.add_child(home_box)
	app_box = VBoxContainer.new()
	app_box.add_theme_constant_override("separation", 14)
	app_box.visible = false
	root.add_child(app_box)

	# --- Accueil : logo + deux choix
	var logo := TextureRect.new()
	logo.texture = load("res://icon.svg")
	logo.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	logo.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	logo.custom_minimum_size = Vector2(72, 72)
	home_box.add_child(logo)
	var ht := _label("Sound Link", home_box)
	ht.add_theme_font_size_override("font_size", 30)
	ht.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	var spacer := Control.new()
	spacer.custom_minimum_size.y = 8
	home_box.add_child(spacer)
	_mode_card(home_box, "Host", "Partager le son de ce PC", "host")
	_mode_card(home_box, "Client", "Écouter le son d'un host, ou servir de micro", "client")
	upd_card = PanelContainer.new()
	upd_card.add_theme_stylebox_override("panel", _sb(C_CARD, 12, 14, 8, C_BORDER))
	home_box.add_child(upd_card)
	var uh := HBoxContainer.new()
	upd_card.add_child(uh)
	upd_lbl = _label("", uh)
	upd_lbl.size_flags_horizontal = SIZE_EXPAND_FILL
	upd_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	upd_btn = _button("Mettre à jour", uh)
	upd_btn.theme_type_variation = "Tab"
	upd_btn.toggle_mode = false
	upd_btn.pressed.connect(_do_update)
	var foot := LinkButton.new()
	foot.text = "v%s  ·  github.com/goodview-soft/sound-link" % VERSION
	foot.uri = "https://github.com/goodview-soft/sound-link"
	foot.underline = LinkButton.UNDERLINE_MODE_ON_HOVER
	foot.add_theme_color_override("font_color", C_MUTED)
	foot.add_theme_color_override("font_hover_color", C_ACCENT2)
	foot.add_theme_font_size_override("font_size", 12)
	foot.size_flags_horizontal = SIZE_SHRINK_CENTER
	home_box.add_child(foot)

	root = app_box
	# --- Host
	host_box = VBoxContainer.new()
	host_box.add_theme_constant_override("separation", 14)
	root.add_child(host_box)
	var hs := _card(host_box, "Son partagé")
	var src := OS.get_environment("PULSE_SOURCE")
	_hint("« Default » = sortie son du PC." if src.ends_with(".monitor")
		else "Pour envoyer la sortie son du PC, lancer via sound-link.sh puis garder « Default ».", hs)
	var row := HBoxContainer.new()
	hs.add_child(row)
	dev_opt = OptionButton.new()
	dev_opt.size_flags_horizontal = SIZE_EXPAND_FILL
	dev_opt.clip_text = true
	row.add_child(dev_opt)
	_button("↻", row).pressed.connect(_refresh_devices)
	_slider_row(hs, "Gain d'envoi", 0, 200, host_gain * 100.0, func(x: float) -> String:
		host_gain = x / 100.0
		return "%d %%" % roundi(x))
	host_btn = _button("", hs)
	host_btn.pressed.connect(func() -> void:
		if running: _stop()
		else: _start_host())
	host_status = _hint("", hs)
	var hc := _card(host_box, "Clients connectés")
	vsink_lbl = _hint("", hc)
	no_client_lbl = _hint("Aucun client pour l'instant.", hc)
	no_client_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	clients_list = VBoxContainer.new()
	clients_list.add_theme_constant_override("separation", 10)
	hc.add_child(clients_list)
	if not OS.has_feature("mobile"):
		var qc := _card(host_box, "Installer sur un téléphone")
		var qh := HBoxContainer.new()
		qh.add_theme_constant_override("separation", 14)
		qc.add_child(qh)
		var qr := TextureRect.new()
		qr.texture = load("res://qr_apk.svg")
		qr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		qr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		qr.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		qr.custom_minimum_size = Vector2(132, 132)
		qh.add_child(qr)
		var qv := VBoxContainer.new()
		qv.size_flags_horizontal = SIZE_EXPAND_FILL
		qv.alignment = BoxContainer.ALIGNMENT_CENTER
		qh.add_child(qv)
		_label("Scanner avec le téléphone", qv)
		_hint("Télécharge la dernière version de l'appli Android. Autoriser l'installation si Android le demande, puis choisir Client : l'IP de ce PC est détectée toute seule.", qv)

	# --- Client
	client_box = VBoxContainer.new()
	client_box.add_theme_constant_override("separation", 14)
	root.add_child(client_box)
	var cc := _card(client_box, "Connexion")
	ip_edit = LineEdit.new()
	ip_edit.placeholder_text = "IP du host  (192.168.1.x)"
	ip_edit.text = cfg.get_value("client", "ip", "")
	cc.add_child(ip_edit)
	name_edit = LineEdit.new()
	name_edit.text = cfg.get_value("client", "name", OS.get_model_name() if OS.get_name() == "Android" else "")
	name_edit.placeholder_text = "Mon nom  (ex. Téléphone)"
	cc.add_child(name_edit)
	client_btn = _button("", cc)
	client_btn.pressed.connect(func() -> void:
		if running: _stop()
		else: _start_client())
	ip_edit.text_submitted.connect(func(_t: String) -> void:
		if not running: _start_client())
	found_lbl = _hint("", cc)
	client_status = _hint("", cc)

	var ce := _card(client_box, "Écoute")
	_slider_row(ce, "Volume", 0, 150, volume * 100.0, func(x: float) -> String:
		volume = x / 100.0
		return "%d %%" % roundi(x))
	bal_slider = _slider_row(ce, "Balance", -100, 100, balance * 100.0, func(x: float) -> String:
		balance = x / 100.0
		return "centre" if absf(x) < 1 else "%s %d %%" % ["D" if x > 0 else "G", roundi(absf(x))])
	var brow := HBoxContainer.new()
	ce.add_child(brow)
	var mute := CheckButton.new()
	mute.text = "Muet"
	mute.size_flags_horizontal = SIZE_EXPAND_FILL
	mute.toggled.connect(func(on: bool) -> void: muted = on)
	brow.add_child(mute)
	_button("Centrer", brow).pressed.connect(func() -> void: bal_slider.value = 0)

	var cm := _card(client_box, "Micro")
	var mic_chk := CheckButton.new()
	mic_chk.text = "Servir de micro au PC"
	mic_chk.button_pressed = send_mic
	mic_chk.toggled.connect(func(on: bool) -> void:
		send_mic = on
		mic_box.visible = on
		if running:
			if on: _start_capture("Default")
			else: _stop_capture())
	cm.add_child(mic_chk)
	mic_box = VBoxContainer.new()
	mic_box.visible = send_mic
	mic_box.add_theme_constant_override("separation", 10)
	cm.add_child(mic_box)
	_slider_row(mic_box, "Gain micro", 0, 300, mic_gain * 100.0, func(x: float) -> String:
		mic_gain = x / 100.0
		return "%d %%" % roundi(x))
	mic_box.add_child(Spectrum.new("Capture", 56.0))
	_hint("Son du PC dans le haut-parleur ? Casque ou « Muet » pour éviter l'écho.", mic_box)

	# --- Niveau
	var lv := _card(root, "Niveau  L / R")
	meter = LevelMeter.new()
	lv.add_child(meter)
	_set_run_btn(host_btn, false)
	_set_run_btn(client_btn, false)


func _make_theme() -> Theme:
	var t := Theme.new()
	var f := SystemFont.new()
	f.font_names = PackedStringArray(["Inter", "Cantarell", "Noto Sans", "Ubuntu", "DejaVu Sans"])
	t.default_font = f
	t.default_font_size = 15
	t.set_color("font_color", "Label", C_TEXT)

	var bn := _sb(Color("#222735"), 9, 14, 9)
	var bh := _sb(Color("#2b3142"), 9, 14, 9)
	var bp := _sb(Color("#1b1f2a"), 9, 14, 9)
	for ty in ["Button", "OptionButton"]:
		t.set_stylebox("normal", ty, bn)
		t.set_stylebox("hover", ty, bh)
		t.set_stylebox("pressed", ty, bp)
		t.set_stylebox("hover_pressed", ty, bh)
		t.set_stylebox("disabled", ty, bn)
		t.set_stylebox("focus", ty, StyleBoxEmpty.new())
		for c in ["font_color", "font_hover_color", "font_focus_color"]:
			t.set_color(c, ty, C_TEXT)
		t.set_color("font_pressed_color", ty, Color.WHITE)
		t.set_color("font_hover_pressed_color", ty, Color.WHITE)

	# Onglets : transparents, l'actif en accent
	t.set_type_variation("Tab", "Button")
	t.set_stylebox("normal", "Tab", _sb(Color(0, 0, 0, 0), 9, 10, 9))
	t.set_stylebox("hover", "Tab", _sb(Color("#1d2230"), 9, 10, 9))
	t.set_stylebox("pressed", "Tab", _sb(C_ACCENT, 9, 10, 9))
	t.set_stylebox("hover_pressed", "Tab", _sb(C_ACCENT.lightened(0.08), 9, 10, 9))
	t.set_color("font_color", "Tab", C_MUTED)

	# Bouton principal / bouton d'arrêt
	t.set_type_variation("Primary", "Button")
	t.set_stylebox("normal", "Primary", _sb(C_ACCENT, 10, 16, 12))
	t.set_stylebox("hover", "Primary", _sb(C_ACCENT.lightened(0.1), 10, 16, 12))
	t.set_stylebox("pressed", "Primary", _sb(C_ACCENT.darkened(0.15), 10, 16, 12))
	t.set_color("font_color", "Primary", Color.WHITE)
	t.set_color("font_hover_color", "Primary", Color.WHITE)
	t.set_font_size("font_size", "Primary", 16)
	t.set_type_variation("Danger", "Button")
	t.set_stylebox("normal", "Danger", _sb(Color("#3a1f26"), 10, 16, 12, C_DANGER))
	t.set_stylebox("hover", "Danger", _sb(Color("#4a2430"), 10, 16, 12, C_DANGER))
	t.set_stylebox("pressed", "Danger", _sb(Color("#2c171c"), 10, 16, 12, C_DANGER))
	t.set_color("font_color", "Danger", C_DANGER)
	t.set_color("font_hover_color", "Danger", Color("#fecaca"))
	t.set_font_size("font_size", "Danger", 16)

	# Cartes de mode (accueil)
	t.set_type_variation("ModeCard", "Button")
	t.set_stylebox("normal", "ModeCard", _sb(C_CARD, 14, 16, 14, C_BORDER))
	t.set_stylebox("hover", "ModeCard", _sb(Color("#1d2130"), 14, 16, 14, C_ACCENT))
	t.set_stylebox("pressed", "ModeCard", _sb(Color("#241f45"), 14, 16, 14, C_ACCENT))
	t.set_stylebox("hover_pressed", "ModeCard", _sb(Color("#241f45"), 14, 16, 14, C_ACCENT))

	# Champs texte
	t.set_stylebox("normal", "LineEdit", _sb(C_FIELD, 9, 12, 10, C_BORDER))
	t.set_stylebox("focus", "LineEdit", _sb(C_FIELD, 9, 12, 10, C_ACCENT))
	t.set_color("font_color", "LineEdit", C_TEXT)
	t.set_color("font_placeholder_color", "LineEdit", C_MUTED)
	t.set_color("caret_color", "LineEdit", C_ACCENT2)

	# Curseurs
	var track := _sb(C_BORDER, 4, 0, 3)
	var fill := _sb(C_ACCENT, 4, 0, 3)
	t.set_stylebox("slider", "HSlider", track)
	t.set_stylebox("grabber_area", "HSlider", fill)
	t.set_stylebox("grabber_area_highlight", "HSlider", _sb(C_ACCENT.lightened(0.1), 4, 0, 3))
	t.set_icon("grabber", "HSlider", _circle(18, Color.WHITE))
	t.set_icon("grabber_highlight", "HSlider", _circle(18, C_ACCENT2))

	# Interrupteurs
	for s in ["normal", "hover", "pressed", "hover_pressed", "focus"]:
		t.set_stylebox(s, "CheckButton", StyleBoxEmpty.new())
	for c in ["font_color", "font_hover_color", "font_pressed_color", "font_hover_pressed_color", "font_focus_color"]:
		t.set_color(c, "CheckButton", C_TEXT)

	# Cartes, barres de défilement
	t.set_stylebox("panel", "PanelContainer", _sb(C_CARD, 14, 16, 14, C_BORDER))
	var grab := _sb(C_BORDER, 4, 3, 3)
	t.set_stylebox("scroll", "VScrollBar", _sb(Color(0, 0, 0, 0), 4, 3, 3))
	for s in ["grabber", "grabber_highlight", "grabber_pressed"]:
		t.set_stylebox(s, "VScrollBar", grab)
	t.set_color("font_color", "TooltipLabel", C_TEXT)
	t.set_stylebox("panel", "TooltipPanel", _sb(C_CARD, 6, 8, 5, C_BORDER))
	return t


func _sb(col: Color, radius: int, pad_h: int, pad_v: int, border := Color(0, 0, 0, 0)) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = col
	s.set_corner_radius_all(radius)
	s.content_margin_left = pad_h
	s.content_margin_right = pad_h
	s.content_margin_top = pad_v
	s.content_margin_bottom = pad_v
	if border.a > 0:
		s.border_color = border
		s.set_border_width_all(1)
	s.anti_aliasing = true
	return s


func _circle(d: int, col: Color) -> ImageTexture:
	var img := Image.create(d, d, false, Image.FORMAT_RGBA8)
	var c := (d - 1) / 2.0
	for y in d:
		for x in d:
			var a := clampf(c - Vector2(x - c, y - c).length() + 0.5, 0.0, 1.0)
			img.set_pixel(x, y, Color(col, a))
	return ImageTexture.create_from_image(img)


func _card(parent: Node, title := "") -> VBoxContainer:
	var p := PanelContainer.new()
	parent.add_child(p)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 10)
	p.add_child(v)
	if title != "":
		var l := _label(title.to_upper(), v)
		l.add_theme_font_size_override("font_size", 12)
		l.add_theme_color_override("font_color", C_MUTED)
	return v


func _label(t: String, parent: Node) -> Label:
	var l := Label.new()
	l.text = t
	parent.add_child(l)
	return l


func _hint(t: String, parent: Node) -> Label:
	var l := _label(t, parent)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.add_theme_color_override("font_color", C_MUTED)
	l.add_theme_font_size_override("font_size", 13)
	return l


func _button(t: String, parent: Node) -> Button:
	var b := Button.new()
	b.text = t
	parent.add_child(b)
	return b


func _slider(mn: float, mx: float, val: float, parent: Node) -> HSlider:
	var s := HSlider.new()
	s.min_value = mn
	s.max_value = mx
	s.step = 1
	s.value = val
	s.custom_minimum_size.y = 24
	parent.add_child(s)
	return s


## Ligne « titre ........ valeur » + curseur ; fmt applique la valeur et renvoie son texte.
func _slider_row(parent: Node, title: String, mn: float, mx: float, val: float, fmt: Callable) -> HSlider:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 2)
	parent.add_child(box)
	var row := HBoxContainer.new()
	box.add_child(row)
	var l := _label(title, row)
	l.size_flags_horizontal = SIZE_EXPAND_FILL
	l.add_theme_color_override("font_color", C_MUTED)
	var vl := _label("", row)
	vl.add_theme_color_override("font_color", C_ACCENT2)
	var s := _slider(mn, mx, val, box)
	s.value_changed.connect(func(x: float) -> void: vl.text = fmt.call(x))
	vl.text = fmt.call(val)
	return s


func _set_run_btn(b: Button, on: bool) -> void:
	b.theme_type_variation = "Danger" if on else "Primary"
	if b == host_btn:
		b.text = "■  Arrêter la diffusion" if on else "▶  Démarrer la diffusion"
	else:
		b.text = "■  Se déconnecter" if on else "▶  Se connecter"


func _set_mode(m: String) -> void:
	if running and m != mode:
		_stop()
	mode = m
	host_box.visible = m == "host"
	client_box.visible = m == "client"
	if m == "host":
		_refresh_devices()


func _refresh_devices() -> void:
	var saved: String = cfg.get_value("host", "device", "")
	if dev_opt.selected >= 0:
		saved = dev_opt.get_item_text(dev_opt.selected)
	dev_opt.clear()
	var pick := -1
	for d in AudioServer.get_input_device_list():
		dev_opt.add_item(d)
		var i := dev_opt.item_count - 1
		if d == saved:
			pick = i
		elif pick == -1 and saved == "" and d.to_lower().contains("monitor"):
			pick = i
	dev_opt.select(maxi(pick, 0))


# ---------------------------------------------------------------- Bus audio

func _make_bus(bus: String, effects: Array) -> int:
	var idx := AudioServer.get_bus_index(bus)
	if idx < 0:
		AudioServer.add_bus()
		idx = AudioServer.bus_count - 1
		AudioServer.set_bus_name(idx, bus)
		for e in effects:
			AudioServer.add_bus_effect(idx, e)
	return idx


func _remove_bus(bus: String) -> void:
	var idx := AudioServer.get_bus_index(bus)
	if idx > 0:
		AudioServer.remove_bus(idx)


func _start_capture(dev: String) -> void:
	if mic_player:
		return
	if OS.get_name() == "Android":
		OS.request_permissions()
	if capture == null:
		capture = AudioEffectCapture.new()
		var idx := _make_bus("Capture", [capture, AudioEffectSpectrumAnalyzer.new()])
		AudioServer.set_bus_mute(idx, true)  # pas de retour local (évite l'écho)
	AudioServer.input_device = dev
	mic_player = AudioStreamPlayer.new()
	mic_player.stream = AudioStreamMicrophone.new()
	mic_player.bus = "Capture"
	add_child(mic_player)
	mic_player.play()
	capture.clear_buffer()


func _stop_capture() -> void:
	if mic_player:
		mic_player.queue_free()
		mic_player = null


# ---------------------------------------------------------------- Start / stop

func _start_host() -> void:
	if udp.bind(PORT) != OK:
		host_status.text = "Port %d indisponible." % PORT
		return
	var dev := dev_opt.get_item_text(dev_opt.selected) if dev_opt.selected >= 0 else "Default"
	cfg.set_value("host", "device", dev)
	_start_capture(dev)
	# Les micros reçus sont joués dans le micro virtuel, jamais sur les haut-parleurs (boucle).
	vsink_ok = VSINK in AudioServer.get_output_device_list()
	if vsink_ok:
		AudioServer.output_device = VSINK
	vsink_lbl.text = ("Micros reçus → micro virtuel « Sound-Link-Micro » (à choisir dans Discord, OBS…)." if vsink_ok
		else "Micro virtuel absent : lancer via sound-link.sh pour utiliser les micros des clients (spectre seul).")
	seq = 0
	running = true
	_set_run_btn(host_btn, true)


func _start_client() -> void:
	var ip := ip_edit.text.strip_edges()
	if not ip.is_valid_ip_address():
		ip = IP.resolve_hostname(ip, IP.TYPE_IPV4)
	if ip == "":
		client_status.text = "Adresse invalide."
		return
	if udp.bind(0) != OK:
		client_status.text = "Impossible d'ouvrir le réseau."
		return
	udp.set_dest_address(ip, PORT)
	rx = RxStream.new(self, true, 0)
	running = true
	hello_t = 0.0
	mic_seq = 0
	if send_mic:
		_start_capture("Default")
	_set_run_btn(client_btn, true)
	_save()


func _stop() -> void:
	if running and mode == "client":
		udp.put_packet("BYE".to_ascii_buffer())
	running = false
	udp.close()
	_stop_capture()
	if rx:
		rx.free_player()
		rx = null
	for k in clients.keys():
		_remove_client(k)
	if mode == "host" and vsink_ok:
		AudioServer.output_device = "Default"
		vsink_ok = false
	if host_btn:
		_set_run_btn(host_btn, false)
		_set_run_btn(client_btn, false)


# ---------------------------------------------------------------- Clients (host)

func _add_client(key: String, ip: String, port: int, cname: String, now: float) -> Dictionary:
	bus_id += 1
	var bus := "Mic%d" % bus_id
	_make_bus(bus, [AudioEffectSpectrumAnalyzer.new()])
	var c := {"ip": ip, "port": port, "t": now, "bus": bus, "rx": null, "muted": false}

	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", _sb(C_FIELD, 12, 12, 10, C_BORDER))
	clients_list.add_child(panel)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 8)
	panel.add_child(v)
	var top := HBoxContainer.new()
	v.add_child(top)
	var dot := _label("●", top)
	var nm := _label(cname if cname != "" else ip, top)
	nm.add_theme_font_size_override("font_size", 16)
	nm.size_flags_horizontal = SIZE_EXPAND_FILL
	nm.clip_text = true
	nm.tooltip_text = key
	var info := _hint("", top)
	info.autowrap_mode = TextServer.AUTOWRAP_OFF
	var mb := _button("Micro on", top)
	mb.toggle_mode = true
	mb.add_theme_font_size_override("font_size", 13)
	mb.toggled.connect(func(off: bool) -> void:
		c["muted"] = off
		mb.text = "Micro off" if off else "Micro on")
	v.add_child(Spectrum.new(bus, 52.0))
	var vs := _slider(0, 200, 100, v)
	vs.tooltip_text = "Volume de ce micro"
	vs.value_changed.connect(func(x: float) -> void: AudioServer.set_bus_volume_db(
		AudioServer.get_bus_index(bus), linear_to_db(maxf(x / 100.0, 0.0001))))

	c["panel"] = panel
	c["name"] = nm
	c["dot"] = dot
	c["info"] = info
	clients[key] = c
	return c


func _remove_client(key: String) -> void:
	var c: Dictionary = clients.get(key, {})
	if c.is_empty():
		return
	if c["rx"]:
		c["rx"].free_player()
	c["panel"].queue_free()
	_remove_bus(c["bus"])
	clients.erase(key)


# ---------------------------------------------------------------- Boucle

func _process(delta: float) -> void:
	var now := Time.get_ticks_msec() / 1000.0
	var peaks := Vector2.ZERO
	if running:
		peaks = _host_process(now) if mode == "host" else _client_process(now, delta)
	level_l = maxf(level_l * 0.88, peaks.x)
	level_r = maxf(level_r * 0.88, peaks.y)
	meter.set_levels(sqrt(level_l), sqrt(level_r))
	_discovery(now, delta)
	_update_status(now)


func _host_process(now: float) -> Vector2:
	while udp.get_available_packet_count() > 0:
		var pkt := udp.get_packet()
		var ip := udp.get_packet_ip()
		var port := udp.get_packet_port()
		var key := "%s:%d" % [ip, port]
		if pkt.size() > 12 and pkt.slice(0, 4).get_string_from_ascii() == MIC_TAG:
			var c: Dictionary = clients[key] if clients.has(key) else _add_client(key, ip, port, ip, now)
			c["t"] = now
			if c["rx"] == null:
				c["rx"] = RxStream.new(self, false, 4, c["bus"])
			c["rx"].receive(pkt, now)
			continue
		var msg := pkt.get_string_from_ascii()
		if msg.begins_with("HELLO"):
			var cname := msg.substr(6).strip_edges() if msg.length() > 6 else ""
			if clients.has(key):
				clients[key]["t"] = now
				if cname != "":
					clients[key]["name"].text = cname
			else:
				_add_client(key, ip, port, cname, now)
		elif msg == "BYE":
			_remove_client(key)
	for k in clients.keys():
		if now - clients[k]["t"] > TIMEOUT:
			_remove_client(k)

	# Micros reçus -> sortie (micro virtuel)
	for c in clients.values():
		var idx := AudioServer.get_bus_index(c["bus"])
		AudioServer.set_bus_mute(idx, c["muted"] or not vsink_ok)
		var talking := false
		var r: RxStream = c["rx"]
		if r:
			r.pump(1.0 / 32768.0, 1.0 / 32768.0)
			talking = now - r.last_rx < 1.0
		c["dot"].add_theme_color_override("font_color", C_OK if talking else C_MUTED)
		c["info"].text = ("micro %d ms" % r.latency_ms()) if talking else "écoute"

	# Source -> clients
	var rate := int(AudioServer.get_mix_rate())
	var pl := 0.0
	var pr := 0.0
	while capture.get_frames_available() >= FRAMES_PER_PACKET:
		var frames := capture.get_buffer(FRAMES_PER_PACKET)
		var pkt := PackedByteArray()
		pkt.resize(8 + FRAMES_PER_PACKET * 4)
		pkt.encode_u32(0, seq)
		pkt.encode_u32(4, rate)
		seq = (seq + 1) & 0xFFFFFFFF
		var o := 8
		for f in frames:
			var l := clampf(f.x * host_gain, -1.0, 1.0)
			var r := clampf(f.y * host_gain, -1.0, 1.0)
			pl = maxf(pl, absf(l))
			pr = maxf(pr, absf(r))
			pkt.encode_s16(o, int(l * 32767.0))
			pkt.encode_s16(o + 2, int(r * 32767.0))
			o += 4
		for c in clients.values():
			udp.set_dest_address(c["ip"], c["port"])
			udp.put_packet(pkt)
	return Vector2(pl, pr)


func _client_process(now: float, delta: float) -> Vector2:
	hello_t -= delta
	if hello_t <= 0.0:
		udp.put_packet(("HELLO " + name_edit.text.strip_edges()).to_utf8_buffer())
		hello_t = 1.0

	# Micro -> host
	if mic_player:
		var rate := int(AudioServer.get_mix_rate())
		while capture.get_frames_available() >= FRAMES_PER_PACKET:
			var frames := capture.get_buffer(FRAMES_PER_PACKET)
			var pkt := MIC_TAG.to_ascii_buffer()
			pkt.resize(12 + FRAMES_PER_PACKET * 2)
			pkt.encode_u32(4, mic_seq)
			pkt.encode_u32(8, rate)
			mic_seq = (mic_seq + 1) & 0xFFFFFFFF
			var o := 12
			for f in frames:
				pkt.encode_s16(o, int(clampf((f.x + f.y) * 0.5 * mic_gain, -1.0, 1.0) * 32767.0))
				o += 2
			udp.put_packet(pkt)

	# Host -> haut-parleur
	while udp.get_available_packet_count() > 0:
		rx.receive(udp.get_packet(), now)
	var gl := 0.0
	var gr := 0.0
	if not muted:
		var v := volume * volume / 32768.0  # courbe perceptive
		gl = v * minf(1.0, 1.0 - balance)
		gr = v * minf(1.0, 1.0 + balance)
	return rx.pump(gl, gr)


func _update_status(now: float) -> void:
	var live := running and (mode == "host" or now - rx.last_rx < 2.0)
	pill_dot.add_theme_color_override("font_color", C_OK if live else (Color("#fbbf24") if running else C_MUTED))
	pill_txt.text = ("En diffusion" if mode == "host" else "Connecté") if live else ("Connexion…" if running else "Arrêté")
	no_client_lbl.visible = clients.is_empty()
	if mode == "host":
		if not running:
			host_status.text = "Arrêté. IP de ce PC : %s" % _local_ips()
			vsink_lbl.text = ""
		else:
			host_status.text = "Diffusion sur le port %d — IP de ce PC : %s\nClients connectés : %d" % [PORT, _local_ips(), clients.size()]
	elif not running:
		client_status.text = "Déconnecté."
	elif now - rx.last_rx > 2.0:
		client_status.text = "En attente du host… (vérifier l'IP, le pare-feu UDP %d)" % PORT
	else:
		client_status.text = "Réception OK — %d Hz — tampon ~%d ms — paquets perdus : %d" % [rx.rate, rx.latency_ms(), rx.lost]


func _local_ips() -> String:
	var out: PackedStringArray = []
	for a in IP.get_local_addresses():
		if a.contains(".") and not a.begins_with("127.") and not a.begins_with("169.254"):
			out.append(a)
	return ", ".join(out) if out.size() > 0 else "?"


# ---------------------------------------------------------------- Mise à jour

func _check_update() -> void:
	if upd_http == null:
		upd_http = HTTPRequest.new()
		upd_http.timeout = 10.0
		add_child(upd_http)
	upd_http.cancel_request()
	upd_lbl.text = "Recherche de mises à jour…"
	upd_btn.visible = false
	upd_http.request_completed.connect(_on_version_json, CONNECT_ONE_SHOT)
	upd_http.request(UPDATE_URL)


func _on_version_json(result: int, code: int, _h: PackedStringArray, body: PackedByteArray) -> void:
	upd_btn.text = "Vérifier"
	upd_btn.visible = true
	if result != HTTPRequest.RESULT_SUCCESS or code != 200:
		upd_lbl.text = ("✓  v%s (aucune version publiée)" % VERSION) if code == 404 \
			else "Mises à jour : vérification impossible (hors ligne ?)."
		return
	var info = JSON.parse_string(body.get_string_from_utf8())
	if not (info is Dictionary) or not info.has("version"):
		return
	if not preload("res://boot.gd").newer(str(info["version"]), VERSION):
		upd_lbl.text = "✓  À jour (v%s)" % VERSION
		return
	upd_info = info
	upd_btn.visible = true
	upd_card.add_theme_stylebox_override("panel", _sb(Color("#1e1a3a"), 12, 14, 10, C_ACCENT))
	var same_engine: bool = str(info.get("godot", "")) == "%d.%d.%d" % [Engine.get_version_info().major,
		Engine.get_version_info().minor, Engine.get_version_info().patch]
	if same_engine and info.has("pck"):
		upd_lbl.text = "Version %s disponible." % info["version"]
		upd_btn.text = "Mettre à jour"
	else:
		upd_lbl.text = "Version %s disponible (nouveau programme à télécharger)." % info["version"]
		upd_btn.text = "Télécharger"


func _do_update() -> void:
	if upd_btn.text == "Vérifier":
		_check_update()
		return
	if upd_btn.text == "Télécharger":
		OS.shell_open(RELEASES_URL)
		return
	if upd_btn.text == "Redémarrer":
		OS.set_restart_on_exit(true)
		get_tree().quit()
		return
	upd_btn.disabled = true
	upd_lbl.text = "Téléchargement…"
	upd_http.download_file = "user://update.tmp"
	upd_http.request_completed.connect(_on_pck, CONNECT_ONE_SHOT)
	upd_http.request(str(upd_info["pck"]))


func _on_pck(result: int, code: int, _h: PackedStringArray, _b: PackedByteArray) -> void:
	upd_http.download_file = ""
	upd_btn.disabled = false
	var tmp := "user://update.tmp"
	if result != HTTPRequest.RESULT_SUCCESS or code != 200 \
			or FileAccess.get_sha256(tmp) != str(upd_info.get("sha256", "")):
		DirAccess.remove_absolute(tmp)
		upd_lbl.text = "Échec du téléchargement, réessayer."
		return
	DirAccess.rename_absolute(tmp, "user://update.pck")
	var c := ConfigFile.new()
	c.set_value("update", "version", str(upd_info["version"]))
	c.save("user://update.cfg")
	if OS.has_feature("pc"):
		upd_lbl.text = "Mise à jour %s installée." % upd_info["version"]
		upd_btn.text = "Redémarrer"
	else:
		upd_lbl.text = "Mise à jour %s installée : fermer puis rouvrir l'appli." % upd_info["version"]
		upd_btn.visible = false


# ---------------------------------------------------------------- Accueil / modes

func _mode_card(parent: Node, title: String, desc: String, target: String) -> void:
	var b := Button.new()
	b.theme_type_variation = "ModeCard"
	b.custom_minimum_size.y = 96
	parent.add_child(b)
	var m := MarginContainer.new()
	m.set_anchors_preset(PRESET_FULL_RECT)
	m.mouse_filter = MOUSE_FILTER_IGNORE
	for side in ["left", "right", "top", "bottom"]:
		m.add_theme_constant_override("margin_" + side, 16)
	b.add_child(m)
	var h := HBoxContainer.new()
	h.mouse_filter = MOUSE_FILTER_IGNORE
	h.add_theme_constant_override("separation", 14)
	m.add_child(h)
	var ic := ModeIcon.new()
	h.add_child(ic)
	var v := VBoxContainer.new()
	v.mouse_filter = MOUSE_FILTER_IGNORE
	v.size_flags_horizontal = SIZE_EXPAND_FILL
	v.alignment = BoxContainer.ALIGNMENT_CENTER
	v.add_theme_constant_override("separation", 2)
	h.add_child(v)
	var t := _label(title, v)
	t.add_theme_font_size_override("font_size", 19)
	_hint(desc, v)
	var arrow := _label("›", h)
	arrow.add_theme_font_size_override("font_size", 26)
	arrow.add_theme_color_override("font_color", C_MUTED)
	b.mouse_entered.connect(func() -> void: ic.hover = true)
	b.mouse_exited.connect(func() -> void: ic.hover = false)
	b.pressed.connect(_enter_app.bind(target))


func _enter_app(target: String) -> void:
	_set_mode(target)
	conn_lbl.text = "Host" if target == "host" else "Client"
	home_box.visible = false
	head_box.visible = true
	app_box.visible = true


func _go_home() -> void:
	if running:
		_stop()
	app_box.visible = false
	head_box.visible = false
	home_box.visible = true


# ---------------------------------------------------------------- Découverte du host

## Le host annonce sa présence en broadcast ; le client écoute et remplit l'IP tout seul.
func _discovery(now: float, delta: float) -> void:
	if mode == "host" and running:
		beacon_t -= delta
		if beacon_t <= 0.0:
			beacon_t = 1.0
			udp.set_broadcast_enabled(true)
			for b in _broadcast_addrs():
				udp.set_dest_address(b, DISC_PORT)
				udp.put_packet(BEACON.to_ascii_buffer())
		return
	if mode != "client" or not app_box.visible:
		if disc.is_bound():
			disc.close()
		return
	if not disc.is_bound() and disc.bind(DISC_PORT) != OK:
		return
	while disc.get_available_packet_count() > 0:
		var msg := disc.get_packet().get_string_from_ascii()
		var ip := disc.get_packet_ip()
		if msg != BEACON:
			continue
		found_lbl.text = "Host détecté : %s" % ip
		found_lbl.add_theme_color_override("font_color", C_OK)
		if not running and ip_edit.text.strip_edges() == "":
			ip_edit.text = ip


func _broadcast_addrs() -> PackedStringArray:
	var out: PackedStringArray = ["255.255.255.255"]
	for a in IP.get_local_addresses():
		if a.contains(".") and not a.begins_with("127.") and not a.begins_with("169.254"):
			out.append(a.substr(0, a.rfind(".")) + ".255")
	return out
