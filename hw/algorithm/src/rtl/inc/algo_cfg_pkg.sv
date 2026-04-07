package algo_cfg_pkg;

  localparam int EMA_Q = 16;
  localparam logic [15:0] ALPHA_FAST_Q16   = 16'd26214; 
  localparam logic [15:0] ALPHA_SLOW_Q16   = 16'd14563; 
  localparam logic [15:0] ALPHA_SIGNAL_Q16 = 16'd32768; 

  localparam logic [31:0] MAX_SPREAD_TICKS = 32'd5;  
  localparam logic [31:0] DEFAULT_QTY      = 32'd100;

  // CHANGED TO 0: Trade on every single microscopic crossover!
  localparam signed [63:0] CROSS_THRESHOLD = 64'd0; 

endpackage