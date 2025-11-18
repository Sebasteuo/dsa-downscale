"""
Funciones de apoyo para leer y escribir imágenes RAW de 8 bits
y para guardar imágenes en PGM. Código simple y comentado.
"""

def read_raw_u8(path, w, h):
    """
    Lee un archivo RAW de nivel de gris de 8 bits.
    Retorna una lista de listas con h filas y w columnas.
    """
    with open(path, "rb") as f:
        data = list(f.read())
    if len(data) != w*h:
        raise ValueError("el tamaño del archivo no coincide con w*h")
    img = [data[r*w:(r+1)*w] for r in range(h)]
    return img

def write_raw_u8(path, img):
    """
    Escribe una imagen 2D en un archivo RAW de 8 bits.
    """
    h = len(img)
    w = len(img[0])
    buf = bytearray()
    for r in range(h):
        buf.extend(img[r])
    with open(path, "wb") as f:
        f.write(buf)

def write_pgm_u8(path, img):
    """
    Guarda una imagen 2D en formato PGM binario.
    Encabezado: P5 <ancho> <alto> 255
    """
    h = len(img)
    w = len(img[0])
    header = f"P5\n{w} {h}\n255\n".encode("ascii")
    body = bytearray()
    for r in range(h):
        body.extend(img[r])
    with open(path, "wb") as f:
        f.write(header + body)
