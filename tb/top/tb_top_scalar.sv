// tb_top_scalar.sv
// Lee un RAW 8-bit, hace bilineal simple y escribe results/out_hw.raw

module tb_top_scalar;
  int W_in  = 32;
  int H_in  = 32;
  real scale = 0.5;

  int W_out, H_out;

  byte img_in  [0:1024*1024-1];
  byte img_out [0:1024*1024-1];

  int fin, fout;

  function automatic int clamp_u8(int x);
    if (x < 0)    return 0;
    if (x > 255)  return 255;
    return x;
  endfunction

  function automatic byte calcular_pixel(int x0, y0, x1, y1, int tx_q, ty_q);
    int wx0 = 256 - tx_q;
    int wy0 = 256 - ty_q;
    int I00 = img_in[y0*W_in + x0];
    int I10 = img_in[y0*W_in + x1];
    int I01 = img_in[y1*W_in + x0];
    int I11 = img_in[y1*W_in + x1];
    int acc;
    acc  = I00*wx0*wy0 + I10*tx_q*wy0 + I01*wx0*ty_q + I11*tx_q*ty_q;
    acc  = (acc + (1<<15)) >> 16;
    return byte'( (acc<0)?0 : (acc>255)?255 : acc );
  endfunction

  initial begin
    // cargar RAW
    fin = $fopen("vectors/patterns/grad_32x32.raw", "rb");
    if (fin == 0) begin
      $display("no se pudo abrir vectors/patterns/grad_32x32.raw");
      $finish;
    end
    for (int i=0; i<W_in*H_in; i++) begin
      int ch = $fgetc(fin);
      if (ch == -1) begin
        $display("archivo RAW mas corto de lo esperado");
        $finish;
      end
      img_in[i] = ch;
    end
    $fclose(fin);

    // tamaño de salida
    W_out = (W_in*scale < 1.0) ? 1 : $rtoi($floor(W_in*scale + 0.5));
    H_out = (H_in*scale < 1.0) ? 1 : $rtoi($floor(H_in*scale + 0.5));

    // calcular pixeles de salida
    for (int yo=0; yo<H_out; yo++) begin
      real ys   = (yo + 0.5)/scale - 0.5;
      int  y0   = (ys < 0) ? 0 : (ys > (H_in-1)) ? (H_in-1) : int'(ys);
      int  y1   = (y0+1 < H_in) ? y0+1 : y0;
      real ty   = ys - y0;
      int  ty_q = (ty*256.0 > 255.0) ? 255 : int'($rtoi(ty*256.0 + 0.5));

      for (int xo=0; xo<W_out; xo++) begin
        real xs   = (xo + 0.5)/scale - 0.5;
        int  x0   = (xs < 0) ? 0 : (xs > (W_in-1)) ? (W_in-1) : int'(xs);
        int  x1   = (x0+1 < W_in) ? x0+1 : x0;
        real tx   = xs - x0;
        int  tx_q = (tx*256.0 > 255.0) ? 255 : int'($rtoi(tx*256.0 + 0.5));

        img_out[yo*W_out + xo] = calcular_pixel(x0,y0,x1,y1, tx_q,ty_q);
      end
    end

    // escribir salida
    fout = $fopen("results/out_hw.raw", "wb");
    if (fout == 0) begin
      $display("no se pudo abrir results/out_hw.raw");
      $finish;
    end
    for (int i=0; i<W_out*H_out; i++) begin
      void'($fwrite(fout, "%c", img_out[i]));
    end
    $fclose(fout);

    $display("listo results/out_hw.raw  %0dx%0d", W_out, H_out);
    $finish;
  end
endmodule
