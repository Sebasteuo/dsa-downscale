// tb/top/tb_top_scalar.v
// Testbench de tope: usa bilinear_core_scalar sobre un RAW 32x32 con scale=0.5

`timescale 1ns/1ps

module tb_top_scalar;

  // Dimensiones fijas
  localparam IN_W  = 32;
  localparam IN_H  = 32;
  localparam OUT_W = 16;
  localparam OUT_H = 16;

  // BRAM 
  reg [7:0] img_in  [0:IN_W*IN_H-1];   // 0..1023
  reg [7:0] img_out [0:OUT_W*OUT_H-1]; // 0..255

  integer fin, fout;
  integer i;
  integer ch;

  // Clock y reset
  reg clk = 0;
  always #5 clk = ~clk;   // 100 MHz

  reg rst_n;
  reg start;

  // Config core
  reg [15:0] in_w,  in_h;
  reg [15:0] out_w, out_h;
  reg [15:0] inv_scale_q;  // Q8.8 de 1/scale

  // Interface hacia el core
  wire        busy, done;
  wire [31:0] rd_addr0, rd_addr1, rd_addr2, rd_addr3;
  reg  [7:0]  rd_data0, rd_data1, rd_data2, rd_data3;
  wire        wr_valid;
  wire [31:0] wr_addr;
  wire [7:0]  wr_data;

  integer ciclos;

  // Instancia del núcleo RTL
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

  // BRAM de entrada
  always @* begin
    rd_data0 = 8'd0;
    rd_data1 = 8'd0;
    rd_data2 = 8'd0;
    rd_data3 = 8'd0;

    if (rd_addr0 < IN_W*IN_H) rd_data0 = img_in[rd_addr0];
    if (rd_addr1 < IN_W*IN_H) rd_data1 = img_in[rd_addr1];
    if (rd_addr2 < IN_W*IN_H) rd_data2 = img_in[rd_addr2];
    if (rd_addr3 < IN_W*IN_H) rd_data3 = img_in[rd_addr3];
  end

  // BRAM de salida
  always @(posedge clk) begin
    if (wr_valid) begin
      if (wr_addr < OUT_W*OUT_H) begin
        img_out[wr_addr] <= wr_data;
        // $display("[TB] WRITE addr=%0d data=%0d t=%0t", wr_addr, wr_data, $time);
      end
    end
  end

  // Estímulo principal
  initial begin
    $display("[TB] Inicio de simulacion t=%0t", $time);

    // Reset
    rst_n = 0;
    start = 0;
    repeat (5) @(posedge clk);
    rst_n = 1;
    $display("[TB] Reset liberado t=%0t", $time);

    // Cargar RAW 32x32
    fin = $fopen("vectors/patterns/grad_32x32.raw", "r");
    if (fin == 0) begin
      $display("ERROR: no se pudo abrir vectors/patterns/grad_32x32.raw");
      $finish;
    end

    for (i = 0; i < IN_W*IN_H; i = i+1) begin
      ch = $fgetc(fin);
      if (ch == -1) begin
        $display("ERROR: archivo RAW mas corto de lo esperado");
        $finish;
      end
      img_in[i] = ch[7:0];
    end
    $fclose(fin);
    $display("[TB] RAW cargado t=%0t", $time);

    // Configuración fija
    in_w        = IN_W;
    in_h        = IN_H;
    out_w       = OUT_W;
    out_h       = OUT_H;
    inv_scale_q = 16'd512; // 1/0.5 * 256 = 512 (Q8.8)

    $display("[TB] Input:  %0dx%0d", IN_W, IN_H);
    $display("[TB] Output: %0dx%0d", OUT_W, OUT_H);
    $display("[TB] inv_scale_q (Q8.8) = %0d", inv_scale_q);

    // Disparar el core
    @(posedge clk);
    $display("[TB] Enviando start t=%0t", $time);
    start <= 1;
    @(posedge clk);
    start <= 0;

    // Esperar done con límite de ciclos
    ciclos = 0;
    $display("[TB] Esperando done...");

    while (!done && ciclos < 20000) begin
      @(posedge clk);
      ciclos = ciclos + 1;
    end

    if (!done) begin
      $display("[TB] TIMEOUT: done nunca llegó, ciclos=%0d busy=%0b", ciclos, busy);
      $finish;
    end

    $display("[TB] done=1 t=%0t, ciclos=%0d", $time, ciclos);
    @(posedge clk);

    // Escribir salida a archivo
    fout = $fopen("results/out_hw.raw", "w");
    if (fout == 0) begin
      $display("ERROR: no se pudo abrir results/out_hw.raw");
      $finish;
    end

    for (i = 0; i < OUT_W*OUT_H; i = i+1) begin
      $fwrite(fout, "%c", img_out[i]);
    end
    $fclose(fout);

    $display("[TB] Listo results/out_hw.raw  %0dx%0d", OUT_W, OUT_H);
    $finish;
  end

endmodule
