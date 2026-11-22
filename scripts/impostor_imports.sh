#!/usr/bin/env bash
# Write Godot .import settings for impostor atlases (mipmaps + BC7, alpha border fix). Idempotent.
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
for f in "$ROOT"/game/assets/vegetation/impostors/*.png; do
  imp="$f.import"
  grep -q "mipmaps/generate=true" "$imp" 2>/dev/null && continue
  rel="res://${f#$ROOT/game/}"
  cat > "$imp" <<EOT
[remap]

importer="texture"
type="CompressedTexture2D"

[deps]

source_file="$rel"

[params]

compress/mode=2
compress/high_quality=true
compress/lossy_quality=0.7
compress/hdr_compression=1
compress/normal_map=2
compress/channel_pack=0
mipmaps/generate=true
mipmaps/limit=-1
roughness/mode=0
roughness/src_normal=""
process/fix_alpha_border=true
process/premult_alpha=false
process/normal_map_invert_y=false
process/hdr_as_srgb=false
process/hdr_clamp_exposure=false
process/size_limit=0
detect_3d/compress_to=0
EOT
done
