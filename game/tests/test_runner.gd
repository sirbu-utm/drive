extends SceneTree
## Headless test runner.
##   scripts/test.sh            -> runs every res://tests/*_tests.gd
##   scripts/test.sh phase1     -> runs only res://tests/phase1_tests.gd
## Each test file is a script with `extends "res://tests/test_case.gd"` and methods named `test_*`
## (may be coroutines: they can `await` physics/process frames). Exit code 1 on any failure.

const TestCase := preload("res://tests/test_case.gd")

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	var filter := ""
	for a in OS.get_cmdline_user_args():
		filter = a
	var files: Array[String] = []
	var dir := DirAccess.open("res://tests")
	for f in dir.get_files():
		if f.ends_with("_tests.gd") and (filter == "" or f.begins_with(filter)):
			files.append(f)
	files.sort()
	var total := 0
	var failed := 0
	for f in files:
		var script: GDScript = load("res://tests/" + f)
		if script == null:
			printerr("TEST LOAD FAILED: ", f)
			failed += 1
			continue
		var tc: TestCase = script.new()
		tc.tree = self
		root.add_child(tc)
		for m in tc.get_method_list():
			var name: String = m["name"]
			if not name.begins_with("test_"):
				continue
			total += 1
			tc.failures.clear()
			var t0 := Time.get_ticks_msec()
			await tc.call(name)
			var dt := Time.get_ticks_msec() - t0
			if tc.failures.is_empty():
				print("[PASS] %s::%s (%d ms)" % [f, name, dt])
			else:
				failed += 1
				print("[FAIL] %s::%s" % [f, name])
				for msg in tc.failures:
					print("       - ", msg)
		tc.queue_free()
	print("TESTS: %d run, %d failed" % [total, failed])
	quit(1 if failed > 0 or total == 0 else 0)
