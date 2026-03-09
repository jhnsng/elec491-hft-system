module feature_pipe (
  input  logic clk,
  input  logic rst_n,
  input  logic snap_en,
  input  logic sig_ready,

  input  logic [31:0] bb_p,
  input  logic [31:0] bb_q,
  input  logic [31:0] ba_p,
  input  logic [31:0] ba_q,

  input  logic [15:0] alpha_fast_q16,
  input  logic [15:0] alpha_slow_q16,
  input  logic [15:0] alpha_sig_q16,
  input  logic [31:0] max_spread,
  input  logic signed [63:0] cross_thresh,

  output logic                 sig_valid,
  output logic                 sig_enter,
  output hft_types_pkg::side_e sig_side,
  output logic [31:0]          sig_price_int,
  output logic [31:0]          sig_qty,
  output logic [31:0]          spread_out,
  output logic [31:0]          mid_out
);

  import hft_types_pkg::*;

  // ----------------------------------------------------------------
  // INPUT BUFFER STAGE (Cuts the 12ns I/O pin routing delay to 0!)
  // ----------------------------------------------------------------
  logic [31:0] bb_p_reg, bb_q_reg, ba_p_reg, ba_q_reg;
  logic        snap_en_reg;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      bb_p_reg    <= '0;
      bb_q_reg    <= '0;
      ba_p_reg    <= '0;
      ba_q_reg    <= '0;
      snap_en_reg <= 1'b0;
    end else begin
      bb_p_reg    <= bb_p;
      bb_q_reg    <= bb_q;
      ba_p_reg    <= ba_p;
      ba_q_reg    <= ba_q;
      snap_en_reg <= snap_en;
    end
  end

  logic [32:0]        sum_p;
  logic [31:0]        mid;
  logic [31:0]        spread;

  always_comb begin
    sum_p = {1'b0, bb_p_reg} + {1'b0, ba_p_reg};
    mid   = sum_p[32:1];
    if (ba_p_reg >= bb_p_reg) spread = ba_p_reg - bb_p_reg;
    else                      spread = 32'hFFFF_FFFF; 
  end

  logic [15:0] sample_cnt;
  logic        ema_ready;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      sample_cnt <= '0;
    end else if (snap_en_reg) begin
      if (sample_cnt != 16'hFFFF)
        sample_cnt <= sample_cnt + 16'd1;
    end
  end

  assign ema_ready = (sample_cnt >= 16'd64);

  // ----------------------------------------------------------------
  // Pipelined Fast/Slow Math (7 Cycles)
  // ----------------------------------------------------------------
  logic signed [63:0] ema_fast, ema_slow, ema_sig;
  logic signed [63:0] mid_s64;

  assign mid_s64 = $signed({32'd0, mid});

  util_ema_q16 u_fast (.clk(clk), .rst_n(rst_n), .en(snap_en_reg), .x_in(mid_s64), .alpha_q16(alpha_fast_q16), .y_out(ema_fast));
  util_ema_q16 u_slow (.clk(clk), .rst_n(rst_n), .en(snap_en_reg), .x_in(mid_s64), .alpha_q16(alpha_slow_q16), .y_out(ema_slow));

  // ----------------------------------------------------------------
  // 17-STAGE ALIGNMENT SHIFT REGISTER 
  // ----------------------------------------------------------------
  logic [31:0] ba_p_d1, ba_p_d2, ba_p_d3, ba_p_d4, ba_p_d5, ba_p_d6, ba_p_d7, ba_p_d8, ba_p_d9, ba_p_d10, ba_p_d11, ba_p_d12, ba_p_d13, ba_p_d14, ba_p_d15, ba_p_d16, ba_p_d17;
  logic [31:0] bb_p_d1, bb_p_d2, bb_p_d3, bb_p_d4, bb_p_d5, bb_p_d6, bb_p_d7, bb_p_d8, bb_p_d9, bb_p_d10, bb_p_d11, bb_p_d12, bb_p_d13, bb_p_d14, bb_p_d15, bb_p_d16, bb_p_d17;
  logic [31:0] mid_d1, mid_d2, mid_d3, mid_d4, mid_d5, mid_d6, mid_d7, mid_d8, mid_d9, mid_d10, mid_d11, mid_d12, mid_d13, mid_d14, mid_d15, mid_d16, mid_d17;
  logic [31:0] spr_d1, spr_d2, spr_d3, spr_d4, spr_d5, spr_d6, spr_d7, spr_d8, spr_d9, spr_d10, spr_d11, spr_d12, spr_d13, spr_d14, spr_d15, spr_d16, spr_d17;
  logic        en_d1, en_d2, en_d3, en_d4, en_d5, en_d6, en_d7, en_d8, en_d9, en_d10, en_d11, en_d12, en_d13, en_d14, en_d15, en_d16, en_d17;
  logic        rdy_d1, rdy_d2, rdy_d3, rdy_d4, rdy_d5, rdy_d6, rdy_d7, rdy_d8, rdy_d9, rdy_d10, rdy_d11, rdy_d12, rdy_d13, rdy_d14, rdy_d15, rdy_d16, rdy_d17;
  
  logic signed [63:0] macd_reg_d8; 
  logic signed [63:0] macd_d9, macd_d10, macd_d11, macd_d12, macd_d13, macd_d14, macd_d15, macd_d16, macd_d17;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      en_d1<=0; en_d2<=0; en_d3<=0; en_d4<=0; en_d5<=0; en_d6<=0; en_d7<=0; en_d8<=0; en_d9<=0; en_d10<=0; en_d11<=0; en_d12<=0; en_d13<=0; en_d14<=0; en_d15<=0; en_d16<=0; en_d17<=0;
      rdy_d1<=0; rdy_d2<=0; rdy_d3<=0; rdy_d4<=0; rdy_d5<=0; rdy_d6<=0; rdy_d7<=0; rdy_d8<=0; rdy_d9<=0; rdy_d10<=0; rdy_d11<=0; rdy_d12<=0; rdy_d13<=0; rdy_d14<=0; rdy_d15<=0; rdy_d16<=0; rdy_d17<=0;
      macd_reg_d8<=0; macd_d9<=0; macd_d10<=0; macd_d11<=0; macd_d12<=0; macd_d13<=0; macd_d14<=0; macd_d15<=0; macd_d16<=0; macd_d17<=0;
    end else begin
      en_d1 <= snap_en_reg; ba_p_d1 <= ba_p_reg; bb_p_d1 <= bb_p_reg; mid_d1 <= mid; spr_d1 <= spread; rdy_d1 <= ema_ready;
      en_d2 <= en_d1; ba_p_d2 <= ba_p_d1; bb_p_d2 <= bb_p_d1; mid_d2 <= mid_d1; spr_d2 <= spr_d1; rdy_d2 <= rdy_d1;
      en_d3 <= en_d2; ba_p_d3 <= ba_p_d2; bb_p_d3 <= bb_p_d2; mid_d3 <= mid_d2; spr_d3 <= spr_d2; rdy_d3 <= rdy_d2;
      en_d4 <= en_d3; ba_p_d4 <= ba_p_d3; bb_p_d4 <= bb_p_d3; mid_d4 <= mid_d3; spr_d4 <= spr_d3; rdy_d4 <= rdy_d3;
      en_d5 <= en_d4; ba_p_d5 <= ba_p_d4; bb_p_d5 <= bb_p_d4; mid_d5 <= mid_d4; spr_d5 <= spr_d4; rdy_d5 <= rdy_d4;
      en_d6 <= en_d5; ba_p_d6 <= ba_p_d5; bb_p_d6 <= bb_p_d5; mid_d6 <= mid_d5; spr_d6 <= spr_d5; rdy_d6 <= rdy_d5;
      en_d7 <= en_d6; ba_p_d7 <= ba_p_d6; bb_p_d7 <= bb_p_d6; mid_d7 <= mid_d6; spr_d7 <= spr_d6; rdy_d7 <= rdy_d6;
      en_d8 <= en_d7; ba_p_d8 <= ba_p_d7; bb_p_d8 <= bb_p_d7; mid_d8 <= mid_d7; spr_d8 <= spr_d7; rdy_d8 <= rdy_d7;
      en_d9 <= en_d8; ba_p_d9 <= ba_p_d8; bb_p_d9 <= bb_p_d8; mid_d9 <= mid_d8; spr_d9 <= spr_d8; rdy_d9 <= rdy_d8;
      en_d10 <= en_d9; ba_p_d10 <= ba_p_d9; bb_p_d10 <= bb_p_d9; mid_d10 <= mid_d9; spr_d10 <= spr_d9; rdy_d10 <= rdy_d9;
      en_d11 <= en_d10; ba_p_d11 <= ba_p_d10; bb_p_d11 <= bb_p_d10; mid_d11 <= mid_d10; spr_d11 <= spr_d10; rdy_d11 <= rdy_d10;
      en_d12 <= en_d11; ba_p_d12 <= ba_p_d11; bb_p_d12 <= bb_p_d11; mid_d12 <= mid_d11; spr_d12 <= spr_d11; rdy_d12 <= rdy_d11;
      en_d13 <= en_d12; ba_p_d13 <= ba_p_d12; bb_p_d13 <= bb_p_d12; mid_d13 <= mid_d12; spr_d13 <= spr_d12; rdy_d13 <= rdy_d12;
      en_d14 <= en_d13; ba_p_d14 <= ba_p_d13; bb_p_d14 <= bb_p_d13; mid_d14 <= mid_d13; spr_d14 <= spr_d13; rdy_d14 <= rdy_d13;
      en_d15 <= en_d14; ba_p_d15 <= ba_p_d14; bb_p_d15 <= bb_p_d14; mid_d15 <= mid_d14; spr_d15 <= spr_d14; rdy_d15 <= rdy_d14;
      en_d16 <= en_d15; ba_p_d16 <= ba_p_d15; bb_p_d16 <= bb_p_d15; mid_d16 <= mid_d15; spr_d16 <= spr_d15; rdy_d16 <= rdy_d15;
      en_d17 <= en_d16; ba_p_d17 <= ba_p_d16; bb_p_d17 <= bb_p_d16; mid_d17 <= mid_d16; spr_d17 <= spr_d16; rdy_d17 <= rdy_d16;

      if (en_d7) begin
         macd_reg_d8 <= ema_fast - ema_slow;
      end

      macd_d9 <= macd_reg_d8;
      macd_d10 <= macd_d9;
      macd_d11 <= macd_d10;
      macd_d12 <= macd_d11;
      macd_d13 <= macd_d12;
      macd_d14 <= macd_d13;
      macd_d15 <= macd_d14;
      macd_d16 <= macd_d15;
      macd_d17 <= macd_d16;
    end
  end

  util_ema_q16 u_sig  (.clk(clk), .rst_n(rst_n), .en(en_d8), .x_in(macd_reg_d8), .alpha_q16(alpha_sig_q16),  .y_out(ema_sig));

  // ----------------------------------------------------------------
  // STAGE 16 & 17: PIPELINE THE COMPARATORS!
  // ----------------------------------------------------------------
  logic signed [63:0] diff_now_reg_d16;
  logic signed [63:0] macd_prev, sig_prev;
  logic signed [63:0] diff_prev_reg_d16;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      macd_prev <= '0; sig_prev <= '0;
      diff_now_reg_d16 <= '0;
      diff_prev_reg_d16 <= '0;
    end else begin
      if (en_d15) begin
        diff_now_reg_d16 <= macd_d15 - ema_sig;
        diff_prev_reg_d16 <= macd_prev - sig_prev;
        
        macd_prev <= macd_d15;
        sig_prev  <= ema_sig;
      end
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      sig_valid     <= 1'b0; sig_enter     <= 1'b0; sig_side      <= SIDE_BUY;
      sig_price_int <= 32'd0; sig_qty       <= 32'd0; spread_out    <= 32'd0; mid_out       <= 32'd0;
    end else begin
      if (sig_ready) sig_valid <= 1'b0; 

      if (en_d16 && sig_ready) begin
        spread_out <= spr_d16;
        mid_out    <= mid_d16;
        sig_valid     <= 1'b1;
        sig_enter     <= 1'b0;
        sig_side      <= SIDE_BUY;
        sig_qty       <= 32'd100;
        sig_price_int <= ba_p_d16;

        if (rdy_d16 && (spr_d16 <= max_spread)) begin
          if (($signed(diff_prev_reg_d16) <= $signed(cross_thresh)) && ($signed(diff_now_reg_d16) > $signed(cross_thresh))) begin
            sig_side <= SIDE_BUY; sig_enter <= 1'b1; sig_price_int <= ba_p_d16;
          end
          else if (($signed(diff_prev_reg_d16) >= -$signed(cross_thresh)) && ($signed(diff_now_reg_d16) < -$signed(cross_thresh))) begin
            sig_side <= SIDE_SELL; sig_enter <= 1'b1; sig_price_int <= bb_p_d16;
          end
        end
      end
    end
  end

endmodule
