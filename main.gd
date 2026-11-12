extends Control
## Sound Link : le host capture une source audio (ex. « Monitor of ... » = sortie du PC)
## et l'envoie en UDP (PCM 16 bits stéréo) aux clients, qui règlent volume et balance.
## Un client (ex. téléphone) peut renvoyer son micro (PCM 16 bits mono, préfixe "MIC1") :
## le host le joue dans le micro virtuel « Sound-Link-Micro » créé par sound-link.sh.

const FRAMES_PER_PACKET := 480
const TIMEOUT := 3.0
const MAX_QUEUE := 8
const PREBUFFER := 4
const CFG_PATH := "user://settings.cfg"
const SND_TAG := "SND1"  # flux « son » : SND1 + seq u32 + rate u32 + PCM s16 stéréo
const MIC_TAG := "MIC1"  # flux « micro » : MIC1 + seq u32 + rate u32 + PCM s16 mono
const VSINK := "soundlink_sink"
const VERSION: String = preload("res://version.gd").VERSION
const UPDATE_URL := "https://github.com/goodview-soft/sound-link/releases/latest/download/version.json"
const BEACON := "SL3"  # SL3|id|port|flags|nom  (flags : son, micro)
const RELEASES_URL := "https://github.com/goodview-soft/sound-link/releases/latest"
const CHECK_UPDATES := true  # mettre false pour ignorer les mises à jour

var data_port := 4242
var disc_port := 4243
var udp := PacketPeerUDP.new()
var disc := PacketPeerUDP.new()
var cfg := ConfigFile.new()
var my_id := ""
var peers := {}  # id -> {ip, port, snd, mic, name, t}
var listening := {}  # id -> true : appareils que j'écoute
var subs := {}  # "ip:port" -> {ip, port, t} : appareils qui m'écoutent
var rxs := {}  # "ip:port" -> {snd: RxStream, mic: RxStream, bus, bus_name}
var peers_sig := ""
var peer_cfg := {}  # id appareil -> {vol, bal, mute} (mémorisé)
var beacon_t := 0.0
var sub_t := 0.0
var vsink_exists := false

# Capture locale : une seule à la fois (« snd » = sortie du PC, « mic » = micro)
var capture: AudioEffectCapture
var mic_player: AudioStreamPlayer
var cap_kind := ""
var seq := 0
var host_gain := 1.0
var mic_gain := 1.0
var volume := 1.0
var balance := 0.0
var muted := false
var bus_id := 0
var level_l := 0.0
var level_r := 0.0

const C_BG := Color("#0c0d12")
const C_CARD := Color("#14161e")
const C_FIELD := Color("#10131a")
const C_BORDER := Color("#262b37")
const C_ACCENT := Color("#ffb347")
const C_ACCENT2 := Color("#ffd58a")
const C_TEXT := Color("#e7eaf0")
const C_MUTED := Color("#7d8497")
const C_OK := Color("#5eead4")
const C_DANGER := Color("#f87171")
var dev_opt: OptionButton
var mic_opt: OptionButton
var vsink_lbl: Label
var ip_edit: LineEdit
var name_edit: LineEdit
var bal_slider: HSlider
var meter: SpeakerHero
var pill_dot: Label
var pill_txt: Label
var sw_snd: Switch
var sw_mic: Switch
var upd_card: PanelContainer
var main_margin: MarginContainer
var drawer: Control
var drawer_margin: MarginContainer
var upd_dot: Label
var list_title: Label
var found_lbl: Label
var found_list: VBoxContainer
var hero_name: Label
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
			var base := Color("#ffd58a").lerp(Color("#ffb347"), t) if t < 0.6 else Color("#ffb347").lerp(Color("#ff7a59"), (t - 0.6) / 0.4)
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


class Switch extends Control:
	## Interrupteur animé.
	signal toggled(on: bool)
	var on := false
	var k := 0.0

	func _init() -> void:
		custom_minimum_size = Vector2(56, 32)
		size_flags_vertical = SIZE_SHRINK_CENTER

	func set_on(v: bool) -> void:
		on = v

	func _gui_input(ev: InputEvent) -> void:
		if ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_LEFT:
			on = not on
			toggled.emit(on)
			accept_event()

	func _process(d: float) -> void:
		var t := 1.0 if on else 0.0
		if absf(k - t) > 0.001:
			k = move_toward(k, t, d * 8.0)
			queue_redraw()

	func _draw() -> void:
		var sb := StyleBoxFlat.new()
		sb.bg_color = Color("#2a2e3b").lerp(Color("#ffb347"), k)
		sb.set_corner_radius_all(16)
		sb.anti_aliasing = true
		draw_style_box(sb, Rect2(Vector2.ZERO, size))
		draw_circle(Vector2(16 + k * (size.x - 32), size.y / 2.0), 12, Color("#f4efe6") if on else Color("#9aa1b3"))


