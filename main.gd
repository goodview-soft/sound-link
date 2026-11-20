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
const DevIcon := preload("res://dev_icon.gd")
const Blueprint := preload("res://blueprint.gd")
const LevelBar := preload("res://level_bar.gd")
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
var hero_name: Label
var upd_lbl: Label
var upd_btn: Button
var upd_http: HTTPRequest
var upd_info := {}
var overlay: Window
var sw_overlay: Switch
var overlay_on := true
var ov_t := 0.0
var bp: Control
var my_type := "c"
var out_pkts: Array = []
var trust := {}  # id -> {key, name} : appareils appairés
var prompts: Array = []
var cur_prompt := {}
var pair_try := {}
var ctl_seen := {}
var ctl_nonce := 0
var pending := {}  # "dir:id" -> {t, dir, id, kind}
var want := {}  # id -> type de flux demandé en réception
var favs: Array = []
var flows_sig := ""
var flows_t := 0.0
var flow_list: VBoxContainer
var flows_empty: Label
var fav_box: HFlowContainer
var fav_title: Label
var flow_bars: Array = []
var sheet: Control
var sheet_body: VBoxContainer
var sheet_stage := "devices"
var sheet_dev := ""
var map_view: Control
var toast_lbl: Label
var toast_t := 0.0
var idle_t := 0.0
var trust_box: VBoxContainer
var confirm: ConfirmationDialog
var spec_t := 0.0
var type_picks: Array = []


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
	var last_pkts: Array = []  # 2 derniers paquets (pour le spectre au survol)
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
		last_pkts.append(pkt)
		if last_pkts.size() > 2:
			last_pkts.pop_front()
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
	my_type = cfg.get_value("app", "type", "p" if OS.has_feature("mobile") else "c")
	overlay_on = cfg.get_value("app", "overlay", true)
	trust = cfg.get_value("trust", "map", {})
	favs = cfg.get_value("app", "favs", [])
	_build_ui()
	if not OS.has_feature("mobile"):
		get_window().min_size = Vector2i(400, 680)
		overlay = preload("res://overlay.gd").new()
		add_child(overlay)
		sw_overlay.set_on(overlay_on)
		sw_overlay.toggled.connect(func(on: bool) -> void:
			overlay_on = on
			ov_t = 0.0)
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
	cfg.set_value("app", "overlay", overlay_on)
	cfg.set_value("app", "type", my_type)
	cfg.set_value("trust", "map", trust)
	cfg.set_value("app", "favs", favs)
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
	var mapb := _button("Carte", bar)
	mapb.theme_type_variation = "Ghost"
	mapb.add_theme_font_size_override("font_size", 15)
	mapb.pressed.connect(func() -> void: map_view.visible = true)
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
	hero.visible = false
	me.add_child(hero)
	hero_name = _label("", me)
	hero_name.add_theme_font_size_override("font_size", 20)
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

	# --- Favoris + flux actifs
	fav_title = _hint("Favoris", root)
	fav_box = HFlowContainer.new()
	fav_box.add_theme_constant_override("h_separation", 8)
	fav_box.add_theme_constant_override("v_separation", 8)
	root.add_child(fav_box)
	_hint("Flux actifs", root)
	var ls := ScrollContainer.new()
	ls.size_flags_vertical = SIZE_EXPAND_FILL
	ls.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	root.add_child(ls)
	var lv := VBoxContainer.new()
	lv.size_flags_horizontal = SIZE_EXPAND_FILL
	lv.add_theme_constant_override("separation", 12)
	ls.add_child(lv)
	flows_empty = _hint("Aucun flux pour l'instant. Touchez « Nouveau flux » pour envoyer ou recevoir du son.", lv)
	flow_list = _vbox(lv, 12)
	var newb := _button("+  Nouveau flux", root)
	newb.theme_type_variation = "Primary"
	newb.pressed.connect(_open_sheet.bind(true))
	card.visible = false  # plus de réglage « partager » : il se fait par les flux
	bp = Blueprint.new()
	bp.size_flags_horizontal = SIZE_EXPAND_FILL
	bp.size_flags_vertical = SIZE_EXPAND_FILL
	bp.readonly = true
	bp.me["can_snd"] = not mobile

	# --- Feuille « Nouveau flux »
	sheet = Control.new()
	sheet.set_anchors_preset(PRESET_FULL_RECT)
	sheet.visible = false
	add_child(sheet)
	var sdim := ColorRect.new()
	sdim.color = Color(0, 0, 0, 0.6)
	sdim.set_anchors_preset(PRESET_FULL_RECT)
	sdim.gui_input.connect(func(ev: InputEvent) -> void:
		if ev is InputEventMouseButton and ev.pressed:
			_open_sheet(false))
	sheet.add_child(sdim)
	var sm := MarginContainer.new()
	sm.set_anchors_preset(PRESET_FULL_RECT)
	sm.mouse_filter = MOUSE_FILTER_IGNORE
	sm.add_theme_constant_override("margin_top", 160)
	sheet.add_child(sm)
	var sp := PanelContainer.new()
	sp.add_theme_stylebox_override("panel", _sb(C_CARD, 24, 24, 24))
	sm.add_child(sp)
	var ssc := ScrollContainer.new()
	ssc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	sp.add_child(ssc)
	sheet_body = VBoxContainer.new()
	sheet_body.size_flags_horizontal = SIZE_EXPAND_FILL
	sheet_body.add_theme_constant_override("separation", 12)
	ssc.add_child(sheet_body)

	# --- Vue Carte (schéma en lecture seule)
	map_view = ColorRect.new()
	map_view.color = C_BG
	map_view.set_anchors_preset(PRESET_FULL_RECT)
	map_view.visible = false
	add_child(map_view)
	var mm := MarginContainer.new()
	mm.set_anchors_preset(PRESET_FULL_RECT)
	mm.add_theme_constant_override("margin_left", 16)
	mm.add_theme_constant_override("margin_right", 16)
	mm.add_theme_constant_override("margin_top", 16)
	mm.add_theme_constant_override("margin_bottom", 16)
	map_view.add_child(mm)
	var mv := VBoxContainer.new()
	mv.add_theme_constant_override("separation", 12)
	mm.add_child(mv)
	var mh := HBoxContainer.new()
	mv.add_child(mh)
	var mt := _label("Carte des appareils", mh)
	mt.size_flags_horizontal = SIZE_EXPAND_FILL
	var mcl := _button("✕", mh)
	mcl.theme_type_variation = "Ghost"
	mcl.pressed.connect(func() -> void: map_view.visible = false)
	var msc := ScrollContainer.new()
	msc.size_flags_vertical = SIZE_EXPAND_FILL
	msc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	mv.add_child(msc)
	msc.add_child(bp)

	# --- Message temporaire
	var tp := PanelContainer.new()
	tp.add_theme_stylebox_override("panel", _sb(Color("#232733"), 20, 18, 10, C_BORDER))
	tp.set_anchors_preset(PRESET_CENTER_BOTTOM)
	tp.grow_horizontal = GROW_DIRECTION_BOTH
	tp.grow_vertical = GROW_DIRECTION_BEGIN
	tp.offset_bottom = -90
	tp.visible = false
	tp.mouse_filter = MOUSE_FILTER_IGNORE
	add_child(tp)
	toast_lbl = _label("", tp)
	toast_lbl.mouse_filter = MOUSE_FILTER_IGNORE

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
	_hint("Type d'appareil", g0)
	var tr := HBoxContainer.new()
	tr.add_theme_constant_override("separation", 10)
	g0.add_child(tr)
	for ty in ["p", "c", "e"]:
		var pk := DevIcon.new()
		pk.dev_type = ty
		pk.custom_minimum_size = Vector2(56, 44)
		pk.picked.connect(func() -> void:
			my_type = ty
			_refresh_type_picks())
		tr.add_child(pk)
		type_picks.append(pk)
	_refresh_type_picks()

	var gp := _vbox(gs, 8)
	_hint("Appareils appairés", gp)
	trust_box = _vbox(gp, 8)

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
	if not OS.has_feature("mobile"):
		sw_overlay = _switch_row(gl, "Overlay des appareils (bas de l'écran)")

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
		_refresh_trust_list()
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
		out_pkts.append(pkt)
		if out_pkts.size() > 2:
			out_pkts.pop_front()
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
			if trust.has(msg.substr(4)):  # seuls les appareils appairés peuvent m'écouter
				subs[key] = {"ip": ip, "port": port, "t": now}
		elif msg.begins_with("C|"):
			_on_ctl(msg.split("|"), ip, port, now)
		elif msg.begins_with("PAIRREQ|"):
			_on_pairreq(msg.split("|"), ip, port)
		elif msg.begins_with("PAIROK|"):
			_on_pairok(msg.split("|"))
		elif msg.begins_with("PAIRNO|"):
			_on_pairno(msg.split("|"))
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
	bp.me["ll"] = sqrt(level_l)
	bp.me["lr"] = sqrt(level_r)
	_discovery(now, delta)
	_update_status(now)
	_overlay_process(now, delta)
	_spec_process(now, delta)
	_ov_spec(now, delta)
	_flows_process(now, delta)


