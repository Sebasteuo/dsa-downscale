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
