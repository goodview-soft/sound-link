class_name ClientPage
extends VBoxContainer
## Page Client : vide pour l'instant.


func _ready() -> void:
	add_theme_constant_override("separation", 16)
	var c := Ui.card(self, "Client")
	Ui.hint("Rien ici pour le moment.", c)


func stop() -> void:
	pass
