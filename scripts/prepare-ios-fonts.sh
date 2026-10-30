#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SOURCE_DIR="$ROOT_DIR/tools/ios-fonts"
DEST_DIR="$ROOT_DIR/ios/RideScreenIOS/Fonts"

mkdir -p "$DEST_DIR"

python3 - "$SOURCE_DIR" "$DEST_DIR" <<'PY'
import base64
import sys
from pathlib import Path

source = Path(sys.argv[1])
destination = Path(sys.argv[2])
fonts = sorted(source.glob("*.ttf.b64"))
if len(fonts) != 5:
    raise SystemExit(f"Expected 5 encoded Archivo fonts, found {len(fonts)}")

for encoded_path in fonts:
    payload = base64.b64decode("".join(encoded_path.read_text(encoding="ascii").split()), validate=True)
    if payload[:4] != bytes.fromhex("00010000"):
        raise SystemExit(f"Invalid TrueType header: {encoded_path.name}")
    output = destination / encoded_path.name[:-4]
    output.write_bytes(payload)
    print(f"Decoded {output.name}: {len(payload)} bytes")
PY