func _overlay_process(now: float, delta: float) -> void:
	ov_t -= delta
	if ov_t > 0.0:
		return
	ov_t = 0.15
	var list := _conn_rows(now)
	if overlay != null:
		overlay.set_items(list if overlay_on else [])
	_bp_update(now)


var ovs_t := 0.0


## Spectre (14 bandes) de chaque pastille de l'overlay : flux reçu, sinon ce que j'envoie.
func _ov_spec(now: float, delta: float) -> void:
	if overlay == null or not overlay.visible:
		return
	ovs_t -= delta
	if ovs_t > 0.0:
		return
	ovs_t = 0.06
	var res: Array = []
	for it in overlay.items:
		var pk: Array = []
		var st := true
		if it["mouth"] and it["talk"]:
			for k in rxs:
				if k.begins_with(str(it["ip"]) + ":"):
					for t in ["snd", "mic"]:
						if rxs[k][t] and now - rxs[k][t].last_rx < 1.0:
							pk = rxs[k][t].last_pkts
							st = t == "snd"
		elif it["ear"] and it["ear_on"]:
			pk = out_pkts
			st = cap_kind == "snd"
		var sp := _spectrum_of(pk, st) if not pk.is_empty() else PackedFloat32Array()
		var s14 := PackedFloat32Array()
		if sp.size() == 28:
			for i in 14:
				s14.append((sp[i * 2] + sp[i * 2 + 1]) * 0.5)
		res.append(s14)
	overlay.specs = res
	overlay.canvas.queue_redraw()


