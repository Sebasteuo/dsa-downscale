"""
Genera imágenes de prueba en RAW de 8 bits.
Patrones: grad  checker.
"""
import argparse
from utils import write_raw_u8

def gen_grad(w, h):
    """
    Gradiente horizontal de 0 a 255.
    """
    img = []
    for y in range(h):
        fila = []
        for x in range(w):
            val = int(255 * x / max(1, w-1))
            fila.append(val)
        img.append(fila)
    return img

def gen_checker(w, h, sz=8):
    """
    Damero blanco y negro con tamaño de celda sz.
    """
    img = []
    for y in range(h):
        fila = []
        for x in range(w):
            c = 255 if ((x//sz + y//sz) % 2) == 0 else 0
            fila.append(c)
        img.append(fila)
    return img

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--w", type=int, required=True)
    ap.add_argument("--h", type=int, required=True)
    ap.add_argument("--pattern", choices=["grad","checker"], default="grad")
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    img = gen_grad(args.w, args.h) if args.pattern=="grad" else gen_checker(args.w, args.h)
    write_raw_u8(args.out, img)
    print("listo imagen RAW generada")

if __name__ == "__main__":
    main()
