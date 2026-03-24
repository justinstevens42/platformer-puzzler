extends Control

## Preload avoids global `class_name` resolution during parse (breaks circular / cascade errors in 4.x).
const _LG := preload("res://scripts/level_generator.gd")
const _TilePlatformDraw := preload("res://scripts/tile_platform_draw.gd")

# ── Constants ────────────────────────────────────────────────────────────────
const COLS     := _LG.COLS
const ROWS     := _LG.ROWS
const TILE_PX  := _LG.TILE   # world pixel size, used for coord conversion

const COL_AIR    := Color(0.13, 0.17, 0.27)
const COL_SOLID  := Color(0.55, 0.33, 0.18)
const COL_GRID   := Color(0.30, 0.32, 0.42, 0.35)
const COL_SPAWN  := Color(0.20, 0.95, 0.30, 0.85)
const COL_FLAG   := Color(0.95, 0.25, 0.20, 0.85)
const COL_HOVER  := Color(1.0,  1.0,  1.0,  0.18)
## Muted route line (rough player trajectory through cell centers).
const COL_PATH   := Color(0.95, 0.78, 0.22, 0.42)
const COL_EDGE_HP   := Color(0.42, 0.62, 0.98, 0.92)
const COL_EDGE_DJ   := Color(0.32, 0.90, 0.48, 0.92)
const COL_EDGE_JUMP := Color(0.98, 0.68, 0.22, 0.92)

# ── State ────────────────────────────────────────────────────────────────────
var _grid:  Array = []
var _spawn: Vector2i = Vector2i(_LG.SPAWN_COL, _LG.GROUND_ROW - 1)
var _flag:  Vector2i = Vector2i(_LG.FLAG_COL,  _LG.GROUND_ROW - 1)

var _has_hj: bool = true
var _has_hp: bool = true
var _hj_charges: int = 2
var _hp_charges: int = 2

var _tool: StringName = &"tile"   # tile | erase | spawn | flag
var _painting: bool = false
var _paint_solid: bool = true
var _hover: Vector2i = Vector2i(-1, -1)

var _status_text: String = ""
## Solver cell path + one action label per edge (same length as path minus one).
var _solution_raw_path: Array[Vector2i] = []
var _solution_edge_actions: Array[StringName] = []

@onready var _rs: RunGameState = get_node("/root/RunState") as RunGameState

# ── UI nodes (set in _build_ui) ───────────────────────────────────────────────
var _canvas: _GridCanvas = null
var _result_lbl: Label    = null
var _status_lbl: Label    = null
var _hj_check: CheckBox   = null
var _hp_check: CheckBox   = null
var _hj_spin: SpinBox     = null
var _hp_spin: SpinBox     = null
var _save_name_edit: LineEdit = null
var _load_list: ItemList  = null


# ────────────────────────────────────────────────────────────────────────────
func _ready() -> void:
	_init_flat_grid()
	_build_ui()

	# Auto-load last PCG or custom level if available.
	if not _rs.last_level_data.is_empty():
		_load_from_data(_rs.last_level_data)
		_status_text = "Loaded last played level. Paint to edit."
	else:
		_status_text = "New blank level. Start painting!"

	_refresh_status()
	_refresh_saved_puzzle_list()
	_canvas.queue_redraw()


# ── Grid canvas (inner class) ─────────────────────────────────────────────────
class _GridCanvas extends Control:
	var ed: Control  # reference to parent editor

	func _draw() -> void:
		ed._draw_grid(self)

	func _gui_input(event: InputEvent) -> void:
		ed._on_canvas_input(event)


# ── Grid initialisation ───────────────────────────────────────────────────────
func _init_flat_grid() -> void:
	_grid = []
	for r in ROWS:
		var row: Array = []
		for _c in COLS:
			row.append(r >= _LG.GROUND_ROW)
		_grid.append(row)


func _load_from_data(data: Dictionary) -> void:
	_solution_raw_path.clear()
	_solution_edge_actions.clear()
	var raw_grid = data.get("grid", [])
	if raw_grid.size() == ROWS:
		_grid = []
		for r in ROWS:
			var src = raw_grid[r]
			var row: Array = []
			for c in COLS:
				row.append(bool(src[c]) if c < src.size() else false)
			_grid.append(row)
	else:
		_init_flat_grid()

	var spawn_v: Vector2 = data.get("spawn", Vector2.ZERO)
	var flag_v:  Vector2 = data.get("flag",  Vector2.ZERO)
	_spawn = Vector2i(
		int(spawn_v.x / TILE_PX),
		int(spawn_v.y / TILE_PX))
	_flag = Vector2i(
		int(flag_v.x  / TILE_PX),
		int(flag_v.y  / TILE_PX))

	# Clamp to valid positions.
	_spawn = _spawn.clamp(Vector2i(0, 0), Vector2i(COLS - 1, ROWS - 1))
	_flag  = _flag.clamp( Vector2i(0, 0), Vector2i(COLS - 1, ROWS - 1))

	var mc: Dictionary = data.get("min_charges", {})
	_hj_charges = int(mc.get(&"high_jump",        _hj_charges))
	_hp_charges = int(mc.get(&"horizontal_pass",   _hp_charges))

	_sync_ui_to_state()


