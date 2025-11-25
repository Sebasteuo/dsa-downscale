// tb_bilinear_core.sv
// Lee results/bilinear_cases_grad32_s05.csv y compara salidas

module tb_bilinear_core;
  string path = "results/bilinear_cases_grad32_s05.csv";
  int f, line = 0;
  int I00, I10, I01, I11, tx_q, ty_q, expected;
  string header;

  function automatic int clamp_u8(int x);
    if (x < 0) return 0;
    if (x > 255) return 255;
    return x;
  endfunction

  function automatic int bilinear_u8(int I00, I10, I01, I11, int tx_q, ty_q);
    int wx0 = 256 - tx_q;
    int wy0 = 256 - ty_q;
    int acc;
    acc  = I00*wx0*wy0 + I10*tx_q*wy0 + I01*wx0*ty_q + I11*tx_q*ty_q;
    acc  = (acc + (1<<15)) >> 16;
    return clamp_u8(acc);
  endfunction

  initial begin
    f = $fopen(path, "r");
    if (f == 0) begin
      $display("no se pudo abrir %s", path);
      $finish;
    end

    // leer encabezado
    void'($fgets(header, f));

    // recorrer casos
    while (!$feof(f)) begin
      int n = $fscanf(f, "%d,%d,%d,%d,%d,%d,%d\n",
                      I00, I10, I01, I11, tx_q, ty_q, expected);
      if (n == 7) begin
        line++;
        int got = bilinear_u8(I00, I10, I01, I11, tx_q, ty_q);
        if (got !== expected) begin
          $display("mismatch en linea %0d  got=%0d expected=%0d", line, got, expected);
          $finish;
        end
      end
    end
    $fclose(f);
    $display("bilinear ok  casos %0d", line);
    $finish;
  end
endmodule
