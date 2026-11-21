"""Preview renders of the exported car GLB (what Godot gets), headless Blender.

    blender -b --factory-startup -P pipeline/render_previews.py -- --out docs/shots/phase1
        [--glb game/assets/cars/ccgt/ccgt.glb] [--modes beauty,class] [--views front34,side,...]
        [--res 1600x900] [--samples 96] [--hdri tools/hdri/xxx.hdr] [--prefix ccgt]

modes:  beauty = Cycles (HIP GPU if available, else CPU) with HDRI lighting and a ground plane
        class  = flat-colour material-class map (Workbench, back-face culling ON like Godot)
Car frame (Blender): forward = +Y, right = +X, up = +Z, ground at z = 0.
"""
import bpy
import sys
import os
import math
from mathutils import Vector

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)

CLASS_COLORS = {
    "paint": (0.90, 0.10, 0.10), "carbon": (0.15, 0.15, 0.60), "glass": (0.20, 0.85, 0.95),
    "headlight_glass": (0.60, 0.95, 1.0), "headlight_chrome": (1.0, 0.95, 0.20), "headlight_bulb": (1.0, 1.0, 1.0), "taillight": (1.0, 0.45, 0.0),
    "black_plastic": (0.30, 0.30, 0.30), "interior": (0.60, 0.35, 0.15), "chrome": (0.95, 0.95, 0.95),
    "exhaust": (0.65, 0.20, 0.75), "rim": (0.20, 0.80, 0.30), "tire": (0.04, 0.04, 0.04),
    "brake_disc": (0.50, 0.85, 0.55), "caliper": (1.0, 0.0, 0.8),
}

# name: (location, target, lens_mm or ortho_scale)
VIEWS = {
    "front34": ((-4.6, 6.0, 1.35), (0.0, 0.1, 0.42), 45),
    "rear34": ((4.7, -6.3, 1.5), (0.0, -0.1, 0.48), 45),
    "side": ((-12.0, 0.0, 0.52), (0.0, 0.0, 0.52), ("ortho", 5.2)),
    "top": ((0.0, 0.0, 12.0), (0.0, 0.0, 0.0), ("ortho", 9.0, -90)),
    "bottom": ((0.0, 0.0, -12.0), (0.0, 0.0, 0.0), ("ortho", 9.0, 90)),
    "front": ((0.0, 14.0, 0.55), (0.0, 0.0, 0.5), 100),
    "rear": ((0.0, -14.0, 0.6), (0.0, 0.0, 0.5), 100),
    "side_persp": ((-6.5, 0.4, 0.6), (0.0, 0.1, 0.4), 55),
    "front_wheel": ((-3.0, 4.2, 0.55), (-0.8, 1.35, 0.3), 70),
    "rear_wheel": ((-3.2, -2.2, 0.6), (-0.8, -1.35, 0.3), 70),
    "front_low": ((-1.2, 5.2, 0.45), (0.0, 1.8, 0.4), 60),
    "rear_low": ((1.2, -5.0, 0.7), (0.0, -1.8, 0.5), 60),
    "cockpit": ((-2.2, 1.8, 1.9), (-0.25, 0.4, 0.65), 45),
    "head_close": ((-1.8, 3.6, 0.7), (-0.65, 1.9, 0.4), 70),
}


def log(*a):
    print("[render]", *a, flush=True)


def setup_cycles(scene, samples):
    scene.render.engine = "CYCLES"
    cy = scene.cycles
    prefs = bpy.context.preferences.addons["cycles"].preferences
    gpu = False
    try:
        prefs.compute_device_type = "HIP"
        prefs.refresh_devices()
        for d in prefs.devices:
            d.use = ("7800" in d.name)
            if d.use:
                log("render device:", d.name, d.type)
                gpu = True
    except Exception as e:
        log("HIP setup failed:", e)
    cy.device = "GPU" if gpu else "CPU"
    if not gpu:
        log("falling back to CPU")
    cy.samples = samples
    cy.use_adaptive_sampling = True
    cy.use_denoising = True
    try:
        cy.denoiser = "OPENIMAGEDENOISE"
    except Exception:
        pass
    cy.max_bounces = 10
    cy.transparent_max_bounces = 16
    cy.glossy_bounces = 6
    cy.caustics_reflective = False
    cy.caustics_refractive = False
    scene.view_settings.view_transform = "AgX"
    scene.view_settings.look = "None"


