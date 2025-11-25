"""
Calcula el tamaño de salida redondeando al entero más cercano.
Siempre devuelve al menos 1x1.

Ejemplo:
  python3 scripts/calc_dims.py --w 64 --h 64 --scale 0.75
"""
import argparse
def main():
    ap = argparse.ArgumentParser(description="Calcula W_out H_out a partir de W H y scale.")
    ap.add_argument("--w", type=int, required=True)
    ap.add_argument("--h", type=int, required=True)
    ap.add_argument("--scale", type=float, required=True)
    args = ap.parse_args()
    w2 = max(1, round(args.w * args.scale))
    h2 = max(1, round(args.h * args.scale))
    print(f"{w2} {h2}")
if __name__ == "__main__":
    main()
