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
3. Producir la salida del sistema (usamoss SV si iverilog está instalado, si no, usamos el modelo en Python)
```
make tb_top
```

5. Ver tamaño de salida de ejemplo:
```
make dims
```

6. Comparar contra la referencia
```
make compare_top
```

7. Comparar dos RAW del mismo tamaño
```
python3 pc/compare.py --wa 32 --ha 32 --wb 32 --hb 32
--a vectors/golden/grad_32_s10.raw
--b vectors/golden/grad_32_s10.raw
```

8. Ver resumen y generar reporte
```
make perf_summary
make report
# reporte final
sed -n '1,120p' results/report.md
```
Notas
* Las imágenes son RAW de 8 bits en escala de grises
* Los golden se guardan en vectors/golden
* Se requiere Python 3 EOF