# ── UI construction ───────────────────────────────────────────────────────────
func _build_ui() -> void:
	anchor_right  = 1.0
	anchor_bottom = 1.0
	grow_horizontal = Control.GROW_DIRECTION_BOTH
	grow_vertical   = Control.GROW_DIRECTION_BOTH

	# Dark background.
	var bg := ColorRect.new()
	bg.color = Color(0.07, 0.09, 0.13)
	bg.anchor_right  = 1.0
	bg.anchor_bottom = 1.0
	bg.grow_horizontal = Control.GROW_DIRECTION_BOTH
	bg.grow_vertical   = Control.GROW_DIRECTION_BOTH
	add_child(bg)

	# Root split: canvas on left, side panel on right.
	var hbox := HBoxContainer.new()
	hbox.anchor_right  = 1.0
	hbox.anchor_bottom = 1.0
	hbox.grow_horizontal = Control.GROW_DIRECTION_BOTH
	hbox.grow_vertical   = Control.GROW_DIRECTION_BOTH
	add_child(hbox)

	# ── Canvas ───────────────────────────────────────────────────────────
	_canvas = _GridCanvas.new()
	_canvas.ed = self
	_canvas.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_canvas.size_flags_vertical   = Control.SIZE_EXPAND_FILL
	_canvas.focus_mode = Control.FOCUS_CLICK
	_canvas.mouse_filter = Control.MOUSE_FILTER_STOP
	hbox.add_child(_canvas)

	# ── Side panel ────────────────────────────────────────────────────────
	var panel_bg := StyleBoxFlat.new()
	panel_bg.bg_color = Color(0.10, 0.12, 0.16)
	panel_bg.border_color = Color(0.22, 0.26, 0.34)
	panel_bg.border_width_left = 2

	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(256, 0)
	panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	panel.add_theme_stylebox_override("panel", panel_bg)
	hbox.add_child(panel)

	var vbox_margin := MarginContainer.new()
	vbox_margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox_margin.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox_margin.add_theme_constant_override("margin_left",   10)
	vbox_margin.add_theme_constant_override("margin_right",  10)
	vbox_margin.add_theme_constant_override("margin_top",    10)
	vbox_margin.add_theme_constant_override("margin_bottom", 10)
	panel.add_child(vbox_margin)

	var vbox := VBoxContainer.new()
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_theme_constant_override("separation", 6)
	vbox_margin.add_child(vbox)

	# ── TOOLS ────────────────────────────────────────────────────────────
	vbox.add_child(_section_label("TOOLS"))
	var tool_grid := GridContainer.new()
	tool_grid.columns = 2
	tool_grid.add_theme_constant_override("h_separation", 6)
	tool_grid.add_theme_constant_override("v_separation", 6)
	vbox.add_child(tool_grid)

	_make_tool_btn(tool_grid, &"tile",  "Solid Tile",  Color(0.55, 0.33, 0.18))
	_make_tool_btn(tool_grid, &"erase", "Erase",       Color(0.25, 0.28, 0.38))
	_make_tool_btn(tool_grid, &"spawn", "Spawn",       Color(0.15, 0.65, 0.25))
	_make_tool_btn(tool_grid, &"flag",  "Flag",        Color(0.75, 0.18, 0.15))
	vbox.add_child(_separator())

	# ── ABILITIES ─────────────────────────────────────────────────────────
	vbox.add_child(_section_label("ABILITIES"))

	var hj_row := HBoxContainer.new()
	hj_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_hj_check = CheckBox.new()
	_hj_check.text = "Double Jump"
	_hj_check.button_pressed = _has_hj
	_hj_check.toggled.connect(func(v: bool) -> void: _has_hj = v)
	hj_row.add_child(_hj_check)
	var hj_spin_lbl := Label.new()
	hj_spin_lbl.text = "x"
	hj_row.add_child(hj_spin_lbl)
	_hj_spin = _make_spin(1, 5, _hj_charges, func(v: float) -> void: _hj_charges = int(v))
	hj_row.add_child(_hj_spin)
	vbox.add_child(hj_row)

	var hp_row := HBoxContainer.new()
	hp_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_hp_check = CheckBox.new()
	_hp_check.text = "Horiz Pass"
	_hp_check.button_pressed = _has_hp
	_hp_check.toggled.connect(func(v: bool) -> void: _has_hp = v)
	hp_row.add_child(_hp_check)
	var hp_spin_lbl := Label.new()
	hp_spin_lbl.text = "x"
	hp_row.add_child(hp_spin_lbl)
	_hp_spin = _make_spin(1, 5, _hp_charges, func(v: float) -> void: _hp_charges = int(v))
	hp_row.add_child(_hp_spin)
	vbox.add_child(hp_row)
	vbox.add_child(_separator())

	# ── SOLVE ─────────────────────────────────────────────────────────────
	vbox.add_child(_section_label("SOLVER (experimental)"))
	var solve_btn := _action_btn("Analyze / Solve", Color(0.18, 0.26, 0.44))
	solve_btn.pressed.connect(_on_solve_pressed)
	vbox.add_child(solve_btn)

	_result_lbl = Label.new()
	_result_lbl.text = "-"
	_result_lbl.add_theme_font_size_override("font_size", 13)
	_result_lbl.add_theme_color_override("font_color", Color(0.72, 0.80, 0.92))
	_result_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_result_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_child(_result_lbl)
	vbox.add_child(_separator())

	# ── FILE ──────────────────────────────────────────────────────────────
	vbox.add_child(_section_label("FILE"))

	var id_lbl := Label.new()
	id_lbl.text = "Puzzle ID (save / copy JSON)"
	id_lbl.add_theme_font_size_override("font_size", 12)
	id_lbl.add_theme_color_override("font_color", Color(0.62, 0.68, 0.78))
	id_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	id_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_child(id_lbl)

	_save_name_edit = LineEdit.new()
	_save_name_edit.placeholder_text = "e.g. my_maze_01"
	_save_name_edit.custom_minimum_size = Vector2(0, 30)
	_save_name_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_save_name_edit.clear_button_enabled = true
	vbox.add_child(_save_name_edit)

	var save_btn := _action_btn("Save JSON (local only)", Color(0.25, 0.20, 0.38))
	save_btn.pressed.connect(_on_save_pressed)
	vbox.add_child(save_btn)

	var copy_json_btn := _action_btn(
		"Copy JSON to clipboard (share / send in)", Color(0.22, 0.28, 0.38))
	copy_json_btn.pressed.connect(_on_copy_level_json_to_clipboard)
	vbox.add_child(copy_json_btn)

	var list_lbl := Label.new()
	list_lbl.text = "Saved puzzles - select an ID, then Load:"
	list_lbl.add_theme_font_size_override("font_size", 12)
	list_lbl.add_theme_color_override("font_color", Color(0.62, 0.68, 0.78))
	list_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	list_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_child(list_lbl)

	_load_list = ItemList.new()
	_load_list.custom_minimum_size = Vector2(0, 64)
	_load_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_load_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_load_list.select_mode = ItemList.SELECT_SINGLE
	_load_list.allow_reselect = true
	_load_list.item_activated.connect(_on_load_list_activated)
	vbox.add_child(_load_list)

	var load_btn := _action_btn("Load selected JSON", Color(0.22, 0.22, 0.28))
	load_btn.pressed.connect(_on_load_file_pressed)
	vbox.add_child(load_btn)

	var load_pcg_btn := _action_btn("Reload Last PCG Level", Color(0.18, 0.30, 0.22))
	load_pcg_btn.pressed.connect(_on_load_pcg_pressed)
	vbox.add_child(load_pcg_btn)

	var new_btn := _action_btn("New Blank Level", Color(0.18, 0.22, 0.30))
	new_btn.pressed.connect(_on_new_pressed)
	vbox.add_child(new_btn)
	vbox.add_child(_separator())

	# ── PLAY ──────────────────────────────────────────────────────────────
	var play_btn := _action_btn("Play This Level", Color(0.15, 0.38, 0.18))
	play_btn.pressed.connect(_on_play_pressed)
	vbox.add_child(play_btn)
	vbox.add_child(_separator())

	# ── BACK ──────────────────────────────────────────────────────────────
	var back_btn := _action_btn("Back to Menu", Color(0.18, 0.10, 0.10))
	back_btn.pressed.connect(_on_back_pressed)
	vbox.add_child(back_btn)

	# ── Status bar ────────────────────────────────────────────────────────
	_status_lbl = Label.new()
	_status_lbl.add_theme_font_size_override("font_size", 12)
	_status_lbl.add_theme_color_override("font_color", Color(0.55, 0.65, 0.75))
	_status_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_child(_status_lbl)


