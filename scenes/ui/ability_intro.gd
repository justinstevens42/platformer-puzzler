extends Control

@onready var _rs: RunGameState = get_node("/root/RunState") as RunGameState

@onready var _heading: Label = $Center/VBox/Heading
@onready var _card_row: HBoxContainer = $Center/VBox/CardRow
@onready var _continue_btn: Button = $Center/VBox/ContinueBtn
@onready var _level_label: Label = $Center/VBox/LevelLabel

var _thread: Thread = null
## Instance of PcgCancel (see scripts/pcg_cancel.gd).
var _pcg_cancel = null
var _progress_bar: ProgressBar = null
var _gen_label: Label = null
var _pcg_start_ticks: int = 0
var _pcg_generating_web_sync: bool = false


func _ready() -> void:
	_rs.stop_level_timer()
	_continue_btn.pressed.connect(_on_continue_pressed)

	# Inject a generation status label + indeterminate bar into the VBox.
	_gen_label = Label.new()
	_gen_label.add_theme_font_size_override("font_size", 15)
	_gen_label.add_theme_color_override("font_color", Color(0.55, 0.65, 0.80))
	_gen_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	$Center/VBox.add_child(_gen_label)

	_progress_bar = ProgressBar.new()
	_progress_bar.custom_minimum_size = Vector2(360, 10)
	_progress_bar.show_percentage = false
	_progress_bar.min_value = 0.0
	_progress_bar.max_value = 1.0
	_progress_bar.value = 0.0
	$Center/VBox.add_child(_progress_bar)

	var mid_tip: bool = (
		not _rs.intro_heading_override.is_empty()
		or not _rs.pending_intro_abilities.is_empty())

	if not _rs.fixed_level_paths.is_empty():
		var paths: PackedStringArray = _rs.fixed_level_paths
		_rs.fixed_level_paths = PackedStringArray()
		var loaded: Array = []
		var failed_path: String = ""
		for p: String in paths:
			var ld: Dictionary = LevelGenerator.load_level_from_json_path(p)
			if ld.is_empty():
				failed_path = p
				break
			loaded.append(ld)
		if not failed_path.is_empty():
			# Justin pack: keep double-jump-only tip on level 1 even when JSON is missing.
			if not _rs.justin_campaign:
				_rs.intro_heading_override = ""
				_rs.pending_intro_abilities.clear()
			var tried: PackedStringArray = LevelGenerator.puzzle_json_lookup_candidates(failed_path)
			var line_parts: Array[String] = []
			for q: String in tried:
				line_parts.append("  * " + LevelGenerator.format_puzzle_path_for_user(q))
			_gen_label.text = (
				"Missing or invalid level JSON (wrong path, missing file, or bad grid size).\nTried:\n%s\n\n"
				+ "Open Level Editor - under FILE it shows the save folder on this PC (same paths as above). Or add the .json under res://levels/ in the project.\n\n"
				+ "Press Escape to return.") % "\n".join(line_parts)
			_progress_bar.max_value = 1.0
			_progress_bar.value = 0.0
			_continue_btn.disabled = true
			_refresh_intro_face()
			return
		_rs.archive = loaded
		_gen_label.text = "%d Justin levels ready." % loaded.size()
		_progress_bar.value = 1.0
		_continue_btn.disabled = false
		_refresh_intro_face()
		_continue_btn.grab_focus()
		return

	if mid_tip:
		_gen_label.text = ""
		_progress_bar.visible = false
		_continue_btn.disabled = false
		_refresh_intro_face()
		_continue_btn.grab_focus()
		return

	if not _rs.archive.is_empty():
		# Archive already ready (e.g. coming back from editor with a custom level).
		_gen_label.text = "%d levels ready" % _rs.archive.size()
		_progress_bar.value = 1.0
		_continue_btn.grab_focus()
		_refresh_intro_face()
		return

	_refresh_intro_face()
	_continue_btn.disabled = true
	_pcg_start_ticks = Time.get_ticks_msec()
	var save_target: int = LevelGenerator.ARCHIVE_MAX_LEVELS
	_gen_label.text = "Generating levels... 0 / %d saved (up to %d tries)" % [save_target, LevelGenerator.ARCHIVE_ATTEMPTS]
	_progress_bar.indeterminate = false
	_progress_bar.min_value = 0.0
	_progress_bar.max_value = float(save_target)
	_progress_bar.value = 0.0
	_progress_bar.show_percentage = true

	var seed_val: int = _rs.run_seed
	var loadout_copy: Array[StringName] = []
	loadout_copy.assign(_rs.loadout)
	if OS.has_feature("web"):
		# Web export: avoid Thread usage for broad browser compatibility.
		_pcg_generating_web_sync = true
		_progress_bar.indeterminate = true
		_progress_bar.show_percentage = false
		_gen_label.text = "Generating levels for web build..."
		call_deferred("_build_archive_web_sync", seed_val, loadout_copy)
		return

	var ui_ref: Control = self
	_pcg_cancel = PcgCancel.new()
	var cancel_ref = _pcg_cancel

	_thread = Thread.new()
	@warning_ignore("return_value_discarded")
	_thread.start(func() -> Array:
		return LevelGenerator.build_archive(
			seed_val, loadout_copy, LevelGenerator.ARCHIVE_ATTEMPTS, ui_ref, &"_pcg_progress", cancel_ref)
	)