def make_world(scene, hdri, rot_deg=0.0, strength=1.0):
    w = bpy.data.worlds.new("preview")
    scene.world = w
    w.use_nodes = True
    nt = w.node_tree
    for n in list(nt.nodes):
        nt.nodes.remove(n)
    out = nt.nodes.new("ShaderNodeOutputWorld")
    bg = nt.nodes.new("ShaderNodeBackground")
    bg.inputs["Strength"].default_value = strength
    if hdri and os.path.exists(hdri):
        env = nt.nodes.new("ShaderNodeTexEnvironment")
        env.image = bpy.data.images.load(hdri)
        mp = nt.nodes.new("ShaderNodeMapping")
        mp.inputs["Rotation"].default_value[2] = math.radians(rot_deg)
        tc = nt.nodes.new("ShaderNodeTexCoord")
        nt.links.new(tc.outputs["Generated"], mp.inputs["Vector"])
        nt.links.new(mp.outputs["Vector"], env.inputs["Vector"])
        nt.links.new(env.outputs["Color"], bg.inputs["Color"])
    else:
        bg.inputs["Color"].default_value = (0.6, 0.7, 0.85, 1.0)
    nt.links.new(bg.outputs["Background"], out.inputs["Surface"])


def principled(mat, **kw):
    mat.use_nodes = True
    nt = mat.node_tree
    for n in list(nt.nodes):
        nt.nodes.remove(n)
    out = nt.nodes.new("ShaderNodeOutputMaterial")
    b = nt.nodes.new("ShaderNodeBsdfPrincipled")
    for k, v in kw.items():
        if k in b.inputs:
            b.inputs[k].default_value = v
    nt.links.new(b.outputs["BSDF"], out.inputs["Surface"])
    return nt, b


def thin_glass(mat, tint, ior=1.45, rough=0.0):
    """Thin-sheet glass: Fresnel-mixed transparent / glossy (no refraction) - right for single surfaces."""
    mat.use_nodes = True
    nt = mat.node_tree
    for n in list(nt.nodes):
        nt.nodes.remove(n)
    out = nt.nodes.new("ShaderNodeOutputMaterial")
    tr = nt.nodes.new("ShaderNodeBsdfTransparent")
    tr.inputs["Color"].default_value = (*tint, 1.0)
    gl = nt.nodes.new("ShaderNodeBsdfGlossy")
    gl.inputs["Roughness"].default_value = rough
    fr = nt.nodes.new("ShaderNodeFresnel")
    fr.inputs["IOR"].default_value = ior
    mx = nt.nodes.new("ShaderNodeMixShader")
    nt.links.new(fr.outputs["Fac"], mx.inputs["Fac"])
    nt.links.new(tr.outputs["BSDF"], mx.inputs[1])
    nt.links.new(gl.outputs["BSDF"], mx.inputs[2])
    nt.links.new(mx.outputs["Shader"], out.inputs["Surface"])


def carbon_weave(mat):
    """Carbon placeholder: checker on the (metre-scale) box UV so UV scale/validity is visible in the render."""
    nt, b = principled(mat, **{"Roughness": 0.28, "Metallic": 0.0})
    b.inputs["Coat Weight"].default_value = 0.6
    b.inputs["Coat Roughness"].default_value = 0.05
    uv = nt.nodes.new("ShaderNodeTexCoord")
    ck = nt.nodes.new("ShaderNodeTexChecker")
    ck.inputs["Scale"].default_value = 160.0
    ck.inputs["Color1"].default_value = (0.004, 0.004, 0.005, 1)
    ck.inputs["Color2"].default_value = (0.03, 0.03, 0.034, 1)
    nt.links.new(uv.outputs["UV"], ck.inputs["Vector"])
    nt.links.new(ck.outputs["Color"], b.inputs["Base Color"])


def dress_beauty(objs):
    for m in bpy.data.materials:
        n = m.name.split(".")[0]
        if n == "paint":
            principled(m, **{"Base Color": (0.50, 0.015, 0.02, 1), "Metallic": 0.6, "Roughness": 0.30,
                             "Coat Weight": 1.0, "Coat Roughness": 0.015})
        elif n == "carbon":
            carbon_weave(m)
        elif n == "glass":
            thin_glass(m, (0.55, 0.65, 0.7))
        elif n == "headlight_glass":
            thin_glass(m, (0.9, 0.93, 0.95))
        elif n == "headlight_chrome":
            principled(m, **{"Base Color": (0.9, 0.9, 0.92, 1), "Metallic": 1.0, "Roughness": 0.12})
        elif n == "taillight":
            principled(m, **{"Base Color": (0.5, 0.0, 0.0, 1), "Roughness": 0.1, "Emission Color": (1, 0.03, 0.03, 1),
                             "Emission Strength": 3.0})
        elif n == "black_plastic":
            principled(m, **{"Base Color": (0.015, 0.015, 0.016, 1), "Roughness": 0.5})
        elif n == "interior":
            principled(m, **{"Base Color": (0.06, 0.05, 0.045, 1), "Roughness": 0.85})
        elif n == "chrome":
            principled(m, **{"Base Color": (0.9, 0.9, 0.9, 1), "Metallic": 1.0, "Roughness": 0.06})
        elif n == "exhaust":
            principled(m, **{"Base Color": (0.5, 0.45, 0.42, 1), "Metallic": 1.0, "Roughness": 0.3})
        elif n == "rim":
            principled(m, **{"Base Color": (0.72, 0.73, 0.76, 1), "Metallic": 1.0, "Roughness": 0.2})
        elif n == "tire":
            principled(m, **{"Base Color": (0.012, 0.012, 0.012, 1), "Roughness": 0.75})
        elif n == "brake_disc":
            principled(m, **{"Base Color": (0.55, 0.5, 0.45, 1), "Metallic": 1.0, "Roughness": 0.4})
        elif n == "caliper":
            principled(m, **{"Base Color": (0.9, 0.55, 0.0, 1), "Roughness": 0.3, "Coat Weight": 0.5})