# ── Drawing ───────────────────────────────────────────────────────────────────
func _draw_grid(canvas: Control) -> void:
	var cw: float = canvas.size.x
	var ch: float = canvas.size.y
	if cw <= 0.0 or ch <= 0.0:
		return

	var bands: int = ROWS + 1
	var ts: float = minf(cw / float(COLS), ch / float(bands))
	var ox: float = (cw - ts * float(COLS)) * 0.5
	var oy_top: float = (ch - ts * float(bands)) * 0.5
	var oy_grid: float = oy_top + ts

	_TilePlatformDraw.draw_terrain_strip(
		canvas, Rect2(ox, oy_top, ts * float(COLS), ts), _TilePlatformDraw.STYLE_CEILING)

	for r in ROWS:
		for c in COLS:
			var rx: float = ox + c * ts
			var ry: float = oy_grid + r * ts
			var rect := Rect2(rx, ry, ts, ts)
			canvas.draw_rect(rect, COL_SOLID if _grid[r][c] else COL_AIR)
			canvas.draw_rect(rect, COL_GRID, false, 0.5)

	_draw_solution_path_overlay(canvas, ox, oy_grid, ts)

	# Spawn marker.
	var spr := Rect2(ox + _spawn.x * ts, oy_grid + _spawn.y * ts, ts, ts)
	canvas.draw_rect(spr, COL_SPAWN)
	canvas.draw_string(ThemeDB.fallback_font, spr.position + Vector2(ts * 0.12, ts * 0.82),
		"S", HORIZONTAL_ALIGNMENT_LEFT, -1, int(ts * 0.72), Color.WHITE)

	# Flag marker.
	var fr := Rect2(ox + _flag.x * ts, oy_grid + _flag.y * ts, ts, ts)
	canvas.draw_rect(fr, COL_FLAG)
	canvas.draw_string(ThemeDB.fallback_font, fr.position + Vector2(ts * 0.12, ts * 0.82),
		"F", HORIZONTAL_ALIGNMENT_LEFT, -1, int(ts * 0.72), Color.WHITE)

	# Hover highlight.
	if _hover.x >= 0 and _hover.y >= 0:
		canvas.draw_rect(Rect2(ox + _hover.x * ts, oy_grid + _hover.y * ts, ts, ts),
			COL_HOVER)


