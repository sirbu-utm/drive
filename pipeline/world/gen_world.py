"""DRIVE1 world generator (offline): heightmap, road network, terrain material map, vegetation.

    tools/venv/bin/python pipeline/world/gen_world.py [--size 4096] [--seed 7]

Outputs (game/assets/world/gen/, regenerated, not committed):
    height.r32          float32 N*N, metres, row = +Z (south), col = +X (east); pixel (c, r) = world (c - N/2, r - N/2)
    material.u8         uint8 N*N   terrain material id per pixel (see MATERIALS)
    material2.u8        uint8 N*N   secondary material id (overlay)
    blend.u8            uint8 N*N   overlay weight 0..255
    roads.json          road centrelines (resampled every 2 m, with heights), widths, kinds
    trees_<kind>.f32    float32 [x, z, yaw, scale] * n
    rocks.f32           float32 [x, z, yaw, scale] * n
    map_preview.png     hillshade + materials + roads (for review)
World units: metres, Godot axes (X east, Y up, Z south). Sea level = 0.
"""
import json
import math
import os
import sys
import time

import numpy as np
from scipy import ndimage
from scipy.spatial import cKDTree

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
OUT = os.path.join(ROOT, "game", "assets", "world", "gen")

MATERIALS = ["grass", "meadow", "rock", "scree", "dirt", "sand", "gravel", "forest"]
M = {k: i for i, k in enumerate(MATERIALS)}

ROAD_KINDS = {
    #            width  smooth_win  max_grade  mesh   surface
    "highway":  (14.0,   320.0,      0.05,      True,  "asphalt"),
    "country":  (9.0,    140.0,      0.08,      True,  "asphalt"),
    "mountain": (8.0,    50.0,       0.115,     True,  "asphalt"),
    "runway":   (45.0,   700.0,      0.008,     True,  "asphalt"),
    "taxi":     (14.0,   120.0,      0.04,      True,  "asphalt"),
    "dirt":     (6.5,    40.0,       0.16,      False, "dirt"),
}


CAMBER = {"country": 0.02, "highway": 0.02, "mountain": 0.025, "runway": 0.01, "taxi": 0.015, "dirt": 0.0}
# vertical-curve smoothing (gaussian sigma, metres) and design speed (m/s) for the comfort check
VCURVE = {"country": (34.0, 45.0), "highway": (50.0, 70.0), "mountain": (12.0, 24.0), "runway": (90.0, 85.0),
          "taxi": (16.0, 20.0), "dirt": (8.0, 18.0)}


def log(*a):
    print("[world]", *a, flush=True)


# ------------------------------------------------------------------------------------------------
# noise
# ------------------------------------------------------------------------------------------------
class Noise:
    def __init__(self, n, seed):
        self.n = n
        self.rng = np.random.default_rng(seed)
        ax = np.arange(n, dtype=np.float32)
        self.X, self.Z = np.meshgrid(ax - n / 2, ax - n / 2)       # world metres, X east, Z south

    def value(self, period, x=None, z=None, seed_off=0):
        """Smooth value noise in [-1, 1] with feature size `period` metres, sampled at (x, z) (default: grid)."""
        x = self.X if x is None else x
        z = self.Z if z is None else z
        g = int(self.n / period) + 4
        grid = np.random.default_rng(1000 + seed_off + int(period * 13)).uniform(-1, 1, (g, g)).astype(np.float32)
        cx = (x + self.n / 2) / period + 1.5
        cz = (z + self.n / 2) / period + 1.5
        return ndimage.map_coordinates(grid, [cz, cx], order=3, mode="wrap").astype(np.float32)

    def fbm(self, period, octaves, gain=0.5, lac=2.0, x=None, z=None, seed_off=0, ridged=False):
        amp, tot, norm, p = 1.0, 0.0, 0.0, period
        for o in range(octaves):
            v = self.value(p, x, z, seed_off + o * 101)
            if ridged:
                v = 1.0 - np.abs(v)
                v = v * v
            tot = tot + amp * v
            norm += amp
            amp *= gain
            p /= lac
        return tot / norm


def smoothstep(e0, e1, x):
    t = np.clip((x - e0) / (e1 - e0), 0.0, 1.0)
    return t * t * (3 - 2 * t)


