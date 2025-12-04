// dsa_jtag_driver.cpp
//
// Wrapper en C++ para:
//  - ejecutar el downscale de referencia en CPU (modelo "igual" al core HW),
//  - llamar a system-console + Tcl para ejecutar el core en FPGA,
//  - comparar la salida HW vs referencia (píxel a píxel).
//
// Uso:
//   ./dsa_jtag_driver <img_w> <img_h> <scale_hex> <in_raw> <out_hw_raw>
//
// Ejemplo:
//   ./dsa_jtag_driver 32 32 0x000000C0 ../pc/entrada_32x32.raw ../pc/salida_32x32_075.raw
//
// NOTA: ajusta SC_BIN, PROJ_DIR y TCL_SCRIPT a tu entorno real.

#include <iostream>
#include <fstream>
#include <vector>
#include <string>
#include <sstream>
#include <iomanip>
#include <cstdint>
#include <cstdlib>
#include <stdexcept>

// -----------------------------------------------------------------------------
// CONFIGURACIÓN: ajusta estas rutas a tu entorno
// -----------------------------------------------------------------------------

// Ruta al system-console (ya probada por ti)
static const std::string SC_BIN =
    "/home/hack/altera_lite/25.1std/quartus/sopc_builder/bin/system-console";

// Directorio del proyecto Quartus (donde está el .qpf)
static const std::string PROJ_DIR =
    "../dsa/quartus";

// Ruta al script Tcl (desde donde se ejecuta este binario)
static const std::string TCL_SCRIPT =
    "../jtag/dsa_jtag_downscale_raw.tcl";

// Límite actual del core en HW (ahora mismo tu dsa_top_seq usa 64x64)
static const int HW_IMG_MAX_W = 64;
static const int HW_IMG_MAX_H = 64;

// -----------------------------------------------------------------------------
// Utilidades para RAW
// -----------------------------------------------------------------------------

// Lee un .raw de w*h bytes (8 bits por píxel, gris)
// Si el archivo tiene menos bytes, rellena con 0 y avisa.
std::vector<uint8_t> load_raw(const std::string &path, int w, int h)
{
    int total = w * h;
    std::vector<uint8_t> img(total, 0);

    std::ifstream f(path, std::ios::binary);
    if (!f)
    {
        std::cerr << "ERROR: no se pudo abrir " << path << " para lectura.\n";
        return img;
    }

    f.read(reinterpret_cast<char *>(img.data()), total);
    std::streamsize got = f.gcount();
    if (got < total)
    {
        std::cerr << "WARNING: RAW " << path
                  << " tiene solo " << got << " bytes, se rellenan con 0.\n";
    }
    return img;
}

// Escribe un .raw de w*h bytes
bool save_raw(const std::string &path, const std::vector<uint8_t> &img)
{
    std::ofstream f(path, std::ios::binary);
    if (!f)
    {
        std::cerr << "ERROR: no se pudo abrir " << path << " para escritura.\n";
        return false;
    }
    f.write(reinterpret_cast<const char *>(img.data()), img.size());
    return true;
}

// -----------------------------------------------------------------------------
// Modelo de referencia C++ "igual" al core HW (modo 1)
// -----------------------------------------------------------------------------

// Calcula out_w y out_h igual que en dsa_top_seq (modo 1)
static void compute_out_dims_hw_like(
    int img_w, int img_h, uint32_t scale_q8_8,
    int &out_w, int &out_h)
{
    if (img_w <= 0 || img_h <= 0)
        throw std::runtime_error("Dimensiones de imagen inválidas");

    // ow_full = img_w * scale_q8_8;  oh_full = img_h * scale_q8_8;
    uint32_t ow_full = static_cast<uint32_t>(img_w) * scale_q8_8;
    uint32_t oh_full = static_cast<uint32_t>(img_h) * scale_q8_8;

    // >> 8 (equivalente a tomar bits [23:8] en el HDL)
    int ow = static_cast<int>(ow_full >> 8);
    int oh = static_cast<int>(oh_full >> 8);

    // Evitar cero
    if (ow <= 0)
        ow = 1;
    if (oh <= 0)
        oh = 1;

    // Clamp contra límites del core
    if (ow > HW_IMG_MAX_W)
        ow = HW_IMG_MAX_W;
    if (oh > HW_IMG_MAX_H)
        oh = HW_IMG_MAX_H;

    // Clamp contra dimensiones reales de la imagen
    if (ow > img_w)
        ow = img_w;
    if (oh > img_h)
        oh = img_h;

    out_w = ow;
    out_h = oh;
}

