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
var ip_chip: Label
var board_grids := []  # [grille, bus]
var board_until := 0.0
var board_cap := AudioEffectCapture.new()
var board_to_game := true
var board_to_clients := false
var board_vol := 0.8
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


class HeroWave extends Control:
	## Onde décorative animée sous le titre.
	const N := 36
	var t := 0.0

	func _init() -> void:
		custom_minimum_size.y = 36
		size_flags_horizontal = SIZE_EXPAND_FILL

	func _process(d: float) -> void:
		if is_visible_in_tree():
			t += d
			queue_redraw()

	func _draw() -> void:
		var w := size.x / N
		var mid := size.y / 2.0
		for i in N:
			var x := float(i) / (N - 1)
			var env := sin(x * PI)  # plus haut au centre
			var a := 0.5 + 0.5 * sin(t * 2.2 + i * 0.45) * cos(t * 1.3 - i * 0.21)
			var h := maxf(3.0, env * a * (size.y - 4))
			var c := Color("#22d3ee").lerp(Color("#7c6cff"), x)
			draw_rect(Rect2(i * w + w * 0.25, mid - h / 2, w * 0.5, h), Color(c, 0.35 + 0.5 * env))


class Icon extends Control:
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
	board_to_game = cfg.get_value("board", "game", true)
	board_to_clients = cfg.get_value("board", "clients", false)
	_build_ui()
	_set_mode(cfg.get_value("app", "mode", "client"))
	_check_update()
	for arg in OS.get_cmdline_user_args():  # ex. -- --page=host
		if arg in ["--page=host", "--page=client"]:
			_open(arg.substr(7))


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
	cfg.set_value("board", "game", board_to_game)
	cfg.set_value("board", "clients", board_to_clients)
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
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 18)
	scroll.add_child(margin)
	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 16)
	margin.add_child(root)

	# --- Barre du haut (pages)
	head_box = HBoxContainer.new()
	head_box.add_theme_constant_override("separation", 10)
	head_box.visible = false
	root.add_child(head_box)
	_icon_btn("back", head_box).pressed.connect(_go_home)
	conn_lbl = _label("", head_box)
	conn_lbl.add_theme_font_size_override("font_size", 22)
	conn_lbl.size_flags_horizontal = SIZE_EXPAND_FILL
	var pill := PanelContainer.new()
	pill.add_theme_stylebox_override("panel", _sb(C_FIELD, 20, 12, 6, C_BORDER))
	pill.size_flags_vertical = SIZE_SHRINK_CENTER
	head_box.add_child(pill)
	var ph := HBoxContainer.new()
	pill.add_child(ph)
	pill_dot = _label("●", ph)
	pill_txt = _label("", ph)
	pill_txt.add_theme_font_size_override("font_size", 13)

	# --- Accueil
	home_box = VBoxContainer.new()
	home_box.add_theme_constant_override("separation", 18)
	root.add_child(home_box)
	var sp := Control.new()
	sp.custom_minimum_size.y = 24
	home_box.add_child(sp)
	var logo := TextureRect.new()
	logo.texture = load("res://icon.svg")
	logo.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	logo.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	logo.custom_minimum_size = Vector2(76, 76)
	home_box.add_child(logo)
	var ht := _label("Sound Link", home_box)
	ht.add_theme_font_size_override("font_size", 32)
	ht.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	home_box.add_child(HeroWave.new())
	var tiles := HBoxContainer.new()
	tiles.add_theme_constant_override("separation", 12)
	home_box.add_child(tiles)
	_tile(tiles, "broadcast", "Diffuser", "host")
	_tile(tiles, "headphones", "Écouter", "client")
	upd_card = PanelContainer.new()
	upd_card.add_theme_stylebox_override("panel", _sb(C_CARD, 20, 14, 6, C_BORDER))
	upd_card.size_flags_horizontal = SIZE_SHRINK_CENTER
	home_box.add_child(upd_card)
	var uh := HBoxContainer.new()
	uh.add_theme_constant_override("separation", 10)
	upd_card.add_child(uh)
	upd_lbl = _label("", uh)
	upd_lbl.add_theme_font_size_override("font_size", 13)
	upd_lbl.add_theme_color_override("font_color", C_MUTED)
	upd_btn = _button("", uh)
	upd_btn.theme_type_variation = "Chip"
	upd_btn.pressed.connect(_do_update)
	var foot := LinkButton.new()
	foot.text = "v%s · GitHub" % VERSION
	foot.uri = "https://github.com/goodview-soft/sound-link"
	foot.underline = LinkButton.UNDERLINE_MODE_ON_HOVER
	foot.add_theme_color_override("font_color", Color(C_MUTED, 0.7))
	foot.add_theme_color_override("font_hover_color", C_ACCENT2)
	foot.add_theme_font_size_override("font_size", 12)
	foot.size_flags_horizontal = SIZE_SHRINK_CENTER
	home_box.add_child(foot)

	# --- Pages
	app_box = VBoxContainer.new()
	app_box.add_theme_constant_override("separation", 16)
	app_box.visible = false
	root.add_child(app_box)

	# Diffuser (host)
	host_box = VBoxContainer.new()
	host_box.add_theme_constant_override("separation", 16)
	app_box.add_child(host_box)
	var hs := _card(host_box)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	hs.add_child(row)
	dev_opt = OptionButton.new()
	dev_opt.size_flags_horizontal = SIZE_EXPAND_FILL
	dev_opt.clip_text = true
	row.add_child(dev_opt)
	_icon_btn("refresh", row).pressed.connect(_refresh_devices)
	_slider_line(hs, Icon.new("speaker", 22, C_MUTED), 0, 200, host_gain * 100.0, 100, func(x: float) -> String:
		host_gain = x / 100.0
		return "%d%%" % roundi(x))
	host_btn = _round_btn(host_box)
	host_btn.pressed.connect(func() -> void:
		if running: _stop()
		else: _start_host())
	host_status = _caption(host_box)
	ip_chip = _label("", host_box)
	ip_chip.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	ip_chip.add_theme_color_override("font_color", C_ACCENT2)
	ip_chip.add_theme_font_size_override("font_size", 18)
	var hc := _card(host_box)
	var ch := HBoxContainer.new()
	hc.add_child(ch)
	var ct := _label("Clients", ch)
	ct.add_theme_font_size_override("font_size", 16)
	ct.size_flags_horizontal = SIZE_EXPAND_FILL
	var qr_btn := _icon_btn("qr", ch)
	qr_btn.toggle_mode = true
	qr_btn.tooltip_text = "Installer l'appli sur un téléphone"
	var qr_box := VBoxContainer.new()
	qr_box.visible = false
	hc.add_child(qr_box)
	if OS.has_feature("mobile"):
		qr_btn.visible = false
	else:
		var qr := TextureRect.new()
		qr.texture = load("res://qr_apk.svg")
		qr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		qr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		qr.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		qr.custom_minimum_size = Vector2(170, 170)
		qr_box.add_child(qr)
		_caption(qr_box).text = "Scanner pour installer l'appli Android"
	qr_btn.toggled.connect(func(on: bool) -> void: qr_box.visible = on)
	vsink_lbl = _hint("", hc)
	no_client_lbl = _caption(hc)
	no_client_lbl.text = "Aucun client"
	clients_list = VBoxContainer.new()
	clients_list.add_theme_constant_override("separation", 10)
	hc.add_child(clients_list)

	_board_card(host_box, "Board")  # host : joue dans le micro virtuel

	# Écouter (client)
	client_box = VBoxContainer.new()
	client_box.add_theme_constant_override("separation", 16)
	app_box.add_child(client_box)
	var cc := _card(client_box)
	ip_edit = LineEdit.new()
	ip_edit.placeholder_text = "IP du host"
	ip_edit.text = cfg.get_value("client", "ip", "")
	cc.add_child(ip_edit)
	name_edit = LineEdit.new()
	name_edit.text = cfg.get_value("client", "name", OS.get_model_name() if OS.get_name() == "Android" else "")
	name_edit.placeholder_text = "Mon nom"
	cc.add_child(name_edit)
	found_lbl = _hint("", cc)
	client_btn = _round_btn(client_box)
	client_btn.pressed.connect(func() -> void:
		if running: _stop()
		else: _start_client())
	ip_edit.text_submitted.connect(func(_t: String) -> void:
		if not running: _start_client())
	client_status = _caption(client_box)

	var ce := _card(client_box)
	var mute_btn := _icon_btn("speaker", null)
	mute_btn.toggle_mode = true
	mute_btn.tooltip_text = "Muet"
	mute_btn.toggled.connect(func(on: bool) -> void:
		muted = on
		mute_btn.get_meta("icon").set_kind("speaker_off" if on else "speaker"))
	_slider_line(ce, mute_btn, 0, 150, volume * 100.0, 100, func(x: float) -> String:
		volume = x / 100.0
		return "%d%%" % roundi(x))
	var bl := Label.new()
	bl.text = "G  D"
	bl.add_theme_color_override("font_color", C_MUTED)
	bl.custom_minimum_size.x = 40
	bl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	bal_slider = _slider_line(ce, bl, -100, 100, balance * 100.0, 0, func(x: float) -> String:
		balance = x / 100.0
		return "centre" if absf(x) < 1 else "%s %d" % ["D" if x > 0 else "G", roundi(absf(x))])

	var cm := _card(client_box)
	var mrow := HBoxContainer.new()
	mrow.add_theme_constant_override("separation", 10)
	cm.add_child(mrow)
	var mic_btn := _icon_btn("mic" if send_mic else "mic_off", mrow)
	mic_btn.toggle_mode = true
	mic_btn.button_pressed = send_mic
	var mlab := _label("Micro vers le PC", mrow)
	mlab.size_flags_horizontal = SIZE_EXPAND_FILL
	mic_box = VBoxContainer.new()
	mic_box.visible = send_mic
	mic_box.add_theme_constant_override("separation", 8)
	cm.add_child(mic_box)
	_slider_line(mic_box, Icon.new("mic", 22, C_MUTED), 0, 300, mic_gain * 100.0, 100, func(x: float) -> String:
		mic_gain = x / 100.0
		return "%d%%" % roundi(x))
	mic_box.add_child(Spectrum.new("Capture", 48.0))
	mic_btn.toggled.connect(func(on: bool) -> void:
		send_mic = on
		mic_btn.get_meta("icon").set_kind("mic" if on else "mic_off")
		mic_box.visible = on
		if running:
			if on: _start_capture("Default")
			else: _stop_capture())

	_board_card(client_box, "Capture")  # client : part vers le host avec le micro
	_build_board()

	meter = LevelMeter.new()
	app_box.add_child(meter)
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

	t.set_type_variation("IconBtn", "Button")
	t.set_stylebox("normal", "IconBtn", _sb(Color("#1d2130"), 12, 0, 0))
	t.set_stylebox("hover", "IconBtn", _sb(Color("#272c3c"), 12, 0, 0))
	t.set_stylebox("pressed", "IconBtn", _sb(C_ACCENT, 12, 0, 0))
	t.set_stylebox("hover_pressed", "IconBtn", _sb(C_ACCENT.lightened(0.08), 12, 0, 0))
	t.set_type_variation("Round", "Button")
	t.set_stylebox("normal", "Round", _sb(C_ACCENT, 40, 0, 0))
	t.set_stylebox("hover", "Round", _sb(C_ACCENT.lightened(0.1), 40, 0, 0))
	t.set_stylebox("pressed", "Round", _sb(C_ACCENT.darkened(0.15), 40, 0, 0))
	t.set_type_variation("RoundOn", "Button")
	t.set_stylebox("normal", "RoundOn", _sb(Color("#3a1f26"), 40, 0, 0, C_DANGER))
	t.set_stylebox("hover", "RoundOn", _sb(Color("#4a2430"), 40, 0, 0, C_DANGER))
	t.set_stylebox("pressed", "RoundOn", _sb(Color("#2c171c"), 40, 0, 0, C_DANGER))
	t.set_type_variation("Chip", "Button")
	t.set_stylebox("normal", "Chip", _sb(Color(C_ACCENT2, 0.10), 10, 9, 3))
	t.set_stylebox("hover", "Chip", _sb(Color(C_ACCENT2, 0.2), 10, 9, 3))
	t.set_stylebox("pressed", "Chip", _sb(Color(C_ACCENT2, 0.3), 10, 9, 3))
	for k in ["font_color", "font_hover_color", "font_pressed_color"]:
		t.set_color(k, "Chip", C_ACCENT2)
	t.set_font_size("font_size", "Chip", 13)

	t.set_type_variation("Toggle", "Button")
	t.set_stylebox("normal", "Toggle", _sb(Color("#1d2130"), 10, 12, 5, C_BORDER))
	t.set_stylebox("hover", "Toggle", _sb(Color("#272c3c"), 10, 12, 5, C_BORDER))
	t.set_stylebox("pressed", "Toggle", _sb(C_ACCENT, 10, 12, 5))
	t.set_stylebox("hover_pressed", "Toggle", _sb(C_ACCENT.lightened(0.08), 10, 12, 5))
	t.set_color("font_color", "Toggle", C_MUTED)
	t.set_font_size("font_size", "Toggle", 13)
	t.set_type_variation("Pad", "Button")
	t.set_stylebox("normal", "Pad", _sb(Color("#1b1f2b"), 10, 6, 14, C_BORDER))
	t.set_stylebox("hover", "Pad", _sb(Color("#232838"), 10, 6, 14, C_ACCENT))
	t.set_stylebox("pressed", "Pad", _sb(Color("#2d2656"), 10, 6, 14, C_ACCENT))
	t.set_font_size("font_size", "Pad", 13)

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
## Ligne compacte : [élément de tête] [curseur] [valeur cliquable = réinitialiser].
func _slider_line(parent: Node, lead: Control, mn: float, mx: float, val: float, reset: float, fmt: Callable) -> HSlider:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	parent.add_child(row)
	row.add_child(lead)
	var s := _slider(mn, mx, val, row)
	s.size_flags_horizontal = SIZE_EXPAND_FILL
	s.size_flags_vertical = SIZE_SHRINK_CENTER
	var vb := _button("", row)
	vb.theme_type_variation = "Chip"
	vb.custom_minimum_size.x = 64
	vb.tooltip_text = "Réinitialiser"
	vb.pressed.connect(func() -> void: s.value = reset)
	s.value_changed.connect(func(x: float) -> void: vb.text = fmt.call(x))
	vb.text = fmt.call(val)
	return s


