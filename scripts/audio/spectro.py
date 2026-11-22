#!/usr/bin/env python3
"""Spectrogram of a recorded WAV (e.g. the engine pull captured from the running game with --audio-rec).
    tools/venv/bin/python scripts/audio/spectro.py in.wav out.png [max_hz=4000] [rpm_csv]
Left/right are mixed to mono. Time on x, frequency on y (log-magnitude, 70 dB range)."""
import sys
import wave
import numpy as np
from PIL import Image, ImageDraw


def read_wav(path):
    with wave.open(path, "rb") as w:
        n, ch, fs, sw = w.getnframes(), w.getnchannels(), w.getframerate(), w.getsampwidth()
        raw = w.readframes(n)
    if sw == 2:
        x = np.frombuffer(raw, dtype="<i2").astype(np.float64) / 32768.0
    elif sw == 4:
        x = np.frombuffer(raw, dtype="<i4").astype(np.float64) / 2147483648.0
    else:
        raise SystemExit("unsupported sample width %d" % sw)
    x = x.reshape(-1, ch).mean(axis=1)
    return x, fs


def main():
    src, dst = sys.argv[1], sys.argv[2]
    maxhz = float(sys.argv[3]) if len(sys.argv) > 3 else 4000.0
    x, fs = read_wav(src)
    nfft, hop = 4096, 512
    win = np.hanning(nfft)
    frames = [np.abs(np.fft.rfft(x[s:s + nfft] * win)) for s in range(0, len(x) - nfft, hop)]
    S = 20 * np.log10(np.array(frames).T + 1e-9)
    S = np.clip((S - (S.max() - 70)) / 70.0, 0, 1)
    keep = int(nfft / 2 * maxhz / (fs / 2))
    S = S[:keep][::-1]
    W, H = 1400, 560
    img = Image.fromarray(np.uint8(S * 255)).resize((W, H))
    rgb = Image.merge("RGB", (img.point(lambda v: min(255, v * 2)), img.point(lambda v: int(255 * (v / 255) ** 1.6)),
                              img.point(lambda v: int(255 * (1 - v / 255) * 0.6 + v * 0.25))))
    d = ImageDraw.Draw(rgb)
    for hz in range(500, int(maxhz) + 1, 500):
        y = int(H - hz / maxhz * H)
        d.line([(0, y), (14, y)], fill=(255, 255, 255))
        d.text((18, y - 5), str(hz), fill=(255, 255, 255))
    dur = len(x) / fs
    for t in range(0, int(dur) + 1):
        xx = int(t / dur * W)
        d.line([(xx, H - 12), (xx, H)], fill=(255, 255, 255))
        d.text((xx + 3, H - 24), "%ds" % t, fill=(255, 255, 255))
    d.text((W - 360, 6), "%s  (%.1f s, %d Hz)" % (src.split("/")[-1], dur, fs), fill=(255, 255, 255))
    rgb.save(dst)
    print("saved", dst, "rms", float(np.sqrt(np.mean(x ** 2))), "peak", float(np.max(np.abs(x))))


main()