# ------------------------------------------------------------------------------------------------
# terrain
# ------------------------------------------------------------------------------------------------
def make_terrain(nz):
    n = nz.n
    X, Z = nz.X, nz.Z
    u, v = X / (n / 2), Z / (n / 2)                        # -1..1
    # domain warp for organic coastlines / ridges
    wx = nz.fbm(900, 3, seed_off=11) * 160
    wz = nz.fbm(900, 3, seed_off=23) * 160
    Xw, Zw = X + wx, Z + wz
    uw, vw = Xw / (n / 2), Zw / (n / 2)

    # coast: sea in the south and the west, smooth corner
    d_south = 0.80 - vw                                 # >0 = land
    d_west = uw + 0.84
    k = 0.12
    d_coast = -k * np.log(np.exp(-d_south / k) + np.exp(-d_west / k))   # smooth min
    land = smoothstep(-0.02, 0.10, d_coast)

    # rolling interior hills
    hills = nz.fbm(700, 5, gain=0.5, x=Xw, z=Zw, seed_off=31) * 38 + 30
    detail = nz.fbm(120, 4, gain=0.5, seed_off=41) * 4.0
    # northern mountain range + eastern highlands (ridged)
    north = smoothstep(-0.35, -0.85, vw)
    east = smoothstep(0.62, 0.95, uw) * 0.55
    mtn_mask = np.maximum(north, east)
    ridges = nz.fbm(520, 6, gain=0.52, x=Xw, z=Zw, seed_off=51, ridged=True)
    mountains = mtn_mask * (60 + 380 * ridges * (0.55 + 0.45 * mtn_mask))
    # a natural col/valley along the mountain pass route so the road can climb at a sane grade
    route = resample(np.array(PASS_ROUTE, dtype=float), 4.0)
    dist, _ = cKDTree(route).query(np.column_stack([X.ravel(), Z.ravel()]), distance_upper_bound=900, workers=-1)
    dist = np.where(np.isfinite(dist), dist, 900).reshape(X.shape)
    saddle = np.exp(-(dist / 300.0) ** 2)
    mountains = mountains * (1 - 0.5 * saddle)
    # western plain (airfield) and southern lowlands flatter
    plain = smoothstep(-0.30, -0.55, u) * smoothstep(-0.55, -0.25, v) * smoothstep(0.75, 0.45, v)
    hills = hills * (1 - 0.8 * plain) + plain * 14 * 0.8

    h = hills + mountains + detail
    # coast profile: beaches then sea floor
    beach = smoothstep(0.0, 0.16, d_coast)
    h = h * beach + (1 - beach) * (2.0 * np.clip(d_coast / 0.16, 0, 1))
    h = np.where(d_coast < 0, -1.0 + d_coast * 160, h)                  # sea floor drops off
    h = h * (0.25 + 0.75 * land) + (1 - land) * np.minimum(h, 0.0)
    # thermal erosion (talus ~ 33 deg at 2 m cells) on a 2x downsampled copy, then add back fine detail
    h = erode(h, iters=28, talus=1.3, rate=0.35)
    return h.astype(np.float32), dict(d_coast=d_coast, plain=plain, mtn=mtn_mask)


def erode(h, iters, talus, rate):
    hs = ndimage.zoom(h, 0.5, order=1)
    for _ in range(iters):
        out = np.zeros_like(hs)
        for dx, dz in ((1, 0), (-1, 0), (0, 1), (0, -1)):
            nb = np.roll(np.roll(hs, dx, axis=1), dz, axis=0)
            diff = hs - nb - talus
            mv = np.where(diff > 0, diff * rate * 0.25, 0.0)
            out -= mv
            out += np.roll(np.roll(mv, -dx, axis=1), -dz, axis=0)
        hs = hs + out
    low = ndimage.zoom(ndimage.zoom(h, 0.5, order=1), 2.0, order=1)[: h.shape[0], : h.shape[1]]
    up = ndimage.zoom(hs, 2.0, order=1)[: h.shape[0], : h.shape[1]]
    return h + (up - low)


