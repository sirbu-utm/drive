"""DRIVE1 car pipeline: raw OBJ -> classified, wheel-fitted GLB for Godot.

Run headless (see scripts/build_car.sh):
    blender -b --factory-startup -P pipeline/build_car.py -- [--out game/assets/cars/ccgt]

Coordinate conventions
----------------------
SOURCE OBJ : +Z up, car front = -Y, car LEFT = +X (right-handed), metres, no sensible origin.
BLENDER    : (working frame, "car frame") forward = +Y, right = +X, up = +Z; origin on the ground plane,
             centred between the axles and on the centre line. The source is rotated 180 deg about Z.
GLTF/GODOT : exported with +Y up  =>  forward = -Z, right = +X, up = +Y  (Godot native: Node3D forward
             is -Z, left is -X).  godot = (blender.x, blender.z, -blender.y).

Steps
-----
 1  import the 3 OBJs as numpy arrays (including the author's per-corner normals)
 2  split the body in index-connected components ("parts"), compute per-part stats
 3  detect the wheel arches geometrically (side-silhouette gaps -> axle Y, lip extent -> track); hub height and
    radius come from the wheel model itself -> ground plane
 4  classify every part into a material class (rules in classify_body + pipeline/material_overrides.json)
 5  build Blender objects (Body, Wing, Mirrors, Wheels, Calipers, Taillights, markers), UVs, materials
 6  export GLB + ccgt_meta.json
"""
import bpy
import bmesh
import numpy as np
import sys
import os
import json
import math
import struct
from mathutils import Vector

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
RAW = os.path.join(ROOT, "assets_raw")
OBJ_BODY = "keonigsegg ccgt no win no wheels.obj"
OBJ_WING = "keonigsegg ccgt wing.obj"
OBJ_WHEEL = "koenigsegg ccgt wheels.obj"

TIRE_INSET = 0.02       # tire outer face sits this far inside the fender lip (m)

# ----------------------------------------------------------------------------------------------
# material classes: placeholder PBR values (Phase 4 replaces paint/carbon/glass/tire by real shaders)
# ----------------------------------------------------------------------------------------------
#                    base colour (linear)     metal rough alpha  emission(rgb, strength)  coat
MATERIALS = {
    "paint":            ((0.60, 0.035, 0.03),   0.0, 0.30, 1.0, None, 1.0),
    "carbon":           ((0.015, 0.015, 0.017), 0.0, 0.38, 1.0, None, 0.0),
    "glass":            ((0.02, 0.035, 0.045),  0.0, 0.03, 0.22, None, 0.0),
    "headlight_glass":  ((0.9, 0.95, 1.0),      0.0, 0.02, 0.10, None, 0.0),
    "headlight_chrome": ((0.9, 0.9, 0.92),      1.0, 0.10, 1.0, None, 0.0),
    "headlight_bulb":   ((0.9, 0.9, 0.95),      0.0, 0.05, 1.0, ((1.0, 0.95, 0.88), 2.0), 0.0),
    "taillight":        ((0.6, 0.0, 0.0),       0.0, 0.15, 1.0, ((1.0, 0.02, 0.02), 1.5), 0.0),
    "black_plastic":    ((0.02, 0.02, 0.022),   0.0, 0.55, 1.0, None, 0.0),
    "interior":         ((0.05, 0.045, 0.045),  0.0, 0.8, 1.0, None, 0.0),
    "chrome":           ((0.85, 0.85, 0.87),    1.0, 0.08, 1.0, None, 0.0),
    "exhaust":          ((0.35, 0.34, 0.33),    1.0, 0.32, 1.0, None, 0.0),
    "rim":              ((0.55, 0.56, 0.58),    1.0, 0.22, 1.0, None, 0.0),
    "tire":             ((0.012, 0.012, 0.012), 0.0, 0.85, 1.0, None, 0.0),
    "brake_disc":       ((0.45, 0.44, 0.43),    1.0, 0.42, 1.0, None, 0.0),
    "caliper":          ((0.85, 0.55, 0.0),     0.0, 0.35, 1.0, None, 0.0),
}
# flat colours for the material-class map (render_previews.py)
CLASS_COLORS = {
    "paint": (0.90, 0.10, 0.10), "carbon": (0.15, 0.15, 0.60), "glass": (0.20, 0.85, 0.95),
    "headlight_glass": (0.60, 0.95, 1.0), "headlight_chrome": (1.0, 0.95, 0.20), "headlight_bulb": (1.0, 1.0, 1.0), "taillight": (1.0, 0.45, 0.0),
    "black_plastic": (0.30, 0.30, 0.30), "interior": (0.60, 0.35, 0.15), "chrome": (0.95, 0.95, 0.95),
    "exhaust": (0.65, 0.20, 0.75), "rim": (0.20, 0.80, 0.30), "tire": (0.04, 0.04, 0.04),
    "brake_disc": (0.50, 0.85, 0.55), "caliper": (1.0, 0.0, 0.8),
}


def log(*a):
    print("[build_car]", *a, flush=True)


