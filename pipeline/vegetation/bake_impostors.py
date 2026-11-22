"""Bake view-dependent impostor atlases from film-quality Poly Haven trees (headless Blender + Cycles GPU).

    blender -b --factory-startup -P pipeline/vegetation/bake_impostors.py -- <model.gltf> <out_dir> [--node NAME] [--name OUT]

Frame layout (tuned for ground-level viewing): AZ azimuths x EL elevations, frame k = el * AZ + az,
atlas column = k % COLS, row = k // COLS.  Elevations: 0, 25, 55 degrees.
Outputs  <out>/<name>_albedo.png   RGB = albedo * baked canopy AO, A = coverage
         <out>/<name>_normal.png   RGB = object-space normal (Godot axes, *0.5+0.5), A = depth (0 = near)
         <out>/<name>.json         radius, centre, frame layout, size
Godot axes: +Y up. Blender: +Z up.  godot (x, y, z) = blender (x, z, -y).
"""
import bpy
import json
import math
import os
import sys

import numpy as np
from mathutils import Vector

AZ = 16
ELS = [0.0, 25.0, 55.0]
COLS = 8
FRAME = 512
SAMPLES = 32


def log(*a):
    print("[impostor]", *a, flush=True)


def setup_render(scene):
    scene.render.engine = "CYCLES"
    prefs = bpy.context.preferences.addons["cycles"].preferences
    try:
        prefs.compute_device_type = "HIP"
        prefs.refresh_devices()
        for d in prefs.devices:
            d.use = d.type != "CPU"
        scene.cycles.device = "GPU"
    except Exception as e:
        log("GPU setup failed, CPU:", e)
    scene.cycles.samples = SAMPLES
    scene.cycles.use_denoising = False
    scene.cycles.max_bounces = 4
    scene.cycles.transparent_max_bounces = 16
    scene.render.film_transparent = True
    scene.render.resolution_x = FRAME
    scene.render.resolution_y = FRAME
    scene.render.resolution_percentage = 100
    scene.render.use_persistent_data = True
    scene.view_settings.view_transform = "Standard"
    vl = scene.view_layers[0]
    vl.use_pass_diffuse_color = True
    vl.use_pass_normal = True
    vl.use_pass_z = True
    vl.use_pass_ambient_occlusion = True
    scene.world = bpy.data.worlds.new("w")
    scene.world.color = (1, 1, 1)
    scene.world.light_settings.distance = 1.5


def comp_outputs(scene, tmpdir):
    scene.use_nodes = True
    nt = scene.node_tree
    nt.nodes.clear()
    rl = nt.nodes.new("CompositorNodeRLayers")
    out = nt.nodes.new("CompositorNodeOutputFile")
    out.base_path = tmpdir
    out.format.file_format = "OPEN_EXR"
    out.format.color_depth = "32"
    out.file_slots.clear()
    for name in ("DiffCol", "Normal", "Depth", "AO", "Alpha"):
        out.file_slots.new(name)
        nt.links.new(rl.outputs[name], out.inputs[name])
    return out


def load_exr(path):
    img = bpy.data.images.load(path)
    w, h = img.size
    px = np.empty(w * h * 4, dtype=np.float32)
    img.pixels.foreach_get(px)
    bpy.data.images.remove(img)
    return px.reshape(h, w, 4)[::-1]            # row 0 = top


def dilate(rgb, alpha, iters=12):
    """Push colours into transparent texels so mip-maps don't bleed dark halos."""
    rgb = rgb.copy()
    m = alpha > 0.02
    for _ in range(iters):
        acc = np.zeros_like(rgb)
        cnt = np.zeros(m.shape, dtype=np.float32)
        for dy, dx in ((1, 0), (-1, 0), (0, 1), (0, -1), (1, 1), (-1, -1), (1, -1), (-1, 1)):
            sm = np.roll(np.roll(m, dy, 0), dx, 1)
            sc = np.roll(np.roll(rgb, dy, 0), dx, 1)
            acc += sc * sm[..., None]
            cnt += sm
        grow = (~m) & (cnt > 0)
        rgb[grow] = acc[grow] / cnt[grow][:, None]
        m = m | grow
    return rgb


