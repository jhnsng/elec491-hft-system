module order_fsm (
  input  logic clk,
  input  logic rst_n,

  // Decision input (from feature_pipe)
  input  logic                sig_valid,
  output logic                sig_ready,
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
  output logic                    ord_valid,
  input  logic                    ord_ready,
  output hft_types_pkg::order_intent_t ord,

  // Exchange/formatter reports
  input  logic                    rpt_valid,
  output logic                    rpt_ready,
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

  // SCALED TO 32 FOR HISTORICAL BURSTS
  localparam int MAX_OUT = 32;

  typedef struct packed {
    symbol_id_t  symbol_id;
    logic [31:0] token_id;
    side_e       side;
    logic [31:0] price;
    logic [31:0] qty;
    logic [31:0] filled_tot;
    logic        cancel_sent;
  } out_ent_t;

  logic [MAX_OUT-1:0] out_valid;
  out_ent_t out_tab [MAX_OUT];

  logic [4:0] free_i, free_i_next;
  logic       has_free, has_free_next;

  // DYNAMIC Priority Encoder using loop
  always_comb begin
    free_i_next = 5'd0;
    has_free_next = 1'b0;
    for (int i = 0; i < MAX_OUT; i++) begin
      if (!out_valid[i]) begin
        free_i_next = i[4:0];
        has_free_next = 1'b1;
        break; 
      end
    end
  end

  logic out_full;
  assign out_full = !has_free;

  // --- CANCEL TIMEOUT LOGIC ---
  localparam int CANCEL_TIMEOUT_CYCLES = 250_000_000; 
  logic [27:0] age_cnt [MAX_OUT];
  logic        timeout_fire;
  logic [4:0]  timeout_id;
  logic        is_timeout_cancel_reg;
  logic [4:0]  timeout_id_reg;

  // ==========================================
  // 1. AGE COUNTERS 
  // ==========================================
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      for (int i = 0; i < MAX_OUT; i++) begin
        age_cnt[i] <= '0;
      end
    end else begin
      for (int i = 0; i < MAX_OUT; i++) begin
        if (!out_valid[i]) begin
          age_cnt[i] <= '0; 
        end else if (age_cnt[i] != 28'hFFFFFFF) begin
          age_cnt[i] <= age_cnt[i] + 1'b1; 
        end
      end
    end
  end

  // ==========================================
  // 2. TIMEOUT TRIGGER 
  // ==========================================
  always_comb begin
    timeout_fire = 1'b0;
    timeout_id   = 5'd0;
    
    for (int i = 0; i < MAX_OUT; i++) begin
      if (out_valid[i] && !out_tab[i].cancel_sent && (age_cnt[i] >= CANCEL_TIMEOUT_CYCLES)) begin
        timeout_fire = 1'b1;
        timeout_id   = i[4:0]; 
        break;
      end
    end
  end

  // Input FIFO
  localparam int FIFO_DEPTH = MAX_OUT; 
  localparam int PTR_W      = $clog2(FIFO_DEPTH);

  intent_t i_mem [FIFO_DEPTH];
  logic [PTR_W:0] i_wr, i_rd;
  logic i_mem_empty, i_mem_full;

  assign i_mem_empty = (i_wr == i_rd);
  assign i_mem_full  = (i_wr[PTR_W] != i_rd[PTR_W]) && (i_wr[PTR_W-1:0] == i_rd[PTR_W-1:0]);

  intent_t i_head_reg;
  logic    i_head_valid;
  logic    i_pop;
  logic    i_read_mem_reg;

  assign sig_ready = !i_mem_full && !out_full;

  logic                     rpt_valid_s0;
  hft_types_pkg::order_rpt_t rpt_s0;

  (* preserve, dont_retime *) logic [MAX_OUT-1:0]        token_match_s1;
  logic                      rpt_valid_s1;
  hft_types_pkg::order_rpt_t rpt_s1;

  logic                      rpt_valid_s2;
  hft_types_pkg::order_rpt_t rpt_s2;
  logic                      has_match_s2;
  out_ent_t                  match_data_s2;
  logic [31:0]               matched_qty_s2;
  logic [MAX_OUT-1:0]        token_match_s2;

  logic                      rpt_valid_p1;
  hft_types_pkg::order_rpt_t rpt_p1;
  logic [MAX_OUT-1:0]        token_match_p1;
  logic                      has_match_p1;
  out_ent_t                  match_data_p1;
  logic                      is_partial_fill_p1;
  logic                      is_complete_fill_p1;

  typedef struct packed {
    symbol_id_t  symbol_id;
    logic [31:0] token_id;
    side_e       side;
    logic [31:0] price;
    logic [31:0] intended_total; 
  } cancel_req_t;

  localparam int CDEPTH = MAX_OUT;
  localparam int CPTR_W = $clog2(CDEPTH);

  cancel_req_t c_mem [CDEPTH];
  logic [CPTR_W:0] c_wr, c_rd;
  logic c_mem_empty, c_mem_full;

  assign c_mem_empty = (c_wr == c_rd);
  assign c_mem_full  = (c_wr[CPTR_W] != c_rd[CPTR_W]) && (c_wr[CPTR_W-1:0] == c_rd[CPTR_W-1:0]);

  cancel_req_t c_head_reg;
  logic        c_head_valid;
  logic        c_read_mem_reg;

  assign rpt_ready = 1'b1;

  typedef enum logic [1:0] {ISS_IDLE, ISS_REQTOK, ISS_WAITTOK, ISS_SENDENTER} iss_e;
  iss_e iss, iss_n;

  intent_t  pend_intent, pend_intent_n;
  logic     have_intent, have_intent_n;
  logic [31:0] pend_token; 
  
  logic tok_req_valid_reg;
  logic tok_resp_ready_reg;
  logic do_enqueue_cancel_reg;
  cancel_req_t cr_reg;

  // --- SHADOW REGISTER PIPELINE ---
  hft_types_pkg::order_intent_t shadow_reg;
  (* maxfan = 16 *) logic shadow_valid_reg;

  logic int_ready;
  logic want_cancel, want_enter;

  assign want_cancel = c_head_valid;
  assign want_enter  = !c_head_valid && (iss == ISS_SENDENTER);

  // Skid Buffer logic
  hft_types_pkg::order_intent_t skid_data;
  (* maxfan = 16 *) logic skid_valid;

  assign int_ready = !skid_valid;

  // --- INVENTORY RISK TRACKING ---
  logic signed [31:0] target_pos;
  logic               pos_limit_exceeded;

  always_comb begin
    pos_limit_exceeded = 1'b0;
    if (i_head_valid) begin
       if (i_head_reg.side == SIDE_BUY  && (target_pos >=  1000)) pos_limit_exceeded = 1'b1;
       if (i_head_reg.side == SIDE_SELL && (target_pos <= -1000)) pos_limit_exceeded = 1'b1;
    end

    i_pop         = 1'b0;
    iss_n         = iss; 
    pend_intent_n = pend_intent;
    have_intent_n = have_intent;

    if (iss == ISS_IDLE) begin
      if (!have_intent && i_head_valid) begin
        pend_intent_n = i_head_reg;
      end
      if (!have_intent && i_head_valid && !out_full) begin
        i_pop = 1'b1;
        if (pos_limit_exceeded) begin
            have_intent_n = 1'b0;
            iss_n         = ISS_IDLE;
        end else begin
            have_intent_n = 1'b1;
            iss_n         = ISS_REQTOK;
        end
      end
    end 
    else if (iss == ISS_REQTOK) begin
      if (tok_req_valid_reg && tok_req_ready) iss_n = ISS_WAITTOK;
    end 
    else if (iss == ISS_WAITTOK) begin
      if (tok_resp_ready_reg && tok_resp_valid) iss_n = ISS_SENDENTER;
    end 
    else if (iss == ISS_SENDENTER) begin
      if (want_enter && int_ready) begin 
        iss_n         = ISS_IDLE; 
        have_intent_n = 1'b0;
      end
    end
  end

  assign tok_req_valid  = tok_req_valid_reg;
  assign tok_resp_ready = tok_resp_ready_reg;

  // DYNAMIC Load Slots
  logic [MAX_OUT-1:0] load_slot;
  logic entering_sendenter;
  assign entering_sendenter = (iss == ISS_WAITTOK) && tok_resp_ready_reg && tok_resp_valid;

  // =========================================================================
  // BLOCK 1: CONTROL ONLY (Synchronous Reset)
  // =========================================================================
  always_ff @(posedge clk) begin 
    if (!rst_n) begin
      target_pos <= 32'd0;
      is_timeout_cancel_reg <= 1'b0;
      timeout_id_reg <= '0;
      for (int i=0; i<MAX_OUT; i++) age_cnt[i] <= '0;

      free_i <= 5'd0; has_free <= 1'b0;
      i_wr <= '0; i_rd <= '0;
      i_head_valid <= 1'b0; i_read_mem_reg <= 1'b0;
      rpt_valid_s0 <= 1'b0; rpt_valid_s1 <= 1'b0; rpt_valid_s2 <= 1'b0; rpt_valid_p1 <= 1'b0;
      token_match_s2 <= '0; token_match_p1 <= '0;
      has_match_s2 <= 1'b0; has_match_p1 <= 1'b0;
      is_partial_fill_p1 <= 1'b0; is_complete_fill_p1 <= 1'b0;
      c_wr <= '0; c_rd <= '0;
      c_head_valid <= 1'b0; c_read_mem_reg <= 1'b0;
      do_enqueue_cancel_reg <= 1'b0;
      iss <= ISS_IDLE;
      have_intent <= 1'b0;
      tok_req_valid_reg  <= 1'b0;
      tok_resp_ready_reg <= 1'b0;
      ord_valid <= 1'b0;
      skid_valid <= 1'b0;
      out_valid <= '0;
      load_slot <= '0;
      shadow_valid_reg <= 1'b0;
    end else begin
      free_i <= free_i_next;
      has_free <= has_free_next;

      if (sig_valid && sig_ready) i_wr <= i_wr + 1'b1;

      if (!i_mem_empty && !i_head_valid && !i_read_mem_reg) i_read_mem_reg <= 1'b1;
      else i_read_mem_reg <= 1'b0;

      if (i_read_mem_reg) begin
        i_rd <= i_rd + 1'b1;
        i_head_valid <= 1'b1;
      end else if (i_pop) begin
        i_head_valid <= 1'b0;
      end

      // DELAY PIPELINE
      rpt_valid_s0 <= rpt_valid;
      rpt_valid_s1 <= rpt_valid_s0;
      rpt_valid_s2 <= rpt_valid_s1;
      rpt_valid_p1 <= rpt_valid_s2;

      token_match_s2 <= token_match_s1; has_match_s2 <= |token_match_s1;
      token_match_p1 <= token_match_s2; has_match_p1 <= has_match_s2;

      is_partial_fill_p1  <= (rpt_s2.filled_total < matched_qty_s2);
      is_complete_fill_p1 <= (rpt_s2.filled_total >= matched_qty_s2);

      for (int i = 0; i < MAX_OUT; i++) begin
          if (!out_valid[i]) age_cnt[i] <= '0;
          else if (age_cnt[i] != 28'hFFFFFFF) age_cnt[i] <= age_cnt[i] + 1'b1; 
      end

      do_enqueue_cancel_reg <= 1'b0;
      is_timeout_cancel_reg <= 1'b0;
      if (timeout_fire && !c_mem_full) begin
        timeout_id_reg <= timeout_id;
      end

      if (rpt_valid_p1 && has_match_p1 && (rpt_p1.kind == RPT_EXEC)) begin
        if (is_partial_fill_p1 && !match_data_p1.cancel_sent && !c_mem_full) begin
          do_enqueue_cancel_reg <= 1'b1;
        end
      end else if (timeout_fire && !c_mem_full) begin
        do_enqueue_cancel_reg <= 1'b1;
        is_timeout_cancel_reg <= 1'b1;
      end

      if (do_enqueue_cancel_reg) c_wr <= c_wr + 1'b1;

      if (!c_mem_empty && !c_head_valid && !c_read_mem_reg) c_read_mem_reg <= 1'b1;
      else                                                  c_read_mem_reg <= 1'b0;

      if (c_read_mem_reg) begin
          c_rd <= c_rd + 1'b1;
          c_head_valid <= 1'b1;
      end else if (want_cancel && int_ready) begin
          c_head_valid <= 1'b0;
      end

      iss <= iss_n;
      have_intent <= have_intent_n;
      tok_req_valid_reg  <= (iss_n == ISS_REQTOK);
      tok_resp_ready_reg <= (iss_n == ISS_WAITTOK) || (iss_n == ISS_REQTOK);

      if (int_ready) begin
          shadow_valid_reg <= (want_cancel || want_enter);
      end else begin
          shadow_valid_reg <= 1'b0;
      end

      if (ord_ready || !ord_valid) begin
         ord_valid <= skid_valid | shadow_valid_reg;
         skid_valid <= 1'b0;
      end else if (shadow_valid_reg && !skid_valid) begin
         skid_valid <= 1'b1;
      end

      for (int i = 0; i < MAX_OUT; i++) begin
          load_slot[i] <= entering_sendenter && (free_i == i[4:0]);
      end

      if (want_enter && int_ready && has_free) begin
          out_valid[free_i] <= 1'b1;
      end

      // 1. ADD TO POSITION
      if (iss == ISS_IDLE && !have_intent && i_head_valid && !out_full && !pos_limit_exceeded) begin
         if (i_head_reg.side == SIDE_BUY) target_pos <= target_pos + $signed(i_head_reg.qty);
         else                             target_pos <= target_pos - $signed(i_head_reg.qty);
      end

      // 2. REVERT POSITION ON CANCELS / REJECTS
      if (rpt_valid_p1) begin
        for (int i = 0; i < MAX_OUT; i++) begin
          if (token_match_p1[i]) begin
            unique case (rpt_p1.kind)
              RPT_EXEC: begin
                if (is_complete_fill_p1) out_valid[i] <= 1'b0;
              end
              RPT_CANCELED, RPT_REJECT: begin
                out_valid[i] <= 1'b0;
                if (match_data_p1.side == SIDE_BUY) 
                  target_pos <= target_pos - $signed(match_data_p1.qty - rpt_p1.filled_total);
                else                                
                  target_pos <= target_pos + $signed(match_data_p1.qty - rpt_p1.filled_total);
              end
              default: ;
            endcase
          end
        end
      end
    end
  end

  // =========================================================================
  // BLOCK 2: DATAPATH ONLY (NO RESET)
  // =========================================================================
  (* preserve, dont_retime *) logic [31:0] safe_token_id [MAX_OUT];

  always_ff @(posedge clk) begin 
    if (sig_valid && sig_ready) begin
      i_mem[i_wr[PTR_W-1:0]].symbol_id <= symbol_id;
      i_mem[i_wr[PTR_W-1:0]].side      <= sig_side;
      i_mem[i_wr[PTR_W-1:0]].price     <= sig_price;
      i_mem[i_wr[PTR_W-1:0]].qty       <= sig_qty;
    end
    if (i_read_mem_reg) i_head_reg <= i_mem[i_rd[PTR_W-1:0]];

    rpt_s0 <= rpt; rpt_s1 <= rpt_s0; rpt_s2 <= rpt_s1; rpt_p1 <= rpt_s2;

    for (int i = 0; i < MAX_OUT; i++) begin
        token_match_s1[i] <= out_valid[i] && !load_slot[i] && (safe_token_id[i] == rpt_s0.token_id);
    end

    // DYNAMIC MATCH MUX
    match_data_s2 <= '0;
    matched_qty_s2 <= 32'd0;
    for (int i = 0; i < MAX_OUT; i++) begin
        if (token_match_s1[i]) begin
            match_data_s2 <= out_tab[i];
            matched_qty_s2 <= out_tab[i].qty;
        end
    end

    match_data_p1 <= match_data_s2;

    if (rpt_valid_p1 && has_match_p1 && (rpt_p1.kind == RPT_EXEC)) begin
      cr_reg.symbol_id      <= match_data_p1.symbol_id;
      cr_reg.token_id       <= match_data_p1.token_id;
      cr_reg.side           <= match_data_p1.side;
      cr_reg.price          <= match_data_p1.price;
      cr_reg.intended_total <= match_data_p1.qty;
    end else if (is_timeout_cancel_reg) begin
      cr_reg.symbol_id      <= out_tab[timeout_id_reg].symbol_id;
      cr_reg.token_id       <= out_tab[timeout_id_reg].token_id;
      cr_reg.side           <= out_tab[timeout_id_reg].side;
      cr_reg.price          <= out_tab[timeout_id_reg].price;
      cr_reg.intended_total <= out_tab[timeout_id_reg].qty; 
    end

    if (do_enqueue_cancel_reg) c_mem[c_wr[CPTR_W-1:0]] <= cr_reg;
    if (c_read_mem_reg) c_head_reg <= c_mem[c_rd[CPTR_W-1:0]];

    pend_intent <= pend_intent_n;
    if (tok_resp_valid) pend_token <= tok_resp_id;

    if (int_ready) begin
        if (want_cancel) begin
            shadow_reg.symbol_id  <= c_head_reg.symbol_id;
            shadow_reg.strat_id   <= strat_id;
            shadow_reg.action     <= ACT_CANCEL;
            shadow_reg.side       <= c_head_reg.side;
            shadow_reg.price_int  <= c_head_reg.price;
            shadow_reg.qty        <= c_head_reg.intended_total;
            shadow_reg.token_id   <= c_head_reg.token_id;
        end else begin
            shadow_reg.symbol_id  <= pend_intent.symbol_id;
            shadow_reg.strat_id   <= strat_id;
            shadow_reg.action     <= ACT_ENTER;
            shadow_reg.side       <= pend_intent.side;
            shadow_reg.price_int  <= pend_intent.price;
            shadow_reg.qty        <= pend_intent.qty;
            shadow_reg.token_id   <= pend_token;
        end
    end

    if (ord_ready || !ord_valid) begin
       if (skid_valid) ord <= skid_data;
       else            ord <= shadow_reg;
    end else if (shadow_valid_reg && !skid_valid) begin
       skid_data <= shadow_reg;
    end

    for (int i = 0; i < MAX_OUT; i++) begin
        if (load_slot[i]) begin 
            out_tab[i].symbol_id   <= pend_intent.symbol_id; 
            out_tab[i].token_id    <= pend_token; 
            safe_token_id[i]       <= pend_token; 
            out_tab[i].side        <= pend_intent.side; 
            out_tab[i].price       <= pend_intent.price; 
            out_tab[i].qty         <= pend_intent.qty; 
            out_tab[i].filled_tot  <= 32'd0; 
            out_tab[i].cancel_sent <= 1'b0; 
        end
    end

    if (rpt_valid_p1) begin
      for (int i = 0; i < MAX_OUT; i++) begin
        if (token_match_p1[i]) begin
          out_tab[i].filled_tot <= rpt_p1.filled_total;
          if (rpt_p1.kind == RPT_EXEC && !is_complete_fill_p1 && !out_tab[i].cancel_sent) begin
             out_tab[i].cancel_sent <= 1'b1;
          end
        end
      end
    end

    if (is_timeout_cancel_reg && do_enqueue_cancel_reg) begin
      out_tab[timeout_id_reg].cancel_sent <= 1'b1;
    end
  end

endmodule