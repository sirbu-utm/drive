"""Analyse equirectangular HDRIs: find the sun (or moon) and measure sky/sun light, so Godot can light the
scene with a DirectionalLight that matches the photo while the sky shader clamps the disc out of the HDRI.

Run headless:  blender -b --factory-startup -P pipeline/hdri_sun.py -- <hdri_dir> <out.json>

Direction convention = Godot panorama mapping used by game/shaders/sky_hdri.gdshader:
    u = atan2(d.x, d.z) / 2pi  (wrapped to 0..1),  v = acos(d.y) / pi   (v = 0 at the zenith, image top)
Energies follow Godot's convention: a white Lambert surface lit by a DirectionalLight of energy e (facing it)
outputs e; under a uniform sky of radiance L it outputs L.  =>  sun_energy = E_sun / pi.
"""
import bpy
import numpy as np
import os
import sys
import json
import math

CLAMP = 40.0       # sky shader clamp (radiance above this is treated as the disc)


def analyse(path):
    img = bpy.data.images.load(path)
    W, H = img.size
    px = np.empty(W * H * 4, dtype=np.float32)
    img.pixels.foreach_get(px)
    bpy.data.images.remove(img)
    rgb = px.reshape(H, W, 4)[::-1, :, :3].astype(np.float64)       # row 0 = top
    lum = rgb @ np.array([0.2126, 0.7152, 0.0722])
    v = (np.arange(H) + 0.5) / H
    u = (np.arange(W) + 0.5) / W
    phi = v * math.pi
    theta = u * 2 * math.pi
    sinp = np.sin(phi)
    d_omega = (2 * math.pi / W) * (math.pi / H) * sinp               # solid angle per pixel, per row
    dx = np.outer(sinp, np.sin(theta))
    dy = np.repeat(np.cos(phi)[:, None], W, axis=1)
    dz = np.outer(sinp, np.cos(theta))

    # sun = brightest pixel; disc = pixels above the clamp within 3 deg of it
    r, c = np.unravel_index(np.argmax(lum), lum.shape)
    sdir = np.array([dx[r, c], dy[r, c], dz[r, c]])
    cosang = dx * sdir[0] + dy * sdir[1] + dz * sdir[2]
    near = cosang > math.cos(math.radians(3.0))
    disc = near & (lum > CLAMP)
    w = d_omega[:, None] * np.ones((1, W))
    if disc.any():
        e_rgb = (rgb[disc] * w[disc][:, None]).sum(0)                   # irradiance normal to the sun
        # luminance-weighted centroid for a precise direction
        ww = (lum * w)[disc]
        sdir = np.array([(dx[disc] * ww).sum(), (dy[disc] * ww).sum(), (dz[disc] * ww).sum()])
        sdir /= np.linalg.norm(sdir)
    else:
        e_rgb = np.zeros(3)
    e_sun = float(e_rgb @ np.array([0.2126, 0.7152, 0.0722]))
    sun_color = (e_rgb / max(e_rgb.max(), 1e-9)).tolist() if e_sun > 0 else [1.0, 1.0, 1.0]

    # sky irradiance on a horizontal surface (upper hemisphere, disc clamped like the shader does)
    clamped = np.minimum(rgb, CLAMP)
    up = dy > 0
    cosw = (dy * w)
    e_sky_rgb = (clamped * (cosw * up)[:, :, None]).reshape(-1, 3).sum(0)
    e_sky = float(e_sky_rgb @ np.array([0.2126, 0.7152, 0.0722]))
    # average horizon colour (for fog) and zenith colour
    hz = (dy > 0.0) & (dy < 0.12)
    horizon = (clamped[hz]).mean(0).tolist()
    zen = dy > 0.85
    zenith = (clamped[zen]).mean(0).tolist()
    # what does the lower hemisphere contain?
    low = dy < -0.2
    lower_mean = float(lum[low].mean())
    return dict(
        sun_dir=[float(x) for x in sdir],
        sun_elevation_deg=float(math.degrees(math.asin(max(-1.0, min(1.0, sdir[1]))))),
        sun_azimuth_u=float(c / W),
        has_disc=bool(disc.any()),
        disc_pixels=int(disc.sum()),
        sun_energy=e_sun / math.pi,
        sun_color=sun_color,
        sky_irradiance=e_sky,
        sky_ambient_L=e_sky / math.pi,
        horizon_color=horizon,
        zenith_color=zenith,
        lower_hemisphere_mean_lum=lower_mean,
        max_lum=float(lum.max()),
        size=[W, H],
    )


def main():
    argv = sys.argv[sys.argv.index("--") + 1:]
    src, out = argv[0], argv[1]
    res = {}
    for f in sorted(os.listdir(src)):
        if f.lower().endswith(".hdr") or f.lower().endswith(".exr"):
            res[f] = analyse(os.path.join(src, f))
            q = res[f]
            print(f"[hdri] {f}: elev {q['sun_elevation_deg']:6.1f}  disc {q['has_disc']} ({q['disc_pixels']} px)  "
                  f"sun_E {q['sun_energy']:9.3f}  sky_L {q['sky_ambient_L']:8.4f}  lower {q['lower_hemisphere_mean_lum']:.4f}",
                  flush=True)
    with open(out, "w") as fh:
        json.dump(res, fh, indent=1)


main()
