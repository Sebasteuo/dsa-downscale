# Smoke test MODO 1 (downscale) para varias escalas:
#   - IMG 16x16
#   - scale = 0.5  (0x0080)
#   - scale = 0.75 (0x00C0)
#
# Genera golden en PC usando el mismo Bresenham que el core.

# 1) Obtener master JTAG
set masters [get_service_paths master]
puts "Masters disponibles: $masters"

if {[llength $masters] == 0} {
    puts "ERROR: No se encontró servicio master."
    return
}

set mp [claim_service master [lindex $masters 0] "dsa_jtag_downscale_mode1_scales"]
puts "Usando master: $mp"

# Base address del esclavo
set BASE_ADDR 0x00000000

# 2) Funciones auxiliares acceso registro
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

# 5) Construir patrón de entrada (igual que copia)
#    pattern[i] = palabra con el byte (i & 0xFF) repetido 4 veces
set pattern {}
for {set i 0} {$i < $total_words} {incr i} {
    set b [expr {$i & 0xFF}]
    set w [expr {($b << 24) | ($b << 16) | ($b << 8) | $b}]
    lappend pattern $w
}

# 6) Función: calcula out_w, out_h como en el core
#    out_w = floor(img_w * scale_q8_8 / 256), clamp y >=1
proc compute_out_dims {img_w img_h scale_q8_8 img_max_w img_max_h} {
    # ow_full = img_w * scale
    set ow_full [expr {$img_w * $scale_q8_8}]
    set oh_full [expr {$img_h * $scale_q8_8}]

    # >> 8 (Q8.8)
    set ow [expr {$ow_full >> 8}]
    set oh [expr {$oh_full >> 8}]

    if {$ow < 1} { set ow 1 }
    if {$oh < 1} { set oh 1 }

    if {$ow > $img_max_w} { set ow $img_max_w }
    if {$oh > $img_max_h} { set oh $img_max_h }

    if {$ow > $img_w} { set ow $img_w }
    if {$oh > $img_h} { set oh $img_h }

    return [list $ow $oh]
}

# 7) Función: genera golden_words usando Bresenham como el core
proc generate_golden_downscale {img_w img_h scale_q8_8 img_max_w img_max_h} {
    # 7.1) Calcular dimensiones de salida
    set dims [compute_out_dims $img_w $img_h $scale_q8_8 $img_max_w $img_max_h]
    set out_w [lindex $dims 0]
    set out_h [lindex $dims 1]

    puts "  [format "Golden: out_w=%d, out_h=%d" $out_w $out_h]"

    # 7.2) Generar píxeles de salida (0..255) siguiendo Bresenham
    set out_pixels {}

    set in_y  0
    set err_y 0

    for {set y 0} {$y < $out_h} {incr y} {
        set in_x  0
        set err_x 0

        for {set x 0} {$x < $out_w} {incr x} {
            # índice de píxel de entrada
            set src_index   [expr {$in_y * $img_w + $in_x}]
            set src_word_idx [expr {$src_index >> 2}]

            # valor de píxel = (word_idx & 0xFF) porque todos los bytes son iguales
            set pix_val [expr {$src_word_idx & 0xFF}]
            lappend out_pixels $pix_val

            # Bresenham horizontal: err_x += img_w; while err_x >= out_w { err_x -= out_w; in_x++ }
            set err_x [expr {$err_x + $img_w}]
            while {$err_x >= $out_w} {
                set err_x [expr {$err_x - $out_w}]
                incr in_x
            }
        }

        # Bresenham vertical: err_y += img_h; while err_y >= out_h { err_y -= out_h; in_y++ }
        set err_y [expr {$err_y + $img_h}]
        while {$err_y >= $out_h} {
            set err_y [expr {$err_y - $out_h}]
            incr in_y
        }
    }

    # 7.3) Empaquetar píxeles en palabras de 32 bits (4 bytes)
    set golden_words {}
    set curr_word 0
    set byte_pos 0

    foreach p $out_pixels {
        set p8 [expr {$p & 0xFF}]
        set shift [expr {$byte_pos * 8}]
        set curr_word [expr {$curr_word | ($p8 << $shift)}]

        if {$byte_pos == 3} {
            lappend golden_words $curr_word
            set curr_word 0
            set byte_pos 0
        } else {
            incr byte_pos
        }
    }

    # Si quedaron píxeles "sueltos" en el último word, lo agregamos igual (con ceros en bytes altos)
    if {$byte_pos != 0} {
        lappend golden_words $curr_word
    }

    return [list $golden_words $out_w $out_h]
}