class Ico extends Control:
	## Icône dessinée, cliquable : "vol" (haut-parleur), "mute" (barré, bascule), "center" (recentrer).
	signal pressed
	signal toggled(on: bool)
	var kind := "vol"
	var on := false  # pour "mute" : coupé

	func _init(k: String, clickable := false, sz := 32.0) -> void:
		kind = k
		custom_minimum_size = Vector2(sz, sz)
		size_flags_vertical = SIZE_SHRINK_CENTER
		mouse_filter = MOUSE_FILTER_STOP if clickable else MOUSE_FILTER_IGNORE

	func set_on(v: bool) -> void:
		on = v
		queue_redraw()

	func _gui_input(ev: InputEvent) -> void:
		if ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_LEFT:
			if kind == "mute":
				on = not on
				toggled.emit(on)
				queue_redraw()
			else:
				pressed.emit()
			accept_event()

	func _draw() -> void:
		var c := size / 2.0
		var fg := Color("#7d8497")
		if kind == "mute":
			fg = Color("#ffb347") if on else Color("#7d8497")
		if kind == "center":
			draw_arc(c, 6, 0, TAU, 20, fg, 2.0, true)
			draw_line(c + Vector2(0, -10), c + Vector2(0, -6), fg, 2.0)
			draw_line(c + Vector2(0, 6), c + Vector2(0, 10), fg, 2.0)
			return
		draw_colored_polygon(PackedVector2Array([c + Vector2(-9, -3.5), c + Vector2(-5, -3.5), c + Vector2(0, -8),
			c + Vector2(0, 8), c + Vector2(-5, 3.5), c + Vector2(-9, 3.5)]), fg)
		if kind == "mute" and on:
			draw_line(c + Vector2(4, -4), c + Vector2(10, 4), fg, 2.0)
			draw_line(c + Vector2(10, -4), c + Vector2(4, 4), fg, 2.0)
		else:
			draw_arc(c, 6, -0.9, 0.9, 10, fg, 2.0, true)
			draw_arc(c, 10, -0.9, 0.9, 10, Color(fg, 0.6), 2.0, true)


class SpeakerHero extends Control:
	## Haut-parleur central : disque + anneaux qui suivent le niveau sonore.
	var level := 0.0
	var shown := 0.0
	var kind := 1  # 1 ordinateur, 2 téléphone
	var state := 0  # 0 arrêté, 1 connexion, 2 actif
	var t := 0.0

	func _init() -> void:
		custom_minimum_size.y = 144
		size_flags_horizontal = SIZE_EXPAND_FILL

	func set_levels(a: float, b: float) -> void:
		level = maxf(a, b)

	func _process(d: float) -> void:
		t += d
		shown = lerpf(shown, level if state == 2 else 0.0, minf(1.0, d * 12.0))
		queue_redraw()

	func _draw() -> void:
		var c := size / 2.0
		var on := state == 2
		var col := Color("#ffb347") if state > 0 else Color("#4a5063")
		var base := 34.0
		for i in 3:
			var r := base + 8.0 + i * 8.0 + shown * 4.0 * (i + 1) + (sin(t * 1.5 + i * 1.3) * 2.0 if state > 0 else 0.0)
			var a := (0.34 - i * 0.09) * (1.0 if on else 0.45)
			draw_arc(c, r, 0, TAU, 72, Color(col, a), 2.0, true)
		draw_circle(c, base, Color("#161821"))
		draw_arc(c, base, 0, TAU, 72, Color(col, 0.95 if on else 0.4), 2.0, true)
		var fg := Color("#f4efe6") if state > 0 else Color("#7d8497")
		draw_set_transform(c, 0.0, Vector2(0.62, 0.62))
		c = Vector2.ZERO
		if kind == 2:
			draw_rect(Rect2(c + Vector2(-14, -22), Vector2(28, 44)), fg, false, 3.0)
			draw_circle(c + Vector2(0, 15), 2.2, fg)
			return
		if kind == 1:
			draw_rect(Rect2(c + Vector2(-24, -20), Vector2(48, 31)), fg)
			draw_rect(Rect2(c + Vector2(-20, -16), Vector2(40, 23)), Color("#161821"))
			draw_rect(Rect2(c + Vector2(-3, 11), Vector2(6, 8)), fg)
			draw_rect(Rect2(c + Vector2(-12, 19), Vector2(24, 3)), fg)
			return
		draw_colored_polygon(PackedVector2Array([c + Vector2(-22, -9), c + Vector2(-10, -9), c + Vector2(6, -21),
			c + Vector2(6, 21), c + Vector2(-10, 9), c + Vector2(-22, 9)]), fg)
		draw_arc(c + Vector2(6, 0), 12, -0.85, 0.85, 12, fg, 2.6, true)
		draw_arc(c + Vector2(6, 0), 21, -0.85, 0.85, 12, Color(fg, 0.55), 2.6, true)


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
	if OS.get_environment("SL_PORT") != "":
		data_port = OS.get_environment("SL_PORT").to_int()
	if OS.get_environment("SL_DISC") != "":
		disc_port = OS.get_environment("SL_DISC").to_int()
	host_gain = cfg.get_value("share", "gain", 1.0)
	mic_gain = cfg.get_value("share", "mic_gain", 1.0)
	volume = cfg.get_value("listen", "volume", 1.0)
	balance = cfg.get_value("listen", "balance", 0.0)
	my_id = cfg.get_value("app", "id", "")
	if my_id == "":
		my_id = str(randi())
	peer_cfg = cfg.get_value("peers", "cfg", {})
	_build_ui()
	if not OS.has_feature("mobile"):
		get_window().min_size = Vector2i(400, 680)
	_refresh_devices()
	if udp.bind(data_port) != OK:
		pill_txt.text = "Port %d indisponible" % data_port
	vsink_exists = VSINK in AudioServer.get_output_device_list()
	_check_update()


func _exit_tree() -> void:
	for id in listening.keys():
		_unlisten(id)
	_stop_capture()
	for k in rxs.keys():
		_free_rx(k)
	if AudioServer.output_device == VSINK:
		AudioServer.output_device = "Default"
	_save()


func _save() -> void:
	cfg.set_value("share", "gain", host_gain)
	cfg.set_value("share", "mic_gain", mic_gain)
	cfg.set_value("listen", "volume", volume)
	cfg.set_value("listen", "balance", balance)
	cfg.set_value("app", "id", my_id)
	cfg.set_value("peers", "cfg", peer_cfg)
	cfg.set_value("app", "ip", ip_edit.text)
	cfg.set_value("app", "name", name_edit.text)
	if dev_opt.selected >= 0:
		cfg.set_value("share", "device", dev_opt.get_item_text(dev_opt.selected))
	if mic_opt.selected >= 0:
		cfg.set_value("share", "mic_device", mic_opt.get_item_text(mic_opt.selected))
	cfg.save(CFG_PATH)


