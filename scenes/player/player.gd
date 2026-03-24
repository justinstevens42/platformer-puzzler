extends CharacterBody2D

@onready var _rs: RunGameState = get_node("/root/RunState") as RunGameState

const SPEED := 220.0
const JUMP_VELOCITY := -360.0
const DOUBLE_TAP_WINDOW := 0.3
## "Coyote time": allow jump shortly after walking off a ledge.
const COYOTE_TIME := 0.06
## Prevent accidental instant double-jump right after takeoff / edge drop.
const DOUBLE_JUMP_ARM_TIME := 0.12
## Approximate feet Y offset from CharacterBody2D origin (collision center Y + half height).
const FEET_Y_OFFSET := 16.0
## Match `player.tscn`: RectangleShape2D 20×28, CollisionShape2D position (0, 2).
const _COL_HALFW := 10.0
const _ROW_HALFW := 14.0
const _COLL_CENTER_Y_OFF := 2.0

var gravity: float = ProjectSettings.get_setting("physics/2d/default_gravity") as float

var _has_double_jumped: bool = false
var _last_left_time: float = -1000.0
var _last_right_time: float = -1000.0
var _time_since_floor: float = 0.0
var _air_time: float = 0.0


func _ready() -> void:
	add_to_group("player")


func _physics_process(delta: float) -> void:
	if not _rs.is_run_active:
		velocity = Vector2.ZERO
		_time_since_floor = 0.0
		_air_time = 0.0
		return

	if not is_on_floor():
		_time_since_floor += delta
		_air_time += delta
		velocity.y += gravity * delta
	else:
		_time_since_floor = 0.0
		_air_time = 0.0
		_has_double_jumped = false

	velocity.x = Input.get_axis("move_left", "move_right") * SPEED

	var now: float = Time.get_ticks_msec() * 0.001

	if Input.is_action_just_pressed("move_up"):
		if is_on_floor() or _time_since_floor <= COYOTE_TIME:
			velocity.y = JUMP_VELOCITY
			_time_since_floor = COYOTE_TIME + 1.0
		elif _air_time >= DOUBLE_JUMP_ARM_TIME and not _has_double_jumped and &"high_jump" in _rs.loadout:
			if _rs.consume_charge(&"high_jump"):
				velocity.y = JUMP_VELOCITY
				_has_double_jumped = true

	if Input.is_action_just_pressed("move_left"):
		if (now - _last_left_time) < DOUBLE_TAP_WINDOW:
			_try_horizontal_pass(-1.0)
			_last_left_time = -1000.0
		else:
			_last_left_time = now

	if Input.is_action_just_pressed("move_right"):
		if (now - _last_right_time) < DOUBLE_TAP_WINDOW:
			_try_horizontal_pass(1.0)
			_last_right_time = -1000.0
		else:
			_last_right_time = now

	move_and_slide()

	if is_on_ceiling():
		velocity.y = maxf(velocity.y, 0.0)