func _icon_btn(kind: String, parent: Node, sz := 40.0) -> Button:
	var b := Button.new()
	b.theme_type_variation = "IconBtn"
	b.custom_minimum_size = Vector2(sz, sz)
	b.size_flags_vertical = SIZE_SHRINK_CENTER
	var ic := Icon.new(kind, 0)
	ic.scale_f = 0.55
	ic.set_anchors_preset(PRESET_FULL_RECT)
	b.add_child(ic)
	b.set_meta("icon", ic)
	if parent:
		parent.add_child(b)
	return b


func _round_btn(parent: Node) -> Button:
	var cc := CenterContainer.new()
	parent.add_child(cc)
	var b := Button.new()
	b.custom_minimum_size = Vector2(80, 80)
	cc.add_child(b)
	var ic := Icon.new("play", 0, Color.WHITE)
	ic.scale_f = 0.42
	ic.set_anchors_preset(PRESET_FULL_RECT)
	b.add_child(ic)
	b.set_meta("icon", ic)
	return b


func _caption(parent: Node) -> Label:
	var l := _label("", parent)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.add_theme_color_override("font_color", C_MUTED)
	l.add_theme_font_size_override("font_size", 13)
	return l


func _tile(parent: Node, kind: String, title: String, m: String) -> void:
	var b := Button.new()
	b.theme_type_variation = "ModeCard"
	b.custom_minimum_size.y = 148
	b.size_flags_horizontal = SIZE_EXPAND_FILL
	parent.add_child(b)
	var v := VBoxContainer.new()
	v.set_anchors_preset(PRESET_FULL_RECT)
	v.alignment = BoxContainer.ALIGNMENT_CENTER
	v.mouse_filter = MOUSE_FILTER_IGNORE
	v.add_theme_constant_override("separation", 12)
	b.add_child(v)
	var ic := Icon.new(kind, 46, C_ACCENT2)
	ic.size_flags_horizontal = SIZE_SHRINK_CENTER
	v.add_child(ic)
	var l := _label(title, v)
	l.add_theme_font_size_override("font_size", 18)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	b.pressed.connect(_open.bind(m))


