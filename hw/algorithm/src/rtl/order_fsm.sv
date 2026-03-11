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
  // Free Slot Finder (Pipelined)
  // ----------------------------
  logic [1:0] free_i, free_i_next;
  logic       has_free, has_free_next;

  always_comb begin
    free_i_next = 2'd0;
    has_free_next = 1'b0;
    if      (!out_tab[0].valid) begin free_i_next = 2'd0; has_free_next = 1'b1; end
    else if (!out_tab[1].valid) begin free_i_next = 2'd1; has_free_next = 1'b1; end
    else if (!out_tab[2].valid) begin free_i_next = 2'd2; has_free_next = 1'b1; end
    else if (!out_tab[3].valid) begin free_i_next = 2'd3; has_free_next = 1'b1; end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      free_i <= 2'd0;
      has_free <= 1'b0;
    end else begin
      free_i <= free_i_next;
      has_free <= has_free_next;
    end
  end

  logic out_full;
  assign out_full = !has_free;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      sig_ready <= 1'b0;
    end else begin
      sig_ready <= !fifo_full && !out_full;
    end
  end

   // ----------------------------
  // Token Matcher & Pipelining
  // ----------------------------

  // --- STAGE 0: Incoming Report Buffer ---
  (* preserve *) logic                      rpt_valid_s0;
  (* preserve *) hft_types_pkg::order_rpt_t rpt_s0;

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
      has_match_s2   <= |token_match_s1;

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
  (* preserve *) logic                      rpt_valid_p1;
  (* preserve *) hft_types_pkg::order_rpt_t rpt_p1;
  (* preserve *) logic [MAX_OUT-1:0]        token_match_p1;
  (* preserve *) logic                      has_match_p1;
  (* preserve *) out_ent_t                  match_data_p1;
  (* preserve *) logic                      is_partial_fill_p1;
  (* preserve *) logic                      is_complete_fill_p1;

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

      is_partial_fill_p1  <= (rpt_s2.filled_total <  matched_qty_s2);
      is_complete_fill_p1 <= (rpt_s2.filled_total >= matched_qty_s2);
    end
  end

  // ----------------------------
  // Cancel request FWFT (First-Word Fall-Through) FIFO
  // ----------------------------
  typedef struct packed {
    symbol_id_t  symbol_id;
    logic [31:0] token_id;
    side_e       side;
    logic [31:0] price;
    logic [31:0] intended_total; 
  } cancel_req_t;

  localparam int CDEPTH = MAX_OUT;
  localparam int CPTR_W = $clog2(CDEPTH);

  // The internal circular buffer (Completely isolated from output pins!)
  cancel_req_t c_mem [CDEPTH];
  logic [CPTR_W:0] c_wr, c_rd;
  logic c_mem_empty, c_mem_full;

  assign c_mem_empty = (c_wr == c_rd);
  assign c_mem_full  = (c_wr[CPTR_W] != c_rd[CPTR_W]) && (c_wr[CPTR_W-1:0] == c_rd[CPTR_W-1:0]);

  // The dedicated Head Register (provides 0-delay access to the output mux)
  cancel_req_t c_head_reg;
  logic        c_head_valid;

  assign rpt_ready = 1'b1;

  // ----------------------------
  // Issue FSM
  // ----------------------------
  typedef enum logic [1:0] {ISS_IDLE, ISS_REQTOK, ISS_WAITTOK, ISS_SENDENTER} iss_e;
  (* preserve *) iss_e iss;
  iss_e iss_n;

  intent_t     pend_intent, pend_intent_n;
  logic        have_intent, have_intent_n;
  logic [31:0] pend_token,  pend_token_n;

  // Pipeline registers for ALL outputs
  logic                      ord_valid_reg;
  hft_types_pkg::order_intent_t ord_reg;
  logic                      tok_req_valid_reg;
  logic                      tok_resp_ready_reg;

  // *** PIPELINE REGISTERS FOR CANCEL ENQUEUE ***
  logic do_enqueue_cancel_reg;
  cancel_req_t cr_reg;

  always_comb begin
    fifo_pop        = 1'b0;

    iss_n           = iss;
    pend_intent_n   = pend_intent;
    have_intent_n   = have_intent;
    pend_token_n    = pend_token;

    if (iss == ISS_IDLE) begin
      if (!have_intent && !fifo_empty && !out_full) begin
        fifo_pop        = 1'b1;
        pend_intent_n   = fifo_rdata;
        have_intent_n   = 1'b1;
        iss_n           = ISS_REQTOK;
      end
    end else if (iss == ISS_REQTOK) begin
      if (tok_req_valid_reg && tok_req_ready) iss_n = ISS_WAITTOK;
    end else if (iss == ISS_WAITTOK) begin
      if (tok_resp_ready_reg && tok_resp_valid) begin
        pend_token_n = tok_resp_id;
        iss_n        = ISS_SENDENTER;
      end
    end else if (iss == ISS_SENDENTER) begin
      if (!ord_valid_reg || ord_ready) begin
        iss_n         = ISS_IDLE; 
        have_intent_n = 1'b0;
      end
    end
  end

  assign ord_valid      = ord_valid_reg;
  assign ord            = ord_reg;
  assign tok_req_valid  = tok_req_valid_reg;
  assign tok_resp_ready = tok_resp_ready_reg;

  // ----------------------------
  // Single-owner sequential block
  // ----------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    logic cancel_accept;
    logic enter_accept;
    logic read_mem;

    if (!rst_n) begin
      iss         <= ISS_IDLE;
      pend_intent <= '0;
      have_intent <= 1'b0;
      pend_token  <= 32'd0;

      ord_valid_reg      <= 1'b0;
      ord_reg            <= '0;
      tok_req_valid_reg  <= 1'b0;
      tok_resp_ready_reg <= 1'b0;

      do_enqueue_cancel_reg <= 1'b0;
      cr_reg <= '0;

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
      c_head_valid <= 1'b0;
      c_head_reg <= '0;
      for (int j = 0; j < CDEPTH; j++) c_mem[j] <= '0;

    end else begin
      iss         <= iss_n;
      pend_intent <= pend_intent_n;
      have_intent <= have_intent_n;
      pend_token  <= pend_token_n;

      tok_req_valid_reg  <= (iss_n == ISS_REQTOK);
      tok_resp_ready_reg <= (iss_n == ISS_WAITTOK) || (iss_n == ISS_REQTOK);

      // --- 1. Evaluate Enqueue Decision ---
      do_enqueue_cancel_reg <= 1'b0;
      if (rpt_valid_p1 && has_match_p1 && (rpt_p1.kind == RPT_EXEC)) begin
        if (is_partial_fill_p1 && !match_data_p1.cancel_sent && !c_mem_full) begin
          do_enqueue_cancel_reg <= 1'b1;
          cr_reg.symbol_id      <= match_data_p1.symbol_id;
          cr_reg.token_id       <= match_data_p1.token_id;
          cr_reg.side           <= match_data_p1.side;
          cr_reg.price          <= match_data_p1.price;
          cr_reg.intended_total <= rpt_p1.filled_total;
        end
      end

      // --- 2. Write to FWFT Memory (Isolated from output routing) ---
      if (do_enqueue_cancel_reg) begin
          c_mem[c_wr[CPTR_W-1:0]] <= cr_reg;
          c_wr <= c_wr + 1'b1;
      end

      // --- 3. Output Muxing (Reads directly from c_head_reg) ---
      if (!ord_valid_reg || ord_ready) begin
          if (c_head_valid) begin
            ord_valid_reg       <= 1'b1;
            ord_reg.symbol_id   <= c_head_reg.symbol_id;
            ord_reg.strat_id    <= strat_id;
            ord_reg.action      <= ACT_CANCEL;
            ord_reg.side        <= c_head_reg.side;
            ord_reg.price_int   <= c_head_reg.price;
            ord_reg.qty         <= c_head_reg.intended_total;
            ord_reg.token_id    <= c_head_reg.token_id;
          end else if (iss == ISS_SENDENTER) begin
            ord_valid_reg       <= 1'b1;
            ord_reg.symbol_id   <= pend_intent.symbol_id;
            ord_reg.strat_id    <= strat_id;
            ord_reg.action      <= ACT_ENTER;
            ord_reg.side        <= pend_intent.side;
            ord_reg.price_int   <= pend_intent.price;
            ord_reg.qty         <= pend_intent.qty;
            ord_reg.token_id    <= pend_token;
          end else begin
            ord_valid_reg <= 1'b0;
          end
      end

      // --- 4. Update the FWFT Head Register ---
      cancel_accept = c_head_valid && (!ord_valid_reg || ord_ready);
      enter_accept  = !c_head_valid && (!ord_valid_reg || ord_ready) && (iss == ISS_SENDENTER);

      read_mem = !c_mem_empty && (!c_head_valid || cancel_accept);

      if (read_mem) begin
          c_rd <= c_rd + 1'b1;
          c_head_valid <= 1'b1;
          c_head_reg <= c_mem[c_rd[CPTR_W-1:0]];
      end else if (cancel_accept) begin
          c_head_valid <= 1'b0;
      end

      // --- Output table update ---
      if ((iss == ISS_SENDENTER) && has_free) begin
        out_tab[free_i].symbol_id   <= pend_intent.symbol_id;
        out_tab[free_i].token_id    <= pend_token;
        out_tab[free_i].side        <= pend_intent.side;
        out_tab[free_i].price       <= pend_intent.price;
        out_tab[free_i].qty         <= pend_intent.qty;
        out_tab[free_i].filled_tot  <= 32'd0;
        out_tab[free_i].cancel_sent <= 1'b0;

        if (enter_accept) begin
            out_tab[free_i].valid   <= 1'b1;
        end
      end

      // --- Process reports to update outstanding orders ---
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

    end
  end

endmodule
