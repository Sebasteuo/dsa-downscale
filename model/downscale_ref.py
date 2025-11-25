"""
Modelo de referencia para downscaling por interpolación bilineal.

Usa:
  - Q8.8 para pesos y fracciones
  - Q10.8 para coordenadas (implícito en los cálculos)
Sirve como oráculo: lo que sale aquí debería coincidir con la FPGA.

Ejemplo:
  python3 model/downscale_ref.py --in vectors/patterns/grad_32x32.raw \
    --w 32 --h 32 --scale 0.5 \
    --out-raw vectors/golden/grad_32_s05.raw \
    --out-pgm  vectors/golden/grad_32_s05.pgm
"""
import argparse
from utils import read_raw_u8, write_raw_u8, write_pgm_u8

def clamp_u8(x):
    return 0 if x < 0 else 255 if x > 255 else x

def downscale_bilinear_u8(img, scale):
    """
    img: matriz 2D con valores 0..255
    scale: 0.5 .. 1.0
    Retorna imagen reducida usando bilinear con punto fijo.
    """
    H, W = len(img), len(img[0])
    H2 = max(1, round(H*scale))
    W2 = max(1, round(W*scale))
    out = [[0]*W2 for _ in range(H2)]

    for yo in range(H2):
        ys = (yo + 0.5)/scale - 0.5
        y0 = int(ys); y0 = 0 if y0 < 0 else H-1 if y0 > H-1 else y0
        y1 = y0 + 1 if y0 + 1 < H else y0
        ty = ys - y0; ty_q = min(255, round(ty*256))  # Q8.8

        for xo in range(W2):
            xs = (xo + 0.5)/scale - 0.5
            x0 = int(xs); x0 = 0 if x0 < 0 else W-1 if x0 > W-1 else x0
            x1 = x0 + 1 if x0 + 1 < W else x0
            tx = xs - x0; tx_q = min(255, round(tx*256))  # Q8.8

            I00 = img[y0][x0]; I10 = img[y0][x1]
            I01 = img[y1][x0]; I11 = img[y1][x1]
            wx0 = 256 - tx_q; wy0 = 256 - ty_q

            s  = I00*wx0*wy0 + I10*tx_q*wy0 + I01*wx0*ty_q + I11*tx_q*ty_q
            out[yo][xo] = clamp_u8((s + (1<<15)) >> 16)  # redondeo Q16.16 -> 8 bits

    return out

def main():
    ap = argparse.ArgumentParser(description="Modelo de referencia bilineal en gris 8-bit.")
    ap.add_argument("--in", required=True, help="imagen RAW de entrada")
    ap.add_argument("--w", type=int, required=True, help="ancho de entrada")
    ap.add_argument("--h", type=int, required=True, help="alto de entrada")
    ap.add_argument("--scale", type=float, required=True, help="factor 0.5..1.0")
    ap.add_argument("--out-raw", required=True, help="RAW de salida")
    ap.add_argument("--out-pgm", required=True, help="PGM de salida")
    args = ap.parse_args()

    img = read_raw_u8(args.__dict__["in"], args.w, args.h)
    out = downscale_bilinear_u8(img, args.scale)
    write_raw_u8(args.out_raw, out)
    write_pgm_u8(args.out_pgm, out)
    print("listo modelo ejecutado")

if __name__ == "__main__":
    main()
