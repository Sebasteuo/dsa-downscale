// Memoria RAM dual-port para almacenar imágenes.

module image_bram #(
  parameter int ADDR_WIDTH = 18,
  parameter int DATA_WIDTH = 32
) (
  input  logic                  clk,

  // Puerto A: HOST (lectura/escritura)
  input  logic                  a_we,
  input  logic [ADDR_WIDTH-1:0] a_addr,
  input  logic [DATA_WIDTH-1:0] a_wdata,
  output logic [DATA_WIDTH-1:0] a_rdata,

  // Puerto B: CORE (lectura/escritura)
  input  logic                  b_we,
  input  logic [ADDR_WIDTH-1:0] b_addr,
  input  logic [DATA_WIDTH-1:0] b_wdata,
  output logic [DATA_WIDTH-1:0] b_rdata
);

  (* ramstyle = "M10K" *) logic [DATA_WIDTH-1:0] mem [0:(1<<ADDR_WIDTH)-1];

  always_ff @(posedge clk) begin
    // Puerto A
    if (a_we) begin
      mem[a_addr] <= a_wdata;
    end
    a_rdata <= mem[a_addr];

    // Puerto B
    if (b_we) begin
      mem[b_addr] <= b_wdata;
    end
    b_rdata <= mem[b_addr];
  end

endmodule