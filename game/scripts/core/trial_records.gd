class_name TrialRecords
extends RefCounted
## Best laps (time + sector splits) in user://records.cfg and the ghost of the best lap in user://ghost_<route>.bin.

static var cfg_path := "user://records.cfg"
static var ghost_dir := "user://"


static func _cfg() -> ConfigFile:
	var c := ConfigFile.new()
	c.load(cfg_path)
	return c


## {time: float (0 = none), splits: PackedFloat32Array}
static func best(route: String) -> Dictionary:
	var c := _cfg()
	return {"time": float(c.get_value(route, "time", 0.0)), "splits": PackedFloat32Array(c.get_value(route, "splits", PackedFloat32Array()))}


static func save_best(route: String, time: float, splits: PackedFloat32Array) -> void:
	var c := _cfg()
	c.set_value(route, "time", time)
	c.set_value(route, "splits", splits)
	c.save(cfg_path)


static func ghost_path(route: String) -> String:
	return ghost_dir + "ghost_%s.bin" % route


static func save_ghost(route: String, samples: PackedFloat32Array) -> void:
	var f := FileAccess.open_compressed(ghost_path(route), FileAccess.WRITE, FileAccess.COMPRESSION_ZSTD)
	if f != null:
		f.store_var(samples)
		f.close()


static func load_ghost(route: String) -> PackedFloat32Array:
	if not FileAccess.file_exists(ghost_path(route)):
		return PackedFloat32Array()
	var f := FileAccess.open_compressed(ghost_path(route), FileAccess.READ, FileAccess.COMPRESSION_ZSTD)
	if f == null:
		return PackedFloat32Array()
	var v: Variant = f.get_var()
	f.close()
	return v if v is PackedFloat32Array else PackedFloat32Array()


static func fmt_time(t: float) -> String:
	if t <= 0.0:
		return "--:--.---"
	var m := int(t / 60.0)
	var s := t - m * 60.0
	return "%d:%06.3f" % [m, s]


static func fmt_delta(d: float) -> String:
	return "%s%.3f" % ["+" if d >= 0.0 else "-", absf(d)]
