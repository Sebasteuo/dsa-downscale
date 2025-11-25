// tb_coords_gen.sv
// Lee results/coords_32_s05.csv y valida campos basicos de rango

module tb_coords_gen;
  string path = "results/coords_32_s05.csv";
  int f, line = 0;
  int yo, xo, x0, y0, x1, y1, tx_q, ty_q;
  string header;

  initial begin
    f = $fopen(path, "r");
    if (f == 0) begin
      $display("no se pudo abrir %s", path);
      $finish;
    end

    // leer encabezado
    void'($fgets(header, f));

    // leer filas y validar rangos sencillos
    while (!$feof(f)) begin
      int n = $fscanf(f, "%d,%d,%d,%d,%d,%d,%d,%d\n",
                      yo, xo, x0, y0, x1, y1, tx_q, ty_q);
      if (n == 8) begin
        line++;
        if (tx_q < 0 || tx_q > 255) begin
          $display("tx_q fuera de rango en linea %0d", line);
          $finish;
        end
        if (ty_q < 0 || ty_q > 255) begin
          $display("ty_q fuera de rango en linea %0d", line);
          $finish;
        end
      end
    end
    $fclose(f);
    $display("coords ok  lineas %0d", line);
    $finish;
  end
endmodule
