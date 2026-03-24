extends RefCounted
class_name LevelGenerator

const TILE := 32
const COLS := 40
const ROWS := 18
## Jump arcs may not use row 0 air (hard ceiling); matches in-game slab above the grid.
const JUMP_MIN_ROW := 1
const GROUND_ROW := 14
const SPAWN_COL := 2
const FLAG_COL := 37

## Discrete jumps tuned to CharacterBody2D: JUMP_VELOCITY=-360, default g≈980 → peak ≈66px (~2 tiles).
## One "double jump" step must not exceed ~1 extra tile beyond a strong normal hop (dy=4 was ~128px).
const NORMAL_JUMP_UP := 2
const NORMAL_JUMP_H := 5
const HIGH_JUMP_UP := 3
const HIGH_JUMP_H := 5

## HP walls must be ≤ `HORIZONTAL_PASS_MAX_SOLID_TILES` wide or the pass can never succeed.
const WALL_W := 1
const CLIFF_W := 2
## One horizontal-pass activation may only phase through this many solid columns at a time.
const HORIZONTAL_PASS_MAX_SOLID_TILES := 1

## Floor under the flag and its horizontal neighbors must stay solid for a valid goal stand.
const FLAG_FLOOR_BAND_LO := FLAG_COL - 1
const FLAG_FLOOR_BAND_HI := FLAG_COL + 1

## PCG tries per archive build (upper bound; we stop earlier once ARCHIVE_MAX_LEVELS accept).
const ARCHIVE_ATTEMPTS := 150
## Enough variety for difficulty tiers; 3 procedural modes × 15 + Justin pack 15 = 60 levels total.
const ARCHIVE_MAX_LEVELS := 15

## Level editor saves here (must stay in sync with `level_editor.gd` and `game_session` saves).
const PUZZLES_USER_DIR := "user://levels/"
## Shipped / repo copies: tried if `user://` file is missing (same filenames as editor).
const PUZZLES_RES_DIR := "res://levels/"

## Random pit start column in [lo, hi] so [px, px + pw - 1] does not overlap the flag floor band.
## Returns -1 if no placement exists (caller should skip the pit).
static func _pit_start_avoid_flag_floor_band(rng: RandomNumberGenerator, lo: int, hi: int, pw: int) -> int:
	if lo > hi or pw < 1:
		return -1
	var opts: Array = []
	for px in range(lo, hi + 1):
		if px + pw - 1 < FLAG_FLOOR_BAND_LO or px > FLAG_FLOOR_BAND_HI:
			opts.append(px)
	if opts.is_empty():
		return -1
	return int(opts[rng.randi() % opts.size()])

## Upper bound on distinct BFS states: every (cell × high_jump remaining × horiz_pass remaining).
## A fixed low cap (previously 5000) falsely failed on common editor settings, e.g. 720×3×4 = 8640.
static func _bfs_visit_cap(max_hj: int, max_hp: int) -> int:
	var dh: int = maxi(max_hj, 0) + 1
	var dp: int = maxi(max_hp, 0) + 1
	# ×2: airborne "double jump already spent this airtime" bit (matches player._has_double_jumped).
	return COLS * ROWS * dh * dp * 2 + 2048


## Build a MAP-Elites archive of levels sorted from easiest to hardest.
## Behavior space: (min_hj_charges × min_hp_charges). Quality metric: BFS exploration count.
## max_attempts: clamped try count; use -1 for [constant ARCHIVE_ATTEMPTS].
## progress_receiver / progress_method: optional; `call_deferred(method, iter_done, tries, accepted_count, cap)` after each attempt (worker thread → main thread UI).
## cancel: optional; worker checks `is_cancelled()` each attempt so the UI can abort without blocking.
## Returns a flat Array of level dictionaries ordered by ascending difficulty.
static func build_archive(
		rng_seed: int, abilities: Array[StringName], max_attempts: int = -1,
		progress_receiver: Object = null, progress_method: StringName = StringName(),
		cancel = null) -> Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = rng_seed

	var tries: int = ARCHIVE_ATTEMPTS if max_attempts < 0 else clampi(max_attempts, 1, 500)

	var has_hj := &"high_jump" in abilities
	var has_hp := &"horizontal_pass" in abilities

	var accepted: Array = []
	var iter_done: int = 0
	var report: bool = progress_receiver != null and String(progress_method) != ""

	for _i in tries:
		if cancel != null and cancel.is_cancelled():
			break
		if accepted.size() >= ARCHIVE_MAX_LEVELS:
			break
		var grid := _empty_grid()
		var flag_row: int

		if has_hj and has_hp:
			flag_row = _build_combined(rng, grid, rng.randi_range(1, 2), rng.randi_range(1, 2))
		elif has_hp:
			flag_row = _build_hp(rng, grid, rng.randi_range(1, 3))
		else:
			flag_row = _build_hj(rng, grid, rng.randi_range(1, 2))
		_ensure_flag_cell_clear(grid, flag_row)

		var platforms := _grid_to_platforms(grid)
		var result := _validate_for_archive(grid, platforms, flag_row, abilities)
		if result.get("solvable", false):
			accepted.append(result)

		iter_done += 1
		if report and is_instance_valid(progress_receiver) and progress_receiver.has_method(progress_method):
			progress_receiver.call_deferred(
				progress_method, iter_done, tries, accepted.size(), ARCHIVE_MAX_LEVELS)

	# Run order: easier levels first (lower BFS explored-state count).
	accepted.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a.get("bfs_score", 0)) < int(b.get("bfs_score", 0))
	)

	var sorted_levels: Array = []
	for lvl: Dictionary in accepted:
		sorted_levels.append(lvl)
	var n_pcg: int = sorted_levels.size()

	var user_cancelled: bool = cancel != null and cancel.is_cancelled()
	if sorted_levels.is_empty() and not user_cancelled:
		push_warning(
			"LevelGenerator: archive empty after PCG; using flat fallback so the run can start.")
		sorted_levels.append(_make_flat_fallback(abilities))

	if not user_cancelled:
		push_warning("LevelGenerator: archive built – %d levels (%d PCG from %d iterations, max %d tries)." % [
			sorted_levels.size(), n_pcg, iter_done, tries])
	return sorted_levels


## Analyse a hand-crafted grid and return the same dict format as the archive.
## Pass abilities = [] to skip non-triviality check (useful while editing).
static func analyze_level(grid: Array, spawn_col: int, spawn_row: int,
		flag_col: int, flag_row: int, abilities: Array[StringName]) -> Dictionary:
	var spawn := Vector2i(spawn_col, spawn_row)
	var flag  := Vector2i(flag_col,  flag_row)
	var platforms := _grid_to_platforms(grid)

	# Full-ability solve first.
	var score: int = _bfs_solve(grid, spawn, flag, abilities, {}, 10)
	if score < 0:
		return {
			"solvable": false,
			"bfs_score": 0,
			"min_charges": {},
			"path_ability_uses": {},
			"platforms": platforms,
		}

	var mc: Dictionary = {}
	var path_uses: Dictionary = {}
	if not abilities.is_empty():
		mc = _find_min_charges_auto(grid, spawn, flag, abilities)
		path_uses = solution_ability_uses(
			grid, spawn.x, spawn.y, flag.x, flag.y, abilities, {}, 10)

	return {
		"solvable": true,
		"bfs_score": score,
		"min_charges": mc,
		"path_ability_uses": path_uses,
		"platforms": platforms,
		"spawn": Vector2((spawn_col + 0.5) * TILE, spawn_row * TILE),
		"flag": Vector2((flag_col  + 0.5) * TILE, flag_row  * TILE),
		"grid": grid,
	}


