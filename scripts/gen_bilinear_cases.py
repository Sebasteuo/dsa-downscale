"""
Genera casos para probar el núcleo bilinear
Columnas: I00,I10,I01,I11,tx_q,ty_q,expected_out
Entrada: RAW 8-bit y factor de escala
"""
import argparse
import csv
import os
import sys

# asegurar import de model.utils al ejecutar desde la raiz del repo
sys.path.append(os.path.dirname(os.path.dirname(__file__)))
from model.utils import read_raw_u8

def main():
    ap = argparse.ArgumentParser(description="Casos unitarios para núcleo bilinear")
    ap.add_argument("--in", required=True, help="RAW de entrada")
    ap.add_argument("--w", type=int, required=True)
    ap.add_argument("--h", type=int, required=True)
    ap.add_argument("--scale", type=float, required=True)
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    img = read_raw_u8(args.__dict__["in"], args.w, args.h)
    s = args.scale
    H2 = max(1, round(args.h*s))
    W2 = max(1, round(args.w*s))

    with open(args.out, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["I00","I10","I01","I11","tx_q","ty_q","expected_out"])
        for yo in range(H2):
            ys = (yo + 0.5)/s - 0.5
            y0 = int(ys); y0 = 0 if y0 < 0 else args.h-1 if y0 > args.h-1 else y0
            y1 = y0 + 1 if y0 + 1 < args.h else y0
            ty = ys - y0; ty_q = min(255, round(ty*256))
            for xo in range(W2):
                xs = (xo + 0.5)/s - 0.5
                x0 = int(xs); x0 = 0 if x0 < 0 else args.w-1 if x0 > args.w-1 else x0
                x1 = x0 + 1 if x0 + 1 < args.w else x0
                tx = xs - x0; tx_q = min(255, round(tx*256))

                I00 = img[y0][x0]; I10 = img[y0][x1]
                I01 = img[y1][x0]; I11 = img[y1][x1]
                wx0 = 256 - tx_q; wy0 = 256 - ty_q
                acc = I00*wx0*wy0 + I10*tx_q*wy0 + I01*wx0*ty_q + I11*tx_q*ty_q
                expected = (acc + (1<<15)) >> 16
                if expected > 255: expected = 255
                if expected < 0: expected = 0
                w.writerow([I00,I10,I01,I11,tx_q,ty_q,expected])

    print(f"listo {args.out}")

if __name__ == "__main__":
    main()