func _cell_center_canvas(ox: float, oy: float, ts: float, cell: Vector2i) -> Vector2:
	return Vector2(ox + (float(cell.x) + 0.5) * ts, oy + (float(cell.y) + 0.5) * ts)


## Intermediate grid cells for one solver edge (falls step down, walks step sideways, jumps use a simple arc).
func _edge_waypoints_rough(a: Vector2i, b: Vector2i) -> Array[Vector2i]:
	var dx: int = b.x - a.x
	var dy: int = b.y - a.y
	if dx == 0 and dy == 0:
		return [b]
	if absi(dx) + absi(dy) == 1:
		return [b]
	if dx == 0 and dy > 0:
		var fall: Array[Vector2i] = []
		for y in range(a.y + 1, b.y + 1):
			fall.append(Vector2i(a.x, y))
		return fall
	if dy == 0 and dx != 0:
		var walk: Array[Vector2i] = []
		var step: int = 1 if dx > 0 else -1
		var x: int = a.x + step
		while true:
			walk.append(Vector2i(x, a.y))
			if x == b.x:
				break
			x += step
		return walk
	return _jump_arc_sample_rough(a, b)


func _jump_arc_sample_rough(a: Vector2i, b: Vector2i) -> Array[Vector2i]:
	var adx: int = absi(b.x - a.x)
	var ady: int = absi(b.y - a.y)
	var span: int = maxi(adx, ady)
	var n: int = clampi(maxi(span + 2, 6), 6, 24)
	var arc_h: float = maxf(
		0.85,
		minf(0.45 * float(ady) + 0.22 * float(adx), float(_LG.HIGH_JUMP_UP + 2)))
	var out: Array[Vector2i] = []
	for k in range(1, n):
		var t: float = float(k) / float(n)
		var fx: float = lerpf(float(a.x), float(b.x), t)
		var fy0: float = lerpf(float(a.y), float(b.y), t)
		var bump: float = 4.0 * t * (1.0 - t) * arc_h
		var fy: float = fy0 - bump
		var c := Vector2i(
			clampi(int(round(fx)), 0, COLS - 1),
			clampi(int(round(fy)), 0, ROWS - 1))
		if out.is_empty() or out[out.size() - 1] != c:
			out.append(c)
	if out.is_empty() or out[out.size() - 1] != b:
		out.append(b)
	return out


func _trajectory_polyline_canvas(ox: float, oy: float, ts: float) -> PackedVector2Array:
	var raw: Array[Vector2i] = _solution_raw_path
	if raw.is_empty():
		return PackedVector2Array()
	var pts := PackedVector2Array()
	var last_p: Vector2 = _cell_center_canvas(ox, oy, ts, raw[0])
	pts.append(last_p)
	for i in range(raw.size() - 1):
		for c: Vector2i in _edge_waypoints_rough(raw[i], raw[i + 1]):
			var p: Vector2 = _cell_center_canvas(ox, oy, ts, c)
			if p.distance_squared_to(last_p) > 0.25:
				pts.append(p)
				last_p = p
	var tail_from: Vector2i = raw[raw.size() - 1]
	if tail_from != _flag:
		var fc: Vector2 = _cell_center_canvas(ox, oy, ts, _flag)
		for c: Vector2i in _edge_waypoints_rough(tail_from, _flag):
			var p2: Vector2 = _cell_center_canvas(ox, oy, ts, c)
			if p2.distance_squared_to(last_p) > 0.25:
				pts.append(p2)
				last_p = p2
		if fc.distance_squared_to(last_p) > 0.25:
			pts.append(fc)
	return pts