# ----------------------------------------------------------------------------------------------
# 1. import
# ----------------------------------------------------------------------------------------------
class Raw:
    """Triangle soup straight from an OBJ, in SOURCE coordinates."""

    def __init__(self, co, tris, loop_n):
        self.co = co            # (N,3) float64
        self.tris = tris        # (T,3) int  vertex ids
        self.loop_n = loop_n    # (T,3,3)   per-corner normals (author's custom normals)


def import_obj(filename):
    bpy.ops.wm.obj_import(filepath=os.path.join(RAW, filename), forward_axis="Y", up_axis="Z")
    ob = bpy.context.selected_objects[0]
    me = ob.data
    nv = len(me.vertices)
    co = np.empty(nv * 3)
    me.vertices.foreach_get("co", co)
    co = co.reshape(-1, 3)
    loops = np.empty(len(me.loops), dtype=np.int32)
    me.loops.foreach_get("vertex_index", loops)
    lt = np.empty(len(me.polygons), dtype=np.int32)
    me.polygons.foreach_get("loop_total", lt)
    assert (lt == 3).all(), "source OBJ must be pure triangles"
    cn = np.empty(len(me.corner_normals) * 3)
    me.corner_normals.foreach_get("vector", cn)
    bpy.data.objects.remove(ob)
    bpy.data.meshes.remove(me)
    return Raw(co, loops.reshape(-1, 3).copy(), cn.reshape(-1, 3, 3))


def tri_geometry(co, tris):
    P = co[tris]
    fn = np.cross(P[:, 1] - P[:, 0], P[:, 2] - P[:, 0])
    ln = np.linalg.norm(fn, axis=1)
    return P, fn / np.maximum(ln[:, None], 1e-20), ln / 2


def clean(raw):
    """Drop degenerate triangles and exact opposite-winding duplicates."""
    P, fn, area = tri_geometry(raw.co, raw.tris)
    keep = area > 1e-9
    key = np.round(raw.co / 1e-5).astype(np.int64)
    _, wid = np.unique(key, axis=0, return_inverse=True)
    wid = wid.reshape(-1)
    srt = np.sort(wid[raw.tris], axis=1)
    N = int(wid.max()) + 1
    k = srt[:, 0].astype(np.int64) * N * N + srt[:, 1].astype(np.int64) * N + srt[:, 2]
    seen = {}
    dup = 0
    for i, kk in enumerate(k):
        if not keep[i]:
            continue
        if kk in seen:
            keep[i] = False
            dup += 1
        else:
            seen[kk] = i
    log(f"clean: {int((~keep).sum())} tris dropped (degenerate/duplicate, {dup} duplicates)")
    raw.tris = raw.tris[keep]
    raw.loop_n = raw.loop_n[keep]


def index_components(tris, nv):
    """Connected components by shared vertex INDEX: the author's separate objects stay separate even if they
    touch. Returns per-triangle component id (0..C-1; ids are stable for the given OBJ)."""
    parent = np.arange(nv)

    def find(a):
        while parent[a] != a:
            parent[a] = parent[parent[a]]
            a = parent[a]
        return a

    for a, b, c in tris.tolist():
        for x, y in ((a, b), (b, c)):
            rx, ry = find(x), find(y)
            if rx != ry:
                parent[ry] = rx
    roots = np.array([find(i) for i in range(nv)])
    _, inv = np.unique(roots[tris[:, 0]], return_inverse=True)
    return inv


def part_table(raw, comp):
    P, _, area = tri_geometry(raw.co, raw.tris)
    parts = []
    for i in range(int(comp.max()) + 1):
        m = comp == i
        pts = P[m].reshape(-1, 3)
        a = float(area[m].sum())
        cen = (P[m].mean(1) * area[m, None]).sum(0) / max(a, 1e-12)
        parts.append(dict(id=i, tris=int(m.sum()), area=a, mn=pts.min(0), mx=pts.max(0), cen=cen))
    return parts


# ----------------------------------------------------------------------------------------------
# 3. arches / frame
# ----------------------------------------------------------------------------------------------
def scanline_spans(P, mask, z0):
    """Occupied y-intervals (merged) of triangles in `mask` cut by the horizontal line z=z0 in the YZ projection."""
    Pm = P[mask]
    z = Pm[:, :, 2]
    y = Pm[:, :, 1]
    cut = (z.min(1) <= z0) & (z.max(1) >= z0)
    z, y = z[cut], y[cut]
    ys = np.full((len(z), 3), np.nan)
    for k, (a, b) in enumerate(((0, 1), (1, 2), (2, 0))):
        za, zb = z[:, a], z[:, b]
        m = ((za - z0) * (zb - z0) <= 0) & (za != zb)
        t = np.where(m, (z0 - za) / np.where(zb == za, 1.0, zb - za), 0.0)
        ys[:, k] = np.where(m, y[:, a] + t * (y[:, b] - y[:, a]), np.nan)
    ok = np.isfinite(ys).any(axis=1)
    ys = ys[ok]
    a0 = np.nanmin(ys, axis=1)
    a1 = np.nanmax(ys, axis=1)
    order = np.argsort(a0)
    a0, a1 = a0[order], a1[order]
    merged = []
    c0, c1 = a0[0], a1[0]
    for s, e in zip(a0[1:], a1[1:]):
        if s <= c1 + 1e-4:
            c1 = max(c1, e)
        else:
            merged.append((c0, c1))
            c0, c1 = s, e
    merged.append((c0, c1))
    return merged


