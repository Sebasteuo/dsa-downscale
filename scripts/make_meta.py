#!/usr/bin/env python3
"""
Crea un meta.json simple con info de la corrida
Campos basicos: w_in h_in scale w_out h_out mode units perf_cyc perf_pix
Los dos ultimos son opcionales
"""
import argparse, json, os

def calc_dims(w, h, scale):
    w2 = max(1, round(w*scale))
    h2 = max(1, round(h*scale))
    return w2, h2

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--w", type=int, required=True)
    ap.add_argument("--h", type=int, required=True)
    ap.add_argument("--scale", type=float, required=True)
    ap.add_argument("--mode", choices=["sw","secuencial","paralelo"], default="sw")
    ap.add_argument("--units", type=int, default=1, help="unidades en paralelo si aplica")
    ap.add_argument("--perf-cyc", type=int, default=None)
    ap.add_argument("--perf-pix", type=int, default=None)
    ap.add_argument("--out", default="results/meta.json")
    args = ap.parse_args()

    w2, h2 = calc_dims(args.w, args.h, args.scale)
    meta = {
        "w_in": args.w, "h_in": args.h,
        "scale": args.scale,
        "w_out": w2, "h_out": h2,
        "mode": args.mode,
        "units": args.units
    }
    if args.perf_cyc is not None: meta["perf_cyc"] = args.perf_cyc
    if args.perf_pix is not None: meta["perf_pix"] = args.perf_pix

    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    with open(args.out, "w") as f:
        json.dump(meta, f, indent=2)
    print(f"listo {args.out}")

if __name__ == "__main__":
    main()
