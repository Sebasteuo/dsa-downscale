"""
Genera salidas "golden" del modelo leyendo vectors/manifest.csv.

CSV por fila:
  name,w,h,scale,in_path,out_raw,out_pgm
"""
import csv, subprocess, sys

def run_model(in_path, w, h, scale, out_raw, out_pgm):
    cmd = [
        "python3", "model/downscale_ref.py",
        "--in", in_path, "--w", str(w), "--h", str(h),
        "--scale", str(scale), "--out-raw", out_raw, "--out-pgm", out_pgm
    ]
    subprocess.check_call(cmd)

def main():
    ok = 0; total = 0
    with open("vectors/manifest.csv", newline="") as f:
        for row in csv.reader(f):
            if not row or row[0].startswith("#"):
                continue
            total += 1
            name, w, h, scale, in_path, out_raw, out_pgm = row
            w = int(w); h = int(h); scale = float(scale)
            print(f"-> procesando {name}  {w}x{h}  s={scale}")
            run_model(in_path, w, h, scale, out_raw, out_pgm)
            print(f"listo {name}")
            ok += 1
    print(f"golden generados {ok} de {total}")
if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        print("error al generar golden", e)
        sys.exit(1)