func _set_run_btn(b: Button, on: bool) -> void:
	b.theme_type_variation = "RoundOn" if on else "Round"
	b.get_meta("icon").set_kind("stop" if on else "play", C_DANGER if on else Color.WHITE)
	b.tooltip_text = ("Arrêter" if on else "Démarrer") if b == host_btn else ("Se déconnecter" if on else "Se connecter")


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
	_ensure_capture()
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
	vsink_lbl.text = "Micros → « Sound-Link-Micro »" if vsink_ok else "Micro virtuel absent : lancer via sound-link.sh"
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
	top.add_theme_constant_override("separation", 8)
	v.add_child(top)
	var dot := _label("●", top)
	var nm := _label(cname if cname != "" else ip, top)
	nm.add_theme_font_size_override("font_size", 15)
	nm.size_flags_horizontal = SIZE_EXPAND_FILL
	nm.clip_text = true
	nm.tooltip_text = key
	var info := _hint("", top)
	info.autowrap_mode = TextServer.AUTOWRAP_OFF
	var mb := _icon_btn("mic", top, 34)
	mb.toggle_mode = true
	mb.tooltip_text = "Couper ce micro"
	mb.toggled.connect(func(off: bool) -> void:
		c["muted"] = off
		mb.get_meta("icon").set_kind("mic_off" if off else "mic"))
	v.add_child(Spectrum.new(bus, 40.0))
	_slider_line(v, Icon.new("speaker", 20, C_MUTED), 0, 200, 100, 100, func(x: float) -> String:
		AudioServer.set_bus_volume_db(AudioServer.get_bus_index(bus), linear_to_db(maxf(x / 100.0, 0.0001)))
		return "%d%%" % roundi(x))

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
		var bf := _board_frames()
		for j in frames.size():
			var f := frames[j] * host_gain
			if j < bf.size():
				f += bf[j]  # soundboard partagée avec les clients
			var l := clampf(f.x, -1.0, 1.0)
			var r := clampf(f.y, -1.0, 1.0)
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

	# Micro (+ soundboard) -> host
	if mic_player or now < board_until:
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
	elif capture:
		capture.clear_buffer()  # rien à envoyer : on garde le tampon frais

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
	pill_txt.text = ("En direct" if mode == "host" else "Connecté") if live else ("Recherche…" if running else "Arrêté")
	no_client_lbl.visible = clients.is_empty()
	if mode == "host":
		ip_chip.text = _local_ips()
		if running:
			var n := clients.size()
			host_status.text = "%d client%s" % [n, "s" if n > 1 else ""]
		else:
			host_status.text = "Prêt à diffuser"
			vsink_lbl.text = ""
	elif not running:
		client_status.text = "Déconnecté"
	elif now - rx.last_rx > 2.0:
		client_status.text = "Recherche du host…"
	else:
		client_status.text = "%d ms · %d perdus" % [rx.latency_ms(), rx.lost]


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
	upd_lbl.text = "Recherche…"
	upd_btn.visible = false
	upd_http.request_completed.connect(_on_version_json, CONNECT_ONE_SHOT)
	upd_http.request(UPDATE_URL)