# ------------------------------------------------------------------------------------------------
# roads
# ------------------------------------------------------------------------------------------------
def catmull_rom(pts, closed, step=2.0):
    """Centripetal Catmull-Rom through pts (K,2), resampled every `step` metres."""
    P = np.asarray(pts, dtype=np.float64)
    if closed:
        P = np.vstack([P[-1], P, P[0], P[1]])
    else:
        P = np.vstack([2 * P[0] - P[1], P, 2 * P[-1] - P[-2]])
    out = []
    for i in range(1, len(P) - 2):
        p0, p1, p2, p3 = P[i - 1], P[i], P[i + 1], P[i + 2]

        def tj(ti, a, b):
            return ti + max(np.linalg.norm(b - a), 1e-6) ** 0.5
        t0 = 0.0
        t1 = tj(t0, p0, p1)
        t2 = tj(t1, p1, p2)
        t3 = tj(t2, p2, p3)
        seg = np.linalg.norm(p2 - p1)
        m = max(int(seg / 0.5), 2)
        for t in np.linspace(t1, t2, m, endpoint=False):
            a1 = (t1 - t) / (t1 - t0) * p0 + (t - t0) / (t1 - t0) * p1
            a2 = (t2 - t) / (t2 - t1) * p1 + (t - t1) / (t2 - t1) * p2
            a3 = (t3 - t) / (t3 - t2) * p2 + (t - t2) / (t3 - t2) * p3
            b1 = (t2 - t) / (t2 - t0) * a1 + (t - t0) / (t2 - t0) * a2
            b2 = (t3 - t) / (t3 - t1) * a2 + (t - t1) / (t3 - t1) * a3
            out.append((t2 - t) / (t2 - t1) * b1 + (t - t1) / (t2 - t1) * b2)
    if not closed:
        out.append(P[-2])
    else:
        out.append(out[0])
    return resample(np.array(out), step)


def resample(poly, step):
    d = np.r_[0, np.cumsum(np.linalg.norm(np.diff(poly, axis=0), axis=1))]
    s = np.arange(0, d[-1], step)
    if d[-1] - s[-1] > step * 0.3:
        s = np.r_[s, d[-1]]
    return np.stack([np.interp(s, d, poly[:, 0]), np.interp(s, d, poly[:, 1])], axis=1)


def serpentine(start, heading_deg, legs, leg_len, spacing, climb_dir_deg):
    """Switchback road: straight legs joined by 180 deg hairpins of radius spacing/2.
    Legs run along `heading`, successive legs are offset by `spacing` towards `climb_dir`."""
    hd = np.radians(heading_deg)
    cd = np.radians(climb_dir_deg)
    fwd = np.array([math.cos(hd), math.sin(hd)])
    up = np.array([math.cos(cd), math.sin(cd)])
    r = spacing / 2
    pts = [np.array(start, dtype=float)]
    p = np.array(start, dtype=float)
    d = fwd.copy()
    for i in range(legs):
        p = p + d * leg_len
        pts.append(p.copy())
        if i == legs - 1:
            break
        c = p + up * r
        a0 = math.atan2(p[1] - c[1], p[0] - c[0])
        # turn direction so that the arc bulges forward
        cross = d[0] * up[1] - d[1] * up[0]
        sgn = 1.0 if cross > 0 else -1.0
        for k in range(1, 9):
            a = a0 + sgn * math.pi * k / 8
            pts.append(c + r * np.array([math.cos(a), math.sin(a)]))
        p = c + up * r
        d = -d
    return pts


PASS_ROUTE = [(-20, -1000), (-60, -1150), (-40, -1420), (150, -1540), (450, -1610), (720, -1540),
              (920, -1390), (1020, -1180), (1060, -990)]


def road_network():
    """Control points in world metres (x east, z south)."""
    ring = [(-1450, 1350), (-1120, 1480), (-760, 1500), (-420, 1440), (-80, 1515), (280, 1470), (640, 1505),
            (950, 1420), (1180, 1250), (1290, 1000), (1305, 700), (1320, 0), (1335, -620), (1270, -880),
            (1060, -990), (820, -905), (600, -1020), (370, -950), (160, -1050), (-20, -1000), (-260, -1060),
            (-520, -940), (-770, -1010), (-1010, -880), (-1250, -700), (-1360, -440), (-1430, -150),
            (-1375, 140), (-1470, 430), (-1505, 790), (-1510, 1110)]
    serp = [tuple(p) for p in serpentine((-60, -1120), 180, 6, 240, 68, -90)]
    mpass = [(-20, -1000), (-50, -1080)] + serp + [(120, -1520), (450, -1610), (720, -1540),
                                                   (920, -1390), (1020, -1180), (1060, -990)]
    runway = [(-1080, -380), (-1080, 1180)]
    taxi = [(-1375, 140), (-1250, 160), (-1110, 165)]
    dirt = [(-380, 120), (-120, -60), (220, 20), (420, 300), (300, 640), (-40, 760), (-360, 600), (-520, 360)]
    return [
        dict(name="ring", kind="country", pts=ring, closed=True),
        dict(name="mountain_pass", kind="mountain", pts=mpass, closed=False, join=["ring", "ring"]),
        dict(name="runway", kind="runway", pts=runway, closed=False, linear=True),
        dict(name="taxiway", kind="taxi", pts=taxi, closed=False, join=["ring", None]),
        dict(name="dirt_loop", kind="dirt", pts=dirt, closed=True),
    ], dict(highway=((1290, 1000), (1335, -620)))