## Appareils connectés (que j'écoute et/ou qui m'écoutent), un par IP (overlay).
func _conn_rows(now: float) -> Array:
	var rows := {}  # ip -> {name, mouth, talk, mute, ear, ear_on}
	if true:
		for id in listening:
			if not peers.has(id):
				continue
			var p: Dictionary = peers[id]
			var e: Dictionary = rxs.get("%s:%d" % [p["ip"], p["port"]], {})
			var talk := false
			for t in ["snd", "mic"]:
				if e.has(t) and e[t] and now - e[t].last_rx < 1.0:
					talk = true
			rows[p["ip"]] = {"ip": p["ip"], "name": p["name"], "mouth": true, "talk": talk, "mute": _pcfg(id)["mute"], "ear": false, "ear_on": false}
		for sb in subs.values():
			if now - sb["t"] > TIMEOUT:
				continue
			if not rows.has(sb["ip"]):
				var nm: String = sb["ip"]
				for p in peers.values():
					if p["ip"] == sb["ip"]:
						nm = p["name"]
				rows[sb["ip"]] = {"ip": sb["ip"], "name": nm, "mouth": false, "talk": false, "mute": false, "ear": false, "ear_on": false}
			rows[sb["ip"]]["ear"] = true
			rows[sb["ip"]]["ear_on"] = cap_kind != ""  # barré si je ne partage rien
	return rows.values()


func _bp_update(now: float) -> void:
	var out: Array = []
	var sub_lbl := "mon son" if cap_kind == "snd" else ("mon micro" if cap_kind == "mic" else "")
	var seen := {}
	for id in peers:
		var p: Dictionary = peers[id]
		var e: Dictionary = rxs.get("%s:%d" % [p["ip"], p["port"]], {})
		var talk := false
		for t in ["snd", "mic"]:
			if e.has(t) and e[t] and now - e[t].last_rx < 1.0:
				talk = true
		var sub := false
		for sb in subs.values():
			if sb["ip"] == p["ip"] and now - sb["t"] <= TIMEOUT:
				sub = true
		seen[p["ip"]] = true
		out.append({"id": id, "type": p.get("type", "c"), "name": p["name"], "snd": p["snd"], "mic": p["mic"], "listen": listening.has(id),
			"talk": talk, "mute": _pcfg(id)["mute"] if listening.has(id) else false, "sub": sub,
			"sub_on": sub and cap_kind != "", "sub_lbl": sub_lbl, "invited": pending.has("out:" + str(id)) and not sub})
	for sb in subs.values():
		if not seen.has(sb["ip"]) and now - sb["t"] <= TIMEOUT:
			seen[sb["ip"]] = true
			out.append({"id": "sub:" + sb["ip"], "type": "p", "name": sb["ip"], "snd": false, "mic": false, "listen": false,
				"talk": false, "mute": false, "sub": true, "sub_on": cap_kind != "", "sub_lbl": sub_lbl, "invited": false})
	bp.nodes = out
	bp.me["name"] = hero_name.text
	bp.me["status"] = pill_txt.text
	bp.me["state"] = meter.state
	bp.me["cap"] = cap_kind
	bp.me["type"] = my_type


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
		var flags := ("1" if cap_kind == "snd" else "0") + ("1" if cap_kind == "mic" else "0") + my_type
		var msg := ("%s|%s|%d|%s|%s" % [BEACON, my_id, data_port, flags, _my_name().replace("|", " ")]).to_utf8_buffer()
		var dests := _broadcast_addrs()
		var man0 := ip_edit.text.strip_edges()
		if man0.is_valid_ip_address():
			dests.append(man0)
		for b in dests:
			disc.set_dest_address(b, disc_port)
			disc.put_packet(msg)
	while disc.get_available_packet_count() > 0:
		var parts := disc.get_packet().get_string_from_utf8().split("|", true, 4)
		var ip := disc.get_packet_ip()
		if parts.size() < 5 or parts[0] != BEACON or parts[1] == my_id:
			continue
		peers[parts[1]] = {"ip": ip, "port": parts[2].to_int(), "snd": parts[3].substr(0, 1) == "1",
			"mic": parts[3].substr(1, 1) == "1", "name": parts[4], "t": now,
			"type": parts[3].substr(2, 1) if parts[3].length() > 2 else "c"}
	for k in peers.keys():
		if now - peers[k]["t"] > 4.0:
			peers.erase(k)
	var sig := "%s" % [listening.keys()]
	for k in peers:
		sig += "|%s%s%s%s" % [k, peers[k]["name"], peers[k]["snd"], peers[k]["mic"]]
	if sig != peers_sig:
		peers_sig = sig
		_refresh_sheet()


