// tb/top/tb_core_minimal.v
// Testbench mínimo para probar bilinear_core_scalar sin archivos ni 'real'

`timescale 1ns/1ps

module tb_core_minimal;

  // Imagen de entrada pequeña: 4x4
  reg [7:0] img_in  [0:15];   // 4*4
  reg [7:0] img_out [0:15];   // espacio para salida (2x2)

  // Parámetros "duros" de dims
  reg [15:0] in_w, in_h;
  reg [15:0] out_w, out_h;
  reg [15:0] inv_scale_q; // Q8.8 de 1/scale

  // Clock y reset
  reg clk = 0;
  always #5 clk = ~clk;   // 100 MHz

  reg rst_n;
  reg start;

  // Interfaz core
  wire        busy, done;
  wire [31:0] rd_addr0, rd_addr1, rd_addr2, rd_addr3;
  reg  [7:0]  rd_data0, rd_data1, rd_data2, rd_data3;
  wire        wr_valid;
  wire [31:0] wr_addr;
  wire [7:0]  wr_data;

  integer i;

  // Instancia del core
  bilinear_core_scalar core_u (
    .clk         (clk),
    .rst_n       (rst_n),
    .start       (start),
    .in_w        (in_w),
    .in_h        (in_h),
    .out_w       (out_w),
    .out_h       (out_h),
    .inv_scale_q (inv_scale_q),
    .busy        (busy),
    .done        (done),

    .rd_addr0    (rd_addr0),
    .rd_addr1    (rd_addr1),
    .rd_addr2    (rd_addr2),
    .rd_addr3    (rd_addr3),
    .rd_data0    (rd_data0),
    .rd_data1    (rd_data1),
    .rd_data2    (rd_data2),
    .rd_data3    (rd_data3),

    .wr_valid    (wr_valid),
    .wr_addr     (wr_addr),
    .wr_data     (wr_data)
  );

  // BRAM de entrada (4x4)
  always @* begin
    rd_data0 = img_in[rd_addr0];
    rd_data1 = img_in[rd_addr1];
    rd_data2 = img_in[rd_addr2];
    rd_data3 = img_in[rd_addr3];
  end

  // BRAM de salida
  always @(posedge clk) begin
    if (wr_valid) begin
      if (wr_addr < 16) begin
        img_out[wr_addr] <= wr_data;
        $display("[TB_MIN] WRITE addr=%0d data=%0d t=%0t", wr_addr, wr_data, $time);
      end
    end
  end

  // Estímulo
  initial begin
    $display("[TB_MIN] Inicio de simulacion t=%0t", $time);

    // Inicializar imagen 4x4 con un patrón simple
    for (i = 0; i < 16; i = i+1) begin
      img_in[i] = i * 10;
    end

    // Parámetros: entrada 4x4, salida 2x2, scale=0.5 => inv_scale_q=1/0.5*256=512
    in_w        = 4;
    in_h        = 4;
    out_w       = 2;
    out_h       = 2;
    inv_scale_q = 16'd512; // Q8.8 de 2.0

    // Reset
    rst_n = 0;
    start = 0;
    repeat (5) @(posedge clk);
    rst_n = 1;
    $display("[TB_MIN] Reset liberado t=%0t", $time);

    // Disparar core
    @(posedge clk);
    $display("[TB_MIN] Enviando start t=%0t", $time);
    start <= 1;
    @(posedge clk);
    start <= 0;

    // Esperar done (con un timeout grande por si las moscas)
    i = 0;
    while (!done && i < 500) begin
      @(posedge clk);
      i = i + 1;
    end

    if (!done) begin
      $display("[TB_MIN] TIMEOUT: done nunca llegó, ciclos=%0d busy=%0b", i, busy);
      $finish;
    end

    $display("[TB_MIN] done=1 t=%0t, ciclos=%0d", $time, i);

    // Mostrar memoria de salida
    $display("[TB_MIN] img_out[0]=%0d", img_out[0]);
    $display("[TB_MIN] img_out[1]=%0d", img_out[1]);
    $display("[TB_MIN] img_out[2]=%0d", img_out[2]);
    $display("[TB_MIN] img_out[3]=%0d", img_out[3]);

    $finish;
  end

endmodule
