#include <iostream>
#include <fstream>
#include <vector>
#include <cstdint>
#include <cmath>
#include <string>
#include <stdexcept>

static uint8_t clamp_u8(int x) {
    if (x < 0)   return 0;
    if (x > 255) return 255;
    return static_cast<uint8_t>(x);
}

std::vector<uint8_t> read_raw_u8(const std::string &path, int W, int H) {
    std::ifstream f(path, std::ios::binary);
    if (!f) throw std::runtime_error("no se pudo abrir archivo de entrada " + path);
    std::vector<uint8_t> data(W*H);
    f.read(reinterpret_cast<char*>(data.data()), data.size());
    if (!f) throw std::runtime_error("tamano incorrecto en RAW (se esperaba W*H)");
    return data;
}

void write_raw_u8(const std::string &path, const std::vector<uint8_t> &img) {
    std::ofstream f(path, std::ios::binary);
    if (!f) throw std::runtime_error("no se pudo abrir archivo de salida " + path);
    f.write(reinterpret_cast<const char*>(img.data()), img.size());
}

void write_pgm_u8(const std::string &path, const std::vector<uint8_t> &img, int W, int H) {
    std::ofstream f(path, std::ios::binary);
    if (!f) throw std::runtime_error("no se pudo abrir PGM de salida " + path);
    f << "P5\n" << W << " " << H << "\n255\n";
    f.write(reinterpret_cast<const char*>(img.data()), img.size());
}

// Modelo de referencia en C++ con la misma logica que el Python (Q8.8 y Q10.8)
std::vector<uint8_t> downscale_bilinear_u8_cpp(
        const std::vector<uint8_t> &img, int W, int H,
        double scale, int &W2, int &H2) {

    H2 = std::max(1, (int)std::round(H * scale));
    W2 = std::max(1, (int)std::round(W * scale));
    std::vector<uint8_t> out(W2 * H2, 0);

    auto at = [&](int x, int y) -> uint8_t {
        return img[y*W + x];
    };

    for (int yo = 0; yo < H2; ++yo) {
        double ys = ( (double)yo + 0.5 ) / scale - 0.5;
        int y0 = (int)std::floor(ys);
        if (y0 < 0) y0 = 0;
        if (y0 > H-1) y0 = H-1;
        int y1 = (y0 + 1 < H) ? y0 + 1 : y0;
        double ty = ys - y0;
        int ty_q = std::min(255, (int)std::round(ty * 256.0)); // Q8.8

        for (int xo = 0; xo < W2; ++xo) {
            double xs = ( (double)xo + 0.5 ) / scale - 0.5;
            int x0 = (int)std::floor(xs);
            if (x0 < 0) x0 = 0;
            if (x0 > W-1) x0 = W-1;
            int x1 = (x0 + 1 < W) ? x0 + 1 : x0;
            double tx = xs - x0;
            int tx_q = std::min(255, (int)std::round(tx * 256.0)); // Q8.8

            int I00 = at(x0, y0);
            int I10 = at(x1, y0);
            int I01 = at(x0, y1);
            int I11 = at(x1, y1);

            int wx0 = 256 - tx_q;
            int wy0 = 256 - ty_q;

            // mismo acumulador que en Python: I*wx*wy + ...
            long long acc = 0;
            acc += 1LL * I00 * wx0 * wy0;
            acc += 1LL * I10 * tx_q * wy0;
            acc += 1LL * I01 * wx0 * ty_q;
            acc += 1LL * I11 * tx_q * ty_q;

            acc = (acc + (1LL<<15)) >> 16; // redondeo
            out[yo*W2 + xo] = clamp_u8((int)acc);
        }
    }

    return out;
}

int main(int argc, char **argv) {
    std::string in_path, out_raw_path, out_pgm_path;
    int W = 0, H = 0;
    double scale = 1.0;

    // parseo sencillo de argumentos estilo --clave valor
    for (int i = 1; i < argc; ++i) {
        std::string a = argv[i];
        if (a == "--in" && i+1 < argc) in_path = argv[++i];
        else if (a == "--w" && i+1 < argc) W = std::stoi(argv[++i]);
        else if (a == "--h" && i+1 < argc) H = std::stoi(argv[++i]);
        else if (a == "--scale" && i+1 < argc) scale = std::stod(argv[++i]);
        else if (a == "--out-raw" && i+1 < argc) out_raw_path = argv[++i];
        else if (a == "--out-pgm" && i+1 < argc) out_pgm_path = argv[++i];
    }

    if (in_path.empty() || W <= 0 || H <= 0 || out_raw_path.empty()) {
        std::cerr << "uso: " << argv[0]
                  << " --in ruta.raw --w W --h H --scale s"
                  << " --out-raw salida.raw [--out-pgm salida.pgm]\n";
        return 1;
    }

    try {
        auto img = read_raw_u8(in_path, W, H);
        int W2 = 0, H2 = 0;
        auto out = downscale_bilinear_u8_cpp(img, W, H, scale, W2, H2);
        write_raw_u8(out_raw_path, out);
        if (!out_pgm_path.empty()) {
            write_pgm_u8(out_pgm_path, out, W2, H2);
        }
        std::cout << "C++ ref: salida " << W2 << "x" << H2
                  << " generada en " << out_raw_path << std::endl;
    } catch (const std::exception &e) {
        std::cerr << "error: " << e.what() << std::endl;
        return 1;
    }

    return 0;
}