## Réglages de l'appareil écouté : volume + muet (icônes), balance G/D (centre par défaut).
## Spectre (28 bandes log 60 Hz–10 kHz, Goertzel) des derniers paquets, 0..1.
func _spectrum_of(pkts: Array, stereo: bool) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(28)
	if pkts.is_empty():
		return out
	var xs := PackedFloat32Array()
	var step := 4 if stereo else 2
	for pk: PackedByteArray in pkts:
		var n := (pk.size() - 12) / step
		for i in n:
			xs.append(pk.decode_s16(12 + i * step) / 32768.0)
	var rate := float(pkts[pkts.size() - 1].decode_u32(8))
	if rate <= 0.0 or xs.size() < 64:
		return out
	var cnt := xs.size()
	for b in 28:
		var f := 60.0 * pow(10000.0 / 60.0, (b + 0.5) / 28.0)
		var coeff := 2.0 * cos(TAU * f / rate)
		var s1 := 0.0
		var s2 := 0.0
		for x in xs:
			var s0: float = x + coeff * s1 - s2
			s2 = s1
			s1 = s0
		var mag := sqrt(maxf(s1 * s1 + s2 * s2 - coeff * s1 * s2, 0.0)) * 2.0 / cnt
		out[b] = clampf((20.0 * log(mag + 1e-6) / log(10.0) + 60.0) / 60.0, 0.0, 1.0)
	return out


func _spec_process(now: float, delta: float) -> void:
	spec_t -= delta
	if spec_t > 0.0:
		return
	spec_t = 0.035
	var h: Dictionary = bp.hover
	if h.is_empty():
		bp.spec = PackedFloat32Array()
		return
	if h["kind"] == "in":
		var p: Dictionary = peers.get(h["id"], {})
		var e: Dictionary = rxs.get("%s:%d" % [p.get("ip", ""), p.get("port", 0)], {})
		for t in ["snd", "mic"]:
			if e.has(t) and e[t] and now - e[t].last_rx < 1.0:
				bp.spec = _spectrum_of(e[t].last_pkts, t == "snd")
				return
		bp.spec = PackedFloat32Array()
	else:
		bp.spec = _spectrum_of(out_pkts, cap_kind == "snd") if cap_kind != "" else PackedFloat32Array()


func _refresh_type_picks() -> void:
	for pk in type_picks:
		pk.selected = pk.dev_type == my_type
		pk.queue_redraw()


# ---------------------------------------------------------------- Appairage et contrôle (v4)

func _hmac(key: String, msg: String) -> String:
	return Crypto.new().hmac_digest(HashingContext.HASH_SHA256, key.to_utf8_buffer(), msg.to_utf8_buffer()).hex_encode()


func _send_raw(ip: String, port: int, msg: String, times := 1) -> void:
	udp.set_dest_address(ip, port)
	for i in times:
		udp.put_packet(msg.to_utf8_buffer())


## Commande signée (HMAC avec la clé d'appairage), envoyée 3 fois (UDP) ; idempotente côté récepteur.
func _send_ctl(id: String, cmd: String, arg := "") -> void:
	var p: Dictionary = peers.get(id, {})
	if p.is_empty() or not trust.has(id):
		return
	ctl_nonce = maxi(ctl_nonce + 1, int(Time.get_unix_time_from_system() * 1000.0))
	var body := "%s|%d|%s|%s" % [my_id, ctl_nonce, cmd, arg]
	_send_raw(p["ip"], p["port"], "C|%s|%s" % [body, _hmac(trust[id]["key"], body)], 3)


func _on_ctl(q: PackedStringArray, ip: String, port: int, now: float) -> void:
	if q.size() != 6 or not trust.has(q[1]):
		return
	if _hmac(trust[q[1]]["key"], "%s|%s|%s|%s" % [q[1], q[2], q[3], q[4]]) != q[5]:
		return
	var n := q[2].to_int()
	if n <= int(ctl_seen.get(q[1], 0)):
		return  # rejeu / doublon
	ctl_seen[q[1]] = n
	var id := q[1]
	if not peers.has(id):
		peers[id] = {"ip": ip, "port": port, "snd": false, "mic": false, "name": trust[id]["name"], "t": now, "type": "c"}
	var nm: String = peers[id]["name"]
	var what := _kind_txt(q[4])
	match q[3]:
		"OFFER":
			if listening.has(id) and want.get(id, "") == q[4]:
				return
			_ask("%s veut vous envoyer son %s. Accepter ?" % [nm, what],
				func() -> void:
					listening[id] = true
					want[id] = q[4]
					sub_t = 0.0
					flows_sig = "",
				func() -> void: _send_ctl(id, "DENY", "out"))
		"STOPOFFER":
			if listening.has(id):
				_toggle_listen(id)
		"ASK":
			if q[4] == "snd" and OS.has_feature("mobile"):
				_send_ctl(id, "DENY", "in")
				return
			_ask("%s veut écouter votre %s. Accepter ?" % [nm, what],
				func() -> void: _set_share(q[4]),
				func() -> void: _send_ctl(id, "DENY", "in"))
		"DENY":
			_toast("%s a refusé" % nm)
			_stop_flow(q[4], id)