func _edge_action_color(id: StringName) -> Color:
	match id:
		&"horizontal_pass":
			return COL_EDGE_HP
		&"high_jump":
			return COL_EDGE_DJ
		&"jump":
			return COL_EDGE_JUMP
		_:
			return Color(0.65, 0.68, 0.78, 0.9)


func _action_marker_label(id: StringName) -> String:
	match id:
		&"horizontal_pass":
			return "HP"
		&"high_jump":
			return "DJ"
		&"jump":
			return "J"
		&"fall":
			return ""
		&"walk":
			return ""
		_:
			return ""


func _draw_solution_path_overlay(canvas: Control, ox: float, oy: float, ts: float) -> void:
	if _solution_raw_path.size() < 2:
		return
	var lw: float = maxf(2.0, ts * 0.085)
	var poly: PackedVector2Array = _trajectory_polyline_canvas(ox, oy, ts)
	if poly.size() >= 2:
		canvas.draw_polyline(poly, COL_PATH, lw, true)

	var raw: Array[Vector2i] = _solution_raw_path
	var fs: int = clampi(int(ts * 0.26), 8, 14)
	var n_mark: int = mini(_solution_edge_actions.size(), raw.size() - 1)
	for i in range(n_mark):
		var id: StringName = _solution_edge_actions[i]
		var mtxt: String = _action_marker_label(id)
		if mtxt.is_empty():
			continue
		var at: Vector2i = raw[i + 1]
		var pc: Vector2 = _cell_center_canvas(ox, oy, ts, at)
		var pr: float = maxf(ts * 0.22, 5.0)
		var bg := _edge_action_color(id)
		bg.a = 0.92
		canvas.draw_circle(pc, pr, bg)
		canvas.draw_arc(pc, pr, 0.0, TAU, 28, Color(0.05, 0.05, 0.08, 0.65), 1.5)
		canvas.draw_string(
			ThemeDB.fallback_font, pc + Vector2(-fs * 0.34, fs * 0.28), mtxt,
			HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(0.06, 0.05, 0.04, 0.95))


func _canvas_to_grid(canvas: Control, pos: Vector2) -> Vector2i:
	var cw := canvas.size.x
	var ch := canvas.size.y
	var bands := ROWS + 1
	var ts := minf(cw / float(COLS), ch / float(bands))
	var ox := (cw - ts * float(COLS)) * 0.5
	var oy_top := (ch - ts * float(bands)) * 0.5
	var oy_grid := oy_top + ts
	var c := int((pos.x - ox) / ts)
	var r := int((pos.y - oy_grid) / ts)
	return Vector2i(c, r)


func _in_grid(v: Vector2i) -> bool:
	return v.x >= 0 and v.x < COLS and v.y >= 0 and v.y < ROWS


# ── Canvas input ──────────────────────────────────────────────────────────────
func _on_canvas_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		var cell := _canvas_to_grid(_canvas, event.position)
		if _in_grid(cell):
			_hover = cell
		else:
			_hover = Vector2i(-1, -1)
		_canvas.queue_redraw()

		if _painting and _in_grid(cell):
			_apply_tool(cell)

	elif event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				_painting = true
				_paint_solid = (_tool == &"tile")
				var cell := _canvas_to_grid(_canvas, mb.position)
				if _in_grid(cell):
					_apply_tool(cell)
			else:
				_painting = false
		elif mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed:
			# Right-click always erases.
			var cell := _canvas_to_grid(_canvas, mb.position)
			if _in_grid(cell):
				_grid[cell.y][cell.x] = false
				_solution_raw_path.clear()
				_solution_edge_actions.clear()
				_canvas.queue_redraw()


func _apply_tool(cell: Vector2i) -> void:
	match _tool:
		&"tile":
			_grid[cell.y][cell.x] = true
		&"erase":
			_grid[cell.y][cell.x] = false
		&"spawn":
			_spawn = cell
		&"flag":
			_flag = cell
	_solution_raw_path.clear()
	_solution_edge_actions.clear()
	_canvas.queue_redraw()


