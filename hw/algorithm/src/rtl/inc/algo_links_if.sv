interface algo_links_if (input logic clk, input logic rst_n);
  import hft_types_pkg::*;

  // ----------------------------
  // Orderbook -> Algo (L1 snapshot stream)
  // ----------------------------
  logic     l1_valid;
  logic     l1_ready;
  l1_snap_t l1;

  // ----------------------------
  // Algo <-> Formatter (token allocator)
  // ----------------------------
  logic       tok_req_valid;
  logic       tok_req_ready;
  token_req_t tok_req;

  logic        tok_resp_valid;
  logic        tok_resp_ready;
  token_resp_t tok_resp;

  // ----------------------------
  // Algo -> Formatter (order intent stream)
  // ----------------------------
  logic          ord_valid;
  logic          ord_ready;
  order_intent_t ord;

  // ----------------------------
  // Formatter/Exchange -> Algo (order reports)
  // ----------------------------
  logic       rpt_valid;
  logic       rpt_ready;
  order_rpt_t rpt;

  // Modports
  modport algo_mp (
    input  clk, rst_n,

    input  l1_valid, l1,
    output l1_ready,

    output tok_req_valid, tok_req,
    input  tok_req_ready,

    input  tok_resp_valid, tok_resp,
    output tok_resp_ready,

    output ord_valid, ord,
    input  ord_ready,

    input  rpt_valid, rpt,
    output rpt_ready
  );

  modport ob_mp ( // orderbook producer
    input  clk, rst_n,
    output l1_valid, l1,
    input  l1_ready
  );

  modport fmt_mp ( // formatter consumer/producer
    input  clk, rst_n,

    input  tok_req_valid, tok_req,
    output tok_req_ready,

    output tok_resp_valid, tok_resp,
    input  tok_resp_ready,

    input  ord_valid, ord,
    output ord_ready,

    output rpt_valid, rpt,
    input  rpt_ready
  );

endinterface
