extends Area2D

var _cleared: bool = false
var _wave_time: float = 0.0

const POLE_TOP := -80.0
const GROUND_Y := 32.0


func _ready() -> void:
	monitoring = false
	body_entered.connect(_on_body_entered)
	queue_redraw()
	get_tree().create_timer(0.2).timeout.connect(_activate)


func _activate() -> void:
	if is_inside_tree():
		monitoring = true


func _process(delta: float) -> void:
	_wave_time += delta
	queue_redraw()


func _draw() -> void:
	# Base plate sitting on the ground.
	draw_rect(Rect2(-12.0, GROUND_Y - 6.0, 24.0, 6.0), Color(0.55, 0.42, 0.22))
	draw_rect(Rect2(-8.0, GROUND_Y - 10.0, 16.0, 4.0), Color(0.50, 0.38, 0.18))

	# Pole from base to top.
	draw_rect(Rect2(-2.5, POLE_TOP, 5.0, GROUND_Y - POLE_TOP - 6.0), Color(0.62, 0.52, 0.30))
	draw_rect(Rect2(-1.5, POLE_TOP, 3.0, GROUND_Y - POLE_TOP - 6.0), Color(0.72, 0.60, 0.35))

	# Gold ball at the top.
	draw_circle(Vector2(0.0, POLE_TOP - 4.0), 5.0, Color(0.95, 0.82, 0.20))
	draw_circle(Vector2(-1.0, POLE_TOP - 5.5), 2.0, Color(1.0, 0.95, 0.55))

	# Flag banner waving.
	var wave: float = sin(_wave_time * 4.0) * 3.0
	var flag_top: float = POLE_TOP + 2.0
	var flag_h := 20.0
	var flag_w := 28.0
	var pts := PackedVector2Array([
		Vector2(2.0, flag_top),
		Vector2(2.0 + flag_w, flag_top + wave),
		Vector2(2.0 + flag_w, flag_top + flag_h + wave * 0.6),
		Vector2(2.0, flag_top + flag_h),
	])
	draw_colored_polygon(pts, Color(0.92, 0.25, 0.22))

	# Inner highlight stripe.
	var stripe_pts := PackedVector2Array([
		Vector2(2.0, flag_top + 6.0),
		Vector2(2.0 + flag_w * 0.85, flag_top + 6.0 + wave * 0.7),
		Vector2(2.0 + flag_w * 0.85, flag_top + 12.0 + wave * 0.5),
		Vector2(2.0, flag_top + 12.0),
	])
	draw_colored_polygon(stripe_pts, Color(1.0, 0.45, 0.30))


func _on_body_entered(body: Node2D) -> void:
	if _cleared:
		return
	if body == null or not body.is_in_group("player"):
		return
	_cleared = true
	set_deferred("monitoring", false)
	get_tree().call_group("game_session", "notify_goal_reached")