func _on_version_json(result: int, code: int, _h: PackedStringArray, body: PackedByteArray) -> void:
	upd_btn.text = "Vérifier"
	upd_btn.visible = true
	if result != HTTPRequest.RESULT_SUCCESS or code != 200:
		upd_lbl.text = "✓ À jour" if code == 404 else "Hors ligne"
		return
	var info = JSON.parse_string(body.get_string_from_utf8())
	if not (info is Dictionary) or not info.has("version"):
		return
	if not preload("res://boot.gd").newer(str(info["version"]), VERSION):
		upd_lbl.text = "✓ À jour"
		return
	upd_info = info
	upd_btn.visible = true
	upd_card.add_theme_stylebox_override("panel", _sb(Color("#1e1a3a"), 12, 14, 10, C_ACCENT))
	var same_engine: bool = str(info.get("godot", "")) == "%d.%d.%d" % [Engine.get_version_info().major,
		Engine.get_version_info().minor, Engine.get_version_info().patch]
	if same_engine and info.has("pck"):
		upd_lbl.text = "v%s disponible" % info["version"]
		upd_btn.text = "Mettre à jour"
	else:
		upd_lbl.text = "v%s disponible" % info["version"]
		upd_btn.text = "Télécharger"


func _do_update() -> void:
	if upd_btn.text == "Vérifier":
		_check_update()
	for arg in OS.get_cmdline_user_args():  # ex. -- --page=host
		if arg in ["--page=host", "--page=client"]:
			_open(arg.substr(7))
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

