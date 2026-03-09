module order_fsm (
  input  logic clk,
  input  logic rst_n,

  // Decision input (from feature_pipe)
  input  logic                 sig_valid,
  output logic                 sig_ready,
  input  hft_types_pkg::side_e sig_side,
  input  logic [31:0]          sig_price,
  input  logic [31:0]          sig_qty,

  // Token allocator
  output logic tok_req_valid,
  input  logic tok_req_ready,

  input  logic tok_resp_valid,
  output logic tok_resp_ready,
  input  logic [31:0] tok_resp_id,

  // Order intent output
  output logic                     ord_valid,
  input  logic                     ord_ready,
  output hft_types_pkg::order_intent_t ord,

  // Exchange/formatter reports
  input  logic                     rpt_valid,
  output logic                     rpt_ready,
  input  hft_types_pkg::order_rpt_t rpt,

  input  hft_types_pkg::symbol_id_t  symbol_id,
  input  logic [15:0]                strat_id
);

  import hft_types_pkg::*;

  typedef struct packed {
    symbol_id_t  symbol_id;
    side_e       side;
    logic [31:0] price;
    logic [31:0] qty;
  } intent_t;

  // ----------------------------
  // Intent FIFO 
  // ----------------------------
  localparam int FIFO_DEPTH = 4;
  localparam int PTR_W      = $clog2(FIFO_DEPTH);

  intent_t fifo_mem [FIFO_DEPTH];
  logic [PTR_W:0] wr_ptr, rd_ptr;
  logic fifo_full, fifo_empty;

  assign fifo_empty = (wr_ptr == rd_ptr);
  assign fifo_full  =
      (wr_ptr[PTR_W] != rd_ptr[PTR_W]) &&
      (wr_ptr[PTR_W-1:0] == rd_ptr[PTR_W-1:0]);

  intent_t fifo_rdata;
  assign fifo_rdata = fifo_mem[rd_ptr[PTR_W-1:0]];

  logic fifo_pop;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      wr_ptr <= '0;
    end else if (sig_valid && sig_ready) begin
      fifo_mem[wr_ptr[PTR_W-1:0]].symbol_id <= symbol_id;
      fifo_mem[wr_ptr[PTR_W-1:0]].side      <= sig_side;
      fifo_mem[wr_ptr[PTR_W-1:0]].price     <= sig_price;
      fifo_mem[wr_ptr[PTR_W-1:0]].qty       <= sig_qty;
      wr_ptr <= wr_ptr + 1'b1;
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rd_ptr <= '0;
    end else if (fifo_pop && !fifo_empty) begin
      rd_ptr <= rd_ptr + 1'b1;
    end
  end

  // ----------------------------
  // Outstanding table (token->state)
  // ----------------------------
  localparam int MAX_OUT = 4;

  typedef struct packed {
    logic        valid;
    symbol_id_t  symbol_id;
    logic [31:0] token_id;
    side_e       side;
    logic [31:0] price;
    logic [31:0] qty;
    logic [31:0] filled_tot;
    logic        cancel_sent;
  } out_ent_t;

  out_ent_t out_tab [MAX_OUT];

  // ----------------------------
  // Free Slot Finder (Parallel)
  // ----------------------------
  logic [1:0] free_i;
  logic       has_free;
  
  always_comb begin
    free_i = 2'd0;
    has_free = 1'b0;
    if      (!out_tab[0].valid) begin free_i = 2'd0; has_free = 1'b1; end
    else if (!out_tab[1].valid) begin free_i = 2'd1; has_free = 1'b1; end
    else if (!out_tab[2].valid) begin free_i = 2'd2; has_free = 1'b1; end
    else if (!out_tab[3].valid) begin free_i = 2'd3; has_free = 1'b1; end
  end

  logic out_full;
  assign out_full = !has_free;
  assign sig_ready = !fifo_full && !out_full;

   // ----------------------------
  // Token Matcher & Pipelining
  // ----------------------------

  // --- STAGE 0: Incoming Report Buffer ---
  // Buffer the incoming report so it doesn't fan out directly from I/O pins
  logic                      rpt_valid_s0;
  hft_types_pkg::order_rpt_t rpt_s0;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rpt_valid_s0 <= 1'b0;
      rpt_s0       <= '0;
    end else begin
      rpt_valid_s0 <= rpt_valid;
      rpt_s0       <= rpt;
    end
  end

  // --- STAGE 1: Match Generation (Isolates the Equal6 comparators) ---
  logic [MAX_OUT-1:0]        token_match_s1;
  logic                      rpt_valid_s1;
  hft_types_pkg::order_rpt_t rpt_s1;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      token_match_s1 <= '0;
      rpt_valid_s1   <= 1'b0;
      rpt_s1         <= '0;
    end else begin
      rpt_valid_s1 <= rpt_valid_s0;
      rpt_s1       <= rpt_s0;
      
      // Force hardware registers immediately after the 32-bit equality checks
      token_match_s1[0] <= out_tab[0].valid && (out_tab[0].token_id == rpt_s0.token_id);
      token_match_s1[1] <= out_tab[1].valid && (out_tab[1].token_id == rpt_s0.token_id);
      token_match_s1[2] <= out_tab[2].valid && (out_tab[2].token_id == rpt_s0.token_id);
      token_match_s1[3] <= out_tab[3].valid && (out_tab[3].token_id == rpt_s0.token_id);
    end
  end

  // --- STAGE 2: Data Muxing (Uses the registered matches) ---
  logic                      rpt_valid_s2;
  hft_types_pkg::order_rpt_t rpt_s2;
  logic                      has_match_s2;
  out_ent_t                  match_data_s2;
  logic [31:0]               matched_qty_s2;
  logic [MAX_OUT-1:0]        token_match_s2;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rpt_valid_s2   <= 1'b0;
      rpt_s2         <= '0;
      has_match_s2   <= 1'b0;
      match_data_s2  <= '0;
      matched_qty_s2 <= 32'd0;
      token_match_s2 <= '0;
    end else begin
      rpt_valid_s2   <= rpt_valid_s1;
      rpt_s2         <= rpt_s1;
      token_match_s2 <= token_match_s1;
      has_match_s2   <= |token_match_s1; // Logical OR of registered bits

      // Now the large multiplexer runs based purely on registered select signals
      if (token_match_s1[0]) begin
        match_data_s2  <= out_tab[0];
        matched_qty_s2 <= out_tab[0].qty;
      end else if (token_match_s1[1]) begin
        match_data_s2  <= out_tab[1];
        matched_qty_s2 <= out_tab[1].qty;
      end else if (token_match_s1[2]) begin
        match_data_s2  <= out_tab[2];
        matched_qty_s2 <= out_tab[2].qty;
      end else if (token_match_s1[3]) begin
        match_data_s2  <= out_tab[3];
        matched_qty_s2 <= out_tab[3].qty;
      end else begin
        match_data_s2  <= '0;
        matched_qty_s2 <= 32'd0;
      end
    end
  end

  // --- STAGE 3: Slow 32-bit Comparators ---
  logic                      rpt_valid_p1;
  hft_types_pkg::order_rpt_t rpt_p1;
  logic [MAX_OUT-1:0]        token_match_p1;
  logic                      has_match_p1;
  out_ent_t                  match_data_p1;
  logic                      is_partial_fill_p1;
  logic                      is_complete_fill_p1;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rpt_valid_p1        <= 1'b0;
      rpt_p1              <= '0;
      token_match_p1      <= '0;
      has_match_p1        <= 1'b0;
      match_data_p1       <= '0;
      is_partial_fill_p1  <= 1'b0;
      is_complete_fill_p1 <= 1'b0;
    end else begin
      rpt_valid_p1   <= rpt_valid_s2;
      rpt_p1         <= rpt_s2;
      token_match_p1 <= token_match_s2;
      has_match_p1   <= has_match_s2;
      match_data_p1  <= match_data_s2;

      // The less-than/greater-than comparators run completely isolated
      is_partial_fill_p1  <= (rpt_s2.filled_total <  matched_qty_s2);
      is_complete_fill_p1 <= (rpt_s2.filled_total >= matched_qty_s2);
    end
  end


  // ----------------------------
  // Cancel request FIFO
  // ----------------------------
  typedef struct packed {
    symbol_id_t  symbol_id;
    logic [31:0] token_id;
    side_e       side;
    logic [31:0] price;
    logic [31:0] intended_total; 
  } cancel_req_t;

  localparam int CDEPTH = MAX_OUT;
  localparam int CPtrW  = $clog2(CDEPTH);

  cancel_req_t c_fifo [CDEPTH];
  logic [CPtrW:0] c_wr, c_rd;
  logic c_empty, c_full;

  assign c_empty = (c_wr == c_rd);
  assign c_full  =
      (c_wr[CPtrW] != c_rd[CPtrW]) &&
      (c_wr[CPtrW-1:0] == c_rd[CPtrW-1:0]);

  cancel_req_t c_head;
  assign c_head = c_fifo[c_rd[CPtrW-1:0]];

  assign rpt_ready = 1'b1;

  // ----------------------------
  // Issue FSM
  // ----------------------------
  typedef enum logic [1:0] {ISS_IDLE, ISS_REQTOK, ISS_WAITTOK, ISS_SENDENTER} iss_e;
  iss_e iss, iss_n;

  intent_t     pend_intent, pend_intent_n;
  logic        have_intent, have_intent_n;
  logic [31:0] pend_token,  pend_token_n;

  logic                      ord_valid_next;
  hft_types_pkg::order_intent_t ord_next;

  always_comb begin
    fifo_pop        = 1'b0;
    tok_req_valid   = 1'b0;
    tok_resp_ready  = 1'b0;

    ord_valid_next = 1'b0;
    ord_next       = '0;

    iss_n          = iss;
    pend_intent_n  = pend_intent;
    have_intent_n  = have_intent;
    pend_token_n   = pend_token;

    if (!ord_valid || ord_ready) begin
        if (!c_empty) begin
          ord_valid_next      = 1'b1;
          ord_next.symbol_id  = c_head.symbol_id;
          ord_next.strat_id   = strat_id;
          ord_next.action     = ACT_CANCEL;
          ord_next.side       = c_head.side;
          ord_next.price_int  = c_head.price;
          ord_next.qty        = c_head.intended_total;
          ord_next.token_id   = c_head.token_id;
        end else begin
          unique case (iss)
            ISS_IDLE: begin
              if (!have_intent && !fifo_empty && !out_full) begin
                fifo_pop        = 1'b1;
                pend_intent_n   = fifo_rdata;
                have_intent_n   = 1'b1;
                iss_n           = ISS_REQTOK;
              end
            end

            ISS_REQTOK: begin
              tok_req_valid = 1'b1;
              if (tok_req_ready) iss_n = ISS_WAITTOK;
            end

            ISS_WAITTOK: begin
              tok_resp_ready = 1'b1;
              if (tok_resp_valid) begin
                pend_token_n = tok_resp_id;
                iss_n        = ISS_SENDENTER;
              end
            end

            ISS_SENDENTER: begin
              ord_valid_next      = 1'b1;
              ord_next.symbol_id  = pend_intent.symbol_id;
              ord_next.strat_id   = strat_id;
              ord_next.action     = ACT_ENTER;
              ord_next.side       = pend_intent.side;
              ord_next.price_int  = pend_intent.price;
              ord_next.qty        = pend_intent.qty;
              ord_next.token_id   = pend_token;

              iss_n         = ISS_IDLE;
              have_intent_n = 1'b0;
            end

            default: iss_n = ISS_IDLE;
          endcase
        end
    end
  end

  // ----------------------------
  // Single-owner sequential block
  // ----------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    logic cancel_accept;
    logic enter_accept;
    logic can_enqueue_cancel;
    cancel_req_t cr;

    if (!rst_n) begin
      iss         <= ISS_IDLE;
      pend_intent <= '0;
      have_intent <= 1'b0;
      pend_token  <= 32'd0;

      ord_valid   <= 1'b0;
      ord         <= '0;

      for (int i = 0; i < MAX_OUT; i++) begin
        out_tab[i].valid       <= 1'b0;
        out_tab[i].symbol_id   <= '0;
        out_tab[i].token_id    <= '0;
        out_tab[i].side        <= SIDE_BUY; 
        out_tab[i].price       <= '0;
        out_tab[i].qty         <= '0;
        out_tab[i].filled_tot  <= '0;
        out_tab[i].cancel_sent <= 1'b0;
      end

      c_wr <= '0;
      c_rd <= '0;
      for (int j = 0; j < CDEPTH; j++) c_fifo[j] <= '0;

    end else begin
      iss         <= iss_n;
      pend_intent <= pend_intent_n;
      have_intent <= have_intent_n;
      pend_token  <= pend_token_n;

      if (!ord_valid || ord_ready) begin
          ord_valid <= ord_valid_next;
          ord       <= ord_next;
      end

      cancel_accept = (ord_valid && ord_ready && (ord.action == ACT_CANCEL));
      enter_accept  = (ord_valid && ord_ready && (ord.action == ACT_ENTER));

      if (cancel_accept) begin
        c_rd <= c_rd + 1'b1;
      end

      can_enqueue_cancel = (!c_full) || cancel_accept;

      if (enter_accept && has_free) begin
        out_tab[free_i].valid       <= 1'b1;
        out_tab[free_i].symbol_id   <= ord.symbol_id;
        out_tab[free_i].token_id    <= ord.token_id;
        out_tab[free_i].side        <= ord.side;
        out_tab[free_i].price       <= ord.price_int;
        out_tab[free_i].qty         <= ord.qty;
        out_tab[free_i].filled_tot  <= 32'd0;
        out_tab[free_i].cancel_sent <= 1'b0;
      end

      // Update Array Registers using the pipelined `is_complete_fill_p1`
      if (rpt_valid_p1) begin
        for (int i = 0; i < MAX_OUT; i++) begin
          if (token_match_p1[i]) begin
            out_tab[i].filled_tot <= rpt_p1.filled_total;

            unique case (rpt_p1.kind)
              RPT_EXEC: begin
                if (is_complete_fill_p1) begin
                  out_tab[i].valid <= 1'b0;
                end else if (!out_tab[i].cancel_sent) begin
                  out_tab[i].cancel_sent <= 1'b1;
                end
              end
              RPT_CANCELED: out_tab[i].valid <= 1'b0;
              RPT_REJECT:   out_tab[i].valid <= 1'b0;
              default: ;
            endcase
          end
        end
      end

      // Push to Cancel FIFO using the pipelined `is_partial_fill_p1`
      if (rpt_valid_p1 && has_match_p1 && (rpt_p1.kind == RPT_EXEC)) begin
        if (is_partial_fill_p1 && !match_data_p1.cancel_sent) begin
          if (can_enqueue_cancel) begin
            cr.symbol_id      = match_data_p1.symbol_id;
            cr.token_id       = match_data_p1.token_id;
            cr.side           = match_data_p1.side;
            cr.price          = match_data_p1.price;
            cr.intended_total = rpt_p1.filled_total;

            c_fifo[c_wr[CPtrW-1:0]] <= cr;
            c_wr <= c_wr + 1'b1;
          end
        end
      end

    end
  end

endmodule
