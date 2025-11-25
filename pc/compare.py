"""
Compara dos imágenes RAW de 8 bits con el mismo tamaño y reporta:
- porcentaje de píxeles iguales
- diferencia máxima en LSB

Ejemplo:
  python3 pc/compare.py --wa 32 --ha 32 --wb 32 --hb 32 \
    --a vectors/golden/grad_32_s10.raw \
    --b vectors/golden/grad_32_s10.raw
"""
import argparse, os, sys
sys.path.append(os.path.dirname(os.path.dirname(__file__)))
from model.utils import read_raw_u8

def stats(a, b):
    h = len(a); w = len(a[0])
    iguales = 0; dif_max = 0
    total = w*h
    for y in range(h):
        for x in range(w):
            d = abs(a[y][x] - b[y][x])
            if d == 0:
                iguales += 1
            if d > dif_max:
                dif_max = d
    return 100.0*iguales/total, dif_max

def main():
    ap = argparse.ArgumentParser(description="Comparador simple de imágenes RAW 8-bit.")
    ap.add_argument("--wa", type=int, required=True); ap.add_argument("--ha", type=int, required=True)
    ap.add_argument("--wb", type=int, required=True); ap.add_argument("--hb", type=int, required=True)
    ap.add_argument("--a", required=True, help="imagen A RAW")
    ap.add_argument("--b", required=True, help="imagen B RAW")
    args = ap.parse_args()

    A = read_raw_u8(args.a, args.wa, args.ha)
    B = read_raw_u8(args.b, args.wb, args.hb)

    if len(A) != len(B) or len(A[0]) != len(B[0]):
        print(f"tamaños distintos  A {args.wa}x{args.ha}  B {args.wb}x{args.hb}")
        sys.exit(1)

    pct, dmax = stats(A, B)
    print(f"iguales {pct:.2f}%")
    print(f"dif_max {dmax} LSB")
    print("OK" if dmax == 0 else "hay diferencias")

if __name__ == "__main__":
    main()
