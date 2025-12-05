// tb/rtl/bilinear_top.sv
// Top sintetizable para bilinear downscale.
// - Selecciona entre core escalar y SIMD por CTRL.MODE.
// - Registros tipo CSR:
//   CTRL    (0x0)  : EN, START, MODE, STEP_MODE, STEP, UNIDADES...
//   STATUS  (0x4)  : BUSY, DONE, ERR, STEP_ACK
//   SCALE_Q (0x8)  : inv_scale_q (Q8.8) en [15:0]
//   IN_W_H  (0xC)  : {in_w[31:16], in_h[15:0]}
//   OUT_W_H (0x10) : {out_w[31:16], out_h[15:0]}
//   PERF_CYC(0x14) : ciclos de procesamiento
//   PERF_PIX(0x18) : píxeles producidos
//
// - Interfaz de memoria estilo SIMD (N lanes):
//      rd_addrX  : N direcciones de 32 bits
//      rd_dataX  : N bytes
//      wr_valid  : N bits
//      wr_addr   : N direcciones de 32 bits
//      wr_data   : N bytes
//
// En modo escalar sólo se usa el lane 0.

`timescale 1ns/1ps

module bilinear_top #(
    parameter integer N     = 4,
    parameter integer W_MAX = 1024,
    parameter integer H_MAX = 1024
) (
    input  wire             clk,
    input  wire             rst_n,

    // ---------------- Interfaz CSR simple ----------------
    input  wire             csr_we,      // write enable
    input  wire [3:0]       csr_addr,    // palabra (0,4,8,... en bytes)
    input  wire [31:0]      csr_wdata,
    output reg  [31:0]      csr_rdata,

    // ---------------- Interfaz de memoria empaquetada ----------------
    // Lectura (4 vecinos por píxel, N lanes)
    output wire [N*32-1:0]  rd_addr0,
    output wire [N*32-1:0]  rd_addr1,
    output wire [N*32-1:0]  rd_addr2,
    output wire [N*32-1:0]  rd_addr3,
    input  wire [N*8-1:0]   rd_data0,
    input  wire [N*8-1:0]   rd_data1,
    input  wire [N*8-1:0]   rd_data2,
    input  wire [N*8-1:0]   rd_data3,

    // Escritura de salida (N lanes)
    output wire [N-1:0]     wr_valid,
    output wire [N*32-1:0]  wr_addr,
    output wire [N*8-1:0]   wr_data
);

    // ---------------- Direcciones de CSR ----------------
    localparam [3:0] CSR_CTRL     = 4'h0;
    localparam [3:0] CSR_STATUS   = 4'h1;
    localparam [3:0] CSR_SCALE_Q  = 4'h2;
    localparam [3:0] CSR_IN_W_H   = 4'h3;
    localparam [3:0] CSR_OUT_W_H  = 4'h4;
    localparam [3:0] CSR_PERF_CYC = 4'h5;
    localparam [3:0] CSR_PERF_PIX = 4'h6;

    // ---------------- Registros CSR ----------------
    reg [31:0] ctrl_reg;
    reg [31:0] scale_q_reg;
    reg [31:0] in_w_h_reg;
    reg [31:0] out_w_h_reg;

    reg [31:0] perf_cycles;
    reg [31:0] perf_pixels;

    // STATUS se arma combinacionalmente a partir de core activo
    reg [31:0] status_reg;
    reg [7:0] pix_inc;

    // ---------- Campos útiles de CTRL ----------
    wire ctrl_en        = ctrl_reg[0];   // EN
    wire ctrl_mode      = ctrl_reg[2];   // 0 = escalar, 1 = SIMD
    wire ctrl_step_mode = ctrl_reg[3];   // 0 normal, 1 stepping
    wire ctrl_step      = ctrl_reg[4];   // STEP (host hace handshake con STEP_ACK)
    // ctrl_reg[1] = START (se usa como pulso, no se guarda como tal)
    // ctrl_reg[7:4] = UNIDADES (informativo, aquí no se usa para HW)

    // START interno como pulso de 1 ciclo cuando se escribe CTRL.START=1
    reg start_pulse;

    // ---------- Campos de dimensiones ----------
    wire [15:0] in_w        = in_w_h_reg[31:16];
    wire [15:0] in_h        = in_w_h_reg[15:0];
    wire [15:0] out_w       = out_w_h_reg[31:16];
    wire [15:0] out_h       = out_w_h_reg[15:0];
    wire [15:0] inv_scale_q = scale_q_reg[15:0];

    // ---------------- Señales de los cores ----------------
    // Escalar
    wire        busy_scalar, done_scalar;
    wire        wr_valid_scalar;
    wire [31:0] wr_addr_scalar;
    wire [7:0]  wr_data_scalar;
    wire [31:0] rd_addr0_scalar, rd_addr1_scalar, rd_addr2_scalar, rd_addr3_scalar;
    wire [7:0]  rd_data0_scalar, rd_data1_scalar, rd_data2_scalar, rd_data3_scalar;
    wire        step_ack_scalar;

    // SIMD
    wire        busy_simd, done_simd;
    wire [N-1:0]    wr_valid_simd;
    wire [N*32-1:0] wr_addr_simd;
    wire [N*8-1:0]  wr_data_simd;
    wire [N*32-1:0] rd_addr0_simd, rd_addr1_simd, rd_addr2_simd, rd_addr3_simd;
    wire [N*8-1:0]  rd_data0_simd, rd_data1_simd, rd_data2_simd, rd_data3_simd;
    wire            step_ack_simd;

    // Core activo según MODE
    wire core_busy     = (ctrl_mode == 1'b0) ? busy_scalar     : busy_simd;
    wire core_done     = (ctrl_mode == 1'b0) ? done_scalar     : done_simd;
    wire core_step_ack = (ctrl_mode == 1'b0) ? step_ack_scalar : step_ack_simd;

    // START separado por core (pulso)
    wire start_scalar = ctrl_en && start_pulse && (ctrl_mode == 1'b0);
    wire start_simd   = ctrl_en && start_pulse && (ctrl_mode == 1'b1);

    // ---------------- Escritura de CSRs ----------------
    integer k;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ctrl_reg     <= 32'd0;
            scale_q_reg  <= 32'd0;
            in_w_h_reg   <= 32'd0;
            out_w_h_reg  <= 32'd0;
            perf_cycles  <= 32'd0;
            perf_pixels  <= 32'd0;
            start_pulse  <= 1'b0;
        end else begin
            start_pulse <= 1'b0;  // default: sin pulso

            // Escritura de CSRs
            if (csr_we) begin
                case (csr_addr)
                    CSR_CTRL: begin
                        // START (bit 1) se usa como pulso, no se almacena como 1
                        ctrl_reg <= csr_wdata & ~(32'h2); // limpiar bit 1 almacenado
                        if (csr_wdata[1])
                            start_pulse <= 1'b1;
                    end
                    CSR_SCALE_Q: begin
                        scale_q_reg <= csr_wdata;
                    end
                    CSR_IN_W_H: begin
                        in_w_h_reg <= csr_wdata;
                    end
                    CSR_OUT_W_H: begin
                        out_w_h_reg <= csr_wdata;
                    end
                    default: ;
                endcase
            end

            // ----------- Contadores de desempeño -----------
            if (start_pulse) begin
                // Nuevo procesamiento → resetear contadores
                perf_cycles <= 32'd0;
                perf_pixels <= 32'd0;
            end else begin
                // ciclos mientras el core esté ocupado
                if (core_busy && !core_done)
                    perf_cycles <= perf_cycles + 1;

                // píxeles generados este ciclo
                // escalar: 1 si wr_valid_scalar
                // SIMD: popcount(wr_valid_simd)
                pix_inc = 8'd0;
                if (ctrl_mode == 1'b0) begin
                    if (wr_valid_scalar)
                        pix_inc = 8'd1;
                end else begin
                    for (k = 0; k < N; k = k + 1) begin
                        if (wr_valid_simd[k])
                            pix_inc = pix_inc + 1;
                    end
                end
                perf_pixels <= perf_pixels + pix_inc;
            end
        end
    end

    // ---------------- STATUS combinacional ----------------
    always @* begin
        status_reg       = 32'd0;
        status_reg[0]    = core_busy;      // BUSY
        status_reg[1]    = core_done;      // DONE
        status_reg[2]    = 1'b0;           // ERR (por ahora sin uso)
        status_reg[3]    = core_step_ack;  // STEP_ACK
        // demás bits en 0
    end

    // ---------------- Lectura de CSRs ----------------
    always @* begin
        case (csr_addr)
            CSR_CTRL:     csr_rdata = ctrl_reg;
            CSR_STATUS:   csr_rdata = status_reg;
            CSR_SCALE_Q:  csr_rdata = scale_q_reg;
            CSR_IN_W_H:   csr_rdata = in_w_h_reg;
            CSR_OUT_W_H:  csr_rdata = out_w_h_reg;
            CSR_PERF_CYC: csr_rdata = perf_cycles;
            CSR_PERF_PIX: csr_rdata = perf_pixels;
            default:      csr_rdata = 32'd0;
        endcase
    end

    // ---------------- Instancia core escalar ----------------
    bilinear_core_scalar #(
        .W_MAX(W_MAX),
        .H_MAX(H_MAX)
    ) core_scalar_u (
        .clk        (clk),
        .rst_n      (rst_n),

        .start      (start_scalar),
        .in_w       (in_w),
        .in_h       (in_h),
        .out_w      (out_w),
        .out_h      (out_h),
        .inv_scale_q(inv_scale_q),

        .step_mode  (ctrl_step_mode),
        .step       (ctrl_step),
        .step_ack   (step_ack_scalar),

        .busy       (busy_scalar),
        .done       (done_scalar),

        .rd_addr0   (rd_addr0_scalar),
        .rd_addr1   (rd_addr1_scalar),
        .rd_addr2   (rd_addr2_scalar),
        .rd_addr3   (rd_addr3_scalar),
        .rd_data0   (rd_data0_scalar),
        .rd_data1   (rd_data1_scalar),
        .rd_data2   (rd_data2_scalar),
        .rd_data3   (rd_data3_scalar),

        .wr_valid   (wr_valid_scalar),
        .wr_addr    (wr_addr_scalar),
        .wr_data    (wr_data_scalar)
    );

    // ---------------- Instancia core SIMD ----------------
    bilinear_core_simd #(
        .N    (N),
        .W_MAX(W_MAX),
        .H_MAX(H_MAX)
    ) core_simd_u (
        .clk         (clk),
        .rst_n       (rst_n),

        .start       (start_simd),
        .in_w        (in_w),
        .in_h        (in_h),
        .out_w       (out_w),
        .out_h       (out_h),
        .inv_scale_q (inv_scale_q),

        .step_mode   (ctrl_step_mode),
        .step        (ctrl_step),
        .step_ack    (step_ack_simd),

        .busy        (busy_simd),
        .done        (done_simd),

        .rd_addr0    (rd_addr0_simd),
        .rd_addr1    (rd_addr1_simd),
        .rd_addr2    (rd_addr2_simd),
        .rd_addr3    (rd_addr3_simd),
        .rd_data0    (rd_data0_simd),
        .rd_data1    (rd_data1_simd),
        .rd_data2    (rd_data2_simd),
        .rd_data3    (rd_data3_simd),

        .wr_valid    (wr_valid_simd),
        .wr_addr     (wr_addr_simd),
        .wr_data     (wr_data_simd)
    );

    // ---------------- Mux de memoria: core activo → interfaz externa ----------------
    // Lectura: direcciones hacia memoria
    assign rd_addr0 = (ctrl_mode == 1'b0)
                      ? { {(N-1)*32{1'b0}}, rd_addr0_scalar }
                      : rd_addr0_simd;

    assign rd_addr1 = (ctrl_mode == 1'b0)
                      ? { {(N-1)*32{1'b0}}, rd_addr1_scalar }
                      : rd_addr1_simd;

    assign rd_addr2 = (ctrl_mode == 1'b0)
                      ? { {(N-1)*32{1'b0}}, rd_addr2_scalar }
                      : rd_addr2_simd;

    assign rd_addr3 = (ctrl_mode == 1'b0)
                      ? { {(N-1)*32{1'b0}}, rd_addr3_scalar }
                      : rd_addr3_simd;

    // Lectura: datos desde memoria hacia core
    assign rd_data0_scalar = rd_data0[7:0];       // lane 0
    assign rd_data1_scalar = rd_data1[7:0];
    assign rd_data2_scalar = rd_data2[7:0];
    assign rd_data3_scalar = rd_data3[7:0];

    assign rd_data0_simd   = rd_data0;
    assign rd_data1_simd   = rd_data1;
    assign rd_data2_simd   = rd_data2;
    assign rd_data3_simd   = rd_data3;

    // Escritura: del core hacia interfaz externa
    assign wr_valid = (ctrl_mode == 1'b0)
                      ? { {(N-1){1'b0}}, wr_valid_scalar }
                      : wr_valid_simd;

    assign wr_addr  = (ctrl_mode == 1'b0)
                      ? { {(N-1)*32{1'b0}}, wr_addr_scalar }
                      : wr_addr_simd;

    assign wr_data  = (ctrl_mode == 1'b0)
                      ? { {(N-1)*8{1'b0}}, wr_data_scalar }
                      : wr_data_simd;

endmodule