// Modelo de referencia "literal" del modo 1 del core.
// Devuelve el buffer de salida y además retorna out_w/out_h por referencia.
std::vector<uint8_t> downscale_ref_hw_like(
    int img_w, int img_h,
    uint32_t scale_q8_8,
    const std::vector<uint8_t> &src,
    int &out_w,
    int &out_h)
{
    if (img_w <= 0 || img_h <= 0)
        throw std::runtime_error("Dimensiones inválidas");

    const int total_pix = img_w * img_h;
    if (static_cast<int>(src.size()) < total_pix)
    {
        std::cerr << "WARNING: src.size() < img_w*img_h, se asumirá 0 para faltantes.\n";
    }

    // Dimensiones de salida igual que en HW
    compute_out_dims_hw_like(img_w, img_h, scale_q8_8, out_w, out_h);

    std::vector<uint8_t> dst;
    dst.reserve(out_w * out_h);

    // Variables "clon" del HDL
    int ds_out_x = 0;
    int ds_out_y = 0;
    int ds_in_x = 0;
    int ds_in_y = 0;
    int err_x = 0;
    int err_y = 0;

    // Bucle equivalente a S_RUN (modo 1) pero trabajando a nivel de píxel
    while (true)
    {
        // 1) Muestreo: idx_in = ds_in_y * img_w + ds_in_x
        int idx_in = ds_in_y * img_w + ds_in_x;
        uint8_t pix = 0;

        if (idx_in >= 0 && idx_in < total_pix)
        {
            pix = src[idx_in];
        }
        else
        {
            // Si se sale del rango, colocamos 0; si esto pasa, es síntoma de bug HW.
            pix = 0;
        }

        dst.push_back(pix);

        // ¿Último píxel?
        bool last_pixel = (ds_out_y == out_h - 1) && (ds_out_x == out_w - 1);
        if (last_pixel)
        {
            break;
        }

        // ¿Fin de fila?
        bool end_row = (ds_out_x == out_w - 1);

        if (end_row)
        {
            // --- Fin de fila de salida ---

            // Reiniciar X de salida
            ds_out_x = 0;
            // Avanzar Y de salida
            ds_out_y += 1;

            // Reiniciar mapeo horizontal
            ds_in_x = 0;
            err_x = 0;

            // Bresenham vertical (igual estructura que en el HDL)
            int tmp_err_y = err_y + img_h;
            int tmp_in_y = ds_in_y;

            if (tmp_err_y >= out_h)
            {
                tmp_err_y -= out_h;
                tmp_in_y += 1;
                // Segundo paso opcional
                if (tmp_err_y >= out_h)
                {
                    tmp_err_y -= out_h;
                    tmp_in_y += 1;
                }
            }

            err_y = tmp_err_y;
            ds_in_y = tmp_in_y;
        }
        else
        {
            // --- Misma fila de salida ---
            ds_out_x += 1;

            // Bresenham horizontal
            int tmp_err_x = err_x + img_w;
            int tmp_in_x = ds_in_x;

            if (tmp_err_x >= out_w)
            {
                tmp_err_x -= out_w;
                tmp_in_x += 1;
                if (tmp_err_x >= out_w)
                {
                    tmp_err_x -= out_w;
                    tmp_in_x += 1;
                }
            }

            err_x = tmp_err_x;
            ds_in_x = tmp_in_x;
            // ds_in_y no cambia aquí
        }
    }

    return dst;
}

// -----------------------------------------------------------------------------
// Wrapper para llamar system-console + Tcl
// -----------------------------------------------------------------------------

bool run_system_console(
    int img_w, int img_h,
    const std::string &scale_hex,
    const std::string &in_raw,
    const std::string &out_raw)
{
    // Pasamos los argumentos igual que hacías a mano:
    //   system-console --project-dir PROJ_DIR --script=TCL_SCRIPT -- \
    //       PROJ_DIR img_w img_h scale_hex in_raw out_raw
    std::ostringstream cmd;
    cmd << "\"" << SC_BIN << "\""
        << " --project-dir " << "\"" << PROJ_DIR << "\""
        << " --script=" << "\"" << TCL_SCRIPT << "\""
        << " -- "
        << img_w << " "
        << img_h << " "
        << scale_hex << " "
        << in_raw << " "
        << out_raw;

    std::string cmd_str = cmd.str();
    std::cout << "[C++] Ejecutando system-console:\n"
              << cmd_str << "\n";

    int ret = std::system(cmd_str.c_str());
    if (ret != 0)
    {
        std::cerr << "ERROR: system-console devolvió código " << ret << "\n";
        return false;
    }
    return true;
}

// -----------------------------------------------------------------------------
// Comparación HW vs referencia
// -----------------------------------------------------------------------------

