from PIL import Image

img = Image.open("prueba.png").convert("L")
img = img.resize((64, 64))                   
img.save("prueba.pgm")   

# Guardar como RAW 
with open("prueba.raw", "wb") as f:
    f.write(img.tobytes())
