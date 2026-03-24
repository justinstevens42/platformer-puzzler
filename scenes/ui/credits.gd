extends Control


func _on_back_pressed() -> void:
	get_tree().change_scene_to_file("res://scenes/ui/main_menu.tscn")


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_ESCAPE:
		if is_inside_tree():
			var vp := get_viewport()
			if vp:
				vp.set_input_as_handled()
		_on_back_pressed()