def add_ground(size=60.0):
    me = bpy.data.meshes.new("ground")
    me.from_pydata([(-size, -size, 0), (size, -size, 0), (size, size, 0), (-size, size, 0)], [], [(0, 1, 2, 3)])
    ob = bpy.data.objects.new("ground", me)
    bpy.context.scene.collection.objects.link(ob)
    m = bpy.data.materials.new("ground")
    m.use_nodes = True
    nt, b = principled(m, **{"Base Color": (0.16, 0.16, 0.17, 1), "Roughness": 0.65})
    ob.data.materials.append(m)
    return ob


def add_camera(name, loc, target, lens):
    cam = bpy.data.cameras.new(name)
    ob = bpy.data.objects.new(name, cam)
    bpy.context.scene.collection.objects.link(ob)
    ob.location = Vector(loc)
    d = Vector(target) - Vector(loc)
    ob.rotation_euler = d.to_track_quat("-Z", "Y").to_euler()
    if isinstance(lens, tuple):
        cam.type = "ORTHO"
        cam.ortho_scale = lens[1]
        if len(lens) > 2:        # roll about the view axis (degrees)
            from mathutils import Quaternion
            q = ob.rotation_euler.to_quaternion() @ Quaternion((0, 0, 1), math.radians(lens[2]))
            ob.rotation_euler = q.to_euler()
    else:
        cam.lens = lens
    cam.clip_start = 0.05
    cam.clip_end = 200
    return ob


def main():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []

    def arg(name, default=None):
        return argv[argv.index(name) + 1] if name in argv else default

    out = os.path.abspath(arg("--out", os.path.join(ROOT, "docs", "shots", "phase1")))
    glb = os.path.abspath(arg("--glb", os.path.join(ROOT, "game", "assets", "cars", "ccgt", "ccgt.glb")))
    modes = arg("--modes", "beauty,class").split(",")
    views = arg("--views", "front34,side,rear34,top").split(",")
    res = [int(x) for x in arg("--res", "1600x900").split("x")]
    samples = int(arg("--samples", "96"))
    prefix = arg("--prefix", "")
    hdri = arg("--hdri", os.path.join(ROOT, "tools", "hdri", "kloofendal_48d_partly_cloudy_puresky_2k.hdr"))
    hide = [h for h in arg("--hide", "").split(",") if h]
    os.makedirs(out, exist_ok=True)

    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.ops.import_scene.gltf(filepath=glb)
    scene = bpy.context.scene
    scene.render.resolution_x, scene.render.resolution_y = res
    scene.render.resolution_percentage = 100
    scene.render.image_settings.file_format = "PNG"
    objs = [o for o in scene.objects]
    for o in objs:
        if o.type == "EMPTY" and o.name != "CCGT":
            o.hide_render = True
        if any(o.name.startswith(h) for h in hide):
            o.hide_render = True
            o.hide_viewport = True

    cams = {}
    for v in views:
        loc, tgt, lens = VIEWS[v]
        cams[v] = add_camera("cam_" + v, loc, tgt, lens)

    for mode in modes:
        if mode == "beauty":
            setup_cycles(scene, samples)
            make_world(scene, hdri, rot_deg=float(arg("--hdri-rot", "200")), strength=float(arg("--hdri-strength", "1.0")))
            dress_beauty(objs)
            g = add_ground()
            g.hide_render = False
            for v in views:
                scene.camera = cams[v]
                fp = os.path.join(out, f"{prefix}{'beauty_' if not prefix else ''}{v}.png")
                scene.render.filepath = fp
                bpy.ops.render.render(write_still=True)
                log("wrote", fp)
            bpy.data.objects.remove(g)
        elif mode == "class":
            scene.render.engine = "BLENDER_WORKBENCH"
            sh = scene.display.shading
            sh.light = "STUDIO"
            sh.color_type = "MATERIAL"
            sh.show_backface_culling = True
            sh.show_object_outline = False
            sh.show_cavity = False
            scene.display.render_aa = "16"
            scene.view_settings.view_transform = "Standard"
            scene.world = bpy.data.worlds.new("w")
            scene.world.color = (0.82, 0.84, 0.88)
            for m in bpy.data.materials:
                n = m.name.split(".")[0]
                c = CLASS_COLORS.get(n)
                if c:
                    m.diffuse_color = (*c, 1.0)
            for v in views:
                scene.camera = cams[v]
                fp = os.path.join(out, f"{prefix}class_{v}.png")
                scene.render.filepath = fp
                bpy.ops.render.render(write_still=True)
                log("wrote", fp)


if __name__ == "__main__":
    main()