# ---------------------------------------------------------------- UI

func _build_ui() -> void:
	var mobile := OS.has_feature("mobile")
	theme = _make_theme()
	var bg := ColorRect.new()
	bg.color = C_BG
	bg.set_anchors_preset(PRESET_FULL_RECT)
	add_child(bg)
	main_margin = MarginContainer.new()
	main_margin.set_anchors_preset(PRESET_FULL_RECT)
	main_margin.add_theme_constant_override("margin_top", 16)
	main_margin.add_theme_constant_override("margin_bottom", 24)
	add_child(main_margin)
	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 16)
	main_margin.add_child(root)

	# --- Barre du haut : nom de l'appli, réglages
	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", 8)
	root.add_child(bar)
	var title := _label("Sound Link", bar)
	title.add_theme_font_size_override("font_size", 16)
	title.size_flags_horizontal = SIZE_EXPAND_FILL
	title.size_flags_vertical = SIZE_SHRINK_CENTER
	upd_dot = _label("●", bar)
	upd_dot.add_theme_font_size_override("font_size", 10)
	upd_dot.add_theme_color_override("font_color", C_ACCENT)
	upd_dot.size_flags_vertical = SIZE_SHRINK_CENTER
	upd_dot.visible = false
	var gear := _button("⚙", bar)
	gear.theme_type_variation = "Ghost"
	gear.custom_minimum_size = Vector2(40, 40)
	gear.pressed.connect(_open_drawer.bind(true))

	# --- Mon appareil
	var me := VBoxContainer.new()
	me.add_theme_constant_override("separation", 0)
	root.add_child(me)
	var hero := SpeakerHero.new()
	hero.kind = 2 if mobile else 1
	meter = hero
	me.add_child(hero)
	hero_name = _label("", me)
	hero_name.add_theme_font_size_override("font_size", 24)
	hero_name.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hero_name.clip_text = true
	var st := HBoxContainer.new()
	st.alignment = BoxContainer.ALIGNMENT_CENTER
	st.add_theme_constant_override("separation", 8)
	me.add_child(st)
	pill_dot = _label("●", st)
	pill_dot.add_theme_font_size_override("font_size", 10)
	pill_dot.size_flags_vertical = SIZE_SHRINK_CENTER
	pill_txt = _label("", st)
	pill_txt.add_theme_color_override("font_color", C_MUTED)

	# --- Ce que je partage (tout est coupé au démarrage)
	var card := PanelContainer.new()
	root.add_child(card)
	var cv := _vbox(card, 16)
	if not mobile:
		sw_snd = _switch_row(cv, "Partager mon son")
		sw_snd.toggled.connect(func(on: bool) -> void: _on_share("snd", on))
	sw_mic = _switch_row(cv, "Partager mon micro")
	sw_mic.toggled.connect(func(on: bool) -> void: _on_share("mic", on))

	# --- Appareils à proximité
	list_title = _hint("Appareils à proximité", root)
	var ls := ScrollContainer.new()
	ls.size_flags_vertical = SIZE_EXPAND_FILL
	ls.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	root.add_child(ls)
	var lb := VBoxContainer.new()
	lb.size_flags_horizontal = SIZE_EXPAND_FILL
	lb.add_theme_constant_override("separation", 0)
	ls.add_child(lb)
	found_lbl = _hint("", lb)
	found_list = VBoxContainer.new()
	found_list.add_theme_constant_override("separation", 0)
	lb.add_child(found_list)

	# --- Tiroir de réglages
	drawer = Control.new()
	drawer.set_anchors_preset(PRESET_FULL_RECT)
	drawer.visible = false
	add_child(drawer)
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.6)
	dim.set_anchors_preset(PRESET_FULL_RECT)
	dim.gui_input.connect(func(ev: InputEvent) -> void:
		if ev is InputEventMouseButton and ev.pressed:
			_open_drawer(false))
	drawer.add_child(dim)
	drawer_margin = MarginContainer.new()
	drawer_margin.set_anchors_preset(PRESET_FULL_RECT)
	drawer_margin.mouse_filter = MOUSE_FILTER_IGNORE
	drawer_margin.add_theme_constant_override("margin_top", 64)
	drawer.add_child(drawer_margin)
	var sheet := PanelContainer.new()
	sheet.add_theme_stylebox_override("panel", _sb(C_CARD, 24, 24, 24))
	drawer_margin.add_child(sheet)
	var sv := VBoxContainer.new()
	sv.add_theme_constant_override("separation", 16)
	sheet.add_child(sv)
	var sh := HBoxContainer.new()
	sv.add_child(sh)
	var stt := _label("Réglages", sh)
	stt.add_theme_font_size_override("font_size", 20)
	stt.size_flags_horizontal = SIZE_EXPAND_FILL
	var cl := _button("✕", sh)
	cl.theme_type_variation = "Ghost"
	cl.pressed.connect(_open_drawer.bind(false))
	var sc := ScrollContainer.new()
	sc.size_flags_vertical = SIZE_EXPAND_FILL
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	sv.add_child(sc)
	var gs := _vbox(sc, 24)
	gs.size_flags_horizontal = SIZE_EXPAND_FILL

	var g0 := _vbox(gs, 8)
	_hint("Nom de cet appareil", g0)
	name_edit = LineEdit.new()
	var saved_name: String = cfg.get_value("app", "name", "")
	name_edit.text = "" if saved_name.is_valid_ip_address() else saved_name
	if name_edit.text == "":
		name_edit.text = _device_name()
	g0.add_child(name_edit)

	var gsh := _vbox(gs, 16)
	_hint("Ce que je partage", gsh)
	if not mobile:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		gsh.add_child(row)
		dev_opt = OptionButton.new()
		dev_opt.size_flags_horizontal = SIZE_EXPAND_FILL
		dev_opt.clip_text = true
		row.add_child(dev_opt)
		_button("↻", row).pressed.connect(_refresh_devices)
		_slider_row(gsh, "Gain du son", 0, 200, host_gain * 100.0, func(x: float) -> String:
			host_gain = x / 100.0
			return "%d %%" % roundi(x))
		mic_opt = OptionButton.new()
		mic_opt.clip_text = true
		gsh.add_child(mic_opt)
	else:
		dev_opt = OptionButton.new()  # inutilisé sur téléphone
		mic_opt = OptionButton.new()
	_slider_row(gsh, "Gain du micro", 0, 300, mic_gain * 100.0, func(x: float) -> String:
		mic_gain = x / 100.0
		return "%d %%" % roundi(x))

	var gl := _vbox(gs, 16)
	_hint("Ce que j'écoute", gl)
	_slider_row(gl, "Volume", 0, 150, volume * 100.0, func(x: float) -> String:
		volume = x / 100.0
		return "%d %%" % roundi(x))
	bal_slider = _slider_row(gl, "Balance", -100, 100, balance * 100.0, func(x: float) -> String:
		balance = x / 100.0
		return "centre" if absf(x) < 1 else "%s %d %%" % ["D" if x > 0 else "G", roundi(absf(x))])
	var brow := HBoxContainer.new()
	gl.add_child(brow)
	var mute := CheckButton.new()
	mute.text = "Muet"
	mute.size_flags_horizontal = SIZE_EXPAND_FILL
	mute.toggled.connect(func(on: bool) -> void: muted = on)
	brow.add_child(mute)
	_button("Centrer", brow).pressed.connect(func() -> void: bal_slider.value = 0)
	vsink_lbl = _hint("", gl)

	var gi := _vbox(gs, 8)
	_hint("Adresse d'un appareil non détecté", gi)
	ip_edit = LineEdit.new()
	ip_edit.placeholder_text = "192.168.1.x"
	ip_edit.text = cfg.get_value("app", "ip", "")
	gi.add_child(ip_edit)
	if not mobile:
		var qh := HBoxContainer.new()
		qh.add_theme_constant_override("separation", 16)
		gs.add_child(qh)
		var qr := TextureRect.new()
		qr.texture = load("res://qr_apk.svg")
		qr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		qr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		qr.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		qr.custom_minimum_size = Vector2(88, 88)
		qh.add_child(qr)
		var qv := _hint("Appli Android", qh)
		qv.size_flags_vertical = SIZE_SHRINK_CENTER
		qv.autowrap_mode = TextServer.AUTOWRAP_OFF

	# Version et mise à jour
	upd_card = PanelContainer.new()
	upd_card.add_theme_stylebox_override("panel", _sb(Color(0, 0, 0, 0), 0, 0, 0))
	gs.add_child(upd_card)
	var uh := HBoxContainer.new()
	upd_card.add_child(uh)
	upd_lbl = _hint("", uh)
	upd_lbl.size_flags_horizontal = SIZE_EXPAND_FILL
	upd_lbl.size_flags_vertical = SIZE_SHRINK_CENTER
	upd_btn = _button("Mettre à jour", uh)
	upd_btn.theme_type_variation = "Tab"
	upd_btn.toggle_mode = false
	upd_btn.pressed.connect(_do_update)
	get_tree().root.size_changed.connect(_fit)
	_fit()


