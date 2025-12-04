// dsa_jtag_driver.cpp
//
// Wrapper en C++ para:
//  - ejecutar el downscale de referencia en CPU (modelo bilineal igual al core),
//  - llamar a system-console + Tcl para ejecutar el core en FPGA,
//  - comparar la salida HW vs referencia (píxel a píxel).
//
// Uso:
//   ./dsa_jtag_driver <img_w> <img_h> <scale_hex> <in_raw> <out_hw_raw>
//
// Ejemplo:
//   ./dsa_jtag_driver 32 32 0x00000080 ../pc/entrada_32x32.raw ../pc/salida_32x32_05.raw
//
// NOTA: ajustar SC_BIN, PROJ_DIR y TCL_SCRIPT a tu entorno real.

#include <iostream>
#include <fstream>
#include <vector>
#include <string>
#include <sstream>
#include <iomanip>
#include <cstdint>
#include <cstdlib>
#include <stdexcept>
#include <cmath>

// -----------------------------------------------------------------------------
// CONFIGURACIÓN: ajusta estas rutas a tu entorno
// -----------------------------------------------------------------------------
// helpers por si el compilador no trae std::round en el namespace
static inline double my_floor(double x) { return std::floor(x); }
static inline double my_round(double x) { return std::floor(x + 0.5); }
// Ruta al system-console (ya probada por Randall en su máquina)
static const std::string SC_BIN =
    "/home/hack/altera_lite/25.1std/quartus/sopc_builder/bin/system-console";

// Directorio del proyecto Quartus (donde está el .qpf)
static const std::string PROJ_DIR =
    "../dsa/quartus";

// Ruta al script Tcl (desde donde se ejecuta este binario)
static const std::string TCL_SCRIPT =
    "../jtag/dsa_jtag_downscale_raw.tcl";

// Límite actual del core en HW (por ahora 64x64)
static const int HW_IMG_MAX_W = 64;
static const int HW_IMG_MAX_H = 64;

// -----------------------------------------------------------------------------
// Utilidades simples
// -----------------------------------------------------------------------------

static uint8_t clamp_u8(int x) {
    if (x < 0)   return 0;
    if (x > 255) return 255;
    return static_cast<uint8_t>(x);
}

// Lee un .raw de w*h bytes (8 bits por píxel, gris)
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
// Dimensiones de salida iguales al HW (modo 1)
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

// -----------------------------------------------------------------------------
// Modelo de referencia bilineal en C++ (igual al Python/ref_cpp)
// -----------------------------------------------------------------------------

std::vector<uint8_t> downscale_ref_bilinear(
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

    // Dimensiones de salida iguales que en HW
    compute_out_dims_hw_like(img_w, img_h, scale_q8_8, out_w, out_h);

    // escala en double (por ejemplo 0.5 si scale_q8_8 = 0x80)
    double scale = static_cast<double>(scale_q8_8) / 256.0;

    std::vector<uint8_t> dst(out_w * out_h, 0);

    auto at = [&](int x, int y) -> uint8_t {
        if (x < 0) x = 0;
        if (x >= img_w) x = img_w - 1;
        if (y < 0) y = 0;
        if (y >= img_h) y = img_h - 1;
        int idx = y * img_w + x;
        if (idx < 0 || idx >= total_pix) return 0;
        return src[idx];
    };

    for (int yo = 0; yo < out_h; ++yo) {
        double ys = (static_cast<double>(yo) + 0.5) / scale - 0.5;
        int y0 = static_cast<int>(my_floor(ys));
        if (y0 < 0) y0 = 0;
        if (y0 > img_h - 1) y0 = img_h - 1;
        int y1 = (y0 + 1 < img_h) ? y0 + 1 : y0;
        double ty = ys - y0;
        int ty_q = std::min(255, static_cast<int>(my_round(ty * 256.0))); // Q8.8

        for (int xo = 0; xo < out_w; ++xo) {
            double xs = (static_cast<double>(xo) + 0.5) / scale - 0.5;
            int x0 = static_cast<int>(my_floor(xs));
            if (x0 < 0) x0 = 0;
            if (x0 > img_w - 1) x0 = img_w - 1;
            int x1 = (x0 + 1 < img_w) ? x0 + 1 : x0;
            double tx = xs - x0;
            int tx_q = std::min(255, static_cast<int>(my_round(tx * 256.0))); // Q8.8

            int I00 = at(x0, y0);
            int I10 = at(x1, y0);
            int I01 = at(x0, y1);
            int I11 = at(x1, y1);

            int wx0 = 256 - tx_q;
            int wy0 = 256 - ty_q;

            long long acc = 0;
            acc += 1LL * I00 * wx0 * wy0;
            acc += 1LL * I10 * tx_q * wy0;
            acc += 1LL * I01 * wx0 * ty_q;
            acc += 1LL * I11 * tx_q * ty_q;

            acc = (acc + (1LL << 15)) >> 16; // redondeo Q16.16 -> Q8.8
            dst[yo * out_w + xo] = clamp_u8(static_cast<int>(acc));
        }
    }

    return dst;
}

