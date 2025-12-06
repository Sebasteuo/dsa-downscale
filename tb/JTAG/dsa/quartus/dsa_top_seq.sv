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
  input  logic                  step,

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
  // Configuración / estado (vista desde el host)
  // ---------------------------------------------------------
  logic [15:0] img_w;
  logic [15:0] img_h;
  logic [15:0] scale_q8_8;
  logic [7:0]  mode;
  
  wire core_mode      = mode[0];
  wire core_step_mode = mode[1];
  logic step_sync_0, step_sync_1;
  logic step_sync_1_d;
  logic step_pulse_btn;

  // Dimensiones de salida e inv_scale calculadas en HW
  logic [15:0] out_w;
  logic [15:0] out_h;
  logic [15:0] inv_scale_q;

  // punteros host (en palabras de 32 bits)
  logic [15:0] in_ptr;    // informativo
  logic [15:0] out_ptr;

  // ---------------------------------------------------------
  // Desempaquetador de entrada (4 píxeles por palabra)
  // ---------------------------------------------------------
  logic [31:0]              in_word_buf;
  logic [1:0]               in_word_byte_idx;
  logic                     in_word_pending;
  logic [PIX_ADDR_W-1:0]    pix_wr_idx;

  // Puerto B de los 4 BRAM de entrada (host)
  logic [PIX_ADDR_W-1:0] in_host_addr;
  logic [7:0]            in_host_data;
  logic                  in_host_we;

  // Puerto A de los 4 BRAM de entrada (core)
  logic [7:0] in_q0, in_q1, in_q2, in_q3;

  // ---------------------------------------------------------
  // Interface CSR hacia bilinear_top
  // ---------------------------------------------------------
  localparam logic [3:0] CSR_CTRL     = 4'h0;
  localparam logic [3:0] CSR_STATUS   = 4'h1;
  localparam logic [3:0] CSR_SCALE_Q  = 4'h2;  // inv_scale_q (Q8.8) en [15:0]
  localparam logic [3:0] CSR_IN_W_H   = 4'h3;
  localparam logic [3:0] CSR_OUT_W_H  = 4'h4;
  localparam logic [3:0] CSR_PERF_CYC = 4'h5;
  localparam logic [3:0] CSR_PERF_PIX = 4'h6;

  logic        csr_we;
  logic [3:0]  csr_addr;
  logic [31:0] csr_wdata;
  logic [31:0] csr_rdata;

  // ---------------------------------------------------------
  // Interfaz de memoria de bilinear_top (modo N=1)
  // ---------------------------------------------------------
  logic [31:0] bt_rd_addr0, bt_rd_addr1, bt_rd_addr2, bt_rd_addr3;
  logic [7:0]  bt_rd_data0, bt_rd_data1, bt_rd_data2, bt_rd_data3;

  logic        bt_wr_valid;
  logic [31:0] bt_wr_addr;
  logic [7:0]  bt_wr_data;

  // Detención de START desde el host
  wire start_cond = (h_wr_en && (h_addr == REG_CTRL) && h_wdata[0]);
  
  // Memoria de salida como IP RAM: 2-PORT (out_pix_mem_dp)
  logic [PIX_ADDR_W-1:0] out_core_addr;   // dirección que usa el core
  logic                  out_core_we;     // write enable del core
  logic [7:0]  out_core_data;

  logic [PIX_ADDR_W-1:0] out_host_addr;   // dirección que usa el host (JTAG)
  logic [7:0]            out_host_q;      // dato leído por el host

  // ---------------------------------------------------------
  // BRAM de entrada (4 bancos, misma imagen)
  // ---------------------------------------------------------
  // Dirección para el core (puerto A de cada banco)
  wire [PIX_ADDR_W-1:0] rd_addr0_trunc = bt_rd_addr0[PIX_ADDR_W-1:0];
  wire [PIX_ADDR_W-1:0] rd_addr1_trunc = bt_rd_addr1[PIX_ADDR_W-1:0];
  wire [PIX_ADDR_W-1:0] rd_addr2_trunc = bt_rd_addr2[PIX_ADDR_W-1:0];
  wire [PIX_ADDR_W-1:0] rd_addr3_trunc = bt_rd_addr3[PIX_ADDR_W-1:0];
  

  // Conectar salidas de los bancos al core
  assign bt_rd_data0 = in_q0;
  assign bt_rd_data1 = in_q1;
  assign bt_rd_data2 = in_q2;
  assign bt_rd_data3 = in_q3;
  assign out_core_addr = bt_wr_addr[PIX_ADDR_W-1:0];
  assign out_core_data = bt_wr_data;
  assign out_core_we   = bt_wr_valid;

  out_pix_mem_db out_pix_mem_inst (
    .clock    (clk),

    // Puerto A: core
    .address_a(out_core_addr),
    .data_a   (out_core_data),
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
    .address_a(rd_addr0_trunc),
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
    .address_a(rd_addr1_trunc),
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
    .address_a(rd_addr2_trunc),
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
    .address_a(rd_addr3_trunc),
    .data_a  (8'd0),
    .wren_a  (1'b0),
    .q_a     (in_q3),
    .address_b(in_host_addr),
    .data_b  (in_host_data),
    .wren_b  (in_host_we),
    .q_b     ()
  );

  // ---------------------------------------------------------
  // Instancia del core bilineal escalar
  // ---------------------------------------------------------
  bilinear_top #(
    .N    (1),
    .W_MAX(IMG_MAX_W),
    .H_MAX(IMG_MAX_H)
  ) bilinear_top_u (
    .clk      (clk),
    .rst_n    (rst_n),

    // Interface CSR
    .csr_we   (csr_we),
    .csr_addr (csr_addr),
    .csr_wdata(csr_wdata),
    .csr_rdata(csr_rdata),

    // Lectura de 4 vecinos (N=1 → un byte por vecino)
    .rd_addr0 (bt_rd_addr0),
    .rd_addr1 (bt_rd_addr1),
    .rd_addr2 (bt_rd_addr2),
    .rd_addr3 (bt_rd_addr3),
    .rd_data0 (bt_rd_data0),
    .rd_data1 (bt_rd_data1),
    .rd_data2 (bt_rd_data2),
    .rd_data3 (bt_rd_data3),

    // Escritura de salida (N=1 → un píxel por ciclo)
    .wr_valid (bt_wr_valid),
    .wr_addr  (bt_wr_addr),
    .wr_data  (bt_wr_data)
  );

  typedef enum logic [2:0] {
    CFG_IDLE,
    CFG_WRITE_SCALE,
    CFG_WRITE_IN_WH,
    CFG_WRITE_OUT_WH,
    CFG_WRITE_CTRL
  } cfg_state_t;

  cfg_state_t cfg_state;
  
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

      in_word_buf      <= 32'd0;
      in_word_byte_idx <= 2'd0;
      in_word_pending  <= 1'b0;
      pix_wr_idx       <= '0;

      in_host_addr <= '0;
      in_host_data <= 8'd0;
      in_host_we   <= 1'b0;
		
		csr_we    <= 1'b0;
      csr_addr  <= CSR_STATUS;
      csr_wdata <= 32'd0;
      cfg_state <= CFG_IDLE;
		
		step_sync_0   <= 1'b0;
      step_sync_1   <= 1'b0;
      step_sync_1_d <= 1'b0;
    end else begin		
      // Por defecto, no escribimos en BRAM de entrada en este ciclo
      in_host_we <= 1'b0;
		csr_we     <= 1'b0;
		step_sync_0   <= step;
      step_sync_1   <= step_sync_0;
      step_sync_1_d <= step_sync_1;

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
            if (h_wdata[0]) begin
              // calcular out_w, out_h e inv_scale_q como antes
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

              if (scale_q8_8 == 16'd0)
                inv_scale_q <= 16'h0100;
              else
                inv_scale_q <= (32'd65536 / scale_q8_8);

              // arrancar FSM de configuración
              cfg_state <= CFG_WRITE_SCALE;
            end
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
        if (out_ptr < MAX_PIXELS[15:0]) begin
          out_ptr <= out_ptr + 16'd1;
        end
      end

      // ====================================
      // FSM de configuración de bilinear_top
      // ====================================
      case (cfg_state)
        CFG_IDLE: begin
          // nada
        end

        CFG_WRITE_SCALE: begin
          csr_we    <= 1'b1;
          csr_addr  <= CSR_SCALE_Q;
          csr_wdata <= {16'd0, inv_scale_q};
          cfg_state <= CFG_WRITE_IN_WH;
        end

        CFG_WRITE_IN_WH: begin
          csr_we    <= 1'b1;
          csr_addr  <= CSR_IN_W_H;
          csr_wdata <= {img_w, img_h};
          cfg_state <= CFG_WRITE_OUT_WH;
        end

        CFG_WRITE_OUT_WH: begin
          csr_we    <= 1'b1;
          csr_addr  <= CSR_OUT_W_H;
          csr_wdata <= {out_w, out_h};
          cfg_state <= CFG_WRITE_CTRL;
        end

        CFG_WRITE_CTRL: begin  
          logic [31:0] new_ctrl;
          csr_we   <= 1'b1;
          csr_addr <= CSR_CTRL;

          // Construimos la palabra de control para bilinear_top:
          // Asumimos el mapeo de bits:
          //   bit 0: EN
          //   bit 1: START
          //   bit 2: MODE      (0 = escalar, 1 = SIMD)
          //   bit 3: STEP_MODE (0 = run continuo, 1 = stepping)
          //   bit 4: STEP      (pulso de step)
          new_ctrl        = 32'd0;
          new_ctrl[0]     = 1'b1;        // EN = 1
          new_ctrl[1]     = 1'b1;        // START = 1
          new_ctrl[2]     = core_mode;   // MODE: 0 = scalar, 1 = SIMD
          new_ctrl[3]     = core_step_mode;        // STEP_MODE
          new_ctrl[4]     = step;        // STEP

          csr_wdata <= new_ctrl;
          cfg_state <= CFG_IDLE;
        end

        default: cfg_state <= CFG_IDLE;
      endcase

      // ====================================
      // Cuando el host lea STATUS / PERF, movemos csr_addr
      // ====================================
      if (h_rd_en) begin
        unique case (h_addr)
          REG_STATUS:    csr_addr <= CSR_STATUS;
          REG_PERF_CYC:  csr_addr <= CSR_PERF_CYC;
          REG_PERF_PIX:  csr_addr <= CSR_PERF_PIX;
          default: ;
        endcase
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
      REG_STATUS:    h_rdata = csr_rdata;
      REG_IMG_W:     h_rdata = {16'd0, img_w};
      REG_IMG_H:     h_rdata = {16'd0, img_h};
      REG_SCALE:     h_rdata = {16'd0, scale_q8_8};
      REG_MODE:      h_rdata = {24'd0, mode};

      REG_PERF_CYC:  h_rdata = csr_rdata;
      REG_PERF_PIX:  h_rdata = csr_rdata; 

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
  assign step_pulse_btn = step_sync_1 & ~step_sync_1_d;

endmodule