## Ligne « titre ........ interrupteur » ; renvoie l'interrupteur.
func _switch_row(parent: Node, text: String) -> Switch:
	var r := HBoxContainer.new()
	parent.add_child(r)
	var l := _label(text, r)
	l.add_theme_font_size_override("font_size", 17)
	l.size_flags_horizontal = SIZE_EXPAND_FILL
	l.size_flags_vertical = SIZE_SHRINK_CENTER
	var sw := Switch.new()
	r.add_child(sw)
	return sw


func _open_drawer(on: bool) -> void:
	drawer.visible = on
	if on:
		drawer.modulate.a = 0.0
		create_tween().tween_property(drawer, "modulate:a", 1.0, 0.15)
	else:
		_save()


## Colonne de 420 px max centrée sur PC, pleine largeur sur téléphone.
func _fit() -> void:
	if main_margin:
		var side := maxf(24.0, (get_viewport_rect().size.x - 420.0) / 2.0)
		main_margin.add_theme_constant_override("margin_left", int(side))
		main_margin.add_theme_constant_override("margin_right", int(side))
		drawer_margin.add_theme_constant_override("margin_left", int(maxf(0.0, side - 24.0)))
		drawer_margin.add_theme_constant_override("margin_right", int(maxf(0.0, side - 24.0)))


func _vbox(parent: Node, sep := 16) -> VBoxContainer:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", sep)
	parent.add_child(v)
	return v


func _device_name() -> String:
	var n := ""
	if OS.get_name() == "Android":
		n = OS.get_model_name()
	for k in ["HOSTNAME", "HOST", "COMPUTERNAME"]:
		if n == "":
			n = OS.get_environment(k)
	if n == "" and FileAccess.file_exists("/etc/hostname"):
		n = FileAccess.get_file_as_string("/etc/hostname").strip_edges()
	if n == "":
		var out := []
		if OS.execute("hostname", [], out) == 0 and out.size() > 0:
			n = str(out[0]).strip_edges()
	if n == "":
		n = OS.get_model_name()
	return n if n != "" and n != "GenericDevice" and not n.is_valid_ip_address() else "Mon appareil"


