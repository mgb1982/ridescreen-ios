#!/usr/bin/env bash
# Manually regenerate AppIcon.png after changing design/icon.svg.
# Requires rsvg-convert (librsvg) and Python 3 with Pillow.
# No dependencies are installed and this script is not run by Xcode.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SOURCE_SVG="$ROOT_DIR/design/icon.svg"
OUTPUT_PNG="$ROOT_DIR/ios/RideScreenIOS/Assets.xcassets/AppIcon.appiconset/AppIcon.png"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

command -v rsvg-convert >/dev/null 2>&1 || {
  echo "Missing rsvg-convert. Install librsvg manually, then rerun this script." >&2; exit 1;
}
python3 -c 'from PIL import Image' >/dev/null 2>&1 || {
  echo "Missing Pillow. Install it manually in your Python environment, then rerun." >&2; exit 1;
}

python3 - "$SOURCE_SVG" "$TMP_DIR/icon.svg" <<'PY'
import sys
from pathlib import Path
source_path = Path(sys.argv[1])
source = source_path.read_text(encoding="utf-8")
marker = '<g clip-path="url(#c)">'
if marker not in source:
    raise SystemExit("Expected clip-path group was not found in design/icon.svg")
source = source.replace(
    marker,
    '<rect x="18" y="18" width="72" height="72" fill="#1A231D"/>' + marker,
    1,
)
Path(sys.argv[2]).write_text(source, encoding="utf-8")
PY

rsvg-convert --width 1024 --height 1024 "$TMP_DIR/icon.svg" > "$TMP_DIR/icon-rgba.png"
python3 - "$TMP_DIR/icon-rgba.png" "$OUTPUT_PNG" <<'PY'
import sys
from pathlib import Path
from PIL import Image
source_path, output_path = map(Path, sys.argv[1:])
with Image.open(source_path) as source:
    if source.size != (1024, 1024):
        raise SystemExit(f"Expected 1024x1024 render, got {source.size}")
    background = Image.new("RGB", source.size, "#1A231D")
    if source.mode == "RGBA":
        background.paste(source, mask=source.getchannel("A"))
    else:
        background.paste(source.convert("RGB"))
    background.save(output_path, format="PNG", optimize=True)
with Image.open(output_path) as output:
    if output.size != (1024, 1024) or output.mode != "RGB":
        raise SystemExit("AppIcon must be a 1024x1024 opaque RGB PNG")
print(f"Generated opaque RGB app icon: {output_path}")
PY
