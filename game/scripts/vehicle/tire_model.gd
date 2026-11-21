class_name TireModel
extends RefCounted
## Pacejka "Magic Formula" tyre with load sensitivity and combined slip through a normalised slip vector
## (friction ellipse). Pure functions of slip; no state.

var p: VehicleParams
var kappa_peak := 0.1       # slip ratio where the pure longitudinal force peaks
var alpha_peak := 0.12      # slip angle (rad) where the pure lateral force peaks


func _init(params: VehicleParams) -> void:
	p = params
	kappa_peak = _find_peak(p.long_B, p.long_C, p.long_E, 1.0)
	alpha_peak = _find_peak(p.lat_B, p.lat_C, p.lat_E, 1.0)


static func mf(x: float, B: float, C: float, E: float) -> float:
	var bx := B * x
	return sin(C * atan(bx - E * (bx - atan(bx))))


static func _find_peak(B: float, C: float, E: float, xmax: float) -> float:
	var best_x := 0.0
	var best := 0.0
	var n := 4000
	for i in range(1, n):
		var x := xmax * float(i) / float(n)
		var y := mf(x, B, C, E)
		if y > best:
			best = y
			best_x = x
	return best_x


## load sensitive friction coefficient multiplier (1 at the nominal load)
func load_factor(fz: float) -> float:
	return maxf(1.0 - p.load_sensitivity * (fz / p.nominal_load - 1.0), 0.45)


## Peak force magnitude available at this load (used by the stick model).
func peak_force(fz: float, mu_scale: float) -> float:
	return p.mu_lat * load_factor(fz) * fz * mu_scale


## Peak pure longitudinal force at this load (traction limit used by TCS / launch control).
func peak_long(fz: float, mu_scale: float) -> float:
	return p.mu_long * load_factor(fz) * fz * mu_scale


## Combined slip force in the contact frame.
## kappa: slip ratio (+ = wheel spinning faster than the ground), alpha: slip angle (+ = moving to the right of the wheel heading).
## Returns Vector3(Fx, Fy, dFx/dkappa); Fy is the force along "positive alpha" = to be applied against the slip, i.e. caller negates.
func combined(kappa: float, alpha: float, fz: float, mu_scale: float) -> Vector3:
	if fz <= 0.0:
		return Vector3.ZERO
	var lf := load_factor(fz)
	var dx := p.mu_long * lf * fz * mu_scale
	var dy := p.mu_lat * lf * fz * mu_scale
	var f := _combined(kappa, alpha, dx, dy)
	var dk := 0.004
	var f2 := _combined(kappa + dk, alpha, dx, dy)
	return Vector3(f.x, f.y, (f2.x - f.x) / dk)


func _combined(kappa: float, alpha: float, dx: float, dy: float) -> Vector2:
	var kn := kappa / kappa_peak
	var an := alpha / alpha_peak
	var s := sqrt(kn * kn + an * an)
	if s < 1e-7:
		return Vector2.ZERO
	var fx0 := dx * mf(s * kappa_peak, p.long_B, p.long_C, p.long_E)
	var fy0 := dy * mf(s * alpha_peak, p.lat_B, p.lat_C, p.lat_E)
	return Vector2(fx0 * kn / s, fy0 * an / s)
