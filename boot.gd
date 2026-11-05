extends Node
## Démarrage : charge la mise à jour téléchargée (user://update.pck) si elle est plus récente
## que la version intégrée au programme, puis lance la scène principale.

const PCK := "user://update.pck"
const CFG := "user://update.cfg"


func _ready() -> void:
	var base: String = load("res://version.gd").VERSION
	var cfg := ConfigFile.new()
	if FileAccess.file_exists(PCK) and cfg.load(CFG) == OK:
		var v: String = cfg.get_value("update", "version", "0")
		if newer(v, base) and ProjectSettings.load_resource_pack(PCK):
			print("Mise à jour chargée : ", v)
		else:
			DirAccess.remove_absolute(PCK)  # obsolète (programme plus récent) ou illisible
	get_tree().change_scene_to_file.call_deferred("res://main.tscn")


static func newer(a: String, b: String) -> bool:
	var pa := a.split(".")
	var pb := b.split(".")
	for i in maxi(pa.size(), pb.size()):
		var x := pa[i].to_int() if i < pa.size() else 0
		var y := pb[i].to_int() if i < pb.size() else 0
		if x != y:
			return x > y
	return false