func _open(m: String) -> void:
	_set_mode(m)
	conn_lbl.text = "Diffuser" if m == "host" else "Écouter"
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


# ---------------------------------------------------------------- Soundboard

func _sounds_dir() -> String:
	return OS.get_user_data_dir().path_join("sons")


func _ensure_capture() -> void:
	if capture == null:
		capture = AudioEffectCapture.new()
		var idx := _make_bus("Capture", [capture, AudioEffectSpectrumAnalyzer.new()])
		AudioServer.set_bus_mute(idx, true)  # pas de retour local (évite l'écho)


func _board_card(parent: Node, bus: String) -> void:
	var sb := _card(parent)
	var sbh := HBoxContainer.new()
	sbh.add_theme_constant_override("separation", 8)
	sb.add_child(sbh)
	var sbt := _label("Soundboard", sbh)
	sbt.add_theme_font_size_override("font_size", 16)
	sbt.size_flags_horizontal = SIZE_EXPAND_FILL
	if not OS.has_feature("mobile"):
		var fb := _icon_btn("folder", sbh)
		fb.tooltip_text = "Ajouter mes sons (.wav .ogg .mp3)"
		fb.pressed.connect(func() -> void:
			DirAccess.make_dir_recursive_absolute(_sounds_dir())
			OS.shell_open(_sounds_dir()))
	_icon_btn("refresh", sbh).pressed.connect(_build_board)
	var grid := GridContainer.new()
	grid.columns = 3
	grid.add_theme_constant_override("h_separation", 8)
	grid.add_theme_constant_override("v_separation", 8)
	sb.add_child(grid)
	_slider_line(sb, Icon.new("speaker", 22, C_MUTED), 0, 150, board_vol * 100.0, 80, func(x: float) -> String:
		board_vol = x / 100.0
		return "%d%%" % roundi(x))
	if bus == "Board":  # host : où envoyer la soundboard
		var dr := HBoxContainer.new()
		dr.add_theme_constant_override("separation", 8)
		sb.add_child(dr)
		var dl := _label("Envoyer vers", dr)
		dl.add_theme_color_override("font_color", C_MUTED)
		dl.add_theme_font_size_override("font_size", 13)
		dl.size_flags_horizontal = SIZE_EXPAND_FILL
		for opt in [["Jeu", "game"], ["Clients", "clients"]]:
			var t := _button(opt[0], dr)
			t.theme_type_variation = "Toggle"
			t.toggle_mode = true
			t.button_pressed = board_to_game if opt[1] == "game" else board_to_clients
			t.tooltip_text = "Micro virtuel (entendu en jeu)" if opt[1] == "game" else "Son diffusé aux clients"
			t.toggled.connect(func(on: bool) -> void:
				if opt[1] == "game":
					board_to_game = on
				else:
					board_to_clients = on
				_apply_board_route())
	board_grids.append([grid, bus])


