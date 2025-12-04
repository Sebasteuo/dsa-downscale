#!/usr/bin/env python3
"""
Convierte un PNG a RAW 32x32 en gris.
Uso:
  python3 scripts/png_to_raw_32.py input.png output.raw
"""

import sys
from PIL import Image

if len(sys.argv) != 3:
    print("uso: png_to_raw_32.py input.png output.raw")
    sys.exit(1)

inp = sys.argv[1]
out = sys.argv[2]

img = Image.open(inp).convert("L")
img = img.resize((32, 32))
with open(out, "wb") as f:
    f.write(img.tobytes())

print(f"listo {out} (32x32)")
