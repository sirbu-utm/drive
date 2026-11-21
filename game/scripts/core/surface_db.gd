class_name SurfaceDB
extends RefCounted
## Surface types for the tyre model.
## A collider selects its surface with node meta "surface" (on the physics body or one of its parents), e.g.
##   body.set_meta("surface", "grass")                         (uniform surface)
## or, for big colliders that mix several surfaces (terrain), with node meta "surface_provider":
##   body.set_meta("surface_provider", obj)   # obj.surface_at(world_pos: Vector3) -> String
## The provider is asked with the tyre hit position. Default surface: asphalt.

const SURFACES := {
	"asphalt": {"key": "asphalt", "mu": 1.0, "crr": 1.0, "dust": 0.0},
	"curb": {"key": "curb", "mu": 0.95, "crr": 1.3, "dust": 0.0},
	"concrete": {"key": "concrete", "mu": 0.95, "crr": 1.0, "dust": 0.0},
	"gravel": {"key": "gravel", "mu": 0.62, "crr": 3.5, "dust": 0.6},
	"dirt": {"key": "dirt", "mu": 0.68, "crr": 3.0, "dust": 0.8},
	"grass": {"key": "grass", "mu": 0.55, "crr": 4.5, "dust": 0.1},
	"sand": {"key": "sand", "mu": 0.5, "crr": 6.0, "dust": 0.9},
	"rock": {"key": "rock", "mu": 0.85, "crr": 1.6, "dust": 0.2},
	"wet": {"key": "wet", "mu": 0.7, "crr": 1.2, "dust": 0.0},
	"ice": {"key": "ice", "mu": 0.12, "crr": 1.0, "dust": 0.0},
}

static func get_surface(collider: Object, hit_pos: Vector3 = Vector3.INF) -> Dictionary:
	var n := collider as Node
	var depth := 0
	while n != null and depth < 4:
		if n.has_meta("surface_provider") and hit_pos != Vector3.INF:
			var prov: Object = n.get_meta("surface_provider")
			if prov != null and is_instance_valid(prov) and prov.has_method("surface_at"):
				var key := String(prov.surface_at(hit_pos))
				return SURFACES.get(key, SURFACES["asphalt"])
		if n.has_meta("surface"):
			var key2 := String(n.get_meta("surface"))
			return SURFACES.get(key2, SURFACES["asphalt"])
		n = n.get_parent()
		depth += 1
	return SURFACES["asphalt"]