def bilinear(h, x, z):
    n = h.shape[0]
    c = np.clip(x + n / 2, 0, n - 1.001)
    r = np.clip(z + n / 2, 0, n - 1.001)
    return ndimage.map_coordinates(h, [r, c], order=1)


def profile(h, xz, kind, closed, pins):
    width, win, grade, _, _ = ROAD_KINDS[kind]
    raw = bilinear(h, xz[:, 0], xz[:, 1]).astype(np.float64)
    raw = np.maximum(raw, 2.5)                         # stay above the beach line
    step = 2.0
    k = max(int(win / step) | 1, 3)
    mode = "wrap" if closed else "nearest"
    sm = ndimage.uniform_filter1d(raw, k, mode=mode)
    sm = ndimage.uniform_filter1d(sm, k, mode=mode)
    for idx, val in pins:                               # pinned junction heights, blended over 80 m
        span = int(80 / step)
        for j in range(-span, span + 1):
            q = idx + j
            if closed:
                q %= len(sm)
            elif q < 0 or q >= len(sm):
                continue
            w = 0.5 + 0.5 * math.cos(math.pi * abs(j) / span)
            sm[q] = sm[q] * (1 - w) + val * w
    # feasibility envelope from the pinned heights (a road can't climb faster than `grade` away from a pin)
    dmax = grade * step
    idx_all = np.arange(len(sm))
    for idx, val in pins:
        dd = np.abs(idx_all - idx) * step
        if closed:
            dd = np.minimum(dd, len(sm) * step - dd)
        sm = np.clip(sm, val - grade * dd, val + grade * dd)
    # grade limit (forward + backward passes)
    for _ in range(4):
        for i in range(1, len(sm)):
            sm[i] = np.clip(sm[i], sm[i - 1] - dmax, sm[i - 1] + dmax)
        for i in range(len(sm) - 2, -1, -1):
            sm[i] = np.clip(sm[i], sm[i + 1] - dmax, sm[i + 1] + dmax)
        for idx, val in pins:
            sm[idx] = val
    # vertical curves: gaussian smoothing, then re-impose pins with a smooth (raised-cosine) correction
    sigma = VCURVE[kind][0] / step
    for it in range(3):
        sm = ndimage.gaussian_filter1d(sm, sigma * (1.0 if it < 2 else 0.5), mode=mode)
        for idx, val in pins:
            delta = val - sm[idx]
            span = int(max(60.0, 3 * VCURVE[kind][0]) / step)
            for j in range(-span, span + 1):
                q = idx + j
                if closed:
                    q %= len(sm)
                elif q < 0 or q >= len(sm):
                    continue
                sm[q] += delta * (0.5 + 0.5 * math.cos(math.pi * abs(j) / span))
    return sm


def comfort(hh, kind, closed):
    """Max vertical acceleration (g) at design speed implied by the profile curvature."""
    v = VCURVE[kind][1]
    d2 = np.abs(np.diff(np.r_[hh[-2:-1], hh, hh[1:2]] if closed else hh, 2)) / 4.0   # 1/m (2 m samples)
    return float((v * v * d2).max() / 9.81), float(d2.max())


