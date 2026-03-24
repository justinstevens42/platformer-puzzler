extends Node2D

const _TilePlatformDraw := preload("res://scripts/tile_platform_draw.gd")

@onready var _rs: RunGameState = get_node("/root/RunState") as RunGameState

@onready var _level_root: Node2D = $LevelContainer
@onready var _player: CharacterBody2D = $Player
@onready var _cam: Camera2D = $Camera2D
@onready var _overlay: ColorRect = $CanvasLayer/Overlay
@onready var _overlay_label: Label = $CanvasLayer/Overlay/Margin/VBox/Message
@onready var _menu_button: Button = $CanvasLayer/Overlay/Margin/VBox/ToMenu

var _respawn_position: Vector2 = Vector2(64, 300)
var _current_level_data: Dictionary = {}
var _level_archive: Array = []
var _goal_reached: bool = false
var _edit_btn: Button = null
var _save_layer: CanvasLayer = null
var _save_dialog: AcceptDialog = null
var _save_line: LineEdit = null
## True while the "Justin Levels complete" summary overlay is up.
var _justin_pack_complete: bool = false
## True while the main-menu PCG run (15 sequential levels) complete summary is up.
var _pcg_run_complete: bool = false
## End-of-run stats overlays: only arrow keys dismiss.
var _arrow_continue_only: bool = false


func _ready() -> void:
	add_to_group("game_session")
	_overlay.visible = false
	_rs.level_advanced.connect(_on_level_advanced)
	_rs.level_skipped.connect(_on_level_skipped)
	_rs.run_over.connect(_on_run_over)
	_menu_button.pressed.connect(_on_to_menu_pressed)
	_cam.enabled = true
	_cam.make_current()
	get_window().size_changed.connect(_refit_camera_deferred)

	# Inject "Edit This Level" button into the overlay VBox.
	var overlay_vbox: VBoxContainer = $CanvasLayer/Overlay/Margin/VBox as VBoxContainer
	_edit_btn = Button.new()
	_edit_btn.text = "Edit This Level [E]"
	_edit_btn.focus_mode = Control.FOCUS_NONE
	_edit_btn.add_theme_font_size_override("font_size", 18)
	var esb := StyleBoxFlat.new()
	esb.bg_color = Color(0.10, 0.14, 0.22, 0.92)
	esb.border_color = Color(0.38, 0.52, 0.78, 1.0)
	esb.set_border_width_all(2)
	esb.set_corner_radius_all(8)
	esb.content_margin_left = 20; esb.content_margin_right = 20
	esb.content_margin_top = 8;   esb.content_margin_bottom = 8
	_edit_btn.add_theme_stylebox_override("normal", esb)
	_edit_btn.add_theme_stylebox_override("hover", esb)
	_edit_btn.add_theme_stylebox_override("pressed", esb)
	_edit_btn.pressed.connect(_open_level_editor)
	overlay_vbox.add_child(_edit_btn)
	_edit_btn.visible = false
	if _rs.justin_campaign:
		_edit_btn.visible = false

	_save_layer = CanvasLayer.new()
	_save_layer.layer = 80
	add_child(_save_layer)
	_save_dialog = AcceptDialog.new()
	_save_dialog.title = "Save puzzle"
	_save_dialog.ok_button_text = "Save"
	_save_dialog.min_size = Vector2i(400, 160)
	var save_vb := VBoxContainer.new()
	save_vb.add_theme_constant_override("separation", 10)
	var save_hint := Label.new()
	save_hint.text = "Puzzle file ID (letters, numbers, _ and -):"
	save_vb.add_child(save_hint)
	_save_line = LineEdit.new()
	_save_line.placeholder_text = "e.g. my_favorite_level"
	_save_line.custom_minimum_size = Vector2(320, 0)
	save_vb.add_child(_save_line)
	_save_dialog.add_child(save_vb)
	_save_layer.add_child(_save_dialog)
	_save_dialog.confirmed.connect(_on_save_puzzle_dialog_confirmed)

	# Use the archive built by ability_intro; fall back to building it here.
	if not _rs.archive.is_empty():
		_level_archive = _rs.archive
	else:
		_level_archive = LevelGenerator.build_archive(_rs.run_seed, _rs.loadout)
		_rs.archive = _level_archive

	load_current_level()