# ── Solver ────────────────────────────────────────────────────────────────────
func _on_solve_pressed() -> void:
	var abilities: Array[StringName] = []
	if _has_hj:
		abilities.append(&"high_jump")
	if _has_hp:
		abilities.append(&"horizontal_pass")

	var overrides: Dictionary = {}
	if _has_hj:
		overrides[&"high_jump"] = _hj_charges
	if _has_hp:
		overrides[&"horizontal_pass"] = _hp_charges

	_result_lbl.text = "Solving..."
	_result_lbl.add_theme_color_override("font_color", Color(0.72, 0.80, 0.92))

	var result := _LG.analyze_level(
		_grid, _spawn.x, _spawn.y, _flag.x, _flag.y, abilities)

	if not result.get("solvable", false):
		_solution_raw_path.clear()
		_solution_edge_actions.clear()
		_result_lbl.text = "Unsolvable with current abilities."
		_result_lbl.add_theme_color_override("font_color", Color(0.90, 0.40, 0.35))
	else:
		var sol: Dictionary = _LG.solution_path_and_uses(
			_grid, _spawn.x, _spawn.y, _flag.x, _flag.y, abilities, overrides)
		var raw_path: Array[Vector2i] = sol["path"] as Array[Vector2i]
		var uses: Dictionary = sol["uses"] as Dictionary
		_solution_raw_path = raw_path.duplicate() as Array[Vector2i]
		_solution_edge_actions.clear()
		var ea: Variant = sol.get("edge_actions", [])
		if ea is Array:
			for x: Variant in ea as Array:
				_solution_edge_actions.append(x as StringName)
		var bfs: int = result.get("bfs_score", 0)
		var lines: PackedStringArray = ["Solvable!", "BFS score: %d" % bfs]
		if not _solution_raw_path.is_empty():
			lines.append(
				"Preview: rough route (walk/fall/jump) + J / HP / DJ on special landings. %d cells, %d steps." % [
					_solution_raw_path.size(), _solution_edge_actions.size()])
		if not uses.is_empty():
			lines.append("This path uses:")
			for id: StringName in [&"high_jump", &"horizontal_pass"]:
				if uses.has(id):
					lines.append("  %s x %d" % [CardCatalog.title(id), int(uses[id])])
		_result_lbl.text = "\n".join(lines)
		_result_lbl.add_theme_color_override("font_color", Color(0.45, 0.90, 0.55))

	_canvas.queue_redraw()


# ── File operations ───────────────────────────────────────────────────────────
func _sanitize_puzzle_id(raw: String) -> String:
	var t: String = raw.strip_edges()
	if t.is_empty():
		return ""
	var re := RegEx.new()
	re.compile("[^a-zA-Z0-9_\\-]+")
	var cleaned: String = re.sub(t, "_", true)
	while cleaned.contains("__"):
		cleaned = cleaned.replace("__", "_")
	cleaned = cleaned.strip_edges()
	while cleaned.begins_with("_") or cleaned.begins_with("-"):
		cleaned = cleaned.substr(1)
	while cleaned.ends_with("_") or cleaned.ends_with("-"):
		cleaned = cleaned.substr(0, cleaned.length() - 1)
	return cleaned


func _refresh_saved_puzzle_list() -> void:
	if _load_list == null:
		return
	_load_list.clear()
	var dir := DirAccess.open(_LG.PUZZLES_USER_DIR)
	if dir == null:
		return
	var stems: PackedStringArray = []
	dir.list_dir_begin()
	var fn := dir.get_next()
	while fn != "":
		if fn != "." and fn != ".." and fn.ends_with(".json"):
			stems.append(fn.get_basename())
		fn = dir.get_next()
	dir.list_dir_end()
	stems.sort()
	for stem: String in stems:
		var idx: int = _load_list.add_item(stem)
		_load_list.set_item_metadata(idx, stem + ".json")


func _on_load_list_activated(index: int) -> void:
	_load_list.select(index)
	_on_load_file_pressed()


# ── File operations ───────────────────────────────────────────────────────────
func _on_load_pcg_pressed() -> void:
	if _rs.last_level_data.is_empty():
		_set_status("No PCG level recorded yet. Play a level first.")
		return
	_load_from_data(_rs.last_level_data)
	_result_lbl.text = "-"
	_set_status("PCG level loaded. Paint to edit.")
	_canvas.queue_redraw()


func _on_new_pressed() -> void:
	_init_flat_grid()
	_spawn = Vector2i(_LG.SPAWN_COL, _LG.GROUND_ROW - 1)
	_flag  = Vector2i(_LG.FLAG_COL,  _LG.GROUND_ROW - 1)
	_result_lbl.text = "-"
	_solution_raw_path.clear()
	_solution_edge_actions.clear()
	_set_status("New blank level.")
	_canvas.queue_redraw()


func _on_save_pressed() -> void:
	var stem := _sanitize_puzzle_id(_save_name_edit.text)
	if stem.is_empty():
		_set_status("Enter a puzzle file ID (name) above before saving.")
		return
	var path := _save_to_json(stem)
	if path.is_empty():
		_set_status("Save failed - could not write file.")
	else:
		_refresh_saved_puzzle_list()
		if OS.has_feature("web"):
			_set_status(
				"JSON saved in this browser only (not a shareable file). "
				+ "Use Copy JSON to clipboard to share via chat or email.")
		else:
			_set_status("JSON saved (local): " + ProjectSettings.globalize_path(path))


