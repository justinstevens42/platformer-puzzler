extends StaticBody2D


func _ready() -> void:
	queue_redraw()


func _draw() -> void:
	var r := Rect2(-12.0, -90.0, 24.0, 180.0)
	draw_rect(r, Color(0.38, 0.62, 0.78, 0.55))
	draw_rect(r, Color(0.55, 0.85, 1.0, 0.9), false, 3.0)