func _make_theme() -> Theme:
	var t := Theme.new()
	var f := SystemFont.new()
	f.font_names = PackedStringArray(["Inter", "Cantarell", "Noto Sans", "Ubuntu", "DejaVu Sans"])
	t.default_font = f
	t.default_font_size = 15
	t.set_color("font_color", "Label", C_TEXT)

	var bn := _sb(Color("#222735"), 12, 16, 8)
	var bh := _sb(Color("#2b3142"), 12, 16, 8)
	var bp := _sb(Color("#1b1f2a"), 12, 16, 8)
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
	t.set_stylebox("normal", "Tab", _sb(Color(0, 0, 0, 0), 12, 16, 8))
	t.set_stylebox("hover", "Tab", _sb(Color("#1d2230"), 12, 16, 8))
	t.set_stylebox("pressed", "Tab", _sb(C_ACCENT, 12, 16, 8))
	t.set_stylebox("hover_pressed", "Tab", _sb(C_ACCENT.lightened(0.08), 12, 16, 8))
	t.set_color("font_color", "Tab", C_MUTED)
	t.set_color("font_pressed_color", "Tab", Color("#1a1205"))
	t.set_color("font_hover_pressed_color", "Tab", Color("#1a1205"))

	# Segments, lignes de liste, boutons discrets
	t.set_type_variation("Seg", "Button")
	t.set_stylebox("normal", "Seg", _sb(Color(0, 0, 0, 0), 24, 24, 8))
	t.set_stylebox("hover", "Seg", _sb(Color("#1b1e29"), 24, 24, 8))
	t.set_stylebox("pressed", "Seg", _sb(Color("#2a2e3b"), 24, 24, 8))
	t.set_stylebox("hover_pressed", "Seg", _sb(Color("#2a2e3b"), 24, 24, 8))
	t.set_color("font_color", "Seg", C_MUTED)
	t.set_color("font_hover_color", "Seg", C_TEXT)
	t.set_color("font_pressed_color", "Seg", Color.WHITE)
	t.set_color("font_hover_pressed_color", "Seg", Color.WHITE)
	t.set_type_variation("Row", "Button")
	t.set_stylebox("normal", "Row", _sb(Color(0, 0, 0, 0), 12, 0, 0))
	t.set_stylebox("hover", "Row", _sb(Color("#171a24"), 12, 0, 0))
	t.set_stylebox("pressed", "Row", _sb(Color("#1d2130"), 12, 0, 0))
	t.set_stylebox("hover_pressed", "Row", _sb(Color("#1d2130"), 12, 0, 0))
	t.set_stylebox("disabled", "Row", _sb(Color(0, 0, 0, 0), 12, 0, 0))
	t.set_type_variation("Ghost", "Button")
	t.set_stylebox("normal", "Ghost", _sb(Color(0, 0, 0, 0), 20, 8, 4))
	t.set_stylebox("hover", "Ghost", _sb(Color("#1b1e29"), 20, 8, 4))
	t.set_stylebox("pressed", "Ghost", _sb(Color("#232733"), 20, 8, 4))
	t.set_font_size("font_size", "Ghost", 20)
	t.set_color("font_color", "Ghost", C_MUTED)

	# Bouton principal / bouton d'arrêt
	t.set_type_variation("Primary", "Button")
	t.set_stylebox("normal", "Primary", _sb(C_ACCENT, 28, 24, 16))
	t.set_stylebox("hover", "Primary", _sb(C_ACCENT.lightened(0.1), 28, 24, 16))
	t.set_stylebox("pressed", "Primary", _sb(C_ACCENT.darkened(0.15), 28, 24, 16))
	t.set_color("font_color", "Primary", Color("#1a1205"))
	t.set_color("font_hover_color", "Primary", Color("#1a1205"))
	t.set_font_size("font_size", "Primary", 16)
	t.set_type_variation("Danger", "Button")
	t.set_stylebox("normal", "Danger", _sb(Color("#3a1f26"), 28, 24, 16, C_DANGER))
	t.set_stylebox("hover", "Danger", _sb(Color("#4a2430"), 28, 24, 16, C_DANGER))
	t.set_stylebox("pressed", "Danger", _sb(Color("#2c171c"), 28, 24, 16, C_DANGER))
	t.set_color("font_color", "Danger", C_DANGER)
	t.set_color("font_hover_color", "Danger", Color("#fecaca"))
	t.set_font_size("font_size", "Danger", 16)

	# Cartes de mode (accueil)
	t.set_type_variation("ModeCard", "Button")
	t.set_stylebox("normal", "ModeCard", _sb(C_CARD, 14, 16, 14, C_BORDER))
	t.set_stylebox("hover", "ModeCard", _sb(Color("#1d2130"), 14, 16, 14, C_ACCENT))
	t.set_stylebox("pressed", "ModeCard", _sb(Color("#2a2113"), 14, 16, 14, C_ACCENT))
	t.set_stylebox("hover_pressed", "ModeCard", _sb(Color("#2a2113"), 14, 16, 14, C_ACCENT))

	# Champs texte
	t.set_stylebox("normal", "LineEdit", _sb(C_FIELD, 12, 16, 8, C_BORDER))
	t.set_stylebox("focus", "LineEdit", _sb(C_FIELD, 12, 16, 8, C_ACCENT))
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
	t.set_stylebox("panel", "PanelContainer", _sb(C_CARD, 16, 16, 16))
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
	v.add_theme_constant_override("separation", 12)
	p.add_child(v)
	if title != "":
		var l := _label(title, v)
		l.add_theme_font_size_override("font_size", 13)
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


func _refresh_devices() -> void:
	if OS.has_feature("mobile"):
		return
	var saved: String = cfg.get_value("share", "device", "")
	var saved_mic: String = cfg.get_value("share", "mic_device", "")
	if dev_opt.selected >= 0:
		saved = dev_opt.get_item_text(dev_opt.selected)
	if mic_opt.selected >= 0:
		saved_mic = mic_opt.get_item_text(mic_opt.selected)
	dev_opt.clear()
	mic_opt.clear()
	var pick := -1
	var pick_mic := -1
	for d in AudioServer.get_input_device_list():
		dev_opt.add_item(d)
		mic_opt.add_item(d)
		var i := dev_opt.item_count - 1
		var mon := d.to_lower().contains("monitor")
		# Son partagé : le moniteur de la sortie (PULSE_SOURCE via sound-link.sh = « Default »)
		if d == saved:
			pick = i
		elif pick == -1 and saved == "" and mon:
			pick = i
		# Micro : un vrai micro, jamais un moniteur ni « Default » (= moniteur ici)
		if d == saved_mic:
			pick_mic = i
		elif pick_mic == -1 and saved_mic == "" and not mon and d != "Default":
			pick_mic = i
	dev_opt.select(maxi(pick, 0))
	mic_opt.select(maxi(pick_mic, 0))


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


