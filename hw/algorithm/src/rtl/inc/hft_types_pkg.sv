package hft_types_pkg;

  // ---------- Common ----------
  typedef logic [15:0] symbol_id_t;

  // ---------- Market snapshot (L1) ----------
  typedef struct packed {
    symbol_id_t  symbol_id;
    logic [63:0] ts_ns;        // internal timebase (ns since midnight or sim time)
    logic [31:0] bb_p;         // best bid price (dollars * 10000)
    logic [31:0] bb_q;         // best bid aggregated qty
    logic [31:0] ba_p;         // best ask price (dollars * 10000)
    logic [31:0] ba_q;         // best ask aggregated qty
  } l1_snap_t;

  // ---------- Order intents ----------
  typedef enum logic [1:0] {
    ACT_NOP    = 2'b00,
    ACT_ENTER  = 2'b01,
    ACT_CANCEL = 2'b10
    // ACT_REPLACE = 2'b11
  } action_e;

  typedef enum logic [0:0] {
    SIDE_BUY  = 1'b0,
    SIDE_SELL = 1'b1
  } side_e;

  typedef struct packed {
    symbol_id_t  symbol_id;
    action_e     action;
    side_e       side;
    logic [31:0] price_int;    // dollars * 10000
    logic [31:0] qty;          // shares (ENTER) or "new intended total size" (CANCEL semantics)
    logic [31:0] token_id;     // allocated by formatter (handle, not ASCII)
    logic [15:0] strat_id;     // optional: strategy/version tagging
  } order_intent_t;

  // ---------- Token allocation ----------
  typedef struct packed {
    symbol_id_t  symbol_id;
    logic [15:0] strat_id;     // optional
  } token_req_t;

  typedef struct packed {
    symbol_id_t  symbol_id;
    logic [31:0] token_id;
  } token_resp_t;

  // ---------- Order reports (formatter/exchange -> algo) ----------
  typedef enum logic [1:0] {
    RPT_EXEC     = 2'b00,  // execution happened (k may be < qty)
    RPT_CANCELED = 2'b01,  // cancel acknowledged / order dead
    RPT_REJECT   = 2'b10   // rejected / order dead
  } rpt_kind_e;

  typedef struct packed {
    symbol_id_t  symbol_id;
    logic [31:0] token_id;
    rpt_kind_e   kind;
    logic [31:0] filled_total; // for your design: "k filled for this order"
  } order_rpt_t;

endpackage
