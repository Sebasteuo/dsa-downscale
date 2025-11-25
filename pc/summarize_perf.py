#!/usr/bin/env python3
"""
Muestra un resumen simple a partir de meta.json
Si hay perf_cyc y perf_pix calcula pixeles por ciclo
"""
import argparse, json

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--meta", default="results/meta.json")
    args = ap.parse_args()

    with open(args.meta) as f:
        m = json.load(f)

    print("=== Resumen ===")
    print(f"entrada {m['w_in']}x{m['h_in']}")
    print(f"scale {m['scale']}")
    print(f"salida {m['w_out']}x{m['h_out']}")
    print(f"modo {m.get('mode','-')}  unidades {m.get('units','-')}")
    pc = m.get("perf_cyc"); pp = m.get("perf_pix")
    if pc is not None and pp is not None and pc > 0:
        tpp = pp/pc
        print(f"pixeles por ciclo {tpp:.3f}")
    else:
        print("pixeles por ciclo sin datos aun")
    print("===============")

if __name__ == "__main__":
    main()
