#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
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
if not fonts:
    raise SystemExit(f"No encoded Archivo fonts found in {source}")

for encoded_path in fonts:
    payload = base64.b64decode(encoded_path.read_bytes(), validate=False)
    if not payload.startswith(b"\x00\x01\x00\x00"):
        raise SystemExit(f"Invalid TrueType data: {encoded_path.name}")
    output = destination / encoded_path.name[:-4]
    output.write_bytes(payload)
    print(f"Prepared {output.name} ({len(payload)} bytes)")
PY