void compare_images(
    const std::vector<uint8_t> &ref,
    const std::vector<uint8_t> &hw,
    int out_w,
    int out_h)
{
    int total = std::min(ref.size(), hw.size());
    int mismatches = 0;

    for (int i = 0; i < total; ++i)
    {
        if (ref[i] != hw[i])
        {
            if (mismatches < 20)
            {
                int y = (out_w > 0) ? (i / out_w) : 0;
                int x = (out_w > 0) ? (i % out_w) : 0;
                std::cout << "Mismatch en pixel " << i
                          << " (x=" << x << ", y=" << y << "): "
                          << "REF=0x" << std::hex << std::setw(2) << std::setfill('0')
                          << (int)ref[i]
                          << " HW=0x" << std::setw(2)
                          << (int)hw[i]
                          << std::dec << "\n";
            }
            mismatches++;
        }
    }

    if (ref.size() != hw.size())
    {
        std::cout << "WARNING: tamaños distintos ref=" << ref.size()
                  << " hw=" << hw.size() << " (se comparó hasta min).\n";
    }

    if (mismatches == 0)
    {
        std::cout << "[OK] HW y referencia coinciden (" << out_w << "x" << out_h
                  << ", " << ref.size() << " píxeles).\n";
    }
    else
    {
        std::cout << "[FAIL] Se encontraron " << mismatches
                  << " mismatches (se muestran hasta 20).\n";
    }
}

// -----------------------------------------------------------------------------
// main
// -----------------------------------------------------------------------------

int main(int argc, char **argv)
{
    if (argc != 6)
    {
        std::cerr << "Uso:\n"
                  << "  " << argv[0]
                  << " <img_w> <img_h> <scale_hex> <in_raw> <out_hw_raw>\n\n"
                  << "Ejemplo:\n"
                  << "  " << argv[0]
                  << " 32 32 0x000000C0 ../pc/entrada_32x32.raw ../pc/salida_32x32_075.raw\n";
        return 1;
    }

    int img_w = std::atoi(argv[1]);
    int img_h = std::atoi(argv[2]);
    std::string scale_hex = argv[3];
    std::string in_raw = argv[4];
    std::string out_hw = argv[5];

    if (img_w <= 0 || img_h <= 0)
    {
        std::cerr << "ERROR: img_w e img_h deben ser positivos.\n";
        return 1;
    }
    if (img_w > HW_IMG_MAX_W || img_h > HW_IMG_MAX_H)
    {
        std::cerr << "ATENCIÓN: img_w/img_h exceden HW_IMG_MAX_W/H ("
                  << HW_IMG_MAX_W << "x" << HW_IMG_MAX_H << ").\n"
                  << "         El HW puede saturar o fallar, pero sigo.\n";
    }

    uint32_t scale_q8_8 = 0;
    try
    {
        scale_q8_8 = static_cast<uint32_t>(std::stoul(scale_hex, nullptr, 16));
    }
    catch (...)
    {
        std::cerr << "ERROR: no se pudo parsear scale_hex=" << scale_hex
                  << " como hexadecimal.\n";
        return 1;
    }

    std::cout << "-------------------------------------------------\n";
    std::cout << "Parámetros:\n";
    std::cout << "  img_w      = " << img_w << "\n";
    std::cout << "  img_h      = " << img_h << "\n";
    std::cout << "  scale_q8_8 = 0x" << std::hex << std::setw(8) << std::setfill('0')
              << scale_q8_8 << std::dec << "\n";
    std::cout << "  in_raw     = " << in_raw << "\n";
    std::cout << "  out_hw_raw = " << out_hw << "\n";
    std::cout << "-------------------------------------------------\n";

    // 1) Leer imagen de entrada
    auto src = load_raw(in_raw, img_w, img_h);

    // 2) Ejecutar modelo de referencia "igual al HW"
    int out_w_ref = 0, out_h_ref = 0;
    std::vector<uint8_t> ref_out;
    try
    {
        ref_out = downscale_ref_hw_like(
            img_w, img_h, scale_q8_8, src,
            out_w_ref, out_h_ref);
    }
    catch (const std::exception &e)
    {
        std::cerr << "ERROR en modelo de referencia: " << e.what() << "\n";
        return 1;
    }

    std::cout << "Referencia C++: out_w=" << out_w_ref
              << ", out_h=" << out_h_ref
              << ", pix=" << ref_out.size() << "\n";

    // Guardar también la referencia, si quieres
    std::string out_ref = out_hw + ".ref.raw";
    if (save_raw(out_ref, ref_out))
    {
        std::cout << "Referencia escrita en: " << out_ref << "\n";
    }

    // 3) Ejecutar HW vía system-console + Tcl
    if (!run_system_console(img_w, img_h, scale_hex, in_raw, out_hw))
    {
        std::cerr << "ERROR: fallo al invocar system-console.\n";
        return 1;
    }

    // 4) Leer la salida de HW (mismo tamaño que la referencia)
    auto hw_out = load_raw(out_hw, out_w_ref, out_h_ref);
    std::cout << "HW: leídos " << hw_out.size()
              << " bytes desde " << out_hw << "\n";

    // 5) Comparar HW vs referencia
    compare_images(ref_out, hw_out, out_w_ref, out_h_ref);

    return 0;
}
