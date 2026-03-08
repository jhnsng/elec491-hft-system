module order_fsm (
  input  logic clk,
  input  logic rst_n,

  // Decision input (from feature_pipe)
  input  logic                  sig_valid,
  output logic                  sig_ready,
  input  hft_types_pkg::side_e  sig_side,
  input  logic [31:0]           sig_price,
  input  logic [31:0]           sig_qty,

  // Token allocator
  output logic tok_req_valid,
  input  logic tok_req_ready,

  input  logic tok_resp_valid,
  output logic tok_resp_ready,
  input  logic [31:0] tok_resp_id,

  // Order intent output
  output logic                      ord_valid,
  input  logic                      ord_ready,
  output hft_types_pkg::order_intent_t ord,

  // Exchange/formatter reports
  input  logic                      rpt_valid,
  output logic                      rpt_ready,
  input  hft_types_pkg::order_rpt_t  rpt,

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
  // Intent FIFO (buffers signals)
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

  /*always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      wr_ptr <= '0;
    end else if (sig_valid && sig_ready) begin
      fifo_mem[wr_ptr[PTR_W-1:0]] <= intent_t'{
        symbol_id,
        sig_side,
        sig_price,
        sig_qty
      };
      wr_ptr <= wr_ptr + 1'b1;
    end
  end*/

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

  function automatic int find_token(input logic [31:0] tok);
    int i;
    begin
      find_token = -1;
      for (i = 0; i < MAX_OUT; i++) begin
        if (out_tab[i].valid && (out_tab[i].token_id == tok)) find_token = i;
      end
    end
  endfunction

  function automatic int find_free();
    int i;
    begin
      find_free = -1;
      for (i = 0; i < MAX_OUT; i++) begin
        if (!out_tab[i].valid) find_free = i;
      end
    end
  endfunction

  logic out_full;
  //assign out_full  = (find_free() == -1);
    // NEW: Robust logic to determine if table is full

  always_comb begin
    out_full = 1'b1; // Assume full by default
    
    // Check if any slot is invalid (free)
    for (int i = 0; i < MAX_OUT; i++) begin
      if (!out_tab[i].valid) begin
        out_full = 1'b0; // Found a free slot!
      end
    end
  end

  assign sig_ready = !fifo_full && !out_full;

  // ----------------------------
  // Cancel request FIFO
  // ----------------------------
  typedef struct packed {
    symbol_id_t  symbol_id;
    logic [31:0] token_id;
    side_e       side;
    logic [31:0] price;
    logic [31:0] intended_total; // for your design: equals rpt.filled_total
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

  // ----------------------------
  // Reports: always drain
  // ----------------------------
  assign rpt_ready = 1'b1;

  // ----------------------------
  // Issue FSM (ENTER path only; cancels are priority)
  // ----------------------------
  typedef enum logic [1:0] {ISS_IDLE, ISS_REQTOK, ISS_WAITTOK, ISS_SENDENTER} iss_e;
  iss_e iss, iss_n;

  intent_t     pend_intent, pend_intent_n;
  logic        have_intent, have_intent_n;
  logic [31:0] pend_token,  pend_token_n;

  // ----------------------------
  // Output / control combinational
  // ----------------------------
  always_comb begin
    fifo_pop        = 1'b0;
    tok_req_valid   = 1'b0;
    tok_resp_ready  = 1'b0;

    ord_valid = 1'b0;
    ord       = '0;

    iss_n          = iss;
    pend_intent_n  = pend_intent;
    have_intent_n  = have_intent;
    pend_token_n   = pend_token;

    // Priority 1: send CANCEL if queued
    if (!c_empty) begin
      ord_valid      = 1'b1;
      ord.symbol_id  = c_head.symbol_id;
      ord.strat_id   = strat_id;
      ord.action     = ACT_CANCEL;
      ord.side       = c_head.side;
      ord.price_int  = c_head.price;
      ord.qty        = c_head.intended_total;
      ord.token_id   = c_head.token_id;
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
          ord_valid      = 1'b1;
          ord.symbol_id  = pend_intent.symbol_id;
          ord.strat_id   = strat_id;
          ord.action     = ACT_ENTER;
          ord.side       = pend_intent.side;
          ord.price_int  = pend_intent.price;
          ord.qty        = pend_intent.qty;
          ord.token_id   = pend_token;

          if (ord_ready) begin
            iss_n         = ISS_IDLE;
            have_intent_n = 1'b0;
          end
        end

        default: iss_n = ISS_IDLE;
      endcase
    end
  end

  // ----------------------------
  // Single-owner sequential block
  // ----------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    int idx;
    int free_i;

    logic cancel_accept;
    logic enter_accept;
    logic can_enqueue_cancel;

    logic same_cycle_enter_rpt;

    // “Effective” fields (use ord.* if report is same-cycle with ENTER accept)
    symbol_id_t eff_sym;
    logic [31:0] eff_tok;
    side_e       eff_side;
    logic [31:0] eff_price;
    logic [31:0] eff_qty;

    cancel_req_t cr;

    if (!rst_n) begin
      iss         <= ISS_IDLE;
      pend_intent <= '0;
      have_intent <= 1'b0;
      pend_token  <= 32'd0;

      //for (int i = 0; i < MAX_OUT; i++) out_tab[i] <= '0;
      /*for (int i = 0; i < MAX_OUT; i++) begin
        out_tab[i].valid <= 1'b0; // Explicitly clear valid bit
        out_tab[i].token_id <= '0;*/
      for (int i = 0; i < MAX_OUT; i++) begin
        out_tab[i].valid       <= 1'b0;
        out_tab[i].symbol_id   <= '0;
        out_tab[i].token_id    <= '0;
        out_tab[i].side        <= SIDE_BUY; // Init enum to known value
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

      cancel_accept = (ord_valid && ord_ready && (ord.action == ACT_CANCEL));
      enter_accept  = (ord_valid && ord_ready && (ord.action == ACT_ENTER));

      // Pop cancel FIFO on accept
      if (cancel_accept) begin
        c_rd <= c_rd + 1'b1;
      end

      // Allow enqueue if not full OR if we are popping this cycle
      can_enqueue_cancel = (!c_full) || cancel_accept;

      // Allocate outstanding entry on ENTER accept
      free_i = -1;
      if (enter_accept) begin
        free_i = find_free();
        if (free_i != -1) begin
          out_tab[free_i].valid       <= 1'b1;
          out_tab[free_i].symbol_id   <= ord.symbol_id;
          out_tab[free_i].token_id    <= ord.token_id;
          out_tab[free_i].side        <= ord.side;
          out_tab[free_i].price       <= ord.price_int;
          out_tab[free_i].qty         <= ord.qty;
          out_tab[free_i].filled_tot  <= 32'd0;
          out_tab[free_i].cancel_sent <= 1'b0;
        end
      end

      // Consume reports
      if (rpt_valid) begin
        idx = find_token(rpt.token_id);

        // If report is same-cycle as ENTER accept, map it to the just-allocated entry
        if ((idx == -1) && enter_accept && (rpt.token_id == ord.token_id)) begin
          idx = free_i;
        end

        // Determine whether this is that special same-cycle case
        same_cycle_enter_rpt = (enter_accept &&
                                (free_i != -1) &&
                                (idx == free_i) &&
                                (rpt.token_id == ord.token_id));

        if (idx != -1) begin
          // Select effective fields
          eff_sym   = same_cycle_enter_rpt ? ord.symbol_id  : out_tab[idx].symbol_id;
          eff_tok   = same_cycle_enter_rpt ? ord.token_id   : out_tab[idx].token_id;
          eff_side  = same_cycle_enter_rpt ? ord.side       : out_tab[idx].side;
          eff_price = same_cycle_enter_rpt ? ord.price_int  : out_tab[idx].price;
          eff_qty   = same_cycle_enter_rpt ? ord.qty        : out_tab[idx].qty;

          // Update filled total bookkeeping
          out_tab[idx].filled_tot <= rpt.filled_total;

          unique case (rpt.kind)
            RPT_EXEC: begin
              if (rpt.filled_total >= eff_qty) begin
                out_tab[idx].valid <= 1'b0;
              end else if (!out_tab[idx].cancel_sent) begin
                out_tab[idx].cancel_sent <= 1'b1;

                if (can_enqueue_cancel) begin
                  cr.symbol_id      = eff_sym;
                  cr.token_id       = eff_tok;
                  cr.side           = eff_side;
                  cr.price          = eff_price;
                  cr.intended_total = rpt.filled_total;

                  c_fifo[c_wr[CPtrW-1:0]] <= cr;
                  c_wr <= c_wr + 1'b1;
                end
              end
            end

            RPT_CANCELED: out_tab[idx].valid <= 1'b0;
            RPT_REJECT:   out_tab[idx].valid <= 1'b0;
            default: ;
          endcase
        end
      end
    end
  end

endmodule