# ---------------------------------------------------------------- Partage (ce que j'envoie)

## Une seule capture à la fois : son de l'appareil (PC) ou micro.
func _on_share(kind: String, on: bool) -> void:
	if not on:
		if cap_kind == kind:
			_stop_capture()
			cap_kind = ""
		return
	var other: Switch = sw_mic if kind == "snd" else sw_snd
	if other:
		other.set_on(false)
	_stop_capture()
	var dev := "Default"
	if not OS.has_feature("mobile"):
		var opt := dev_opt if kind == "snd" else mic_opt
		if opt.selected >= 0:
			dev = opt.get_item_text(opt.selected)
	cap_kind = kind
	seq = 0
	_start_capture(dev)


## Envoie ce qui est capturé aux appareils qui m'écoutent ; renvoie les crêtes (L, R).
func _share_process(now: float) -> Vector2:
	for k in subs.keys():
		if now - subs[k]["t"] > TIMEOUT:
			subs.erase(k)
	if mic_player == null or cap_kind == "":
		return Vector2.ZERO
	var rate := int(AudioServer.get_mix_rate())
	var pl := 0.0
	var pr := 0.0
	while capture.get_frames_available() >= FRAMES_PER_PACKET:
		var frames := capture.get_buffer(FRAMES_PER_PACKET)
		var snd := cap_kind == "snd"
		var pkt := (SND_TAG if snd else MIC_TAG).to_ascii_buffer()
		pkt.resize(12 + FRAMES_PER_PACKET * (4 if snd else 2))
		pkt.encode_u32(4, seq)
		pkt.encode_u32(8, rate)
		seq = (seq + 1) & 0xFFFFFFFF
		var o := 12
		for f in frames:
			if snd:
				var l := clampf(f.x * host_gain, -1.0, 1.0)
				var r := clampf(f.y * host_gain, -1.0, 1.0)
				pl = maxf(pl, absf(l))
				pr = maxf(pr, absf(r))
				pkt.encode_s16(o, int(l * 32767.0))
				pkt.encode_s16(o + 2, int(r * 32767.0))
				o += 4
			else:
				var m := clampf((f.x + f.y) * 0.5 * mic_gain, -1.0, 1.0)
				pl = maxf(pl, absf(m))
				pkt.encode_s16(o, int(m * 32767.0))
				o += 2
		for s in subs.values():
			udp.set_dest_address(s["ip"], s["port"])
			udp.put_packet(pkt)
	return Vector2(pl, maxf(pl, pr))


# ---------------------------------------------------------------- Écoute (ce que je reçois)

func _listened(ip: String, port: int) -> bool:
	for id in listening:
		var p: Dictionary = peers.get(id, {})
		if not p.is_empty() and p["ip"] == ip and p["port"] == port:
			return true
	return false


## Réglages d'un appareil écouté : volume, balance (-1 G .. +1 D), muet.
func _pcfg(id: String) -> Dictionary:
	if not peer_cfg.has(id):
		peer_cfg[id] = {"vol": 1.0, "bal": 0.0, "mute": false}
	return peer_cfg[id]


func _id_for_key(key: String) -> String:
	for id in listening:
		var p: Dictionary = peers.get(id, {})
		if not p.is_empty() and "%s:%d" % [p["ip"], p["port"]] == key:
			return id
	return ""


func _toggle_listen(id: String) -> void:
	if listening.has(id):
		_unlisten(id)
		listening.erase(id)
	else:
		listening[id] = true
		sub_t = 0.0
	peers_sig = ""


func _unlisten(id: String) -> void:
	var p: Dictionary = peers.get(id, {})
	if p.is_empty():
		return
	udp.set_dest_address(p["ip"], p["port"])
	udp.put_packet("BYE".to_ascii_buffer())
	_free_rx("%s:%d" % [p["ip"], p["port"]])


func _free_rx(key: String) -> void:
	var e: Dictionary = rxs.get(key, {})
	if e.is_empty():
		return
	for t in ["snd", "mic"]:
		if e[t]:
			e[t].free_player()
	if e["bus"] != "":
		_remove_bus(e["bus"])
	rxs.erase(key)


## Réception réseau : abonnements (SUB/BYE) et flux audio des appareils écoutés.
func _recv_process(now: float) -> void:
	while udp.get_available_packet_count() > 0:
		var pkt := udp.get_packet()
		var ip := udp.get_packet_ip()
		var port := udp.get_packet_port()
		var key := "%s:%d" % [ip, port]
		if pkt.size() > 12:
			var tag := pkt.slice(0, 4).get_string_from_ascii()
			if tag == SND_TAG or tag == MIC_TAG:
				if not _listened(ip, port):
					continue
				if not rxs.has(key):
					rxs[key] = {"snd": null, "mic": null, "bus": ""}
				var e: Dictionary = rxs[key]
				if tag == SND_TAG:
					if e["snd"] == null:
						e["snd"] = RxStream.new(self, true, 4)
					e["snd"].receive(pkt, now)
				else:
					if e["mic"] == null:
						bus_id += 1
						e["bus"] = "Mic%d" % bus_id
						AudioServer.set_bus_mute(_make_bus(e["bus"], []), true)  # jamais sur les enceintes
						e["mic"] = RxStream.new(self, false, 4, e["bus"])
					e["mic"].receive(pkt, now)
				continue
		var msg := pkt.get_string_from_utf8()
		if msg.begins_with("SUB|"):
			subs[key] = {"ip": ip, "port": port, "t": now}
		elif msg == "BYE":
			subs.erase(key)