func _process(_delta: float) -> void:
	if _thread == null:
		return
	if _thread.is_alive():
		return
	var archive: Array = _thread.wait_to_finish()
	_thread = null
	var cancelled: bool = _pcg_cancel != null and _pcg_cancel.is_cancelled()
	_pcg_cancel = null
	if cancelled:
		if is_inside_tree():
			get_tree().change_scene_to_file("res://scenes/ui/main_menu.tscn")
		return
	_rs.archive = archive
	_progress_bar.show_percentage = false
	_progress_bar.max_value = 1.0
	_progress_bar.value = 1.0
	_gen_label.text = "%d levels ready" % archive.size()
	_continue_btn.disabled = false
	_refresh_intro_face()
	_continue_btn.grab_focus()


func _build_archive_web_sync(seed_val: int, loadout_copy: Array[StringName]) -> void:
	if not is_inside_tree():
		return
	# Let the loading UI paint before synchronous generation starts on web.
	await get_tree().process_frame
	if not is_inside_tree():
		return
	var archive: Array = LevelGenerator.build_archive(seed_val, loadout_copy, LevelGenerator.ARCHIVE_ATTEMPTS)
	_pcg_generating_web_sync = false
	_rs.archive = archive
	_progress_bar.indeterminate = false
	_progress_bar.max_value = 1.0
	_progress_bar.value = 1.0
	_gen_label.text = "%d levels ready" % archive.size()
	_continue_btn.disabled = false
	_refresh_intro_face()
	_continue_btn.grab_focus()


func _refresh_intro_face() -> void:
	_level_label.text = "Level %d" % (_rs.current_level_index + 1)
	if _rs.intro_heading_override.is_empty():
		_heading.text = "Your Abilities"
	else:
		_heading.text = _rs.intro_heading_override
	_build_cards()


func _build_cards() -> void:
	for c in _card_row.get_children():
		c.queue_free()
	if _rs.pending_intro_abilities.is_empty():
		for id: StringName in _rs.loadout:
			_card_row.add_child(_make_card(id))
	else:
		for v in _rs.pending_intro_abilities:
			_card_row.add_child(_make_card(v as StringName))


