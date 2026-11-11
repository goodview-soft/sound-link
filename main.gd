extends Control
## Sound Link : accueil (Host / Client) et navigation entre les pages.

var _home: VBoxContainer
var _head: HBoxContainer
var _title: Label
var _page: Control
var _holder: VBoxContainer


func _ready() -> void:
	theme = Ui.theme()
	var bg := ColorRect.new()
	bg.color = Ui.C_BG
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

	_head = HBoxContainer.new()
	_head.add_theme_constant_override("separation", 10)
	_head.visible = false
	root.add_child(_head)
	Ui.icon_btn("back", _head).pressed.connect(_go_home)
	_title = Ui.label("", _head)
	_title.add_theme_font_size_override("font_size", 20)
	_holder = VBoxContainer.new()
	root.add_child(_holder)

	_home = VBoxContainer.new()
	_home.add_theme_constant_override("separation", 18)
	root.add_child(_home)
	var logo := TextureRect.new()
	logo.texture = load("res://icon.svg")
	logo.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	logo.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	logo.custom_minimum_size = Vector2(76, 76)
	_home.add_child(logo)
	var t := Ui.label("Sound Link", _home)
	t.add_theme_font_size_override("font_size", 32)
	t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	var tiles := HBoxContainer.new()
	tiles.add_theme_constant_override("separation", 12)
	_home.add_child(tiles)
	Ui.tile(tiles, "broadcast", "Host", _open.bind("Host", HostPage))
	Ui.tile(tiles, "headphones", "Client", _open.bind("Client", ClientPage))
	_home.add_child(Updater.new())
	var foot := LinkButton.new()
	foot.text = "v%s · GitHub" % Updater.VERSION
	foot.uri = "https://github.com/goodview-soft/sound-link"
	foot.underline = LinkButton.UNDERLINE_MODE_ON_HOVER
	foot.add_theme_color_override("font_color", Color(Ui.C_MUTED, 0.7))
	foot.add_theme_color_override("font_hover_color", Ui.C_ACCENT2)
	foot.add_theme_font_size_override("font_size", 12)
	foot.size_flags_horizontal = SIZE_SHRINK_CENTER
	_home.add_child(foot)

	for arg in OS.get_cmdline_user_args():  # ex. -- --page=host
		match arg:
			"--page=host": _open("Host", HostPage)
			"--page=client": _open("Client", ClientPage)


func _open(title: String, page_class: GDScript) -> void:
	_page = page_class.new()
	_holder.add_child(_page)
	_title.text = title
	_home.visible = false
	_head.visible = true


func _go_home() -> void:
	if _page:
		_page.stop()
		_page.queue_free()
		_page = null
	_head.visible = false
	_home.visible = true