## Joue les flux reçus. Le micro reçu va UNIQUEMENT dans le micro virtuel (sortie = soundlink_sink) ;
## le son reçu est joué sur la sortie par défaut, et coupé tant que la sortie est le micro virtuel.
func _play_process(now: float) -> Vector2:
	var any_mic := false
	for k in rxs.keys():
		var e: Dictionary = rxs[k]
		var last := -100.0
		for t in ["snd", "mic"]:
			if e[t]:
				last = maxf(last, e[t].last_rx)
		if now - last > TIMEOUT:
			_free_rx(k)
		elif e["mic"] and now - e["mic"].last_rx < 1.0:
			any_mic = true
	var want_v := vsink_exists and any_mic
	var in_v := AudioServer.output_device == VSINK
	if want_v and not in_v:
		AudioServer.output_device = VSINK
	elif not want_v and in_v:
		for e in rxs.values():
			if e["bus"] != "":
				AudioServer.set_bus_mute(AudioServer.get_bus_index(e["bus"]), true)
		AudioServer.output_device = "Default"
	in_v = AudioServer.output_device == VSINK
	var peak := Vector2.ZERO
	for key in rxs.keys():
		var e: Dictionary = rxs[key]
		var pc := _pcfg(_id_for_key(key))
		var pv: float = pc["vol"] * pc["vol"] / 32768.0  # courbe perceptive
		var pb: float = pc["bal"]
		if e["snd"]:
			var gl := 0.0
			var gr := 0.0
			if not muted and not pc["mute"] and not in_v:
				var bl := clampf(balance + pb, -1.0, 1.0)
				var v := volume * volume * pv
				gl = v * minf(1.0, 1.0 - bl)
				gr = v * minf(1.0, 1.0 + bl)
			peak = peak.max(e["snd"].pump(gl, gr))
		if e["mic"]:
			# un lecteur + un bus par pair, mixés dans la sortie soundlink_sink ; balance par pair
			AudioServer.set_bus_mute(AudioServer.get_bus_index(e["bus"]), not in_v)
			var mv := 0.0 if pc["mute"] else pv
			e["mic"].pump(mv * minf(1.0, 1.0 - pb), mv * minf(1.0, 1.0 + pb))
	return peak


func _subscribe_process(delta: float) -> void:
	sub_t -= delta
	if sub_t > 0.0:
		return
	sub_t = 1.0
	for id in listening:
		var p: Dictionary = peers.get(id, {})
		if not p.is_empty():
			udp.set_dest_address(p["ip"], p["port"])
			udp.put_packet(("SUB|%s" % my_id).to_utf8_buffer())


# ---------------------------------------------------------------- Boucle

func _process(delta: float) -> void:
	var now := Time.get_ticks_msec() / 1000.0
	_recv_process(now)
	var peaks := _share_process(now).max(_play_process(now))
	_subscribe_process(delta)
	level_l = maxf(level_l * 0.88, peaks.x)
	level_r = maxf(level_r * 0.88, peaks.y)
	meter.set_levels(sqrt(level_l), sqrt(level_r))
	_discovery(now, delta)
	_update_status(now)


func _update_status(now: float) -> void:
	var receiving := false
	for e in rxs.values():
		for t in ["snd", "mic"]:
			if e[t] and now - e[t].last_rx < 1.0:
				receiving = true
	var sharing := cap_kind != ""
	meter.state = 2 if (sharing or receiving) else (1 if not listening.is_empty() else 0)
	pill_dot.add_theme_color_override("font_color", C_OK if meter.state == 2 else (Color("#fbbf24") if meter.state == 1 else C_MUTED))
	var txt := "Rien n'est partagé"
	if sharing:
		txt = "Partage mon " + ("son" if cap_kind == "snd" else "micro")
	if receiving:
		txt = ("J'écoute" if not sharing else txt + ", j'écoute")
	pill_txt.text = txt
	hero_name.text = _my_name()
	vsink_lbl.text = "Micros reçus : uniquement dans « Sound-Link-Micro »." if vsink_exists \
		else "Micro virtuel absent (sound-link.sh) : les micros reçus restent muets."


func _local_ips() -> String:
	var out: PackedStringArray = []
	for a in IP.get_local_addresses():
		if a.contains(".") and not a.begins_with("127.") and not a.begins_with("169.254"):
			out.append(a)
	return ", ".join(out) if out.size() > 0 else "?"


# ---------------------------------------------------------------- Mise à jour

func _check_update() -> void:
	if not CHECK_UPDATES:
		upd_lbl.text = "Version %s" % VERSION
		upd_btn.visible = false
		return
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
	upd_dot.visible = true
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


# ---------------------------------------------------------------- Découverte des appareils

func _my_name() -> String:
	var n := name_edit.text.strip_edges()
	return n if n != "" else _device_name()