## File d'attente de demandes à accepter / refuser, une boîte à la fois.
func _ask(text: String, ok: Callable, no := Callable()) -> void:
	prompts.append({"text": text, "ok": ok, "no": no})
	_next_prompt()


func _next_prompt() -> void:
	if not cur_prompt.is_empty() or prompts.is_empty():
		return
	if confirm == null:
		confirm = ConfirmationDialog.new()
		confirm.ok_button_text = "Accepter"
		confirm.cancel_button_text = "Refuser"
		confirm.confirmed.connect(func() -> void: _answer(true))
		confirm.canceled.connect(func() -> void: _answer(false))
		add_child(confirm)
	cur_prompt = prompts.pop_front()
	confirm.dialog_text = cur_prompt["text"]
	confirm.popup_centered(Vector2i(380, 140))


func _answer(yes: bool) -> void:
	var p: Dictionary = cur_prompt
	cur_prompt = {}
	var cb: Callable = p["ok"] if yes else p["no"]
	if cb.is_valid():
		cb.call()
	_next_prompt()


func _on_pairreq(q: PackedStringArray, ip: String, port: int) -> void:
	# PAIRREQ|id|nom|nonce : un appareil demande à s'appairer, je décide
	if q.size() != 4:
		return
	var bid := q[1]
	for p in prompts:
		if p.get("pid", "") == bid:
			return
	if cur_prompt.get("pid", "") == bid:
		return
	var nm := _my_name().replace("|", " ")
	prompts.append({"pid": bid, "text": "%s demande à s'appairer avec cet appareil. Accepter ?" % q[2],
		"ok": func() -> void:
			var key := Crypto.new().generate_random_bytes(16).hex_encode()
			trust[bid] = {"key": key, "name": q[2]}
			_send_raw(ip, port, "PAIROK|%s|%s|%s|%s" % [my_id, nm, q[3], key], 3)
			_save()
			_toast("%s est appairé" % q[2])
			_refresh_sheet(),
		"no": func() -> void: _send_raw(ip, port, "PAIRNO|%s|%s" % [my_id, q[3]], 3)})
	_next_prompt()


func _on_pairok(q: PackedStringArray) -> void:
	# PAIROK|id|nom|nonce|clé
	if q.size() != 5 or pair_try.is_empty() or q[3] != pair_try["nonce"]:
		return
	trust[q[1]] = {"key": q[4], "name": q[2]}
	pair_try = {}
	_save()
	_toast("Appairage accepté")
	if sheet_stage == "pair" and sheet_dev == q[1]:
		sheet_stage = "kinds"
	_refresh_sheet()


func _on_pairno(q: PackedStringArray) -> void:
	if q.size() == 3 and not pair_try.is_empty() and q[2] == pair_try["nonce"]:
		pair_try = {}
		_toast("%s a refusé l'appairage" % _peer_name(q[1]))
		sheet_stage = "devices"
		_refresh_sheet()


func _do_pair(id: String) -> void:
	var p: Dictionary = peers.get(id, {})
	if p.is_empty():
		return
	var nonce := str(randi())
	pair_try = {"nonce": nonce}
	var nm := _my_name().replace("|", " ")
	_send_raw(p["ip"], p["port"], "PAIRREQ|%s|%s|%s" % [my_id, nm, nonce], 3)
	get_tree().create_timer(30.0).timeout.connect(func() -> void:
		if not pair_try.is_empty() and pair_try["nonce"] == nonce:
			pair_try = {}
			_toast("Pas de réponse à la demande d'appairage")
			if sheet_stage == "pair":
				sheet_stage = "devices"
				_refresh_sheet())


func _toast(t: String) -> void:
	if toast_lbl == null:
		return
	toast_lbl.text = t
	toast_lbl.get_parent().visible = true
	toast_lbl.get_parent().modulate.a = 1.0
	toast_t = 3.0


func _set_share(kind: String) -> void:
	if cap_kind == kind:
		return
	var sw: Switch = sw_snd if kind == "snd" else sw_mic
	if sw:
		sw.set_on(true)
	_on_share(kind, true)


