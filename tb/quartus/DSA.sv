// Top "lógico" de la DSA.
// - Interfaz de registros hacia el host (h_*).
// - BRAM de entrada/salida.
// - Contadores de rendimiento PERF_CYC / PERF_PIX.
// - Core de downscale (dsa_core).

module DSA #(
  parameter int N_LANES        = 1,
  parameter int IN_ADDR_WIDTH  = 18,
  parameter int OUT_ADDR_WIDTH = 18
) (
  input  logic                 clk,
  input  logic                 rst_n,

  // Bus simple del host
  input  logic                 h_wr_en,
  input  logic                 h_rd_en,
  input  logic [15:0]          h_addr,
  input  logic [31:0]          h_wdata,
  output logic [31:0]          h_rdata,
  output logic                 h_rvalid
);

  // Señales de configuración
  logic [15:0] cfg_img_w;
  logic [15:0] cfg_img_h;
  logic [15:0] cfg_scale_q8_8;
  logic [1:0]  cfg_mode;

  // Pulsos de control
  logic start_pulse;
  logic soft_reset_pulse;

  // Estado del core
  logic core_busy;
  logic core_done;
  logic core_error;

  // Contadores de rendimiento
  logic [31:0] perf_cyc;
  logic [31:0] perf_pix;

  // Señales BRAM entrada (HOST)
  logic                 in_host_we;
  logic [IN_ADDR_WIDTH-1:0] in_host_addr;
  logic [31:0]          in_host_wdata;
  logic [31:0]          in_host_rdata;

  // Señales BRAM salida (HOST)
  logic [OUT_ADDR_WIDTH-1:0] out_host_addr;
  logic [31:0]          out_host_rdata;

  // Señales BRAM entrada (CORE)
  logic [IN_ADDR_WIDTH-1:0]  in_core_addr;
  logic [31:0]               in_core_rdata;

  // Señales BRAM salida (CORE)
  logic [OUT_ADDR_WIDTH-1:0] out_core_addr;
  logic [31:0]               out_core_wdata;
  logic                      out_core_we;

  // Máscaras de píxeles válidos desde el core
  logic [N_LANES-1:0]        core_pix_valid_mask;

  // host_regs: interfaz de registros hacia el host
  host_regs #(
    .ADDR_WIDTH    (16),
    .IN_ADDR_WIDTH (IN_ADDR_WIDTH),
    .OUT_ADDR_WIDTH(OUT_ADDR_WIDTH)
  ) u_host_regs (
    .clk               (clk),
    .rst_n             (rst_n),

    .h_wr_en           (h_wr_en),
    .h_rd_en           (h_rd_en),
    .h_addr            (h_addr),
    .h_wdata           (h_wdata),
    .h_rdata           (h_rdata),
    .h_rvalid          (h_rvalid),

    .cfg_img_w         (cfg_img_w),
    .cfg_img_h         (cfg_img_h),
    .cfg_scale_q8_8    (cfg_scale_q8_8),
    .cfg_mode          (cfg_mode),

    .start_pulse       (start_pulse),
    .soft_reset_pulse  (soft_reset_pulse),

    .core_busy         (core_busy),
    .core_done         (core_done),
    .core_error        (core_error),

    .perf_cyc          (perf_cyc),
    .perf_pix          (perf_pix),

    .in_host_we        (in_host_we),
    .in_host_addr      (in_host_addr),
    .in_host_wdata     (in_host_wdata),
    .in_host_rdata     (in_host_rdata),

    .out_host_addr     (out_host_addr),
    .out_host_rdata    (out_host_rdata)
  );

  // BRAM de entrada
  //  - Puerto A: host
  //  - Puerto B: core (solo lectura)
  image_bram #(
    .ADDR_WIDTH (IN_ADDR_WIDTH),
    .DATA_WIDTH (32)
  ) u_in_bram (
    .clk     (clk),

    // Puerto A: HOST
    .a_we    (in_host_we),
    .a_addr  (in_host_addr),
    .a_wdata (in_host_wdata),
    .a_rdata (in_host_rdata),

    // Puerto B: CORE
    .b_we    (1'b0),           // BRAM de entrada: core solo lee
    .b_addr  (in_core_addr),
    .b_wdata ('0),
    .b_rdata (in_core_rdata)
  );

  // BRAM de salida
  //  - Puerto A: host (lectura)
  //  - Puerto B: core (escritura)
  image_bram #(
    .ADDR_WIDTH (OUT_ADDR_WIDTH),
    .DATA_WIDTH (32)
  ) u_out_bram (
    .clk     (clk),

    // Puerto A: HOST (solo lectura)
    .a_we    (1'b0),
    .a_addr  (out_host_addr),
    .a_wdata ('0),
    .a_rdata (out_host_rdata),

    // Puerto B: CORE (escritura)
    .b_we    (out_core_we),
    .b_addr  (out_core_addr),
    .b_wdata (out_core_wdata),
    .b_rdata ()              // no se usa lectura por el core
  );

  // dsa_core: módulo principal de downscale
  dsa_core #(
    .IN_ADDR_WIDTH  (IN_ADDR_WIDTH),
    .OUT_ADDR_WIDTH (OUT_ADDR_WIDTH),
    .N_LANES        (N_LANES)
  ) u_dsa_core (
    .clk             (clk),
    .rst_n           (rst_n),

    .start           (start_pulse),
    .busy            (core_busy),
    .done            (core_done),
    .error           (core_error),

    .img_w           (cfg_img_w),
    .img_h           (cfg_img_h),
    .scale_q8_8      (cfg_scale_q8_8),
    .mode            (cfg_mode),

    // BRAM entrada
    .in_addr         (in_core_addr),
    .in_rdata        (in_core_rdata),

    // BRAM salida
    .out_addr        (out_core_addr),
    .out_wdata       (out_core_wdata),
    .out_we          (out_core_we),

    // Máscara de píxeles válidos para contadores
    .pix_valid_mask  (core_pix_valid_mask)
  );

  // perf_counters: contadores de ciclos y píxeles
  // Detectar pulso de DONE a partir de core_done
  logic core_done_q;
  logic done_pulse;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      core_done_q <= 1'b0;
    end else begin
      core_done_q <= core_done;
    end
  end

  assign done_pulse = core_done & ~core_done_q;

  perf_counters #(
    .N_LANES       (N_LANES),
    .COUNTER_WIDTH (32)
  ) u_perf (
    .clk            (clk),
    .rst_n          (rst_n),
    .start          (start_pulse),
    .done           (done_pulse),
    .enable         (1'b1),
    .pix_valid_mask (core_pix_valid_mask),
    .perf_cyc       (perf_cyc),
    .perf_pix       (perf_pix)
  );

endmodule


module dsa_core #(
  parameter int IN_ADDR_WIDTH  = 18,
  parameter int OUT_ADDR_WIDTH = 18,
  parameter int N_LANES        = 1
) (
  input  logic                 clk,
  input  logic                 rst_n,

  // Control
  input  logic                 start,
  output logic                 busy,
  output logic                 done,
  output logic                 error,

  // Configuración
  input  logic [15:0]          img_w,
  input  logic [15:0]          img_h,
  input  logic [15:0]          scale_q8_8,
  input  logic [1:0]           mode,

  // BRAM entrada (solo lectura)
  output logic [IN_ADDR_WIDTH-1:0]  in_addr,
  input  logic [31:0]               in_rdata,

  // BRAM salida (escritura)
  output logic [OUT_ADDR_WIDTH-1:0] out_addr,
  output logic [31:0]               out_wdata,
  output logic                      out_we,

  // Máscara de píxeles válidos (para contadores)
  output logic [N_LANES-1:0]        pix_valid_mask
);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      busy           <= 1'b0;
      done           <= 1'b0;
      error          <= 1'b0;
      in_addr        <= '0;
      out_addr       <= '0;
      out_wdata      <= '0;
      out_we         <= 1'b0;
      pix_valid_mask <= '0;
    end else begin
      // Esqueleto mínimo: sin operación real.
      busy           <= 1'b0;
      done           <= 1'b0;
      error          <= 1'b0;
      in_addr        <= in_addr;
      out_addr       <= out_addr;
      out_wdata      <= out_wdata;
      out_we         <= 1'b0;
      pix_valid_mask <= '0;
    end
  end

endmodule