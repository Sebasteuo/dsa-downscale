// dsa_top_seq.sv
// Top secuencial con core bilineal escalar:
//  - Soporta hasta 64x64 píxeles (IMG_MAX_W/H).
//  - Entrada y salida en BRAM interna de 8 bits (1 píxel por entrada).
//  - Usa bilinear_core_scalar como único core.
//  - PERF_CYC: ciclos mientras el core está ocupado.
//  - PERF_PIX: número de píxeles escritos por el core (wr_valid).

module dsa_top_seq #(
  parameter int ADDR_WIDTH = 16,
  parameter int IMG_MAX_W  = 32,
  parameter int IMG_MAX_H  = 32
) (
  input  logic                  clk,
  input  logic                  rst_n,

  // Bus simple desde esclavo Avalon
  input  logic                  h_wr_en,
  input  logic                  h_rd_en,
  input  logic [ADDR_WIDTH-1:0] h_addr,
  input  logic [31:0]           h_wdata,
  output logic [31:0]           h_rdata,
  output logic                  h_rvalid
);

  // ---------------------------------------------------------
  // Parámetros y memoria
  // ---------------------------------------------------------
  localparam int MAX_PIXELS = IMG_MAX_W * IMG_MAX_H;            // 64x64 = 4096
  localparam int MAX_WORDS  = (MAX_PIXELS + 3) >> 2;            // 4096/4 = 1024

  // Memoria de entrada/salida en píxeles de 8 bits
  logic [7:0] in_pix_mem  [0:MAX_PIXELS-1];
  logic [7:0] out_pix_mem [0:MAX_PIXELS-1];

  // ---------------------------------------------------------
  // Registros de configuración / estado
  // ---------------------------------------------------------
  localparam logic [15:0] REG_CTRL      = 16'h0000;
  localparam logic [15:0] REG_STATUS    = 16'h0001;
  localparam logic [15:0] REG_IMG_W     = 16'h0002;
  localparam logic [15:0] REG_IMG_H     = 16'h0003;
  localparam logic [15:0] REG_SCALE     = 16'h0004;
  localparam logic [15:0] REG_MODE      = 16'h0005;   // guardado pero no usado
  localparam logic [15:0] REG_PERF_CYC  = 16'h0006;
  localparam logic [15:0] REG_PERF_PIX  = 16'h0007;

  localparam logic [15:0] REG_IN_ADDR   = 16'h0020;
  localparam logic [15:0] REG_IN_DATA   = 16'h0021;
  localparam logic [15:0] REG_OUT_ADDR  = 16'h0030;
  localparam logic [15:0] REG_OUT_DATA  = 16'h0031;

  // Config
  logic [15:0] img_w;
  logic [15:0] img_h;
  logic [15:0] scale_q8_8;   // scale en Q8.8 (lo que viene de SW)
  logic [7:0]  mode;         // guardado pero no usado

  // Dimensiones de salida calculadas en HW
  logic [15:0] out_w;
  logic [15:0] out_h;

  // Escala inversa para el core bilineal (inv_scale_q ≈ 1/scale)
  logic [15:0] inv_scale_q;

  // punteros de BRAM (en palabras de 32 bits para interfaz host)
  logic [15:0] in_ptr;       // índice de palabra para escritura de entrada
  logic [15:0] out_ptr;      // índice de palabra para lectura de salida

  // Performance
  logic [31:0] perf_cyc;
  logic [31:0] perf_pix;

  // Señales del core bilineal escalar
  logic        core_busy;
  logic        core_done;
  logic        core_wr_valid;
  logic [31:0] core_wr_addr;
  logic [7:0]  core_wr_data;

  logic [31:0] core_rd_addr0, core_rd_addr1, core_rd_addr2, core_rd_addr3;
  logic [7:0]  core_rd_data0, core_rd_data1, core_rd_data2, core_rd_data3;

  // Pulso de start hacia el core
  logic        start_pulse;

  // STATUS
  wire busy = core_busy;
  wire done = core_done;

  // Auxiliares
  logic [31:0] tmp_word;
  integer      i;

  // Índices para lectura del core
  integer rd_idx0, rd_idx1, rd_idx2, rd_idx3;

  // Índices base separados para escritura/lectura
  integer base_pix_wr;  // se usa sólo en always_ff (escritura)
  integer base_pix_rd;  // se usa sólo en always_comb (lectura/empacado)

  // Condición de START detectada en la escritura al registro CTRL
  wire start_cond = (h_wr_en && (h_addr == REG_CTRL) && h_wdata[0]);

  // ---------------------------------------------------------
  // Instancia del core bilineal escalar
  // ---------------------------------------------------------
  bilinear_core_scalar #(
    .W_MAX(IMG_MAX_W),
    .H_MAX(IMG_MAX_H)
  ) core_scalar_u (
    .clk        (clk),
    .rst_n      (rst_n),

    .start      (start_pulse),
    .in_w       (img_w),
    .in_h       (img_h),
    .out_w      (out_w),
    .out_h      (out_h),
    .inv_scale_q(inv_scale_q),

    // Stepping desactivado
    .step_mode  (1'b0),
    .step       (1'b0),
    .step_ack   (),

    .busy       (core_busy),
    .done       (core_done),

    .rd_addr0   (core_rd_addr0),
    .rd_addr1   (core_rd_addr1),
    .rd_addr2   (core_rd_addr2),
    .rd_addr3   (core_rd_addr3),
    .rd_data0   (core_rd_data0),
    .rd_data1   (core_rd_data1),
    .rd_data2   (core_rd_data2),
    .rd_data3   (core_rd_data3),

    .wr_valid   (core_wr_valid),
    .wr_addr    (core_wr_addr),
    .wr_data    (core_wr_data)
  );

  // start_pulse dura 1 ciclo cuando se escribe CTRL con bit0=1
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      start_pulse <= 1'b0;
    end else begin
      start_pulse <= start_cond;
    end
  end

  // ---------------------------------------------------------
  // Lectura de píxeles para el core desde in_pix_mem
  // ---------------------------------------------------------
  always_comb begin
    core_rd_data0 = 8'd0;
    core_rd_data1 = 8'd0;
    core_rd_data2 = 8'd0;
    core_rd_data3 = 8'd0;

    rd_idx0 = core_rd_addr0;
    rd_idx1 = core_rd_addr1;
    rd_idx2 = core_rd_addr2;
    rd_idx3 = core_rd_addr3;

    if (rd_idx0 >= 0 && rd_idx0 < MAX_PIXELS)
      core_rd_data0 = in_pix_mem[rd_idx0];

    if (rd_idx1 >= 0 && rd_idx1 < MAX_PIXELS)
      core_rd_data1 = in_pix_mem[rd_idx1];

    if (rd_idx2 >= 0 && rd_idx2 < MAX_PIXELS)
      core_rd_data2 = in_pix_mem[rd_idx2];

    if (rd_idx3 >= 0 && rd_idx3 < MAX_PIXELS)
      core_rd_data3 = in_pix_mem[rd_idx3];
  end

  // ---------------------------------------------------------
  // Escrituras, lecturas, contadores y memoria
  // ---------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      img_w      <= 16'd0;
      img_h      <= 16'd0;
      scale_q8_8 <= 16'd0;
      mode       <= 8'd0;

      out_w      <= 16'd0;
      out_h      <= 16'd0;
      inv_scale_q<= 16'h0100;  // por defecto 1.0

      in_ptr     <= 16'd0;
      out_ptr    <= 16'd0;

      perf_cyc   <= 32'd0;
      perf_pix   <= 32'd0;

      base_pix_wr <= 0;

      // Inicializar memorias a 0 (útil en simulación)
      for (i = 0; i < MAX_PIXELS; i = i + 1) begin
        in_pix_mem[i]  <= 8'd0;
        out_pix_mem[i] <= 8'd0;
      end
    end else begin
      // ==============================
      // Escrituras desde el host
      // ==============================
      if (h_wr_en) begin
        unique case (h_addr)
          REG_IMG_W:   img_w      <= h_wdata[15:0];
          REG_IMG_H:   img_h      <= h_wdata[15:0];
          REG_SCALE:   scale_q8_8 <= h_wdata[15:0];
          REG_MODE:    mode       <= h_wdata[7:0];

          // Puntero de entrada en palabras de 32 bits
          REG_IN_ADDR: in_ptr     <= h_wdata[15:0];

          // Escritura de datos de entrada (4 píxeles por palabra)
          REG_IN_DATA: begin
            if (in_ptr < MAX_WORDS[15:0]) begin
              tmp_word    = h_wdata;
              base_pix_wr = in_ptr * 4;

              // b0 = píxel 0 (LSB)
              if (base_pix_wr >= 0 && base_pix_wr < MAX_PIXELS)
                in_pix_mem[base_pix_wr] <= tmp_word[7:0];

              // b1 = píxel 1
              if ((base_pix_wr + 1) >= 0 && (base_pix_wr + 1) < MAX_PIXELS)
                in_pix_mem[base_pix_wr + 1] <= tmp_word[15:8];

              // b2 = píxel 2
              if ((base_pix_wr + 2) >= 0 && (base_pix_wr + 2) < MAX_PIXELS)
                in_pix_mem[base_pix_wr + 2] <= tmp_word[23:16];

              // b3 = píxel 3
              if ((base_pix_wr + 3) >= 0 && (base_pix_wr + 3) < MAX_PIXELS)
                in_pix_mem[base_pix_wr + 3] <= tmp_word[31:24];

              in_ptr <= in_ptr + 16'd1;
            end
          end

          // Puntero de salida en palabras de 32 bits
          REG_OUT_ADDR: out_ptr   <= h_wdata[15:0];

          // REG_CTRL: sólo usamos bit0 como START, manejado por start_cond/start_pulse
          REG_CTRL: begin
            // Nada que guardar; el efecto es start_cond/start_pulse
          end

          default: ;
        endcase
      end

      // ==============================
      // Autoincremento de OUT_ADDR al leer OUT_DATA
      // ==============================
      if (h_rd_en && (h_addr == REG_OUT_DATA)) begin
        if (out_ptr < MAX_WORDS[15:0]) begin
          out_ptr <= out_ptr + 16'd1;
        end
      end

      // ==============================
      // Lógica de inicio de operación
      // ==============================
      if (start_cond) begin
        // Dimensiones de salida igual que compute_out_dims_hw_like()
        logic [31:0] ow_full;
        logic [31:0] oh_full;
        logic [15:0] ow;
        logic [15:0] oh;

        ow_full = img_w * scale_q8_8;
        oh_full = img_h * scale_q8_8;

        ow = ow_full[23:8]; // >> 8
        oh = oh_full[23:8];

        if (ow == 16'd0) ow = 16'd1;
        if (oh == 16'd0) oh = 16'd1;

        if (ow > IMG_MAX_W[15:0]) ow = IMG_MAX_W[15:0];
        if (oh > IMG_MAX_H[15:0]) oh = IMG_MAX_H[15:0];

        if (ow > img_w) ow = img_w;
        if (oh > img_h) oh = img_h;

        out_w <= ow;
        out_h <= oh;

        // inv_scale_q ≈ (1/scale) en Q8.8 => 65536 / scale_q8_8
        if (scale_q8_8 == 16'd0) begin
          inv_scale_q <= 16'h0100; // por defecto 1.0 para evitar /0
        end else begin
          inv_scale_q <= (32'd65536 / scale_q8_8);
        end

        // Reset de contadores
        perf_cyc <= 32'd0;
        perf_pix <= 32'd0;
      end else begin
        // ==============================
        // Actualización de contadores
        // ==============================
        if (core_busy && !core_done) begin
          perf_cyc <= perf_cyc + 32'd1;
        end

        if (core_wr_valid) begin
          perf_pix <= perf_pix + 32'd1;
        end
      end

      // ==============================
      // Escritura en memoria de salida desde el core
      // ==============================
      if (core_wr_valid) begin
        if (core_wr_addr < MAX_PIXELS) begin
          out_pix_mem[core_wr_addr] <= core_wr_data;
        end
      end
    end
  end

  // ---------------------------------------------------------
  // Lecturas (CSRs + empaquetado de salida)
  // ---------------------------------------------------------
  always_comb begin
    h_rdata     = 32'd0;
    base_pix_rd = out_ptr * 4;

    unique case (h_addr)
      REG_STATUS:    h_rdata = {30'd0, done, busy};
      REG_IMG_W:     h_rdata = {16'd0, img_w};
      REG_IMG_H:     h_rdata = {16'd0, img_h};
      REG_SCALE:     h_rdata = {16'd0, scale_q8_8};
      REG_MODE:      h_rdata = {24'd0, mode};

      REG_PERF_CYC:  h_rdata = perf_cyc;
      REG_PERF_PIX:  h_rdata = perf_pix;

      REG_IN_ADDR:   h_rdata = {16'd0, in_ptr};
      REG_OUT_ADDR:  h_rdata = {16'd0, out_ptr};

      REG_OUT_DATA: begin
        logic [7:0] b0, b1, b2, b3;

        b0 = 8'd0;
        b1 = 8'd0;
        b2 = 8'd0;
        b3 = 8'd0;

        if (base_pix_rd >= 0 && base_pix_rd < MAX_PIXELS)
          b0 = out_pix_mem[base_pix_rd];

        if ((base_pix_rd + 1) >= 0 && (base_pix_rd + 1) < MAX_PIXELS)
          b1 = out_pix_mem[base_pix_rd + 1];

        if ((base_pix_rd + 2) >= 0 && (base_pix_rd + 2) < MAX_PIXELS)
          b2 = out_pix_mem[base_pix_rd + 2];

        if ((base_pix_rd + 3) >= 0 && (base_pix_rd + 3) < MAX_PIXELS)
          b3 = out_pix_mem[base_pix_rd + 3];

        h_rdata = {b3, b2, b1, b0};
      end

      default: ;
    endcase
  end

  assign h_rvalid = h_rd_en;

endmodule