func _stop_share() -> void:
	if cap_kind == "":
		return
	var sw: Switch = sw_snd if cap_kind == "snd" else sw_mic
	if sw:
		sw.set_on(false)
	_on_share(cap_kind, false)


# ---------------------------------------------------------------- Flux (v4)

## dir "out" : j'envoie mon son/micro à id ; dir "in" : je reçois le son/micro de id.
func _start_flow(id: String, dir: String, kind: String) -> void:
	if not peers.has(id):
		_toast("Appareil absent du réseau")
		return
	if not trust.has(id):
		_toast("Appairez d'abord cet appareil")
		return
	var now := Time.get_ticks_msec() / 1000.0
	if dir == "out":
		_set_share(kind)
		_send_ctl(id, "OFFER", kind)
	else:
		if not listening.has(id):
			_toggle_listen(id)
		want[id] = kind
		_send_ctl(id, "ASK", kind)
	pending["%s:%s" % [dir, id]] = {"t": now, "dir": dir, "id": id, "kind": kind}
	flows_sig = ""


func _stop_flow(dir: String, id: String) -> void:
	pending.erase("%s:%s" % [dir, id])
	if dir == "in":
		if listening.has(id):
			_toggle_listen(id)
	else:
		_send_ctl(id, "STOPOFFER")
		var p: Dictionary = peers.get(id, {})
		for k in subs.keys():
			if not p.is_empty() and subs[k]["ip"] == p["ip"]:
				subs.erase(k)
	flows_sig = ""


func _fav_index(id: String, dir: String, kind: String) -> int:
	for i in favs.size():
		if favs[i]["id"] == id and favs[i]["dir"] == dir and favs[i]["kind"] == kind:
			return i
	return -1


func _peer_name(id: String) -> String:
	if peers.has(id):
		return peers[id]["name"]
	return str(trust.get(id, {}).get("name", "appareil"))


func _id_for_ip(ip: String) -> String:
	for id in peers:
		if peers[id]["ip"] == ip:
			return id
	return ""


func _flow_items(now: float) -> Array:
	var items: Array = []
	for id in listening:
		var p: Dictionary = peers.get(id, {})
		if p.is_empty():
			continue
		var e: Dictionary = rxs.get("%s:%d" % [p["ip"], p["port"]], {})
		var kind: String = want.get(id, "snd" if p["snd"] else ("mic" if p["mic"] else "snd"))
		var live := false
		for t in ["snd", "mic"]:
			if e.has(t) and e[t] and now - e[t].last_rx < 1.0:
				live = true
				kind = t
		items.append({"dir": "in", "id": id, "name": p["name"], "type": p.get("type", "c"), "kind": kind, "live": live})
	var seen := {}
	for sb in subs.values():
		if now - sb["t"] > TIMEOUT:
			continue
		var id := _id_for_ip(sb["ip"])
		if id == "" or seen.has(id):
			continue
		seen[id] = true
		items.append({"dir": "out", "id": id, "name": peers[id]["name"], "type": peers[id].get("type", "c"),
			"kind": cap_kind if cap_kind != "" else "snd", "live": cap_kind != ""})
	for k in pending.keys():
		var pd: Dictionary = pending[k]
		if pd["dir"] == "out" and not seen.has(pd["id"]) and peers.has(pd["id"]):
			items.append({"dir": "out", "id": pd["id"], "name": peers[pd["id"]]["name"], "type": peers[pd["id"]].get("type", "c"),
				"kind": pd["kind"], "live": false})
	return items


func _flows_process(now: float, delta: float) -> void:
	# expiration des demandes sans réponse
	for k in pending.keys():
		var pd: Dictionary = pending[k]
		var done := false
		if pd["dir"] == "in":
			var p: Dictionary = peers.get(pd["id"], {})
			var e: Dictionary = rxs.get("%s:%d" % [p.get("ip", ""), p.get("port", 0)], {})
			for t in ["snd", "mic"]:
				if e.has(t) and e[t] and now - e[t].last_rx < 1.0:
					done = true
		else:
			var p2: Dictionary = peers.get(pd["id"], {})
			for sb in subs.values():
				if sb["ip"] == p2.get("ip", ""):
					done = true
		if done:
			pending.erase(k)
		elif now - pd["t"] > 8.0:
			_toast("%s ne répond pas" % _peer_name(pd["id"]))
			_stop_flow(pd["dir"], pd["id"])
	# partage coupé automatiquement quand plus personne n'écoute
	if cap_kind != "" and subs.is_empty() and not _has_pending_out():
		idle_t += delta
		if idle_t > 8.0:
			_stop_share()
			idle_t = 0.0
	else:
		idle_t = 0.0
	# toast
	if toast_t > 0.0:
		toast_t -= delta
		if toast_t < 0.5:
			toast_lbl.get_parent().modulate.a = maxf(toast_t / 0.5, 0.0)
		if toast_t <= 0.0:
			toast_lbl.get_parent().visible = false
	# niveaux
	for fb in flow_bars:
		fb["bar"].value = _flow_level(fb["dir"], fb["id"], now)
	flows_t -= delta
	if flows_t > 0.0:
		return
	flows_t = 0.15
	var items := _flow_items(now)
	var sig := str(items) + str(favs) + str(trust.keys())
	if sig != flows_sig:
		flows_sig = sig
		_build_flows(items)