def build_roads(h, nz):
    roads, extra = road_network()
    done = {}
    for r in roads:
        if r.get("linear"):
            xz = resample(np.array(r["pts"], dtype=float), 2.0)
        else:
            xz = catmull_rom(r["pts"], r["closed"])
        joins = r.get("join", [None, None])
        edge_pin = {}
        for which, target in (("start", joins[0]), ("end", joins[1])):
            if not (target and target in done):
                continue
            t = done[target]
            tree = cKDTree(t["xz"])
            half_t = ROAD_KINDS[t["kind"]][0] / 2
            dist, jj = tree.query(xz)
            inside = dist < half_t - 0.5
            if which == "start":
                k0 = int(np.argmax(~inside)) if inside[0] else 0
                xz = xz[k0:]
                jt = int(jj[k0])
            else:
                rev = inside[::-1]
                k1 = len(xz) - (int(np.argmax(~rev)) if rev[0] else 0)
                xz = xz[:k1]
                jt = int(jj[k1 - 1])
            edge_pin[which] = float(t["h"][jt]) - CAMBER[t["kind"]] * half_t - 0.015
        pins = []
        if "start" in edge_pin:
            pins.append((0, edge_pin["start"]))
        if "end" in edge_pin:
            pins.append((len(xz) - 1, edge_pin["end"]))
        hh = profile(h, xz, r["kind"], r["closed"], pins)
        r["xz"], r["h"] = xz, hh
        done[r["name"]] = r
        L = np.linalg.norm(np.diff(xz, axis=0), axis=1).sum()
        gr = np.abs(np.diff(hh)) / 2.0
        terr = bilinear(h, xz[:, 0], xz[:, 1])
        r["cut"] = float((terr - hh).max())
        r["fill"] = float((hh - terr).max())
        g_max, d2 = comfort(hh, r["kind"], r["closed"])
        log(f"      cut max {r['cut']:6.1f} m   fill max {r['fill']:6.1f} m   vertical {g_max:4.2f} g @ "
            f"{VCURVE[r['kind']][1]:.0f} m/s (max d2h {d2 * 4:.3f} m per 2 m^2)")
        log(f"road {r['name']:14s} {r['kind']:8s} length {L / 1000:6.2f} km  h {hh.min():6.1f}..{hh.max():6.1f}  "
            f"max grade {gr.max() * 100:4.1f}%")
    # mark the long straight of the ring as highway width
    ring = done["ring"]
    a, b = extra["highway"]
    tree = cKDTree(ring["xz"])
    ia, ib = tree.query(a)[1], tree.query(b)[1]
    w = np.full(len(ring["xz"]), ROAD_KINDS["country"][0])
    lo, hi = sorted((ia, ib))
    w[lo:hi + 1] = ROAD_KINDS["highway"][0]
    # taper over 60 m
    for i in range(1, 31):
        f = i / 31
        if lo - i >= 0:
            w[lo - i] = ROAD_KINDS["highway"][0] * (1 - f) + ROAD_KINDS["country"][0] * f
        if hi + i < len(w):
            w[hi + i] = ROAD_KINDS["highway"][0] * (1 - f) + ROAD_KINDS["country"][0] * f
    ring["width"] = w
    for r in roads:
        if "width" not in r:
            r["width"] = np.full(len(r["xz"]), ROAD_KINDS[r["kind"]][0])
    return roads


