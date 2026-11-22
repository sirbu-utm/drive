#!/usr/bin/env python3
"""Offline synthesis of all DRIVE1 car sounds (numpy only). Run with tools/venv/bin/python.

    tools/venv/bin/python scripts/audio/synth_audio.py [--out game/assets/audio] [--only engine|fx] [--spectrograms docs/shots/phase5]

Engine model (5.0 l naturally aspirated cross-plane V8, firing order 1-8-4-3-6-5-7-2, idle 1000 -> limiter 9000 rpm):
  * 8 firing events per 720 degrees, each with its own amplitude/timing jitter; the banks are L R R L R L L R,
    so each exhaust bank sees an uneven pulse train (the typical V8 "burble").
  * Each bank has its own exhaust: pipe resonance (feedback comb with an open-end reflection), muffler / body
    resonances, rpm dependent low-pass, radiation tilt, soft clipping for the high rpm rasp.
  * Intake: broad pulses at the firing frequency + noise modulated by the pulses (induction roar), scaled by load.
  * Mechanical: valvetrain ticks, combustion noise, bearing/gear whine is a separate layer.
  * Everything is built on a circular buffer and filtered in the frequency domain, so every loop is seamless.
Loops are written with a 'smpl' chunk (loop points) so Godot's WAV importer loops them.
"""
import argparse
import json
import os
import struct
import sys
import numpy as np

FS = 44100
RNG_SEED = 20261121

# ------------------------------------------------------------------------------------------------------
# helpers
# ------------------------------------------------------------------------------------------------------

def write_wav(path, x, fs=FS, loop=False, peak=0.97):
    x = np.asarray(x, dtype=np.float64)
    m = np.max(np.abs(x)) + 1e-12
    if m > peak:
        x = x * (peak / m)
    pcm = np.int16(np.clip(x, -1.0, 1.0) * 32767.0)
    data = pcm.tobytes()
    fmt = struct.pack("<HHIIHH", 1, 1, fs, fs * 2, 2, 16)
    chunks = b"fmt " + struct.pack("<I", len(fmt)) + fmt
    chunks += b"data" + struct.pack("<I", len(data)) + data
    if len(data) % 2:
        chunks += b"\0"
    if loop:
        # one forward loop over the whole file
        smpl = struct.pack("<IIIIIIIII", 0, 0, int(1e9 / fs), 60, 0, 0, 0, 1, 0)
        smpl += struct.pack("<IIIIII", 0, 0, 0, len(pcm) - 1, 0, 0)
        chunks += b"smpl" + struct.pack("<I", len(smpl)) + smpl
    riff = b"RIFF" + struct.pack("<I", 4 + len(chunks)) + b"WAVE" + chunks
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as f:
        f.write(riff)


def rfreqs(n):
    return np.fft.rfftfreq(n, 1.0 / FS)


def fdomain(x, H):
    """circular filtering: x (time) * H (rfft-domain transfer function)"""
    return np.fft.irfft(np.fft.rfft(x) * H, n=len(x))


def lowpass_H(f, fc, order=2):
    return 1.0 / np.sqrt(1.0 + (f / fc) ** (2 * order))


def highpass_H(f, fc, order=2):
    r = (f / fc) ** (2 * order)
    return np.sqrt(r / (1.0 + r))


def bandpass_H(f, f0, q):
    # 2nd order bandpass magnitude+phase-free (zero-phase), gain 1 at f0
    x = (f / f0 - f0 / np.maximum(f, 1e-9)) * q
    return 1.0 / np.sqrt(1.0 + x * x)


def peak_H(f, f0, gain_db, q):
    g = 10 ** (gain_db / 20.0)
    bw = bandpass_H(f, f0, q)
    return 1.0 + (g - 1.0) * bw


def shelf_low_H(f, fc, gain_db):
    g = 10 ** (gain_db / 20.0)
    return 1.0 + (g - 1.0) / (1.0 + (f / fc) ** 2)


