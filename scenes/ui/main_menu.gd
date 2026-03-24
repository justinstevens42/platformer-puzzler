extends Control

@onready var _rs: RunGameState = get_node("/root/RunState") as RunGameState


func _start_run(abilities: Array[StringName]) -> void:
	_rs.start_new_run(abilities)
	_rs.pcg_sequential_run = true
	get_tree().change_scene_to_file("res://scenes/ui/ability_intro.tscn")


func _on_tutorial_hj_pressed() -> void:
	_start_run([&"high_jump"])


func _on_tutorial_hp_pressed() -> void:
	_start_run([&"horizontal_pass"])


func _on_main_level_pressed() -> void:
	_start_run([&"high_jump", &"horizontal_pass"])


func _on_justin_levels_pressed() -> void:
	_rs.start_new_run([&"high_jump", &"horizontal_pass"])
	_rs.justin_campaign = true
	_rs.intro_heading_override = "Double jump"
	_rs.pending_intro_abilities.clear()
	_rs.pending_intro_abilities.append(&"high_jump")
	_rs.fixed_level_paths = _rs.JUSTIN_PACK_PATHS.duplicate()
	get_tree().change_scene_to_file("res://scenes/ui/ability_intro.tscn")


func _on_level_editor_pressed() -> void:
	get_tree().change_scene_to_file("res://scenes/ui/level_editor.tscn")


func _on_credits_pressed() -> void:
	get_tree().change_scene_to_file("res://scenes/ui/credits.tscn")