def carve(h, roads):
    """Flatten terrain under roads and blend embankments. Returns new h and per-pixel road info."""
    n = h.shape[0]
    pts, hs, ws, rid, paved, cams = [], [], [], [], [], []
    for i, r in enumerate(roads):
        xz = resample(np.column_stack([r["xz"]]), 1.0) if False else r["xz"]
        # densify to 1 m for the KD-tree
        d = np.r_[0, np.cumsum(np.linalg.norm(np.diff(xz, axis=0), axis=1))]
        s = np.arange(0, d[-1], 1.0)
        X = np.interp(s, d, xz[:, 0])
        Z = np.interp(s, d, xz[:, 1])
        pts.append(np.column_stack([X, Z]))
        hs.append(np.interp(s, d, r["h"]))
        ws.append(np.interp(s, d, r["width"]))
        rid.append(np.full(len(s), i))
        paved.append(np.full(len(s), ROAD_KINDS[r["kind"]][3]))
        cams.append(np.full(len(s), CAMBER[r["kind"]]))
    pts, hs, ws, rid, paved, cams = map(np.concatenate, (pts, hs, ws, rid, paved, cams))
    tree = cKDTree(pts)
    reach = 90.0
    # query only pixels within the bounding boxes of the roads (all of them, chunked)
    road_d = np.full(h.shape, np.inf, dtype=np.float32)
    road_h = np.zeros(h.shape, dtype=np.float32)
    road_w = np.zeros(h.shape, dtype=np.float32)
    road_paved = np.zeros(h.shape, dtype=bool)
    road_id = np.full(h.shape, -1, dtype=np.int16)
    road_cam = np.zeros(h.shape, dtype=np.float32)
    xs = np.arange(n) - n / 2
    for r0 in range(0, n, 256):
        Zr = (np.arange(r0, min(r0 + 256, n)) - n / 2)
        XX, ZZ = np.meshgrid(xs, Zr)
        q = np.column_stack([XX.ravel(), ZZ.ravel()])
        dist, j = tree.query(q, distance_upper_bound=reach, workers=-1)
        ok = np.isfinite(dist)
        jj = np.where(ok, j, 0)
        sl = slice(r0, r0 + len(Zr))
        road_d[sl] = np.where(ok, dist, np.inf).reshape(XX.shape)
        road_h[sl] = hs[jj].reshape(XX.shape)
        road_w[sl] = ws[jj].reshape(XX.shape)
        road_paved[sl] = (paved[jj] & ok).reshape(XX.shape)
        road_id[sl] = np.where(ok, rid[jj], -1).reshape(XX.shape)
        road_cam[sl] = np.where(ok, cams[jj], 0.0).reshape(XX.shape)
    half = road_w / 2
    d = road_d
    h0 = h.copy()
    core = d <= half + 0.6
    # under the asphalt: follow the road's cross-fall, 12 cm below the surface (no poke-through at the edges)
    target_core = np.where(road_paved, road_h - road_cam * np.minimum(d, half) - 0.12, road_h)
    # shoulder: just below the asphalt edge so leaving the road is a small step down, never a lip up
    shoulder_h = np.where(road_paved, road_h - road_cam * half - 0.03, road_h - 0.04)
    bank_w = np.clip(np.abs(h0 - road_h) * 1.8, 8.0, 140.0)
    t = smoothstep(0.0, 1.0, (d - (half + 3.0)) / bank_w)
    hb = shoulder_h * (1 - t) + h0 * t
    out = np.where(d <= half + 3.0, shoulder_h, np.where(np.isfinite(d), hb, h0))
    out = np.where(core, target_core, out)
    # smooth the embankment band (removes stair-stepping where nearest-sample heights jump)
    band_mask = np.isfinite(d) & (d > half + 3.5)
    sm = ndimage.gaussian_filter(out, 2.0)
    wgt = smoothstep(half + 3.5, half + 9.0, d) * band_mask
    out = np.where(band_mask, out * (1 - wgt) + sm * wgt, out)
    return out.astype(np.float32), dict(d=road_d, half=half, paved=road_paved, id=road_id, h=road_h)


# ------------------------------------------------------------------------------------------------
# materials + vegetation
# ------------------------------------------------------------------------------------------------
def slope_deg(h):
    gz, gx = np.gradient(h)
    return np.degrees(np.arctan(np.hypot(gx, gz)))


def materials(h, nz, info, road):
    """Per-pixel base/overlay material + blend. Soft, multi-scale transitions (no camo blobs)."""
    s = slope_deg(h)
    n_big = nz.fbm(420, 4, seed_off=71)
    n_mid = nz.fbm(90, 4, seed_off=81)
    n_fine = nz.fbm(22, 3, seed_off=83)
    forest = smoothstep(-0.05, 0.25, nz.fbm(600, 4, seed_off=91) + 0.12 * n_mid)
    alt = h
    base = np.full(h.shape, M["grass"], dtype=np.uint8)
    over = np.full(h.shape, M["meadow"], dtype=np.uint8)
    # meadow variation everywhere (soft, multi-scale)
    blend = np.clip(0.45 + 0.55 * n_big + 0.35 * n_mid + 0.15 * n_fine, 0, 0.85)
    # forest floor under the woods
    fo = smoothstep(0.35, 0.75, forest + 0.15 * n_mid)
    over = np.where(fo > 0.15, M["forest"], over)
    blend = np.where(fo > 0.15, np.clip(fo * 0.95, 0, 1), blend)
    # high altitude: scree with grass pockets
    hi = smoothstep(150, 240, alt + 35 * n_mid)
    base = np.where(hi > 0.5, M["scree"], base)
    over = np.where(hi > 0.5, M["grass"], over)
    blend = np.where(hi > 0.5, np.clip((1 - hi) * 1.6 + 0.3 * n_mid, 0, 1), blend)
    # steep -> rock (overlay strength by slope)
    st = smoothstep(24, 38, s + 5 * n_mid + 2 * n_fine)
    over = np.where(st > 0.04, M["rock"], over)
    blend = np.where(st > 0.04, st, blend)
    # beaches
    beach = smoothstep(4.5, 1.8, alt + 1.3 * n_mid) * (info["d_coast"] < 0.3)
    base = np.where(beach > 0.5, M["sand"], base)
    over = np.where(beach > 0.5, M["grass"], over)
    blend = np.where(beach > 0.5, np.clip((1 - beach) * 1.5, 0, 1), blend)
    # paved roads: gravel under the asphalt and a narrow gravel shoulder fading into grass
    d, half = road["d"], road["half"]
    under = (d <= half + 0.3) & road["paved"]
    sh = (d > half + 0.3) & (d < half + 2.4) & road["paved"]
    base = np.where(under | sh, M["gravel"], base)
    over = np.where(sh, M["grass"], over)
    blend = np.where(under, 0, np.where(sh, (smoothstep(half + 0.8, half + 2.4, d) * 255 / 255.0), blend))
    # dirt roads: dirt with a grassy crown
    dr = (d <= half + 1.2) & ~road["paved"] & np.isfinite(d)
    base = np.where(dr, M["dirt"], base)
    over = np.where(dr, M["grass"], over)
    crown = smoothstep(0.9, 0.0, d) * 0.55 + smoothstep(half - 0.4, half + 1.2, d)
    blend = np.where(dr, np.clip(crown + 0.15 * n_fine, 0, 1), blend)
    return base, over, (np.clip(blend, 0, 1) * 255).astype(np.uint8), forest, s