def gaps_of(spans):
    return [(b, c) for (a, b), (c, d) in zip(spans[:-1], spans[1:])]


def detect_arches(P, cx, hub_z):
    """Wheel arch openings in the side silhouette (x beyond +-0.5 m of the centre line, projected on YZ).
    Returns {'left': [front, rear], 'right': [front, rear]} (source coords; front = smaller y), each entry holds
    the axle y (median of the opening mid-line over the hub-height rows), the roof of the arch and the edge rows."""
    cen_x = P[:, :, 0].mean(1)
    out = {}
    for side, mask in (("left", cen_x > cx + 0.6), ("right", cen_x < cx - 0.6)):
        spans = scanline_spans(P, mask, hub_z)
        arch_gaps = [g for g in gaps_of(spans) if 0.45 < g[1] - g[0] < 1.1]
        assert len(arch_gaps) == 2, f"{side}: expected 2 arch gaps at hub height, got {arch_gaps}"
        arches = []
        for g in sorted(arch_gaps):
            yc0 = 0.5 * (g[0] + g[1])
            rows = []
            for z0 in np.arange(hub_z - 0.06, hub_z + 0.25, 0.01):
                for b, c in gaps_of(scanline_spans(P, mask, z0)):
                    if b <= yc0 <= c:
                        rows.append((float(z0), float(b), float(c)))
                        break
            top = None
            for z0 in np.arange(hub_z, hub_z + 0.6, 0.004):
                if not any(b <= yc0 <= c for b, c in gaps_of(scanline_spans(P, mask, z0))):
                    top = float(z0)
                    break
            mids = [0.5 * (b + c) for (z0, b, c) in rows if z0 <= hub_z + 0.12]
            widths = [c - b for (z0, b, c) in rows]
            arches.append(dict(y=float(np.median(mids)), top=top, rows=rows, width=float(max(widths))))
        out[side] = arches
    return out


def lip_outer_x(co, cx, arch):
    """Outer x (source, left side) of the fender lip around an arch: median over the rows of the max x of body
    vertices on the opening edges."""
    L = co[co[:, 0] > cx + 0.5]
    vals = []
    for (z0, b, c) in arch["rows"]:
        if z0 < arch["rows"][0][0] + 0.05:
            continue
        for ye in (b, c):
            sel = (np.abs(L[:, 2] - z0) < 0.012) & (np.abs(L[:, 1] - ye) < 0.03)
            if sel.any():
                vals.append(L[sel, 0].max())
    return float(np.median(vals))


# ----------------------------------------------------------------------------------------------
# 4. classification
# ----------------------------------------------------------------------------------------------
def load_overrides():
    with open(os.path.join(HERE, "material_overrides.json")) as f:
        return json.load(f)


class Frame:
    """source -> car frame transform: rotate 180 deg about Z, then translate."""

    def __init__(self, cx, cy, zg):
        self.cx, self.cy, self.zg = cx, cy, zg

    def pt(self, v):
        v = np.asarray(v, dtype=np.float64)
        out = np.empty_like(v)
        out[..., 0] = -(v[..., 0] - self.cx)
        out[..., 1] = -(v[..., 1] - self.cy)
        out[..., 2] = v[..., 2] - self.zg
        return out

    def dir(self, v):
        v = np.asarray(v, dtype=np.float64)
        out = v.copy()
        out[..., 0] *= -1
        out[..., 1] *= -1
        return out


