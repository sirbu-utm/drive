class_name VehicleParams
extends Resource
## All numbers of one car in one place (Koenigsegg CCGT starting values, tuned by game/tests/vehicle_tests.gd).
## SI units everywhere. Car frame: forward = -Z, right = +X, up = +Y. Origin on the ground, mid-wheelbase.

# ---- chassis -----------------------------------------------------------------------------------------
@export_group("Chassis")
@export var mass := 1150.0
## centre of mass height above the ground at static ride height
@export var cog_height := 0.40
## fraction of the static weight carried by the front axle (CoM is closer to the rear when < 0.5)
@export var front_weight_fraction := 0.42
## principal moments of inertia (x = pitch, y = yaw, z = roll), kg m^2
@export var inertia := Vector3(1500.0, 1750.0, 480.0)

# ---- geometry (overwritten from the car meta json) ---------------------------------------------------
@export_group("Geometry")
@export var wheelbase := 2.72
@export var track_front := 1.62
@export var track_rear := 1.62
@export var wheel_radius := 0.3225
@export var wheel_width := 0.33
## wheel + tyre + brake disc rotating inertia
@export var wheel_inertia := 1.2

# ---- suspension --------------------------------------------------------------------------------------
@export_group("Suspension")
## spring rate at the wheel, N/m
@export var spring_front := 100000.0
@export var spring_rear := 150000.0
## damper, N s/m. Bump = compressing, rebound = extending
@export var bump_front := 3800.0
@export var rebound_front := 7200.0
@export var bump_rear := 5200.0
@export var rebound_rear := 10000.0
## travel from static ride height: up (bump) and down (droop)
@export var travel_bump := 0.095
@export var travel_droop := 0.095
## the last part of the bump travel is a progressive bump stop
@export var bumpstop_length := 0.035
@export var bumpstop_rate := 300000.0
## anti-roll bar, N per metre of left/right compression difference
@export var arb_front := 30000.0
@export var arb_rear := 18000.0
## height above the ground at which tyre side/long forces act on the chassis (roll-centre / anti-dive proxy)
@export var force_height := 0.10

# ---- tyres -------------------------------------------------------------------------------------------
@export_group("Tyres")
## peak friction coefficient at the nominal load (semi slicks)
@export var mu_long := 1.55
@export var mu_lat := 1.32
@export var nominal_load := 3000.0
## mu drops by this fraction per +100 % of load (load sensitivity)
@export var load_sensitivity := 0.14
## Magic Formula coefficients (B stiffness, C shape, E curvature)
@export var long_B := 18.0
@export var long_C := 1.35
@export var long_E := -0.5
@export var lat_B := 15.0
@export var lat_C := 1.30
@export var lat_E := -0.4
## relaxation length of the lateral force (m); 0 disables
@export var relaxation_length := 0.45
## low speed "stick" (bristle) model: stiffness N/m per N of load, damping N s/m per N of load
@export var stick_stiffness := 90.0
@export var stick_damping := 8.0
## below / above these ground speeds the bristle model / Magic Formula is used
@export var stick_speed_low := 0.6
@export var stick_speed_high := 2.2

# ---- engine / drivetrain -----------------------------------------------------------------------------
@export_group("Drivetrain")
## full-throttle torque curve: rpm -> Nm  (peak 560 Nm @ 6500, 450 kW @ 8500) times torque_scale
@export var torque_scale := 0.80
@export var torque_curve_rpm := PackedFloat32Array([0, 1000, 2000, 3000, 4000, 5000, 6000, 6500, 7000, 7500, 8000, 8500, 9000, 9500, 10000])
@export var torque_curve_nm := PackedFloat32Array([0, 180, 260, 330, 420, 500, 548, 560, 556, 542, 524, 506, 470, 380, 250])
@export var idle_rpm := 1100.0
@export var rev_limit_rpm := 9000.0
@export var rev_limit_soft := 250.0
## engine braking torque at closed throttle = a + b * rpm
@export var engine_brake_a := 30.0
@export var engine_brake_b := 0.016
@export var engine_inertia := 0.30
## sequential 6 speed
@export var gear_ratios := PackedFloat32Array([2.92, 2.13, 1.67, 1.35, 1.13, 0.96])
@export var reverse_ratio := 2.9
@export var final_drive := 3.5
@export var driveline_efficiency := 0.92
@export var shift_time := 0.07
@export var clutch_capacity := 1100.0
## engine speed held during clutch launches / launch control (rpm)
@export var launch_rpm := 5200.0
## limited slip differential (clutch pack): preload + coefficient * input torque (power / coast)
@export var diff_preload := 80.0
@export var diff_power_lock := 0.45
@export var diff_coast_lock := 0.2
@export var diff_stiffness := 400.0
## auto-shift
@export var upshift_rpm := 8700.0
@export var downshift_rpm := 4300.0

# ---- brakes ------------------------------------------------------------------------------------------
@export_group("Brakes")
## total brake torque at full pedal over all four wheels (Nm) and front share
@export var brake_torque_total := 5000.0
@export var brake_bias_front := 0.70
@export var handbrake_torque := 4500.0
## hold the car with a light brake when stopped without throttle (parking)
@export var auto_hold_torque := 600.0

# ---- aero --------------------------------------------------------------------------------------------
@export_group("Aero")
@export var cda := 0.60
@export var cla := 2.2
@export var air_density := 1.225
## share of the downforce applied at the front point, the rest at the rear (wing) point
@export var aero_front_share := 0.42
@export var aero_front_point := Vector3(0.0, 0.30, -1.55)
@export var aero_rear_point := Vector3(0.0, 0.95, 1.55)
@export var drag_point_height := 0.45

# ---- steering ----------------------------------------------------------------------------------------
@export_group("Steering")
@export var max_steer_angle_deg := 32.0
## speed at which the available steering angle falls to ~1/(1+1) of the lock (keyboard limiter), m/s
@export var steer_speed_ref := 20.0
@export var steer_speed_exp := 1.6
## steering rack speed limit (rad/s of the wheel angle)
@export var steer_rate := 6.0

# ---- assists -----------------------------------------------------------------------------------------
@export_group("Assists")
@export var abs_enabled := true
@export var tcs_enabled := true
@export var esc_enabled := false
@export var countersteer_assist := false

# ---- rolling resistance ------------------------------------------------------------------------------
@export_group("Resistance")
@export var rolling_resistance := 0.012
@export var rolling_resistance_speed := 0.00005   # added per m/s


func total_ratio(gear: int) -> float:
	if gear == 0:
		return 0.0
	if gear < 0:
		return -reverse_ratio * final_drive
	return gear_ratios[gear - 1] * final_drive


func torque_at(rpm: float) -> float:
	var n := torque_curve_rpm.size()
	if rpm <= torque_curve_rpm[0]:
		return torque_curve_nm[0] * torque_scale
	for i in range(1, n):
		if rpm <= torque_curve_rpm[i]:
			var t := (rpm - torque_curve_rpm[i - 1]) / (torque_curve_rpm[i] - torque_curve_rpm[i - 1])
			return lerpf(torque_curve_nm[i - 1], torque_curve_nm[i], t) * torque_scale
	return torque_curve_nm[n - 1] * torque_scale
