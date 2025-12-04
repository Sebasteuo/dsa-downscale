PY=python3

.PHONY: help dirs setup gen_vectors golden_all tb_top tb_top_sv tb_top_sw compare_top \
        meta_sw perf_summary report unit_csv coords_csv bilinear_csv all_ok

help:
	@echo "make setup           crea carpetas y patrones base"
	@echo "make golden_all      genera referencias en vectors/golden"
	@echo "make tb_top          produce results/out_hw.raw con SV o fallback"
	@echo "make compare_top     compara out_hw.raw contra golden"
	@echo "make meta_sw         crea meta.json del caso 32x32 s=0.5"
	@echo "make perf_summary    imprime resumen simple"
	@echo "make report          genera results/report.md"
	@echo "make unit_csv        crea CSV de coords y bilinear cases"
	@echo "make all_ok          corre todo de punta a punta"

dirs:
	@mkdir -p vectors/golden results

setup: dirs gen_vectors

gen_vectors:
	$(PY) model/img2raw.py --w 32 --h 32 --pattern grad --out vectors/patterns/grad_32x32.raw
	$(PY) model/img2raw.py --w 64 --h 64 --pattern checker --out vectors/patterns/checker_64x64.raw
	@echo "manifest en vectors/manifest.csv listo"

golden_all: dirs gen_vectors
	$(PY) scripts/make_golden.py

tb_top_sv: gen_vectors
	@if command -v iverilog >/dev/null 2>&1; then \
		iverilog -g2012 -o tb_top_sv tb/top/tb_top_scalar.sv; \
		vvp tb_top_sv; \
	else \
		$(MAKE) tb_top_sw; \
	fi

tb_top_sw: dirs gen_vectors
	$(PY) model/downscale_ref.py --in vectors/patterns/grad_32x32.raw --w 32 --h 32 --scale 0.5 --out-raw results/out_hw.raw --out-pgm results/out_hw.pgm

# alias para compare_top
tb_top: tb_top_sv

compare_top:
	@command -v python3 >/dev/null 2>&1 || { echo "no hay python3"; exit 1; }
	@[ -s vectors/golden/grad_32_s05.raw ] || { echo "no existe el golden, corra make golden_all"; exit 1; }
	@if [ ! -s results/out_hw.raw ]; then \
		$(MAKE) tb_top; \
	fi
	@W2=`$(PY) scripts/calc_dims.py --w 32 --h 32 --scale 0.5 | cut -d' ' -f1`; \
	H2=`$(PY) scripts/calc_dims.py --w 32 --h 32 --scale 0.5 | cut -d' ' -f2`; \
	$(PY) pc/compare.py --wa $$W2 --ha $$H2 --wb $$W2 --hb $$H2 --a results/out_hw.raw --b vectors/golden/grad_32_s05.raw

meta_sw: dirs
	$(PY) scripts/make_meta.py --w 32 --h 32 --scale 0.5 --mode sw --units 1 --out results/meta.json

perf_summary: meta_sw
	$(PY) pc/summarize_perf.py --meta results/meta.json

report: dirs
	$(PY) scripts/make_report.py --meta results/meta.json --hw results/out_hw.raw --golden vectors/golden/grad_32_s05.raw --out results/report.md

coords_csv:
	$(PY) scripts/gen_coords_csv.py --w 32 --h 32 --scale 0.5 --out results/coords_32_s05.csv

bilinear_csv: gen_vectors
	$(PY) scripts/gen_bilinear_cases.py --in vectors/patterns/grad_32x32.raw --w 32 --h 32 --scale 0.5 --out results/bilinear_cases_grad32_s05.csv

unit_csv: coords_csv bilinear_csv
	@echo "csv unitarios listos en results/"

all_ok: dirs gen_vectors golden_all tb_top compare_top meta_sw perf_summary report
	@echo "listo todo"

.PHONY: simd_run simd_check

# corre la simulacion SIMD y genera results/out_hw_simd.raw
simd_run:
	@if command -v iverilog >/dev/null 2>&1; then \
		iverilog -g2012 -o tb_top_simd_tb \
		  tb/top/tb_top_simd.sv \
		  tb/rtl/bilinear_top.sv \
		  tb/rtl/bilinear_core_scalar.sv \
		  tb/rtl/bilinear_core_simd.sv && \
		vvp tb_top_simd_tb; \
	else \
		echo "no hay iverilog instalado, se omite simd_run"; \
	fi

# compara salida SIMD contra golden (32x32 con escala 0.5)
simd_check:
	@W2=`$(PY) scripts/calc_dims.py --w 32 --h 32 --scale 0.5 | cut -d' ' -f1`; \
	H2=`$(PY) scripts/calc_dims.py --w 32 --h 32 --scale 0.5 | cut -d' ' -f2`; \
	$(PY) pc/compare.py --wa $$W2 --ha $$H2 --wb $$W2 --hb $$H2 \
	  --a results/out_hw_simd.raw \
	  --b vectors/golden/grad_32_s05.raw

.PHONY: sim_scalar_run sim_scalar_check

# corre la simulacion del core secuencial y genera results/out_hw.raw
sim_scalar_run:
	@if command -v iverilog >/dev/null 2>&1; then \
		iverilog -g2012 -o tb_top_scalar_tb \
		  tb/top/tb_top_scalar.sv \
		  tb/rtl/bilinear_top.sv \
		  tb/rtl/bilinear_core_scalar.sv \
		  tb/rtl/bilinear_core_simd.sv && \
		vvp tb_top_scalar_tb; \
	else \
		echo "no hay iverilog instalado, se omite sim_scalar_run"; \
	fi

# compara salida escalar contra golden (32x32 con escala 0.5)
sim_scalar_check:
	@W2=`$(PY) scripts/calc_dims.py --w 32 --h 32 --scale 0.5 | cut -d' ' -f1`; \
	H2=`$(PY) scripts/calc_dims.py --w 32 --h 32 --scale 0.5 | cut -d' ' -f2`; \
	$(PY) pc/compare.py --wa $$W2 --ha $$H2 --wb $$W2 --hb $$H2 \
	  --a results/out_hw.raw \
	  --b vectors/golden/grad_32_s05.raw

.PHONY: verify_all

verify_all:
	$(PY) tests/run_all_tests.py

.PHONY: golden_cpp

golden_cpp:
	./downscale_ref_cpp --in vectors/patterns/grad_32x32.raw \
	  --w 32 --h 32 --scale 0.5 \
	  --out-raw results/out_cpp_s05.raw \
	  --out-pgm results/out_cpp_s05.pgm
