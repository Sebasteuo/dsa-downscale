// dsa_top_seq.sv
// Top secuencial con core bilineal escalar:
//  - Imagen máx IMG_MAX_W x IMG_MAX_H píxeles.
//  - Entrada: 4 BRAM IP (in_pix_mem_dp_0..3) con la misma imagen replicada.
//  - Salida: array out_pix_mem (por simplicidad, sigue como registros).
//  - Core: bilinear_core_scalar (probado en simulación / C++).
//  - PERF_CYC: ciclos mientras el core está ocupado.
//  - PERF_PIX: píxeles escritos (wr_valid del core).

module dsa_top_seq #(
  parameter int ADDR_WIDTH = 16,
  parameter int IMG_MAX_W  = 32,
  parameter int IMG_MAX_H  = 32
) (
  input  logic                  clk,
  input  logic                  rst_n,

  // Bus simple tipo Avalon-MM
  input  logic                  h_wr_en,
  input  logic                  h_rd_en,
  input  logic [ADDR_WIDTH-1:0] h_addr,
  input  logic [31:0]           h_wdata,
  output logic [31:0]           h_rdata,
  output logic                  h_rvalid
);

  // ---------------------------------------------------------
  // Parámetros, límites e índices
  // ---------------------------------------------------------
  localparam int MAX_PIXELS  = IMG_MAX_W * IMG_MAX_H;        // ej 32x32=1024
  localparam int MAX_WORDS   = (MAX_PIXELS + 3) >> 2;        // palabras de 32b
  localparam int PIX_ADDR_W  = $clog2(MAX_PIXELS);

  // ---------------------------------------------------------
  // Mapa de registros
  // ---------------------------------------------------------
  localparam logic [15:0] REG_CTRL      = 16'h0000;
  localparam logic [15:0] REG_STATUS    = 16'h0001;
  localparam logic [15:0] REG_IMG_W     = 16'h0002;
  localparam logic [15:0] REG_IMG_H     = 16'h0003;
  localparam logic [15:0] REG_SCALE     = 16'h0004;
  localparam logic [15:0] REG_MODE      = 16'h0005;   // se guarda pero no se usa
  localparam logic [15:0] REG_PERF_CYC  = 16'h0006;
  localparam logic [15:0] REG_PERF_PIX  = 16'h0007;

  localparam logic [15:0] REG_IN_ADDR   = 16'h0020;
  localparam logic [15:0] REG_IN_DATA   = 16'h0021;
  localparam logic [15:0] REG_OUT_ADDR  = 16'h0030;
  localparam logic [15:0] REG_OUT_DATA  = 16'h0031;

  // ---------------------------------------------------------
  // Configuración / estado
  // ---------------------------------------------------------
  logic [15:0] img_w;
  logic [15:0] img_h;
  logic [15:0] scale_q8_8;
  logic [7:0]  mode;

  logic [15:0] out_w;
  logic [15:0] out_h;
  logic [15:0] inv_scale_q;

  // punteros host (en palabras 32 bits)
  logic [15:0] in_ptr;    // sólo informativo ahora
  logic [15:0] out_ptr;

  // Performance
  logic [31:0] perf_cyc;
  logic [31:0] perf_pix;

  // Core bilineal
  logic        core_busy;
  logic        core_done;
  logic        core_wr_valid;
  logic [31:0] core_wr_addr;
  logic [7:0]  core_wr_data;

  logic [31:0] core_rd_addr0, core_rd_addr1, core_rd_addr2, core_rd_addr3;
  logic [7:0]  core_rd_data0, core_rd_data1, core_rd_data2, core_rd_data3;

  // Pulso de start
  logic        start_pulse;
  wire         start_cond = (h_wr_en && (h_addr == REG_CTRL) && h_wdata[0]);

  // STATUS
  wire busy = core_busy;
  wire done = core_done;

  // Memoria de salida como IP RAM: 2-PORT (out_pix_mem_dp)
  logic [PIX_ADDR_W-1:0] out_core_addr;   // dirección que usa el core
  logic                  out_core_we;     // write enable del core

  logic [PIX_ADDR_W-1:0] out_host_addr;   // dirección que usa el host (JTAG)
  logic [7:0]            out_host_q;      // dato leído por el host

  // ---------------------------------------------------------
  // BRAM de entrada (4 bancos, misma imagen)
  // ---------------------------------------------------------
  // Dirección para el core (puerto A de cada banco)
  wire [PIX_ADDR_W-1:0] core_rd_addr0_trunc = core_rd_addr0[PIX_ADDR_W-1:0];
  wire [PIX_ADDR_W-1:0] core_rd_addr1_trunc = core_rd_addr1[PIX_ADDR_W-1:0];
  wire [PIX_ADDR_W-1:0] core_rd_addr2_trunc = core_rd_addr2[PIX_ADDR_W-1:0];
  wire [PIX_ADDR_W-1:0] core_rd_addr3_trunc = core_rd_addr3[PIX_ADDR_W-1:0];

  // Dirección / datos para el host (puerto B de TODOS los bancos)
  logic [PIX_ADDR_W-1:0] in_host_addr;
  logic [7:0]            in_host_data;
  
  logic [7:0]            aux;
  logic                  in_host_we;

  // Salidas de lectura del core
  logic [7:0] in_q0, in_q1, in_q2, in_q3;
  
  assign out_core_addr = core_wr_addr[PIX_ADDR_W-1:0];
  assign out_core_we   = core_wr_valid;

  out_pix_mem_db out_pix_mem_inst (
    .clock    (clk),

    // Puerto A: core
    .address_a(out_core_addr),
    .data_a   (core_wr_data),
    .wren_a   (out_core_we),
    .q_a      (/* no se usa */),

    // Puerto B: host
    .address_b(out_host_addr),
    .data_b   (8'd0),
    .wren_b   (1'b0),
    .q_b      (out_host_q)
  );

  // Banco 0: rd_addr0 → core_rd_data0
  in_pix_mem_db in_pix_mem_dp_0 (
    .clock   (clk),
    // Puerto A: core
    .address_a(core_rd_addr0_trunc),
    .data_a  (8'd0),
    .wren_a  (1'b0),
    .q_a     (in_q0),
    // Puerto B: host (escritura)
    .address_b(in_host_addr),
    .data_b  (in_host_data),
    .wren_b  (in_host_we),
    .q_b     ()
  );

  // Banco 1: rd_addr1 → core_rd_data1
  in_pix_mem_db in_pix_mem_dp_1 (
    .clock   (clk),
    .address_a(core_rd_addr1_trunc),
    .data_a  (8'd0),
    .wren_a  (1'b0),
    .q_a     (in_q1),
    .address_b(in_host_addr),
    .data_b  (in_host_data),
    .wren_b  (in_host_we),
    .q_b     ()
  );

  // Banco 2: rd_addr2 → core_rd_data2
  in_pix_mem_db in_pix_mem_dp_2 (
    .clock   (clk),
    .address_a(core_rd_addr2_trunc),
    .data_a  (8'd0),
    .wren_a  (1'b0),
    .q_a     (in_q2),
    .address_b(in_host_addr),
    .data_b  (in_host_data),
    .wren_b  (in_host_we),
    .q_b     ()
  );

  // Banco 3: rd_addr3 → core_rd_data3
  in_pix_mem_db in_pix_mem_dp_3 (
    .clock   (clk),
    .address_a(core_rd_addr3_trunc),
    .data_a  (8'd0),
    .wren_a  (1'b0),
    .q_a     (in_q3),
    .address_b(in_host_addr),
    .data_b  (in_host_data),
    .wren_b  (in_host_we),
    .q_b     ()
  );

  // Conectar salidas de los bancos al core
  assign core_rd_data0 = in_q0;
  assign core_rd_data1 = in_q1;
  assign core_rd_data2 = in_q2;
  assign core_rd_data3 = in_q3;

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

  // Pulso de start (1 ciclo cuando se escribe CTRL con bit0=1)
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)
      start_pulse <= 1'b0;
    else
      start_pulse <= start_cond;
  end

  // ---------------------------------------------------------
  // Desempaquetador de IN_DATA → 4 píxeles → BRAMs de entrada
  // ---------------------------------------------------------
  logic [31:0] in_word_buf;
  logic [1:0]  in_word_byte_idx;
  logic        in_word_pending;
  logic [PIX_ADDR_W-1:0] pix_wr_idx;

  // ---------------------------------------------------------
  // Escrituras, contadores y salida
  // ---------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      img_w       <= 16'd0;
      img_h       <= 16'd0;
      scale_q8_8  <= 16'd0;
      mode        <= 8'd0;

      out_w       <= 16'd0;
      out_h       <= 16'd0;
      inv_scale_q <= 16'h0100;

      in_ptr      <= 16'd0;
      out_ptr     <= 16'd0;

      perf_cyc    <= 32'd0;
      perf_pix    <= 32'd0;

      in_word_buf      <= 32'd0;
      in_word_byte_idx <= 2'd0;
      in_word_pending  <= 1'b0;
      pix_wr_idx       <= '0;

      in_host_addr <= '0;
      in_host_data <= 8'd0;
      in_host_we   <= 1'b0;
    end else begin		
      // Por defecto, no escribimos en BRAM de entrada en este ciclo
      in_host_we <= 1'b0;

      // ==============================
      // Escrituras desde el host
      // ==============================
      if (h_wr_en) begin
        unique case (h_addr)
          REG_IMG_W:   img_w      <= h_wdata[15:0];
          REG_IMG_H:   img_h      <= h_wdata[15:0];
          REG_SCALE:   scale_q8_8 <= h_wdata[15:0];
          REG_MODE:    mode       <= h_wdata[7:0];

          // Puntero de entrada (en palabras de 32 bits)
          REG_IN_ADDR: begin
            in_ptr      <= h_wdata[15:0];
            // Convertimos a índice de píxel: word * 4
            pix_wr_idx  <= {h_wdata[15:0], 2'b00};
				in_word_pending <= 1'b0;
				in_word_byte_idx<= 2'd0;
          end

          // Escritura de datos de entrada (4 píxeles empaquetados)
          REG_IN_DATA: begin
              in_word_buf      <= h_wdata;
              in_word_byte_idx <= 2'd0;
              in_word_pending  <= 1'b1;
          end

          // Puntero de salida (en palabras 32 bits)
          REG_OUT_ADDR: out_ptr <= h_wdata[15:0];

          // REG_CTRL: sólo usamos bit0 como START (start_cond/start_pulse)
          REG_CTRL: begin
            // no guardamos nada aquí
          end

          default: ;
        endcase
      end

      // ==============================
      // Desempaquetar in_word_buf → 4 píxeles
      // ==============================
      if (in_word_pending) begin
        logic [7:0] cur_pix;
        case (in_word_byte_idx)
          2'd0: cur_pix = in_word_buf[7:0];
          2'd1: cur_pix = in_word_buf[15:8];
          2'd2: cur_pix = in_word_buf[23:16];
          2'd3: cur_pix = in_word_buf[31:24];
          default: cur_pix = 8'd00;
        endcase
		  
		  //if (in_word_buf == 0) begin
			//	cur_pix = 8'd255;
		  //end

		  in_host_addr <= pix_wr_idx;
		  in_host_data <= cur_pix;
		  in_host_we   <= 1'b1;       // se escribe en los 4 bancos a la vez
		  pix_wr_idx   <= pix_wr_idx + 1'b1;

        if (in_word_byte_idx == 2'd3) begin
          in_word_pending <= 1'b0;
        end else begin
          in_word_byte_idx <= in_word_byte_idx + 2'd1;
        end
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
        logic [15:0] ow, oh;

        ow = (img_w * scale_q8_8) >> 8;
        oh = (img_h * scale_q8_8) >> 8;

        if (ow == 16'd0) ow = 16'd1;
        if (oh == 16'd0) oh = 16'd1;

        if (ow > IMG_MAX_W[15:0]) ow = IMG_MAX_W[15:0];
        if (oh > IMG_MAX_H[15:0]) oh = IMG_MAX_H[15:0];

        if (ow > img_w) ow = img_w;
        if (oh > img_h) oh = img_h;

        out_w <= ow;
        out_h <= oh;

        // inv_scale_q ≈ (1/scale) en Q8.8 => 65536 / scale_q8_8
        if (scale_q8_8 == 16'd0)
          inv_scale_q <= 16'h0100;
        else
          inv_scale_q <= (32'd65536 / scale_q8_8);

        // Reset de contadores
        perf_cyc <= 32'd0;
        perf_pix <= 32'd0;
      end else begin
        // ==============================
        // Actualización de contadores
        // ==============================
        if (core_busy && !core_done)
          perf_cyc <= perf_cyc + 32'd1;

        if (core_wr_valid)
          perf_pix <= perf_pix + 32'd1;
      end

      
    end
  end

  // ---------------------------------------------------------
  // Lecturas (CSRs + empaquetado de salida)
  // ---------------------------------------------------------
  always_comb begin
    logic [31:0] base_pix_rd;

    h_rdata      = 32'd0;
    out_host_addr = '0;   // default, para evitar latches

    // Mantengo tu lógica original de base_pix_rd
    base_pix_rd = out_ptr + 1;

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

        // Dirección para el puerto B del IP
        out_host_addr = base_pix_rd[PIX_ADDR_W-1:0];

        // Valor leído desde el IP
        b0 = out_host_q;

        h_rdata = {b3, b2, b1, b0};
      end

      default: ;
    endcase
  end

  assign h_rvalid = h_rd_en;

endmodule
