// tb/rtl/bilinear_core_scalar.sv
// Núcleo secuencial: procesa 1 píxel de salida en varios ciclos.
// - Misma aritmética que el core "100%" (Q8.8).
// - Sin 'integer' genéricos: logic signed [31:0].
// - La suma de I*w se SERIALIZA en 4 subfases dentro de S_COMP.

`timescale 1ns/1ps

module bilinear_core_scalar #(
    parameter W_MAX = 64,
    parameter H_MAX = 64
) (
    input        clk,
    input        rst_n,

    // Control
    input        start,
    input  [15:0] in_w,
    input  [15:0] in_h,
    input  [15:0] out_w,
    input  [15:0] out_h,
    input  [15:0] inv_scale_q,   // Q8.8 ≈ 1/scale

    // Stepping
    input        step_mode,  // 0 = corre normal, 1 = stepping
    input        step,       // pedido de paso (desde CTRL.STEP)
    output reg   step_ack,   // se pone en 1 cuando se consumió ese paso

    // Estado
    output reg   busy,
    output reg   done,

    // Lectura de BRAM de entrada (4 vecinos por píxel)
    output reg [31:0] rd_addr0,
    output reg [31:0] rd_addr1,
    output reg [31:0] rd_addr2,
    output reg [31:0] rd_addr3,
    input      [7:0]  rd_data0,
    input      [7:0]  rd_data1,
    input      [7:0]  rd_data2,
    input      [7:0]  rd_data3,

    // Escritura de salida
    output reg        wr_valid,
    output reg [31:0] wr_addr,
    output reg [7:0]  wr_data
);

    // Q8.8
    localparam FRAC_BITS = 8;
    localparam ONE_Q     = 1 << FRAC_BITS; // 256

    // Índices de píxel de salida (xo, yo)
    reg [15:0] cur_x, cur_y;

    // Estados de la FSM
    localparam S_IDLE  = 2'd0;
    localparam S_ISSUE = 2'd1;
    localparam S_COMP  = 2'd2;

    reg [1:0] state;

    // ----- Variables internas con ancho fijo (equivalentes a integer) -----
    // Coordenadas y fracciones
    logic signed [31:0] y0_i, y1_i, x0_i, x1_i;
    logic signed [31:0] tx_q_i, ty_q_i;
    logic signed [31:0] yo_int, xo_int;
    logic signed [31:0] yo_q, xo_q;
    logic signed [31:0] temp_q_y, temp_q_x;
    logic signed [31:0] ys_q, xs_q;
    logic signed [31:0] y_int, x_int;

    // Pesos e interpolación
    logic signed [31:0] wx0, wy0;
    logic signed [31:0] w00, w10, w01, w11;

    // Serialización de productos I*w
    reg  [2:0]         comp_phase;  // 0..4
    logic signed [31:0] acc_r;      // acumulador parcial
    logic signed [31:0] acc_final;
    logic signed [31:0] pix;

    // ----------------------------------------------------------------
    // Lógica secuencial principal + stepping
    // ----------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            busy       <= 1'b0;
            done       <= 1'b0;
            wr_valid   <= 1'b0;
            wr_addr    <= 32'd0;
            wr_data    <= 8'd0;
            cur_x      <= 16'd0;
            cur_y      <= 16'd0;
            rd_addr0   <= 32'd0;
            rd_addr1   <= 32'd0;
            rd_addr2   <= 32'd0;
            rd_addr3   <= 32'd0;
            state      <= S_IDLE;
            step_ack   <= 1'b0;

            y0_i       <= '0;
            y1_i       <= '0;
            x0_i       <= '0;
            x1_i       <= '0;
            tx_q_i     <= '0;
            ty_q_i     <= '0;
            yo_int     <= '0;
            xo_int     <= '0;
            yo_q       <= '0;
            xo_q       <= '0;
            temp_q_y   <= '0;
            temp_q_x   <= '0;
            ys_q       <= '0;
            xs_q       <= '0;
            y_int      <= '0;
            x_int      <= '0;
            wx0        <= '0;
            wy0        <= '0;
            w00        <= '0;
            w10        <= '0;
            w01        <= '0;
            w11        <= '0;
            comp_phase <= 3'd0;
            acc_r      <= '0;
            acc_final  <= '0;
            pix        <= '0;
        end else begin
            // default
            wr_valid <= 1'b0;

            // ---------------------------
            // Modo stepping
            // ---------------------------
            if (step_mode) begin
                if (step && !step_ack) begin
                    step_ack <= 1'b1;

                    case (state)
                        //--------------------------------------------------
                        S_IDLE: begin
                            busy <= 1'b0;
                            if (start) begin
                                busy       <= 1'b1;
                                done       <= 1'b0;
                                cur_x      <= 16'd0;
                                cur_y      <= 16'd0;
                                state      <= S_ISSUE;
                                comp_phase <= 3'd0;
                                $display("[CORE] START t=%0t out_w=%0d out_h=%0d", $time, out_w, out_h);
                            end
                        end

                        //--------------------------------------------------
                        S_ISSUE: begin
                            yo_int = cur_y;
                            xo_int = cur_x;

                            // (yo + 0.5) en Q8.8
                            yo_q     = (yo_int <<< FRAC_BITS) + (ONE_Q/2);
                            temp_q_y = (yo_q * $signed(inv_scale_q)) >>> FRAC_BITS;
                            ys_q     = temp_q_y - (ONE_Q/2);

                            // (xo + 0.5) en Q8.8
                            xo_q     = (xo_int <<< FRAC_BITS) + (ONE_Q/2);
                            temp_q_x = (xo_q * $signed(inv_scale_q)) >>> FRAC_BITS;
                            xs_q     = temp_q_x - (ONE_Q/2);

                            // Parte entera (clamp)
                            y_int = ys_q >>> FRAC_BITS;
                            if (y_int < 0)
                                y_int = 0;
                            else if (y_int > $signed(in_h-1))
                                y_int = $signed(in_h-1);

                            x_int = xs_q >>> FRAC_BITS;
                            if (x_int < 0)
                                x_int = 0;
                            else if (x_int > $signed(in_w-1))
                                x_int = $signed(in_w-1);

                            y0_i = y_int;
                            if (y_int + 1 <= $signed(in_h-1))
                                y1_i = y_int + 1;
                            else
                                y1_i = y_int;

                            x0_i = x_int;
                            if (x_int + 1 <= $signed(in_w-1))
                                x1_i = x_int + 1;
                            else
                                x1_i = x_int;

                            // Parte fraccional (0..255)
                            ty_q_i = ys_q & (ONE_Q - 1);
                            tx_q_i = xs_q & (ONE_Q - 1);
                            if (ty_q_i < 0)     ty_q_i = 0;
                            if (ty_q_i > 255)   ty_q_i = 255;
                            if (tx_q_i < 0)     tx_q_i = 0;
                            if (tx_q_i > 255)   tx_q_i = 255;

                            // Direcciones lineales: img[y][x] -> y*in_w + x
                            rd_addr0 <= y0_i*in_w + x0_i;
                            rd_addr1 <= y0_i*in_w + x1_i;
                            rd_addr2 <= y1_i*in_w + x0_i;
                            rd_addr3 <= y1_i*in_w + x1_i;

                            comp_phase <= 3'd0;
                            acc_r      <= 32'sd0;
                            state      <= S_COMP;
                        end

                        //--------------------------------------------------
                        S_COMP: begin
                            case (comp_phase)
                                // Fase 0: calcular pesos como en el core original
                                3'd0: begin
                                    wx0 <= ONE_Q - tx_q_i;
                                    wy0 <= ONE_Q - ty_q_i;

                                    w00 <= (ONE_Q - tx_q_i) * (ONE_Q - ty_q_i);
                                    w10 <= tx_q_i           * (ONE_Q - ty_q_i);
                                    w01 <= (ONE_Q - tx_q_i) * ty_q_i;
                                    w11 <= tx_q_i           * ty_q_i;

                                    acc_r      <= 32'sd0;
                                    comp_phase <= 3'd1;
                                end

                                // Fase 1: acc_r = rd_data0*w00
                                3'd1: begin
                                    acc_r      <= rd_data0 * w00;
                                    comp_phase <= 3'd2;
                                end

                                // Fase 2: acc_r += rd_data1*w10
                                3'd2: begin
                                    acc_r      <= acc_r + rd_data1 * w10;
                                    comp_phase <= 3'd3;
                                end

                                // Fase 3: acc_r += rd_data2*w01
                                3'd3: begin
                                    acc_r      <= acc_r + rd_data2 * w01;
                                    comp_phase <= 3'd4;
                                end

                                // Fase 4: acc_final = acc_r + rd_data3*w11; luego pix
                                3'd4: begin
                                    acc_final = acc_r + rd_data3 * w11;

                                    pix = (acc_final + (1 <<< 15)) >>> 16;
                                    if (pix < 0)
                                        pix = 0;
                                    else if (pix > 255)
                                        pix = 255;

                                    wr_addr  <= cur_y * out_w + cur_x;
                                    wr_data  <= pix[7:0];
                                    wr_valid <= 1'b1;

                                    if (cur_x + 1 < out_w) begin
                                        cur_x      <= cur_x + 1;
                                        state      <= S_ISSUE;
                                        comp_phase <= 3'd0;
                                    end else begin
                                        cur_x <= 16'd0;
                                        if (cur_y + 1 < out_h) begin
                                            cur_y      <= cur_y + 1;
                                            state      <= S_ISSUE;
                                            comp_phase <= 3'd0;
                                        end else begin
                                            busy       <= 1'b0;
                                            done       <= 1'b1;
                                            state      <= S_IDLE;
                                            comp_phase <= 3'd0;
                                            $display("[CORE] DONE t=%0t", $time);
                                        end
                                    end
                                end

                                default: comp_phase <= 3'd0;
                            endcase
                        end

                        default: state <= S_IDLE;
                    endcase

                end else if (!step && step_ack) begin
                    step_ack <= 1'b0;
                end

            end else begin
                // ---------------------------
                // Modo normal (sin stepping)
                // ---------------------------
                step_ack <= 1'b0;

                case (state)
                    S_IDLE: begin
                        busy <= 1'b0;
                        if (start) begin
                            busy       <= 1'b1;
                            done       <= 1'b0;
                            cur_x      <= 16'd0;
                            cur_y      <= 16'd0;
                            state      <= S_ISSUE;
                            comp_phase <= 3'd0;
                            $display("[CORE] START t=%0t out_w=%0d out_h=%0d", $time, out_w, out_h);
                        end
                    end

                    S_ISSUE: begin
                        yo_int = cur_y;
                        xo_int = cur_x;

                        yo_q     = (yo_int <<< FRAC_BITS) + (ONE_Q/2);
                        temp_q_y = (yo_q * $signed(inv_scale_q)) >>> FRAC_BITS;
                        ys_q     = temp_q_y - (ONE_Q/2);

                        xo_q     = (xo_int <<< FRAC_BITS) + (ONE_Q/2);
                        temp_q_x = (xo_q * $signed(inv_scale_q)) >>> FRAC_BITS;
                        xs_q     = temp_q_x - (ONE_Q/2);

                        y_int = ys_q >>> FRAC_BITS;
                        if (y_int < 0)
                            y_int = 0;
                        else if (y_int > $signed(in_h-1))
                            y_int = $signed(in_h-1);

                        x_int = xs_q >>> FRAC_BITS;
                        if (x_int < 0)
                            x_int = 0;
                        else if (x_int > $signed(in_w-1))
                            x_int = $signed(in_w-1);

                        y0_i = y_int;
                        if (y_int + 1 <= $signed(in_h-1))
                            y1_i = y_int + 1;
                        else
                            y1_i = y_int;

                        x0_i = x_int;
                        if (x_int + 1 <= $signed(in_w-1))
                            x1_i = x_int + 1;
                        else
                            x1_i = x_int;

                        ty_q_i = ys_q & (ONE_Q - 1);
                        tx_q_i = xs_q & (ONE_Q - 1);
                        if (ty_q_i < 0)     ty_q_i = 0;
                        if (ty_q_i > 255)   ty_q_i = 255;
                        if (tx_q_i < 0)     tx_q_i = 0;
                        if (tx_q_i > 255)   tx_q_i = 255;

                        rd_addr0 <= y0_i*in_w + x0_i;
                        rd_addr1 <= y0_i*in_w + x1_i;
                        rd_addr2 <= y1_i*in_w + x0_i;
                        rd_addr3 <= y1_i*in_w + x1_i;

                        comp_phase <= 3'd0;
                        acc_r      <= 32'sd0;
                        state      <= S_COMP;
                    end

                    S_COMP: begin
                        case (comp_phase)
                            3'd0: begin
                                wx0 <= ONE_Q - tx_q_i;
                                wy0 <= ONE_Q - ty_q_i;

                                w00 <= (ONE_Q - tx_q_i) * (ONE_Q - ty_q_i);
                                w10 <= tx_q_i           * (ONE_Q - ty_q_i);
                                w01 <= (ONE_Q - tx_q_i) * ty_q_i;
                                w11 <= tx_q_i           * ty_q_i;

                                acc_r      <= 32'sd0;
                                comp_phase <= 3'd1;
                            end

                            3'd1: begin
                                acc_r      <= rd_data0 * w00;
                                comp_phase <= 3'd2;
                            end

                            3'd2: begin
                                acc_r      <= acc_r + rd_data1 * w10;
                                comp_phase <= 3'd3;
                            end

                            3'd3: begin
                                acc_r      <= acc_r + rd_data2 * w01;
                                comp_phase <= 3'd4;
                            end

                            3'd4: begin
                                acc_final = acc_r + rd_data3 * w11;

                                pix = (acc_final + (1 <<< 15)) >>> 16;
                                if (pix < 0)
                                    pix = 0;
                                else if (pix > 255)
                                    pix = 255;

                                wr_addr  <= cur_y * out_w + cur_x;
                                wr_data  <= pix[7:0];
                                wr_valid <= 1'b1;

                                if (cur_x + 1 < out_w) begin
                                    cur_x      <= cur_x + 1;
                                    state      <= S_ISSUE;
                                    comp_phase <= 3'd0;
                                end else begin
                                    cur_x <= 16'd0;
                                    if (cur_y + 1 < out_h) begin
                                        cur_y      <= cur_y + 1;
                                        state      <= S_ISSUE;
                                        comp_phase <= 3'd0;
                                    end else begin
                                        busy       <= 1'b0;
                                        done       <= 1'b1;
                                        state      <= S_IDLE;
                                        comp_phase <= 3'd0;
                                        $display("[CORE] DONE t=%0t", $time);
                                    end
                                end
                            end

                            default: comp_phase <= 3'd0;
                        endcase
                    end

                    default: state <= S_IDLE;
                endcase
            end
        end
    end

endmodule
