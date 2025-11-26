// Contadores de rendimiento:
//  - perf_cyc: cuenta ciclos activos entre start y done
//  - perf_pix: cuenta píxeles válidos producidos entre start y done

module perf_counters #(
    parameter int N_LANES       = 1,
    parameter int COUNTER_WIDTH = 32
) (
    input  logic                     clk,
    input  logic                     rst_n,

    // Control de medición
    input  logic                     start,     // pulso: inicia medición y resetea contadores
    input  logic                     done,      // nivel/pulso: termina medición
    input  logic                     enable,    // habilita/deshabilita contar
    input  logic [N_LANES-1:0]       pix_valid_mask,

    // Contadores de salida
    output logic [COUNTER_WIDTH-1:0] perf_cyc,
    output logic [COUNTER_WIDTH-1:0] perf_pix
);
    logic counting;

    // counting
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            counting <= 1'b0;
        end else begin
            if (start) begin
                // Arranca una nueva medición
                counting <= 1'b1;
            end else if (done) begin
                // Detiene la medición
                counting <= 1'b0;
            end
        end
    end

    // Contador de ciclos y píxeles
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            perf_cyc <= '0;
            perf_pix <= '0;
        end else begin
            if (start) begin
                perf_cyc <= '0;
                perf_pix <= '0;
            end else if (counting && enable) begin
                perf_cyc <= perf_cyc + {{(COUNTER_WIDTH-1){1'b0}}, 1'b1};

                perf_pix <= perf_pix + $countones(pix_valid_mask);
            end
        end
    end

endmodule