const BOARD_SOUNDS := ["Tir", "Rafale", "Tir lointain", "Sniper", "Explosion", "Recharge",
	"Radio ON", "Radio OFF", "Grésillement", "Alerte", "Ping", "SOS"]


func _build_board() -> void:
	_make_bus("Board", [board_cap])
	_apply_board_route()
	_ensure_capture()
	var items := []
	for k in BOARD_SOUNDS:
		items.append([k, _synth(k)])
	var d := DirAccess.open(_sounds_dir())
	if d:
		for f in d.get_files():
			var path := _sounds_dir().path_join(f)
			var st: AudioStream = null
			match f.get_extension().to_lower():
				"wav": st = AudioStreamWAV.load_from_file(path)
				"ogg": st = AudioStreamOggVorbis.load_from_file(path)
				"mp3": st = AudioStreamMP3.load_from_file(path)
			if st:
				items.append([f.get_basename(), st])
	for gb in board_grids:
		var grid: GridContainer = gb[0]
		var bus: String = gb[1]
		for ch in grid.get_children():
			ch.queue_free()
		for it in items:
			var b := _button(it[0], grid)
			b.theme_type_variation = "Pad"
			b.size_flags_horizontal = SIZE_EXPAND_FILL
			b.clip_text = true
			b.tooltip_text = it[0]
			var pl := AudioStreamPlayer.new()
			pl.stream = it[1]
			pl.bus = bus
			pl.max_polyphony = 4
			b.add_child(pl)
			b.pressed.connect(func() -> void:
				pl.volume_db = linear_to_db(maxf(board_vol, 0.0001))
				pl.play()
				if bus == "Capture":  # client : garder l'envoi ouvert pendant le son
					board_until = maxf(board_until, Time.get_ticks_msec() / 1000.0 + pl.stream.get_length() + 0.3))


