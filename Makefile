PY=python3

help:
	@echo "make help"
	@echo "make gen_example   crea un gradiente 8x8 en RAW"
	@echo "make golden        ejecuta el modelo y genera salida RAW y PGM"
	@echo "make compare_self  compara un archivo contra sí mismo"

gen_example:
	$(PY) model/img2raw.py --w 8 --h 8 --pattern grad --out vectors/patterns/grad_8x8.raw

golden: gen_example
	$(PY) model/downscale_ref.py --in vectors/patterns/grad_8x8.raw --w 8 --h 8 --scale 0.5 --out-raw vectors/golden_grad_8x8_s05.raw --out-pgm vectors/golden_grad_8x8_s05.pgm

compare_self:
	$(PY) pc/compare.py --wa 8 --ha 8 --wb 8 --hb 8 --a vectors/patterns/grad_8x8.raw --b vectors/patterns/grad_8x8.raw
