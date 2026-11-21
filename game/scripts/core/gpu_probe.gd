extends Node
## Prints which GPU / renderer is in use (used by Phase 0 verification).

func _ready() -> void:
	print("GPU_PROBE adapter=", RenderingServer.get_video_adapter_name(),
		" vendor=", RenderingServer.get_video_adapter_vendor(),
		" renderer=", RenderingServer.get_current_rendering_method(),
		" driver=", RenderingServer.get_current_rendering_driver_name())
	print("GPU_PROBE physics_ticks=", Engine.physics_ticks_per_second,
		" max_steps=", Engine.max_physics_steps_per_frame,
		" physics_engine=", ProjectSettings.get_setting("physics/3d/physics_engine"))