## One BFS solution path as grid cells (for editor visualization). Empty if unsolvable.
static func solution_path(grid: Array, spawn_col: int, spawn_row: int,
		flag_col: int, flag_row: int, abilities: Array[StringName],
		charge_overrides: Dictionary, max_charges: int = 10) -> Array[Vector2i]:
	var spawn := Vector2i(spawn_col, spawn_row)
	var flag := Vector2i(flag_col, flag_row)
	return _bfs_solve_path(grid, spawn, flag, abilities, charge_overrides, max_charges)


## Double jumps and horizontal passes **consumed** along the same BFS path as `solution_path`.
static func solution_ability_uses(grid: Array, spawn_col: int, spawn_row: int,
		flag_col: int, flag_row: int, abilities: Array[StringName],
		charge_overrides: Dictionary, max_charges: int = 10) -> Dictionary:
	var spawn := Vector2i(spawn_col, spawn_row)
	var flag := Vector2i(flag_col, flag_row)
	var d: Dictionary = _bfs_solve_path_core(grid, spawn, flag, abilities, charge_overrides, max_charges)
	if not d.get("ok", false):
		return {}
	var chain: Array = _reconstruct_state_chain(
		d["came_from"] as Dictionary, int(d["goal_key"]), int(d["max_hj"]), int(d["max_hp"]))
	return ability_uses_from_state_chain(chain, abilities)


## Single BFS: grid path (for overlay) + ability counts along that path (for UI).
static func solution_path_and_uses(grid: Array, spawn_col: int, spawn_row: int,
		flag_col: int, flag_row: int, abilities: Array[StringName],
		charge_overrides: Dictionary, max_charges: int = 10) -> Dictionary:
	var spawn := Vector2i(spawn_col, spawn_row)
	var flag := Vector2i(flag_col, flag_row)
	var d: Dictionary = _bfs_solve_path_core(grid, spawn, flag, abilities, charge_overrides, max_charges)
	if not d.get("ok", false):
		return {
			"path": [] as Array[Vector2i],
			"uses": {} as Dictionary,
			"edge_actions": [] as Array[StringName],
		}
	var came: Dictionary = d["came_from"] as Dictionary
	var gk: int = int(d["goal_key"])
	var max_hj: int = int(d["max_hj"])
	var max_hp: int = int(d["max_hp"])
	var raw_path: Array[Vector2i] = _reconstruct_path_cells(came, gk, max_hj, max_hp)
	var chain: Array = _reconstruct_state_chain(came, gk, max_hj, max_hp)
	var uses: Dictionary = ability_uses_from_state_chain(chain, abilities)
	var edge_actions: Array[StringName] = edge_actions_for_cell_path(chain, raw_path)
	return {"path": raw_path, "uses": uses, "edge_actions": edge_actions}


## Select a level from a pre-built archive by index (easiest → hardest).
## If sequential_no_recycle is true (main-menu PCG run), indices are clamped to the archive; the game should not load past the last level.
## Otherwise, when the tier exceeds the archive, cycles through the hardest quarter (open-ended / editor test runs).
static func pick_from_archive(archive: Array, difficulty_tier: int,
		abilities: Array[StringName], sequential_no_recycle: bool = false) -> Dictionary:
	if archive.is_empty():
		push_warning("LevelGenerator: archive empty, flat fallback.")
		return _make_flat_fallback(abilities)
	if difficulty_tier < archive.size():
		return archive[difficulty_tier]
	if sequential_no_recycle:
		push_warning("LevelGenerator: sequential PCG run requested level past archive end; using last level.")
		return archive[archive.size() - 1]
	@warning_ignore("integer_division")
	var hard_start: int = maxi(archive.size() * 3 / 4, 0)
	var hard_count: int = archive.size() - hard_start
	if hard_count <= 0:
		return archive[archive.size() - 1]
	var cycle_idx: int = (difficulty_tier - hard_start) % hard_count
	return archive[hard_start + cycle_idx]


# ── High Jump levels ──────────────────────────────────────────────────

static func _build_hj(rng: RandomNumberGenerator, grid: Array, num_cliffs: int) -> int:
	num_cliffs = clampi(num_cliffs, 1, 2)

	var total_obstacle_w: int = num_cliffs * CLIFF_W
	var num_sections: int = num_cliffs + 1
	var usable: int = FLAG_COL - SPAWN_COL + 1 - total_obstacle_w
	@warning_ignore("integer_division")
	var base_section_w: int = maxi(usable / num_sections, 4)

	var cursor: int = SPAWN_COL
	var current_ground: int = GROUND_ROW

	# Spawn section.
	var spawn_w: int = base_section_w + rng.randi_range(-2, 2)
	spawn_w = clampi(spawn_w, 4, base_section_w + 4)
	_set_rect(grid, 0, current_ground, cursor + spawn_w, ROWS - current_ground)
	cursor += spawn_w

	# Random pits in spawn section.
	var pit_count: int = rng.randi_range(0, 2)
	for _p in pit_count:
		if spawn_w < 7:
			break
		var pw: int = rng.randi_range(2, 4)
		var slo: int = SPAWN_COL + 2
		var shi: int = cursor - pw - 2
		var px: int = _pit_start_avoid_flag_floor_band(rng, slo, shi, pw)
		if px >= 0:
			_clear_rect(grid, px, current_ground, pw, ROWS - current_ground)

	# Place cliffs.
	for ci in num_cliffs:
		var raise: int = rng.randi_range(3, 4)
		var new_ground: int = maxi(current_ground - raise, 4)

		_set_rect(grid, cursor, new_ground, CLIFF_W, ROWS - new_ground)
		cursor += CLIFF_W

		var is_last: bool = (ci == num_cliffs - 1)
		var sec_w: int
		if is_last:
			sec_w = maxi(FLAG_COL + 1 - cursor, 3)
		else:
			sec_w = base_section_w + rng.randi_range(-2, 2)
			sec_w = clampi(sec_w, 3, FLAG_COL - cursor - (num_cliffs - ci - 1) * (CLIFF_W + 3))

		_set_rect(grid, cursor, new_ground, sec_w, ROWS - new_ground)

		# Random pits and platforms for variety.
		if sec_w >= 5:
			var n_pits: int = rng.randi_range(0, 2)
			for _p in n_pits:
				var pw: int = rng.randi_range(2, 3)
				if cursor + sec_w - pw - 2 <= cursor + 1:
					break
				var px: int = _pit_start_avoid_flag_floor_band(
					rng, cursor + 1, cursor + sec_w - pw - 2, pw)
				if px >= 0:
					_clear_rect(grid, px, new_ground, pw, ROWS - new_ground)

		if not is_last and sec_w >= 5 and rng.randf() < 0.4:
			var pw: int = rng.randi_range(2, 3)
			var px: int = rng.randi_range(cursor + 1, cursor + sec_w - pw - 1)
			px = clampi(px, cursor + 1, cursor + sec_w - pw)
			_set_rect(grid, px, new_ground - rng.randi_range(2, 3), pw, 1)

		cursor += sec_w
		current_ground = new_ground

	return current_ground - 1


