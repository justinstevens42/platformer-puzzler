extends Control

@onready var _rs: RunGameState = get_node("/root/RunState") as RunGameState
@onready var _charge_row: HBoxContainer = $Margin/VBox/TopBar/ChargeRow
@onready var _reset_btn: Button = $Margin/VBox/TopBar/ResetBtn
@onready var _skip_btn: Button = $Margin/VBox/TopBar/SkipBtn
@onready var _run_stats_panel: PanelContainer = $Margin/VBox/TopBar/LivesPanel

var _charge_labels: Dictionary = {}


func _ready() -> void:
	_rs.charges_updated.connect(_refresh_charges)
	_rs.loadout_changed.connect(_build_charge_display)
	_reset_btn.pressed.connect(_on_reset_pressed)
	_skip_btn.pressed.connect(_on_skip_pressed)
	_build_charge_display()
	_refresh_charges()
	_run_stats_panel.visible = false
	if not _rs.justin_campaign:
		_add_save_button()


func _add_save_button() -> void:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.08, 0.12, 0.06, 0.92)
	sb.border_color = Color(0.45, 0.60, 0.20, 1.0)
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(8)
	sb.content_margin_left = 12
	sb.content_margin_top = 6
	sb.content_margin_right = 12
	sb.content_margin_bottom = 6

	var btn := Button.new()
	btn.text = "Save [B]"
	btn.focus_mode = Control.FOCUS_NONE
	btn.add_theme_font_size_override("font_size", 17)
	btn.add_theme_stylebox_override("normal", sb)
	btn.add_theme_stylebox_override("hover", sb)
	btn.add_theme_stylebox_override("pressed", sb)
	btn.pressed.connect(_on_save_pressed)
	$Margin/VBox/TopBar.add_child(btn)


func _build_charge_display() -> void:
	for c in _charge_row.get_children():
		c.queue_free()
	_charge_labels.clear()

	for id: StringName in _rs.loadout:
		var panel := PanelContainer.new()
		var sb := StyleBoxFlat.new()
		var col: Color = CardCatalog.card_color(id)
		sb.bg_color = col.darkened(0.7)
		sb.border_color = col.darkened(0.2)
		sb.set_border_width_all(2)
		sb.set_corner_radius_all(8)
		sb.content_margin_left = 14
		sb.content_margin_top = 8
		sb.content_margin_right = 14
		sb.content_margin_bottom = 8
		panel.add_theme_stylebox_override("panel", sb)

		var lbl := Label.new()
		lbl.add_theme_font_size_override("font_size", 17)
		lbl.add_theme_color_override("font_color", Color(0.92, 0.95, 1.0))
		panel.add_child(lbl)

		_charge_row.add_child(panel)
		_charge_labels[id] = lbl

	_refresh_charges()


func _refresh_charges() -> void:
	for id: StringName in _charge_labels:
		var lbl: Label = _charge_labels[id]
		var n: int = _rs.get_charge(id)
		lbl.text = "%s (%d)" % [CardCatalog.title(id), n]
		lbl.modulate = Color.WHITE if n > 0 else Color(0.45, 0.48, 0.52)


func _on_reset_pressed() -> void:
	var gs: Node = get_tree().get_first_node_in_group("game_session")
	if gs and gs.has_method("reset_current_level"):
		gs.call("reset_current_level")


func _on_skip_pressed() -> void:
	var gs: Node = get_tree().get_first_node_in_group("game_session")
	if gs and gs.has_method("skip_current_level"):
		gs.call("skip_current_level")


func _on_save_pressed() -> void:
	var gs: Node = get_tree().get_first_node_in_group("game_session")
	if gs and gs.has_method("save_current_level"):
		gs.call("save_current_level")


func _update_timer() -> void:
	var elapsed: float = _rs.total_time_spent
	if _rs.timer_running:
		elapsed += Time.get_ticks_msec() * 0.001 - _rs.level_start_time
	var total_seconds: int = int(floorf(maxf(elapsed, 0.0)))
	@warning_ignore("integer_division")
	var m: int = total_seconds / 60
	var s: int = total_seconds % 60
	var label: Label = $Margin/VBox/TopBar/TimerPanel/TimerLabel as Label
	label.text = "Lv %d  %02d:%02d" % [_rs.current_level_index + 1, m, s]


func _process(_delta: float) -> void:
	_update_timer()
