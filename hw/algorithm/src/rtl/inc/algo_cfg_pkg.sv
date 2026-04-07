package algo_cfg_pkg;

  // Fixed-point choice for EMA coefficients: Q16
  localparam int EMA_Q = 16;

  // =========================================================================
  // THE "SNIPER" CONFIGURATION (Fast EMAs + Strict Spread Protection)
  // =========================================================================

  // Fast EMA (approx 4 periods) -> 2/5 = 0.40 -> 26214
  localparam logic [15:0] ALPHA_FAST_Q16   = 16'd26214; 
  // Slow EMA (approx 8 periods) -> 2/9 = 0.222 -> 14563
  localparam logic [15:0] ALPHA_SLOW_Q16   = 16'd14563; 
  // Signal EMA (approx 3 periods) -> 2/4 = 0.50 -> 32768
  localparam logic [15:0] ALPHA_SIGNAL_Q16 = 16'd32768; 

  // =========================================================================
  // RISK & SPREAD KNOBS
  // =========================================================================
  localparam logic [31:0] MAX_SPREAD_TICKS = 32'd5;  
  localparam logic [31:0] DEFAULT_QTY      = 32'd100;

  // MACD Cross Threshold (Keeps us safe from the 2-cent spread!)
  localparam signed [63:0] CROSS_THRESHOLD = 64'd2; 

endpackage