package algo_cfg_pkg;

  // Fixed-point choice for EMA coefficients: Q16
  localparam int EMA_Q = 16;

  // =========================================================================
  // THE "SNIPER" CONFIGURATION (Fast EMAs)
  // =========================================================================
  localparam logic [15:0] ALPHA_FAST_Q16   = 16'd26214; 
  localparam logic [15:0] ALPHA_SLOW_Q16   = 16'd14563; 
  localparam logic [15:0] ALPHA_SIGNAL_Q16 = 16'd32768; 

  // =========================================================================
  // 2-DECIMAL SCALED RISK & SPREAD KNOBS (1 unit = 1 cent)
  // =========================================================================
  
  // Allow trading as long as the spread is $0.05 or less (5 units)
  localparam logic [31:0] MAX_SPREAD_TICKS = 32'd5;  
  
  localparam logic [31:0] DEFAULT_QTY      = 32'd100;

  // Require a true 2-cent momentum breakout (2 units) to beat the spread!
  localparam signed [63:0] CROSS_THRESHOLD = 64'd2; 

endpackage