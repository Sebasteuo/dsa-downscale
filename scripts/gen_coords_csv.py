"""
Genera un CSV con coordenadas y fracciones por píxel de salida
Columnas: yo,xo,x0,y0,x1,y1,tx_q,ty_q
Usa mapeo por centros y Q8.8 para fracciones
"""
import argparse
import csv

def main():
    ap = argparse.ArgumentParser(description="CSV de coordenadas y fracciones Q8.8")
    ap.add_argument("--w", type=int, required=True, help="ancho de entrada")
    ap.add_argument("--h", type=int, required=True, help="alto de entrada")
    ap.add_argument("--scale", type=float, required=True)
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    W, H, s = args.w, args.h, args.scale
    H2 = max(1, round(H*s))
    W2 = max(1, round(W*s))

    with open(args.out, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["yo","xo","x0","y0","x1","y1","tx_q","ty_q"])
        for yo in range(H2):
            ys = (yo + 0.5)/s - 0.5
            y0 = int(ys)
            y0 = 0 if y0 < 0 else H-1 if y0 > H-1 else y0
            y1 = y0 + 1 if y0 + 1 < H else y0
            ty = ys - y0
            ty_q = min(255, round(ty*256))
            for xo in range(W2):
                xs = (xo + 0.5)/s - 0.5
                x0 = int(xs)
                x0 = 0 if x0 < 0 else W-1 if x0 > W-1 else x0
                x1 = x0 + 1 if x0 + 1 < W else x0
                tx = xs - x0
                tx_q = min(255, round(tx*256))
                w.writerow([yo,xo,x0,y0,x1,y1,tx_q,ty_q])

    print(f"listo {args.out}")

if __name__ == "__main__":
    main()