def colored_noise(n, rng, beta=0.0, lo=20.0, hi=20000.0):
    """periodic noise with power ~ 1/f^beta, band limited"""
    spec = rng.normal(size=n // 2 + 1) + 1j * rng.normal(size=n // 2 + 1)
    f = rfreqs(n)
    f[0] = 1.0
    spec *= f ** (-beta / 2.0)
    spec[(f < lo) | (f > hi)] = 0
    spec[0] = 0
    x = np.fft.irfft(spec, n=n)
    return x / (np.std(x) + 1e-12)


def pulse_kernel(width_s, rise_s, fs=FS):
    n = int(max(8, width_s * fs * 6))
    t = np.arange(n) / fs
    k = (1 - np.exp(-t / rise_s)) * np.exp(-t / width_s)
    return k / np.sum(k)


def add_pulses(buf, positions, amps, kernel):
    """add kernel at fractional positions (circular), linear interpolation"""
    n = len(buf)
    L = len(kernel)
    for p, a in zip(positions, amps):
        i = int(np.floor(p))
        fr = p - i
        idx = (np.arange(L) + i) % n
        buf[idx] += a * kernel * (1.0 - fr)
        idx2 = (np.arange(L) + i + 1) % n
        buf[idx2] += a * kernel * fr


# ------------------------------------------------------------------------------------------------------
# engine
# ------------------------------------------------------------------------------------------------------
FIRING_ORDER = [1, 8, 4, 3, 6, 5, 7, 2]
BANK = {1: 0, 3: 0, 5: 0, 7: 0, 2: 1, 4: 1, 6: 1, 8: 1}
# per cylinder level / intake runner differences (small, fixed)
CYL_GAIN = {1: 1.00, 8: 0.93, 4: 1.06, 3: 0.97, 6: 1.04, 5: 0.95, 7: 1.02, 2: 0.99}


def engine_loop(rpm, load, seed, min_dur=2.2, name=""):
    """one seamless loop of the engine at `rpm`; load 0..1 (1 = wide open throttle, 0.05 = overrun)."""
    rng = np.random.default_rng(seed)
    cyc_T = 120.0 / rpm
    K = max(2, int(round(min_dur / cyc_T)))
    N = int(round(K * cyc_T * FS))
    eff_rpm = K * 120.0 / (N / FS)
    f = rfreqs(N)
    ev_T = N / (8.0 * K)                          # samples between firing events (even firing: 90 deg crank)
    rough = 0.05 + 0.55 * np.exp(-(rpm - 1000.0) / 900.0)       # irregularity: large at idle
    rough = rough * (0.6 + 0.8 * (1.0 - load))                  # overrun is lumpier
    # ---- exhaust pulses per bank
    bank_buf = [np.zeros(N), np.zeros(N)]
    intake_buf = np.zeros(N)
    cam_buf = np.zeros(N)
    comb_noise_env = np.zeros(N)
    base_amp = 0.25 + 0.85 * load
    for cyc in range(K):
        cyc_scale = 1.0 + rough * 0.45 * rng.normal()           # whole-cycle strength variation
        for e, cyl in enumerate(FIRING_ORDER):
            idx = cyc * 8 + e
            pos = (idx * ev_T + rng.normal() * ev_T * 0.012 * (1 + 2 * rough)) % N
            a = CYL_GAIN[cyl] * base_amp * (cyc_scale + rough * 0.6 * rng.normal())
            if rough > 0.3 and rng.random() < 0.04 * rough:      # occasional weak / lumpy firing at idle
                a *= 0.35
            bank_buf[BANK[cyl]][int(pos) % N] += 0.0             # (touch for clarity)
            add_pulses(bank_buf[BANK[cyl]], [pos], [a], pulse_kernel(0.00022 + 0.00035 * (1 - load), 0.00006))
            # intake: broader pulse, strongest with open throttle
            add_pulses(intake_buf, [pos + 0.12 * ev_T], [CYL_GAIN[cyl] * (0.12 + 0.95 * load ** 1.5)], pulse_kernel(0.0009 * (1 + 3500.0 / (rpm + 800.0) * 0.1), 0.0003))
            # valvetrain tick (one per cylinder per cycle)
            cam_buf[int(pos + 0.35 * ev_T) % N] += 0.3 + 0.2 * rng.random()
            comb_noise_env[int(pos) % N] += a
    # ---- exhaust system per bank
    out = np.zeros(N)
    for b in range(2):
        x = bank_buf[b]
        L1 = 0.80 + 0.12 * b                       # primary pipe length (m), slightly different per bank
        L2 = 1.45 + 0.10 * b                       # collector + muffler
        tau1 = 2 * L1 / 343.0
        tau2 = 2 * L2 / 343.0
        w = 2 * np.pi * f
        A = 1.0 / (1.0 + 1j * f / 2800.0)           # damping of the reflection
        R1 = 0.58 + 0.10 * load
        R2 = 0.40
        H = 1.0 / (1.0 + R1 * A * np.exp(-1j * w * tau1)) / (1.0 + R2 * A * A * np.exp(-1j * w * tau2))
        H = H * lowpass_H(f, 850.0 + 0.17 * rpm + 650.0 * load, 2)
        H = H * highpass_H(f, 38.0, 2)
        # radiation tilt: +3 dB/oct up to ~ 700 Hz
        H = H * np.sqrt(1.0 + (f / 700.0) ** 2) / np.sqrt(1.0 + (f / 4500.0) ** 2) * 0.6
        out += fdomain(x, H)
    # body / muffler resonances (shared)
    Hb = (peak_H(f, 95.0, 5.5, 1.0) * peak_H(f, 160.0, 3.0, 1.4) * peak_H(f, 310.0, 2.5, 1.2) *
          peak_H(f, 820.0, 2.5, 1.4) * peak_H(f, 1900.0, 2.0, 1.6) * shelf_low_H(f, 120.0, 3.0))
    out = fdomain(out, Hb)
    # soft clip: rasp at load
    drive = 1.0 + 2.2 * load * min(1.0, rpm / 6000.0)
    s = np.std(out) + 1e-9
    out = np.tanh(drive * out / (2.0 * s)) * 2.0 * s / drive
    out = fdomain(out, lowpass_H(f, 3200.0 + 0.25 * rpm, 2))
    out = out / (np.std(out) + 1e-9) * 0.30 * (0.55 + 0.65 * load)
    # ---- intake
    ik = fdomain(intake_buf, lowpass_H(f, 900.0 + 0.45 * rpm, 2) * highpass_H(f, 60.0, 2))
    ik = ik / (np.std(ik) + 1e-9)
    roar = colored_noise(N, rng, beta=1.0, lo=120.0, hi=2500.0)
    env = np.clip(fdomain(intake_buf, lowpass_H(f, 600.0, 2)), 0, None)
    env = env / (np.max(env) + 1e-9)
    ik = ik * 0.10 * (0.18 + 0.95 * load ** 1.4) + roar * env * 0.13 * load ** 2.0 * min(1.0, rpm / 3500.0)
    # ---- mechanical
    ticks = fdomain(cam_buf, bandpass_H(f, 3200.0, 1.2))
    ticks = ticks / (np.std(ticks) + 1e-9) * 0.020 * (0.5 + rpm / 9000.0)
    comb = fdomain(comb_noise_env, bandpass_H(f, 1800.0, 0.9) * lowpass_H(f, 5000.0, 2))
    comb = comb / (np.std(comb) + 1e-9) * 0.045 * (0.2 + 0.8 * load) * (0.4 + rpm / 9000.0)
    hiss = colored_noise(N, rng, beta=0.6, lo=800.0, hi=9000.0) * 0.010 * (0.4 + 0.6 * load) * min(1.0, rpm / 4000.0)
    sub = np.zeros(N)
    # sub-harmonic engine rumble at 0.5 order and 1 order (crank / cycle irregularity)
    t = np.arange(N) / FS
    for order, g in ((0.5, 0.05), (1.0, 0.035), (2.0, 0.06)):
        ph = rng.uniform(0, 2 * np.pi)
        fr = order * eff_rpm / 60.0
        sub += g * np.sin(2 * np.pi * fr * t + ph) * (1.0 + 0.25 * rng.normal())
    sub *= (0.5 + 0.5 * load) * np.exp(-max(0.0, rpm - 2500) / 6000.0)
    x = out + ik + ticks + comb + hiss + sub
    # overall level: engines are louder when revving (≈ +10 dB idle -> limiter)
    level = 0.28 + 0.72 * (rpm / 9000.0) ** 0.55
    x = x * level
    return x, eff_rpm


RPM_POINTS = [1000, 1900, 3000, 4200, 5400, 6600, 7800, 9000]


def make_engine(out_dir, report):
    meta = {"loops": []}
    allx = []
    jobs = []
    for i, rpm in enumerate(RPM_POINTS):
        for load_name, load in (("on", 1.0), ("off", 0.05)):
            x, eff = engine_loop(rpm, load, RNG_SEED + 31 * i + (7 if load_name == "off" else 0),
                                 min_dur=2.4 if rpm < 2500 else 2.0)
            jobs.append((rpm, load_name, x, eff))
            allx.append(x)
    gmax = max(np.max(np.abs(x)) for x in allx)
    gain = 0.80 / gmax
    for rpm, load_name, x, eff in jobs:
        name = f"engine_{load_name}_{rpm:04d}.wav"
        write_wav(os.path.join(out_dir, name), x * gain, loop=True, peak=0.99)
        meta["loops"].append({"file": name, "rpm": float(eff), "nominal_rpm": rpm, "load": load_name, "samples": len(x)})
        report.append((name, x * gain, rpm))
    json.dump(meta, open(os.path.join(out_dir, "engine_loops.json"), "w"), indent=1)


# ------------------------------------------------------------------------------------------------------
# other loops
# ------------------------------------------------------------------------------------------------------

def make_whine(out_dir):
    """transmission / diff whine: gear mesh tone with harmonics and slight wobble (loop, nominal 600 Hz)"""
    rng = np.random.default_rng(11)
    N = FS * 2
    t = np.arange(N) / FS
    f0 = 600.0
    wob = 1.0 + 0.004 * np.sin(2 * np.pi * 3.0 * t) + 0.002 * np.sin(2 * np.pi * 7.0 * t)
    ph = 2 * np.pi * np.cumsum(f0 * wob) / FS
    # make the phase periodic: f0 * 2 s = integer cycles; the wobble terms have integer cycles in 2 s too
    x = (np.sin(ph) * 1.0 + 0.45 * np.sin(2 * ph + 0.7) + 0.22 * np.sin(3 * ph + 1.9) + 0.12 * np.sin(5 * ph + 0.3))
    am = 1.0 + 0.15 * np.sin(2 * np.pi * 1.0 * t + 1.0)
    x = x * am
    nz = colored_noise(N, rng, beta=0.0, lo=300.0, hi=3000.0) * 0.10
    x = x + fdomain(nz, bandpass_H(rfreqs(N), 700.0, 3.0))
    x = x / (np.max(np.abs(x)) + 1e-9) * 0.5
    # force exact periodicity: crossfade the ends
    fade = 2000
    w = np.linspace(0, 1, fade)
    x[:fade] = x[:fade] * w + x[-fade:] * (1 - w) * 0 + (x[-fade:] * (1 - w))
    write_wav(os.path.join(out_dir, "whine.wav"), x, loop=True)


def stick_slip_squeal(n, f0, rng, harm=6, q=0.0):
    """sawtooth-like stick-slip oscillation with slowly wandering pitch + resonant noise"""
    t = np.arange(n) / FS
    # periodic wander: sum of slow sines with integer cycles in the loop length
    dur = n / FS
    wander = 1.0
    for k, a in ((1, 0.035), (2, 0.02), (5, 0.012), (9, 0.006)):
        wander = wander + a * np.sin(2 * np.pi * k / dur * t + rng.uniform(0, 6.28))
    ph = 2 * np.pi * np.cumsum(f0 * wander) / FS
    # make the fundamental periodic over the loop: round the total phase to an integer number of cycles
    total = ph[-1] + 2 * np.pi * f0 / FS
    scale = np.round(total / (2 * np.pi)) * 2 * np.pi / total
    ph = ph * scale
    x = np.zeros(n)
    for h in range(1, harm + 1):
        x += np.sin(h * ph + rng.uniform(0, 6.28)) / h ** 1.15
    # stick-slip amplitude modulation (not exactly periodic -> use integer cycles)
    am = 1.0 + 0.35 * np.sin(2 * np.pi * round(55 * dur) / dur * t) + 0.15 * np.sin(2 * np.pi * round(13 * dur) / dur * t + 1.0)
    x = x * am
    nz = colored_noise(n, rng, beta=0.0, lo=500.0, hi=9000.0)
    nz = fdomain(nz, bandpass_H(rfreqs(n), f0 * 2.0, 4.0 + q))
    x = x / np.std(x) * 0.8 + nz / np.std(nz) * 0.45
    x = fdomain(x, lowpass_H(rfreqs(n), 7000.0, 2) * highpass_H(rfreqs(n), 300.0, 2))
    return x / (np.max(np.abs(x)) + 1e-9) * 0.7


def make_tyres(out_dir):
    rng = np.random.default_rng(23)
    n = FS * 2
    write_wav(os.path.join(out_dir, "squeal_a.wav"), stick_slip_squeal(n, 820.0, rng), loop=True)
    write_wav(os.path.join(out_dir, "squeal_b.wav"), stick_slip_squeal(n, 1350.0, rng, harm=5, q=2.0), loop=True)
    # sliding on loose ground: grainy crunchy noise
    n = FS * 3
    f = rfreqs(n)
    g = np.zeros(n)
    add_pulses(g, rng.uniform(0, n, size=int(n * 0.012)), rng.exponential(1.0, size=int(n * 0.012)), pulse_kernel(0.0004, 0.00008))
    g = fdomain(g, bandpass_H(f, 2400.0, 0.7) * highpass_H(f, 300.0, 2))
    base = fdomain(colored_noise(n, rng, beta=1.0, lo=150.0, hi=6000.0), bandpass_H(f, 900.0, 0.6))
    x = g / np.std(g) * 0.7 + base / np.std(base) * 0.55
    write_wav(os.path.join(out_dir, "slide_loose.wav"), x / np.max(np.abs(x)) * 0.8, loop=True)


def make_road(out_dir):
    rng = np.random.default_rng(37)
    n = FS * 4
    f = rfreqs(n)
    # asphalt: low rumble + tyre hiss + very slow modulation
    a = fdomain(colored_noise(n, rng, beta=1.4, lo=30.0, hi=1800.0), lowpass_H(f, 700.0, 2) * highpass_H(f, 45.0, 2))
    hiss = fdomain(colored_noise(n, rng, beta=0.3, lo=1200.0, hi=9000.0), bandpass_H(f, 3200.0, 0.5))
    t = np.arange(n) / FS
    am = 1.0 + 0.12 * np.sin(2 * np.pi * 0.5 * t) + 0.07 * np.sin(2 * np.pi * 1.25 * t + 2)
    x = (a / np.std(a) * 0.85 + hiss / np.std(hiss) * 0.22) * am
    write_wav(os.path.join(out_dir, "road_asphalt.wav"), x / np.max(np.abs(x)) * 0.85, loop=True)
    # gravel: stones hitting the wheel arches
    g = np.zeros(n)
    cnt = int(n * 0.020)
    add_pulses(g, rng.uniform(0, n, size=cnt), rng.exponential(1.0, size=cnt), pulse_kernel(0.0005, 0.0001))
    g = fdomain(g, bandpass_H(f, 2200.0, 0.6) * highpass_H(f, 400.0, 2))
    rum = fdomain(colored_noise(n, rng, beta=1.2, lo=50.0, hi=1200.0), lowpass_H(f, 500.0, 2))
    x = g / np.std(g) * 0.8 + rum / np.std(rum) * 0.5
    write_wav(os.path.join(out_dir, "road_gravel.wav"), x / np.max(np.abs(x)) * 0.85, loop=True)
    # grass: soft swish
    sw = fdomain(colored_noise(n, rng, beta=1.0, lo=100.0, hi=3500.0), bandpass_H(f, 900.0, 0.4))
    am = 1.0 + 0.30 * np.sin(2 * np.pi * 2.0 * t) + 0.2 * np.sin(2 * np.pi * 3.5 * t + 1)
    x = sw / np.std(sw) * am
    write_wav(os.path.join(out_dir, "road_grass.wav"), x / np.max(np.abs(x)) * 0.8, loop=True)
    # wind: pink-ish noise with slow swirl
    w = colored_noise(n, rng, beta=1.0, lo=40.0, hi=6000.0)
    am = 1.0 + 0.18 * np.sin(2 * np.pi * 0.75 * t) + 0.10 * np.sin(2 * np.pi * 1.75 * t + 0.6)
    w = w * am
    write_wav(os.path.join(out_dir, "wind.wav"), w / np.max(np.abs(w)) * 0.85, loop=True)


# ------------------------------------------------------------------------------------------------------
# one-shots
# ------------------------------------------------------------------------------------------------------

def decay_env(n, tau):
    t = np.arange(n) / FS
    return np.exp(-t / tau)


def ring(n, f0, tau, rng, amp=1.0):
    t = np.arange(n) / FS
    return amp * np.sin(2 * np.pi * f0 * t + rng.uniform(0, 6.28)) * np.exp(-t / tau)


def make_oneshots(out_dir):
    rng = np.random.default_rng(101)
    # exhaust pops / backfire
    for i in range(5):
        n = int(FS * (0.18 + 0.05 * i))
        f = rfreqs(n)
        thump = ring(n, 55.0 + 12 * i, 0.045 + 0.01 * i, rng, 1.0) + ring(n, 110.0 + 20 * i, 0.03, rng, 0.5)
        burst = colored_noise(n, rng, beta=0.4, lo=200.0, hi=7000.0)
        burst = fdomain(burst, bandpass_H(f, 1100.0 + 260 * i, 0.7)) * decay_env(n, 0.014 + 0.004 * i)
        burst = burst / (np.std(burst) + 1e-9) * 0.9
        crackle = np.zeros(n)
        for k in range(rng.integers(2, 6)):
            p = int(rng.uniform(0.02, 0.15) * FS)
            if p < n - 400:
                crackle[p:p + 300] += rng.normal(size=300) * np.exp(-np.arange(300) / 60.0) * rng.uniform(0.2, 0.6)
        crackle = fdomain(crackle, highpass_H(f, 800.0, 2))
        x = thump * 0.8 + burst + crackle
        x = x * np.minimum(1.0, np.arange(n) / 40.0)
        write_wav(os.path.join(out_dir, f"pop_{i + 1}.wav"), x / np.max(np.abs(x)) * 0.9)
    # gearshift clunk (dog box)
    for i in range(3):
        n = int(FS * 0.22)
        f = rfreqs(n)
        thud = ring(n, 70.0 + 14 * i, 0.05, rng, 1.0)
        metal = sum(ring(n, fr * (1 + 0.03 * i), tau, rng, a) for fr, tau, a in ((910.0, 0.05, 0.35), (1730.0, 0.035, 0.25), (2950.0, 0.02, 0.18), (4100.0, 0.012, 0.1)))
        click = colored_noise(n, rng, beta=0.0, lo=1500.0, hi=9000.0) * decay_env(n, 0.004) * 0.6
        x = thud + metal + click
        x = x * np.minimum(1.0, np.arange(n) / 30.0)
        write_wav(os.path.join(out_dir, f"shift_{i + 1}.wav"), x / np.max(np.abs(x)) * 0.85)
    # suspension bump-stop / thump
    n = int(FS * 0.16)
    f = rfreqs(n)
    x = ring(n, 62.0, 0.05, rng, 1.0) + fdomain(colored_noise(n, rng, beta=1.0, lo=30.0, hi=1200.0) * decay_env(n, 0.03), lowpass_H(f, 600.0, 2)) * 0.5
    write_wav(os.path.join(out_dir, "bump.wav"), x / np.max(np.abs(x)) * 0.85)
    # body impacts: light (3), heavy (2)
    for i, (dur, base, crunch) in enumerate(((0.35, 95.0, 0.5), (0.45, 80.0, 0.7), (0.55, 70.0, 0.8))):
        n = int(FS * dur)
        f = rfreqs(n)
        thud = ring(n, base, 0.08, rng, 1.0) + ring(n, base * 2.3, 0.05, rng, 0.4)
        body = fdomain(colored_noise(n, rng, beta=0.8, lo=60.0, hi=5000.0) * decay_env(n, 0.07), bandpass_H(f, 600.0, 0.5))
        metal = sum(ring(n, fr, tau, rng, a) for fr, tau, a in ((420.0, 0.12, 0.25), (1210.0, 0.08, 0.2), (2400.0, 0.05, 0.15)))
        x = thud + body / (np.std(body) + 1e-9) * crunch + metal
        write_wav(os.path.join(out_dir, f"impact_light_{i + 1}.wav"), x / np.max(np.abs(x)) * 0.9)
    for i, (dur, base) in enumerate(((0.9, 55.0), (1.1, 48.0))):
        n = int(FS * dur)
        f = rfreqs(n)
        thud = ring(n, base, 0.16, rng, 1.0) + ring(n, base * 1.9, 0.1, rng, 0.6)
        body = fdomain(colored_noise(n, rng, beta=0.6, lo=40.0, hi=7000.0) * decay_env(n, 0.18), bandpass_H(f, 500.0, 0.4))
        glass = np.zeros(n)
        for k in range(rng.integers(8, 16)):
            p = int(rng.uniform(0.0, 0.5) * FS)
            glass[p:p + 500] += rng.normal(size=500) * np.exp(-np.arange(500) / 90.0) * rng.uniform(0.1, 0.5)
        glass = fdomain(glass, highpass_H(f, 1500.0, 2))
        metal = sum(ring(n, fr, tau, rng, a) for fr, tau, a in ((310.0, 0.3, 0.3), (880.0, 0.22, 0.25), (1730.0, 0.16, 0.2), (3100.0, 0.1, 0.12)))
        x = thud + body / (np.std(body) + 1e-9) * 0.9 + glass * 0.6 + metal
        write_wav(os.path.join(out_dir, f"impact_heavy_{i + 1}.wav"), x / np.max(np.abs(x)) * 0.95)
    # starter / engine catch (short): not looped
    n = int(FS * 1.6)
    t = np.arange(n) / FS
    f = rfreqs(n)
    crank = np.zeros(n)
    for k in range(int(1.0 * 9)):
        p = int(k / 9.0 * FS)
        if p + 4000 < n:
            crank[p:p + 4000] += ring(4000, 120.0, 0.025, rng, 1.0) * rng.uniform(0.7, 1.0)
    motor = np.sin(2 * np.pi * (180.0 + 90.0 * np.minimum(t, 1.0)) * t) * 0.15 * np.minimum(1.0, t * 3)
    x = crank * 0.7 + motor + fdomain(colored_noise(n, rng, beta=1.0, lo=80.0, hi=3000.0), lowpass_H(f, 1500, 2)) * 0.05
    write_wav(os.path.join(out_dir, "starter.wav"), x / np.max(np.abs(x)) * 0.7)


# ------------------------------------------------------------------------------------------------------
# spectrograms / checks
# ------------------------------------------------------------------------------------------------------

def spectrogram_image(items, path, seconds=1.6):
    from PIL import Image, ImageDraw
    W, H = 520, 300
    tiles = []
    for name, x, rpm in items:
        n = int(min(len(x), seconds * FS))
        seg = x[:n]
        nfft = 2048
        hop = 256
        win = np.hanning(nfft)
        frames = []
        for s in range(0, len(seg) - nfft, hop):
            frames.append(np.abs(np.fft.rfft(seg[s:s + nfft] * win)))
        S = np.array(frames).T
        S = 20 * np.log10(S + 1e-9)
        S = np.clip((S - (S.max() - 70)) / 70.0, 0, 1)
        keep = int(nfft / 2 * 4000 / (FS / 2))
        S = S[:keep][::-1]
        img = Image.fromarray(np.uint8(S * 255)).resize((W, H))
        rgb = Image.merge("RGB", (img.point(lambda v: min(255, v * 2)), img.point(lambda v: int(255 * (v / 255) ** 1.6)), img.point(lambda v: int(255 * (1 - v / 255) * 0.6 + v * 0.25))))
        d = ImageDraw.Draw(rgb)
        d.text((6, 4), f"{name}  (0-4 kHz, 70 dB)", fill=(255, 255, 255))
        for hz in (500, 1000, 2000, 3000):
            y = int(H - hz / 4000 * H)
            d.line([(0, y), (12, y)], fill=(255, 255, 255))
            d.text((16, y - 5), f"{hz}", fill=(255, 255, 255))
        tiles.append(rgb)
    cols = 2
    rows = (len(tiles) + cols - 1) // cols
    sheet = Image.new("RGB", (cols * W, rows * H))
    for i, t in enumerate(tiles):
        sheet.paste(t, ((i % cols) * W, (i // cols) * H))
    os.makedirs(os.path.dirname(path), exist_ok=True)
    sheet.save(path)


def spectrum_plot(items, path):
    from PIL import Image, ImageDraw
    W, H = 1040, 520
    img = Image.new("RGB", (W, H), (14, 14, 18))
    d = ImageDraw.Draw(img)
    fmin, fmax = 30.0, 10000.0
    cols = [(255, 120, 90), (255, 200, 80), (120, 220, 120), (90, 190, 255), (200, 140, 255), (255, 255, 255)]
    for fx in (50, 100, 200, 500, 1000, 2000, 5000, 10000):
        x = int((np.log10(fx) - np.log10(fmin)) / (np.log10(fmax) - np.log10(fmin)) * (W - 60)) + 40
        d.line([(x, 20), (x, H - 30)], fill=(50, 50, 60))
        d.text((x - 10, H - 24), str(fx), fill=(200, 200, 200))
    for i, (name, x, rpm) in enumerate(items):
        n = len(x)
        nfft = 8192
        acc = None
        cnt = 0
        for st in range(0, n - nfft, nfft // 2):
            sp = np.abs(np.fft.rfft(x[st:st + nfft] * np.hanning(nfft))) ** 2
            acc = sp if acc is None else acc + sp
            cnt += 1
        P = 10 * np.log10(acc / cnt + 1e-20)
        f = np.fft.rfftfreq(nfft, 1.0 / FS)
        # smooth in log-frequency: 1/6 octave
        pts = []
        for fx in np.geomspace(fmin, fmax, 360):
            m = (f > fx / 1.06) & (f < fx * 1.06)
            pts.append((fx, P[m].mean() if m.any() else -200))
        ref = i  # offsets per curve for readability
        for (fa, pa), (fb, pb) in zip(pts[:-1], pts[1:]):
            xa = int((np.log10(fa) - np.log10(fmin)) / (np.log10(fmax) - np.log10(fmin)) * (W - 60)) + 40
            xb = int((np.log10(fb) - np.log10(fmin)) / (np.log10(fmax) - np.log10(fmin)) * (W - 60)) + 40
            ya = int(H - 30 - (pa + 20) * 2.6)
            yb = int(H - 30 - (pb + 20) * 2.6)
            d.line([(xa, ya), (xb, yb)], fill=cols[i % len(cols)], width=1)
        d.text((50, 24 + 12 * i), name, fill=cols[i % len(cols)])
    d.text((W - 300, 8), "long-term spectrum, dB (relative)", fill=(255, 255, 255))
    os.makedirs(os.path.dirname(path), exist_ok=True)
    img.save(path)


def order_report(items):
    """print the strongest spectral peaks of each engine loop expressed in engine orders"""
    lines = []
    for name, x, rpm in items:
        n = len(x)
        spec = np.abs(np.fft.rfft(x * np.hanning(n)))
        f = rfreqs(n)
        rev = rpm / 60.0
        # energy per order bucket (0.5 .. 24)
        orders = {}
        for o in (0.5, 1, 2, 3, 4, 6, 8, 12, 16, 24):
            m = (np.abs(f - o * rev) < 0.08 * rev) & (f > 20)
            orders[o] = float(np.max(spec[m])) if m.any() else 0.0
        ref = max(orders.values()) + 1e-9
        total = np.sqrt(np.sum(spec ** 2))
        harm = np.sqrt(sum(v ** 2 for v in orders.values()))
        lines.append("%-22s rms=%.3f  orders(dB rel. max): %s  tonal/total=%.2f" % (
            name, float(np.sqrt(np.mean(x ** 2))), " ".join("%s:%d" % (o, round(20 * np.log10(v / ref + 1e-9))) for o, v in orders.items()), harm / total))
    return lines


def main():
    ap = argparse.ArgumentParser()
    root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    ap.add_argument("--out", default=os.path.join(root, "game", "assets", "audio"))
    ap.add_argument("--only", default="all")
    ap.add_argument("--spectrograms", default="")
    a = ap.parse_args()
    report = []
    if a.only in ("all", "engine"):
        make_engine(a.out, report)
    if a.only in ("all", "fx"):
        make_whine(a.out)
        make_tyres(a.out)
        make_road(a.out)
        make_oneshots(a.out)
    if report:
        for line in order_report(report):
            print(line)
        if a.spectrograms:
            pick = [r for r in report if r[0] in ("engine_on_1000.wav", "engine_off_1000.wav", "engine_on_3000.wav", "engine_on_5400.wav",
                                                   "engine_on_7800.wav", "engine_on_9000.wav", "engine_off_5400.wav", "engine_off_9000.wav")]
            spectrogram_image(pick, os.path.join(a.spectrograms, "engine_spectrograms.png"))
            spectrum_plot([r for r in report if r[0] in ("engine_on_1000.wav", "engine_on_3000.wav", "engine_on_5400.wav", "engine_on_7800.wav", "engine_on_9000.wav", "engine_off_5400.wav")],
                          os.path.join(a.spectrograms, "engine_spectrum.png"))
    print("done ->", a.out)


if __name__ == "__main__":
    main()