## Chaque instance annonce en broadcast : id, port, ce qu'elle partage, nom. On ignore son propre id.
func _discovery(now: float, delta: float) -> void:
	if not disc.is_bound():
		if disc.bind(disc_port) != OK:
			return
		disc.set_broadcast_enabled(true)
	beacon_t -= delta
	if beacon_t <= 0.0:
		beacon_t = 1.0
		vsink_exists = VSINK in AudioServer.get_output_device_list()
		var flags := ("1" if cap_kind == "snd" else "0") + ("1" if cap_kind == "mic" else "0")
		var msg := ("%s|%s|%d|%s|%s" % [BEACON, my_id, data_port, flags, _my_name().replace("|", " ")]).to_utf8_buffer()
		for b in _broadcast_addrs():
			disc.set_dest_address(b, disc_port)
			disc.put_packet(msg)
	while disc.get_available_packet_count() > 0:
		var parts := disc.get_packet().get_string_from_utf8().split("|", true, 4)
		var ip := disc.get_packet_ip()
		if parts.size() < 5 or parts[0] != BEACON or parts[1] == my_id:
			continue
		peers[parts[1]] = {"ip": ip, "port": parts[2].to_int(), "snd": parts[3].substr(0, 1) == "1",
			"mic": parts[3].substr(1, 1) == "1", "name": parts[4], "t": now}
	var man := ip_edit.text.strip_edges()
	if man.is_valid_ip_address():  # appareil ajouté à la main (Réglages)
		peers["manual"] = {"ip": man, "port": data_port, "snd": false, "mic": false, "name": man, "t": now}
	else:
		peers.erase("manual")
	for k in peers.keys():
		if now - peers[k]["t"] > 4.0:
			peers.erase(k)
	var sig := "%s" % [listening.keys()]
	for k in peers:
		sig += "|%s%s%s%s" % [k, peers[k]["name"], peers[k]["snd"], peers[k]["mic"]]
	if sig != peers_sig:
		peers_sig = sig
		_rebuild_peers()


## Réglages de l'appareil écouté : volume + muet (icônes), balance G/D (centre par défaut).
func _peer_controls(id: String) -> void:
	var pc := _pcfg(id)
	var pm := MarginContainer.new()
	pm.add_theme_constant_override("margin_left", 32)
	pm.add_theme_constant_override("margin_right", 8)
	pm.add_theme_constant_override("margin_bottom", 8)
	found_list.add_child(pm)
	var v := _vbox(pm, 8)
	var r1 := HBoxContainer.new()
	r1.add_theme_constant_override("separation", 8)
	v.add_child(r1)
	r1.add_child(Ico.new("vol", false, 24.0))
	var vs := _slider(0, 150, pc["vol"] * 100.0, r1)
	vs.size_flags_horizontal = SIZE_EXPAND_FILL
	vs.size_flags_vertical = SIZE_SHRINK_CENTER
	vs.value_changed.connect(func(x: float) -> void: pc["vol"] = x / 100.0)
	var mb := Ico.new("mute", true)
	mb.set_on(pc["mute"])
	mb.toggled.connect(func(on: bool) -> void: pc["mute"] = on)
	r1.add_child(mb)
	var r2 := HBoxContainer.new()
	r2.add_theme_constant_override("separation", 8)
	v.add_child(r2)
	var gl := _hint("G", r2)
	gl.autowrap_mode = TextServer.AUTOWRAP_OFF
	gl.custom_minimum_size.x = 24
	gl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	gl.add_theme_font_size_override("font_size", 11)
	var bs := _slider(-100, 100, pc["bal"] * 100.0, r2)
	bs.size_flags_horizontal = SIZE_EXPAND_FILL
	bs.size_flags_vertical = SIZE_SHRINK_CENTER
	bs.value_changed.connect(func(x: float) -> void: pc["bal"] = x / 100.0)
	bs.gui_input.connect(func(ev: InputEvent) -> void:
		if ev is InputEventMouseButton and ev.double_click:
			bs.value = 0)
	var dl := _hint("D", r2)
	dl.autowrap_mode = TextServer.AUTOWRAP_OFF
	dl.add_theme_font_size_override("font_size", 11)
	var cb := Ico.new("center", true)
	cb.pressed.connect(func() -> void: bs.value = 0)
	r2.add_child(cb)


func _rebuild_peers() -> void:
	for ch in found_list.get_children():
		ch.queue_free()
	for k in peers:
		var p: Dictionary = peers[k]
		var on := listening.has(k)
		var b := Button.new()
		b.theme_type_variation = "Row"
		b.custom_minimum_size.y = 48
		b.pressed.connect(_toggle_listen.bind(k))
		found_list.add_child(b)
		var m := MarginContainer.new()
		m.set_anchors_preset(PRESET_FULL_RECT)
		m.mouse_filter = MOUSE_FILTER_IGNORE
		m.add_theme_constant_override("margin_left", 16)
		m.add_theme_constant_override("margin_right", 16)
		b.add_child(m)
		var h := HBoxContainer.new()
		h.mouse_filter = MOUSE_FILTER_IGNORE
		h.add_theme_constant_override("separation", 16)
		m.add_child(h)
		var dot := _label("●", h)
		dot.add_theme_font_size_override("font_size", 10)
		dot.size_flags_vertical = SIZE_SHRINK_CENTER
		dot.add_theme_color_override("font_color", C_OK if on else C_MUTED)
		var nm := _label(p["name"], h)
		nm.size_flags_horizontal = SIZE_EXPAND_FILL
		nm.size_flags_vertical = SIZE_SHRINK_CENTER
		nm.clip_text = true
		var what: PackedStringArray = []
		if p["snd"]:
			what.append("son")
		if p["mic"]:
			what.append("micro")
		var rl := _hint(", ".join(what) if not what.is_empty() else "ne partage rien", h)
		rl.size_flags_vertical = SIZE_SHRINK_CENTER
		rl.autowrap_mode = TextServer.AUTOWRAP_OFF
		rl.add_theme_color_override("font_color", C_ACCENT if on else C_MUTED)
		for lb in [nm, dot, rl]:
			lb.mouse_filter = MOUSE_FILTER_IGNORE
		if on:
			_peer_controls(k)
	found_lbl.visible = peers.is_empty()
	found_lbl.text = "Aucun autre appareil détecté"
	list_title.text = "Touchez un appareil pour l'écouter" if (not peers.is_empty() and listening.is_empty()) else "Appareils à proximité"


func _broadcast_addrs() -> PackedStringArray:
	var out: PackedStringArray = ["255.255.255.255"]
	for a in IP.get_local_addresses():
		if a.contains(".") and not a.begins_with("127.") and not a.begins_with("169.254"):
			out.append(a.substr(0, a.rfind(".")) + ".255")
	return out
