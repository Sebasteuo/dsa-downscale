#!/usr/bin/env python3
"""
Corre todas las pruebas de verificacion que tenemos del lado de PC y simulacion.
No toca FPGA, pero valida:
 - modelo de referencia
 - generacion de CSV
 - core secuencial en simulacion
 - core SIMD en simulacion
"""

import subprocess

PY = "python3"

def run(cmd):
    print(">>", cmd)
    subprocess.check_call(cmd, shell=True)

def main():
    print("== Pruebas golden del modelo (python) ==")
    run("make golden_all")

    print("== Generar CSV para unitarios ==")
    run("make unit_csv")

    # si tenes los tests unitarios en Python (modelo y CSV), los podés llamar aquí
    # ejemplo:
    # run(f"{PY} tests/test_model_units.py")
    # run(f"{PY} tests/test_csv_units.py")

    print("== Simulacion core secuencial y comparacion ==")
    run("make sim_scalar_run")
    run("make sim_scalar_check")

    print("== Simulacion core SIMD y comparacion ==")
    run("make simd_run")
    run("make simd_check")

    print("== Suite de verificacion completada sin errores ==")

if __name__ == "__main__":
    main()
