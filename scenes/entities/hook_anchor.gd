extends StaticBody2D


func _ready() -> void:
	add_to_group("hook_anchor")
	queue_redraw()


func _draw() -> void:
	draw_circle(Vector2.ZERO, 10.0, Color(0.15, 0.75, 0.45, 0.9))
	draw_arc(Vector2.ZERO, 10.0, 0.0, TAU, 24, Color(0.05, 0.35, 0.2), 2.0)