func _has_pending_out() -> bool:
	for pd in pending.values():
		if pd["dir"] == "out":
			return true
	return false


func _peak_of(pkts: Array, stereo: bool) -> float:
	var pk := 0.0
	var step := 4 if stereo else 2
	for b: PackedByteArray in pkts:
		var n := (b.size() - 12) / step
		var i := 0
		while i < n:
			pk = maxf(pk, absf(b.decode_s16(12 + i * step)) / 32768.0)
			i += 6
	return sqrt(pk)


func _flow_level(dir: String, id: String, now: float) -> float:
	if dir == "out":
		return _peak_of(out_pkts, cap_kind == "snd") if cap_kind != "" else 0.0
	var p: Dictionary = peers.get(id, {})
	var e: Dictionary = rxs.get("%s:%d" % [p.get("ip", ""), p.get("port", 0)], {})
	for t in ["snd", "mic"]:
		if e.has(t) and e[t] and now - e[t].last_rx < 1.0:
			return _peak_of(e[t].last_pkts, t == "snd")
	return 0.0


func _kind_txt(kind: String) -> String:
	return "son" if kind == "snd" else "micro"


func _build_flows(items: Array) -> void:
	for ch in flow_list.get_children():
		ch.queue_free()
	flow_bars.clear()
	flows_empty.visible = items.is_empty()
	for it in items:
		var card := PanelContainer.new()
		card.add_theme_stylebox_override("panel", _sb(C_CARD, 16, 14, 12, C_OK if it["live"] else C_BORDER))
		flow_list.add_child(card)
		var v := _vbox(card, 8)
		var h := HBoxContainer.new()
		h.add_theme_constant_override("separation", 10)
		v.add_child(h)
		var ic := DevIcon.new()
		ic.dev_type = it["type"]
		ic.selected = false
		ic.mouse_filter = MOUSE_FILTER_IGNORE
		ic.custom_minimum_size = Vector2(34, 30)
		h.add_child(ic)
		var title := "%s de %s" % [_kind_txt(it["kind"]).capitalize(), it["name"]] if it["dir"] == "in" \
			else "Mon %s → %s" % [_kind_txt(it["kind"]), it["name"]]
		var tl := _label(title, h)
		tl.size_flags_horizontal = SIZE_EXPAND_FILL
		tl.size_flags_vertical = SIZE_SHRINK_CENTER
		tl.clip_text = true
		var fi := _fav_index(it["id"], it["dir"], it["kind"])
		var star := _button("★" if fi >= 0 else "☆", h)
		star.theme_type_variation = "Ghost"
		star.pressed.connect(func() -> void:
			var j := _fav_index(it["id"], it["dir"], it["kind"])
			if j >= 0:
				favs.remove_at(j)
			else:
				favs.append({"id": it["id"], "name": it["name"], "dir": it["dir"], "kind": it["kind"], "type": it["type"]})
			_save()
			flows_sig = "")
		var stop := _button("Stop", h)
		stop.theme_type_variation = "Danger"
		stop.pressed.connect(_stop_flow.bind(it["dir"], it["id"]))
		var st := _hint("En direct" if it["live"] else "Connexion…", v)
		st.add_theme_color_override("font_color", C_OK if it["live"] else C_MUTED)
		var r2 := HBoxContainer.new()
		r2.add_theme_constant_override("separation", 10)
		v.add_child(r2)
		var bar := LevelBar.new()
		bar.col = C_OK if it["kind"] == "snd" else C_ACCENT
		r2.add_child(bar)
		flow_bars.append({"bar": bar, "dir": it["dir"], "id": it["id"]})
		if it["dir"] == "in":
			var pc := _pcfg(it["id"])
			var vs := _slider(0, 150, pc["vol"] * 100.0, r2)
			vs.custom_minimum_size.x = 120
			vs.size_flags_vertical = SIZE_SHRINK_CENTER
			vs.value_changed.connect(func(x: float) -> void: pc["vol"] = x / 100.0)
			var mb := Ico.new("mute", true)
			mb.set_on(pc["mute"])
			mb.toggled.connect(func(on: bool) -> void: pc["mute"] = on)
			r2.add_child(mb)
	# favoris
	for ch in fav_box.get_children():
		ch.queue_free()
	fav_title.visible = not favs.is_empty()
	fav_box.visible = not favs.is_empty()
	for f in favs:
		var fb := Button.new()
		fb.text = "▶ " + ("%s de %s" % [_kind_txt(f["kind"]), f["name"]] if f["dir"] == "in" else "mon %s → %s" % [_kind_txt(f["kind"]), f["name"]])
		fb.custom_minimum_size.y = 40
		fb.pressed.connect(_start_flow.bind(f["id"], f["dir"], f["kind"]))
		fav_box.add_child(fb)


