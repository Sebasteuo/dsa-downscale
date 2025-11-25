# DSA Downscale

## Cómo correr 
1. Generar patrones de entrada:
```bash
make gen_vectors
```
2. Crear las salidas golden del modelo:
```
make golden_all
```

4. Ver tamaño de salida de ejemplo:
```
make dims
```

6. Comparar dos RAW del mismo tamaño
```
python3 pc/compare.py --wa 32 --ha 32 --wb 32 --hb 32
--a vectors/golden/grad_32_s10.raw
--b vectors/golden/grad_32_s10.raw
```

Notas
* Las imágenes son RAW de 8 bits en escala de grises
* Los golden se guardan en vectors/golden
* Se requiere Python 3 EOF
