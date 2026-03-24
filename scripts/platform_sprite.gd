extends StaticBody2D
## Draws a rectangle matching the first child CollisionShape2D (RectangleShape2D only).

@export var fill_color: Color = Color(0.32, 0.34, 0.38)
@export var border_color: Color = Color(0.12, 0.13, 0.15)
@export var top_accent_color: Color = Color(0.42, 0.72, 0.48)
@export var accent_top_strip: bool = false


func _ready() -> void:
	z_index = -2
	queue_redraw()


func _draw() -> void:
	var cs := get_node_or_null("CollisionShape2D") as CollisionShape2D
	if cs == null:
		return
	var rect_shape := cs.shape as RectangleShape2D
	if rect_shape == null:
		return
	var half: Vector2 = rect_shape.size * 0.5
	var c: Vector2 = cs.position
	var r := Rect2(c - half, rect_shape.size)
	draw_rect(r, fill_color)
	if accent_top_strip:
		var h: float = minf(10.0, r.size.y * 0.28)
		draw_rect(Rect2(r.position.x, r.position.y, r.size.x, h), top_accent_color)
	draw_rect(r, border_color, false, 2.0)
