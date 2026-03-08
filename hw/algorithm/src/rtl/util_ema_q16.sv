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
  logic first_sample; // New flag

  logic signed [63:0] x_scaled;
  logic signed [63:0] diff;
  logic signed [79:0] prod; 

  assign x_scaled = {x_in[47:0], 16'd0}; // Int -> Q16.16
  assign y_out    = y_accum[63:16];      // Q16.16 -> Int

  always_comb begin
    diff = x_scaled - y_accum;
    prod = $signed({1'b0, alpha_q16}) * diff; 
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      y_accum      <= '0;
      first_sample <= 1'b1; // Reset flag
    end else if (en) begin
      if (first_sample) begin
        // SNAP to the first value immediately
        y_accum      <= x_scaled;
        first_sample <= 1'b0;
      end else begin
        // Standard EMA update
        y_accum      <= y_accum + (prod >>> Q); 
      end
    end
  end

endmodule
