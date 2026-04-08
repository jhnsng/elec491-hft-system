package algo_cfg_pkg;

  localparam int EMA_Q = 16;
  
  // These alphas are great (approx 0.4 for Fast, 0.22 for Slow). 
  // Perfect for catching short-term SPY momentum!
  localparam logic [15:0] ALPHA_FAST_Q16   = 16'd26214; 
  localparam logic [15:0] ALPHA_SLOW_Q16   = 16'd14563; 
  localparam logic [15:0] ALPHA_SIGNAL_Q16 = 16'd32768; 

  // 5 ticks = $0.05 max spread. SPY is highly liquid, so this safely 
  // prevents you from trading during crazy volatility spikes.
  localparam logic [31:0] MAX_SPREAD_TICKS = 32'd5;  
  localparam logic [31:0] DEFAULT_QTY      = 32'd100;

  // CHANGE THIS TO 3 or 5!
  // Since 1 unit = $0.01, a threshold of 3 means the momentum must 
  // clearly break out by 3 full cents before the FPGA pulls the trigger.
  localparam signed [63:0] CROSS_THRESHOLD = 64'd3; 

endpackage