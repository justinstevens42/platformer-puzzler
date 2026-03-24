extends Node2D


func get_briefing_text() -> String:
	return (
		"Tutorial - Clear the gap\n\n"
		+ "Reach the flag on the right. The stone posts and brown crate sit in a narrow gap - you can't walk through until the crate is pulled aside.\n\n"
		+ "Play Pull Block from your deck (click the card or press its number key). When it asks for a direction, press the arrow toward the crate (usually RIGHT).\n\n"
		+ "Move: LEFT RIGHT    Jump: UP    Play card: click or 1-4    Esc: cancel aim"
	)


func get_briefing_title() -> String:
	return "How to beat this room"
