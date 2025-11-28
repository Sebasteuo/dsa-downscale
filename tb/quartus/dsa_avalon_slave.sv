// Wrapper que expone dsa_top_task2 como esclavo Avalon-MM.
//
// Puertos típicos Avalon-MM slave:
//  - clk, reset
//  - address       : índice de palabra (lo traduce la interconexión)
//  - read, write   : señales de lectura/escritura
//  - writedata     : datos de escritura
//  - readdata      : datos de lectura
//  - byteenable    : se ignora (siempre 32 bits completos)
//  - waitrequest   : siempre 0 (sin backpressure)

module dsa_avalon_slave #(
  parameter int ADDR_WIDTH     = 16,
  parameter int IN_ADDR_WIDTH  = 18,
  parameter int OUT_ADDR_WIDTH = 18,
  parameter int N_LANES        = 1
) (
  input  logic                 clk,
  input  logic                 reset,

  // Avalon-MM slave
  input  logic [ADDR_WIDTH-1:0] avs_address,
  input  logic                  avs_read,
  input  logic                  avs_write,
  input  logic [3:0]            avs_byteenable,
  input  logic [31:0]           avs_writedata,
  output logic [31:0]           avs_readdata,
  output logic                  avs_waitrequest
);

  // Señales internas del bus "host" hacia dsa_top_task2
  logic        h_wr_en;
  logic        h_rd_en;
  logic [15:0] h_addr;
  logic [31:0] h_wdata;
  logic [31:0] h_rdata;
  logic        h_rvalid;

  // Mapeo directo
  assign h_wr_en   = avs_write;
  assign h_rd_en   = avs_read;
  assign h_addr    = avs_address[15:0];
  assign h_wdata   = avs_writedata;

  assign avs_waitrequest = 1'b0;

  // Salida de lectura
  assign avs_readdata = h_rdata;

  // Instancia del top lógico de la DSA
  dsa_top_task2 #(
    .N_LANES        (N_LANES),
    .IN_ADDR_WIDTH  (IN_ADDR_WIDTH),
    .OUT_ADDR_WIDTH (OUT_ADDR_WIDTH)
  ) u_dsa_top_task2 (
    .clk      (clk),
    .rst_n    (reset),

    .h_wr_en  (h_wr_en),
    .h_rd_en  (h_rd_en),
    .h_addr   (h_addr),
    .h_wdata  (h_wdata),
    .h_rdata  (h_rdata),
    .h_rvalid (h_rvalid)
  );

endmodule