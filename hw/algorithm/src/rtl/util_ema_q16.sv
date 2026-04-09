module util_ema_q16 #(
  parameter int Q = 16
) (
  input  logic              clk,
  input  logic              rst_n,
  input  logic              en,
  input  logic signed [63:0] x_in,      
  input  logic        [15:0] alpha_q16, 
  output logic signed [63:0] y_out      
);

  logic signed [63:0] y_accum;
  assign y_out = y_accum[63:16];      

  logic signed [63:0] x_scaled;
  assign x_scaled = {x_in[47:0], 16'd0}; 

  logic en_s1, en_s2, en_s3, en_s4, en_s5, en_s6;
  logic first_s1, first_s2, first_s3, first_s4, first_s5, first_s6;
  logic signed [63:0] x_s1, x_s2, x_s3, x_s4, x_s5, x_s6;
  logic first_sample;

  logic signed [63:0] diff_s1;
  logic [63:0] abs_diff_s2;
  logic        sign_s2, sign_s3, sign_s4, sign_s5;

  (* multstyle = "dsp" *) logic [31:0] p0_s3, p1_s3, p2_s3, p3_s3;

  logic [79:0] sum01_s4, sum23_s4;
  logic [79:0] abs_prod_s5;
  logic signed [79:0] prod_s6;

  // FIX: Synchronous Reset + Datapath Reset Removal
  always_ff @(posedge clk) begin
    // ==========================================
    // 1. CONTROL PATH (Requires Resets)
    // ==========================================
    if (!rst_n) begin
      y_accum      <= '0;
      first_sample <= 1'b1;
      
      en_s1 <= 0; en_s2 <= 0; en_s3 <= 0; en_s4 <= 0; en_s5 <= 0; en_s6 <= 0;
      first_s1 <= 0; first_s2 <= 0; first_s3 <= 0; first_s4 <= 0; first_s5 <= 0; first_s6 <= 0;
    end else begin
      en_s1 <= en; first_s1 <= first_sample; 
      en_s2 <= en_s1; first_s2 <= first_s1; 
      en_s3 <= en_s2; first_s3 <= first_s2; 
      en_s4 <= en_s3; first_s4 <= first_s3; 
      en_s5 <= en_s4; first_s5 <= first_s4; 
      en_s6 <= en_s5; first_s6 <= first_s5; 

      if (en && first_sample) first_sample <= 1'b0;

      // STAGE 7: Accumulate Feedback
      if (en_s6) begin
        if (first_s6) y_accum <= x_s6;
        else          y_accum <= y_accum + (prod_s6 >>> Q);
      end
    end

    // ==========================================
    // 2. DATAPATH (No Resets - Let it float!)
    // ==========================================
    x_s1 <= x_scaled;
    x_s2 <= x_s1;
    x_s3 <= x_s2;
    x_s4 <= x_s3;
    x_s5 <= x_s4;
    x_s6 <= x_s5;

    // STAGE 1: Subtraction
    if (en) diff_s1 <= x_scaled - y_accum;

    // STAGE 2: Absolute Value
    if (en_s1) begin
      abs_diff_s2 <= diff_s1[63] ? -diff_s1 : diff_s1;
      sign_s2     <= diff_s1[63];
    end

    // STAGE 3: Multiplications
    if (en_s2) begin
      p0_s3   <= alpha_q16 * abs_diff_s2[15:0];
      p1_s3   <= alpha_q16 * abs_diff_s2[31:16];
      p2_s3   <= alpha_q16 * abs_diff_s2[47:32];
      p3_s3   <= alpha_q16 * abs_diff_s2[63:48];
      sign_s3 <= sign_s2;
    end

    // STAGE 4: Adder Tree Level 1 
    if (en_s3) begin
      sum01_s4 <= {48'd0, p0_s3} + {32'd0, p1_s3, 16'd0};
      sum23_s4 <= {16'd0, p2_s3, 32'd0} + {p3_s3, 48'd0};
      sign_s4  <= sign_s3;
    end

    // STAGE 5: Adder Tree Level 2 
    if (en_s4) begin
      abs_prod_s5 <= sum01_s4 + sum23_s4;
      sign_s5     <= sign_s4;
    end

    // STAGE 6: Apply Sign 
    if (en_s5) begin
      prod_s6 <= sign_s5 ? -$signed({1'b0, abs_prod_s5}) : $signed({1'b0, abs_prod_s5});
    end
  end
endmodule