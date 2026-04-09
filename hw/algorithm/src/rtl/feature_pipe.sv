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

  output logic                pipe_ready,
  output logic                sig_valid,
  output logic                sig_enter,
  output hft_types_pkg::side_e sig_side,
  output logic [31:0]          sig_price_int,
  output logic [31:0]          sig_qty,
  output logic [31:0]          spread_out,
  output logic [31:0]          mid_out
);

  import hft_types_pkg::*;

  // ----------------------------------------------------------------
  // INPUT BUFFER STAGE (The Pure SystemVerilog Iron Wall)
  // ----------------------------------------------------------------
  (* preserve, dont_merge, dont_retime *) logic [31:0] bb_p_in_reg, bb_q_in_reg, ba_p_in_reg, ba_q_in_reg;
  (* preserve, dont_merge, dont_retime *) logic        snap_en_in_reg;

  (* keep *) wire [31:0] bb_p_buf = bb_p_in_reg;
  (* keep *) wire [31:0] ba_p_buf = ba_p_in_reg;

  (* preserve, dont_merge, dont_retime *) logic [31:0] bb_p_reg, bb_q_reg, ba_p_reg, ba_q_reg;
  (* preserve, dont_merge, dont_retime *) logic        snap_en_reg;

  always_ff @(posedge clk) begin 
    if (!rst_n) snap_en_in_reg <= 1'b0;
    else        snap_en_in_reg <= snap_en;
    
    bb_p_in_reg <= bb_p;
    bb_q_in_reg <= bb_q;
    ba_p_in_reg <= ba_p;
    ba_q_in_reg <= ba_q;
  end

  always_ff @(posedge clk) begin 
    if (!rst_n) snap_en_reg <= 1'b0;
    else        snap_en_reg <= snap_en_in_reg;
    
    bb_p_reg <= bb_p_buf;
    ba_p_reg <= ba_p_buf;
    bb_q_reg <= bb_q_in_reg;
    ba_q_reg <= ba_q_in_reg;
  end

  // ----------------------------------------------------------------
  // STAGE 1.5: 32-BIT MATH ISOLATION (The 250MHz Fix!)
  // ----------------------------------------------------------------
  logic [32:0] sum_p_comb;
  logic [31:0] mid_comb, spread_comb;
  logic        book_ready_comb;

  always_comb begin
    sum_p_comb = {1'b0, bb_p_reg} + {1'b0, ba_p_reg};
    mid_comb   = sum_p_comb[32:1];
    
    if (ba_p_reg >= bb_p_reg) spread_comb = ba_p_reg - bb_p_reg;
    else                      spread_comb = 32'hFFFF_FFFF; 
    
    // Do the heavy zero-checking and comparisons here!
    book_ready_comb = (bb_p_reg != 32'd0) && (ba_p_reg != 32'd0) && (ba_p_reg >= bb_p_reg);
  end

  // Pipeline Registers to protect the busy_cnt and EMA!
  logic        snap_en_prep;
  logic        book_ready_prep;
  logic [31:0] bb_p_prep, ba_p_prep;
  logic [31:0] mid_prep, spread_prep;

  always_ff @(posedge clk) begin 
    if (!rst_n) begin
      snap_en_prep    <= 1'b0;
      book_ready_prep <= 1'b0;
    end else begin
      snap_en_prep    <= snap_en_reg;
      book_ready_prep <= book_ready_comb;
    end
    
    bb_p_prep   <= bb_p_reg;
    ba_p_prep   <= ba_p_reg;
    mid_prep    <= mid_comb;
    spread_prep <= spread_comb;
  end

  // ----------------------------------------------------------------
  // Book Readiness Gate & Hardware Throttling
  // ----------------------------------------------------------------
  logic valid_snap;
  logic [2:0] busy_cnt;
  logic [15:0] sample_cnt;
  logic        ema_ready;

  // ----------------------------------------------------------------
  // Book Readiness Gate & Hardware Throttling
  // ----------------------------------------------------------------
  logic [31:0] last_sampled_bb_p, last_sampled_ba_p;
  logic        price_changed;

  always_ff @(posedge clk) begin 
    if (!rst_n) begin
      last_sampled_bb_p <= 32'd0;
      last_sampled_ba_p <= 32'd0;
    end else if (valid_snap) begin
      last_sampled_bb_p <= bb_p_prep;
      last_sampled_ba_p <= ba_p_prep;
    end
  end

  // Only trigger the EMA pipeline if the price physically moved!
  assign price_changed = (bb_p_prep != last_sampled_bb_p) || (ba_p_prep != last_sampled_ba_p);
  
  // Notice we now use the 1-bit PREP signals AND the price_changed detector
  assign pipe_ready = (busy_cnt == 0);
  assign valid_snap = snap_en_prep && book_ready_prep && pipe_ready && price_changed;

  always_ff @(posedge clk) begin 
    if (!rst_n) begin
      busy_cnt   <= 3'd0;
      sample_cnt <= '0;
    end else begin
      if (valid_snap) begin
        busy_cnt <= 3'd7; 
        if (sample_cnt != 16'hFFFF) sample_cnt <= sample_cnt + 16'd1;
      end else if (busy_cnt > 0) begin
        busy_cnt <= busy_cnt - 3'd1;
      end
    end
  end

  assign ema_ready = (sample_cnt >= 16'd64);

  // ----------------------------------------------------------------
  // Pipelined Fast/Slow Math (7 Cycles)
  // ----------------------------------------------------------------
  logic signed [63:0] ema_fast, ema_slow, ema_sig;
  logic signed [63:0] mid_s64;

  assign mid_s64 = $signed({32'd0, mid_prep}); // <-- Feed from PREP

  util_ema_q16 u_fast (.clk(clk), .rst_n(rst_n), .en(valid_snap), .x_in(mid_s64), .alpha_q16(alpha_fast_q16), .y_out(ema_fast));
  util_ema_q16 u_slow (.clk(clk), .rst_n(rst_n), .en(valid_snap), .x_in(mid_s64), .alpha_q16(alpha_slow_q16), .y_out(ema_slow));

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

  always_ff @(posedge clk) begin 
    if (!rst_n) begin
      en_d1<=0; en_d2<=0; en_d3<=0; en_d4<=0; en_d5<=0; en_d6<=0; en_d7<=0; en_d8<=0; en_d9<=0; en_d10<=0; en_d11<=0; en_d12<=0; en_d13<=0; en_d14<=0; en_d15<=0; en_d16<=0; en_d17<=0;
      rdy_d1<=0; rdy_d2<=0; rdy_d3<=0; rdy_d4<=0; rdy_d5<=0; rdy_d6<=0; rdy_d7<=0; rdy_d8<=0; rdy_d9<=0; rdy_d10<=0; rdy_d11<=0; rdy_d12<=0; rdy_d13<=0; rdy_d14<=0; rdy_d15<=0; rdy_d16<=0; rdy_d17<=0;
    end else begin
      en_d1 <= valid_snap; rdy_d1 <= ema_ready;
      en_d2 <= en_d1; rdy_d2 <= rdy_d1;
      en_d3 <= en_d2; rdy_d3 <= rdy_d2;
      en_d4 <= en_d3; rdy_d4 <= rdy_d3;
      en_d5 <= en_d4; rdy_d5 <= rdy_d4;
      en_d6 <= en_d5; rdy_d6 <= rdy_d5;
      en_d7 <= en_d6; rdy_d7 <= rdy_d6;
      en_d8 <= en_d7; rdy_d8 <= rdy_d7;
      en_d9 <= en_d8; rdy_d9 <= rdy_d8;
      en_d10 <= en_d9; rdy_d10 <= rdy_d9;
      en_d11 <= en_d10; rdy_d11 <= rdy_d10;
      en_d12 <= en_d11; rdy_d12 <= rdy_d11;
      en_d13 <= en_d12; rdy_d13 <= rdy_d12;
      en_d14 <= en_d13; rdy_d14 <= rdy_d13;
      en_d15 <= en_d14; rdy_d15 <= rdy_d14;
      en_d16 <= en_d15; rdy_d16 <= rdy_d15;
      en_d17 <= en_d16; rdy_d17 <= rdy_d16;
    end

    // FIX: Only shift the price data when the pipeline actually evaluates a snap!
    if (valid_snap) begin
      ba_p_d1 <= ba_p_prep; bb_p_d1 <= bb_p_prep; mid_d1 <= mid_prep; spr_d1 <= spread_prep; 
    end
    
    if (en_d1) begin ba_p_d2 <= ba_p_d1; bb_p_d2 <= bb_p_d1; mid_d2 <= mid_d1; spr_d2 <= spr_d1; end
    if (en_d2) begin ba_p_d3 <= ba_p_d2; bb_p_d3 <= bb_p_d2; mid_d3 <= mid_d2; spr_d3 <= spr_d2; end
    if (en_d3) begin ba_p_d4 <= ba_p_d3; bb_p_d4 <= bb_p_d3; mid_d4 <= mid_d3; spr_d4 <= spr_d3; end
    if (en_d4) begin ba_p_d5 <= ba_p_d4; bb_p_d5 <= bb_p_d4; mid_d5 <= mid_d4; spr_d5 <= spr_d4; end
    if (en_d5) begin ba_p_d6 <= ba_p_d5; bb_p_d6 <= bb_p_d5; mid_d6 <= mid_d5; spr_d6 <= spr_d5; end
    if (en_d6) begin ba_p_d7 <= ba_p_d6; bb_p_d7 <= bb_p_d6; mid_d7 <= mid_d6; spr_d7 <= spr_d6; end
    if (en_d7) begin ba_p_d8 <= ba_p_d7; bb_p_d8 <= bb_p_d7; mid_d8 <= mid_d7; spr_d8 <= spr_d7; end
    if (en_d8) begin ba_p_d9 <= ba_p_d8; bb_p_d9 <= bb_p_d8; mid_d9 <= mid_d8; spr_d9 <= spr_d8; end
    if (en_d9) begin ba_p_d10 <= ba_p_d9; bb_p_d10 <= bb_p_d9; mid_d10 <= mid_d9; spr_d10 <= spr_d9; end
    if (en_d10) begin ba_p_d11 <= ba_p_d10; bb_p_d11 <= bb_p_d10; mid_d11 <= mid_d10; spr_d11 <= spr_d10; end
    if (en_d11) begin ba_p_d12 <= ba_p_d11; bb_p_d12 <= bb_p_d11; mid_d12 <= mid_d11; spr_d12 <= spr_d11; end
    if (en_d12) begin ba_p_d13 <= ba_p_d12; bb_p_d13 <= bb_p_d12; mid_d13 <= mid_d12; spr_d13 <= spr_d12; end
    if (en_d13) begin ba_p_d14 <= ba_p_d13; bb_p_d14 <= bb_p_d13; mid_d14 <= mid_d13; spr_d14 <= spr_d13; end
    if (en_d14) begin ba_p_d15 <= ba_p_d14; bb_p_d15 <= bb_p_d14; mid_d15 <= mid_d14; spr_d15 <= spr_d14; end
    if (en_d15) begin ba_p_d16 <= ba_p_d15; bb_p_d16 <= bb_p_d15; mid_d16 <= mid_d15; spr_d16 <= spr_d15; end
    if (en_d16) begin ba_p_d17 <= ba_p_d16; bb_p_d17 <= bb_p_d16; mid_d17 <= mid_d16; spr_d17 <= spr_d16; end

    if (en_d7) macd_reg_d8 <= ema_fast - ema_slow;

    macd_d9 <= macd_reg_d8; macd_d10 <= macd_d9; macd_d11 <= macd_d10;
    macd_d12 <= macd_d11; macd_d13 <= macd_d12; macd_d14 <= macd_d13;
    macd_d15 <= macd_d14; macd_d16 <= macd_d15; macd_d17 <= macd_d16;
  end

  util_ema_q16 u_sig (.clk(clk), .rst_n(rst_n), .en(en_d8), .x_in(macd_reg_d8), .alpha_q16(alpha_sig_q16),  .y_out(ema_sig));

  // ----------------------------------------------------------------
  // STAGE 15 & 16: PIPELINE THE COMPARATORS (300MHz Fix)
  // ----------------------------------------------------------------
  logic signed [63:0] diff_now_reg_d16;
  logic signed [63:0] macd_prev, sig_prev;
  logic signed [63:0] diff_prev_reg_d16;

  always_ff @(posedge clk) begin
    if (en_d15) begin
      diff_now_reg_d16 <= macd_d15 - ema_sig;
      diff_prev_reg_d16 <= macd_prev - sig_prev;
      macd_prev <= macd_d15;
      sig_prev  <= ema_sig;
    end
  end

  logic cross_up_prev_d17, cross_up_now_d17;
  logic cross_dn_prev_d17, cross_dn_now_d17;
  logic spr_ok_d17;

  always_ff @(posedge clk) begin
    if (en_d16) begin
      cross_up_prev_d17 <= ($signed(diff_prev_reg_d16) <= $signed(cross_thresh));
      cross_up_now_d17  <= ($signed(diff_now_reg_d16)  >  $signed(cross_thresh));
      
      cross_dn_prev_d17 <= ($signed(diff_prev_reg_d16) >= -$signed(cross_thresh));
      cross_dn_now_d17  <= ($signed(diff_now_reg_d16)  <  -$signed(cross_thresh));
      
      spr_ok_d17        <= (spr_d16 <= max_spread) && rdy_d16;
    end
  end

  // ----------------------------------------------------------------
  // STAGE 17: FINAL DECISION MUX
  // ----------------------------------------------------------------
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      sig_valid <= 1'b0; 
      sig_enter <= 1'b0; 
    end else begin
      if (sig_ready) sig_valid <= 1'b0; 

      if (en_d17 && sig_ready) begin
        sig_valid <= 1'b1;
        sig_enter <= 1'b0;

        if (spr_ok_d17) begin
          if (cross_up_prev_d17 && cross_up_now_d17)      sig_enter <= 1'b1;
          else if (cross_dn_prev_d17 && cross_dn_now_d17) sig_enter <= 1'b1;
        end
      end
    end

    if (en_d17 && sig_ready) begin
      spread_out <= spr_d17;
      mid_out    <= mid_d17;
      sig_qty    <= 32'd100;
      sig_side   <= SIDE_BUY; 
      sig_price_int <= ba_p_d17;

      if (spr_ok_d17) begin
        // CONTINUOUS TRIGGER: As long as MACD is above threshold, keep buying!
        if ($signed(diff_now_reg_d16) > $signed(cross_thresh)) begin
          sig_enter <= 1'b1;
          sig_side <= SIDE_BUY; 
          sig_price_int <= ba_p_d17; // Hit the Ask
        end
        // CONTINUOUS TRIGGER: As long as MACD is below threshold, keep selling!
        else if ($signed(diff_now_reg_d16) < -$signed(cross_thresh)) begin
          sig_enter <= 1'b1;
          sig_side <= SIDE_SELL; 
          sig_price_int <= bb_p_d17; // Hit the Bid
        end
      end
    end
  end

endmodule