func _refit_camera_deferred() -> void:
	call_deferred("_refit_camera")


func _refit_camera() -> void:
	if _level_root.get_child_count() > 0:
		_fit_camera_to_level_data(_current_level_data)


func _physics_process(_delta: float) -> void:
	const FEET_Y := 16.0
	if not _rs.is_run_active or _overlay.visible:
		return
	# Die when feet cross into the hazard strip (matches TilePlatformDraw death band).
	var floor_line: float = float(LevelGenerator.ROWS * LevelGenerator.TILE)
	if _player.global_position.y + FEET_Y > floor_line + 6.0:
		_rs.record_death()
		if not _rs.is_run_active:
			return
		_player.velocity = Vector2.ZERO
		_player.global_position = _respawn_position


func _mark_input_handled() -> void:
	if is_inside_tree():
		var vp := get_viewport()
		if vp:
			vp.set_input_as_handled()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_ESCAPE:
		_mark_input_handled()
		_go_to_main_menu()
		return

	# E key opens editor (not during Justin pack).
	# Mark handled *before* scene change — change_scene frees this node, so get_viewport() is null after.
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_E:
			if _rs.justin_campaign:
				return
			_mark_input_handled()
			_open_level_editor()
			return

	if _overlay.visible or not _rs.is_run_active:
		return

	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_R:
			reset_current_level()
			_mark_input_handled()
		elif event.keycode == KEY_S:
			skip_current_level()
			_mark_input_handled()
		elif event.keycode == KEY_B and not _rs.justin_campaign:
			save_current_level()
			_mark_input_handled()


func load_current_level() -> void:
	if _rs.justin_campaign and _rs.current_level_index >= _rs.JUSTIN_PACK_PATHS.size():
		return
	if _rs.pcg_sequential_run and _rs.current_level_index >= _level_archive.size():
		return
	_goal_reached = false
	_rs.stop_level_timer()
	_rs.apply_justin_loadout_for_current_level()

	for c in _level_root.get_children():
		c.queue_free()

	if _player.has_method("reset_ability_state"):
		_player.reset_ability_state()

	var data: Dictionary
	if not _rs.custom_level_data.is_empty():
		data = _rs.custom_level_data
		_rs.custom_level_data = {}
	else:
		data = LevelGenerator.pick_from_archive(
			_level_archive, _rs.current_level_index, _rs.loadout)

	_current_level_data = data
	_rs.last_level_data = data

	if data.has("min_charges"):
		_rs.set_charges_for_level(data["min_charges"])

	_build_level_nodes(data)
	_fit_camera_to_level_data(data)
	_rs.start_level_timer()


func reset_current_level() -> void:
	_rs.record_restart()
	if not _rs.is_run_active:
		return

	if _player.has_method("reset_ability_state"):
		_player.reset_ability_state()

	if _current_level_data.has("min_charges"):
		_rs.set_charges_for_level(_current_level_data["min_charges"])

	for c in _level_root.get_children():
		c.queue_free()

	_build_level_nodes(_current_level_data)
	_fit_camera_to_level_data(_current_level_data)
	_rs.start_level_timer()


func skip_current_level() -> void:
	_rs.skip_level()


func get_level_grid() -> Array:
	return _current_level_data.get("grid", []) as Array


func save_current_level() -> void:
	if _rs.justin_campaign:
		return
	if _current_level_data.is_empty():
		return
	if _save_line == null or _save_dialog == null:
		return
	_save_line.text = "level_%d" % (_rs.current_level_index + 1)
	_save_dialog.popup_centered()


func _on_save_puzzle_dialog_confirmed() -> void:
	var stem := _sanitize_puzzle_stem(_save_line.text)
	if stem.is_empty():
		_show_overlay(
			"Invalid puzzle name.\nUse letters, numbers, underscores, or hyphens.\n\nPress any key to continue.",
			false)
		return
	var path := _write_level_json(_current_level_data, stem)
	if path.is_empty():
		_show_overlay("Save failed - could not write file.\n\nPress any key to continue.", false)
	else:
		_show_overlay(
			"Level saved!\n\nFile: %s\n\nPress any key to continue." % path, false)


static func _sanitize_puzzle_stem(raw: String) -> String:
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


