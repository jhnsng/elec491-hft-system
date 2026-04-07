package algo_cfg_pkg;

  // Fixed-point choice for EMA coefficients: Q16
  localparam int EMA_Q = 16;
  /* 
  localparam logic [15:0] ALPHA_FAST_Q16   = 16'd10082; // 0.0625
  localparam logic [15:0] ALPHA_SLOW_Q16   = 16'd4855; // 0.015625
  localparam logic [15:0] ALPHA_SIGNAL_Q16 = 16'd13107; // 0.03125*/

  // Fast EMA (approx 4 periods) -> 2/5 = 0.40 -> 26214
  localparam logic [15:0] ALPHA_FAST_Q16   = 16'd26214; 
  // Slow EMA (approx 8 periods) -> 2/9 = 0.222 -> 14563
  localparam logic [15:0] ALPHA_SLOW_Q16   = 16'd14563; 
  // Signal EMA (approx 3 periods) -> 2/4 = 0.50 -> 32768
  localparam logic [15:0] ALPHA_SIGNAL_Q16 = 16'd32768; 

  // Basic risk knobs - SCALED DOWN FOR 2 DECIMAL PLACES (CENTS)
  //localparam logic [31:0] MAX_SPREAD_TICKS = 32'd5;  // $0.05 in 1e-2 units
  localparam logic [31:0] MAX_SPREAD_TICKS = 32'd5;  
  localparam logic [31:0] DEFAULT_QTY      = 32'd100;

  // MACD Cross Threshold
  // Scaled down: previously 50 ($0.0050), now 1 ($0.01)
  //localparam signed [63:0] CROSS_THRESHOLD = 64'd1; 
  localparam signed [63:0] CROSS_THRESHOLD = 64'd0; 

endpackage
