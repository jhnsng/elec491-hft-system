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

  // Strategy outputs (from feature_pipe)
  logic  feat_valid, feat_enter;
  side_e feat_side;
  logic [31:0] feat_price_int, feat_qty;
  logic [31:0] spread_out, mid_out;

  // ----------------------------------------------------------------
  // Boundary Skid Buffer
  // ----------------------------------------------------------------
  logic  sig_valid_reg, sig_enter_reg;
  side_e sig_side_reg;
  logic [31:0] sig_price_int_reg, sig_qty_reg;

  always_ff @(posedge link.clk or negedge link.rst_n) begin
    if (!link.rst_n) begin
      sig_valid_reg     <= 1'b0;
      sig_enter_reg     <= 1'b0;
      sig_side_reg      <= SIDE_BUY;
      sig_price_int_reg <= 32'd0;
      sig_qty_reg       <= 32'd0;
    end else begin
      sig_valid_reg     <= feat_valid;
      sig_enter_reg     <= feat_enter;
      sig_side_reg      <= feat_side;
      sig_price_int_reg <= feat_price_int;
      sig_qty_reg       <= feat_qty;
    end
  end

  feature_pipe u_feat (
    .clk(link.clk),
    .rst_n(link.rst_n),
    .snap_en(snap_fire),
    .sig_ready(sig_ready),

    .bb_p(link.l1.bb_p),
    .bb_q(link.l1.bb_q),
    .ba_p(link.l1.ba_p),
    .ba_q(link.l1.ba_q),

    .alpha_fast_q16(ALPHA_FAST_Q16),
    .alpha_slow_q16(ALPHA_SLOW_Q16),
    .alpha_sig_q16 (ALPHA_SIGNAL_Q16),
    .max_spread    (MAX_SPREAD_TICKS),
    .cross_thresh  (CROSS_THRESHOLD),

    // Connect feature_pipe to the pre-register wires
    .sig_valid(feat_valid),
    .sig_enter(feat_enter),
    .sig_side(feat_side),
    .sig_price_int(feat_price_int),
    .sig_qty(feat_qty),
    .spread_out(spread_out),
    .mid_out(mid_out)
  );

  // Only enqueue real entry decisions
  logic sig_fire;
  assign sig_fire = sig_valid_reg && sig_enter_reg;

  // ----------------------------------------------------------------
  // Token request metadata FIFO
  // ----------------------------------------------------------------
  localparam int META_DEPTH = 4;
  localparam int META_PTR_W = $clog2(META_DEPTH);

  typedef struct packed {
    symbol_id_t sym;
    logic [15:0] strat;
  } tok_meta_t;

  tok_meta_t meta_mem [META_DEPTH];
  logic [META_PTR_W-1:0] meta_wr, meta_rd; // Reduced to 2 bits!
  logic [META_PTR_W:0] meta_count;         // 3-bit count (0 to 4)

  logic meta_empty, meta_full;

  assign meta_empty = (meta_count == 0);
  assign meta_full  = (meta_count == META_DEPTH);

  tok_meta_t meta_head;
  assign meta_head = meta_mem[meta_rd];

  logic meta_enq_pre;
  assign meta_enq_pre = sig_fire && sig_ready;

  (* preserve *) logic meta_enq;
  always_ff @(posedge link.clk or negedge link.rst_n) begin
      if (!link.rst_n) meta_enq <= 1'b0;
      else             meta_enq <= meta_enq_pre;
  end

  logic meta_deq;
  assign meta_deq = link.tok_req_valid && link.tok_req_ready;

  logic meta_can_enq_pre;
  assign meta_can_enq_pre = !meta_full;

  logic meta_can_enq;
  always_ff @(posedge link.clk or negedge link.rst_n) begin
      if (!link.rst_n) meta_can_enq <= 1'b0;
      else             meta_can_enq <= meta_can_enq_pre;
  end

  tok_meta_t meta_mem_data_reg;
  always_ff @(posedge link.clk or negedge link.rst_n) begin
      if (!link.rst_n) meta_mem_data_reg <= '0;
      else             meta_mem_data_reg <= '{ sym: link.l1.symbol_id, strat: 16'h0001 };
  end

  always_ff @(posedge link.clk or negedge link.rst_n) begin
    logic do_read, do_write;

    if (!link.rst_n) begin
      meta_wr <= '0;
      meta_rd <= '0;
      meta_count <= '0;
      for (int i = 0; i < META_DEPTH; i++) meta_mem[i] <= '0;
    end else begin
      do_read  = meta_deq && !meta_empty;
      do_write = meta_enq && meta_can_enq;

      if (do_read)  meta_rd <= meta_rd + 1'b1;

      if (do_write) begin
        meta_mem[meta_wr] <= meta_mem_data_reg;
        meta_wr <= meta_wr + 1'b1;
      end

      // Update count based on simultaneous read/write
      if (do_write && !do_read)      meta_count <= meta_count + 1'b1;
      else if (!do_write && do_read) meta_count <= meta_count - 1'b1;
    end
  end

  // DONT FORGET TO MAP THE DATA OUT TO THE LINK!
  always_ff @(posedge link.clk or negedge link.rst_n) begin
    if (!link.rst_n) begin
      link.tok_req.symbol_id <= 16'd0;
      link.tok_req.strat_id  <= 16'd0;
    end else begin
      link.tok_req.symbol_id <= meta_empty ? 16'd0 : meta_head.sym;
      link.tok_req.strat_id  <= meta_empty ? 16'd0 : meta_head.strat;
    end
  end

  // ----------------------------------------------------------------
  // OUTPUT ISOLATION BUFFERS
  // ----------------------------------------------------------------
  // Internal wires from the FSM
  logic                          fsm_ord_valid;
  hft_types_pkg::order_intent_t  fsm_ord;
  logic                          fsm_tok_req_valid;
  logic                          fsm_tok_resp_ready;

  // Registered outputs to break the combinational loop back to the IO pins
  (* preserve *) logic                          ord_valid_out;
  (* preserve *) hft_types_pkg::order_intent_t  ord_out;
  (* preserve *) logic                          tok_req_valid_out;
  (* preserve *) logic                          tok_resp_ready_out;

  always_ff @(posedge link.clk or negedge link.rst_n) begin
    if (!link.rst_n) begin
      ord_valid_out      <= 1'b0;
      ord_out            <= '0;
      tok_req_valid_out  <= 1'b0;
      tok_resp_ready_out <= 1'b0;
    end else begin
      ord_valid_out      <= fsm_ord_valid;
      ord_out            <= fsm_ord;
      tok_req_valid_out  <= fsm_tok_req_valid;
      tok_resp_ready_out <= fsm_tok_resp_ready;
    end
  end

  // Map the registered outputs to the external interface
  assign link.ord_valid      = ord_valid_out;
  assign link.ord            = ord_out;
  assign link.tok_req_valid  = tok_req_valid_out;
  assign link.tok_resp_ready = tok_resp_ready_out;

  // Order FSM
  order_fsm u_fsm (
    .clk(link.clk),
    .rst_n(link.rst_n),

    .sig_valid(sig_fire),
    .sig_ready(sig_ready),
    .sig_side(sig_side_reg),
    .sig_price(sig_price_int_reg),
    .sig_qty(sig_qty_reg),

    // Connect FSM outputs to our internal wires, NOT the external link
    .tok_req_valid(fsm_tok_req_valid),
    .tok_req_ready(link.tok_req_ready),

    .tok_resp_valid(link.tok_resp_valid),
    .tok_resp_ready(fsm_tok_resp_ready),
    .tok_resp_id(link.tok_resp.token_id),

    .ord_valid(fsm_ord_valid),
    .ord_ready(link.ord_ready),
    .ord      (fsm_ord),

    .rpt_valid(link.rpt_valid),
    .rpt_ready(link.rpt_ready),
    .rpt      (link.rpt),

    .symbol_id(link.l1.symbol_id),
    .strat_id (16'h0001)
  );

endmodule
