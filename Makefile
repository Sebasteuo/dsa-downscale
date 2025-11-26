PY=python3

# objetivos que siempre deben ejecutarse
.PHONY: help gen_vectors golden_all compare_self dims

help:
	@echo "make help"
	@echo "make gen_vectors     genera RAW de entrada (32x32 y 64x64)"
	@echo "make golden_all      crea todos los golden outputs segun manifest.csv"
	@echo "make compare_self    compara un archivo contra si mismo"
	@echo "make dims            calcula W_out H_out de un ejemplo"

# Día 1 (se mantienen)
gen_example:
	$(PY) model/img2raw.py --w 8 --h 8 --pattern grad --out vectors/patterns/grad_8x8.raw

golden: gen_example
	$(PY) model/downscale_ref.py --in vectors/patterns/grad_8x8.raw --w 8 --h 8 --scale 0.5 --out-raw vectors/golden_grad_8x8_s05.raw --out-pgm vectors/golden_grad_8x8_s05.pgm

compare_self:
	$(PY) pc/compare.py --wa 8 --ha 8 --wb 8 --hb 8 --a vectors/patterns/grad_8x8.raw --b vectors/patterns/grad_8x8.raw

# Día 2
gen_vectors:
	$(PY) model/img2raw.py --w 32 --h 32 --pattern grad --out vectors/patterns/grad_32x32.raw
	$(PY) model/img2raw.py --w 64 --h 64 --pattern checker --out vectors/patterns/checker_64x64.raw
	@echo "manifest en vectors/manifest.csv listo"

golden_all: gen_vectors
	$(PY) scripts/make_golden.py

# utilidad (ejemplo)
dims:
	$(PY) scripts/calc_dims.py --w 64 --h 64 --scale 0.75

.PHONY: unit_csv coords_csv bilinear_csv

coords_csv:
	$(PY) scripts/gen_coords_csv.py --w 32 --h 32 --scale 0.5 --out results/coords_32_s05.csv

bilinear_csv: gen_vectors
	$(PY) scripts/gen_bilinear_cases.py --in vectors/patterns/grad_32x32.raw --w 32 --h 32 --scale 0.5 --out results/bilinear_cases_grad32_s05.csv

unit_csv: coords_csv bilinear_csv
	@echo "csv unitarios listos en results/"

.PHONY: tb_top tb_top_sv tb_top_sw compare_top

tb_top_sv: gen_vectors
	iverilog -g2012 -o tb_top_sv \
		tb/rtl/bilinear_core_scalar.sv \
		tb/top/tb_top_scalar.sv && vvp tb_top_sv


tb_top_sw: gen_vectors
	$(PY) model/downscale_ref.py --in vectors/patterns/grad_32x32.raw --w 32 --h 32 --scale 0.5 --out-raw results/out_hw.raw --out-pgm results/out_hw.pgm

tb_top: tb_top_sw

compare_top:
	@W2=`$(PY) scripts/calc_dims.py --w 32 --h 32 --scale 0.5 | cut -d' ' -f1`; \
	H2=`$(PY) scripts/calc_dims.py --w 32 --h 32 --scale 0.5 | cut -d' ' -f2`; \
	$(PY) pc/compare.py --wa $$W2 --ha $$H2 --wb $$W2 --hb $$H2 --a results/out_hw.raw --b vectors/golden/grad_32_s05.raw

.PHONY: meta_sw perf_summary report all_ok

# meta con los datos del caso 32x32 s=0.5 por ahora en modo sw
meta_sw:
	$(PY) scripts/make_meta.py --w 32 --h 32 --scale 0.5 --mode sw --units 1 --out results/meta.json

# imprime resumen desde meta.json
perf_summary:
	$(PY) pc/summarize_perf.py --meta results/meta.json

# genera reporte markdown usando out_hw.raw y el golden
report:
	$(PY) scripts/make_report.py --meta results/meta.json --hw results/out_hw.raw --golden vectors/golden/grad_32_s05.raw --out results/report.md

# ruta feliz: genera todo y deja reporte
all_ok: gen_vectors golden_all tb_top compare_top meta_sw perf_summary report
	@echo "listo todo"

.PHONY: tb_unit tb_coords tb_bilinear

tb_coords: unit_csv
	@if command -v iverilog >/dev/null 2>&1; then \
		iverilog -g2012 -o tb_coords tb/unit/tb_coords_gen.sv && vvp tb_coords; \
	else \
		echo "no hay iverilog instalado"; \
	fi

tb_bilinear: unit_csv
	@if command -v iverilog >/dev/null 2>&1; then \
		iverilog -g2012 -o tb_bilinear tb/unit/tb_bilinear_core.sv && vvp tb_bilinear; \
	else \
		echo "no hay iverilog instalado"; \
	fi

tb_unit: tb_coords tb_bilinear
	@echo "unitarios ok"

# --- utilidades ---
.PHONY: dirs setup
dirs:
	@mkdir -p vectors/golden results

# atajos útiles
setup: dirs gen_vectors

# asegurar carpetas antes de generar cosas
golden_all: dirs
tb_top_sw: dirs
tb_top_sv: dirs
meta_sw: dirs
report: dirs
compare_top: dirs

# perf_summary debe tener meta.json listo
perf_summary: meta_sw
