# Checklist de validación

## Generar entradas y referencia
make gen_vectors
make golden_all

## Producir salida del sistema
make tb_top

## Comparar contra referencia
make compare_top

## Crear meta y ver resumen
make meta_sw
make perf_summary

## Reporte final
make report
sed -n '1,120p' results/report.md

## CSV para unitarios
make unit_csv

## Unitarios (si hay iverilog)
make tb_unit
