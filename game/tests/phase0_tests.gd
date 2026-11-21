extends "res://tests/test_case.gd"

func test_physics_settings() -> void:
	check_eq(Engine.physics_ticks_per_second, 240, "physics ticks per second")
	check_eq(Engine.max_physics_steps_per_frame, 8, "max physics steps per frame")
	check_eq(ProjectSettings.get_setting("physics/3d/physics_engine"), "Jolt Physics", "3D physics engine")

func test_rendering_method() -> void:
	check_eq(ProjectSettings.get_setting("rendering/renderer/rendering_method"), "forward_plus", "rendering method")

func test_physics_steps_run() -> void:
	var w := Node3D.new()
	tree.root.add_child(w)
	var body := RigidBody3D.new()
	var shape := CollisionShape3D.new()
	shape.shape = SphereShape3D.new()
	body.add_child(shape)
	w.add_child(body)
	body.global_position = Vector3(0, 10, 0)
	await physics_frames(24)
	check(body.global_position.y < 10.0, "rigid body falls under Jolt (y=%f)" % body.global_position.y)
	# 24 ticks at 240 Hz = 0.1 s -> fall ~ 0.049 m
	check_near(body.global_position.y, 10.0 - 0.5 * 9.8 * 0.1 * 0.1, 0.02, "fall distance after 0.1 s")
	w.queue_free()
