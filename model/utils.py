"""
Utilidades simples para trabajar con imágenes en gris de 8 bits.

- RAW: solo datos, sin encabezado, una fila tras otra.
- PGM: formato P5 con encabezado "P5 ancho alto 255" y luego datos.

Este archivo tiene tres funciones:
  read_raw_u8  | lee un RAW y lo devuelve como matriz [fila][columna]
  write_raw_u8 | escribe una matriz en un RAW
  write_pgm_u8 | guarda una matriz en PGM para verla fácil
"""

def read_raw_u8(path, w, h):
    """Lee un archivo RAW de 8 bits y lo devuelve como lista de listas."""
    with open(path, "rb") as f:
        data = list(f.read())
    if len(data) != w*h:
        raise ValueError("el tamaño del archivo no coincide con w*h")
    img = [data[r*w:(r+1)*w] for r in range(h)]
    return img

def write_raw_u8(path, img):
    """Escribe una imagen 2D (lista de listas) en formato RAW de 8 bits."""
    h = len(img)
    w = len(img[0])
    buf = bytearray()
    for r in range(h):
        buf.extend(img[r])
    with open(path, "wb") as f:
        f.write(buf)

def write_pgm_u8(path, img):
    """Guarda una imagen 2D en PGM binario (P5). Sirve para visualizar rápido."""
    h = len(img)
    w = len(img[0])
    header = f"P5\n{w} {h}\n255\n".encode("ascii")
    body = bytearray()
    for r in range(h):
        body.extend(img[r])
    with open(path, "wb") as f:
        f.write(header + body)
