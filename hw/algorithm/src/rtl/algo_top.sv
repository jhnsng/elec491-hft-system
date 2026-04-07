module algo_top (
  algo_links_if.algo_mp link
);
  import hft_types_pkg::*;
  import algo_cfg_pkg::*;

  // ----------------------------------------------------------------
  // QUARTUS I/O ISOLATION BOUNDARY
  // ----------------------------------------------------------------
  // These force Quartus to measure timing from INSIDE the fabric
  // rather than from the physical pins on the edge of the board.
  (* preserve, dont_merge, dont_retime *) logic rst_n_reg;
  (* preserve, dont_merge, dont_retime *) logic tok_req_ready_reg;

  always_ff @(posedge link.clk) begin
    rst_n_reg         <= link.rst_n;
    tok_req_ready_reg <= link.tok_req_ready;
  end

  // ----------------------------------------------------------------
  // Internal Token Allocator
  // ----------------------------------------------------------------
  logic        internal_tok_req_valid;
  logic        internal_tok_req_ready;
  logic        internal_tok_resp_valid;
  logic [31:0] internal_tok_resp_id;
  logic [31:0] next_token;

  assign internal_tok_req_ready = 1'b1; // Always ready to give a token

  always_ff @(posedge link.clk) begin
      if (!rst_n_reg) begin
          next_token <= 32'd1;  // Start at Token #1
          internal_tok_resp_valid <= 1'b0;
      end else begin
          internal_tok_resp_valid <= 1'b0; // Default pulse
          
          if (internal_tok_req_valid && internal_tok_req_ready) begin
              internal_tok_resp_valid <= 1'b1;
              internal_tok_resp_id    <= next_token;
              next_token              <= next_token + 32'd1; 
          end
      end
  end

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
  logic [META_PTR_W-1:0] meta_wr, meta_rd; 
  logic [META_PTR_W:0] meta_count;         

  logic meta_empty, meta_full;

  assign meta_empty = (meta_count == 0);
  assign meta_full  = (meta_count == META_DEPTH);

  // ----------------------------------------------------------------
  // Backpressure & Readiness Gate
  // ----------------------------------------------------------------
  logic fsm_sig_ready; 
  logic sig_ready;     
  logic pipe_ready; 

  assign sig_ready = fsm_sig_ready && !meta_full; 
  assign link.l1_ready = sig_ready && pipe_ready; 

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

  always_ff @(posedge link.clk) begin
    // Note: We use rst_n_reg here!
    if (!rst_n_reg) begin
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
    .rst_n(rst_n_reg),     // Intercepted Reset
    .snap_en(snap_fire),
    .sig_ready(sig_ready), 
    .pipe_ready(pipe_ready),

    .bb_p(link.l1.bb_p),
    .bb_q(link.l1.bb_q),
    .ba_p(link.l1.ba_p),
    .ba_q(link.l1.ba_q),

    .alpha_fast_q16(ALPHA_FAST_Q16),
    .alpha_slow_q16(ALPHA_SLOW_Q16),
    .alpha_sig_q16 (ALPHA_SIGNAL_Q16),
    .max_spread    (MAX_SPREAD_TICKS),
    .cross_thresh  (CROSS_THRESHOLD),

    .sig_valid(feat_valid),
    .sig_enter(feat_enter),
    .sig_side(feat_side),
    .sig_price_int(feat_price_int),
    .sig_qty(feat_qty),
    .spread_out(spread_out),
    .mid_out(mid_out)
  );

  logic sig_fire;
  assign sig_fire = sig_valid_reg && sig_enter_reg;

  // ----------------------------------------------------------------
  // Token request metadata FIFO Tracking
  // ----------------------------------------------------------------
  tok_meta_t meta_head;
  assign meta_head = meta_mem[meta_rd];

  logic meta_enq_pre;
  assign meta_enq_pre = sig_fire && sig_ready;

  (* preserve *) logic meta_enq;
  always_ff @(posedge link.clk) begin
      if (!rst_n_reg) meta_enq <= 1'b0;
      else            meta_enq <= meta_enq_pre;
  end

  logic meta_deq;
  // Drain the FIFO using the internal token allocator signals!
  assign meta_deq = internal_tok_req_valid && internal_tok_req_ready;

  logic meta_can_enq_pre;
  assign meta_can_enq_pre = !meta_full;

  logic meta_can_enq;
  always_ff @(posedge link.clk) begin
      if (!rst_n_reg) meta_can_enq <= 1'b0;
      else            meta_can_enq <= meta_can_enq_pre;
  end

  tok_meta_t meta_mem_data_reg;
  always_ff @(posedge link.clk) begin
      if (!rst_n_reg) meta_mem_data_reg <= '0;
      else            meta_mem_data_reg <= '{ sym: link.l1.symbol_id, strat: 16'h0001 };
  end

  always_ff @(posedge link.clk) begin
    logic do_read, do_write;

    if (!rst_n_reg) begin
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

      if (do_write && !do_read)      meta_count <= meta_count + 1'b1;
      else if (!do_write && do_read) meta_count <= meta_count - 1'b1;
    end
  end

  always_ff @(posedge link.clk) begin
    if (!rst_n_reg) begin
      link.tok_req.symbol_id <= 16'd0;
      link.tok_req.strat_id  <= 16'd0;
    end else begin
      link.tok_req.symbol_id <= meta_empty ? 16'd0 : meta_head.sym;
      link.tok_req.strat_id  <= meta_empty ? 16'd0 : meta_head.strat;
    end
  end

  // =================================================================
  // Order FSM Instantiation
  // =================================================================
  order_fsm u_fsm (
    .clk(link.clk),
    .rst_n(rst_n_reg),   // Intercepted Reset

    .sig_valid(sig_fire),
    .sig_ready(fsm_sig_ready), 
    .sig_side(sig_side_reg),
    .sig_price(sig_price_int_reg),
    .sig_qty(sig_qty_reg),

    // INTERNALLY ROUTED TOKEN SIGNALS
    .tok_req_valid(internal_tok_req_valid),
    .tok_req_ready(internal_tok_req_ready),
    .tok_resp_valid(internal_tok_resp_valid),
    .tok_resp_ready(), // Ignored by internal allocator
    .tok_resp_id(internal_tok_resp_id),

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