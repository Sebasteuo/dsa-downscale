//  - Entrada y salida en BRAM interna (arrays de 32 bits).
//  - Modo 0: core secuencial que copia in_mem -> out_mem.
//  - Modo 1: downscale con factor Q8.8 (nearest-neighbor / Bresenham).

module dsa_top_seq #(
  parameter int ADDR_WIDTH = 16,
  // Tamaño máximo soportado en esta etapa
  parameter int IMG_MAX_W  = 64,
  parameter int IMG_MAX_H  = 64
) (
  input  logic                  clk,
  input  logic                  rst_n,

  // Bus simple desde esclavo Avalon
  input  logic                  h_wr_en,
  input  logic                  h_rd_en,
  input  logic [ADDR_WIDTH-1:0] h_addr,
  input  logic [31:0]           h_wdata,
  output logic [31:0]           h_rdata,
  output logic                  h_rvalid
);

  // Parámetros y memoria
  localparam int MAX_PIXELS = IMG_MAX_W * IMG_MAX_H;         
  localparam int MAX_WORDS  = (MAX_PIXELS + 3) >> 2;        

  (* ramstyle = "M10K", no_rw_check *)
  logic [31:0] in_mem  [0:MAX_WORDS-1];

  (* ramstyle = "M10K", no_rw_check *)
  logic [31:0] out_mem [0:MAX_WORDS-1];

  // Registros de configuración / estado
  localparam logic [15:0] REG_CTRL      = 16'h0000;
  localparam logic [15:0] REG_STATUS    = 16'h0001;
  localparam logic [15:0] REG_IMG_W     = 16'h0002;
  localparam logic [15:0] REG_IMG_H     = 16'h0003;
  localparam logic [15:0] REG_SCALE     = 16'h0004;
  localparam logic [15:0] REG_MODE      = 16'h0005;
  localparam logic [15:0] REG_PERF_CYC  = 16'h0006;
  localparam logic [15:0] REG_PERF_PIX  = 16'h0007;

  localparam logic [15:0] REG_IN_ADDR   = 16'h0020;
  localparam logic [15:0] REG_IN_DATA   = 16'h0021;
  localparam logic [15:0] REG_OUT_ADDR  = 16'h0030;
  localparam logic [15:0] REG_OUT_DATA  = 16'h0031;

  // Config
  logic [15:0] img_w;
  logic [15:0] img_h;
  logic [15:0] scale_q8_8;  
  logic [7:0]  mode;    

  // punteros de BRAM
  logic [15:0] in_ptr;
  logic [15:0] out_ptr;

  // Status
  logic busy;
  logic done;

  // Performance
  logic [31:0] perf_cyc;
  logic [31:0] perf_pix;
  
  // Dimensiones de salida calculadas en HW (modo downscale)
  logic [15:0] out_w;
  logic [15:0] out_h;

  // Coordenadas actuales de salida (x_out, y_out)
  logic [15:0] ds_out_x;
  logic [15:0] ds_out_y;

  // Coordenadas actuales de entrada (x_in, y_in) mapeadas por Bresenham
  logic [15:0] ds_in_x;
  logic [15:0] ds_in_y;

  // Errores acumulados de Bresenham
  logic [31:0] ds_err_x;
  logic [31:0] ds_err_y;

  // Control de empaquetado de salida
  logic [31:0] ds_dst_word_idx;
  logic [1:0]  ds_dst_byte_pos;
  logic [31:0] ds_dst_word_data;

  // FSM
  typedef enum logic [1:0] {
    S_IDLE,
    S_RUN,
    S_DONE
  } core_state_t;

  core_state_t state;

  logic [15:0] word_idx;
  logic [15:0] word_count;

  // Pulso de start
  logic start_req;

  // Escrituras + FSM
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      img_w      			<= 16'd0;
      img_h      			<= 16'd0;
      scale_q8_8 			<= 16'd0;
      mode       			<= 8'd0;

      in_ptr     			<= 16'd0;
      out_ptr    			<= 16'd0;

      busy       			<= 1'b0;
      done       			<= 1'b0;

      perf_cyc   			<= 32'd0;
      perf_pix   			<= 32'd0;

      state      			<= S_IDLE;
      word_idx   			<= 16'd0;
      word_count 			<= 16'd0;
		
      out_w					<= 16'd0;
      out_h					<= 16'd0;
		
      ds_out_x				<= 16'd0;
      ds_out_y				<= 16'd0;
		
      ds_in_x				<= 16'd0;
      ds_in_y				<= 16'd0;
		
      ds_err_x				<= 32'd0;
      ds_err_y				<= 32'd0;
		
      ds_dst_word_idx	<= 32'd0;
      ds_dst_byte_pos	<= 2'd0;
      ds_dst_word_data	<= 32'd0;

      start_req  			<= 1'b0;
    end else begin
      start_req <= 1'b0;

      // Escrituras host
      if (h_wr_en) begin
        unique case (h_addr)
          REG_IMG_W:    img_w      <= h_wdata[15:0];
          REG_IMG_H:    img_h      <= h_wdata[15:0];
          REG_SCALE:    scale_q8_8 <= h_wdata[15:0];
          REG_MODE:     mode       <= h_wdata[7:0];

          REG_IN_ADDR:  in_ptr     <= h_wdata[15:0];

          REG_IN_DATA: begin
            if (in_ptr < MAX_WORDS[15:0]) begin
              in_mem[in_ptr] <= h_wdata;
              in_ptr         <= in_ptr + 16'd1;
            end
          end

          REG_OUT_ADDR: out_ptr    <= h_wdata[15:0];

          REG_CTRL: begin
            if (h_wdata[0])
              start_req <= 1'b1;
          end

          default: ;
        endcase
      end

      // Lectura de OUT_DATA -> autoincremento
      if (h_rd_en && (h_addr == REG_OUT_DATA)) begin
        if (out_ptr < MAX_WORDS[15:0]) begin
          out_ptr <= out_ptr + 16'd1;
        end
      end

      // FSM
      unique case (state)
        // =========================
        // S_IDLE
        // =========================
        S_IDLE: begin
          busy <= 1'b0;
          done <= 1'b0;

          if (start_req) begin
            if (mode[0] == 1'b0) begin
              // -------------------------
              // Modo 0: COPIA
              // -------------------------
              logic [31:0] total_pix;
              total_pix = img_w * img_h;
              if (total_pix > MAX_PIXELS)
                total_pix = MAX_PIXELS;

              perf_pix   <= total_pix;
              perf_cyc   <= 32'd0;

              word_count <= (total_pix + 3) >> 2;
              word_idx   <= 16'd0;

              busy       <= 1'b1;
              done       <= 1'b0;
              state      <= S_RUN;

            end else begin
              // -------------------------
              // Modo 1: DOWNSCALE
              // -------------------------
              logic [31:0] ow_full, oh_full;
              logic [15:0] ow, oh;

              // out_w = floor(img_w * scale / 256)
              ow_full = img_w * scale_q8_8;
              oh_full = img_h * scale_q8_8;

              ow = ow_full[23:8];  // >> 8
              oh = oh_full[23:8];

              // Evitar cero
              if (ow == 16'd0) ow = 16'd1;
              if (oh == 16'd0) oh = 16'd1;

              // Clamp contra límites y contra img_w/img_h
              if (ow > IMG_MAX_W[15:0]) ow = IMG_MAX_W[15:0];
              if (oh > IMG_MAX_H[15:0]) oh = IMG_MAX_H[15:0];
              if (ow > img_w)           ow = img_w;
              if (oh > img_h)           oh = img_h;

              out_w <= ow;
              out_h <= oh;

              perf_pix <= ow * oh;
              perf_cyc <= 32'd0;

              // No usamos word_count en modo 1, pero lo dejamos coherente
              word_count <= ((ow * oh) + 3) >> 2;

              // Inicializar “loops” de downscale
              ds_out_x <= 16'd0;
              ds_out_y <= 16'd0;
              ds_in_x  <= 16'd0;
              ds_in_y  <= 16'd0;

              ds_err_x <= 32'd0;
              ds_err_y <= 32'd0;

              ds_dst_word_idx  <= 32'd0;
              ds_dst_byte_pos  <= 2'd0;
              ds_dst_word_data <= 32'd0;

              busy  <= 1'b1;
              done  <= 1'b0;
              state <= S_RUN;
            end
          end
        end

        // =========================
        // S_RUN
        // =========================
        S_RUN: begin
          perf_cyc <= perf_cyc + 32'd1;

          if (mode[0] == 1'b0) begin
            // ===== MODO 0: COPIA =====
            if (word_idx < word_count && word_idx < MAX_WORDS[15:0]) begin
              out_mem[word_idx] <= in_mem[word_idx];
              word_idx          <= word_idx + 16'd1;
            end else begin
              busy  <= 1'b0;
              done  <= 1'b1;
              state <= S_DONE;
            end

          end else begin : ds_run
            // ===== MODO 1: DOWNSCALE =====

            // Declaraciones locales
            logic [31:0] src_index;
            logic [31:0] src_word_idx;
            logic [1:0]  src_byte_idx;
            logic [31:0] src_word;
            logic [7:0]  src_pix;
            logic [31:0] new_word;

            logic        last_pixel;
            logic        end_row;
            logic [15:0] next_out_x, next_out_y;
            logic [15:0] next_in_x,  next_in_y;
            logic [31:0] next_err_x, next_err_y;

            // Valores por defecto
            next_out_x = ds_out_x;
            next_out_y = ds_out_y;
            next_in_x  = ds_in_x;
            next_in_y  = ds_in_y;
            next_err_x = ds_err_x;
            next_err_y = ds_err_y;

            // Si ya nos pasamos en Y, terminar
            if (ds_out_y >= out_h) begin
              busy  <= 1'b0;
              done  <= 1'b1;
              state <= S_DONE;
            end else begin
              // 1) Calcular índice de origen
              src_index    = ds_in_y;
              src_index    = src_index * img_w + ds_in_x;
              src_word_idx = src_index >> 2;
              src_byte_idx = src_index[1:0];

              src_word     = in_mem[src_word_idx];
              case (src_byte_idx)
                2'd0: src_pix = src_word[7:0];
                2'd1: src_pix = src_word[15:8];
                2'd2: src_pix = src_word[23:16];
                2'd3: src_pix = src_word[31:24];
              endcase

              // 2) Insertar píxel en la palabra de salida en construcción
              new_word = ds_dst_word_data;
              case (ds_dst_byte_pos)
                2'd0: new_word[7:0]   = src_pix;
                2'd1: new_word[15:8]  = src_pix;
                2'd2: new_word[23:16] = src_pix;
                2'd3: new_word[31:24] = src_pix;
              endcase
              ds_dst_word_data <= new_word;

              // ¿Último píxel global?
              last_pixel = (ds_out_y == out_h - 16'd1) &&
                           (ds_out_x == out_w - 16'd1);

              // ¿Último de la fila?
              end_row    = (ds_out_x == out_w - 16'd1);

              // 3) Escribir palabra cuando se llena o si es el último píxel
              if (ds_dst_byte_pos == 2'd3 || last_pixel) begin
                out_mem[ds_dst_word_idx[15:0]] <= new_word;
                ds_dst_word_idx <= ds_dst_word_idx + 32'd1;
              end

              // 4) Actualizar byte_pos
              if (ds_dst_byte_pos == 2'd3)
                ds_dst_byte_pos <= 2'd0;
              else
                ds_dst_byte_pos <= ds_dst_byte_pos + 2'd1;

              // 5) Si es el último píxel, terminar
              if (last_pixel) begin
                busy  <= 1'b0;
                done  <= 1'b1;
                state <= S_DONE;
              end else begin
                // 6) Calcular coordenadas siguientes (Bresenham)
                if (end_row) begin
                  logic [31:0] tmp_err_y;
                  logic [15:0] tmp_in_y;
                  // ---- Fin de fila de salida ----
                  next_out_x = 16'd0;
                  next_out_y = ds_out_y + 16'd1;

                  // Reiniciar mapeo horizontal
                  next_in_x  = 16'd0;
                  next_err_x = 32'd0;

                  // Avance vertical
                  tmp_err_y = ds_err_y + img_h;
                  tmp_in_y  = ds_in_y;

                  if (tmp_err_y >= out_h) begin
                    tmp_err_y -= out_h;
                    tmp_in_y  += 16'd1;
                    if (tmp_err_y >= out_h) begin
                      tmp_err_y -= out_h;
                      tmp_in_y  += 16'd1;
                    end
                  end

                  next_err_y = tmp_err_y;
                  next_in_y  = tmp_in_y;
                end else begin
                  logic [31:0] tmp_err_x;
                  logic [15:0] tmp_in_x;
                  // ---- Misma fila de salida ----
                  next_out_x = ds_out_x + 16'd1;
                  next_out_y = ds_out_y;

                  // Avance horizontal
                  tmp_err_x = ds_err_x + img_w;
                  tmp_in_x  = ds_in_x;

                  if (tmp_err_x >= out_w) begin
                    tmp_err_x -= out_w;
                    tmp_in_x  += 16'd1;
                    if (tmp_err_x >= out_w) begin
                      tmp_err_x -= out_w;
                      tmp_in_x  += 16'd1;
                    end
                  end

                  next_err_x = tmp_err_x;
                  next_in_x  = tmp_in_x;
                end

                // 7) Commit de coordenadas siguientes
                ds_out_x <= next_out_x;
                ds_out_y <= next_out_y;
                ds_in_x  <= next_in_x;
                ds_in_y  <= next_in_y;
                ds_err_x <= next_err_x;
                ds_err_y <= next_err_y;
              end
            end
          end
        end

        // =========================
        // S_DONE
        // =========================
        S_DONE: begin
          busy <= 1'b0;
          done <= 1'b1;

          if (start_req) begin
            // Exactamente el mismo código de S_IDLE con start_req
            if (mode[0] == 1'b0) begin
              // ---- MODO 0: COPIA ----
              logic [31:0] total_pix;
              total_pix = img_w * img_h;
              if (total_pix > MAX_PIXELS)
                total_pix = MAX_PIXELS;

              perf_pix   <= total_pix;
              perf_cyc   <= 32'd0;

              word_count <= (total_pix + 3) >> 2;
              word_idx   <= 16'd0;

              busy       <= 1'b1;
              done       <= 1'b0;
              state      <= S_RUN;

            end else begin
              // ---- MODO 1: DOWNSCALE ----
              logic [31:0] ow_full, oh_full;
              logic [15:0] ow, oh;

              ow_full = img_w * scale_q8_8;
              oh_full = img_h * scale_q8_8;

              ow = ow_full[23:8];
              oh = oh_full[23:8];

              if (ow == 16'd0) ow = 16'd1;
              if (oh == 16'd0) oh = 16'd1;

              if (ow > IMG_MAX_W[15:0]) ow = IMG_MAX_W[15:0];
              if (oh > IMG_MAX_H[15:0]) oh = IMG_MAX_H[15:0];
              if (ow > img_w)           ow = img_w;
              if (oh > img_h)           oh = img_h;

              out_w <= ow;
              out_h <= oh;

              perf_pix <= ow * oh;
              perf_cyc <= 32'd0;
              word_count <= ((ow * oh) + 3) >> 2;

              ds_out_x <= 16'd0;
              ds_out_y <= 16'd0;
              ds_in_x  <= 16'd0;
              ds_in_y  <= 16'd0;

              ds_err_x <= 32'd0;
              ds_err_y <= 32'd0;

              ds_dst_word_idx  <= 32'd0;
              ds_dst_byte_pos  <= 2'd0;
              ds_dst_word_data <= 32'd0;

              busy  <= 1'b1;
              done  <= 1'b0;
              state <= S_RUN;
            end
          end
        end

        default: state <= S_IDLE;
      endcase
      
    end
  end

  // ---------------------------------------------------------
  // Lecturas
  // ---------------------------------------------------------
  always_comb begin
    h_rdata = 32'd0;

    unique case (h_addr)
      REG_STATUS:    h_rdata = {30'd0, done, busy};
      REG_IMG_W:     h_rdata = {16'd0, img_w};
      REG_IMG_H:     h_rdata = {16'd0, img_h};
      REG_SCALE:     h_rdata = {16'd0, scale_q8_8};
      REG_MODE:      h_rdata = {24'd0, mode};

      REG_PERF_CYC:  h_rdata = perf_cyc;
      REG_PERF_PIX:  h_rdata = perf_pix;

      REG_IN_ADDR:   h_rdata = {16'd0, in_ptr};
      REG_OUT_ADDR:  h_rdata = {16'd0, out_ptr};

      REG_OUT_DATA:  h_rdata = out_mem[out_ptr];

      default: ;
    endcase
  end

  assign h_rvalid = h_rd_en;

endmodule
