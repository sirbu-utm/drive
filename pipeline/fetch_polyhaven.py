"""Download CC0 assets from Poly Haven (https://polyhaven.com, all assets CC0).

    python3 pipeline/fetch_polyhaven.py textures 2k asphalt_track sparse_grass ...
    python3 pipeline/fetch_polyhaven.py models 2k fir_tree_01 boulder_01 ...

Textures -> game/assets/textures/<name>/<name>_{diff,nor_gl,arm}_<res>.jpg
Models   -> game/assets/vegetation/<name>/ (glTF + its textures)
Appends each asset to CREDITS.md once.
"""
import json
import os
import sys
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
API = "https://api.polyhaven.com"
UA = {"User-Agent": "DRIVE1-asset-fetch/1.0"}


def get_json(url):
    with urllib.request.urlopen(urllib.request.Request(url, headers=UA), timeout=60) as r:
        return json.load(r)


def download(url, dst):
    if os.path.exists(dst) and os.path.getsize(dst) > 0:
        return False
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    tmp = dst + ".part"
    with urllib.request.urlopen(urllib.request.Request(url, headers=UA), timeout=300) as r, open(tmp, "wb") as f:
        while True:
            b = r.read(1 << 20)
            if not b:
                break
            f.write(b)
    os.replace(tmp, dst)
    return True


def credit(name, kind):
    path = os.path.join(ROOT, "CREDITS.md")
    line = f"- Poly Haven {kind} `{name}` (CC0) https://polyhaven.com/a/{name}\n"
    txt = open(path, encoding="utf-8").read() if os.path.exists(path) else "# Credits\n"
    if line not in txt:
        with open(path, "a", encoding="utf-8") as f:
            if "## Poly Haven" not in txt:
                f.write("\n## Poly Haven (CC0)\n")
            f.write(line)


def fetch_texture(name, res):
    files = get_json(f"{API}/files/{name}")
    out = os.path.join(ROOT, "game", "assets", "textures", name)
    for key, tag in (("Diffuse", "diff"), ("nor_gl", "nor_gl"), ("arm", "arm"), ("Displacement", "disp")):
        if key not in files:
            print(f"  {name}: no {key}")
            continue
        url = files[key][res]["jpg"]["url"]
        dst = os.path.join(out, f"{name}_{tag}_{res}.jpg")
        print(("  got " if download(url, dst) else "  have ") + os.path.relpath(dst, ROOT))
    credit(name, "texture")


def fetch_model(name, res):
    files = get_json(f"{API}/files/{name}")
    g = files["gltf"][res]["gltf"]
    out = os.path.join(ROOT, "assets_src", "polyhaven_models", name)
    download(g["url"], os.path.join(out, os.path.basename(g["url"])))
    for rel, inc in g.get("include", {}).items():
        download(inc["url"], os.path.join(out, rel))
    print(f"  model {name} -> {os.path.relpath(out, ROOT)}")
    credit(name, "model")


def main():
    kind, res, names = sys.argv[1], sys.argv[2], sys.argv[3:]
    for n in names:
        print(n)
        (fetch_texture if kind == "textures" else fetch_model)(n, res)


main()