## Sons d'exemple générés (combat + radio), mono 16 bits 44,1 kHz.
func _synth(kind: String) -> AudioStreamWAV:
	var sr := 44100
	var out: Array[float] = []
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(kind)
	var tone := func(f: float, dur: float, amp: float) -> void:
		for i in int(dur * sr):
			var e := minf(1.0, minf(i, int(dur * sr) - i) / 220.0)
			out.append(sin(TAU * f * i / sr) * amp * e)
	var noise := func(dur: float, amp: float, fade: bool) -> void:
		var lp := 0.0
		var n := int(dur * sr)
		for i in n:
			lp += (rng.randf_range(-1, 1) - lp) * 0.35  # bruit « radio » un peu étouffé
			out.append(lp * amp * ((1.0 - float(i) / n) if fade else 1.0))
	# Détonation : bruit filtré (k = brillance) à décroissance exponentielle + coup sourd grave
	var burst := func(dur: float, amp: float, k: float, decay: float, thump: float) -> void:
		var lp := 0.0
		for i in int(dur * sr):
			var t := float(i) / sr
			lp += (rng.randf_range(-1, 1) - lp) * k
			var v := lp * amp * exp(-decay * t) * 1.6
			if thump > 0:
				v += sin(TAU * thump * t * (1.0 - t)) * amp * 0.7 * exp(-decay * 0.5 * t)
			out.append(v)
	var silence := func(dur: float) -> void:
		for i in int(dur * sr):
			out.append(0.0)
	match kind:
		"Tir":
			burst.call(0.45, 1.0, 0.55, 14.0, 95.0)
		"Rafale":
			for r in 6:
				burst.call(0.085, 0.9, 0.6, 28.0, 110.0)
			burst.call(0.35, 0.35, 0.25, 9.0, 0.0)
		"Tir lointain":
			burst.call(1.1, 0.55, 0.06, 4.5, 55.0)
		"Sniper":
			burst.call(0.12, 1.0, 0.9, 30.0, 0.0)
			burst.call(1.0, 0.3, 0.08, 3.5, 40.0)
		"Explosion":
			burst.call(2.4, 1.0, 0.045, 2.0, 38.0)
		"Recharge":
			for gap in [0.0, 0.22, 0.06, 0.35]:
				silence.call(gap)
				burst.call(0.035, 0.7, 0.95, 140.0, 0.0)
		"Radio ON":
			noise.call(0.012, 1.0, false)
			noise.call(0.22, 0.45, true)
		"Radio OFF":
			tone.call(1200.0, 0.07, 0.5)
			tone.call(1650.0, 0.09, 0.5)
			noise.call(0.18, 0.5, true)
		"Grésillement":
			noise.call(1.3, 0.4, true)
		"Alerte":
			for r in 2:
				var n := int(0.7 * sr)
				var ph := 0.0
				for i in n:
					ph += TAU * lerpf(600.0, 1250.0, float(i) / n) / sr
					out.append(signf(sin(ph)) * 0.22)
		"Ping":
			var n := int(0.9 * sr)
			for i in n:
				out.append(sin(TAU * 1400.0 * i / sr) * 0.55 * exp(-5.0 * i / sr))
		"SOS":
			for sym in "...---...":
				tone.call(800.0, 0.09 if sym == "." else 0.27, 0.45)
				silence.call(0.09)
	var data := PackedByteArray()
	data.resize(out.size() * 2)
	for i in out.size():
		data.encode_s16(i * 2, int(clampf(out[i], -1.0, 1.0) * 32767.0))
	var w := AudioStreamWAV.new()
	w.format = AudioStreamWAV.FORMAT_16_BITS
	w.mix_rate = sr
	w.stereo = false
	w.data = data
	return w


## Jeu = le bus Board sort vers le micro virtuel ; Clients = capturé et mixé au flux diffusé.
func _apply_board_route() -> void:
	var bi := AudioServer.get_bus_index("Board")
	if bi >= 0:
		AudioServer.set_bus_mute(bi, not board_to_game)  # la capture marche même bus coupé


func _board_frames() -> PackedVector2Array:
	if not board_to_clients:
		board_cap.clear_buffer()
		return PackedVector2Array()
	var av := board_cap.get_frames_available()
	if av > FRAMES_PER_PACKET * 3:
		board_cap.get_buffer(av - FRAMES_PER_PACKET)  # retard accumulé : on le jette
	return board_cap.get_buffer(mini(FRAMES_PER_PACKET, board_cap.get_frames_available()))