func _write_level_json(data: Dictionary, stem: String) -> String:
	if stem.is_empty():
		return ""
	var dir := DirAccess.open("user://")
	if dir and not dir.dir_exists("levels"):
		dir.make_dir("levels")

	var path: String = LevelGenerator.PUZZLES_USER_DIR + "%s.json" % stem

	var spawn_v: Vector2 = data.get("spawn", Vector2.ZERO) as Vector2
	var flag_v: Vector2 = data.get("flag", Vector2.ZERO) as Vector2
	var tf: float = float(LevelGenerator.TILE)
	var sc: int = clampi(int(floorf(spawn_v.x / tf)), 0, LevelGenerator.COLS - 1)
	var sr: int = clampi(int(floorf(spawn_v.y / tf)), 0, LevelGenerator.ROWS - 1)
	var fc: int = clampi(int(floorf(flag_v.x / tf)), 0, LevelGenerator.COLS - 1)
	var fr: int = clampi(int(floorf(flag_v.y / tf)), 0, LevelGenerator.ROWS - 1)

	var save_dict: Dictionary = {
		"version": 1,
		"puzzle_id": stem,
		"bfs_score": data.get("bfs_score", 0),
		"min_charges": _charges_to_string_keys(data.get("min_charges", {})),
		"spawn_col": sc,
		"spawn_row": sr,
		"flag_col": fc,
		"flag_row": fr,
		"spawn": {"x": spawn_v.x, "y": spawn_v.y},
		"flag":  {"x": flag_v.x, "y": flag_v.y},
		"grid": data.get("grid", []),
	}

	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return ""
	f.store_string(JSON.stringify(save_dict, "\t"))
	f.close()
	return path


