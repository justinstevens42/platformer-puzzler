extends AnimatableBody2D


func _ready() -> void:
	add_to_group("movable_block")
	queue_redraw()


func _draw() -> void:
	# Visual slightly larger than physics (26) so corners don't feel like invisible walls.
	draw_rect(Rect2(-15.0, -15.0, 30.0, 30.0), Color(0.5, 0.32, 0.16))
	draw_rect(Rect2(-13.0, -13.0, 26.0, 26.0), Color(0.68, 0.46, 0.24))
	draw_rect(Rect2(-15.0, -15.0, 30.0, 30.0), Color(0.2, 0.12, 0.08), false, 2.0)