# 8) Función: ejecuta un test para una escala dada
proc run_scale_test {mp base_addr img_w img_h scale_q8_8} {
    global REG_CTRL REG_STATUS REG_IMG_W REG_IMG_H REG_SCALE REG_MODE
    global REG_PERF_CYC REG_PERF_PIX REG_IN_ADDR REG_IN_DATA REG_OUT_ADDR REG_OUT_DATA
    global pattern

    # IMG_MAX_W/H en esta versión del core (ajusta si cambias el parámetro del HDL)
    set IMG_MAX_W 64
    set IMG_MAX_H 64

    puts "\n==================================================="
    puts [format "Test MODO 1 - scale=0x%08X" $scale_q8_8]
    puts "==================================================="

    # 8.1) Programar registros básicos
    reg_write $mp $base_addr $REG_IMG_W  $img_w
    reg_write $mp $base_addr $REG_IMG_H  $img_h
    reg_write $mp $base_addr $REG_SCALE  $scale_q8_8
    reg_write $mp $base_addr $REG_MODE   0x00000001   ;# mode[0] = 1 => downscale

    # 8.2) Escribir patrón en BRAM de entrada
    set total_words [llength $pattern]
    puts "  Escribiendo BRAM de entrada con $total_words palabras..."
    reg_write $mp $base_addr $REG_IN_ADDR 0

    set idx 0
    foreach w $pattern {
        reg_write $mp $base_addr $REG_IN_DATA $w
        incr idx
    }
    puts "  Escritura completa de $idx palabras."

    # 8.3) Generar golden en PC
    set golden_res [generate_golden_downscale $img_w $img_h $scale_q8_8 $IMG_MAX_W $IMG_MAX_H]
    set golden_words [lindex $golden_res 0]
    set out_w        [lindex $golden_res 1]
    set out_h        [lindex $golden_res 2]

    set golden_words_count [llength $golden_words]
    set out_pix [expr {$out_w * $out_h}]

    puts "  Golden: out_pix=$out_pix, golden_words=$golden_words_count"

    # 8.4) Lanzar operación en el core
    reg_write $mp $base_addr $REG_OUT_ADDR 0
    reg_write $mp $base_addr $REG_CTRL 0x00000001   ;# START

    puts "  Esperando DONE..."
    while {1} {
        set status [reg_read $mp $base_addr $REG_STATUS]
        set busy   [expr {$status & 0x1}]
        set done   [expr {($status >> 1) & 0x1}]
        if {$done == 1 && $busy == 0} {
            break
        }
        after 50
    }
    puts "  Core DONE."

    # 8.5) Leer PERF_PIX / PERF_CYC
    set perf_pix [reg_read $mp $base_addr $REG_PERF_PIX]
    set perf_cyc [reg_read $mp $base_addr $REG_PERF_CYC]

    puts "  PERF_PIX = $perf_pix (esperado ~ $out_pix)"
    puts "  PERF_CYC = $perf_cyc"

    # 8.6) Leer salida y comparar con golden
    set ok 1
    reg_write $mp $base_addr $REG_OUT_ADDR 0

    puts "  Leyendo y verificando $golden_words_count palabras de salida..."

    for {set i 0} {$i < $golden_words_count} {incr i} {
        set w_out [reg_read $mp $base_addr $REG_OUT_DATA]
        set w_exp [lindex $golden_words $i]

        if {$w_out != $w_exp} {
            puts "  ERROR: mismatch palabra $i: out=0x[format %08X $w_out], exp=0x[format %08X $w_exp]"
            set ok 0
            # Para parar en primer error, descomenta:
            # break
        }
    }

    if {$ok} {
        puts "  ==> OK - scale=0x[format %08X $scale_q8_8]: salida coincide con golden."
    } else {
        puts "  ==> FAIL - scale=0x[format %08X $scale_q8_8]: hubo mismatches."
    }

    return $ok
}

# 9) Ejecutar tests para varias escalas
set all_ok 1

# scale = 0.5 (Q8.8 = 0x0080)
set ok_05 [run_scale_test $mp $BASE_ADDR $img_w $img_h 0x00000080]
if {!$ok_05} { set all_ok 0 }

# scale = 0.75 (Q8.8 = 0x00C0)
set ok_075 [run_scale_test $mp $BASE_ADDR $img_w $img_h 0x000000C0]
if {!$ok_075} { set all_ok 0 }

if {$all_ok} {
    puts "\nOK - Smoke test MODO 1 (0.5 y 0.75): todas las escalas pasaron."
} else {
    puts "\nFAIL - Smoke test MODO 1 (0.5 y/o 0.75 tuvieron errores)."
}

close_service master $mp