func _try_horizontal_pass(sign_x: float) -> bool:
	if &"horizontal_pass" not in _rs.loadout:
		return false

	var dir_i: int = 1 if sign_x > 0.0 else -1

	var gs: Node = get_tree().get_first_node_in_group("game_session")
	if gs == null or not gs.has_method("get_level_grid"):
		return false
	var grid: Array = gs.call("get_level_grid") as Array
	if grid.size() != LevelGenerator.ROWS:
		return false

	var T := float(LevelGenerator.TILE)
	var y_keep: float = global_position.y
	# Stance cell from feet (same convention as LevelGenerator grid / BFS).
	var feet_y: float = global_position.y + FEET_Y_OFFSET
	var gx: int = clampi(int(floorf(global_position.x / T)), 0, LevelGenerator.COLS - 1)
	var gy_feet: int = clampi(int(floorf(feet_y / T)), 0, LevelGenerator.ROWS - 1)

	var hp_avail: int = _rs.get_charge(&"horizontal_pass")
	# Match solver leniency: airborne tries nearby rows; no extra adjacent-column reach.
	var row_try: Array = [0, -1, 1, -2, 2]
	if is_on_floor():
		row_try = [0]
	var col_try: Array = [0]

	var hp_res: Dictionary = {}
	for dc: int in col_try:
		var tcx: int = clampi(gx + dc, 0, LevelGenerator.COLS - 1)
		for offi: int in row_try:
			var try_y: int = gy_feet + offi
			if try_y < LevelGenerator.JUMP_MIN_ROW or try_y >= LevelGenerator.ROWS:
				continue
			var res: Dictionary = LevelGenerator.horizontal_pass_result(grid, tcx, try_y, dir_i, hp_avail)
			if not res.is_empty():
				hp_res = res
				break
		if not hp_res.is_empty():
			break

	if hp_res.is_empty():
		return false

	var cost: int = maxi(int(hp_res.get("cost", 1)), 1)
	for _i in cost:
		if not _rs.consume_charge(&"horizontal_pass"):
			return false

	var land_x: int = int(hp_res["land_x"])
	var land_y: int = int(hp_res["land_y"])
	var new_x: float = LevelGenerator.horizontal_pass_world_position(land_x, land_y, dir_i).x
	var base_pos := Vector2(new_x, y_keep)
	global_position = _hp_resolve_position_clear_of_solids(grid, base_pos, land_x, land_y, dir_i)
	velocity = Vector2.ZERO
	return true


## Keeping Y through a wall can overlap destination solids (ledge vs shaft). Nudge or fall back to floor snap.
func _hp_body_overlaps_solids(grid: Array, pos: Vector2) -> bool:
	var T := float(LevelGenerator.TILE)
	var r := Rect2(
		pos.x - _COL_HALFW,
		pos.y + _COLL_CENTER_Y_OFF - _ROW_HALFW,
		_COL_HALFW * 2.0,
		_ROW_HALFW * 2.0)
	var c0 := clampi(int(floorf(r.position.x / T)), 0, LevelGenerator.COLS - 1)
	var c1 := clampi(int(floorf((r.position.x + r.size.x - 0.001) / T)), 0, LevelGenerator.COLS - 1)
	var r0 := clampi(int(floorf(r.position.y / T)), 0, LevelGenerator.ROWS - 1)
	var r1 := clampi(int(floorf((r.position.y + r.size.y - 0.001) / T)), 0, LevelGenerator.ROWS - 1)
	for c in range(c0, c1 + 1):
		for rr in range(r0, r1 + 1):
			if LevelGenerator._is_solid(grid, c, rr):
				return true
	return false


func _hp_resolve_position_clear_of_solids(
		grid: Array, base_pos: Vector2, land_x: int, land_y: int, pass_dir: int) -> Vector2:
	if not _hp_body_overlaps_solids(grid, base_pos):
		return base_pos
	var tries: Array[Vector2] = []
	for dy in [-4, 4, -8, 8, -12, 12, -16, 16, -20, 20, -24, 24, -28, 28, -32, 32, -36, 36]:
		tries.append(Vector2(0, dy))
	for dx in [3, 6, 9, 12]:
		tries.append(Vector2(float(pass_dir * dx), 0.0))
		tries.append(Vector2(float(pass_dir * dx), -8.0))
		tries.append(Vector2(float(pass_dir * dx), 8.0))
		tries.append(Vector2(float(pass_dir * dx), -16.0))
		tries.append(Vector2(float(pass_dir * dx), 16.0))
	for off: Vector2 in tries:
		var p: Vector2 = base_pos + off
		if not _hp_body_overlaps_solids(grid, p):
			return p
	return LevelGenerator.horizontal_pass_world_position(land_x, land_y, pass_dir)


func reset_ability_state() -> void:
	_has_double_jumped = false
	_last_left_time = -1000.0
	_last_right_time = -1000.0
	_time_since_floor = 0.0
	_air_time = 0.0
