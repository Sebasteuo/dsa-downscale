// tb/top/tb_top_simd.v
// Testbench: prueba bilinear_core_simd con N=4 sobre RAW 32x32, scale=0.5
// Lee vectors/patterns/grad_32x32.raw y escribe results/out_hw_simd.raw.
// Soporta modo normal y stepping.

`timescale 1ns/1ps

module tb_top_simd;

  // Parámetros
  localparam integer IN_W  = 32;
  localparam integer IN_H  = 32;
  localparam integer OUT_W = 16;
  localparam integer OUT_H = 16;
  localparam integer N     = 4;

  // 0 = modo normal, 1 = stepping
  localparam USE_STEPPING = 1'b0;

  // BRAM "simple"
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

  // Stepping
  reg  step_mode;
  reg  step;
  wire step_ack;

  // Interface hacia el core SIMD
  wire             busy, done;
  wire [N*32-1:0]  rd_addr0, rd_addr1, rd_addr2, rd_addr3;
  reg  [N*8-1:0]   rd_data0, rd_data1, rd_data2, rd_data3;
  wire [N-1:0]     wr_valid;
  wire [N*32-1:0]  wr_addr;
  wire [N*8-1:0]   wr_data;

  integer ciclos;
  integer lane;

  // Instancia del núcleo SIMD
  bilinear_core_simd #(
    .N(N)
  ) core_simd_u (
    .clk         (clk),
    .rst_n       (rst_n),
    .start       (start),
    .in_w        (in_w),
    .in_h        (in_h),
    .out_w       (out_w),
    .out_h       (out_h),
    .inv_scale_q (inv_scale_q),

    .step_mode   (step_mode),
    .step        (step),
    .step_ack    (step_ack),

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

  // ---------------- BRAM de entrada (N lanes / 4 vecinos) ----------------
  always @* begin
    rd_data0 = {N*8{1'b0}};
    rd_data1 = {N*8{1'b0}};
    rd_data2 = {N*8{1'b0}};
    rd_data3 = {N*8{1'b0}};

    for (lane = 0; lane < N; lane = lane+1) begin
      integer a0, a1, a2, a3;

      a0 = rd_addr0[lane*32 +: 32];
      a1 = rd_addr1[lane*32 +: 32];
      a2 = rd_addr2[lane*32 +: 32];
      a3 = rd_addr3[lane*32 +: 32];

      if (a0 < IN_W*IN_H) rd_data0[lane*8 +: 8] = img_in[a0];
      if (a1 < IN_W*IN_H) rd_data1[lane*8 +: 8] = img_in[a1];
      if (a2 < IN_W*IN_H) rd_data2[lane*8 +: 8] = img_in[a2];
      if (a3 < IN_W*IN_H) rd_data3[lane*8 +: 8] = img_in[a3];
    end
  end

  // ---------------- BRAM de salida (N lanes) ----------------
  always @(posedge clk) begin
    for (lane = 0; lane < N; lane = lane+1) begin
      integer wa;
      wa = wr_addr[lane*32 +: 32];
      if (wr_valid[lane]) begin
        if (wa < OUT_W*OUT_H) begin
          img_out[wa] <= wr_data[lane*8 +: 8];
          // $display("[TB_SIMD] WRITE lane=%0d addr=%0d data=%0d t=%0t",
          //          lane, wa, wr_data[lane*8 +: 8], $time);
        end
      end
    end
  end

  // ---------------- Estímulo principal ----------------
  initial begin
    $display("[TB_SIMD] Inicio de simulacion t=%0t", $time);

    // Reset
    rst_n     = 0;
    start     = 0;
    step_mode = USE_STEPPING;
    step      = 0;

    repeat (5) @(posedge clk);
    rst_n = 1;
    $display("[TB_SIMD] Reset liberado t=%0t", $time);

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
    $display("[TB_SIMD] RAW cargado t=%0t", $time);

    // Configuración fija
    in_w        = IN_W;
    in_h        = IN_H;
    out_w       = OUT_W;
    out_h       = OUT_H;
    inv_scale_q = 16'd512; // 1/0.5 * 256 = 512 (Q8.8)

    $display("[TB_SIMD] Input:  %0dx%0d", IN_W, IN_H);
    $display("[TB_SIMD] Output: %0dx%0d", OUT_W, OUT_H);
    $display("[TB_SIMD] inv_scale_q (Q8.8) = %0d", inv_scale_q);
    $display("[TB_SIMD] N (lanes) = %0d, step_mode=%0d", N, step_mode);

    ciclos = 0;

    if (!USE_STEPPING) begin
      // ------------ MODO NORMAL ------------
      @(posedge clk);
      $display("[TB_SIMD] Enviando start (modo normal) t=%0t", $time);
      start <= 1;
      @(posedge clk);
      start <= 0;

      $display("[TB_SIMD] Esperando done (modo normal)...");
      while (!done && ciclos < 20000) begin
        @(posedge clk);
        ciclos = ciclos + 1;
      end
    end else begin
      // ------------ MODO STEPPING ------------
      $display("[TB_SIMD] Enviando start (modo stepping) con pasos...");
      // Primer paso: mantener start=1 hasta que el core salga de IDLE
      start <= 1;

      while (!done && ciclos < 20000) begin
        // 1) pedir paso
        step = 1'b1;
        @(posedge clk);
        while (step_ack == 1'b0) @(posedge clk);

        // En el primer paso se consume start en S_IDLE, luego ya se puede bajar
        if (ciclos == 0) begin
          start <= 0;
        end

        // 2) bajar step
        step = 1'b0;
        @(posedge clk);
        while (step_ack == 1'b1) @(posedge clk);  // esperar que limpie ACK

        ciclos = ciclos + 1;
        if (ciclos % 25 == 0) begin
          $display("[TB_SIMD] STEP ciclos=%0d, busy=%0b, done=%0b", ciclos, busy, done);
        end
      end
    end

    if (!done) begin
      $display("[TB_SIMD] TIMEOUT: done nunca llegó, ciclos=%0d busy=%0b", ciclos, busy);
      $finish;
    end

    $display("[TB_SIMD] done=1 t=%0t, ciclos=%0d", $time, ciclos);
    @(posedge clk);

    // Escribir salida a archivo
    fout = $fopen("results/out_hw_simd.raw", "w");
    if (fout == 0) begin
      $display("ERROR: no se pudo abrir results/out_hw_simd.raw");
      $finish;
    end

    for (i = 0; i < OUT_W*OUT_H; i = i+1) begin
      $fwrite(fout, "%c", img_out[i]);
    end
    $fclose(fout);

    $display("[TB_SIMD] Listo results/out_hw_simd.raw  %0dx%0d", OUT_W, OUT_H);
    $finish;
  end

endmodule
