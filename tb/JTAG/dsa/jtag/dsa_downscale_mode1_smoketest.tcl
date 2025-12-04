# Smoke test modo 1 (downscale) con escala 1.0
# - IMG_W = IMG_H = 16
# - scale_q8_8 = 0x0100  => escala 1.0
# - mode[0] = 1          => modo downscale
# En este caso el mapeo debe ser identidad: salida == entrada.

# 1) Obtener master JTAG
set masters [get_service_paths master]
puts "Masters disponibles: $masters"

if {[llength $masters] == 0} {
    puts "ERROR: No se encontró servicio master."
    return
}

set mp [claim_service master [lindex $masters 0] "dsa_jtag_downscale_mode1"]
puts "Usando master: $mp"

# Base address del esclavo
set BASE_ADDR 0x00000000

# 2) Funciones auxiliares
proc reg_write {mp base_idx reg_idx value} {
    set addr [expr {$base_idx + 4 * $reg_idx}]
    master_write_32 $mp $addr [list $value]
}

proc reg_read {mp base_idx reg_idx} {
    set addr [expr {$base_idx + 4 * $reg_idx}]
    set data [master_read_32 $mp $addr 1]
    return [lindex $data 0]
}

# 3) Mapa de registros
set REG_CTRL      0x0000
set REG_STATUS    0x0001
set REG_IMG_W     0x0002
set REG_IMG_H     0x0003
set REG_SCALE     0x0004
set REG_MODE      0x0005
set REG_PERF_CYC  0x0006
set REG_PERF_PIX  0x0007

set REG_IN_ADDR   0x0020
set REG_IN_DATA   0x0021
set REG_OUT_ADDR  0x0030
set REG_OUT_DATA  0x0031

# 4) Parámetros de la imagen de prueba
set img_w 16
set img_h 16

set total_pix   [expr {$img_w * $img_h}]        ;# 256
set total_words [expr {($total_pix + 3) / 4}]   ;# 64

puts "Imagen ${img_w}x${img_h}: $total_pix pix, $total_words palabras."

# 5) Escribir parámetros básicos en registros
#    Modo 1 (downscale), escala 1.0
reg_write $mp $BASE_ADDR $REG_IMG_W  $img_w
reg_write $mp $BASE_ADDR $REG_IMG_H  $img_h
reg_write $mp $BASE_ADDR $REG_SCALE  0x000000C0  
reg_write $mp $BASE_ADDR $REG_MODE   0x00000001  

# 6) Construir patrón de entrada
#    pattern[i] = palabra con el byte (i & 0xFF) repetido 4 veces
set pattern {}
for {set i 0} {$i < $total_words} {incr i} {
    set b [expr {$i & 0xFF}]
    set w [expr {($b << 24) | ($b << 16) | ($b << 8) | $b}]
    lappend pattern $w
}

# 7) Escribir patrón completo en BRAM de entrada
puts "Escribiendo BRAM de entrada con $total_words palabras..."
reg_write $mp $BASE_ADDR $REG_IN_ADDR 0

set idx 0
foreach w $pattern {
    reg_write $mp $BASE_ADDR $REG_IN_DATA $w
    incr idx
}
puts "Escritura completa de $idx palabras."

# 8) Lanzar el procesamiento en modo 1
# Reiniciar puntero de salida
reg_write $mp $BASE_ADDR $REG_OUT_ADDR 0

# CTRL bit0 = START
reg_write $mp $BASE_ADDR $REG_CTRL 0x00000001

# Esperar DONE
puts "Esperando a que termine el core (modo 1, escala 1.0)..."
while {1} {
    set status [reg_read $mp $BASE_ADDR $REG_STATUS]
    set busy   [expr {$status & 0x1}]
    set done   [expr {($status >> 1) & 0x1}]
    if {$done == 1 && $busy == 0} {
        break
    }
    after 50
}

puts "Core reporta DONE."

# 9) Leer PERF_PIX y PERF_CYC
set perf_pix [reg_read $mp $BASE_ADDR $REG_PERF_PIX]
set perf_cyc [reg_read $mp $BASE_ADDR $REG_PERF_CYC]

puts "PERF_PIX = $perf_pix (esperado ~ $total_pix = $total_pix)"
puts "PERF_CYC = $perf_cyc"

# 10) Leer BRAM de salida y comparar con el patrón original
set ok 1

# Asegurar que OUT_ADDR empieza en 0
reg_write $mp $BASE_ADDR $REG_OUT_ADDR 0

puts "Leyendo y verificando $total_words palabras de salida..."

for {set i 0} {$i < $total_words} {incr i} {
    set w_out [reg_read $mp $BASE_ADDR $REG_OUT_DATA]
    set w_exp [lindex $pattern $i]

    if {$w_out != $w_exp} {
        puts "ERROR: mismatch en palabra $i: out=0x[format %08X $w_out], exp=0x[format %08X $w_exp]"
        set ok 0
        # Si quieres parar en el primer error, descomenta:
        # break
    }
}

if {$ok} {
    puts "\nOK - Smoke test MODO 1 (downscale, escala 1.0): salida == entrada."
} else {
    puts "\nFAIL - Smoke test MODO 1: hubo mismatches."
}

close_service master $mp
