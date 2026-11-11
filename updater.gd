class_name Updater
extends PanelContainer
## Carte de mise à jour : vérifie la dernière release GitHub, télécharge le .pck léger.

const VERSION: String = preload("res://version.gd").VERSION
const URL := "https://github.com/goodview-soft/sound-link/releases/latest/download/version.json"
const RELEASES := "https://github.com/goodview-soft/sound-link/releases/latest"
const TMP := "user://update.tmp"

var _http := HTTPRequest.new()
var _lbl: Label
var _btn: Button
var _info := {}


func _ready() -> void:
	add_theme_stylebox_override("panel", Ui.sb(Ui.C_CARD, 20, 14, 6, Ui.C_BORDER))
	size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 10)
	add_child(h)
	_lbl = Ui.label("", h)
	_lbl.add_theme_font_size_override("font_size", 13)
	_lbl.add_theme_color_override("font_color", Ui.C_MUTED)
	_btn = Ui.button("", h)
	_btn.theme_type_variation = "Chip"
	_btn.pressed.connect(_on_button)
	_http.timeout = 10.0
	add_child(_http)
	check()


func check() -> void:
	_http.cancel_request()
	_lbl.text = "Recherche…"
	_btn.visible = false
	_http.download_file = ""
	if _http.request_completed.is_connected(_on_pck):
		_http.request_completed.disconnect(_on_pck)
	if not _http.request_completed.is_connected(_on_version):
		_http.request_completed.connect(_on_version)
	_http.request(URL)


func _on_version(result: int, code: int, _h: PackedStringArray, body: PackedByteArray) -> void:
	_btn.visible = true
	_btn.text = "Vérifier"
	if result != HTTPRequest.RESULT_SUCCESS:
		_lbl.text = "Hors ligne"
		return
	var info: Variant = JSON.parse_string(body.get_string_from_utf8()) if code == 200 else null
	if not (info is Dictionary) or not info.has("version"):
		_lbl.text = "Version introuvable"  # ne pas afficher « à jour » sans l'avoir vérifié
		return
	if not preload("res://boot.gd").newer(str(info["version"]), VERSION):
		_lbl.text = "✓ À jour"
		return
	_info = info
	add_theme_stylebox_override("panel", Ui.sb(Color("#1e1a3a"), 12, 14, 10, Ui.C_ACCENT))
	var v := Engine.get_version_info()
	var same_engine := str(info.get("godot", "")) == "%d.%d.%d" % [v.major, v.minor, v.patch]
	_lbl.text = "v%s disponible" % info["version"]
	_btn.text = "Mettre à jour" if same_engine and info.has("pck") else "Télécharger"


func _on_button() -> void:
	match _btn.text:
		"Vérifier":
			check()
		"Télécharger":
			OS.shell_open(RELEASES)
		"Redémarrer":
			OS.set_restart_on_exit(true)
			get_tree().quit()
		_:
			_btn.disabled = true
			_lbl.text = "Téléchargement…"
			_http.request_completed.disconnect(_on_version)
			_http.request_completed.connect(_on_pck)
			_http.download_file = TMP
			_http.request(str(_info["pck"]))


func _on_pck(result: int, code: int, _h: PackedStringArray, _b: PackedByteArray) -> void:
	_http.download_file = ""
	_http.request_completed.disconnect(_on_pck)
	_http.request_completed.connect(_on_version)
	_btn.disabled = false
	if result != HTTPRequest.RESULT_SUCCESS or code != 200 \
			or FileAccess.get_sha256(TMP) != str(_info.get("sha256", "")):
		DirAccess.remove_absolute(TMP)
		_lbl.text = "Échec du téléchargement, réessayer."
		return
	DirAccess.rename_absolute(TMP, "user://update.pck")
	var c := ConfigFile.new()
	c.set_value("update", "version", str(_info["version"]))
	c.save("user://update.cfg")
	if OS.has_feature("pc"):
		_lbl.text = "Mise à jour %s installée." % _info["version"]
		_btn.text = "Redémarrer"
	else:
		_lbl.text = "Mise à jour %s installée : fermer puis rouvrir l'appli." % _info["version"]
		_btn.visible = false
