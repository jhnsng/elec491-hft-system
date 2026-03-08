module algo_wrapper (
  input  logic clk,
  input  logic rst_n,

  output logic dbg_ord_valid,
  output logic dbg_tok_req_valid
);

  // ----------------------------
  // L1 snapshot stimulus
  // ----------------------------
  logic        l1_valid;
  logic        l1_ready;
  logic [15:0] l1_symbol_id;
  logic [63:0] l1_ts_ns;
  logic [31:0] bb_p, bb_q, ba_p, ba_q;

  logic [23:0] ctr;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)
      ctr <= '0;
    else
      ctr <= ctr + 1'b1;
  end

  assign l1_valid     = ctr[20];
  assign l1_symbol_id = 16'h0001;
  assign l1_ts_ns     = {40'd0, ctr};

  assign bb_q = 32'd10;
  assign ba_q = 32'd12;

  // price moves slowly
  logic signed [31:0] price_ctr;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)
      price_ctr <= 0;
    else
      price_ctr <= price_ctr + 1;
  end

  assign bb_p = 32'd100000 + price_ctr;
  assign ba_p = bb_p + 32'd50;

  // ----------------------------
  // Token request channel
  // ----------------------------
  logic        tok_req_valid;
  logic        tok_req_ready;
  logic [15:0] tok_req_symbol_id;
  logic [15:0] tok_req_strat_id;

  assign tok_req_ready = 1'b1;

  // ----------------------------
  // Token response channel
  // ----------------------------
  logic        tok_resp_valid;
  logic        tok_resp_ready;
  logic [15:0] tok_resp_symbol_id;
  logic [31:0] tok_resp_token_id;

  assign tok_resp_ready = 1'b1;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      tok_resp_valid     <= 1'b0;
      tok_resp_symbol_id <= '0;
      tok_resp_token_id  <= '0;
    end else begin
      tok_resp_valid     <= tok_req_valid;
      tok_resp_symbol_id <= tok_req_symbol_id;
      tok_resp_token_id  <= 32'hCAFE_1234;
    end
  end

  // ----------------------------
  // Order intent channel
  // ----------------------------
  logic        ord_valid;
  logic        ord_ready;
  logic [15:0] ord_symbol_id;
  logic [1:0]  ord_action;
  logic        ord_side;
  logic [31:0] ord_price_int;
  logic [31:0] ord_qty;
  logic [31:0] ord_token_id;
  logic [15:0] ord_strat_id;

  assign ord_ready = 1'b1;

  assign dbg_ord_valid     = ord_valid;
  assign dbg_tok_req_valid = tok_req_valid;

  // ----------------------------
  // Order report channel
  // ----------------------------
  logic        rpt_valid;
  logic        rpt_ready;
  logic [15:0] rpt_symbol_id;
  logic [31:0] rpt_token_id;
  logic [1:0]  rpt_kind;
  logic [31:0] rpt_filled_total;

  assign rpt_ready        = 1'b1;
  assign rpt_valid        = 1'b0;
  assign rpt_kind         = 2'b00;
  assign rpt_filled_total = '0;

  // ----------------------------
  // DUT
  // ----------------------------
  algorithm u_algo (
    .clk(clk),
    .rst_n(rst_n),

    .l1_valid(l1_valid),
    .l1_ready(l1_ready),
    .l1_symbol_id(l1_symbol_id),
    .l1_ts_ns(l1_ts_ns),
    .bb_p(bb_p),
    .bb_q(bb_q),
    .ba_p(ba_p),
    .ba_q(ba_q),

    .tok_req_valid(tok_req_valid),
    .tok_req_ready(tok_req_ready),
    .tok_req_symbol_id(tok_req_symbol_id),
    .tok_req_strat_id(tok_req_strat_id),

    .tok_resp_valid(tok_resp_valid),
    .tok_resp_ready(tok_resp_ready),
    .tok_resp_symbol_id(tok_resp_symbol_id),
    .tok_resp_token_id(tok_resp_token_id),

    .ord_valid(ord_valid),
    .ord_ready(ord_ready),
    .ord_symbol_id(ord_symbol_id),
    .ord_action(ord_action),
    .ord_side(ord_side),
    .ord_price_int(ord_price_int),
    .ord_qty(ord_qty),
    .ord_token_id(ord_token_id),
    .ord_strat_id(ord_strat_id),

    .rpt_valid(rpt_valid),
    .rpt_ready(rpt_ready),
    .rpt_symbol_id(rpt_symbol_id),
    .rpt_token_id(rpt_token_id),
    .rpt_kind(rpt_kind),
    .rpt_filled_total(rpt_filled_total)
  );

endmodule