def scatter(nz, h, forest, s, road, info, cell, kinds, seed):
    """Jittered-grid scatter. kinds: list of (name, weight_fn) -> returns dict name -> (k,4) [x,z,yaw,scale]."""
    rng = np.random.default_rng(seed)
    n = h.shape[0]
    g = np.arange(-n / 2 + cell / 2, n / 2, cell)
    GX, GZ = np.meshgrid(g, g)
    X = (GX + rng.uniform(-0.45, 0.45, GX.shape) * cell).ravel()
    Z = (GZ + rng.uniform(-0.45, 0.45, GZ.shape) * cell).ravel()
    ci = np.clip((X + n / 2).astype(int), 0, n - 1)
    ri = np.clip((Z + n / 2).astype(int), 0, n - 1)
    hh = h[ri, ci]
    ss = s[ri, ci]
    ff = forest[ri, ci]
    rd = road["d"][ri, ci] - road["half"][ri, ci]
    plain = info["plain"][ri, ci]
    roll = rng.uniform(0, 1, X.shape)
    out = {}
    acc = 0.0
    for name, fn in kinds:
        p = fn(hh, ss, ff, rd, plain)
        sel = (roll >= acc) & (roll < acc + p)
        acc_vec = p
        out[name] = np.column_stack([X[sel], Z[sel], rng.uniform(0, 2 * math.pi, sel.sum()),
                                     rng.uniform(0.75, 1.3, sel.sum())]).astype(np.float32)
        roll = np.where(sel, 2.0, roll - p)            # remove used samples; shift the rest
    return out


