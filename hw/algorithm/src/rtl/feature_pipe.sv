module feature_pipe (
  input  logic clk,
  input  logic rst_n,
  input  logic snap_en,

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

  logic [32:0]        sum_p;
  logic [31:0]        mid;
  logic [31:0]        spread;
  logic signed [33:0] imb_s;

  logic signed [63:0] ema_fast, ema_slow, ema_sig;
  logic signed [63:0] mid_s64, macd, macd_prev, sig_prev;

  assign mid_s64 = $signed({32'd0, mid});
  assign macd    = ema_fast - ema_slow;

  util_ema_q16 u_fast (.clk(clk), .rst_n(rst_n), .en(snap_en), .x_in(mid_s64), .alpha_q16(alpha_fast_q16), .y_out(ema_fast));
  util_ema_q16 u_slow (.clk(clk), .rst_n(rst_n), .en(snap_en), .x_in(mid_s64), .alpha_q16(alpha_slow_q16), .y_out(ema_slow));
  util_ema_q16 u_sig  (.clk(clk), .rst_n(rst_n), .en(snap_en), .x_in(macd),    .alpha_q16(alpha_sig_q16),  .y_out(ema_sig));

  // Mid/spread computation
  always_comb begin
    sum_p = {1'b0, bb_p} + {1'b0, ba_p};
    mid   = sum_p[32:1];

    if (ba_p >= bb_p)
      spread = ba_p - bb_p;
    else
      spread = 32'hFFFF_FFFF; // crossed/invalid -> block trading

    imb_s = $signed({1'b0, bb_q}) - $signed({1'b0, ba_q});
  end

  // Warm-up counter (FIXED)
  logic [15:0] sample_cnt;
  logic        ema_ready;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      sample_cnt <= '0;
    end else if (snap_en) begin
      if (sample_cnt != 16'hFFFF)
        sample_cnt <= sample_cnt + 16'd1;
    end
  end

  assign ema_ready = (sample_cnt >= 16'd64);

  // Cross detection
  logic signed [63:0] diff_now, diff_prev;
  always_comb begin
    diff_now  = macd - ema_sig;
    diff_prev = macd_prev - sig_prev;
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      macd_prev     <= '0;
      sig_prev      <= '0;

      sig_valid     <= 1'b0;
      sig_enter     <= 1'b0;
      sig_side      <= SIDE_BUY;

      sig_price_int <= 32'd0;
      sig_qty       <= 32'd0;

      spread_out    <= 32'd0;
      mid_out       <= 32'd0;
    end else begin
      sig_valid <= 1'b0; // pulse

      if (snap_en) begin
        macd_prev  <= macd;
        sig_prev   <= ema_sig;

        spread_out <= spread;
        mid_out    <= mid;

        sig_valid     <= 1'b1;
        sig_enter     <= 1'b0;
        sig_side      <= SIDE_BUY;
        sig_qty       <= 32'd100;
        sig_price_int <= ba_p;

        if (ema_ready && (spread <= max_spread)) begin
          // Up-cross -> BUY
          // Down-cross -> SELL
          // Old Code
          // if ((diff_prev <= 0) && (diff_now > 0)) ...
          //
          // New Code with Hysteresis - Schmitt Trigger to avoid false signals in noisy prices
          // We check if we crossed the POSITIVE threshold from below
          if ((diff_prev <= cross_thresh) && (diff_now > cross_thresh)) begin
            sig_side <= SIDE_BUY;
            sig_enter <= 1'b1;
            sig_price_int <= ba_p;
          end
          // We check if we crossed the NEGATIVE threshold from above
          else if ((diff_prev >= -cross_thresh) && (diff_now < -cross_thresh)) begin
            sig_side <= SIDE_SELL;
            sig_enter <= 1'b1;
            sig_price_int <= bb_p;
          end

        end
      end
    end
  end

endmodule
