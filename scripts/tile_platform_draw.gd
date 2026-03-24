extends Node2D
class_name TilePlatformDraw

## Same terrain sheet as platforms; use CEILING / DEATH for level bounds.
const STYLE_PLATFORM := 0
const STYLE_CEILING := 1
const STYLE_DEATH := 2

var rect: Rect2 = Rect2(0, 0, 32, 32)
var is_ground: bool = false
var visual_style: int = STYLE_PLATFORM

const TERRAIN_PATH := "res://Free/Terrain/Terrain (16x16).png"
const SRC_TILE := 16

static var _shared_tex = null


static func draw_terrain_strip(ci: CanvasItem, r: Rect2, style: int, is_ground_fb: bool = false) -> void:
	if _shared_tex == null:
		_shared_tex = load(TERRAIN_PATH)
	if _shared_tex == null or not (_shared_tex is Texture2D):
		_draw_fallback_strip(ci, r, style, is_ground_fb)
		return
	var tex: Texture2D = _shared_tex as Texture2D

	var top_left := Rect2(96, 0, 16, 16)
	var top_mid := Rect2(112, 0, 16, 16)
	var top_right := Rect2(128, 0, 16, 16)
	var mid_left := Rect2(96, 16, 16, 16)
	var mid_mid := Rect2(112, 16, 16, 16)
	var mid_right := Rect2(128, 16, 16, 16)

	var cols_w := maxi(int(ceil(r.size.x / float(SRC_TILE))), 1)
	var rows_h := maxi(int(ceil(r.size.y / float(SRC_TILE))), 1)

	for row in rows_h:
		for col in cols_w:
			var dest := Rect2(
				r.position.x + col * SRC_TILE,
				r.position.y + row * SRC_TILE,
				SRC_TILE, SRC_TILE
			)
			var row_from_top: int = row
			if style == STYLE_CEILING:
				row_from_top = rows_h - 1 - row
			var is_top: bool = (row_from_top == 0)
			var is_left: bool = (col == 0)
			var is_right: bool = (col == cols_w - 1)

			var src: Rect2
			if style == STYLE_DEATH:
				if is_left:
					src = mid_left
				elif is_right:
					src = mid_right
				else:
					src = mid_mid
			elif is_top:
				if is_left:
					src = top_left
				elif is_right:
					src = top_right
				else:
					src = top_mid
			else:
				if is_left:
					src = mid_left
				elif is_right:
					src = mid_right
				else:
					src = mid_mid

			var mod := Color.WHITE
			if style == STYLE_DEATH:
				mod = Color(0.88, 0.48, 0.44)
			ci.draw_texture_rect_region(tex, dest, src, mod)

	if style == STYLE_DEATH:
		ci.draw_rect(r, Color(0.45, 0.1, 0.12, 0.55), false, maxf(2.0, r.size.y * 0.08))
	elif style == STYLE_CEILING:
		ci.draw_rect(
			Rect2(r.position.x, r.position.y + r.size.y - 2.0, r.size.x, 2.0),
			Color(0.12, 0.14, 0.18, 0.75))


static func _draw_fallback_strip(ci: CanvasItem, r: Rect2, style: int, is_ground_fb: bool) -> void:
	if style == STYLE_CEILING:
		ci.draw_rect(r, Color(0.22, 0.24, 0.30))
		ci.draw_rect(
			Rect2(r.position.x, r.position.y + r.size.y - 4.0, r.size.x, 4.0),
			Color(0.42, 0.68, 0.32))
	elif style == STYLE_DEATH:
		ci.draw_rect(r, Color(0.38, 0.14, 0.14))
		ci.draw_rect(r, Color(0.2, 0.05, 0.06), false, 2.0)
	else:
		var fill := Color(0.32, 0.26, 0.20) if is_ground_fb else Color(0.28, 0.34, 0.26)
		ci.draw_rect(r, fill)
		var accent := Color(0.42, 0.68, 0.32) if not is_ground_fb else Color(0.36, 0.54, 0.28)
		ci.draw_rect(Rect2(r.position.x, r.position.y, r.size.x, minf(8.0, r.size.y * 0.3)), accent)
		ci.draw_rect(r, Color(0.15, 0.12, 0.10), false, 2.0)


func _ready() -> void:
	z_index = -1
	if _shared_tex == null:
		_shared_tex = load(TERRAIN_PATH)
	queue_redraw()


func _draw() -> void:
	draw_terrain_strip(self, rect, visual_style, is_ground)