def classify_body(parts, fr, ov):
    """-> (cls, node, why) dicts keyed by part id.
    cls  : material class
    node : which output object the part goes to ('Body' default, 'Mirror_L', 'Taillight_L1', ...)
    Rules work in the CAR frame (x right, y forward, z up from the ground) and only use geometry; the manual
    exceptions live in pipeline/material_overrides.json ("parts": {id: class}, "nodes": {id: node})."""
    cls, node, why = {}, {}, {}
    # first pass: bbox in car frame
    info = {}
    for p in parts:
        a, b = fr.pt(p["mn"]), fr.pt(p["mx"])
        lo, hi = np.minimum(a, b), np.maximum(a, b)
        info[p["id"]] = dict(lo=lo, hi=hi, c=0.5 * (lo + hi), ext=hi - lo, t=p["tris"], A=p["area"])

    def cabin(c):
        return abs(c[0]) < 0.80 and -0.55 < c[1] < 1.45 and 0.08 < c[2] < 1.06

    tail_discs, tail_caps = [], []
    for pid, q in info.items():
        lo, hi, c, ext, t, A = q["lo"], q["hi"], q["c"], q["ext"], q["t"], q["A"]
        k, r = None, ""
        ax = abs(c[0])
        if t > 10000:
            k, r = "paint", "main shell panel (hood/fenders, cabin shell, rear clamshell)"
        elif t <= 60 and A > 2.0:
            k, r = "carbon", "flat underfloor plate"
        elif t > 3000 and A > 1.0 and ext[1] < 0.7 and hi[2] < 0.5 and abs(c[1]) > 1.6:
            k, r = "carbon", "front splitter / rear diffuser (lower bumper piece)"
        elif t > 600 and ext[1] > 1.5 and ext[2] < 0.12 and hi[2] < 0.2:
            k, r = "carbon", "side sill"
        elif t > 3000 and cabin(c) and A > 3.0:
            k, r = "interior", "cabin tub"
        elif t > 3000 and c[1] > 1.6 and ax > 0.4:
            k, r = "headlight_chrome", "headlight assembly (reflector pods)"
        elif t <= 100 and c[1] > 1.55 and ax > 0.4 and c[2] < 0.75:
            k, r = "headlight_bulb", "headlight bulb"
        elif A > 0.5 and t <= 500 and ext[0] > 1.0 and 0.65 < c[2] < 1.1:
            k, r = "glass", "windscreen (double sided pair)"
        elif t <= 120 and 0.12 < A < 0.16 and ax > 0.55 and 0.7 < c[2] < 1.05 and ext[0] < 0.3:
            k, r = "glass", "side window"
        elif 1400 < t < 1500 and c[1] < -1.6:
            k, r = "chrome", "tail light bezel/bowl"
        elif 500 < t < 520 and c[1] < -1.6 and 0.65 < c[2] < 0.80 and A < 0.01:
            k, r = "taillight", "tail light lens disc"
            tail_discs.append(pid)
        elif t == 72 and c[1] < -1.6 and 0.65 < c[2] < 0.80:
            k, r = "taillight", "tail light centre cap"
            tail_caps.append(pid)
        elif t > 1400 and ax > 0.8 and 0.7 < c[2] < 1.0 and 0.2 < c[1] < 0.7:
            k, r = "paint", "mirror housing"
            node[pid] = "Mirror_L" if c[0] < 0 else "Mirror_R"
        elif 400 < t < 450 and ax > 0.8 and 0.6 < c[2] < 0.85 and 0.2 < c[1] < 0.7:
            k, r = "carbon", "mirror stalk"
            node[pid] = "Mirror_L" if c[0] < 0 else "Mirror_R"
        elif 450 < t < 560 and ext[1] > 0.25 and ext[0] < 0.15 and ext[2] < 0.15 and c[1] < -1.6 and c[2] < 0.4:
            k, r = "exhaust", "exhaust pipe"
        elif t == 222 and c[1] > 2.0 and ax < 0.1:
            k, r = "chrome", "nose emblem"
        elif cabin(c):
            k, r = "interior", "inside cabin volume"
        else:
            k, r = "black_plastic", "default for small exterior/underbody parts"
        cls[pid], why[pid] = k, r
        node.setdefault(pid, "Body")
    # tail lights: name the 6 discs Taillight_{L,R}{1..3} (1 = outboard) and attach the centre caps to the nearest one
    names = {}
    for side, sgn in (("L", -1), ("R", 1)):
        ds = sorted([d for d in tail_discs if np.sign(info[d]["c"][0]) == sgn], key=lambda d: -abs(info[d]["c"][0]))
        for n_, d in enumerate(ds, 1):
            names[d] = f"Taillight_{side}{n_}"
            node[d] = names[d]
    for cpid in tail_caps:
        d = min(tail_discs, key=lambda d: np.linalg.norm(info[d]["c"] - info[cpid]["c"]))
        node[cpid] = names[d]
    # manual exceptions
    for pid, k in ov.get("parts", {}).items():
        pid = int(pid)
        cls[pid] = k
        why[pid] = "override"
    for pid, n in ov.get("nodes", {}).items():
        node[int(pid)] = n
    return cls, node, why, info


# ----------------------------------------------------------------------------------------------
# geometry helpers (numpy)
# ----------------------------------------------------------------------------------------------
def mirror_x(co, tris, loop_n):
    co = co.copy()
    co[:, 0] *= -1
    ln = loop_n.copy()
    ln[..., 0] *= -1
    return co, tris[:, [0, 2, 1]].copy(), ln[:, [0, 2, 1], :].copy()


def compact(co, tris, loop_n):
    """Drop unreferenced vertices."""
    used, inv = np.unique(tris, return_inverse=True)
    return co[used], inv.reshape(-1, 3).astype(np.int64), loop_n


def box_uv(co, tris, scale=1.0):
    """World-space (metre) box projection per triangle: UV = the two coordinates orthogonal to the dominant normal
    axis. Texel density is uniform, so tiling textures (carbon weave) look right at any size."""
    P, fn, _ = tri_geometry(co, tris)
    ax = np.abs(fn).argmax(1)
    uv = np.zeros((len(tris), 3, 2))
    for a, (i, j) in enumerate(((1, 2), (0, 2), (0, 1))):
        m = ax == a
        uv[m, :, 0] = P[m][:, :, i] * scale
        uv[m, :, 1] = P[m][:, :, j] * scale
    return uv.reshape(-1, 2)