def save_png(arr, path):
    h, w, _ = arr.shape
    img = bpy.data.images.new(os.path.basename(path), w, h, alpha=True, float_buffer=False)
    img.pixels.foreach_set(np.ascontiguousarray(arr[::-1]).astype(np.float32).ravel())
    img.filepath_raw = path
    img.file_format = "PNG"
    img.save()
    bpy.data.images.remove(img)


def main():
    argv = sys.argv[sys.argv.index("--") + 1:]
    model, out_dir = argv[0], argv[1]
    only = argv[argv.index("--node") + 1] if "--node" in argv else None
    name = argv[argv.index("--name") + 1] if "--name" in argv else os.path.splitext(os.path.basename(model))[0]
    os.makedirs(out_dir, exist_ok=True)
    bpy.ops.wm.read_factory_settings(use_empty=True)
    scene = bpy.context.scene
    bpy.ops.import_scene.gltf(filepath=model)
    meshes = [o for o in scene.objects if o.type == "MESH"]
    if only:
        keep = [o for o in scene.objects if o.name.startswith(only)]
        keep_set = set(keep)
        for o in keep:
            keep_set.update(o.children_recursive)
        for o in meshes:
            if o not in keep_set:
                bpy.data.objects.remove(o, do_unlink=True)
        meshes = [o for o in scene.objects if o.type == "MESH"]
    # move the tree base to the origin (centre of the bbox footprint, lowest point)
    mn = Vector((1e9, 1e9, 1e9))
    mx = Vector((-1e9, -1e9, -1e9))
    for o in meshes:
        for c in o.bound_box:
            w = o.matrix_world @ Vector(c)
            mn = Vector(map(min, mn, w))
            mx = Vector(map(max, mx, w))
    base = Vector(((mn.x + mx.x) / 2, (mn.y + mx.y) / 2, mn.z))
    for o in scene.objects:
        if o.parent is None:
            o.location -= base
    mn -= base
    mx -= base
    centre = (mn + mx) / 2
    radius = (mx - centre).length * 1.02
    # true horizontal radius of the crown (bounding cylinder about the vertical axis through the centre)
    r_h = 0.0
    for o in meshes:
        n = len(o.data.vertices)
        co = np.empty(n * 3, dtype=np.float32)
        o.data.vertices.foreach_get("co", co)
        co = co.reshape(-1, 3)
        M = np.array(o.matrix_world)
        w = co @ M[:3, :3].T + M[:3, 3]
        r_h = max(r_h, float(np.sqrt((w[:, 0] - centre.x) ** 2 + (w[:, 1] - centre.y) ** 2).max()))
    H = mx.z - mn.z
    # per-elevation frame size: projection of the bounding cylinder, +3% margin
    scales = [1.03 * max(2 * r_h, H * math.cos(math.radians(e)) + 2 * r_h * math.sin(math.radians(e))) for e in ELS]
    log(f"{name}: bbox {tuple(round(v, 2) for v in mn)} .. {tuple(round(v, 2) for v in mx)}  radius {radius:.2f}  "
        f"tris {sum(len(o.data.polygons) for o in meshes)}")

    setup_render(scene)
    tmp = os.path.join(out_dir, "_tmp_" + name)
    os.makedirs(tmp, exist_ok=True)
    comp_outputs(scene, tmp)
    cam_data = bpy.data.cameras.new("cam")
    cam_data.type = "ORTHO"
    cam_data.ortho_scale = 2 * radius
    cam_data.clip_start = 0.01
    cam_data.clip_end = 4 * radius + 10
    cam = bpy.data.objects.new("cam", cam_data)
    scene.collection.objects.link(cam)
    scene.camera = cam

    n_frames = AZ * len(ELS)
    rows = math.ceil(n_frames / COLS)
    alb_atlas = np.zeros((rows * FRAME, COLS * FRAME, 4), dtype=np.float32)
    nrm_atlas = np.zeros((rows * FRAME, COLS * FRAME, 4), dtype=np.float32)
    dist = 2 * radius + 1.0
    for ei, el in enumerate(ELS):
        for ai in range(AZ):
            k = ei * AZ + ai
            az = 2 * math.pi * ai / AZ
            e = math.radians(el)
            # direction from centre to camera, Godot axes, then to Blender axes
            dg = Vector((math.sin(az) * math.cos(e), math.sin(e), math.cos(az) * math.cos(e)))
            db = Vector((dg.x, -dg.z, dg.y))
            cam_data.ortho_scale = scales[ei]
            cam.location = centre + db * dist
            # camera looks at the centre, up = world up
            fwd = (centre - cam.location).normalized()
            rot = fwd.to_track_quat("-Z", "Y")
            cam.rotation_euler = rot.to_euler()
            scene.frame_current = k
            bpy.ops.render.render(write_still=False)
            def f(p):
                return os.path.join(tmp, f"{p}{k:04d}.exr")
            col = load_exr(f("DiffCol"))[..., :3]
            nrm = load_exr(f("Normal"))[..., :3]
            dep = load_exr(f("Depth"))[..., 0]
            ao = load_exr(f("AO"))[..., 0]
            al = load_exr(f("Alpha"))[..., 0]
            cov = al > 0.01
            # normal: blender world -> godot object axes
            ng = np.stack([nrm[..., 0], nrm[..., 2], -nrm[..., 1]], axis=-1)
            ln = np.linalg.norm(ng, axis=-1, keepdims=True)
            ng = np.where(ln > 1e-6, ng / np.maximum(ln, 1e-6), np.array([0, 1, 0]))
            # depth normalised over the bounding sphere (0 = nearest to camera)
            d01 = np.clip((dep - (dist - radius)) / (2 * radius), 0, 1)
            d01 = np.where(cov, d01, 1.0)
            albedo = col * (0.35 + 0.65 * np.clip(ao, 0, 1))[..., None]
            albedo = np.where(cov[..., None], albedo / np.maximum(al[..., None], 1e-3), 0.0)
            albedo = dilate(np.clip(albedo, 0, 1), al)
            ng = dilate(ng * 0.5 + 0.5, al)
            r0, c0 = (k // COLS) * FRAME, (k % COLS) * FRAME
            alb_atlas[r0:r0 + FRAME, c0:c0 + FRAME, :3] = albedo
            alb_atlas[r0:r0 + FRAME, c0:c0 + FRAME, 3] = al
            nrm_atlas[r0:r0 + FRAME, c0:c0 + FRAME, :3] = ng
            nrm_atlas[r0:r0 + FRAME, c0:c0 + FRAME, 3] = d01
            log(f"frame {k + 1}/{n_frames} az {math.degrees(az):5.1f} el {el:4.1f}")
    # albedo pass is linear; store sRGB in the PNG
    lin = alb_atlas[..., :3]
    alb_atlas[..., :3] = np.where(lin <= 0.0031308, lin * 12.92, 1.055 * np.power(np.maximum(lin, 0), 1 / 2.4) - 0.055)
    save_png(alb_atlas, os.path.join(out_dir, f"{name}_albedo.png"))
    save_png(nrm_atlas, os.path.join(out_dir, f"{name}_normal.png"))
    meta = dict(name=name, radius=radius, crown_radius=r_h, scales=scales, centre=[centre.x, centre.z, -centre.y], height=mx.z,
                az=AZ, elevations=ELS, cols=COLS, rows=rows, frame=FRAME,
                bbox_min=[mn.x, mn.z, -mx.y], bbox_max=[mx.x, mx.z, -mn.y])
    with open(os.path.join(out_dir, f"{name}.json"), "w") as fh:
        json.dump(meta, fh, indent=1)
    for fn in os.listdir(tmp):
        os.remove(os.path.join(tmp, fn))
    os.rmdir(tmp)
    log("done", name)


main()