# ── Horizontal Pass levels (rhythm grammar) ───────────────────────────
#
# Each room between walls gets one of four maze templates. All templates
# are solvable with normal walk + jump so ability requirements come
# exclusively from the full-height walls.
#
#  Template 0 – Bridge: pit in floor, platform at rf-2 spanning it.
#               Player jumps up 2 rows onto bridge, crosses, drops down.
#  Template 1 – Left raised: left half of room elevated +2 rows.
#               Player jumps up from right side, or drops down to right.
#  Template 2 – Right raised: mirror of template 1 with optional left pit.
#  Template 3 – Sequential: two bridge-over-pit obstacles in one room
#               (wide rooms) or one bridge (narrow rooms).

static func _build_hp(rng: RandomNumberGenerator, grid: Array, num_walls: int) -> int:
	const MIN_RW := 7
	num_walls = clampi(num_walls, 1, 4)
	# Shrink if there isn't enough horizontal space for all rooms + walls.
	while num_walls > 1 and (num_walls + 1) * MIN_RW + num_walls * WALL_W > FLAG_COL - SPAWN_COL + 1:
		num_walls -= 1
	var num_rooms: int = num_walls + 1

	var usable: int = FLAG_COL - SPAWN_COL + 1 - num_walls * WALL_W
	@warning_ignore("integer_division")
	var base_w: int = maxi(usable / num_rooms, MIN_RW)

	var cursor: int = SPAWN_COL
	var current_ground: int = GROUND_ROW

	# Spawn room: simple flat with optional shallow pit.
	var spawn_w: int = clampi(base_w + rng.randi_range(-1, 1), MIN_RW, base_w + 2)
	_set_rect(grid, cursor, current_ground, spawn_w, ROWS - current_ground)
	if spawn_w >= 9 and rng.randf() < 0.45:
		var pw: int = rng.randi_range(2, 3)
		var px: int = clampi(rng.randi_range(cursor + 3, cursor + spawn_w - pw - 2),
				cursor + 2, cursor + spawn_w - pw - 1)
		_clear_rect(grid, px, current_ground, pw, ROWS - current_ground)
	cursor += spawn_w

	for wi in num_walls:
		_set_rect(grid, cursor, 0, WALL_W, ROWS)
		cursor += WALL_W

		var is_last: bool = (wi == num_walls - 1)
		var rf: int = GROUND_ROW - (rng.randi_range(0, 1) if not is_last else 0)

		var rw: int
		if is_last:
			rw = maxi(FLAG_COL + 1 - cursor, MIN_RW)
		else:
			var remaining: int = num_walls - wi - 1
			var slack: int = FLAG_COL - cursor - remaining * (WALL_W + MIN_RW) - MIN_RW
			rw = clampi(base_w + rng.randi_range(-1, 2), MIN_RW, maxi(slack, MIN_RW))

		_set_rect(grid, cursor, rf, rw, ROWS - rf)

		if not is_last:
			_hp_maze_room(rng, grid, cursor, rw, rf)
		elif rw >= 8 and rng.randf() < 0.4:
			# Goal room: optional simple pit so the last stretch isn't trivial.
			var pw: int = 2
			var px: int = _pit_start_avoid_flag_floor_band(
				rng, cursor + 1, cursor + rw - pw - 1, pw)
			if px >= 0:
				_clear_rect(grid, px, rf, pw, ROWS - rf)

		cursor += rw
		current_ground = rf

	return current_ground - 1


## Place a maze-like interior into a room section.
## All templates stay solvable by normal walk/jump (no abilities needed inside a room).
static func _hp_maze_room(rng: RandomNumberGenerator, grid: Array,
		rx: int, rw: int, rf: int) -> void:
	if rw < 6:
		return

	match rng.randi() % 4:
		0:
			# Bridge over pit.
			# Bridge surface at rf-2: player at rf-1 can jump (dy=2) to stand at rf-3.
			var pit_w: int = clampi(rng.randi_range(3, rw - 4), 3, rw - 4)
			var pit_lo: int = rx + 1
			var pit_hi: int = rx + rw - pit_w - 1
			var pit_x: int = _pit_start_avoid_flag_floor_band(rng, pit_lo, pit_hi, pit_w)
			if pit_x >= 0:
				_clear_rect(grid, pit_x, rf, pit_w, ROWS - rf)
				var bx: int = maxi(pit_x - 1, rx)
				var bw: int = mini(pit_w + 2, rx + rw - bx)
				_set_rect(grid, bx, rf - 2, bw, 1)
		1:
			# Left half elevated by 2 rows.
			@warning_ignore("integer_division")
			var split: int = clampi(rw / 2 + rng.randi_range(-1, 1), 2, rw - 2)
			_set_rect(grid, rx, rf - 2, split, 2)
			if rw - split >= 5 and rng.randf() < 0.5:
				var pw: int = 2
				var lo1: int = rx + split
				var hi1: int = rx + rw - pw - 1
				var px: int = _pit_start_avoid_flag_floor_band(rng, lo1, hi1, pw)
				if px >= 0:
					_clear_rect(grid, px, rf, pw, ROWS - rf)
		2:
			# Right half elevated by 2 rows, optional left-side pit.
			@warning_ignore("integer_division")
			var split: int = clampi(rw / 2 + rng.randi_range(-1, 1), 2, rw - 2)
			_set_rect(grid, rx + rw - split, rf - 2, split, 2)
			if rw - split >= 5 and rng.randf() < 0.5:
				var pw: int = 2
				var lo2: int = rx + 1
				var hi2: int = rx + rw - split - pw - 1
				var px2: int = _pit_start_avoid_flag_floor_band(rng, lo2, hi2, pw)
				if px2 >= 0:
					_clear_rect(grid, px2, rf, pw, ROWS - rf)
		_:
			# Sequential: two bridge obstacles in wide rooms, one in narrow.
			if rw >= 12:
				@warning_ignore("integer_division")
				var half: int = rw / 2
				for side: int in 2:
					var sx: int = rx + side * half
					var sw: int = half if side == 0 else rw - half
					if sw >= 5:
						var pw: int = clampi(sw - 4, 2, 3)
						var lo3: int = sx + 1
						var hi3: int = sx + sw - pw - 1
						var px3: int = _pit_start_avoid_flag_floor_band(rng, lo3, hi3, pw)
						if px3 >= 0:
							_clear_rect(grid, px3, rf, pw, ROWS - rf)
							var bx: int = maxi(px3 - 1, sx)
							var bw: int = mini(pw + 2, sx + sw - bx)
							_set_rect(grid, bx, rf - 2, bw, 1)
			else:
				var pit_w: int = clampi(rw - 4, 2, 4)
				var lo4: int = rx + 1
				var hi4: int = rx + rw - pit_w - 1
				var pit_x: int = _pit_start_avoid_flag_floor_band(rng, lo4, hi4, pit_w)
				if pit_x >= 0:
					_clear_rect(grid, pit_x, rf, pit_w, ROWS - rf)
					_set_rect(grid, maxi(pit_x - 1, rx), rf - 2, pit_w + 2, 1)