static func _charges_to_string_keys(d: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	for k in d:
		out[str(k)] = d[k]
	return out


func _open_level_editor() -> void:
	_rs.stop_level_timer()
	get_tree().change_scene_to_file("res://scenes/ui/level_editor.tscn")


func _build_level_nodes(data: Dictionary) -> void:
	var root := Node2D.new()
	root.name = "LevelRoot"
	_level_root.add_child(root)

	var bg := _make_background()
	root.add_child(bg)

	for plat: Dictionary in data.get("platforms", []):
		var body := _make_platform(plat)
		root.add_child(body)

	_add_level_ceiling(root)

	var spawn: Vector2 = data.get("spawn", Vector2(64, 300))
	_respawn_position = spawn
	_player.global_position = spawn
	_player.velocity = Vector2.ZERO

	var flag_scene := load("res://scenes/entities/goal_flag.tscn") as PackedScene
	if flag_scene:
		var flag_inst := flag_scene.instantiate() as Node2D
		flag_inst.global_position = data.get("flag", Vector2(1200, 300))
		root.add_child(flag_inst)


func _make_background() -> Node2D:
	return LevelBackdrop.new()


func _add_level_ceiling(root: Node2D) -> void:
	var T := LevelGenerator.TILE
	var world_w: float = float(LevelGenerator.COLS * T)
	var slab_h: float = 28.0
	var ceiling := StaticBody2D.new()
	ceiling.name = "LevelCeiling"
	ceiling.collision_layer = 1
	ceiling.collision_mask = 0
	var shape := RectangleShape2D.new()
	shape.size = Vector2(world_w, slab_h)
	var cs := CollisionShape2D.new()
	cs.shape = shape
	cs.position = Vector2(world_w * 0.5, -slab_h * 0.5)
	ceiling.add_child(cs)
	var vis := _TilePlatformDraw.new()
	vis.rect = Rect2(0, -float(T), world_w, float(T))
	vis.visual_style = _TilePlatformDraw.STYLE_CEILING
	vis.z_index = -3
	ceiling.add_child(vis)
	root.add_child(ceiling)


func _make_platform(plat: Dictionary) -> StaticBody2D:
	var T := LevelGenerator.TILE
	var col: int = plat.get("col", 0)
	var row: int = plat.get("row", 0)
	var width: int = plat.get("width", 1)
	var height: int = plat.get("height", 1)

	var px := col * T
	var py := row * T
	var pw := width * T
	var ph := height * T

	var body := StaticBody2D.new()
	body.collision_layer = 1
	body.collision_mask = 0
	body.global_position = Vector2.ZERO

	var shape := RectangleShape2D.new()
	shape.size = Vector2(pw, ph)
	var cs := CollisionShape2D.new()
	cs.shape = shape
	cs.position = Vector2(px + pw * 0.5, py + ph * 0.5)
	body.add_child(cs)

	var vis := _TilePlatformDraw.new()
	vis.rect = Rect2(px, py, pw, ph)
	vis.is_ground = (row + height) >= LevelGenerator.ROWS
	body.add_child(vis)

	return body


func _fit_camera_to_level_data(_data: Dictionary) -> void:
	var T := LevelGenerator.TILE
	var world_w: float = LevelGenerator.COLS * T
	var world_h: float = LevelGenerator.ROWS * T
	var center := Vector2(world_w * 0.5, world_h * 0.5)
	var vp: Vector2 = get_viewport().get_visible_rect().size
	var z: float = minf(vp.x / world_w, vp.y / world_h) * 0.92
	if z <= 0.0:
		z = 1.0
	_cam.zoom = Vector2(z, z)
	_cam.global_position = center
	_cam.position_smoothing_enabled = false


func notify_goal_reached() -> void:
	if not _rs.is_run_active or _goal_reached:
		return
	_goal_reached = true
	_rs.advance_after_level_clear()


func _on_level_advanced(idx: int) -> void:
	if _rs.justin_campaign and idx >= _rs.JUSTIN_PACK_PATHS.size():
		_show_justin_pack_complete_overlay()
		return
	if _rs.justin_campaign:
		_advance_to_next_level_or_intro()
		return
	if _rs.pcg_sequential_run and idx >= _level_archive.size():
		_show_pcg_run_complete_overlay()
		return
	var msg := "Level complete!\n\nPress any key to continue."
	if not _rs.justin_campaign:
		msg += "\nPress E to edit this level."
	_show_overlay(msg, false)


func _on_level_skipped(idx: int) -> void:
	if _rs.justin_campaign and idx >= _rs.JUSTIN_PACK_PATHS.size():
		_show_justin_pack_complete_overlay()
		return
	if _rs.justin_campaign:
		_advance_to_next_level_or_intro()
		return
	if _rs.pcg_sequential_run and idx >= _level_archive.size():
		_show_pcg_run_complete_overlay()
		return
	var msg := "Level skipped.\n\nPress any key to continue."
	if not _rs.justin_campaign:
		msg += "\nPress E to edit this level."
	_show_overlay(msg, false)


func _on_run_over(levels_done: int, total_time: float) -> void:
	var total_s: int = int(total_time)
	@warning_ignore("integer_division")
	var m: int = total_s / 60
	var s: int = total_s % 60

	var lines: String = "Run Over!\n\nLevels cleared: %d\nTotal time: %02d:%02d\nDeaths: %d\nRestarts: %d\n" % [
		levels_done, m, s, _rs.death_count, _rs.restart_count]

	lines += "\nAbility usage:"
	for id: StringName in _rs.loadout:
		var uses: int = int(_rs.ability_uses.get(id, 0))
		lines += "\n  %s: %d %s" % [CardCatalog.title(id), uses, "use" if uses == 1 else "uses"]
	lines += "\n\nHit an arrow key to continue."

	_show_overlay(lines, true, true)


var _overlay_is_final := false


func _show_overlay(text: String, final: bool, arrow_continue_only: bool = false) -> void:
	_overlay_label.text = text
	_overlay_is_final = final
	_arrow_continue_only = arrow_continue_only
	_menu_button.visible = final
	if _edit_btn:
		_edit_btn.visible = not final and not _rs.justin_campaign
	_overlay.visible = true


func _show_pcg_run_complete_overlay() -> void:
	_pcg_run_complete = true
	_rs.stop_level_timer()
	var total_s: int = int(_rs.total_time_spent)
	@warning_ignore("integer_division")
	var m: int = total_s / 60
	var s: int = total_s % 60
	var lines: String = (
		"PCG run complete!\n\n"
		+ "Levels beaten: %d\n"
		+ "Levels skipped: %d\n"
		+ "Total time: %02d:%02d\n"
		+ "Deaths: %d\n"
		+ "Restarts: %d\n"
		+ "\n"
	) % [
		_rs.levels_cleared, _rs.pack_skips, m, s, _rs.death_count, _rs.restart_count]
	lines += "Ability usage:"
	for id: StringName in _rs.loadout:
		var uses: int = int(_rs.ability_uses.get(id, 0))
		lines += "\n  %s: %d %s" % [CardCatalog.title(id), uses, "use" if uses == 1 else "uses"]
	lines += "\n\nHit an arrow key to continue."
	_overlay_label.text = lines
	_overlay_is_final = false
	_arrow_continue_only = true
	_menu_button.visible = false
	if _edit_btn:
		_edit_btn.visible = false
	_overlay.visible = true


func _show_justin_pack_complete_overlay() -> void:
	_justin_pack_complete = true
	_rs.stop_level_timer()
	var total_s: int = int(_rs.total_time_spent)
	@warning_ignore("integer_division")
	var m: int = total_s / 60
	var s: int = total_s % 60
	var dj: int = int(_rs.ability_uses.get(&"high_jump", 0))
	var hp_u: int = int(_rs.ability_uses.get(&"horizontal_pass", 0))
	var txt: String = (
		"Justin Levels - complete!\n\n"
		+ "Levels beaten: %d\n"
		+ "Levels skipped: %d\n"
		+ "Time: %02d:%02d\n"
		+ "Deaths: %d\n"
		+ "Restarts: %d\n"
		+ "Horizontal passes used: %d\n"
		+ "Double jumps used: %d\n\n"
		+ "Hit an arrow key to continue."
	) % [
		_rs.levels_cleared, _rs.pack_skips, m, s,
		_rs.death_count, _rs.restart_count,
		hp_u, dj]
	_overlay_label.text = txt
	_overlay_is_final = false
	_arrow_continue_only = true
	_menu_button.visible = false
	if _edit_btn:
		_edit_btn.visible = false
	_overlay.visible = true


func _advance_to_next_level_or_intro() -> void:
	if _rs.apply_justin_mid_intro_if_entering_pack_level():
		call_deferred("_open_ability_intro_deferred")
	else:
		call_deferred("load_current_level")


func _open_ability_intro_deferred() -> void:
	get_tree().change_scene_to_file("res://scenes/ui/ability_intro.tscn")


func _input(event: InputEvent) -> void:
	if not _overlay.visible:
		return
	if _arrow_continue_only:
		if event is InputEventKey and (event as InputEventKey).pressed and not (event as InputEventKey).echo:
			var kk: Key = (event as InputEventKey).keycode
			if kk == KEY_LEFT or kk == KEY_RIGHT or kk == KEY_UP or kk == KEY_DOWN:
				_mark_input_handled()
				_go_to_main_menu()
			return
		if event is InputEventMouseButton and (event as InputEventMouseButton).pressed:
			_mark_input_handled()
			return
	if event is InputEventKey and (event as InputEventKey).pressed and not (event as InputEventKey).echo:
		if (event as InputEventKey).keycode == KEY_ESCAPE:
			_mark_input_handled()
			_go_to_main_menu()
			return
	if _overlay_is_final:
		return
	if event is InputEventKey and (event as InputEventKey).pressed and not (event as InputEventKey).echo:
		var k := (event as InputEventKey).keycode
		if k == KEY_B:
			save_current_level()
			_mark_input_handled()
			return
		if k == KEY_E:
			return
	var dismiss := false
	if event is InputEventKey and (event as InputEventKey).pressed and not (event as InputEventKey).echo:
		dismiss = true
	elif event is InputEventMouseButton and (event as InputEventMouseButton).pressed:
		dismiss = true
	if dismiss:
		_overlay.visible = false
		_advance_to_next_level_or_intro()
		_mark_input_handled()


func _go_to_main_menu() -> void:
	if _justin_pack_complete:
		_justin_pack_complete = false
		_rs.mark_run_finished_quiet()
	if _pcg_run_complete:
		_pcg_run_complete = false
		_rs.mark_run_finished_quiet()
	_rs.stop_level_timer()
	get_tree().change_scene_to_file("res://scenes/ui/main_menu.tscn")


func _on_to_menu_pressed() -> void:
	_go_to_main_menu()
