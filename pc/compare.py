"""
Comparador entre dos imágenes RAW de 8 bits.
Permite pasar tamaños distintos para A y B.
Sirve para validar que HW y SW producen el mismo resultado.
"""
import argparse, os, sys
sys.path.append(os.path.dirname(os.path.dirname(__file__)))
from model.utils import read_raw_u8

def stats(a, b):
    h = len(a); w = len(a[0])
    iguales = 0
    dif_max = 0
    total = w*h
    for y in range(h):
        for x in range(w):
            d = abs(a[y][x] - b[y][x])
            if d == 0:
                iguales += 1
            if d > dif_max:
                dif_max = d
    pct = 100.0 * iguales / total
    return pct, dif_max

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--wa", type=int, required=True, help="ancho de A")
    ap.add_argument("--ha", type=int, required=True, help="alto de A")
    ap.add_argument("--wb", type=int, required=True, help="ancho de B")
    ap.add_argument("--hb", type=int, required=True, help="alto de B")
    ap.add_argument("--a", required=True, help="imagen A RAW")
    ap.add_argument("--b", required=True, help="imagen B RAW")
    args = ap.parse_args()

    A = read_raw_u8(args.a, args.wa, args.ha)
    B = read_raw_u8(args.b, args.wb, args.hb)

    if len(A) != len(B) or len(A[0]) != len(B[0]):
        print("tamaños distintos  no se puede comparar píxel a píxel")
        print(f"A {args.wa}x{args.ha}  B {args.wb}x{args.hb}")
        sys.exit(1)

    pct, dmax = stats(A, B)
    print(f"iguales {pct:.2f}%")
    print(f"dif_max {dmax} LSB")
    print("OK" if dmax == 0 else "hay diferencias")

if __name__ == "__main__":
    main()
