# DSA Downscale – Proyecto 2 CE-4302

Acelerador sencillo para downscaling bilineal de imágenes en escala de grises sobre FPGA Cyclone V (DE1-SoC).  
Incluye modelo de referencia en Python y C++, núcleo escalar y núcleo SIMD en RTL, y entorno de pruebas por JTAG.

---

## 1. Requisitos

### Software en PC

- Linux  
- Python 3  
  - Paquetes  
    - numpy  
    - Pillow para convertir PNG a RAW  
    - Ejemplo  
      pip install pillow
      
- Compilador C++  
  - Probado con g++  
- Icarus Verilog (iverilog) para simulación RTL  
- Intel Quartus Prime (Standard o Lite) con System Console y Programmer  
  - Versión usada en las pruebas: 25.x 

### Hardware

- Tarjeta DE1-SoC (Cyclone V)  
- Cable USB-Blaster II para JTAG

---

## 2. Estructura del repositorio

- model/  
  - downscale_ref.py  
    - Modelo de referencia en Python  
  - downscale_ref_cpp.cpp  
    - Modelo de referencia en C++  
  - utils.py  
    - Funciones para leer y escribir imágenes RAW y PGM

- vectors/  
  - patterns/  
    - Patrones de prueba en RAW  
  - golden/  
    - Salidas golden del modelo

- scripts/  
  - Herramientas de apoyo  
    - calc_dims.py  
    - make_golden.py  
    - gen_coords_csv.py  
    - gen_bilinear_cases.py  
    - png_to_raw_32.py  
    - diff_pixels.py

- pc/  
  - compare.py  
    - Comparador de imágenes RAW  
  - summarize_perf.py  
    - Resumen de meta datos y rendimiento

- tb/rtl/  
  - bilinear_core_scalar.sv  
  - bilinear_core_simd.sv  
  - bilinear_top.sv

- tb/top/  
  - tb_top_scalar.sv  
  - tb_top_simd.sv  
  - Testbenches de alto nivel para simulación

- tb/JTAG/dsa/quartus/  
  - Proyecto Quartus para la DE1-SoC  
  - RTL de integración con JTAG

- tb/JTAG/dsa/pc/  
  - dsa_jtag_driver.cpp  
    - Driver C++ para correr pruebas en la FPGA vía JTAG  
  - entrada_16x16.raw, entrada_32x32.raw  
    - Imágenes de entrada de prueba

---

## 3. Compilación del modelo de referencia en C++

Desde la raíz del repo

```bash

g++ -std=c++17 -O2 -o downscale_ref_cpp model/downscale_ref_cpp.cpp
```
Prueba rápida

```bash
./downscale_ref_cpp \
  --in vectors/patterns/grad_32x32.raw \
  --w 32 --h 32 --scale 0.5 \
  --out-raw results/out_cpp_s05.raw \
  --out-pgm results/out_cpp_s05.pgm
```

## 4. Simulación RTL y verificación en PC
Desde la raíz del repo

### 4.1 Generar patrones y golden
```bash
make golden_all      # genera golden del modelo
make unit_csv        # genera CSV de coordenadas y casos bilineales
``` 

### 4.2 Simular core escalar
```bash
make sim_scalar_run   # corre tb_top_scalar.sv
make sim_scalar_check # compara out_hw.raw vs golden
```

### 4.3 Simular core SIMD
```bash
make simd_run         # corre tb_top_simd.sv
make simd_check       # compara out_hw_simd.raw vs golden
```

### 4.4 Suite completa de verificación
```bash
make verify_all
```
Este comando ejecuta golden, CSV y las simulaciones de los cores escalar y SIMD y muestra al final un mensaje de éxito si todas las comparaciones bit a bit pasan.

## 5. Compilación y Síntesis en Quartus para la DE1-SoC

Primero se debe conectar el cable JTAG (USB a Blaster II)

### 5.1 Abrir proyecto en Quartus

Abrir tb/JTAG/dsa/quartus/dsa_top_jtag.qpf

Asegurar que

El dispositivo sea el de la DE1-SoC Cyclone V

El top level sea dsa_top_jtag

### 5.2 Compilar en Quartus

Menú Processing → Start Compilation

Al final de la compilación se genera el bitstream (Archivo .sof)

tb/JTAG/dsa/quartus/output_files/dsa_top_jtag.sof

## 6. Programación de la FPGA (DE1-SoC)
Con la tarjeta conectada por USB-Blaster II

Abrir Quartus Programmer

Seleccionar el archivo .sof generado

Seleccionar el dispositivo FPGA de la DE1-SoC

Hacer clic en Start para programar la FPGA

## 7. Ejecución del sistema vía JTAG
Estas pruebas se ejecutan desde un PC que tenga instalado Quartus con System Console y acceso JTAG a la DE1-SoC.

### 7.1 Compilar dsa_jtag_driver.cpp 

Volver a compilar el driver

```bash
cd tb/JTAG/dsa/pc
g++ -std=c++17 -O2 -o dsa_jtag_driver dsa_jtag_driver.cpp
```
## 7.2 Prueba 16x16 (smoke test funcional)
```bash
./dsa_jtag_driver 16 16 0x00000100 \
  entrada_16x16.raw \
  salida_16x16.raw
```
Esta prueba

Carga entrada_16x16.raw en la BRAM de entrada

Configura escala 1.0 en Q8.8

Ejecuta el núcleo escalar en la FPGA

Lee la salida salida_16x16.raw

Compara contra la referencia bilineal en C++

## 7.3 Prueba 32x32
```bash
./dsa_jtag_driver 32 32 0x00000100 \
  entrada_32x32.raw \
  salida_32x32.raw
 ```
En el futuro se pueden correr pruebas con otras escalas

```bash
# escala 0.5 (0x0080 en Q8.8)
./dsa_jtag_driver 32 32 0x00000080 \
  entrada_32x32.raw \
  salida_32x32_05.raw
```
El programa muestra

Tamaño de la imagen de entrada

Valores de PERF_CYC y PERF_PIX de la FPGA

Mensaje [OK] si la salida de hardware coincide bit a bit con la referencia bilineal en C++

## 8. Notas sobre los modos escalar y SIMD
El core escalar está sintetizado en el top dsa_top_jtag y probado en la DE1-SoC para tamaños hasta 32x32.

El core SIMD está implementado y verificado en simulación RTL con simd_run y simd_check.
Por limitaciones de recursos de la FPGA actual, el bitstream de esta entrega incluye solo el núcleo escalar.
El modo SIMD se deja validado en simulación y documentado en el informe como trabajo futuro para hardware real.