#!/usr/bin/env python3
"""
Genera un reporte Markdown en results/report.md
Incluye tamaños, resultado de comparacion y, si hay, perf
"""
import argparse, json, subprocess, os, sys

def run_compare(w, h, a, b):
    try:
        out = subprocess.check_output([
            "python3","pc/compare.py","--wa",str(w),"--ha",str(h),
            "--wb",str(w),"--hb",str(h),"--a",a,"--b",b
        ], text=True)
        return out.strip()
    except subprocess.CalledProcessError as e:
        return f"error en compare: {e}"

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--meta", default="results/meta.json")
    ap.add_argument("--hw", default="results/out_hw.raw")
    ap.add_argument("--golden", default="vectors/golden/grad_32_s05.raw")
    ap.add_argument("--out", default="results/report.md")
    args = ap.parse_args()

    with open(args.meta) as f:
        m = json.load(f)

    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    cmp_text = run_compare(m["w_out"], m["h_out"], args.hw, args.golden)

    lines = []
    lines.append("# Reporte de corrida\n")
    lines.append(f"- Entrada: {m['w_in']}x{m['h_in']}")
    lines.append(f"- Scale: {m['scale']}")
    lines.append(f"- Salida: {m['w_out']}x{m['h_out']}")
    lines.append(f"- Modo: {m.get('mode','-')}  Unidades: {m.get('units','-')}\n")
    lines.append("## Comparacion\n")
    lines.append("```\n"+cmp_text+"\n```\n")
    pc = m.get("perf_cyc"); pp = m.get("perf_pix")
    if pc is not None and pp is not None and pc > 0:
        tpp = pp/pc
        lines.append("## Rendimiento\n")
        lines.append(f"- Ciclos: {pc}")
        lines.append(f"- Pixeles: {pp}")
        lines.append(f"- Pixeles por ciclo: {tpp:.3f}\n")
    with open(args.out,"w") as f:
        f.write("\n".join(lines))
    print(f"listo {args.out}")

if __name__ == "__main__":
    main()
