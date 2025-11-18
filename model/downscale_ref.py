"""
Modelo de referencia para downscaling por interpolación bilineal.
Usa punto fijo Q8.8 para pesos y Q10.8 para las coordenadas.
Sirve como oráculo para comparar con el hardware.
"""
import argparse
from utils import read_raw_u8, write_raw_u8, write_pgm_u8

def clamp_u8(x):
    return 0 if x < 0 else 255 if x > 255 else x

def downscale_bilinear_u8(img, scale):
    """
    img: lista de listas de enteros de 0 a 255.
    scale: en [0.5, 1.0].
    Retorna imagen reducida.
    """
    H, W = len(img), len(img[0])
    H2 = max(1, round(H*scale))
    W2 = max(1, round(W*scale))
    out = [[0]*W2 for _ in range(H2)]

    for yo in range(H2):
        ys = (yo + 0.5)/scale - 0.5
        y0 = int(ys)
        y1 = min(y0+1, H-1)
        ty = ys - y0
        ty_q = min(255, round(ty*256))  # Q8.8

        for xo in range(W2):
            xs = (xo + 0.5)/scale - 0.5
            x0 = int(xs)
            x1 = min(x0+1, W-1)
            tx = xs - x0
            tx_q = min(255, round(tx*256))  # Q8.8

            I00 = img[y0][x0]; I10 = img[y0][x1]
            I01 = img[y1][x0]; I11 = img[y1][x1]
            wx0 = 256 - tx_q
            wy0 = 256 - ty_q

            s  = I00*wx0*wy0 + I10*tx_q*wy0 + I01*wx0*ty_q + I11*tx_q*ty_q
            out[yo][xo] = clamp_u8((s + (1<<15)) >> 16)  # redondeo

    return out

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--in", required=True, help="imagen RAW de entrada")
    ap.add_argument("--w", type=int, required=True)
    ap.add_argument("--h", type=int, required=True)
    ap.add_argument("--scale", type=float, required=True)
    ap.add_argument("--out-raw", required=True)
    ap.add_argument("--out-pgm", required=True)
    args = ap.parse_args()

    img = read_raw_u8(args.__dict__["in"], args.w, args.h)
    out = downscale_bilinear_u8(img, args.scale)
    write_raw_u8(args.out_raw, out)
    write_pgm_u8(args.out_pgm, out)
    print("listo modelo ejecutado")

if __name__ == "__main__":
    main()