func _level_json_dict(stem: String) -> Dictionary:
	var mc_str: Dictionary = {}
	if _has_hj:
		mc_str["high_jump"] = _hj_charges
	if _has_hp:
		mc_str["horizontal_pass"] = _hp_charges
	return {
		"version": 1,
		"puzzle_id": stem,
		"spawn_col": _spawn.x, "spawn_row": _spawn.y,
		"flag_col":  _flag.x,  "flag_row":  _flag.y,
		"abilities": _ability_list_str(),
		"min_charges": mc_str,
		"grid": _grid,
	}


func _save_to_json(stem: String) -> String:
	var dir := DirAccess.open("user://")
	if dir and not dir.dir_exists("levels"):
		dir.make_dir("levels")

	var path: String = _LG.PUZZLES_USER_DIR + "%s.json" % stem
	var json_text: String = JSON.stringify(_level_json_dict(stem), "\t")

	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return ""
	f.store_string(json_text)
	f.close()
	return path


func _on_copy_level_json_to_clipboard() -> void:
	var stem := _sanitize_puzzle_id(_save_name_edit.text)
	if stem.is_empty():
		_set_status("Enter a puzzle ID above before copying.")
		return
	var json_text: String = JSON.stringify(_level_json_dict(stem), "\t")
	DisplayServer.clipboard_set(json_text)
	_set_status(
		"Copied JSON to clipboard. Paste into a .json file or message - same format the game loads.")


func _on_load_file_pressed() -> void:
	var sel: PackedInt32Array = _load_list.get_selected_items()
	if sel.is_empty():
		_set_status("Select a puzzle ID in the list, then press Load (or double-click a row).")
		return

	var fn: String = str(_load_list.get_item_metadata(sel[0]))
	var full_path: String = _LG.PUZZLES_USER_DIR + fn

	var f := FileAccess.open(full_path, FileAccess.READ)
	if f == null:
		_set_status("Could not open: " + fn)
		return
	var raw := f.get_as_text()
	f.close()

	var json := JSON.new()
	var err := json.parse(raw)
	if err != OK:
		_set_status("JSON parse error in: " + fn)
		return

	var d: Dictionary = json.get_data() as Dictionary
	_import_from_json_dict(d, fn.get_basename())
	_set_status("Loaded: " + fn)
	_canvas.queue_redraw()


func _import_from_json_dict(d: Dictionary, stem_fallback: String = "") -> void:
	_solution_raw_path.clear()
	_solution_edge_actions.clear()
	var raw_grid = d.get("grid", [])
	if raw_grid.size() == ROWS:
		_grid = []
		for r in ROWS:
			var src = raw_grid[r]
			var row: Array = []
			for c in COLS:
				row.append(bool(src[c]) if c < src.size() else false)
			_grid.append(row)
	else:
		_init_flat_grid()

	_spawn = Vector2i(
		int(d.get("spawn_col", _LG.SPAWN_COL)),
		int(d.get("spawn_row", _LG.GROUND_ROW - 1)))
	_flag = Vector2i(
		int(d.get("flag_col",  _LG.FLAG_COL)),
		int(d.get("flag_row",  _LG.GROUND_ROW - 1)))

	var mc = d.get("min_charges", {})
	if mc.has("high_jump"):
		_hj_charges = int(mc["high_jump"])
	if mc.has("horizontal_pass"):
		_hp_charges = int(mc["horizontal_pass"])

	_sync_ui_to_state()
	if _save_name_edit:
		var pid: String = str(d.get("puzzle_id", ""))
		if pid.is_empty():
			pid = stem_fallback
		_save_name_edit.text = pid


# ── Play ───────────────────────────────────────────────────────────────────────
func _on_play_pressed() -> void:
	var abilities: Array[StringName] = []
	if _has_hj:
		abilities.append(&"high_jump")
	if _has_hp:
		abilities.append(&"horizontal_pass")

	if abilities.is_empty():
		_set_status("Enable at least one ability to play.")
		return

	var platforms := _LG._grid_to_platforms(_grid)
	var mc: Dictionary = {}
	if _has_hj:
		mc[&"high_jump"] = _hj_charges
	if _has_hp:
		mc[&"horizontal_pass"] = _hp_charges

	var level_data: Dictionary = {
		"platforms":   platforms,
		"spawn":       Vector2((_spawn.x + 0.5) * TILE_PX, _spawn.y * TILE_PX),
		"flag":        Vector2((_flag.x  + 0.5) * TILE_PX, _flag.y  * TILE_PX),
		"grid":        _grid,
		"min_charges": mc,
		"bfs_score":   0,
		"solvable":    true,
	}

	_rs.start_new_run(abilities)
	_rs.archive = [level_data]
	_rs.custom_level_data = level_data
	get_tree().change_scene_to_file("res://scenes/ui/ability_intro.tscn")


