# dsa_jtag_downscale_raw.tcl
# Uso (desde tb/JTAG/dsa/jtag):
#   /ruta/a/system-console \
#     --project-dir <ruta_al_qpf> \
#     --script=../jtag/dsa_jtag_downscale_raw.tcl -- \
#     <img_w> <img_h> <scale_hex> <in_raw> <out_raw>
#
# Ejemplo:
#   /home/hack/altera_lite/25.1std/quartus/sopc_builder/bin/system-console \
#     --project-dir ../../../../quartus/dsa \
#     --script=../jtag/dsa_jtag_downscale_raw.tcl -- \
#     16 16 0x00000100 ../pc/entrada_16x16.raw ../pc/salida_16x16.raw

# ------------------------------------------------------------
# 0) Parseo de argumentos (funciona tanto en quartus_stp como
#    en system-console: prueba primero quartus(args) y luego argv)
# ------------------------------------------------------------

set args_list {}

# Caso herramientas tipo quartus_stp (quartus(args))
if {[info exists ::quartus(args)] && [llength $::quartus(args)] > 0} {
    set args_list $::quartus(args)
}

# Caso System Console (argv)
if {[llength $args_list] == 0 && [info exists ::argv] && [llength $::argv] > 0} {
    set args_list $::argv
}

puts "Args brutos recibidos: $args_list"

# Si la primera palabra es "--", descártala
if {[llength $args_list] > 0 && [lindex $args_list 0] eq "--"} {
    set args_list [lrange $args_list 1 end]
}

if {[llength $args_list] != 6} {
    puts "Uso:"
    puts "  system-console --project-dir <ruta_al_qpf> \\"
    puts "      --script=dsa_jtag_downscale_raw.tcl -- \\"
    puts "      <img_w> <img_h> <scale_hex> <in_raw> <out_raw>"
    return
}

set img_w     [lindex $args_list 1]
set img_h     [lindex $args_list 2]
set scale_hex [lindex $args_list 3]
set in_raw    [lindex $args_list 4]
set out_raw   [lindex $args_list 5]

puts "Parametros:"
puts "  img_w      = $img_w"
puts "  img_h      = $img_h"
puts "  scale_q8_8 = $scale_hex"
puts "  input RAW  = $in_raw"
puts "  output RAW = $out_raw"
puts "------------------------------------------------"

# Convierte scale_hex (tipo 0x00000100) a entero Tcl
scan $scale_hex "%x" scale_q8_8

# ------------------------------------------------------------
# 1) Helpers de acceso a registros (JTAG master)
# ------------------------------------------------------------

# Base address Avalon del core (en tu diseño está en 0x0)
set BASE_ADDR 0x00000000

# Mapa de registros (índices de palabra)
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

proc reg_write {mp base_idx reg_idx value} {
    set addr [expr {$base_idx + 4 * $reg_idx}]
    master_write_32 $mp $addr [list $value]
}

proc reg_read {mp base_idx reg_idx} {
    set addr [expr {$base_idx + 4 * $reg_idx}]
    set data [master_read_32 $mp $addr 1]
    return [lindex $data 0]
}

# ------------------------------------------------------------
# 2) Conectar al master JTAG
# ------------------------------------------------------------

set masters [get_service_paths master]
puts "Masters disponibles: $masters"

if {[llength $masters] == 0} {
    puts "ERROR: No se encontró servicio master. ¿Está la FPGA programada?"
    return
}

# Si tienes varios masters, aquí podrías filtrar por nombre.
set mp [claim_service master [lindex $masters 0] "dsa_jtag_master"]
puts "Usando master: $mp"

# ------------------------------------------------------------
# 3) Leer archivo RAW de entrada (8 bits por píxel, gris)
# ------------------------------------------------------------

# img_w * img_h píxeles → ese número de bytes
set total_pix   [expr {$img_w * $img_h}]
set expected_b  $total_pix

set fh_in [open $in_raw "rb"]
fconfigure $fh_in -translation binary -encoding binary
set raw_data [read $fh_in]
close $fh_in

set num_bytes [string length $raw_data]
puts "RAW de entrada: $num_bytes bytes (esperado $expected_b)"

if {$num_bytes < $expected_b} {
    puts "WARNING: el RAW tiene menos bytes que img_w*img_h, se rellenará con 0."
} elseif {$num_bytes > $expected_b} {
    puts "WARNING: el RAW tiene más bytes que img_w*img_h, se ignorará el sobrante."
    set raw_data [string range $raw_data 0 [expr {$expected_b - 1}]]
    set num_bytes $expected_b
}

