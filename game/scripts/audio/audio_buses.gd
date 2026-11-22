class_name AudioBuses
extends RefCounted
## Runtime audio bus layout (no .tres needed):
##   Master
##     Engine     (engine loops, transmission whine)          LowPass "lp", LowShelf "shelf"
##     Effects    (tyres, surface, pops, shifts, impacts)     LowPass "lp"
##     Ambience   (wind)                                      LowPass "lp"
## The low-pass filters are driven by VehicleAudio: muffled inside the car, open outside, wind darker at low speed.

const NAMES := ["Engine", "Effects", "Ambience"]
static var _ready := false


static func ensure() -> void:
	if _ready:
		return
	_ready = true
	for n in NAMES:
		if AudioServer.get_bus_index(n) >= 0:
			continue
		AudioServer.add_bus()
		var idx := AudioServer.bus_count - 1
		AudioServer.set_bus_name(idx, n)
		AudioServer.set_bus_send(idx, "Master")
		var lp := AudioEffectLowPassFilter.new()
		lp.cutoff_hz = 20000.0
		AudioServer.add_bus_effect(idx, lp)                       # effect 0: lowpass
		if n == "Engine":
			var sh := AudioEffectLowShelfFilter.new()
			sh.cutoff_hz = 220.0
			sh.gain = 1.0
			AudioServer.add_bus_effect(idx, sh)                   # effect 1: low shelf (gain is a ratio)


static func set_lowpass(bus: String, hz: float) -> void:
	var i := AudioServer.get_bus_index(bus)
	if i >= 0:
		(AudioServer.get_bus_effect(i, 0) as AudioEffectLowPassFilter).cutoff_hz = hz


static func set_engine_shelf(gain: float) -> void:
	var i := AudioServer.get_bus_index("Engine")
	if i >= 0 and AudioServer.get_bus_effect_count(i) > 1:
		(AudioServer.get_bus_effect(i, 1) as AudioEffectLowShelfFilter).gain = gain


static func set_volume(bus: String, linear: float) -> void:
	var i := AudioServer.get_bus_index(bus)
	if i >= 0:
		AudioServer.set_bus_volume_db(i, linear_to_db(maxf(linear, 0.0001)))