# ── Combined levels ───────────────────────────────────────────────────

static func _build_combined(rng: RandomNumberGenerator, grid: Array,
		num_hj: int, num_hp: int) -> int:
	num_hj = clampi(num_hj, 1, 2)
	num_hp = clampi(num_hp, 1, 2)

	var obstacles: Array = []
	var hi := 0
	var wi := 0
	while hi < num_hj or wi < num_hp:
		if wi < num_hp and (wi <= hi or hi >= num_hj):
			obstacles.append(&"wall")
			wi += 1
		else:
			obstacles.append(&"cliff")
			hi += 1

	var num_obs: int = obstacles.size()
	var num_sections: int = num_obs + 1
	var total_obs_w: int = 0
	for ob: StringName in obstacles:
		total_obs_w += WALL_W if ob == &"wall" else CLIFF_W
	var usable: int = FLAG_COL - SPAWN_COL + 1 - total_obs_w
	@warning_ignore("integer_division")
	var base_w: int = maxi(usable / num_sections, 4)

	var cursor: int = SPAWN_COL
	var current_ground: int = GROUND_ROW

	var spawn_w: int = base_w + rng.randi_range(-1, 1)
	spawn_w = clampi(spawn_w, 4, base_w + 2)
	_set_rect(grid, 0, current_ground, cursor + spawn_w, ROWS - current_ground)
	cursor += spawn_w

	for oi in num_obs:
		var obs_type: StringName = obstacles[oi]
		var is_last: bool = (oi == num_obs - 1)

		if obs_type == &"wall":
			_set_rect(grid, cursor, 0, WALL_W, ROWS)
			cursor += WALL_W
		else:
			var raise: int = rng.randi_range(3, 4)
			var new_ground: int = maxi(current_ground - raise, 4)
			_set_rect(grid, cursor, new_ground, CLIFF_W, ROWS - new_ground)
			cursor += CLIFF_W
			current_ground = new_ground

		var sec_w: int
		if is_last:
			sec_w = maxi(FLAG_COL + 1 - cursor, 4)
		else:
			sec_w = base_w + rng.randi_range(-1, 1)
			sec_w = clampi(sec_w, 4, FLAG_COL - cursor - (num_obs - oi - 1) * 6)

		_set_rect(grid, cursor, current_ground, sec_w, ROWS - current_ground)

		if obs_type == &"wall" and sec_w >= 6:
			# After a wall: apply a maze room so the player dashes through then
			# immediately navigates a platform/pit challenge.
			_hp_maze_room(rng, grid, cursor, sec_w, current_ground)
		elif obs_type == &"cliff" and sec_w >= 5:
			# After a cliff: pits and optional stepping stone for variety.
			var n_pits: int = rng.randi_range(1, 2)
			for _p in n_pits:
				var pw: int = rng.randi_range(2, 3)
				if cursor + sec_w - pw - 1 > cursor + 1:
					var px: int = _pit_start_avoid_flag_floor_band(
						rng, cursor + 1, cursor + sec_w - pw - 1, pw)
					if px >= 0:
						_clear_rect(grid, px, current_ground, pw, ROWS - current_ground)
			if not is_last and rng.randf() < 0.5:
				var plat_w: int = rng.randi_range(2, 3)
				var plat_x: int = clampi(rng.randi_range(cursor + 1, cursor + sec_w - plat_w), cursor + 1, cursor + sec_w - plat_w)
				_set_rect(grid, plat_x, current_ground - rng.randi_range(2, 3), plat_w, 1)

		cursor += sec_w

	return current_ground - 1


# ── Validation & scoring ──────────────────────────────────────────────

static func _validate_for_archive(grid: Array, platforms: Array, flag_row: int,
		abilities: Array[StringName]) -> Dictionary:
	if _is_solid(grid, FLAG_COL, flag_row):
		return {"solvable": false}
	var spawn := Vector2i(SPAWN_COL, GROUND_ROW - 1)
	var flag := Vector2i(FLAG_COL, flag_row)

	# One path BFS only — repeating _bfs_solve + solution_ability_uses tripled work per attempt
	# and could stall generation for minutes on large state spaces.
	var d: Dictionary = _bfs_solve_path_core(grid, spawn, flag, abilities, {}, 10)
	if not d.get("ok", false):
		return {"solvable": false}

	var came: Dictionary = d["came_from"] as Dictionary
	var score: int = came.size()
	# Minimum charges per ability (0 allowed). Do not use one BFS path's tallies — that path need not
	# minimize DJ/HP, and max(..., 1) falsely required every card every level.
	var min_charges: Dictionary = _find_min_charges_auto(grid, spawn, flag, abilities)

	return {
		"platforms": platforms,
		"spawn": Vector2((SPAWN_COL + 0.5) * TILE, (GROUND_ROW - 1) * TILE),
		"flag": Vector2((FLAG_COL + 0.5) * TILE, flag_row * TILE),
		"solvable": true,
		"grid": grid,
		"min_charges": min_charges,
		"bfs_score": score,
	}


static func _find_min_charges_auto(grid: Array, spawn: Vector2i, flag: Vector2i,
		abilities: Array[StringName]) -> Dictionary:
	var result: Dictionary = {}
	for id: StringName in abilities:
		for count in range(0, 11):
			var overrides: Dictionary = {id: count}
			if _bfs_solve(grid, spawn, flag, abilities, overrides, 10) >= 0:
				result[id] = count
				break
		if not result.has(id):
			result[id] = 10
	return result


# ── Helpers ────────────────────────────────────────────────────────────

static func _empty_grid() -> Array:
	var grid: Array = []
	for _r in ROWS:
		var row: Array = []
		for _c in COLS:
			row.append(false)
		grid.append(row)
	return grid


static func _set_rect(grid: Array, col: int, row: int, width: int, height: int) -> void:
	for r in height:
		for c in width:
			var gr := row + r
			var gc := col + c
			if gr >= 0 and gr < ROWS and gc >= 0 and gc < COLS:
				grid[gr][gc] = true


static func _clear_rect(grid: Array, col: int, row: int, width: int, height: int) -> void:
	for r in height:
		for c in width:
			var gr := row + r
			var gc := col + c
			if gr >= 0 and gr < ROWS and gc >= 0 and gc < COLS:
				grid[gr][gc] = false


## Hard guarantee for PCG: the exact goal tile must be empty.
static func _ensure_flag_cell_clear(grid: Array, flag_row: int) -> void:
	if flag_row < 0 or flag_row >= ROWS:
		return
	grid[flag_row][FLAG_COL] = false


