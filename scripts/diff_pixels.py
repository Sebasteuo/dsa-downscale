#!/usr/bin/env python3
"""
Muestra los pixeles donde A y B difieren y la diferencia.
Uso:
  python3 scripts/diff_pixels.py --w W --h H --a rutaA.raw --b rutaB.raw
"""

import argparse
import os
import sys

# agregar la carpeta raiz del repo al path para poder importar model.utils
sys.path.append(os.path.dirname(os.path.dirname(__file__)))

from model.utils import read_raw_u8

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--w", type=int, required=True)
    ap.add_argument("--h", type=int, required=True)
    ap.add_argument("--a", required=True, help="imagen A RAW (golden)")
    ap.add_argument("--b", required=True, help="imagen B RAW (HW)")
    args = ap.parse_args()

    A = read_raw_u8(args.a, args.w, args.h)
    B = read_raw_u8(args.b, args.w, args.h)

    diffs = []
    for y in range(args.h):
        for x in range(args.w):
            va = A[y][x]
            vb = B[y][x]
            if va != vb:
                diffs.append((y, x, va, vb, vb - va))

    print(f"total pixeles distintos: {len(diffs)}")
    for y, x, va, vb, d in diffs:
        print(f"(y={y}, x={x}) golden={va:02x} hw={vb:02x} diff={d}")

if __name__ == "__main__":
    main()
