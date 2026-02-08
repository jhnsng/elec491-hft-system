module algorithm (
  input  logic clk,
  input  logic rst_n,

  // ----------------------------
  // L1 snapshot input
  // ----------------------------
  input  logic        l1_valid,
  output logic        l1_ready,
  input  logic [15:0] l1_symbol_id,
  input  logic [63:0] l1_ts_ns,
  input  logic [31:0] bb_p,
  input  logic [31:0] bb_q,
  input  logic [31:0] ba_p,
  input  logic [31:0] ba_q,

  // ----------------------------
  // Token request output
  // ----------------------------
  output logic        tok_req_valid,
  input  logic        tok_req_ready,
  output logic [15:0] tok_req_symbol_id,
  output logic [15:0] tok_req_strat_id,

  // ----------------------------
  // Token response input
  // ----------------------------
  input  logic        tok_resp_valid,
  output logic        tok_resp_ready,
  input  logic [15:0] tok_resp_symbol_id,
  input  logic [31:0] tok_resp_token_id,

  // ----------------------------
  // Order intent output
  // ----------------------------
  output logic        ord_valid,
  input  logic        ord_ready,
  output logic [15:0] ord_symbol_id,
  output logic [1:0]  ord_action,
  output logic        ord_side,
  output logic [31:0] ord_price_int,
  output logic [31:0] ord_qty,
  output logic [31:0] ord_token_id,
  output logic [15:0] ord_strat_id,

  // ----------------------------
  // Order report input
  // ----------------------------
  input  logic        rpt_valid,
  output logic        rpt_ready,
  input  logic [15:0] rpt_symbol_id,
  input  logic [31:0] rpt_token_id,
  input  logic [1:0]  rpt_kind,
  input  logic [31:0] rpt_filled_total
);

  import hft_types_pkg::*;

  // Internal interface
  algo_links_if link(.clk(clk), .rst_n(rst_n));

  // ----------------------------
  // L1 mapping
  // ----------------------------
  assign link.l1_valid = l1_valid;
  assign l1_ready      = link.l1_ready;

  assign link.l1.symbol_id = l1_symbol_id;
  assign link.l1.ts_ns     = l1_ts_ns;
  assign link.l1.bb_p      = bb_p;
  assign link.l1.bb_q      = bb_q;
  assign link.l1.ba_p      = ba_p;
  assign link.l1.ba_q      = ba_q;

  // ----------------------------
  // Token request mapping
  // ----------------------------
  assign tok_req_valid       = link.tok_req_valid;
  assign link.tok_req_ready = tok_req_ready;

  assign tok_req_symbol_id = link.tok_req.symbol_id;
  assign tok_req_strat_id  = link.tok_req.strat_id;

  // ----------------------------
  // Token response mapping
  // ----------------------------
  assign link.tok_resp_valid    = tok_resp_valid;
  assign tok_resp_ready         = link.tok_resp_ready;
  assign link.tok_resp.symbol_id = tok_resp_symbol_id;
  assign link.tok_resp.token_id  = tok_resp_token_id;

  // ----------------------------
  // Order intent mapping
  // ----------------------------
  assign ord_valid = link.ord_valid;
  assign link.ord_ready = ord_ready;

  assign ord_symbol_id = link.ord.symbol_id;
  assign ord_action    = link.ord.action;
  assign ord_side      = link.ord.side;
  assign ord_price_int = link.ord.price_int;
  assign ord_qty       = link.ord.qty;
  assign ord_token_id  = link.ord.token_id;
  assign ord_strat_id  = link.ord.strat_id;

  // ----------------------------
  // Order report mapping
  // ----------------------------
  assign link.rpt_valid = rpt_valid;
  assign rpt_ready      = link.rpt_ready;

  assign link.rpt.symbol_id    = rpt_symbol_id;
  assign link.rpt.token_id     = rpt_token_id;
  assign link.rpt.kind         = rpt_kind_e'(rpt_kind);
  assign link.rpt.filled_total = rpt_filled_total;

  // ----------------------------
  // Core
  // ----------------------------
  algo_top u_core (.link(link));

endmodule
