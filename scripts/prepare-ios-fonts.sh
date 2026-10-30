#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "\${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_DIR="$ROOT_DIR/tools/ios-fonts"
DEST_DIR="$ROOT_DIR/ios/RideScreenIOS/Fonts"
APP_ICON="$ROOT_DIR/ios/RideScreenIOS/Assets.xcassets/AppIcon.appiconset/AppIcon.png"
TEMP_DIR="$(mktemp -d -t ridescreen-app-icon)"
TEMP_SVG="$TEMP_DIR/icon.svg"
trap 'rm -rf "$TEMP_DIR"' EXIT

mkdir -p "$DEST_DIR"

# Recreate the Android app's Archivo font files from their committed Base64 sources.
python3 - "$SOURCE_DIR" "$DEST_DIR" <<'PY'
import base64
import sys
from pathlib import Path

source = Path(sys.argv[1])
destination = Path(sys.argv[2])
fonts = sorted(source.glob("*.ttf.b64"))
if not fonts:
    raise SystemExit(f"No encoded Archivo fonts found in {source}")

for encoded_path in fonts:
    payload = base64.b64decode(encoded_path.read_bytes(), validate=False)
    if payload[:4] != bytes.fromhex("00010000"):
        raise SystemExit(f"Invalid TrueType data: {encoded_path.name}")
    output = destination / encoded_path.name[:-4]
    output.write_bytes(payload)
    print(f"Prepared {output.name} ({len(payload)} bytes)")
PY

# The AppIcon must be an opaque, full-size RGB PNG. Render the approved
# SVG with librsvg, then flatten it to RGB for Apple's asset compiler.
if ! command -v rsvg-convert >/dev/null 2>&1; then
    brew install librsvg
fi

if ! python3 -c 'from PIL import Image' >/dev/null 2>&1; then
    python3 -m pip install --user --quiet Pillow
fi

python3 - "$ROOT_DIR/design/icon.svg" "$TEMP_SVG" <<'PY'
import sys
from pathlib import Path

source = Path(sys.argv[1]).read_text(encoding="utf-8")
source = source.replace(
    '<g clip-path="url(#c)">',
    '<rect x="18" y="18" width="72" height="72" fill="#1A231D"/><g clip-path="url(#c)">',
    1,
)
source = source.replace("scale(0.8 0.8)", "scale(1 1)", 1)
if source == Path(sys.argv[1]).read_text(encoding="utf-8"):
    raise SystemExit("Could not prepare the larger square app icon from design/icon.svg")
Path(sys.argv[2]).write_text(source, encoding="utf-8")
PY

rsvg-convert -w 1024 -h 1024 "$TEMP_SVG" > "$APP_ICON"

python3 - "$APP_ICON" <<'PY'
import sys
from pathlib import Path
from PIL import Image

icon_path = Path(sys.argv[1])
with Image.open(icon_path) as source:
    if source.size != (1024, 1024):
        raise SystemExit(f"Unexpected app icon size: {source.size}")
    source.convert("RGB").save(icon_path, format="PNG", optimize=True)
print(f"Prepared opaque 1024x1024 RGB app icon: {icon_path}")
PY
