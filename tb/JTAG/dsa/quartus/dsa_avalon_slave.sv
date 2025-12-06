// Esclavo Avalon-MM que expone dsa_top_seq al JTAG-to-Avalon Master.

module dsa_avalon_slave #(
  parameter int ADDR_WIDTH = 16
) (
  input  logic                   clk,
  input  logic                   reset_n,
  input  logic                   step,

  // Avalon-MM slave
  input  logic [ADDR_WIDTH-1:0]  avs_address,
  input  logic                   avs_read,
  input  logic                   avs_write,
  input  logic [3:0]             avs_byteenable,
  input  logic [31:0]            avs_writedata,
  output logic [31:0]            avs_readdata,
  output logic                   avs_waitrequest
);

  // Señales internas h_*
  logic        h_wr_en;
  logic        h_rd_en;
  logic [15:0] h_addr;
  logic [31:0] h_wdata;
  logic [31:0] h_rdata;
  logic        h_rvalid;

  // Mapeo directo
  assign h_wr_en  = avs_write;
  assign h_rd_en  = avs_read;
  assign h_addr   = avs_address[15:0];
  assign h_wdata  = avs_writedata;

  assign avs_waitrequest = 1'b0;
  assign avs_readdata    = h_rdata;

  // Top lógico de la DSA
  dsa_top_seq #(
    .ADDR_WIDTH (16)
  ) u_dsa_top_seq (
    .clk      (clk),
    .rst_n    (reset_n),
	 .step     (step),
    .h_wr_en  (h_wr_en),
    .h_rd_en  (h_rd_en),
    .h_addr   (h_addr),
    .h_wdata  (h_wdata),
    .h_rdata  (h_rdata),
    .h_rvalid (h_rvalid)
  );

endmodule
