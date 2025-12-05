// Top para bilinear_core_scalar
// - Imagen máxima: IMG_MAX_W x IMG_MAX_H
// - Memoria interna in_mem / out_mem de 32 bits (4 píxeles/word)
// - Registros accesibles por JTAG (vía Avalon-MM simple):
//   0x0000: CTRL      (bit0 = START)
//   0x0001: STATUS    (bit0 = BUSY, bit1 = DONE)
//   0x0002: IMG_W
//   0x0003: IMG_H
//   0x0004: SCALE (Q8.8) 
//   0x0005: MODE
//   0x0006: PERF_CYC
//   0x0007: PERF_PIX
//   0x0020: IN_ADDR
//   0x0021: IN_DATA
//   0x0030: OUT_ADDR
//   0x0031: OUT_DATA

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

  // Parámetros y memoria
  localparam int MAX_PIXELS = IMG_MAX_W * IMG_MAX_H;
  localparam int MAX_WORDS  = (MAX_PIXELS + 3) >> 2; 

  // Memorias internas de 32 bits
  logic [31:0] in_mem  [0:MAX_WORDS-1];
  logic [31:0] out_mem [0:MAX_WORDS-1];

  // Registros de configuración / estado
  localparam logic [15:0] REG_CTRL      = 16'h0000;
  localparam logic [15:0] REG_STATUS    = 16'h0001;
  localparam logic [15:0] REG_IMG_W     = 16'h0002;
  localparam logic [15:0] REG_IMG_H     = 16'h0003;
  localparam logic [15:0] REG_SCALE     = 16'h0004;
  localparam logic [15:0] REG_MODE      = 16'h0005;
  localparam logic [15:0] REG_PERF_CYC  = 16'h0006;
  localparam logic [15:0] REG_PERF_PIX  = 16'h0007;

  localparam logic [15:0] REG_IN_ADDR   = 16'h0020;
  localparam logic [15:0] REG_IN_DATA   = 16'h0021;
  localparam logic [15:0] REG_OUT_ADDR  = 16'h0030;
  localparam logic [15:0] REG_OUT_DATA  = 16'h0031;

  // Config
  logic [15:0] img_w;
  logic [15:0] img_h;
  logic [15:0] scale_q8_8;
  logic [7:0]  mode; 

  // punteros de BRAM
  logic [15:0] in_ptr;
  logic [15:0] out_ptr;

  // Performance
  logic [31:0] perf_cyc;
  logic [31:0] perf_pix;

  // START como pulso de 1 ciclo
  logic start_pulse;

  // Señales hacia / desde el core bilineal
  // ---------------------------------------------------------
  // Salida del core: estado
  wire core_busy;
  wire core_done;

  // Direcciones de lectura de píxel (lineales) para 4 vecinos
  wire [31:0] core_rd_addr0;
  wire [31:0] core_rd_addr1;
  wire [31:0] core_rd_addr2;
  wire [31:0] core_rd_addr3;

  // Datos de píxel (8 bits) desde memoria hacia el core
  logic [7:0] core_rd_data0;
  logic [7:0] core_rd_data1;
  logic [7:0] core_rd_data2;
  logic [7:0] core_rd_data3;

  // Escritura de salida del core
  wire        core_wr_valid;
  wire [31:0] core_wr_addr;   // índice de píxel de salida
  wire [7:0]  core_wr_data;   // valor de píxel de salida

  wire core_step_ack_unused;

  // out_w / out_h para el core:
  wire [15:0] out_w_core = img_w;
  wire [15:0] out_h_core = img_h;

  // START pulse generation + registros + perf_counters
  integer i;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      img_w      <= 16'd0;
      img_h      <= 16'd0;
      scale_q8_8 <= 16'd0;
      mode       <= 8'd0;

      in_ptr     <= 16'd0;
      out_ptr    <= 16'd0;

      perf_cyc   <= 32'd0;
      perf_pix   <= 32'd0;

      start_pulse <= 1'b0;

      // Inicializar memorias
      for (i = 0; i < MAX_WORDS; i = i + 1) begin
        in_mem[i]  <= 32'd0;
        out_mem[i] <= 32'd0;
      end

    end else begin
      start_pulse <= 1'b0;

      // Escrituras desde el host
      if (h_wr_en) begin
        unique case (h_addr)
          REG_IMG_W:    img_w      <= h_wdata[15:0];
          REG_IMG_H:    img_h      <= h_wdata[15:0];
          REG_SCALE:    scale_q8_8 <= h_wdata[15:0];
          REG_MODE:     mode       <= h_wdata[7:0];

          REG_IN_ADDR:  in_ptr     <= h_wdata[15:0];

          REG_IN_DATA: begin
            if (in_ptr < MAX_WORDS[15:0]) begin
              in_mem[in_ptr] <= h_wdata;
              in_ptr         <= in_ptr + 16'd1;
            end
          end

          REG_OUT_ADDR: out_ptr    <= h_wdata[15:0];

          REG_CTRL: begin
            if (h_wdata[0]) begin
              start_pulse <= 1'b1;     // pulso de START
              perf_cyc    <= 32'd0;    // reset de contadores
              perf_pix    <= 32'd0;
            end
          end

          default: ;
        endcase
      end

      // Lectura de OUT_DATA -> autoincremento
      if (h_rd_en && (h_addr == REG_OUT_DATA)) begin
        if (out_ptr < MAX_WORDS[15:0]) begin
          out_ptr <= out_ptr + 16'd1;
        end
      end

      // Contadores de desempeño
      if (core_busy && !core_done) begin
        perf_cyc <= perf_cyc + 32'd1;
      end

      if (core_wr_valid) begin
        perf_pix <= perf_pix + 32'd1;
      end

      // Escritura en out_mem
      if (core_wr_valid) begin
        logic [15:0] word_idx;
        logic [1:0]  byte_sel;
        logic [31:0] w;

        word_idx = core_wr_addr[17:2];
        byte_sel = core_wr_addr[1:0];

        if (word_idx < MAX_WORDS[15:0]) begin
          w = out_mem[word_idx];
          unique case (byte_sel)
            2'd0: w[7:0]    = core_wr_data;
            2'd1: w[15:8]   = core_wr_data;
            2'd2: w[23:16]  = core_wr_data;
            2'd3: w[31:24]  = core_wr_data;
          endcase
          out_mem[word_idx] <= w;
        end
      end
    end
  end

  // Lectura de in_mem para el core
  always_comb begin
    core_rd_data0 = 8'd0;
    core_rd_data1 = 8'd0;
    core_rd_data2 = 8'd0;
    core_rd_data3 = 8'd0;

    // Vecino 0
    if (core_rd_addr0 < MAX_PIXELS) begin
      logic [15:0] widx;
      logic [1:0]  bsel;
      logic [31:0] w;
      widx = core_rd_addr0[17:2];
      bsel = core_rd_addr0[1:0];
      w    = in_mem[widx];
      unique case (bsel)
        2'd0: core_rd_data0 = w[7:0];
        2'd1: core_rd_data0 = w[15:8];
        2'd2: core_rd_data0 = w[23:16];
        2'd3: core_rd_data0 = w[31:24];
      endcase
    end

    // Vecino 1
    if (core_rd_addr1 < MAX_PIXELS) begin
      logic [15:0] widx;
      logic [1:0]  bsel;
      logic [31:0] w;
      widx = core_rd_addr1[17:2];
      bsel = core_rd_addr1[1:0];
      w    = in_mem[widx];
      unique case (bsel)
        2'd0: core_rd_data1 = w[7:0];
        2'd1: core_rd_data1 = w[15:8];
        2'd2: core_rd_data1 = w[23:16];
        2'd3: core_rd_data1 = w[31:24];
      endcase
    end

    // Vecino 2
    if (core_rd_addr2 < MAX_PIXELS) begin
      logic [15:0] widx;
      logic [1:0]  bsel;
      logic [31:0] w;
      widx = core_rd_addr2[17:2];
      bsel = core_rd_addr2[1:0];
      w    = in_mem[widx];
      unique case (bsel)
        2'd0: core_rd_data2 = w[7:0];
        2'd1: core_rd_data2 = w[15:8];
        2'd2: core_rd_data2 = w[23:16];
        2'd3: core_rd_data2 = w[31:24];
      endcase
    end

    // Vecino 3
    if (core_rd_addr3 < MAX_PIXELS) begin
      logic [15:0] widx;
      logic [1:0]  bsel;
      logic [31:0] w;
      widx = core_rd_addr3[17:2];
      bsel = core_rd_addr3[1:0];
      w    = in_mem[widx];
      unique case (bsel)
        2'd0: core_rd_data3 = w[7:0];
        2'd1: core_rd_data3 = w[15:8];
        2'd2: core_rd_data3 = w[23:16];
        2'd3: core_rd_data3 = w[31:24];
      endcase
    end
  end

  // STATUS y lecturas de registros
  wire [31:0] status_reg = { 28'd0,
                             1'b0,         // reservado / ERR
                             1'b0,         // reservado / STEP_ACK
                             core_done,    // bit1 DONE
                             core_busy     // bit0 BUSY
                           };

  always_comb begin
    h_rdata = 32'd0;

    unique case (h_addr)
      REG_STATUS:    h_rdata = status_reg;
      REG_IMG_W:     h_rdata = {16'd0, img_w};
      REG_IMG_H:     h_rdata = {16'd0, img_h};
      REG_SCALE:     h_rdata = {16'd0, scale_q8_8};
      REG_MODE:      h_rdata = {24'd0, mode};

      REG_PERF_CYC:  h_rdata = perf_cyc;
      REG_PERF_PIX:  h_rdata = perf_pix;

      REG_IN_ADDR:   h_rdata = {16'd0, in_ptr};
      REG_OUT_ADDR:  h_rdata = {16'd0, out_ptr};

      REG_OUT_DATA:  h_rdata = out_mem[out_ptr];

      default: ;
    endcase
  end

  assign h_rvalid = h_rd_en;

  // Instancia del core bilinear escalar
  bilinear_core_scalar #(
    .W_MAX(IMG_MAX_W),
    .H_MAX(IMG_MAX_H)
  ) u_core (
    .clk        (clk),
    .rst_n      (rst_n),

    .start      (start_pulse),
    .in_w       (img_w),
    .in_h       (img_h),
    .out_w      (out_w_core),
    .out_h      (out_h_core),
    .inv_scale_q(scale_q8_8), 

    .step_mode  (1'b0),
    .step       (1'b0),
    .step_ack   (core_step_ack_unused),

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

endmodule