# ── Back ───────────────────────────────────────────────────────────────────────
func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_ESCAPE:
		if is_inside_tree():
			var vp := get_viewport()
			if vp:
				vp.set_input_as_handled()
		_on_back_pressed()


func _on_back_pressed() -> void:
	get_tree().change_scene_to_file("res://scenes/ui/main_menu.tscn")


# ── Helper builders ───────────────────────────────────────────────────────────
var _tool_btns: Dictionary = {}

func _make_tool_btn(parent: Control, id: StringName, label: String, col: Color) -> void:
	var sb_off := StyleBoxFlat.new()
	sb_off.bg_color = col.darkened(0.55)
	sb_off.border_color = col.darkened(0.2)
	sb_off.set_border_width_all(2)
	sb_off.set_corner_radius_all(6)
	sb_off.content_margin_left = 8; sb_off.content_margin_right = 8
	sb_off.content_margin_top = 6;  sb_off.content_margin_bottom = 6

	var sb_on := StyleBoxFlat.new()
	sb_on.bg_color = col.darkened(0.2)
	sb_on.border_color = col.lightened(0.3)
	sb_on.set_border_width_all(2)
	sb_on.set_corner_radius_all(6)
	sb_on.content_margin_left = 8; sb_on.content_margin_right = 8
	sb_on.content_margin_top = 6;  sb_on.content_margin_bottom = 6

	var btn := Button.new()
	btn.text = label
	btn.toggle_mode = false
	btn.focus_mode = Control.FOCUS_NONE
	btn.add_theme_font_size_override("font_size", 14)
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_update_tool_btn_style(btn, id == _tool, sb_off, sb_on)
	btn.pressed.connect(func() -> void:
		_tool = id
		for tid: StringName in _tool_btns:
			_update_tool_btn_style(
				_tool_btns[tid]["btn"],
				tid == id,
				_tool_btns[tid]["off"],
				_tool_btns[tid]["on"])
	)
	_tool_btns[id] = {"btn": btn, "off": sb_off, "on": sb_on}
	parent.add_child(btn)


static func _update_tool_btn_style(btn: Button, active: bool,
		sb_off: StyleBoxFlat, sb_on: StyleBoxFlat) -> void:
	btn.add_theme_stylebox_override("normal",  sb_on  if active else sb_off)
	btn.add_theme_stylebox_override("hover",   sb_on)
	btn.add_theme_stylebox_override("pressed", sb_on)


func _action_btn(label: String, col: Color) -> Button:
	var sb := StyleBoxFlat.new()
	sb.bg_color = col
	sb.border_color = col.lightened(0.25)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(6)
	sb.content_margin_left = 10; sb.content_margin_right = 10
	sb.content_margin_top  = 7;  sb.content_margin_bottom = 7

	var btn := Button.new()
	btn.text = label
	btn.focus_mode = Control.FOCUS_NONE
	btn.add_theme_font_size_override("font_size", 14)
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	btn.add_theme_stylebox_override("normal", sb)
	btn.add_theme_stylebox_override("hover",  sb)
	btn.add_theme_stylebox_override("pressed", sb)
	return btn


func _section_label(txt: String) -> Label:
	var lbl := Label.new()
	lbl.text = txt
	lbl.add_theme_font_size_override("font_size", 12)
	lbl.add_theme_color_override("font_color", Color(0.50, 0.55, 0.65))
	return lbl


func _separator() -> HSeparator:
	var sep := HSeparator.new()
	sep.add_theme_color_override("color", Color(0.22, 0.26, 0.34))
	return sep


func _make_spin(min_v: float, max_v: float, val: float, cb: Callable) -> SpinBox:
	var sp := SpinBox.new()
	sp.min_value = min_v
	sp.max_value = max_v
	sp.value = val
	sp.step = 1
	sp.custom_minimum_size = Vector2(56, 0)
	sp.value_changed.connect(cb)
	return sp


func _ability_list_str() -> Array:
	var out: Array = []
	if _has_hj:
		out.append("high_jump")
	if _has_hp:
		out.append("horizontal_pass")
	return out


func _sync_ui_to_state() -> void:
	if _hj_check:
		_hj_check.button_pressed = _has_hj
	if _hp_check:
		_hp_check.button_pressed = _has_hp
	if _hj_spin:
		_hj_spin.value = _hj_charges
	if _hp_spin:
		_hp_spin.value = _hp_charges


func _set_status(msg: String) -> void:
	_status_text = msg
	_refresh_status()


func _refresh_status() -> void:
	if _status_lbl:
		_status_lbl.text = _status_text