## Main-thread only; invoked via call_deferred from LevelGenerator.build_archive worker thread.
func _pcg_progress(attempts_done: int, attempts_total: int, levels_saved: int, save_cap: int) -> void:
	if not is_inside_tree():
		return
	if _pcg_cancel != null and _pcg_cancel.is_cancelled():
		return
	var cap: int = maxi(save_cap, 1)
	_progress_bar.max_value = float(cap)
	_progress_bar.value = float(mini(levels_saved, cap))
	var elapsed_ms: int = Time.get_ticks_msec() - _pcg_start_ticks
	var eta_str: String = ""
	# ETA toward a full archive = time per saved level (not per failed try).
	if levels_saved > 0 and levels_saved < cap:
		var avg: float = float(elapsed_ms) / float(levels_saved)
		var remain: int = int(avg * float(cap - levels_saved))
		if remain >= 60000:
			eta_str = " - ETA ~%dm %ds to %d" % [remain / 60000, (remain % 60000) / 1000, cap]
		elif remain >= 1000:
			eta_str = " - ETA ~%ds to %d" % [remain / 1000, cap]
		else:
			eta_str = " - almost ready"
	elif levels_saved == 0 and attempts_done > 0:
		eta_str = " - searching first level..."
	_gen_label.text = "Generating levels... %d / %d saved - try %d / %d%s" % [
		levels_saved, cap, attempts_done, attempts_total, eta_str]


func _make_card(id: StringName) -> Control:
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(240, 320)

	var sb := StyleBoxFlat.new()
	var base_col: Color = CardCatalog.card_color(id)
	sb.bg_color = base_col.darkened(0.55)
	sb.border_color = base_col
	sb.set_border_width_all(3)
	sb.set_corner_radius_all(14)
	sb.shadow_color = Color(0, 0, 0, 0.45)
	sb.shadow_size = 8
	sb.shadow_offset = Vector2(3, 4)
	sb.content_margin_left = 18
	sb.content_margin_top = 18
	sb.content_margin_right = 18
	sb.content_margin_bottom = 18
	panel.add_theme_stylebox_override("panel", sb)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 14)

	var icon_wrap := PanelContainer.new()
	var icon_sb := StyleBoxFlat.new()
	icon_sb.bg_color = CardCatalog.card_color(id).lightened(0.08)
	icon_sb.set_corner_radius_all(8)
	icon_wrap.add_theme_stylebox_override("panel", icon_sb)
	icon_wrap.custom_minimum_size = Vector2(0, 68)
	vbox.add_child(icon_wrap)

	var title_lbl := Label.new()
	title_lbl.text = CardCatalog.title(id)
	title_lbl.add_theme_font_size_override("font_size", 22)
	title_lbl.add_theme_color_override("font_color", Color(0.96, 0.98, 1.0))
	title_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(title_lbl)

	var sep := HSeparator.new()
	sep.add_theme_color_override("color", CardCatalog.card_color(id).lightened(0.2))
	vbox.add_child(sep)

	var desc_lbl := Label.new()
	desc_lbl.text = CardCatalog.description(id)
	desc_lbl.add_theme_font_size_override("font_size", 16)
	desc_lbl.add_theme_color_override("font_color", Color(0.80, 0.84, 0.90))
	desc_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(desc_lbl)

	var charges_lbl := Label.new()
	charges_lbl.text = "Charges match level difficulty"
	charges_lbl.add_theme_font_size_override("font_size", 15)
	charges_lbl.add_theme_color_override("font_color", CardCatalog.card_color(id).lightened(0.3))
	charges_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(charges_lbl)

	panel.add_child(vbox)
	return panel


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_ESCAPE):
		return
	if is_inside_tree():
		var vp := get_viewport()
		if vp:
			vp.set_input_as_handled()
	if _thread != null and _thread.is_alive():
		if _pcg_cancel != null:
			_pcg_cancel.cancel()
		if _gen_label != null:
			_gen_label.text = "Cancelling..."
		return
	if _pcg_generating_web_sync:
		return
	if _thread != null:
		@warning_ignore("return_value_discarded")
		_thread.wait_to_finish()
		_thread = null
		_pcg_cancel = null
	_rs.intro_heading_override = ""
	_rs.pending_intro_abilities.clear()
	get_tree().change_scene_to_file("res://scenes/ui/main_menu.tscn")


func _on_continue_pressed() -> void:
	_rs.intro_heading_override = ""
	_rs.pending_intro_abilities.clear()
	get_tree().change_scene_to_file("res://scenes/game_session.tscn")
