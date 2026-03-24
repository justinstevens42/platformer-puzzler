extends RefCounted
class_name CardCatalog

static var definitions: Dictionary = {
	&"high_jump": {
		"title": "Double Jump",
		"needs_direction": false,
		"description": "Press UP while airborne to jump again mid-air. Reach elevated platforms that a single jump can't.",
		"color": Color(0.28, 0.76, 0.46),
	},
	&"horizontal_pass": {
		"title": "Horizontal Pass",
		"needs_direction": false,
		"description": "Double-tap LEFT or RIGHT to slip through one adjacent wall tile in that direction.",
		"color": Color(0.38, 0.62, 0.92),
	},
	&"phase_wall": {
		"title": "Phase Wall",
		"needs_direction": true,
		"description": "Momentarily phase through the nearest solid wall in the chosen direction - slip through barriers that would otherwise block your path.",
		"color": Color(0.38, 0.62, 0.92),
	},
	&"hookshot": {
		"title": "Hookshot",
		"needs_direction": false,
		"description": "Fire a grappling hook to the right - if there is an anchor ring nearby, you zip straight to it, crossing any gap in an instant.",
		"color": Color(0.88, 0.72, 0.22),
	},
	&"pull_block": {
		"title": "Pull Block",
		"needs_direction": true,
		"description": "Yank the nearest movable crate in the chosen direction - clear a path, bridge a gap, or stack a step to reach higher ground.",
		"color": Color(0.76, 0.44, 0.24),
	},
	&"dash": {
		"title": "Air Dash",
		"needs_direction": true,
		"description": "Burst through the air in any direction - perfect for crossing wide gaps mid-jump or escaping a tight spot in a hurry.",
		"color": Color(0.88, 0.34, 0.54),
	},
}


static func needs_direction(id: StringName) -> bool:
	var d: Variant = definitions.get(id, {})
	return d.get("needs_direction", false) as bool


static func title(id: StringName) -> String:
	var d: Variant = definitions.get(id, {})
	return str(d.get("title", str(id)))


static func description(id: StringName) -> String:
	var d: Variant = definitions.get(id, {})
	return str(d.get("description", "No description available."))


static func card_color(id: StringName) -> Color:
	var d: Variant = definitions.get(id, {})
	return d.get("color", Color(0.35, 0.42, 0.52)) as Color
