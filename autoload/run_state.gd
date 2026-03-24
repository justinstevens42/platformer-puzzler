extends Node
class_name RunGameState

## Justin pack: same filenames as Level Editor saves (`PUZZLES_USER_DIR`); loader also checks `res://levels/`.
## Not `const`: `PackedStringArray([...])` is not a constant expression in GDScript.
var JUSTIN_PACK_PATHS: PackedStringArray = PackedStringArray([
	LevelGenerator.PUZZLES_USER_DIR + "firstlevel.json",
	LevelGenerator.PUZZLES_USER_DIR + "level_doublejump_2.json",
	LevelGenerator.PUZZLES_USER_DIR + "level_doublejump_3.json",
	LevelGenerator.PUZZLES_USER_DIR + "level_dj_4.json",
	LevelGenerator.PUZZLES_USER_DIR + "level_dj_5.json",
	LevelGenerator.PUZZLES_USER_DIR + "level_hp_tutorial.json",
	LevelGenerator.PUZZLES_USER_DIR + "level_hp_2.json",
	LevelGenerator.PUZZLES_USER_DIR + "level_hp_3.json",
	LevelGenerator.PUZZLES_USER_DIR + "level_hp_4.json",
	LevelGenerator.PUZZLES_USER_DIR + "level_hp_5.json",
	LevelGenerator.PUZZLES_USER_DIR + "level_combined_0.json",
	LevelGenerator.PUZZLES_USER_DIR + "level_combined_1.json",
	LevelGenerator.PUZZLES_USER_DIR + "level_combined_2.json",
	LevelGenerator.PUZZLES_USER_DIR + "level_5.json",
	LevelGenerator.PUZZLES_USER_DIR + "level_10.json",
])

var timer_running: bool = false
var level_start_time: float = 0.0

var is_run_active: bool = false

var loadout: Array[StringName] = []
var charges: Dictionary = {}

var current_level_index: int = 0
var levels_cleared: int = 0

var current_level_seed: int = 0
var run_seed: int = 0

var total_time_spent: float = 0.0
var ability_uses: Dictionary = {}
var death_count: int = 0
var restart_count: int = 0
## Count of levels skipped this run (Justin pack stats).
var pack_skips: int = 0

## Pre-built MAP-Elites archive for the current run (built in ability_intro).
var archive: Array = []
## The most recently loaded level's raw data (for Save/Edit workflows).
var last_level_data: Dictionary = {}
## When set, game_session plays this level once instead of the archive.
var custom_level_data: Dictionary = {}
## Non-empty: ability_intro loads these JSON paths in order (skips PCG). See `LevelGenerator.PUZZLES_*_DIR`.
var fixed_level_paths: PackedStringArray = []
## Hand-authored Justin campaign: mid-run ability tips + fixed list above.
var justin_campaign: bool = false
## Main-menu PCG modes: play archive[0]..archive[n-1] in order, then show run stats (no random recycle).
var pcg_sequential_run: bool = false
## If non-empty, ability_intro shows only these cards (plus `intro_heading_override`).
var pending_intro_abilities: Array = []
var intro_heading_override: String = ""

signal charges_updated
signal loadout_changed
signal run_started
signal level_advanced(index: int)
signal level_skipped(index: int)
signal run_over(levels_done: int, total_time: float)


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_PAUSABLE
	_ensure_input_actions()


func _ensure_input_actions() -> void:
	var pairs: Dictionary = {
		"move_left": [KEY_LEFT],
		"move_right": [KEY_RIGHT],
		"move_up": [KEY_UP],
		"move_down": [KEY_DOWN],
	}
	for action: String in pairs:
		if not InputMap.has_action(action):
			InputMap.add_action(action)
		InputMap.action_erase_events(action)
		for keycode in pairs[action]:
			var ev := InputEventKey.new()
			ev.physical_keycode = keycode as Key
			InputMap.action_add_event(action, ev)


func start_level_timer() -> void:
	level_start_time = Time.get_ticks_msec() * 0.001
	timer_running = true


func stop_level_timer() -> void:
	if timer_running:
		total_time_spent += Time.get_ticks_msec() * 0.001 - level_start_time
	timer_running = false


