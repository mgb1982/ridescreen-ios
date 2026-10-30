#!/usr/bin/env bash
# Run manually after changing design/icon.svg, then commit the generated AppIcon.png.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SOURCE_SVG="$ROOT_DIR/design/icon.svg"
ASSET_DIR="$ROOT_DIR/ios/RideScreenIOS/Assets.xcassets/AppIcon.appiconset"
OUTPUT="$ASSET_DIR/AppIcon.png"
TMP_DIR="$(mktemp -d -t ridescreen-icon)"
TMP_SVG="$TMP_DIR/icon.svg"
TMP_PNG="$TMP_DIR/icon.png"
trap 'rm -rf "$TMP_DIR"' EXIT

command -v rsvg-convert >/dev/null 2>&1 || {
  echo "Missing rsvg-convert. Install it with: brew install librsvg" >&2
  exit 1
}
python3 -c 'from PIL import Image' >/dev/null 2>&1 || {
  echo "Missing Pillow. Install it with: python3 -m pip install Pillow" >&2
  exit 1
}

python3 - "$SOURCE_SVG" "$TMP_SVG" <<'PY'
from pathlib import Path
import sys

source_path = Path(sys.argv[1])
svg = source_path.read_text(encoding="utf-8")
# Fill all square corners, preserving the source artwork and its circular logo crop.
svg = svg.replace(
    '<g clip-path="url(#c)">',
    '<rect x="18" y="18" width="72" height="72" fill="#1A231D"/><g clip-path="url(#c)">',
    1,
)
svg = svg.replace("scale(0.8 0.8)", "scale(1 1)", 1)
if "<svg" not in svg or "url(#c)" not in svg:
    raise SystemExit("Unexpected design/icon.svg structure; update this generator to match the source.")
Path(sys.argv[2]).write_text(svg, encoding="utf-8")
PY

rsvg-convert --width 1024 --height 1024 "$TMP_SVG" > "$TMP_PNG"

python3 - "$TMP_PNG" "$OUTPUT" <<'PY'
from pathlib import Path
import sys
from PIL import Image

source = Path(sys.argv[1])
output = Path(sys.argv[2])
with Image.open(source) as image:
    if image.size != (1024, 1024):
        raise SystemExit(f"Expected 1024x1024 source image, got {image.size}")
    rgb = image.convert("RGB")
    rgb.save(output, format="PNG", optimize=True)
with Image.open(output) as image:
    if image.mode != "RGB" or image.size != (1024, 1024):
        raise SystemExit("AppIcon.png must be 1024x1024 RGB with no alpha channel")
print(f"Generated {output} (1024x1024, RGB, opaque)")
PY
