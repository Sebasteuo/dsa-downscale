from PIL import Image

out_w, out_h = 64, 64   # o 12x12 para 0.75, 16x16 para 1.0, 8x8 para 0.5

with open("salida_64x64.raw_ref.raw", "rb") as f:
    data = f.read()

img_out = Image.frombytes("L", (out_w, out_h), data)
img_out.save("salida_64x64.ref.png")
