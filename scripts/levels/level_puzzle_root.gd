extends Node2D


func get_briefing_text() -> String:
	return (
		"Pit crossing\n\n"
		+ "The pale blue wall is a phase barrier - play Phase Wall, then press LEFT or RIGHT to walk through it for a moment.\n\n"
		+ "Past that is a pit. From the left ledge, play Hookshot to snap to the green ring on the right, then reach the flag.\n\n"
		+ "Include Phase Wall and Hookshot in your four-card loadout. Esc cancels aim."
	)


func get_briefing_title() -> String:
	return "How to beat this room"
