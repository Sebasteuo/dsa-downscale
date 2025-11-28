// Interfaz de registros para el host.

module host_regs #(
  parameter int ADDR_WIDTH     = 16,
  parameter int IN_ADDR_WIDTH  = 18,
  parameter int OUT_ADDR_WIDTH = 18
) (
  input  logic                 clk,
  input  logic                 rst_n,

  // Bus simple del host
  input  logic                 h_wr_en,
  input  logic                 h_rd_en,
  input  logic [ADDR_WIDTH-1:0] h_addr,
  input  logic [31:0]          h_wdata,
  output logic [31:0]          h_rdata,
  output logic                 h_rvalid,

  // Configuración hacia el core
  output logic [15:0]          cfg_img_w,
  output logic [15:0]          cfg_img_h,
  output logic [15:0]          cfg_scale_q8_8,
  output logic [1:0]           cfg_mode,

  // Pulsos de control para la FSM principal
  output logic                 start_pulse,
  output logic                 soft_reset_pulse,

  // Estado proveniente del core
  input  logic                 core_busy,
  input  logic                 core_done,
  input  logic                 core_error,

  // Contadores de rendimiento
  input  logic [31:0]          perf_cyc,
  input  logic [31:0]          perf_pix,

  // Puerto HOST hacia BRAM de entrada
  output logic                 in_host_we,
  output logic [IN_ADDR_WIDTH-1:0] in_host_addr,
  output logic [31:0]          in_host_wdata,
  input  logic [31:0]          in_host_rdata,

  // Puerto HOST hacia BRAM de salida
  output logic [OUT_ADDR_WIDTH-1:0] out_host_addr,
  input  logic [31:0]          out_host_rdata
);

  // Registros internos
  logic [15:0] reg_img_w;
  logic [15:0] reg_img_h;
  logic [15:0] reg_scale_q8_8;
  logic [1:0]  reg_mode;

  logic [IN_ADDR_WIDTH-1:0]  reg_in_addr;
  logic [OUT_ADDR_WIDTH-1:0] reg_out_addr;

  // Pulsos
  logic start_pulse_q;
  logic soft_reset_pulse_q;

  // Escrituras de registros
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      reg_img_w        <= '0;
      reg_img_h        <= '0;
      reg_scale_q8_8   <= '0;
      reg_mode         <= '0;
      reg_in_addr      <= '0;
      reg_out_addr     <= '0;
    end else begin
      if (h_wr_en) begin
        unique case (h_addr)
          16'h0002: reg_img_w      <= h_wdata[15:0];
          16'h0003: reg_img_h      <= h_wdata[15:0];
          16'h0004: reg_scale_q8_8 <= h_wdata[15:0];
          16'h0005: reg_mode       <= h_wdata[1:0];

          // IN_ADDR: posición inicial en BRAM de entrada
          16'h0020: reg_in_addr    <= h_wdata[IN_ADDR_WIDTH-1:0];

          // OUT_ADDR: posición inicial en BRAM de salida
          16'h0030: reg_out_addr   <= h_wdata[OUT_ADDR_WIDTH-1:0];

          default: begin
          end
        endcase
      end

      // Autoincremento de IN_ADDR cuando se escribe IN_DATA
      if (h_wr_en && h_addr == 16'h0021) begin
        reg_in_addr <= reg_in_addr + 1'b1;
      end

      // Autoincremento de OUT_ADDR cuando se lee OUT_DATA
      if (h_rd_en && h_addr == 16'h0031) begin
        reg_out_addr <= reg_out_addr + 1'b1;
      end
    end
  end

  // Generación de pulsos START y SOFT_RESET
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      start_pulse_q       <= 1'b0;
      soft_reset_pulse_q  <= 1'b0;
    end else begin
      // Por defecto, pulsos en 0
      start_pulse_q       <= 1'b0;
      soft_reset_pulse_q  <= 1'b0;

      if (h_wr_en && h_addr == 16'h0000) begin
        if (h_wdata[0]) begin
          start_pulse_q <= 1'b1;
        end
        if (h_wdata[1]) begin
          soft_reset_pulse_q <= 1'b1;
        end
      end
    end
  end

  assign start_pulse       = start_pulse_q;
  assign soft_reset_pulse  = soft_reset_pulse_q;

  // Conexión de configuración hacia el core
  assign cfg_img_w       = reg_img_w;
  assign cfg_img_h       = reg_img_h;
  assign cfg_scale_q8_8  = reg_scale_q8_8;
  assign cfg_mode        = reg_mode;

  // Conexión a BRAM de entrada/salida
  assign in_host_we     = (h_wr_en && h_addr == 16'h0021);
  assign in_host_addr   = reg_in_addr;
  assign in_host_wdata  = h_wdata;

  assign out_host_addr  = reg_out_addr;

  // Lecturas de registros
  always_comb begin
    h_rdata  = 32'h0000_0000;

    unique case (h_addr)
      16'h0001: begin
        // STATUS: bit0=BUSY, bit1=DONE, bit2=ERROR
        h_rdata[0] = core_busy;
        h_rdata[1] = core_done;
        h_rdata[2] = core_error;
      end

      16'h0002: h_rdata[15:0] = reg_img_w;
      16'h0003: h_rdata[15:0] = reg_img_h;
      16'h0004: h_rdata[15:0] = reg_scale_q8_8;
      16'h0005: h_rdata[1:0]  = reg_mode;

      16'h0006: h_rdata = perf_cyc;
      16'h0007: h_rdata = perf_pix;

      // Lectura de IN_DATA (debug/opcional)
      16'h0021: h_rdata = in_host_rdata;

      // Lectura de OUT_DATA
      16'h0031: h_rdata = out_host_rdata;

      default: begin
        h_rdata = 32'h0000_0000;
      end
    endcase
  end

  // RVALID = 1 cuando hay lectura
  assign h_rvalid = h_rd_en;

endmodule