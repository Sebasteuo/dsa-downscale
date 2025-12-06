# Test sencillo para dsa_top_seq con bilinear_core_scalar.
# - Usa el bus Avalon expuesto por JTAG master.

# 1) Parseo de argumentos
set raw_args $argv
puts "Args recibidos: $raw_args"

if {[llength $raw_args] != 6} {
    puts "Uso:"
    puts "  system-console --project-dir <ruta_qpf> \\"
    puts "    --script=dsa_jtag_test_16x16_raw.tcl -- \\"
    puts "    <img_w> <img_h> <scale_q8_8> <entrada.raw> <salida.raw>"
    return
}

set in_raw  [lindex $raw_args 4]
set out_raw [lindex $raw_args 5]

set img_w       [lindex $raw_args 1]
set img_h       [lindex $raw_args 2]
set scale_q8_8  [lindex $raw_args 3]

puts "Parametros:"
puts "  img_w      = $img_w"
puts "  img_h      = $img_h"
puts "  scale_q8_8 = [format {0x%08X} $scale_q8_8]"
puts "  input RAW  = $in_raw"
puts "  output RAW = $out_raw"
puts "------------------------------------------------"

# 2) Cargar paquete master y obtener master JTAG

set masters [get_service_paths master]
puts "Masters disponibles: $masters"

if {[llength $masters] == 0} {
    puts "ERROR: No se encontró servicio master."
    return
}

set mp [claim_service master [lindex $masters 0] "dsa_jtag_master"]
puts "Usando master: $mp"

set BASE_ADDR 0x00000000

# 3) Funciones auxiliares para leer/escribir registros
proc reg_write {mp base_idx reg_idx value} {
    set addr [expr {$base_idx + 4 * $reg_idx}]
    master_write_32 $mp $addr [list $value]
}

proc reg_read {mp base_idx reg_idx} {
    set addr [expr {$base_idx + 4 * $reg_idx}]
    set data [master_read_32 $mp $addr 1]
    return [lindex $data 0]
}

# 4) Mapa de registros
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

# 5) Leer archivo RAW de entrada
if {![file exists $in_raw]} {
    puts "ERROR: archivo de entrada '$in_raw' no existe."
    close_service master $mp
    return
}

set fd [open $in_raw "rb"]
fconfigure $fd -translation binary -encoding binary
set raw_data [read $fd]
close $fd

set in_size [string length $raw_data]
set expected_size [expr {$img_w * $img_h}]

puts "RAW de entrada: $in_size bytes (esperado $expected_size)"

if {$in_size != $expected_size} {
    puts "ADVERTENCIA: el tamaño del RAW no coincide con img_w*img_h."
}

# Convertir a lista de bytes (0..255)
binary scan $raw_data cu* in_bytes
set num_pixels [llength $in_bytes]
puts "Total píxeles: $num_pixels"

set total_words [expr {($num_pixels + 3) / 4}]
puts "Total palabras (32 bits): $total_words"

# 6) Configurar registros de imagen y escala
reg_write $mp $BASE_ADDR $REG_IMG_W   $img_w
reg_write $mp $BASE_ADDR $REG_IMG_H   $img_h
reg_write $mp $BASE_ADDR $REG_SCALE   $scale_q8_8
reg_write $mp $BASE_ADDR $REG_MODE    0x00000000  

# 7) Escribir BRAM de entrada (in_mem) vía IN_ADDR / IN_DATA
puts "Escribiendo BRAM de entrada con $total_words palabras..."
reg_write $mp $BASE_ADDR $REG_IN_ADDR 0

set idx 0
for {set w 0} {$w < $total_words} {incr w} {
    set b0 0
    set b1 0
    set b2 0
    set b3 0

    if {$idx < $num_pixels} {
        set b0 [lindex $in_bytes $idx]
        #puts "bit $idx: $b0"
        incr idx
    }
    if {$idx < $num_pixels} {
        set b1 [lindex $in_bytes $idx]
        #puts "bit $idx: $b1"
        incr idx
    }
    if {$idx < $num_pixels} {
        set b2 [lindex $in_bytes $idx]
        #puts "bit $idx: $b2"
        incr idx
    }
    if {$idx < $num_pixels} {
        set b3 [lindex $in_bytes $idx]
        #puts "bit $idx: $b3"
        incr idx
    }

    # Construimos palabra 0xAABBCCDD como: b3 b2 b1 b0
    set word [expr {($b3 << 24) | ($b2 << 16) | ($b1 << 8) | $b0}]
    #puts "palabra $w: $word"
    reg_write $mp $BASE_ADDR $REG_IN_DATA $word
}

puts "Escritura de BRAM de entrada completa."

# 8) Lanzar operación (START) y esperar DONE
set status_init [reg_read $mp $BASE_ADDR $REG_STATUS]
puts "STATUS inicial = [format {0x%08X} $status_init]"

puts "Esperando DONE..."
reg_write $mp $BASE_ADDR $REG_CTRL 0x00000001   ;# bit0 = START

while {1} {
    set status [reg_read $mp $BASE_ADDR $REG_STATUS]
    set busy   [expr {$status & 0x1}]
    set done   [expr {($status >> 1) & 0x1}]
    if {$done == 1 && $busy == 0} {
        break
    }
    after 10
}

set status_final [reg_read $mp $BASE_ADDR $REG_STATUS]
set perf_cyc     [reg_read $mp $BASE_ADDR $REG_PERF_CYC]
set perf_pix     [reg_read $mp $BASE_ADDR $REG_PERF_PIX]

puts "Core terminó. STATUS final = [format {0x%08X} $status_final]"
puts "PERF_CYC = [format {0x%08X} $perf_cyc] ciclos"
puts "PERF_PIX = [format {0x%08X} $perf_pix] píxeles de salida"

# Número de palabras de salida a leer (en base a PERF_PIX)
set out_pixels $perf_pix
if {$out_pixels == 0} {
    puts "ADVERTENCIA: PERF_PIX = 0, nada que leer."
    set out_words 0
} else {
    set out_words [expr {($out_pixels + 3)}]
}
puts "Lectura de salida: $out_pixels píxeles, $out_words palabras."

# 9) Leer BRAM de salida (out_mem) y escribir RAW de salida
reg_write $mp $BASE_ADDR $REG_OUT_ADDR 0

set out_bytes {}
for {set w 0} {$w < $out_words} {incr w} {
    set word [reg_read $mp $BASE_ADDR $REG_OUT_DATA]

    # Extraer 4 bytes little-endian
    set b0 [expr {$word        & 0xFF}]

    lappend out_bytes $b0 
}

# Recortar a EXACTAMENTE out_pixels
set out_bytes [lrange $out_bytes 0 [expr {$out_pixels - 1}]]

# Volcar a archivo binario
set out_fd [open $out_raw "wb"]
fconfigure $out_fd -translation binary -encoding binary

set out_blob ""
foreach b $out_bytes {
    append out_blob [binary format c [expr {$b & 0xFF}]]
}
puts -nonewline $out_fd $out_blob
close $out_fd

puts "Archivo de salida escrito: $out_raw"
puts "Hecho."

# 10) Liberar master
close_service master $mp
