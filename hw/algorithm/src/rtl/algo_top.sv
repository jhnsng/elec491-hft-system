module algo_top (
  algo_links_if.algo_mp link
);
  import hft_types_pkg::*;
  import algo_cfg_pkg::*;

  // Backpressure from order path
  logic sig_ready;
  assign link.l1_ready = sig_ready;

  logic snap_fire;
  assign snap_fire = link.l1_valid && link.l1_ready;

  // Strategy outputs
  logic  sig_valid, sig_enter;
  side_e sig_side;
  logic [31:0] sig_price_int, sig_qty;
  logic [31:0] spread_out, mid_out;

  feature_pipe u_feat (
    .clk(link.clk),
    .rst_n(link.rst_n),
    .snap_en(snap_fire),

    .bb_p(link.l1.bb_p),
    .bb_q(link.l1.bb_q),
    .ba_p(link.l1.ba_p),
    .ba_q(link.l1.ba_q),

    .alpha_fast_q16(ALPHA_FAST_Q16),
    .alpha_slow_q16(ALPHA_SLOW_Q16),
    .alpha_sig_q16 (ALPHA_SIGNAL_Q16),
    .max_spread    (MAX_SPREAD_TICKS),
    .cross_thresh(CROSS_THRESHOLD),

    .sig_valid(sig_valid),
    .sig_enter(sig_enter),
    .sig_side(sig_side),
    .sig_price_int(sig_price_int),
    .sig_qty(sig_qty),
    .spread_out(spread_out),
    .mid_out(mid_out)
  );

  // Only enqueue real entry decisions
  logic sig_fire;
  assign sig_fire = sig_valid && sig_enter;

  // ----------------------------------------------------------------
  // Token request metadata FIFO (keeps tok_req stable + correctly aligned)
  // ----------------------------------------------------------------
  localparam int META_DEPTH = 4;
  localparam int META_PTR_W = $clog2(META_DEPTH);

  typedef struct packed {
    symbol_id_t sym;
    logic [15:0] strat;
  } tok_meta_t;

  tok_meta_t meta_mem [META_DEPTH];
  logic [META_PTR_W:0] meta_wr, meta_rd;
  logic meta_empty, meta_full;

  assign meta_empty = (meta_wr == meta_rd);
  assign meta_full  =
      (meta_wr[META_PTR_W] != meta_rd[META_PTR_W]) &&
      (meta_wr[META_PTR_W-1:0] == meta_rd[META_PTR_W-1:0]);

  tok_meta_t meta_head;
  assign meta_head = meta_mem[meta_rd[META_PTR_W-1:0]];

  // Enqueue exactly when order_fsm accepts a decision
  logic meta_enq;
  assign meta_enq = sig_fire && sig_ready;

  // Dequeue exactly when token request is accepted by formatter
  logic meta_deq;
  assign meta_deq = link.tok_req_valid && link.tok_req_ready;

  logic meta_can_enq;
  assign meta_can_enq = (!meta_full) || meta_deq; // allow pop+push same cycle

  always_ff @(posedge link.clk or negedge link.rst_n) begin
    if (!link.rst_n) begin
      meta_wr <= '0;
      meta_rd <= '0;
      for (int i = 0; i < META_DEPTH; i++) meta_mem[i] <= '0;
    end else begin
      if (meta_deq && !meta_empty) begin
        meta_rd <= meta_rd + 1'b1;
      end

      if (meta_enq && meta_can_enq) begin
        meta_mem[meta_wr[META_PTR_W-1:0]] <= '{ sym: link.l1.symbol_id, strat: 16'h0001 };
        meta_wr <= meta_wr + 1'b1;
      end
    end
  end

  // Drive token request fields from metadata FIFO head (stable while valid)
  always_comb begin
    link.tok_req.symbol_id = meta_empty ? 16'd0 : meta_head.sym;
    link.tok_req.strat_id  = meta_empty ? 16'd0 : meta_head.strat;
  end

  // Order FSM
  order_fsm u_fsm (
    .clk(link.clk),
    .rst_n(link.rst_n),

    .sig_valid(sig_fire),
    .sig_ready(sig_ready),
    .sig_side(sig_side),
    .sig_price(sig_price_int),
    .sig_qty(sig_qty),

    .tok_req_valid(link.tok_req_valid),
    .tok_req_ready(link.tok_req_ready),

    .tok_resp_valid(link.tok_resp_valid),
    .tok_resp_ready(link.tok_resp_ready),
    .tok_resp_id(link.tok_resp.token_id),

    .ord_valid(link.ord_valid),
    .ord_ready(link.ord_ready),
    .ord      (link.ord),

    .rpt_valid(link.rpt_valid),
    .rpt_ready(link.rpt_ready),
    .rpt      (link.rpt),

    .symbol_id(link.l1.symbol_id),
    .strat_id (16'h0001)
  );

endmodule