static func _grid_to_platforms(grid: Array) -> Array:
	var out: Array = []
	var visited: Array = _empty_grid()
	for r in ROWS:
		for c in COLS:
			if grid[r][c] and not visited[r][c]:
				var run_end := c
				while run_end < COLS and grid[r][run_end] and not visited[r][run_end]:
					run_end += 1
				var h := 1
				var ok := true
				while r + h < ROWS and ok:
					for cc in range(c, run_end):
						if not grid[r + h][cc] or visited[r + h][cc]:
							ok = false
							break
					if ok:
						h += 1
				for rr in range(r, r + h):
					for cc in range(c, run_end):
						visited[rr][cc] = true
				out.append({"col": c, "row": r, "width": run_end - c, "height": h})
	return out


static func _make_flat_fallback(abilities: Array[StringName]) -> Dictionary:
	var grid: Array = _empty_grid()
	_set_rect(grid, 0, GROUND_ROW, COLS, ROWS - GROUND_ROW)
	var mc: Dictionary = {}
	for id: StringName in abilities:
		mc[id] = 1
	return {
		"platforms": _grid_to_platforms(grid),
		"spawn": Vector2((SPAWN_COL + 0.5) * TILE, (GROUND_ROW - 1) * TILE),
		"flag": Vector2((FLAG_COL + 0.5) * TILE, (GROUND_ROW - 1) * TILE),
		"solvable": true,
		"grid": grid,
		"min_charges": mc,
		# Sorts last in ascending bfs_score runs (only used when PCG produced nothing).
		"bfs_score": 9_999_999,
	}


## Editor / export JSON → runtime dictionary for `game_session` (empty if invalid).
static func level_data_from_saved_dict(d: Dictionary) -> Dictionary:
	var raw_grid = d.get("grid", [])
	if raw_grid.size() != ROWS:
		return {}
	var grid: Array = []
	for r in ROWS:
		var src = raw_grid[r]
		if not src is Array or (src as Array).size() < COLS:
			return {}
		var row: Array = []
		for c in COLS:
			row.append(bool((src as Array)[c]))
		grid.append(row)

	var sc: int = clampi(int(d.get("spawn_col", SPAWN_COL)), 0, COLS - 1)
	var sr: int = clampi(int(d.get("spawn_row", GROUND_ROW - 1)), 0, ROWS - 1)
	var fc: int = clampi(int(d.get("flag_col", FLAG_COL)), 0, COLS - 1)
	var fr: int = clampi(int(d.get("flag_row", GROUND_ROW - 1)), 0, ROWS - 1)

	var spawn_v: Vector2
	var flag_v: Vector2
	var sp = d.get("spawn", null)
	var fg = d.get("flag", null)
	if sp is Dictionary:
		spawn_v = Vector2(float(sp.get("x", 0.0)), float(sp.get("y", 0.0)))
	else:
		spawn_v = Vector2((sc + 0.5) * TILE, sr * TILE)
	if fg is Dictionary:
		flag_v = Vector2(float(fg.get("x", 0.0)), float(fg.get("y", 0.0)))
	else:
		flag_v = Vector2((fc + 0.5) * TILE, fr * TILE)

	var mc: Dictionary = {}
	var mc_raw = d.get("min_charges", {})
	if mc_raw is Dictionary:
		for k in mc_raw as Dictionary:
			mc[StringName(str(k))] = int((mc_raw as Dictionary)[k])

	return {
		"platforms": _grid_to_platforms(grid),
		"spawn": spawn_v,
		"flag": flag_v,
		"solvable": bool(d.get("solvable", true)),
		"grid": grid,
		"min_charges": mc,
		"bfs_score": int(d.get("bfs_score", 0)),
	}


## Paths to try for one puzzle (editor `user://` first, then bundled `res://levels/`).
static func puzzle_json_lookup_candidates(primary: String) -> PackedStringArray:
	var out := PackedStringArray()
	var p := primary.strip_edges()
	if p.is_empty():
		return out
	if p.begins_with("user://") or p.begins_with("res://"):
		out.append(p)
		var fn := p.get_file()
		if fn.ends_with(".json"):
			if p.begins_with(PUZZLES_USER_DIR):
				out.append(PUZZLES_RES_DIR + fn)
			elif p.begins_with(PUZZLES_RES_DIR):
				out.append(PUZZLES_USER_DIR + fn)
		return out
	var stem := p.get_basename() if p.ends_with(".json") else p
	out.append(PUZZLES_USER_DIR + stem + ".json")
	out.append(PUZZLES_RES_DIR + stem + ".json")
	return out


