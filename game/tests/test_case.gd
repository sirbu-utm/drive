extends Node
## Base class for test files. Collects failures instead of aborting.

var tree: SceneTree
var failures: Array[String] = []

func check(cond: bool, msg: String) -> void:
	if not cond:
		failures.append(msg)

func check_eq(a: Variant, b: Variant, msg: String) -> void:
	if a != b:
		failures.append("%s (got %s, expected %s)" % [msg, str(a), str(b)])

func check_near(a: float, b: float, tol: float, msg: String) -> void:
	if absf(a - b) > tol:
		failures.append("%s (got %f, expected %f +- %f)" % [msg, a, b, tol])

func physics_frames(n: int) -> void:
	for i in n:
		await tree.physics_frame
