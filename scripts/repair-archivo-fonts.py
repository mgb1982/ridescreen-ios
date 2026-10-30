#!/usr/bin/env python3
"""Repair Archivo name tables and weight classes in the committed Base64 TTF sources."""
from __future__ import annotations

import base64
import io
from pathlib import Path
from fontTools.ttLib import TTFont

ROOT = Path(__file__).resolve().parents[1]
FONT_DIR = ROOT / "tools" / "ios-fonts"
SPECS = {
    "Archivo-Regular.ttf.b64": ("Regular", "Archivo-Regular", 400),
    "Archivo-Medium.ttf.b64": ("Medium", "Archivo-Medium", 500),
    "Archivo-SemiBold.ttf.b64": ("SemiBold", "Archivo-SemiBold", 600),
    "Archivo-ExtraBold.ttf.b64": ("ExtraBold", "Archivo-ExtraBold", 800),
}
NAME_IDS = (1, 2, 4, 6, 16, 17)

for filename, (style, postscript, weight) in SPECS.items():
    path = FONT_DIR / filename
    raw = base64.b64decode("".join(path.read_text(encoding="ascii").split()))
    font = TTFont(io.BytesIO(raw), recalcTimestamp=False)
    table = font["name"]
    table.names = [record for record in table.names if record.nameID not in NAME_IDS]
    values = {
        1: "Archivo",
        2: style,
        4: f"Archivo {style}",
        6: postscript,
        16: "Archivo",
        17: style,
    }
    for platform, encoding, language in ((0, 4, 0), (3, 1, 0x409)):
        for name_id, value in values.items():
            table.setName(value, name_id, platform, encoding, language)
    font["OS/2"].usWeightClass = weight
    output = io.BytesIO()
    font.save(output)
    encoded = base64.b64encode(output.getvalue()).decode("ascii")
    path.write_text(encoded + "\n", encoding="ascii")
    print(f"{filename}: {postscript}, weight {weight}")