def wheel_uv(co, tris):
    """Tyre/rim UV: tread = cylindrical (u = arc length, v = axial); axial faces = planar (u=y, v=z)."""
    P, fn, _ = tri_geometry(co, tris)
    th = np.arctan2(P[:, :, 2], P[:, :, 1])
    r = np.hypot(P[:, :, 1], P[:, :, 2])
    u_cyl = th * 0.3225
    # unwrap seam per triangle
    u_cyl = u_cyl - np.round((u_cyl - u_cyl[:, :1]) / (2 * math.pi * 0.3225)) * 2 * math.pi * 0.3225
    side = np.abs(fn[:, 0]) > 0.7
    uv = np.zeros((len(tris), 3, 2))
    uv[..., 0] = np.where(side[:, None], P[:, :, 1], u_cyl)
    uv[..., 1] = np.where(side[:, None], P[:, :, 2], P[:, :, 0])
    return uv.reshape(-1, 2)


# ----------------------------------------------------------------------------------------------
# Blender object builders
# ----------------------------------------------------------------------------------------------
_mat_cache = {}


def get_material(name):
    if name in _mat_cache:
        return _mat_cache[name]
    base, metal, rough, alpha, emis, coat = MATERIALS[name]
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    bsdf = m.node_tree.nodes["Principled BSDF"]
    bsdf.inputs["Base Color"].default_value = (*base, 1.0)
    bsdf.inputs["Metallic"].default_value = metal
    bsdf.inputs["Roughness"].default_value = rough
    bsdf.inputs["Alpha"].default_value = alpha
    if "Coat Weight" in bsdf.inputs:
        bsdf.inputs["Coat Weight"].default_value = coat
        bsdf.inputs["Coat Roughness"].default_value = 0.03
    if emis:
        bsdf.inputs["Emission Color"].default_value = (*emis[0], 1.0)
        bsdf.inputs["Emission Strength"].default_value = emis[1]
    if alpha < 1.0:
        try:
            m.surface_render_method = "BLENDED"
        except Exception:
            pass
        try:
            m.blend_method = "BLEND"
        except Exception:
            pass
    m.diffuse_color = (*base, 1.0)
    _mat_cache[name] = m
    return m


def make_object(name, co, tris, loop_n, face_cls, uv=None, pivot=(0.0, 0.0, 0.0), parent=None, wire=False):
    """Create a mesh object. co/tris/loop_n are in the car frame (absolute); the object origin is placed at `pivot`
    (vertices are stored relative to it). face_cls: array of class names per triangle."""
    co, tris, loop_n = compact(co, tris, loop_n)
    pivot = np.asarray(pivot, dtype=np.float64)
    me = bpy.data.meshes.new(name)
    me.from_pydata((co - pivot).tolist(), [], tris.tolist())
    me.update()
    classes = sorted(set(face_cls.tolist()))
    for c in classes:
        me.materials.append(get_material(c))
    idx = np.array([classes.index(c) for c in face_cls.tolist()], dtype=np.int32)
    me.polygons.foreach_set("material_index", idx)
    me.polygons.foreach_set("use_smooth", np.ones(len(tris), dtype=bool))
    if loop_n is not None:
        me.normals_split_custom_set(loop_n.reshape(-1, 3).tolist())
    if uv is not None:
        layer = me.uv_layers.new(name="UVMap")
        layer.data.foreach_set("uv", uv.reshape(-1))
    me.update()
    ob = bpy.data.objects.new(name, me)
    ob.location = Vector(pivot.tolist())
    bpy.context.scene.collection.objects.link(ob)
    if parent is not None:
        ob.parent = parent
    return ob


def make_empty(name, loc, rot_z=0.0, parent=None, display="ARROWS", size=0.15, **props):
    e = bpy.data.objects.new(name, None)
    e.empty_display_type = display
    e.empty_display_size = size
    e.location = Vector(tuple(float(x) for x in loc))
    e.rotation_euler = (0.0, 0.0, rot_z)
    for k, v in props.items():
        e[k] = v
    bpy.context.scene.collection.objects.link(e)
    if parent is not None:
        e.parent = parent
    return e


def to_godot(v):
    return [float(v[0]), float(v[2]), float(-v[1])]