static func _load_level_json_single_file(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var text := f.get_as_text()
	f.close()
	var j := JSON.new()
	if j.parse(text) != OK:
		return {}
	var root = j.get_data()
	if not root is Dictionary:
		return {}
	return level_data_from_saved_dict(root as Dictionary)


static func load_level_from_json_path(path: String) -> Dictionary:
	for cand: String in puzzle_json_lookup_candidates(path):
		var d: Dictionary = _load_level_json_single_file(cand)
		if not d.is_empty():
			return d
	return {}


static func format_puzzle_path_for_user(path: String) -> String:
	if path.is_empty():
		return ""
	if path.begins_with("user://") or path.begins_with("res://"):
		return ProjectSettings.globalize_path(path)
	return path


# ── Arc clearance ──────────────────────────────────────────────────────

static func _arc_clear(grid: Array, x1: int, x2: int, peak_y: int) -> bool:
	if peak_y < 0:
		return true
	if peak_y < JUMP_MIN_ROW:
		return false
	if peak_y >= ROWS:
		return true
	var step: int = 1 if x2 > x1 else -1
	if x1 == x2:
		return true
	var cx: int = x1 + step
	while cx != x2:
		if cx < 0 or cx >= COLS:
			return false
		if _is_solid(grid, cx, peak_y):
			return false
		cx += step
	return true


## True if every cell on the Bresenham line between stance cells is in-bounds air (no solids).
## Jumps used to call only _arc_clear, which skipped all checks when start/end columns matched,
## so vertical moves could pass through pillars; flat jumps still pair this with _arc_clear at peak_y.
static func _stance_segment_air_clear(grid: Array, x0: int, y0: int, x1: int, y1: int) -> bool:
	var dx: int = absi(x1 - x0)
	var dy: int = absi(y1 - y0)
	var sx: int = 1 if x0 < x1 else -1
	var sy: int = 1 if y0 < y1 else -1
	var err: int = dx - dy
	var x: int = x0
	var y: int = y0
	while true:
		if x < 0 or x >= COLS or y < 0 or y >= ROWS:
			return false
		if y < JUMP_MIN_ROW:
			return false
		if _is_solid(grid, x, y):
			return false
		if x == x1 and y == y1:
			break
		var e2: int = 2 * err
		if e2 > -dy:
			err -= dy
			x += sx
		if e2 < dx:
			err += dx
			y += sy
	return true


static func _jump_clear(grid: Array, sx: int, sy: int, nx: int, ny: int, peak_y: int) -> bool:
	if not _stance_segment_air_clear(grid, sx, sy, nx, ny):
		return false
	if sx != nx and not _arc_clear(grid, sx, nx, peak_y):
		return false
	return true


## Horizontal pass: crosses exactly one solid column at stance_y in `dir`, then lands in the next air column.
## Costs one charge per activation (always 1 when valid).
## dir -1 = wall on the left, +1 = wall on the right. Landing falls to nearest floor in that column.
## Returns {"land_x","land_y","cost"} or {} if unusable.
static func horizontal_pass_result(grid: Array, stance_x: int, stance_y: int, dir: int, hp_avail: int) -> Dictionary:
	if hp_avail <= 0:
		return {}
	if dir != -1 and dir != 1:
		return {}
	var cx: int = stance_x + dir
	if cx < 0 or cx >= COLS or not _is_solid(grid, cx, stance_y):
		return {}
	var tiles: int = 0
	while cx >= 0 and cx < COLS and _is_solid(grid, cx, stance_y):
		tiles += 1
		cx += dir
	if tiles > HORIZONTAL_PASS_MAX_SOLID_TILES:
		return {}
	if tiles > hp_avail:
		return {}
	if cx < 0 or cx >= COLS or _is_solid(grid, cx, stance_y):
		return {}
	var land_x: int = cx
	var land_y: int = stance_y
	while land_y + 1 < ROWS and not _is_solid(grid, land_x, land_y + 1):
		land_y += 1
	if not _is_valid_stand(grid, land_x, land_y):
		return {}
	return {"land_x": land_x, "land_y": land_y, "cost": tiles}


## Snap against the edge of the landing tile that touches the wall (not tile center — that felt too far out).
## pass_dir is the same as horizontal_pass_result: +1 passed through a wall on your right, −1 wall on your left.
static func horizontal_pass_world_position(land_x: int, land_y: int, pass_dir: int) -> Vector2:
	const WALL_SNAP_FRAC := 0.44
	var tf: float = float(TILE)
	# ~14px from the wall-side edge of the 32px tile → ~20px-wide body sits just into air (tweak with TILE).
	var wx: float
	if pass_dir == 1:
		wx = float(land_x) * tf + tf * WALL_SNAP_FRAC
	elif pass_dir == -1:
		wx = float(land_x + 1) * tf - tf * WALL_SNAP_FRAC
	else:
		wx = (float(land_x) + 0.5) * tf
	return Vector2(wx, float(land_y) * tf)


## Air in this cell, feet not on a surface (void or air below) — mid-jump / falling between tiles.
static func _is_airborne_cell(grid: Array, x: int, y: int) -> bool:
	if x < 0 or x >= COLS or y < 0 or y >= ROWS:
		return false
	if _is_solid(grid, x, y):
		return false
	if _is_valid_stand(grid, x, y):
		return false
	return true


static func _fall_to_stand_row(grid: Array, col: int, start_y: int) -> int:
	var fy: int = start_y
	while fy + 1 < ROWS and not _is_solid(grid, col, fy + 1):
		fy += 1
	if _is_valid_stand(grid, col, fy):
		return fy
	return -1


## After a jump arc to (nx, ny): stand on platform, stop at apex (airborne), or skim to floor below.
## dj_air_spent: for new *airborne* nodes, 1 if double-jump charge already used since last stand (player model).
static func _enqueue_jump_landings(
		grid: Array, queue: Array, visited: Dictionary, came_from: Dictionary, parent_key: int,
		path_mode: bool, nx: int, ny: int, hj_u: int, hp_u: int, max_hj: int, max_hp: int,
		dj_air_spent: int) -> void:
	if _is_valid_stand(grid, nx, ny):
		if path_mode:
			_enqueue_path(queue, came_from, parent_key, nx, ny, hj_u, hp_u, max_hj, max_hp, 0)
		else:
			_enqueue(queue, visited, nx, ny, hj_u, hp_u, max_hj, max_hp, 0)
		return
	if nx < 0 or nx >= COLS or _is_solid(grid, nx, ny):
		return
	if _is_airborne_cell(grid, nx, ny):
		if path_mode:
			_enqueue_path(queue, came_from, parent_key, nx, ny, hj_u, hp_u, max_hj, max_hp, dj_air_spent)
		else:
			_enqueue(queue, visited, nx, ny, hj_u, hp_u, max_hj, max_hp, dj_air_spent)
	var fy: int = ny
	while fy + 1 < ROWS and not _is_solid(grid, nx, fy + 1):
		fy += 1
	if _is_valid_stand(grid, nx, fy):
		if path_mode:
			_enqueue_path(queue, came_from, parent_key, nx, fy, hj_u, hp_u, max_hj, max_hp, 0)
		else:
			_enqueue(queue, visited, nx, fy, hj_u, hp_u, max_hj, max_hp, 0)


## Feet on ground: only `sy`. Mid-air: try nearby rows so wall slices match torso, not only feet cell.
static func _enqueue_horizontal_passes_from_state(
		grid: Array, queue: Array, visited: Dictionary, came_from: Dictionary, parent_key: int,
		path_mode: bool,
		sx: int, sy: int, hj: int, hp: int, max_hj: int, max_hp: int, airborne: bool) -> void:
	if hp <= 0:
		return
	var row_order: Array = [0, -1, 1, -2, 2]
	for offi: int in row_order:
		if not airborne and offi != 0:
			continue
		var try_y: int = sy + offi
		if try_y < JUMP_MIN_ROW or try_y >= ROWS:
			continue
		for dir_a: int in [-1, 1]:
			var hp_ra: Dictionary = horizontal_pass_result(grid, sx, try_y, dir_a, hp)
			if hp_ra.is_empty():
				continue
			var lx: int = int(hp_ra["land_x"])
			var ly: int = int(hp_ra["land_y"])
			var cst: int = int(hp_ra["cost"])
			if path_mode:
				_enqueue_path(queue, came_from, parent_key, lx, ly, hj, hp - cst, max_hj, max_hp, 0)
			else:
				_enqueue(queue, visited, lx, ly, hj, hp - cst, max_hj, max_hp, 0)


# ── BFS solver ─────────────────────────────────────────────────────────
# Returns number of states explored (>= 0) on success, -1 on failure.

static func _bfs_solve(
		grid: Array, spawn: Vector2i, flag: Vector2i,
		abilities: Array[StringName], charge_overrides: Dictionary,
		max_charges: int = 10) -> int:

	var hj_start: int = 0
	var hp_start: int = 0
	if &"high_jump" in abilities:
		hj_start = int(charge_overrides.get(&"high_jump", max_charges))
	if &"horizontal_pass" in abilities:
		hp_start = int(charge_overrides.get(&"horizontal_pass", max_charges))
	var max_hj: int = hj_start
	var max_hp: int = hp_start
	var visit_cap: int = _bfs_visit_cap(max_hj, max_hp)

	var queue: Array = [[spawn.x, spawn.y, hj_start, hp_start, 0]]
	var visited: Dictionary = {}
	visited[_key(spawn.x, spawn.y, hj_start, hp_start, max_hj, max_hp, 0)] = true
	var qi: int = 0

	while qi < queue.size():
		if visited.size() > visit_cap:
			return -1
		var s: Array = queue[qi]
		qi += 1
		var sx: int = s[0]
		var sy: int = s[1]
		var hj: int = s[2]
		var hp: int = s[3]
		var s_air_dj_spent: int = int(s[4])

		if _is_valid_stand(grid, sx, sy) and absi(sx - flag.x) <= 1 and sy <= flag.y:
			return visited.size()

		var dummy_cf: Dictionary = {}
		if _is_valid_stand(grid, sx, sy):
			for dx: int in [-1, 1]:
				var nxw := sx + dx
				if _is_valid_stand(grid, nxw, sy):
					_enqueue(queue, visited, nxw, sy, hj, hp, max_hj, max_hp, 0)
				if nxw >= 0 and nxw < COLS and not _is_solid(grid, nxw, sy) and not _is_solid(grid, nxw, sy + 1):
					var fy_w := sy
					while fy_w + 1 < ROWS and not _is_solid(grid, nxw, fy_w + 1):
						fy_w += 1
					if _is_valid_stand(grid, nxw, fy_w):
						_enqueue(queue, visited, nxw, fy_w, hj, hp, max_hj, max_hp, 0)

			# First jump from floor does not spend a double-jump charge (see player.gd).
			var normal_peak: int = sy - NORMAL_JUMP_UP
			for dy: int in range(0, NORMAL_JUMP_UP + 1):
				for ddx: int in range(-NORMAL_JUMP_H, NORMAL_JUMP_H + 1):
					if dy == 0 and absi(ddx) <= 1:
						continue
					var nxj := sx + ddx
					var nyj := sy - dy
					if not _jump_clear(grid, sx, sy, nxj, nyj, normal_peak):
						continue
					_enqueue_jump_landings(grid, queue, visited, dummy_cf, -1, false, nxj, nyj, hj, hp, max_hj, max_hp, 0)

			if hp > 0:
				_enqueue_horizontal_passes_from_state(
					grid, queue, visited, dummy_cf, -1, false, sx, sy, hj, hp, max_hj, max_hp, false)

		elif _is_airborne_cell(grid, sx, sy):
			var fya: int = _fall_to_stand_row(grid, sx, sy)
			if fya >= 0:
				_enqueue(queue, visited, sx, fya, hj, hp, max_hj, max_hp, 0)
			# One double-jump impulse per airborne segment (player._has_double_jumped).
			if hj > 0 and s_air_dj_spent == 0:
				for dy: int in range(1, HIGH_JUMP_UP + 1):
					var arc_peak: int = sy - (NORMAL_JUMP_UP if dy <= NORMAL_JUMP_UP else HIGH_JUMP_UP)
					for ddx: int in range(-HIGH_JUMP_H, HIGH_JUMP_H + 1):
						if dy <= NORMAL_JUMP_UP and absi(ddx) <= 1:
							continue
						var nxa := sx + ddx
						var nya := sy - dy
						if not _jump_clear(grid, sx, sy, nxa, nya, arc_peak):
							continue
						_enqueue_jump_landings(grid, queue, visited, dummy_cf, -1, false, nxa, nya, hj - 1, hp, max_hj, max_hp, 1)
			if hp > 0:
				_enqueue_horizontal_passes_from_state(
					grid, queue, visited, dummy_cf, -1, false, sx, sy, hj, hp, max_hj, max_hp, true)

	return -1


## Returns ok, goal_key, came_from, max_hj for a shortest path (same BFS as path overlay).
static func _bfs_solve_path_core(
		grid: Array, spawn: Vector2i, flag: Vector2i,
		abilities: Array[StringName], charge_overrides: Dictionary,
		max_charges: int = 10) -> Dictionary:

	var hj_start: int = 0
	var hp_start: int = 0
	if &"high_jump" in abilities:
		hj_start = int(charge_overrides.get(&"high_jump", max_charges))
	if &"horizontal_pass" in abilities:
		hp_start = int(charge_overrides.get(&"horizontal_pass", max_charges))
	var max_hj: int = hj_start
	var max_hp: int = hp_start
	var visit_cap: int = _bfs_visit_cap(max_hj, max_hp)

	var queue: Array = [[spawn.x, spawn.y, hj_start, hp_start, 0]]
	var came_from: Dictionary = {}
	var root_k: int = _key(spawn.x, spawn.y, hj_start, hp_start, max_hj, max_hp, 0)
	came_from[root_k] = -1
	var qi: int = 0
	var goal_key: int = -1

	while qi < queue.size():
		if came_from.size() > visit_cap:
			return {"ok": false}
		var s: Array = queue[qi]
		qi += 1
		var sx: int = s[0]
		var sy: int = s[1]
		var hj: int = s[2]
		var hp: int = s[3]
		var s_air_dj_spent: int = int(s[4])
		var cur_key: int = _key(sx, sy, hj, hp, max_hj, max_hp, s_air_dj_spent)

		if _is_valid_stand(grid, sx, sy) and absi(sx - flag.x) <= 1 and sy <= flag.y:
			goal_key = cur_key
			break

		if _is_valid_stand(grid, sx, sy):
			for dx: int in [-1, 1]:
				var nxw := sx + dx
				if _is_valid_stand(grid, nxw, sy):
					_enqueue_path(queue, came_from, cur_key, nxw, sy, hj, hp, max_hj, max_hp, 0)
				if nxw >= 0 and nxw < COLS and not _is_solid(grid, nxw, sy) and not _is_solid(grid, nxw, sy + 1):
					var fy_w := sy
					while fy_w + 1 < ROWS and not _is_solid(grid, nxw, fy_w + 1):
						fy_w += 1
					if _is_valid_stand(grid, nxw, fy_w):
						_enqueue_path(queue, came_from, cur_key, nxw, fy_w, hj, hp, max_hj, max_hp, 0)

			var normal_peak: int = sy - NORMAL_JUMP_UP
			for dy: int in range(0, NORMAL_JUMP_UP + 1):
				for ddx: int in range(-NORMAL_JUMP_H, NORMAL_JUMP_H + 1):
					if dy == 0 and absi(ddx) <= 1:
						continue
					var nxj := sx + ddx
					var nyj := sy - dy
					if not _jump_clear(grid, sx, sy, nxj, nyj, normal_peak):
						continue
					_enqueue_jump_landings(grid, queue, {}, came_from, cur_key, true, nxj, nyj, hj, hp, max_hj, max_hp, 0)

			if hp > 0:
				_enqueue_horizontal_passes_from_state(
					grid, queue, {}, came_from, cur_key, true, sx, sy, hj, hp, max_hj, max_hp, false)

		elif _is_airborne_cell(grid, sx, sy):
			var fya: int = _fall_to_stand_row(grid, sx, sy)
			if fya >= 0:
				_enqueue_path(queue, came_from, cur_key, sx, fya, hj, hp, max_hj, max_hp, 0)
			if hj > 0 and s_air_dj_spent == 0:
				for dy: int in range(1, HIGH_JUMP_UP + 1):
					var arc_peak: int = sy - (NORMAL_JUMP_UP if dy <= NORMAL_JUMP_UP else HIGH_JUMP_UP)
					for ddx: int in range(-HIGH_JUMP_H, HIGH_JUMP_H + 1):
						if dy <= NORMAL_JUMP_UP and absi(ddx) <= 1:
							continue
						var nxa := sx + ddx
						var nya := sy - dy
						if not _jump_clear(grid, sx, sy, nxa, nya, arc_peak):
							continue
						_enqueue_jump_landings(grid, queue, {}, came_from, cur_key, true, nxa, nya, hj - 1, hp, max_hj, max_hp, 1)
			if hp > 0:
				_enqueue_horizontal_passes_from_state(
					grid, queue, {}, came_from, cur_key, true, sx, sy, hj, hp, max_hj, max_hp, true)

	if goal_key < 0:
		return {"ok": false}
	return {"ok": true, "goal_key": goal_key, "came_from": came_from, "max_hj": max_hj, "max_hp": max_hp}


## BFS with parent chain; returns tile centers along one solution path (deduped), or empty.
static func _bfs_solve_path(
		grid: Array, spawn: Vector2i, flag: Vector2i,
		abilities: Array[StringName], charge_overrides: Dictionary,
		max_charges: int = 10) -> Array[Vector2i]:
	var d: Dictionary = _bfs_solve_path_core(grid, spawn, flag, abilities, charge_overrides, max_charges)
	if not d.get("ok", false):
		return []
	return _reconstruct_path_cells(
		d["came_from"] as Dictionary, int(d["goal_key"]), int(d["max_hj"]), int(d["max_hp"]))


static func _reconstruct_state_chain(came_from: Dictionary, end_key: int, max_hj: int, max_hp: int) -> Array:
	var raw: Array = []
	var k: int = end_key
	while k != -1:
		var st: Array = _decode_state(k, max_hj, max_hp)
		raw.append([int(st[0]), int(st[1]), int(st[2]), int(st[3])])
		k = int(came_from[k])
	raw.reverse()
	return raw


static func ability_uses_from_state_chain(chain: Array, abilities: Array[StringName]) -> Dictionary:
	var hj_u: int = 0
	var hp_u: int = 0
	for i in range(chain.size() - 1):
		var a: Array = chain[i]
		var b: Array = chain[i + 1]
		hj_u += maxi(int(a[2]) - int(b[2]), 0)
		hp_u += maxi(int(a[3]) - int(b[3]), 0)
	var out: Dictionary = {}
	if &"high_jump" in abilities:
		out[&"high_jump"] = hj_u
	if &"horizontal_pass" in abilities:
		out[&"horizontal_pass"] = hp_u
	return out


static func _classify_state_edge(a: Array, b: Array) -> StringName:
	var dhp: int = int(a[3]) - int(b[3])
	var dhj: int = int(a[2]) - int(b[2])
	var ax: int = int(a[0])
	var ay: int = int(a[1])
	var bx: int = int(b[0])
	var by: int = int(b[1])
	if dhp > 0:
		return &"horizontal_pass"
	if dhj > 0:
		return &"high_jump"
	if bx == ax and by > ay:
		return &"fall"
	if by < ay:
		return &"jump"
	if by == ay and bx != ax:
		return &"walk"
	return &"move"


static func _merge_edge_labels(acc: Array[StringName]) -> StringName:
	for id: StringName in [&"horizontal_pass", &"high_jump", &"jump", &"fall", &"walk"]:
		if id in acc:
			return id
	return &"move"


## One label per consecutive pair in `cell_path` (length cell_path.size()-1), aligned with solver state chain.
static func edge_actions_for_cell_path(chain: Array, cell_path: Array[Vector2i]) -> Array[StringName]:
	var out: Array[StringName] = []
	if chain.size() < 2 or cell_path.size() < 2:
		return out
	var pi: int = 0
	var acc: Array[StringName] = []
	for i in range(chain.size() - 1):
		var a: Array = chain[i]
		var b: Array = chain[i + 1]
		acc.append(_classify_state_edge(a, b))
		var pos_b := Vector2i(int(b[0]), int(b[1]))
		if pi + 1 < cell_path.size() and pos_b == cell_path[pi + 1]:
			out.append(_merge_edge_labels(acc))
			acc.clear()
			pi += 1
			if pi >= cell_path.size() - 1:
				break
	if out.size() != cell_path.size() - 1:
		out.clear()
		for _j in range(maxi(cell_path.size() - 1, 0)):
			out.append(&"move")
	return out


static func _enqueue_path(
		queue: Array, came_from: Dictionary, parent_key: int,
		x: int, y: int, hj: int, hp: int,
		max_hj: int, max_hp: int, air_dj_spent: int) -> void:
	var k := _key(x, y, hj, hp, max_hj, max_hp, air_dj_spent)
	if came_from.has(k):
		return
	came_from[k] = parent_key
	queue.append([x, y, hj, hp, air_dj_spent])


static func _decode_state(key: int, max_hj: int, max_hp: int) -> Array:
	var layer: int = COLS * ROWS * (max_hj + 1) * (max_hp + 1)
	var air_dj_spent: int = key / layer
	var rem: int = key % layer
	var stride_hp: int = COLS * ROWS * (max_hj + 1)
	var hp: int = rem / stride_hp
	var rem2: int = rem % stride_hp
	var M: int = COLS * ROWS
	var hj: int = rem2 / M
	var rem3: int = rem2 % M
	var y: int = rem3 / COLS
	var x: int = rem3 % COLS
	return [x, y, hj, hp, air_dj_spent]


static func _reconstruct_path_cells(came_from: Dictionary, end_key: int, max_hj: int, max_hp: int) -> Array[Vector2i]:
	var raw: Array[Vector2i] = []
	var k: int = end_key
	while k != -1:
		var st: Array = _decode_state(k, max_hj, max_hp)
		raw.append(Vector2i(int(st[0]), int(st[1])))
		k = int(came_from[k])
	raw.reverse()
	var out: Array[Vector2i] = []
	for p: Vector2i in raw:
		if out.is_empty() or out[out.size() - 1] != p:
			out.append(p)
	return out


static func _enqueue(
		queue: Array, visited: Dictionary,
		x: int, y: int, hj: int, hp: int,
		max_hj: int, max_hp: int, air_dj_spent: int) -> void:
	var k := _key(x, y, hj, hp, max_hj, max_hp, air_dj_spent)
	if not visited.has(k):
		visited[k] = true
		queue.append([x, y, hj, hp, air_dj_spent])


static func _key(x: int, y: int, hj: int, hp: int, max_hj: int, max_hp: int, air_dj_spent: int) -> int:
	return (
			x + y * COLS
			+ hj * COLS * ROWS
			+ hp * COLS * ROWS * (max_hj + 1)
			+ air_dj_spent * COLS * ROWS * (max_hj + 1) * (max_hp + 1))


static func _is_solid(grid: Array, x: int, y: int) -> bool:
	if x < 0 or x >= COLS or y < 0 or y >= ROWS:
		return false
	return grid[y][x] as bool


static func _is_valid_stand(grid: Array, x: int, y: int) -> bool:
	if x < 0 or x >= COLS or y < 0 or y >= ROWS:
		return false
	if _is_solid(grid, x, y):
		return false
	if y + 1 >= ROWS:
		return true
	return _is_solid(grid, x, y + 1)