// -----------------------------------------------------------------------------
// Llamada a system-console + Tcl
// -----------------------------------------------------------------------------

// Ejecuta el Tcl para correr el DSA en HW.
// La idea es que el script Tcl reciba:
//   PROJ_DIR img_w img_h scale_hex in_raw out_raw
static bool run_system_console(
    int img_w, int img_h,
    const std::string &scale_hex,
    const std::string &in_raw,
    const std::string &out_raw)
{
    std::ostringstream cmd;
    cmd << SC_BIN
        << " -cli --script=" << TCL_SCRIPT
        << " " << PROJ_DIR
        << " " << img_w
        << " " << img_h
        << " " << scale_hex
        << " " << in_raw
        << " " << out_raw;

    std::cout << "------------------------------------------------\n";
    std::cout << "Ejecutando system-console con:\n  " << cmd.str() << "\n";
    std::cout << "------------------------------------------------\n";

    int ret = std::system(cmd.str().c_str());
    if (ret != 0)
    {
        std::cerr << "ERROR: system-console devolvió código " << ret << "\n";
        return false;
    }
    return true;
}

// -----------------------------------------------------------------------------
// Comparación y main()
// -----------------------------------------------------------------------------

int main(int argc, char **argv)
{
    if (argc != 6)
    {
        std::cerr << "Uso:\n  " << argv[0]
                  << " <img_w> <img_h> <scale_hex> <in_raw> <out_hw_raw>\n\n";
        return 1;
    }

    int img_w = std::stoi(argv[1]);
    int img_h = std::stoi(argv[2]);
    std::string scale_hex = argv[3];
    std::string in_raw = argv[4];
    std::string out_hw = argv[5];

    std::cout << "Args brutos recibidos: "
              << img_w << " " << img_h << " " << scale_hex
              << " " << in_raw << " " << out_hw << "\n";

    std::cout << "Parametros:\n";
    std::cout << "  img_w      = " << img_w << "\n";
    std::cout << "  img_h      = " << img_h << "\n";

    uint32_t scale_q8_8 = 0;
    try {
        scale_q8_8 = static_cast<uint32_t>(
            std::stoul(scale_hex, nullptr, 16));
    } catch (const std::exception &e) {
        std::cerr << "ERROR: no se pudo parsear scale_hex=" << scale_hex
                  << " (" << e.what() << ")\n";
        return 1;
    }

    std::cout << "  scale_q8_8 = 0x"
              << std::hex << std::setw(8) << std::setfill('0')
              << scale_q8_8 << std::dec << "\n";
    std::cout << "  input RAW  = " << in_raw << "\n";
    std::cout << "  output RAW = " << out_hw << "\n";

    // 1) Cargar imagen de entrada
    auto src = load_raw(in_raw, img_w, img_h);

    // 2) Ejecutar referencia bilineal en CPU
    int ref_w = 0, ref_h = 0;
    std::vector<uint8_t> ref_out;
    try {
        ref_out = downscale_ref_bilinear(
            img_w, img_h, scale_q8_8, src,
            ref_w, ref_h);
    } catch (const std::exception &e) {
        std::cerr << "ERROR en referencia bilineal: " << e.what() << "\n";
        return 1;
    }

    // Guardar referencia opcionalmente si se quiere inspeccionar
    save_raw("ref_out.raw", ref_out);
    std::cout << "Ref: salida " << ref_w << "x" << ref_h
              << " escrita en ref_out.raw\n";

    // 3) Ejecutar el HW via system-console + Tcl
    if (!run_system_console(img_w, img_h, scale_hex, in_raw, out_hw))
    {
        std::cerr << "ERROR: fallo al invocar system-console.\n";
        return 1;
    }

    // 4) Cargar salida de HW
    auto hw_out = load_raw(out_hw, ref_w, ref_h);
    std::cout << "HW: leídos " << hw_out.size()
              << " bytes desde " << out_hw << "\n";

    // 5) Comparar píxel a píxel
    if (hw_out.size() != ref_out.size())
    {
        std::cerr << "WARNING: hw_out.size() != ref_out.size()\n";
    }

    int total = std::min<int>(hw_out.size(), ref_out.size());
    int mismatches = 0;

    for (int i = 0; i < total; ++i)
    {
        uint8_t ref = ref_out[i];
        uint8_t hw  = hw_out[i];
        if (ref != hw)
        {
            if (mismatches < 20)
            {
                int x = i % ref_w;
                int y = i / ref_w;
                std::cout << "Mismatch en pixel " << i
                          << " (x=" << x << ", y=" << y << "): "
                          << "REF=0x" << std::hex << std::setw(2) << std::setfill('0') << (int)ref
                          << " HW=0x"  << std::setw(2) << (int)hw
                          << std::dec << "\n";
            }
            mismatches++;
        }
    }

    if (mismatches == 0)
    {
        std::cout << "[OK] HW coincide con referencia bilineal.\n";
        return 0;
    }
    else
    {
        std::cout << "[FAIL] Se encontraron " << mismatches
                  << " mismatches (se muestran hasta 20).\n";
        return 1;
    }
}