# ----------------------------------------------------------------------------------------------
# main
# ----------------------------------------------------------------------------------------------
def main():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    out_dir = os.path.join(ROOT, "game", "assets", "cars", "ccgt")
    debug_dir = None
    if "--out" in argv:
        out_dir = os.path.abspath(argv[argv.index("--out") + 1])
    if "--debug-dir" in argv:
        debug_dir = os.path.abspath(argv[argv.index("--debug-dir") + 1])
    os.makedirs(out_dir, exist_ok=True)

    bpy.ops.wm.read_factory_settings(use_empty=True)
    ov = load_overrides()

    # ---- 1/2 import --------------------------------------------------------------------------------
    body, wing, wheel = import_obj(OBJ_BODY), import_obj(OBJ_WING), import_obj(OBJ_WHEEL)
    log(f"imported: body {len(body.tris)} tris, wing {len(wing.tris)}, wheel {len(wheel.tris)}")
    for r in (body, wing, wheel):
        clean(r)
    comp = index_components(body.tris, len(body.co))
    parts = part_table(body, comp)
    log(f"body parts (index-connected): {len(parts)}")

    # ---- 3 wheel model analysis + arch detection -----------------------------------------------------
    wcomp = index_components(wheel.tris, len(wheel.co))
    wparts = part_table(wheel, wcomp)
    tire = max(wparts, key=lambda p: (p["mx"][1] - p["mn"][1]))
    hub = 0.5 * (tire["mn"] + tire["mx"])
    R = 0.5 * (tire["mx"][2] - tire["mn"][2])
    W = tire["mx"][0] - tire["mn"][0]
    log(f"wheel: hub(source)={np.round(hub, 4)} R={R:.4f} width={W:.4f}")
    hub_z = float(hub[2])

    Pb, _, _ = tri_geometry(body.co, body.tris)
    # symmetric centre line from the outer shell extent
    shell = [p for p in parts if p["tris"] > 10000]
    cx = 0.5 * (min(p["mn"][0] for p in shell) + max(p["mx"][0] for p in shell))
    arches = detect_arches(Pb, cx, hub_z)
    yF = np.mean([arches["left"][0]["y"], arches["right"][0]["y"]])
    yR = np.mean([arches["left"][1]["y"], arches["right"][1]["y"]])
    log(f"arch axle y (source): front L/R {arches['left'][0]['y']:.4f}/{arches['right'][0]['y']:.4f} "
        f"rear L/R {arches['left'][1]['y']:.4f}/{arches['right'][1]['y']:.4f}; centre line x={cx:.4f}")
    lipF = lip_outer_x(body.co, cx, arches["left"][0])
    lipR = lip_outer_x(body.co, cx, arches["left"][1])
    # right side for symmetry check (mirror)
    cy = 0.5 * (yF + yR)
    wheelbase = yR - yF
    zg = hub_z - R
    fr = Frame(cx, cy, zg)
    half_front = (lipF - cx) - TIRE_INSET - 0.5 * W      # hub x offset from centre line
    half_rear = (lipR - cx) - TIRE_INSET - 0.5 * W
    log(f"wheelbase {wheelbase:.4f}, ground z(source)={zg:.4f}; fender lip half-width F/R {lipF - cx:.4f}/{lipR - cx:.4f}; "
        f"hub half-track F/R {half_front:.4f}/{half_rear:.4f}")

    # ---- 4 classification -----------------------------------------------------------------------------
    cls, node, why, info = classify_body(parts, fr, ov)
    counts = {}
    for pid, k in cls.items():
        counts[k] = counts.get(k, 0) + parts[pid]["tris"]
    log("class tri counts:", counts)

    # per-triangle arrays in the car frame
    co_f = fr.pt(body.co)
    ln_f = fr.dir(body.loop_n)
    tri_cls = np.array([cls[c] for c in range(len(parts))])[comp].astype(object)
    tri_node = np.array([node[c] for c in range(len(parts))], dtype=object)[comp]

    # per-triangle refinements of the big paint shells ------------------------------------------------------
    Pf, fnf, _ = tri_geometry(co_f, body.tris)
    cen = Pf.mean(1)
    is_paint = tri_cls == "paint"
    # (a) wheel-arch liner: triangles inside the arch openings (YZ projection, beyond 0.5 m from the centre line)
    #     that are NOT outer fender skin (outward-facing normal on the outer 0.85 m) -> black plastic
    liner = np.zeros(len(body.tris), dtype=bool)
    for side in ("left", "right"):
        for ai, arch in enumerate(arches[side]):
            rows = arch["rows"]
            top_f = arch["top"] - zg
            zs = np.array([r_[0] for r_ in rows]) - zg
            hl = np.array([-(r_[2] - cy) for r_ in rows])   # lower y_f edge (car frame y is flipped)
            hh = np.array([-(r_[1] - cy) for r_ in rows])   # upper y_f edge
            m = (np.abs(cen[:, 0]) > 0.5) & ((cen[:, 0] > 0) == (side == "right")) & (cen[:, 2] <= top_f + 0.005)
            iz = np.clip(np.searchsorted(zs, cen[:, 2]), 0, len(zs) - 1)
            marg = 0.012
            inside = (cen[:, 1] > hl[iz] - marg) & (cen[:, 1] < hh[iz] + marg)
            n_out = fnf[:, 0] * np.sign(cen[:, 0])
            outer_skin = (n_out > 0.6) & (np.abs(cen[:, 0]) > 0.85)
            # the liner hugs the tyre: close to the axle in the YZ plane and facing the wheel centre
            ay = -(arch["y"] - cy)
            dy, dz = ay - cen[:, 1], R - cen[:, 2]
            near = np.hypot(dy, dz) < R + 0.20
            facing = (fnf[:, 1] * dy + fnf[:, 2] * dz) > 0.0
            liner |= m & inside & ~outer_skin & near & facing
    arch_liner = liner & is_paint
    tri_cls[arch_liner] = "black_plastic"
    log(f"arch liner triangles reclassified paint->black_plastic: {int(arch_liner.sum())}")
    # (b) underbody / diffuser strakes that live inside the paint comps: low triangles -> carbon
    low = is_paint & ~arch_liner & (((cen[:, 2] < ov.get("underbody_z", 0.19)) & (fnf[:, 2] < -0.35))
                                    | (cen[:, 2] < ov.get("underbody_floor_z", 0.10)))
    tri_cls[low] = "carbon"
    log(f"low (underbody) paint triangles reclassified paint->carbon: {int(low.sum())}")

    # ---- 5 build ---------------------------------------------------------------------------------------
    root = bpy.data.objects.new("CCGT", None)
    root.empty_display_type = "PLAIN_AXES"
    bpy.context.scene.collection.objects.link(root)

    def sel(nodename):
        return tri_node == nodename

    # Body
    mbody = sel("Body")
    uv_body = None
    objs = {}
    t_b = body.tris[mbody]
    ob_body = make_object("Body", co_f, t_b, ln_f[mbody], tri_cls[mbody], uv=box_uv(co_f, t_b), parent=root)
    objs["Body"] = ob_body
    log(f"Body: {len(t_b)} tris")

    # Mirrors / taillights / other named nodes found in classification
    named = sorted(set(tri_node.tolist()) - {"Body"})
    for nm in named:
        m = sel(nm)
        t_n = body.tris[m]
        pts = co_f[np.unique(t_n)]
        piv = pts.mean(0)
        if nm.startswith("Mirror"):
            piv[2] = pts[:, 2].min()          # pivot at the base of the stalk
        objs[nm] = make_object(nm, co_f, t_n, ln_f[m], tri_cls[m], uv=box_uv(co_f, t_n), pivot=piv, parent=root)

    # Wing
    wco = fr.pt(wing.co)
    wln = fr.dir(wing.loop_n)
    wcls = np.array(["carbon"] * len(wing.tris), dtype=object)
    wpiv = wco[np.unique(wing.tris)].mean(0)
    wpiv[0] = 0.0
    objs["Wing"] = make_object("Wing", wco, wing.tris, wln, wcls, uv=box_uv(wco, wing.tris), pivot=wpiv, parent=root)

    # Wheels: local frame, hub at origin, left wheel outward = -X
    outward_src = 1.0
    rim_face = max([p for p in wparts if p["id"] != tire["id"]], key=lambda p: p["tris"])
    outward_src = 1.0 if rim_face["cen"][0] > hub[0] else -1.0
    wl_co = wheel.co - hub
    wl_ln = wheel.loop_n.copy()
    wl_co = np.stack([-wl_co[:, 0], -wl_co[:, 1], wl_co[:, 2]], axis=1)        # rotate 180 deg about Z
    wl_ln = np.stack([-wl_ln[..., 0], -wl_ln[..., 1], wl_ln[..., 2]], axis=-1)
    if outward_src < 0:      # model was a right wheel: mirror into a left one
        wl_co, wl_tris, wl_ln = mirror_x(wl_co, wheel.tris, wl_ln)
    else:
        wl_tris = wheel.tris
    log(f"wheel source outward axis: {'+X' if outward_src > 0 else '-X'} (left-wheel local frame: outward = -X)")
    # classify wheel parts
    wcls_part = {}
    wpart_why = {}
    for p in wparts:
        mn, mx = p["mn"] - hub, p["mx"] - hub
        rmax = max(np.abs([mn[1], mx[1], mn[2], mx[2]]))
        off = np.hypot(0.5 * (mn[1] + mx[1]), 0.5 * (mn[2] + mx[2]))
        if p["id"] == tire["id"]:
            k = "tire"
        elif off > 0.06 and rmax < 0.40:
            k = "caliper"
        elif 0.15 < rmax < 0.23 and abs(0.5 * (mn[2] + mx[2])) < 0.01 and p["tris"] < 600 and p["area"] > 0.2:
            k = "brake_disc"
        else:
            k = "rim"
        wcls_part[p["id"]] = k
    for pid, k in ov.get("wheel_parts", {}).items():
        wcls_part[int(pid)] = k
    wtri_cls = np.array([wcls_part[c] for c in range(len(wparts))], dtype=object)[wcomp]
    log("wheel parts:", {k: [p for p, v in wcls_part.items() if v == k] for k in ("tire", "rim", "brake_disc", "caliper")})
    cal = wtri_cls == "caliper"

    wheel_defs = {"FL": (-half_front, +1, "L"), "FR": (+half_front, +1, "R"),
                  "RL": (-half_rear, -1, "L"), "RR": (+half_rear, -1, "R")}
    axle_y = {1: -(yF - cy), -1: -(yR - cy)}      # car frame y of front/rear axle (front positive)
    wheel_pos = {}
    for nm, (x, ax, side) in wheel_defs.items():
        hubp = np.array([x, axle_y[ax], R])
        wheel_pos[nm] = hubp
        if side == "L":
            c_, t_, n_ = wl_co, wl_tris, wl_ln
        else:
            c_, t_, n_ = mirror_x(wl_co, wl_tris, wl_ln)
        sub = ~cal
        objs["Wheel_" + nm] = make_object("Wheel_" + nm, c_ + hubp, t_[sub], n_[sub], wtri_cls[sub],
                                          uv=wheel_uv(c_, t_[sub]), pivot=hubp, parent=root)
        objs["Caliper_" + nm] = make_object("Caliper_" + nm, c_ + hubp, t_[cal], n_[cal], wtri_cls[cal],
                                            uv=box_uv(c_, t_[cal]), pivot=hubp, parent=root)

    # markers
    def pod(side):
        ids = [pid for pid, k in cls.items() if why[pid].startswith("headlight assembly") and (info[pid]["c"][0] < 0) == (side == "L")]
        assert ids, "headlight pod not found"
        return info[ids[0]]
    for side in ("L", "R"):
        q = pod(side)
        c = q["c"].copy()
        c[1] = q["hi"][1]
        make_empty("Headlight_" + side, c, 0.0, parent=root, size=0.15, kind="headlight")
    ex_ids = sorted([pid for pid, k in cls.items() if k == "exhaust"], key=lambda i: info[i]["c"][0])
    for pid, side in zip(ex_ids, ("L", "R")):
        q = info[pid]
        make_empty("Exhaust_" + side, [q["c"][0], q["lo"][1], q["c"][2]], math.pi, parent=root, size=0.12, kind="exhaust")

    # ---- 6 export ----------------------------------------------------------------------------------------
    bpy.ops.object.select_all(action="DESELECT")
    glb = os.path.join(out_dir, "ccgt.glb")
    bpy.ops.export_scene.gltf(
        filepath=glb, export_format="GLB", use_selection=False, export_yup=True, export_apply=False,
        export_texcoords=True, export_normals=True, export_materials="EXPORT", export_cameras=False,
        export_lights=False, export_extras=True, export_tangents=False, export_animations=False)
    log("exported", glb)

    allco = co_f[np.unique(body.tris[tri_node == "Body"])]
    bb_lo, bb_hi = allco.min(0), allco.max(0)
    meta = dict(
        generator="pipeline/build_car.py",
        axis_convention="Godot: forward = -Z, right = +X, up = +Y. Origin on the ground plane, between the axles, on the centre line.",
        wheelbase=float(wheelbase), wheel_radius=float(R), wheel_width=float(W),
        track_front=float(2 * half_front), track_rear=float(2 * half_rear),
        wheels={k: dict(pos=to_godot(v), position=to_godot(v), radius=float(R), width=float(W),
                        side="left" if k[1] == "L" else "right", axle="front" if k[0] == "F" else "rear")
                for k, v in wheel_pos.items()},
        hub_height=float(R), ground_clearance=float(bb_lo[2]),
        markers={o.name: to_godot(o.location) for o in bpy.data.objects if o.type == "EMPTY" and o.name != "CCGT"},
        bbox_min=to_godot(bb_lo), bbox_max=to_godot(bb_hi),
        size=dict(width=float(bb_hi[0] - bb_lo[0]), length=float(bb_hi[1] - bb_lo[1]), height=float(bb_hi[2])),
        nodes=sorted(o.name for o in objs.values()) + ["Headlight_L", "Headlight_R", "Exhaust_L", "Exhaust_R"],
        material_classes=sorted(MATERIALS.keys()),
        arch=dict(front_axle_y_source=float(yF), rear_axle_y_source=float(yR), centre_x_source=float(cx), ground_z_source=float(zg),
                  fender_lip_half_width_front=float(lipF - cx), fender_lip_half_width_rear=float(lipR - cx), tire_inset=TIRE_INSET),
        source=dict(body_parts=len(parts)),
    )
    with open(os.path.join(out_dir, "ccgt_meta.json"), "w") as f:
        json.dump(meta, f, indent=2)
    log("meta written")

    if debug_dir:
        os.makedirs(debug_dir, exist_ok=True)
        rows = []
        for pid in sorted(cls, key=lambda i: -parts[i]["tris"]):
            q = info[pid]
            rows.append(dict(id=pid, tris=parts[pid]["tris"], cls=cls[pid], node=node[pid], why=why[pid],
                             lo=[round(float(x), 3) for x in q["lo"]], hi=[round(float(x), 3) for x in q["hi"]]))
        with open(os.path.join(debug_dir, "parts.json"), "w") as f:
            json.dump(rows, f, indent=1)
        bpy.ops.wm.save_as_mainfile(filepath=os.path.join(debug_dir, "ccgt_debug.blend"))


if __name__ == "__main__":
    main()