func start_new_run(abilities: Array[StringName]) -> void:
	run_seed = randi()
	loadout.clear()
	loadout.assign(abilities)
	charges.clear()
	current_level_index = 0
	levels_cleared = 0
	pack_skips = 0
	timer_running = false
	is_run_active = true
	total_time_spent = 0.0
	death_count = 0
	restart_count = 0
	ability_uses.clear()
	for id in loadout:
		ability_uses[id] = 0
	current_level_seed = _seed_for_level(0)
	archive.clear()
	last_level_data = {}
	custom_level_data = {}
	fixed_level_paths = PackedStringArray()
	justin_campaign = false
	pcg_sequential_run = false
	pending_intro_abilities.clear()
	intro_heading_override = ""
	run_started.emit()


func set_charges_for_level(min_charges: Dictionary) -> void:
	charges.clear()
	for id: StringName in loadout:
		charges[id] = int(min_charges.get(id, 1))
	charges_updated.emit()


func _seed_for_level(idx: int) -> int:
	return run_seed ^ (idx * 0x9e3779b9)


func advance_after_level_clear() -> void:
	stop_level_timer()
	levels_cleared += 1
	current_level_index += 1
	current_level_seed = _seed_for_level(current_level_index)
	level_advanced.emit(current_level_index)


func record_death() -> void:
	death_count += 1
	for id in loadout:
		charges[id] = int(charges.get(id, 0)) + 1
	charges_updated.emit()


func record_restart() -> void:
	restart_count += 1


func skip_level() -> void:
	stop_level_timer()
	pack_skips += 1
	current_level_index += 1
	current_level_seed = _seed_for_level(current_level_index)
	level_skipped.emit(current_level_index)


## End run without `run_over` (Justin pack already showed a custom summary).
func mark_run_finished_quiet() -> void:
	stop_level_timer()
	is_run_active = false


func _end_run() -> void:
	stop_level_timer()
	is_run_active = false
	run_over.emit(levels_cleared, total_time_spent)


func consume_charge(card_id: StringName) -> bool:
	var left: int = int(charges.get(card_id, 0))
	if left <= 0:
		return false
	charges[card_id] = left - 1
	ability_uses[card_id] = int(ability_uses.get(card_id, 0)) + 1
	charges_updated.emit()
	return true


func consume_charges(card_id: StringName, amount: int) -> bool:
	if amount <= 0:
		return true
	var left: int = int(charges.get(card_id, 0))
	if left < amount:
		return false
	charges[card_id] = left - amount
	ability_uses[card_id] = int(ability_uses.get(card_id, 0)) + amount
	charges_updated.emit()
	return true


func get_charge(card_id: StringName) -> int:
	return int(charges.get(card_id, 0))


func _justin_segment_loadout(level_idx: int) -> Array[StringName]:
	if level_idx < 5:
		return [&"high_jump"]
	if level_idx < 10:
		return [&"horizontal_pass"]
	return [&"high_jump", &"horizontal_pass"]


func _loadouts_match(a: Array[StringName], b: Array[StringName]) -> bool:
	if a.size() != b.size():
		return false
	for i in range(a.size()):
		if a[i] != b[i]:
			return false
	return true


## Justin pack: 5 DJ-only → 5 HP-only → 5 both (matches level order + tip screens).
func apply_justin_loadout_for_current_level() -> void:
	if not justin_campaign:
		return
	var want: Array[StringName] = _justin_segment_loadout(current_level_index)
	if _loadouts_match(loadout, want):
		return
	loadout.clear()
	loadout.assign(want)
	for k in ability_uses.keys():
		if not k in loadout:
			ability_uses.erase(k)
	for id: StringName in loadout:
		if not ability_uses.has(id):
			ability_uses[id] = 0
	loadout_changed.emit()


## After `advance_after_level_clear`, `current_level_index` is the next level to play.
## Returns true if we should open ability_intro (tip) before that level.
func apply_justin_mid_intro_if_entering_pack_level() -> bool:
	if not justin_campaign:
		return false
	match current_level_index:
		5:
			pending_intro_abilities.clear()
			pending_intro_abilities.append(&"horizontal_pass")
			intro_heading_override = "Horizontal pass"
			return true
		10:
			pending_intro_abilities.clear()
			pending_intro_abilities.append(&"high_jump")
			pending_intro_abilities.append(&"horizontal_pass")
			intro_heading_override = "Double jump & horizontal pass"
			return true
		_:
			return false
