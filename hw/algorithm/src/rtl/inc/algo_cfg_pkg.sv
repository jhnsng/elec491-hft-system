package algo_cfg_pkg;

  // Fixed-point choice for EMA coefficients: Q16
  localparam int EMA_Q = 16;

  // =========================================================================
  // THE "MEDIUM SMOOTHER" CONFIGURATION
  // =========================================================================

  // Fast EMA (approx 15 periods) -> 2/(15+1) = 0.1250 -> 0.125 * 65536 = 8192
  localparam logic [15:0] ALPHA_FAST_Q16   = 16'd8192; 

  // Slow EMA (approx 31 periods) -> 2/(31+1) = 0.0625 -> 0.0625 * 65536 = 4096
  localparam logic [15:0] ALPHA_SLOW_Q16   = 16'd4096; 

  // Signal EMA (approx 9 periods) -> 2/(9+1) = 0.2000 -> 0.20 * 65536 = 13107
  localparam logic [15:0] ALPHA_SIGNAL_Q16 = 16'd13107; 


  // =========================================================================
  // RISK & SPREAD KNOBS
  // =========================================================================
  
  // Basic risk knobs - SCALED DOWN FOR 2 DECIMAL PLACES (CENTS)
  localparam logic [31:0] MAX_SPREAD_TICKS = 32'd5;  // Do not trade if spread > $0.05
  localparam logic [31:0] DEFAULT_QTY      = 32'd100; // Standard 1 lot

  // MACD Cross Threshold
  // Requires the MACD to show a definitive momentum shift > 2 cents.
  // This prevents the algorithm from buying/selling inside a flat 1-cent spread.
  localparam signed [63:0] CROSS_THRESHOLD = 64'd2; 

endpackage