# ------------------------------------------------------------
# 4) Convertir bytes en palabras de 32 bits y escribir IN_MEM
# ------------------------------------------------------------

set total_words [expr {($expected_b + 3) / 4}]
puts "Total píxeles: $total_pix, total palabras: $total_words"

# Poner puntero de entrada a 0
reg_write $mp $BASE_ADDR $REG_IN_ADDR 0

set idx 0
for {set w 0} {$w < $total_words} {incr w} {
    set b0 0
    set b1 0
    set b2 0
    set b3 0

    if {$idx < $num_bytes} {
        scan [string index $raw_data $idx] %c b0
    }
    incr idx

    if {$idx < $num_bytes} {
        scan [string index $raw_data $idx] %c b1
    }
    incr idx

    if {$idx < $num_bytes} {
        scan [string index $raw_data $idx] %c b2
    }
    incr idx

    if {$idx < $num_bytes} {
        scan [string index $raw_data $idx] %c b3
    }
    incr idx

    # Píxel 0 en byte menos significativo (LSB)
    set word [expr {($b3 << 24) | ($b2 << 16) | ($b1 << 8) | $b0}]
    reg_write $mp $BASE_ADDR $REG_IN_DATA $word
}

puts "Escritura de BRAM de entrada completa."

# ------------------------------------------------------------
# 5) Programar registros del core y lanzar operación
# ------------------------------------------------------------

# IMG_W, IMG_H, SCALE y modo=1 (downscale)
reg_write $mp $BASE_ADDR $REG_IMG_W  $img_w
reg_write $mp $BASE_ADDR $REG_IMG_H  $img_h
reg_write $mp $BASE_ADDR $REG_SCALE  $scale_q8_8
reg_write $mp $BASE_ADDR $REG_MODE   0x00000001   ;# bit0=1 → modo 1 (downscale)

# Asegurarnos de estar en IDLE
set status [reg_read $mp $BASE_ADDR $REG_STATUS]
puts "STATUS inicial = 0x[format %08X $status]"

# Lanzar START
reg_write $mp $BASE_ADDR $REG_CTRL 0x00000001

# Esperar DONE
puts "Esperando DONE..."
while {1} {
    set status [reg_read $mp $BASE_ADDR $REG_STATUS]
    set busy   [expr {$status & 0x1}]
    set done   [expr {($status >> 1) & 0x1}]
    if {$done == 1 && $busy == 0} {
        break
    }
    after 10
}
puts "Core terminó. STATUS final = 0x[format %08X $status]"

# Leer performance
set perf_cyc [reg_read $mp $BASE_ADDR $REG_PERF_CYC]
set perf_pix [reg_read $mp $BASE_ADDR $REG_PERF_PIX]
puts "PERF_CYC = $perf_cyc ciclos"
puts "PERF_PIX = $perf_pix píxeles de salida"

# ------------------------------------------------------------
# 6) Leer BRAM de salida y generar RAW
# ------------------------------------------------------------

set out_pix    $perf_pix
set out_bytes  $out_pix
set out_words  [expr {($out_bytes + 3) / 4}]

puts "Lectura de salida: $out_pix píxeles, $out_words palabras."

# Poner OUT_ADDR en 0
reg_write $mp $BASE_ADDR $REG_OUT_ADDR 0

set out_bytes_list {}

for {set w 0} {$w < $out_words} {incr w} {
    set word [reg_read $mp $BASE_ADDR $REG_OUT_DATA]
    # Extraer bytes en el mismo orden: LSB = primer píxel
    set b0 [expr {$word        & 0xFF}]
    set b1 [expr {($word >> 8) & 0xFF}]
    set b2 [expr {($word >>16) & 0xFF}]
    set b3 [expr {($word >>24) & 0xFF}]
    lappend out_bytes_list $b0 $b1 $b2 $b3
}

# Recorta exactamente out_bytes
set out_bytes_list [lrange $out_bytes_list 0 [expr {$out_bytes - 1}]]

# Construir string binario
set out_str ""
foreach b $out_bytes_list {
    append out_str [format %c $b]
}

set fh_out [open $out_raw "wb"]
fconfigure $fh_out -translation binary -encoding binary
puts -nonewline $fh_out $out_str
close $fh_out

puts "Archivo de salida escrito: $out_raw"

# ------------------------------------------------------------
# 7) Cerrar master
# ------------------------------------------------------------
close_service master $mp

puts "Hecho."
