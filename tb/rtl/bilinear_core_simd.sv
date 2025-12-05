// tb/rtl/bilinear_core_simd.sv
// Núcleo paralelo: procesa N píxeles de salida por grupo (2 ciclos/grupo).
// Stepping: cuando step_mode=1, la FSM solo avanza cuando llega un "step"
// nuevo (step sube y step_ack=0 en ese flanco).

`timescale 1ns/1ps

module bilinear_core_simd #(
    parameter integer N     = 4,
    parameter integer W_MAX = 64,
    parameter integer H_MAX = 64
) (
    input  wire             clk,
    input  wire             rst_n,

    // Control
    input  wire             start,
    input  wire [15:0]      in_w,
    input  wire [15:0]      in_h,
    input  wire [15:0]      out_w,
    input  wire [15:0]      out_h,
    input  wire [15:0]      inv_scale_q,   // Q8.8 ≈ 1/scale

    // Stepping
    input  wire             step_mode,  // 0 = corre normal, 1 = stepping
    input  wire             step,       // pedido de paso
    output reg              step_ack,   // 1 cuando se consumió este paso

    // Estado
    output reg              busy,
    output reg              done,

    // Lectura de "BRAM" de entrada (4 vecinos por píxel, N lanes)
    output reg [N*32-1:0]   rd_addr0,
    output reg [N*32-1:0]   rd_addr1,
    output reg [N*32-1:0]   rd_addr2,
    output reg [N*32-1:0]   rd_addr3,
    input  wire [N*8-1:0]   rd_data0,
    input  wire [N*8-1:0]   rd_data1,
    input  wire [N*8-1:0]   rd_data2,
    input  wire [N*8-1:0]   rd_data3,

    // Escritura de salida
    output reg [N-1:0]      wr_valid,
    output reg [N*32-1:0]   wr_addr,
    output reg [N*8-1:0]    wr_data
);

    // Q8.8
    localparam integer FRAC_BITS = 8;
    localparam integer ONE_Q     = 1 << FRAC_BITS; // 256

    // Índices de píxel de salida por grupo:
    // cur_x_base : x del lane 0; lane k usa xo = cur_x_base + k
    reg [15:0] cur_x_base;
    reg [15:0] cur_y;

    // Estados de la FSM
    localparam [1:0] S_IDLE  = 2'd0;
    localparam [1:0] S_ISSUE = 2'd1;
    localparam [1:0] S_COMP  = 2'd2;

    reg [1:0] state;

    // Registros por lane (0..N-1) para coords y fracciones
    integer y0_i   [0:N-1];
    integer y1_i   [0:N-1];
    integer x0_i   [0:N-1];
    integer x1_i   [0:N-1];
    integer tx_q_i [0:N-1];
    integer ty_q_i [0:N-1];
    reg     lane_active [0:N-1];   // 1 si ese lane es válido en el grupo actual

    // Auxiliares para coordenadas
    integer yo_int, xo_int;
    integer yo_q, xo_q;
    integer temp_q_y, temp_q_x;
    integer ys_q, xs_q;
    integer y_int, x_int;

    // Auxiliares para interpolación
    integer wx0, wy0;
    integer w00, w10, w01, w11;
    integer acc;
    integer pix;

    integer lane;  // índice para bucles

    // Señal interna: ¿esta subida de reloj avanza la FSM?
    reg do_step;

    // ----------------------------------------------------------------
    // Lógica secuencial principal + stepping
    // ----------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            busy        <= 1'b0;
            done        <= 1'b0;
            step_ack    <= 1'b0;
            wr_valid    <= {N{1'b0}};
            wr_addr     <= {N*32{1'b0}};
            wr_data     <= {N*8{1'b0}};
            rd_addr0    <= {N*32{1'b0}};
            rd_addr1    <= {N*32{1'b0}};
            rd_addr2    <= {N*32{1'b0}};
            rd_addr3    <= {N*32{1'b0}};
            cur_x_base  <= 16'd0;
            cur_y       <= 16'd0;
            state       <= S_IDLE;
            do_step     <= 1'b0;
            for (lane = 0; lane < N; lane = lane+1) begin
                lane_active[lane] <= 1'b0;
                y0_i[lane]        <= 0;
                y1_i[lane]        <= 0;
                x0_i[lane]        <= 0;
                x1_i[lane]        <= 0;
                tx_q_i[lane]      <= 0;
                ty_q_i[lane]      <= 0;
            end
        end else begin
            // defaults
            wr_valid <= {N{1'b0}};
            do_step  <= 1'b0;

            // ---------- handshake + cálculo de do_step ----------
            if (!step_mode) begin
                // modo normal: siempre avanzamos
                do_step  <= 1'b1;
                step_ack <= 1'b0;
            end else begin
                // modo stepping
                if (step && !step_ack) begin
                    // nuevo paso pedido → avanzamos y levantamos ACK
                    do_step  <= 1'b1;
                    step_ack <= 1'b1;
                end else if (!step && step_ack) begin
                    // host bajó STEP → limpiamos ACK
                    step_ack <= 1'b0;
                end
                // en los demás casos: do_step=0, no avanza FSM
            end

            // ---------- avance de la FSM SOLO si do_step=1 ----------
            if (do_step) begin
                case (state)
                    //--------------------------------------------------
                    S_IDLE: begin
                        busy <= 1'b0;
                        // done se limpia al iniciar un nuevo procesamiento
                        if (start) begin
                            busy       <= 1'b1;
                            done       <= 1'b0;
                            cur_x_base <= 16'd0;
                            cur_y      <= 16'd0;
                            state      <= S_ISSUE;
                            $display("[SIMD] START t=%0t out_w=%0d out_h=%0d N=%0d",
                                     $time, out_w, out_h, N);
                        end
                    end

                    //--------------------------------------------------
                    // ISSUE: calcular coords y direcciones para N lanes
                    //--------------------------------------------------
                    S_ISSUE: begin
                        for (lane = 0; lane < N; lane = lane+1) begin
                            integer xo;
                            xo = cur_x_base + lane;

                            if (xo < out_w) begin
                                lane_active[lane] <= 1'b1;

                                yo_int = cur_y;
                                xo_int = xo;

                                yo_q = (yo_int << FRAC_BITS) + (ONE_Q/2);
                                temp_q_y = (yo_q * inv_scale_q) >> FRAC_BITS;
                                ys_q     = temp_q_y - (ONE_Q/2);

                                xo_q = (xo_int << FRAC_BITS) + (ONE_Q/2);
                                temp_q_x = (xo_q * inv_scale_q) >> FRAC_BITS;
                                xs_q     = temp_q_x - (ONE_Q/2);

                                y_int = ys_q >>> FRAC_BITS;
                                if (y_int < 0)           y_int = 0;
                                else if (y_int > in_h-1) y_int = in_h-1;

                                x_int = xs_q >>> FRAC_BITS;
                                if (x_int < 0)           x_int = 0;
                                else if (x_int > in_w-1) x_int = in_w-1;

                                y0_i[lane] = y_int;
                                if (y_int + 1 <= in_h-1) y1_i[lane] = y_int + 1;
                                else                     y1_i[lane] = y_int;

                                x0_i[lane] = x_int;
                                if (x_int + 1 <= in_w-1) x1_i[lane] = x_int + 1;
                                else                     x1_i[lane] = x_int;

                                ty_q_i[lane] = ys_q & (ONE_Q - 1);
                                tx_q_i[lane] = xs_q & (ONE_Q - 1);
                                if (ty_q_i[lane] < 0)     ty_q_i[lane] = 0;
                                if (ty_q_i[lane] > 255)   ty_q_i[lane] = 255;
                                if (tx_q_i[lane] < 0)     tx_q_i[lane] = 0;
                                if (tx_q_i[lane] > 255)   tx_q_i[lane] = 255;

                                rd_addr0[lane*32 +: 32] <= y0_i[lane]*in_w + x0_i[lane];
                                rd_addr1[lane*32 +: 32] <= y0_i[lane]*in_w + x1_i[lane];
                                rd_addr2[lane*32 +: 32] <= y1_i[lane]*in_w + x0_i[lane];
                                rd_addr3[lane*32 +: 32] <= y1_i[lane]*in_w + x1_i[lane];

                            end else begin
                                lane_active[lane]        <= 1'b0;
                                rd_addr0[lane*32 +: 32]  <= 32'd0;
                                rd_addr1[lane*32 +: 32]  <= 32'd0;
                                rd_addr2[lane*32 +: 32]  <= 32'd0;
                                rd_addr3[lane*32 +: 32]  <= 32'd0;
                            end
                        end
                        state <= S_COMP;
                    end

                    //--------------------------------------------------
                    // S_COMP: usa rd_dataX para N lanes y emite N píxeles
                    //--------------------------------------------------
                    S_COMP: begin
                        for (lane = 0; lane < N; lane = lane+1) begin
                            if (lane_active[lane]) begin
                                integer I00, I10, I01, I11;

                                I00 = rd_data0[lane*8 +: 8];
                                I10 = rd_data1[lane*8 +: 8];
                                I01 = rd_data2[lane*8 +: 8];
                                I11 = rd_data3[lane*8 +: 8];

                                wx0 = ONE_Q - tx_q_i[lane];
                                wy0 = ONE_Q - ty_q_i[lane];

                                w00 = wx0          * wy0;
                                w10 = tx_q_i[lane] * wy0;
                                w01 = wx0          * ty_q_i[lane];
                                w11 = tx_q_i[lane] * ty_q_i[lane];

                                acc = I00*w00 + I10*w10 + I01*w01 + I11*w11;

                                pix = (acc + (1 << 15)) >>> 16;
                                if (pix < 0)        pix = 0;
                                else if (pix > 255) pix = 255;

                                wr_addr[lane*32 +: 32] <= cur_y * out_w + (cur_x_base + lane);
                                wr_data[lane*8 +: 8]   <= pix[7:0];
                                wr_valid[lane]         <= 1'b1;
                            end else begin
                                wr_valid[lane] <= 1'b0;
                            end
                        end

                        // avanzar grupo de N píxeles
                        if (cur_x_base + N < out_w) begin
                            cur_x_base <= cur_x_base + N[15:0];
                            state      <= S_ISSUE;
                        end else begin
                            cur_x_base <= 16'd0;
                            if (cur_y + 1 < out_h) begin
                                cur_y <= cur_y + 1;
                                state <= S_ISSUE;
                            end else begin
                                busy  <= 1'b0;
                                done  <= 1'b1;
                                state <= S_IDLE;
                                $display("[SIMD] DONE t=%0t", $time);
                            end
                        end
                    end

                    default: begin
                        state <= S_IDLE;
                    end
                endcase
            end // if (do_step)
        end
    end

endmodule