# ------------------------------------------------------------------------------------------------
# preview
# ------------------------------------------------------------------------------------------------
def preview(h, base, over, blend, roads, trees, path, scale=4):
    from PIL import Image
    hs = h[::scale, ::scale]
    gz, gx = np.gradient(hs, scale)
    light = np.array([-0.6, 0.7, -0.4])
    light /= np.linalg.norm(light)
    nrm = np.dstack([-gx, np.ones_like(hs), -gz])
    nrm /= np.linalg.norm(nrm, axis=2, keepdims=True)
    shade = np.clip(nrm @ light, 0, 1) * 0.75 + 0.25
    pal = np.array([[70, 110, 45], [120, 135, 70], [105, 112, 100], [140, 135, 125], [160, 125, 85],
                    [205, 190, 150], [150, 148, 142], [85, 70, 45]], dtype=np.float32)
    b = base[::scale, ::scale]
    o = over[::scale, ::scale]
    w = blend[::scale, ::scale, None] / 255.0
    col = pal[b] * (1 - w) + pal[o] * w
    col = col * shade[..., None]
    sea = hs < 0
    col[sea] = np.array([30, 70, 110]) * (0.7 + 0.3 * np.clip(1 + hs[sea] / 40, 0, 1))[:, None]
    img = Image.fromarray(np.clip(col, 0, 255).astype(np.uint8))
    from PIL import ImageDraw
    dr = ImageDraw.Draw(img)
    N = h.shape[0]
    colors = {"country": (240, 240, 240), "mountain": (255, 200, 60), "runway": (60, 60, 60),
              "taxi": (90, 90, 90), "dirt": (170, 110, 50), "highway": (255, 255, 255)}
    for r in roads:
        p = [((x + N / 2) / scale, (z + N / 2) / scale) for x, z in r["xz"]]
        wid = max(1, int(r["width"].mean() / scale))
        dr.line(p, fill=colors[r["kind"]], width=wid)
    for name, arr in trees.items():
        c = (20, 60, 20) if "fir" in name else (40, 90, 30)
        for x, z, *_ in arr[:: max(1, len(arr) // 6000)]:
            px, pz = (x + N / 2) / scale, (z + N / 2) / scale
            dr.point((px, pz), fill=c)
    img.save(path)


# ------------------------------------------------------------------------------------------------
def main():
    args = sys.argv[1:]
    n = int(args[args.index("--size") + 1]) if "--size" in args else 4096
    seed = int(args[args.index("--seed") + 1]) if "--seed" in args else 7
    os.makedirs(OUT, exist_ok=True)
    t0 = time.time()
    nz = Noise(n, seed)
    h, info = make_terrain(nz)
    log(f"terrain {n}x{n}: {h.min():.1f}..{h.max():.1f} m  ({time.time() - t0:.1f}s)")
    roads = build_roads(h, nz)
    h, road = carve(h, roads)
    log(f"carved ({time.time() - t0:.1f}s)")
    base, over, blend, forest, s = materials(h, nz, info, road)
    log(f"materials ({time.time() - t0:.1f}s)")

    def w_fir(hh, ss, ff, rd, plain):
        return ff ** 1.4 * smoothstep(60, 130, hh) * smoothstep(300, 230, hh) * smoothstep(34, 22, ss) * \
            smoothstep(4, 9, rd) * 0.95

    def w_broad(hh, ss, ff, rd, plain):
        return ff ** 1.6 * smoothstep(4, 10, hh) * smoothstep(150, 90, hh) * smoothstep(30, 18, ss) * \
            smoothstep(4, 9, rd) * (1 - plain) * 0.9

    def w_sapling(hh, ss, ff, rd, plain):
        return (0.08 + 0.25 * ff) * smoothstep(5, 12, hh) * smoothstep(30, 20, ss) * smoothstep(3, 6, rd) * \
            (1 - 0.8 * plain) * 0.4

    trees = scatter(nz, h, forest, s, road, info, 6.5,
                    [("fir", w_fir), ("broadleaf", w_broad), ("sapling", w_sapling)], seed + 1)

    def w_rock(hh, ss, ff, rd, plain):
        return smoothstep(18, 35, ss) * smoothstep(5, 9, rd) * 0.08 + smoothstep(3, 6, rd) * 0.004

    rocks = scatter(nz, h, forest, s, road, info, 14.0, [("rocks", w_rock)], seed + 2)["rocks"]
    for k, v in trees.items():
        log(f"trees {k}: {len(v)}")
    log(f"rocks: {len(rocks)}")

    h.astype(np.float32).tofile(os.path.join(OUT, "height.r32"))
    base.tofile(os.path.join(OUT, "material.u8"))
    over.tofile(os.path.join(OUT, "material2.u8"))
    blend.tofile(os.path.join(OUT, "blend.u8"))
    # Terrain3D control map: base<<27 | overlay<<22 | blend<<14 (bit pattern stored in a float32 image)
    ctrl = (base.astype(np.uint32) << 27) | (over.astype(np.uint32) << 22) | (blend.astype(np.uint32) << 14)
    ctrl.astype("<u4").tofile(os.path.join(OUT, "control.r32"))
    for k, v in trees.items():
        v.tofile(os.path.join(OUT, f"trees_{k}.f32"))
    rocks.tofile(os.path.join(OUT, "rocks.f32"))
    meta = dict(size=n, origin=[-n / 2, -n / 2], materials=MATERIALS, sea_level=0.0, seed=seed,
                roads=[dict(name=r["name"], kind=r["kind"], closed=r["closed"], paved=ROAD_KINDS[r["kind"]][3],
                            surface=ROAD_KINDS[r["kind"]][4],
                            points=[[round(float(x), 3), round(float(y), 3), round(float(z), 3)]
                                    for (x, z), y in zip(r["xz"], r["h"])],
                            width=[round(float(w), 2) for w in r["width"]]) for r in roads])
    with open(os.path.join(OUT, "roads.json"), "w") as f:
        json.dump(meta, f)
    preview(h, base, over, blend, roads, trees, os.path.join(OUT, "map_preview.png"))
    log(f"done ({time.time() - t0:.1f}s) -> {OUT}")


if __name__ == "__main__":
    main()