# ---------------------------------------------------------------- Feuille « Nouveau flux »

func _open_sheet(on: bool) -> void:
	sheet.visible = on
	if on:
		sheet_stage = "devices"
		_refresh_sheet()


func _refresh_sheet() -> void:
	if sheet == null or not sheet.visible:
		return
	for ch in sheet_body.get_children():
		ch.queue_free()
	match sheet_stage:
		"devices":
			_sheet_title("Nouveau flux : avec quel appareil ?")
			if peers.is_empty():
				_hint("Aucun appareil détecté. Ouvrez Sound Link sur l'autre appareil, sur le même Wi-Fi.", sheet_body)
			for id in peers:
				var p: Dictionary = peers[id]
				var paired := trust.has(id)
				_device_row(p.get("type", "c"), p["name"], "appairé" if paired else "demander", C_OK if paired else C_MUTED,
					func() -> void:
						sheet_dev = id
						sheet_stage = "kinds" if trust.has(id) else "pair"
						if sheet_stage == "pair":
							_do_pair(id)
						_refresh_sheet())
		"pair":
			_sheet_back()
			_sheet_title("Demande envoyée à %s" % _peer_name(sheet_dev))
			_hint("En attente : acceptez la demande sur l'autre appareil (bouton Accepter).", sheet_body)
		"kinds":
			var nm := _peer_name(sheet_dev)
			_sheet_back()
			_sheet_title("Avec %s" % nm)
			var opts: Array = []
			if not OS.has_feature("mobile"):
				opts.append(["Envoyer mon son vers %s" % nm, "out", "snd"])
			opts.append(["Envoyer mon micro vers %s" % nm, "out", "mic"])
			opts.append(["Recevoir le son de %s" % nm, "in", "snd"])
			opts.append(["Recevoir le micro de %s" % nm, "in", "mic"])
			for o in opts:
				var b := _button(o[0], sheet_body)
				b.custom_minimum_size.y = 56
				b.pressed.connect(func() -> void:
					_start_flow(sheet_dev, o[1], o[2])
					_open_sheet(false))


func _sheet_title(t: String) -> void:
	var l := _label(t, sheet_body)
	l.add_theme_font_size_override("font_size", 20)


func _sheet_back() -> void:
	var b := _button("‹ Retour", sheet_body)
	b.theme_type_variation = "Ghost"
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.pressed.connect(func() -> void:
		sheet_stage = "devices"
		_refresh_sheet())


func _device_row(type: String, text: String, tag: String, tag_col: Color, cb: Callable) -> void:
	var b := Button.new()
	b.theme_type_variation = "Row"
	b.custom_minimum_size.y = 56
	b.pressed.connect(cb)
	sheet_body.add_child(b)
	var mc := MarginContainer.new()
	mc.set_anchors_preset(PRESET_FULL_RECT)
	mc.mouse_filter = MOUSE_FILTER_IGNORE
	mc.add_theme_constant_override("margin_left", 12)
	mc.add_theme_constant_override("margin_right", 12)
	b.add_child(mc)
	var h := HBoxContainer.new()
	h.mouse_filter = MOUSE_FILTER_IGNORE
	h.add_theme_constant_override("separation", 12)
	mc.add_child(h)
	var ic := DevIcon.new()
	ic.dev_type = type
	ic.mouse_filter = MOUSE_FILTER_IGNORE
	ic.custom_minimum_size = Vector2(34, 30)
	h.add_child(ic)
	var nl := _label(text, h)
	nl.size_flags_horizontal = SIZE_EXPAND_FILL
	nl.size_flags_vertical = SIZE_SHRINK_CENTER
	nl.mouse_filter = MOUSE_FILTER_IGNORE
	var tl := _hint(tag, h)
	tl.size_flags_vertical = SIZE_SHRINK_CENTER
	tl.add_theme_color_override("font_color", tag_col)
	tl.mouse_filter = MOUSE_FILTER_IGNORE


func _refresh_trust_list() -> void:
	for ch in trust_box.get_children():
		ch.queue_free()
	if trust.is_empty():
		_hint("Aucun appareil appairé.", trust_box)
	for id in trust:
		var h := HBoxContainer.new()
		trust_box.add_child(h)
		var l := _label(str(trust[id]["name"]), h)
		l.size_flags_horizontal = SIZE_EXPAND_FILL
		var b := _button("Oublier", h)
		b.pressed.connect(func() -> void:
			_stop_flow("in", id)
			_stop_flow("out", id)
			trust.erase(id)
			_save()
			_refresh_trust_list())


func _broadcast_addrs() -> PackedStringArray:
	var out: PackedStringArray = ["255.255.255.255"]
	for a in IP.get_local_addresses():
		if a.contains(".") and not a.begins_with("127.") and not a.begins_with("169.254"):
			out.append(a.substr(0, a.rfind(".")) + ".255")
	return out
