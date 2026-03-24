extends Node2D
class_name LevelBackdrop

var _tex: Texture2D = null


func _ready() -> void:
	z_index = -100
	_tex = load("res://Free/Background/Blue.png") as Texture2D
	queue_redraw()


func _draw() -> void:
	var margin := 800.0
	var T: float = LevelGenerator.TILE
	var world_w: float = LevelGenerator.COLS * T + margin * 2.0
	var world_h: float = LevelGenerator.ROWS * T + margin * 2.0
	var origin := Vector2(-margin, -margin)

	if _tex:
		var tw := float(_tex.get_width())
		var th := float(_tex.get_height())
		var cols: int = int(ceil(world_w / tw)) + 1
		var rows: int = int(ceil(world_h / th)) + 1
		for r in rows:
			for c in cols:
				draw_texture(_tex, origin + Vector2(c * tw, r * th))
	else:
		draw_rect(Rect2(origin.x, origin.y, world_w, world_h), Color(0.14, 0.17, 0.24))
