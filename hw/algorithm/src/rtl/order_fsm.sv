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

  // INCREASED FOR HISTORICAL DATA BURSTS
  localparam int MAX_OUT = 16;

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

  logic [3:0] free_i, free_i_next;
  logic       has_free, has_free_next;

  // UNROLLED: 16-way Priority Encoder
  always_comb begin
    free_i_next = 4'd0;
    has_free_next = 1'b0;
    if      (!out_valid[0])  begin free_i_next = 4'd0;  has_free_next = 1'b1; end
    else if (!out_valid[1])  begin free_i_next = 4'd1;  has_free_next = 1'b1; end
    else if (!out_valid[2])  begin free_i_next = 4'd2;  has_free_next = 1'b1; end
    else if (!out_valid[3])  begin free_i_next = 4'd3;  has_free_next = 1'b1; end
    else if (!out_valid[4])  begin free_i_next = 4'd4;  has_free_next = 1'b1; end
    else if (!out_valid[5])  begin free_i_next = 4'd5;  has_free_next = 1'b1; end
    else if (!out_valid[6])  begin free_i_next = 4'd6;  has_free_next = 1'b1; end
    else if (!out_valid[7])  begin free_i_next = 4'd7;  has_free_next = 1'b1; end
    else if (!out_valid[8])  begin free_i_next = 4'd8;  has_free_next = 1'b1; end
    else if (!out_valid[9])  begin free_i_next = 4'd9;  has_free_next = 1'b1; end
    else if (!out_valid[10]) begin free_i_next = 4'd10; has_free_next = 1'b1; end
    else if (!out_valid[11]) begin free_i_next = 4'd11; has_free_next = 1'b1; end
    else if (!out_valid[12]) begin free_i_next = 4'd12; has_free_next = 1'b1; end
    else if (!out_valid[13]) begin free_i_next = 4'd13; has_free_next = 1'b1; end
    else if (!out_valid[14]) begin free_i_next = 4'd14; has_free_next = 1'b1; end
    else if (!out_valid[15]) begin free_i_next = 4'd15; has_free_next = 1'b1; end
  end

  logic out_full;
  assign out_full = !has_free;


  // --- NEW: CANCEL TIMEOUT LOGIC ---
  //localparam int CANCEL_TIMEOUT_CYCLES = 250_000; // 1 ms at 250MHz (tune to your liking)
  localparam int CANCEL_TIMEOUT_CYCLES = 250_000_000; 
  //logic [17:0] age_cnt [MAX_OUT];
  // Increased from [17:0] to [27:0] to hold numbers up to 268 million
  logic [27:0] age_cnt [MAX_OUT];
  logic        timeout_fire;
  logic [3:0]  timeout_id;
  logic        is_timeout_cancel_reg;
  logic [3:0]  timeout_id_reg;

  // ==========================================
  // 2. TIMEOUT TRIGGER (Combinational is fine here)
  // ==========================================
  always_comb begin
    timeout_fire = 1'b0;
    timeout_id   = 4'd0;
    
    // Check all slots to see if any reached the timeout
    for (int i = 0; i < MAX_OUT; i++) begin
      // FIX: Only trigger if we haven't already sent a cancel for this slot!
      if (out_valid[i] && !out_tab[i].cancel_sent && (age_cnt[i] >= CANCEL_TIMEOUT_CYCLES)) begin
        timeout_fire = 1'b1;
        timeout_id   = i[3:0]; 
        break; // Stop looking. We handle one cancel at a time!
      end
    end
  end

  // Input FIFO
  localparam int FIFO_DEPTH = 16; // Increased to match MAX_OUT scale
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

  // Added compiler directives to completely disable Quartus Register Retiming on these nodes
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

  intent_t     pend_intent, pend_intent_n;
  logic        have_intent, have_intent_n;
  logic [31:0] pend_token; 
  
  logic tok_req_valid_reg;
  logic tok_resp_ready_reg;
  logic do_enqueue_cancel_reg;
  cancel_req_t cr_reg;

  // --- SHADOW REGISTER PIPELINE (OPTIMIZED FOR 250MHz) ---
  hft_types_pkg::order_intent_t shadow_reg;
  (* maxfan = 16 *) logic shadow_valid_reg;

  logic int_ready;
  logic want_cancel, want_enter;

  assign want_cancel = c_head_valid;
  assign want_enter  = !c_head_valid && (iss == ISS_SENDENTER);

  // The Skid Buffer logic
  hft_types_pkg::order_intent_t skid_data;
  (* maxfan = 16 *) logic skid_valid;

  assign int_ready = !skid_valid;

  // --- NEW: INVENTORY RISK TRACKING ---
  //logic signed [31:0] target_pos;
  //logic               pos_limit_exceeded;

  always_comb begin
    // Check if fulfilling this order would exceed our +/- 100 share limit
    //pos_limit_exceeded = 1'b0;
    //if (i_head_valid) begin
    //   if (i_head_reg.side == SIDE_BUY  && (target_pos >=  1000)) pos_limit_exceeded = 1'b1;
    //   if (i_head_reg.side == SIDE_SELL && (target_pos <= -1000)) pos_limit_exceeded = 1'b1;
    //end

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
        have_intent_n = 1'b1;
        iss_n         = ISS_REQTOK;
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

  // UNROLLED: 16-way Load Slots
  logic load_slot_0, load_slot_1, load_slot_2, load_slot_3;
  logic load_slot_4, load_slot_5, load_slot_6, load_slot_7;
  logic load_slot_8, load_slot_9, load_slot_10, load_slot_11;
  logic load_slot_12, load_slot_13, load_slot_14, load_slot_15;

  logic entering_sendenter;
  assign entering_sendenter = (iss == ISS_WAITTOK) && tok_resp_ready_reg && tok_resp_valid;

  // =========================================================================
  // BLOCK 1: CONTROL ONLY (Synchronous Reset)
  // =========================================================================
  always_ff @(posedge clk) begin 
    if (!rst_n) begin
      //target_pos <= 32'd0;
      is_timeout_cancel_reg <= 1'b0;
      timeout_id_reg <= '0;
      for (int i=0; i<MAX_OUT; i++) age_cnt[i] <= '0;

      free_i <= 4'd0; has_free <= 1'b0;
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
      load_slot_0 <= 1'b0; load_slot_1 <= 1'b0; load_slot_2 <= 1'b0; load_slot_3 <= 1'b0;
      load_slot_4 <= 1'b0; load_slot_5 <= 1'b0; load_slot_6 <= 1'b0; load_slot_7 <= 1'b0;
      load_slot_8 <= 1'b0; load_slot_9 <= 1'b0; load_slot_10 <= 1'b0; load_slot_11 <= 1'b0;
      load_slot_12 <= 1'b0; load_slot_13 <= 1'b0; load_slot_14 <= 1'b0; load_slot_15 <= 1'b0;
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

      // DELAY PIPELINE: Giving out_tab 1 full cycle to settle!
      rpt_valid_s0 <= rpt_valid;
      rpt_valid_s1 <= rpt_valid_s0;
      rpt_valid_s2 <= rpt_valid_s1;
      rpt_valid_p1 <= rpt_valid_s2;

      token_match_s2 <= token_match_s1; has_match_s2 <= |token_match_s1;
      token_match_p1 <= token_match_s2; has_match_p1 <= has_match_s2;

      //is_partial_fill_p1  <= (rpt_s2.filled_total < matched_qty_s2);
      //is_complete_fill_p1 <= (rpt_s2.filled_total >= matched_qty_s2);

      /*do_enqueue_cancel_reg <= 1'b0;
      if (rpt_valid_p1 && has_match_p1 && (rpt_p1.kind == RPT_EXEC)) begin
        if (is_partial_fill_p1 && !match_data_p1.cancel_sent && !c_mem_full) begin
          do_enqueue_cancel_reg <= 1'b1;
        end
      end*/

      ///////

      // NEW: Increment age of active orders
      for (int i = 0; i < MAX_OUT; i++) begin
          if (!out_valid[i]) age_cnt[i] <= '0;
          else if (age_cnt[i] != 28'hFFFFFFF) age_cnt[i] <= age_cnt[i] + 1'b1; // FIXED
      end

      do_enqueue_cancel_reg <= 1'b0;
      is_timeout_cancel_reg <= 1'b0;
      if (timeout_fire && !c_mem_full) begin
        timeout_id_reg <= timeout_id;
      end

      if (rpt_valid_p1 && has_match_p1 && (rpt_p1.kind == RPT_EXEC)) begin
        // FIX: Use aligned p1 data directly!
        if ((rpt_p1.filled_total < match_data_p1.qty) && !match_data_p1.cancel_sent && !c_mem_full) begin
          do_enqueue_cancel_reg <= 1'b1;
        end
      end else if (timeout_fire && !c_mem_full) begin
        // NEW: Trigger cancel from the timeout!
        do_enqueue_cancel_reg <= 1'b1;
        is_timeout_cancel_reg <= 1'b1;
      end

      ///////

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

      load_slot_0  <= entering_sendenter && (free_i == 4'd0);
      load_slot_1  <= entering_sendenter && (free_i == 4'd1);
      load_slot_2  <= entering_sendenter && (free_i == 4'd2);
      load_slot_3  <= entering_sendenter && (free_i == 4'd3);
      load_slot_4  <= entering_sendenter && (free_i == 4'd4);
      load_slot_5  <= entering_sendenter && (free_i == 4'd5);
      load_slot_6  <= entering_sendenter && (free_i == 4'd6);
      load_slot_7  <= entering_sendenter && (free_i == 4'd7);
      load_slot_8  <= entering_sendenter && (free_i == 4'd8);
      load_slot_9  <= entering_sendenter && (free_i == 4'd9);
      load_slot_10 <= entering_sendenter && (free_i == 4'd10);
      load_slot_11 <= entering_sendenter && (free_i == 4'd11);
      load_slot_12 <= entering_sendenter && (free_i == 4'd12);
      load_slot_13 <= entering_sendenter && (free_i == 4'd13);
      load_slot_14 <= entering_sendenter && (free_i == 4'd14);
      load_slot_15 <= entering_sendenter && (free_i == 4'd15);

      if (want_enter && int_ready && has_free) begin
          if (free_i == 4'd0)  out_valid[0]  <= 1'b1;
          if (free_i == 4'd1)  out_valid[1]  <= 1'b1;
          if (free_i == 4'd2)  out_valid[2]  <= 1'b1;
          if (free_i == 4'd3)  out_valid[3]  <= 1'b1;
          if (free_i == 4'd4)  out_valid[4]  <= 1'b1;
          if (free_i == 4'd5)  out_valid[5]  <= 1'b1;
          if (free_i == 4'd6)  out_valid[6]  <= 1'b1;
          if (free_i == 4'd7)  out_valid[7]  <= 1'b1;
          if (free_i == 4'd8)  out_valid[8]  <= 1'b1;
          if (free_i == 4'd9)  out_valid[9]  <= 1'b1;
          if (free_i == 4'd10) out_valid[10] <= 1'b1;
          if (free_i == 4'd11) out_valid[11] <= 1'b1;
          if (free_i == 4'd12) out_valid[12] <= 1'b1;
          if (free_i == 4'd13) out_valid[13] <= 1'b1;
          if (free_i == 4'd14) out_valid[14] <= 1'b1;
          if (free_i == 4'd15) out_valid[15] <= 1'b1;
      end


      // 2. CLEAR SLOTS ON CANCELS / REJECTS / FULL EXECUTION
      if (rpt_valid_p1) begin
        for (int i = 0; i < MAX_OUT; i++) begin
          if (token_match_p1[i]) begin
            unique case (rpt_p1.kind)
              RPT_EXEC: begin
                // FIX: Use the perfectly aligned p1 data!
                if (rpt_p1.filled_total >= match_data_p1.qty) out_valid[i] <= 1'b0;
              end
              RPT_CANCELED, RPT_REJECT: begin
                out_valid[i] <= 1'b0; // Just free the slot!
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
  // PIPELINED OUT_TAB REGISTERS
  // Added compiler directives to completely disable Quartus Register Retiming on these nodes
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

    // ISOLATED COMPARATOR: Safe token ID is guaranteed stable. 
    // We explicitly mask out the comparison during load_slot to break the 7.9ns pend_token routing loop!
    token_match_s1[0]  <= out_valid[0]  && !load_slot_0  && (safe_token_id[0]  == rpt_s0.token_id);
    token_match_s1[1]  <= out_valid[1]  && !load_slot_1  && (safe_token_id[1]  == rpt_s0.token_id);
    token_match_s1[2]  <= out_valid[2]  && !load_slot_2  && (safe_token_id[2]  == rpt_s0.token_id);
    token_match_s1[3]  <= out_valid[3]  && !load_slot_3  && (safe_token_id[3]  == rpt_s0.token_id);
    token_match_s1[4]  <= out_valid[4]  && !load_slot_4  && (safe_token_id[4]  == rpt_s0.token_id);
    token_match_s1[5]  <= out_valid[5]  && !load_slot_5  && (safe_token_id[5]  == rpt_s0.token_id);
    token_match_s1[6]  <= out_valid[6]  && !load_slot_6  && (safe_token_id[6]  == rpt_s0.token_id);
    token_match_s1[7]  <= out_valid[7]  && !load_slot_7  && (safe_token_id[7]  == rpt_s0.token_id);
    token_match_s1[8]  <= out_valid[8]  && !load_slot_8  && (safe_token_id[8]  == rpt_s0.token_id);
    token_match_s1[9]  <= out_valid[9]  && !load_slot_9  && (safe_token_id[9]  == rpt_s0.token_id);
    token_match_s1[10] <= out_valid[10] && !load_slot_10 && (safe_token_id[10] == rpt_s0.token_id);
    token_match_s1[11] <= out_valid[11] && !load_slot_11 && (safe_token_id[11] == rpt_s0.token_id);
    token_match_s1[12] <= out_valid[12] && !load_slot_12 && (safe_token_id[12] == rpt_s0.token_id);
    token_match_s1[13] <= out_valid[13] && !load_slot_13 && (safe_token_id[13] == rpt_s0.token_id);
    token_match_s1[14] <= out_valid[14] && !load_slot_14 && (safe_token_id[14] == rpt_s0.token_id);
    token_match_s1[15] <= out_valid[15] && !load_slot_15 && (safe_token_id[15] == rpt_s0.token_id);

    // FLAT PARALLEL ONE-HOT MUX: Destroys the 16-level priority routing delay!
    unique case (1'b1)
      token_match_s1[0]:  begin match_data_s2 <= out_tab[0];  matched_qty_s2 <= out_tab[0].qty;  end 
      token_match_s1[1]:  begin match_data_s2 <= out_tab[1];  matched_qty_s2 <= out_tab[1].qty;  end 
      token_match_s1[2]:  begin match_data_s2 <= out_tab[2];  matched_qty_s2 <= out_tab[2].qty;  end 
      token_match_s1[3]:  begin match_data_s2 <= out_tab[3];  matched_qty_s2 <= out_tab[3].qty;  end 
      token_match_s1[4]:  begin match_data_s2 <= out_tab[4];  matched_qty_s2 <= out_tab[4].qty;  end 
      token_match_s1[5]:  begin match_data_s2 <= out_tab[5];  matched_qty_s2 <= out_tab[5].qty;  end 
      token_match_s1[6]:  begin match_data_s2 <= out_tab[6];  matched_qty_s2 <= out_tab[6].qty;  end 
      token_match_s1[7]:  begin match_data_s2 <= out_tab[7];  matched_qty_s2 <= out_tab[7].qty;  end 
      token_match_s1[8]:  begin match_data_s2 <= out_tab[8];  matched_qty_s2 <= out_tab[8].qty;  end 
      token_match_s1[9]:  begin match_data_s2 <= out_tab[9];  matched_qty_s2 <= out_tab[9].qty;  end 
      token_match_s1[10]: begin match_data_s2 <= out_tab[10]; matched_qty_s2 <= out_tab[10].qty; end 
      token_match_s1[11]: begin match_data_s2 <= out_tab[11]; matched_qty_s2 <= out_tab[11].qty; end 
      token_match_s1[12]: begin match_data_s2 <= out_tab[12]; matched_qty_s2 <= out_tab[12].qty; end 
      token_match_s1[13]: begin match_data_s2 <= out_tab[13]; matched_qty_s2 <= out_tab[13].qty; end 
      token_match_s1[14]: begin match_data_s2 <= out_tab[14]; matched_qty_s2 <= out_tab[14].qty; end 
      token_match_s1[15]: begin match_data_s2 <= out_tab[15]; matched_qty_s2 <= out_tab[15].qty; end 
      default:            begin match_data_s2 <= '0;          matched_qty_s2 <= 32'd0;           end
    endcase

    match_data_p1 <= match_data_s2;

    /*if (rpt_valid_p1 && has_match_p1 && (rpt_p1.kind == RPT_EXEC)) begin
      cr_reg.symbol_id      <= match_data_p1.symbol_id;
      cr_reg.token_id       <= match_data_p1.token_id;
      cr_reg.side           <= match_data_p1.side;
      cr_reg.price          <= match_data_p1.price;
      cr_reg.intended_total <= rpt_p1.filled_total;
    end*/

    if (rpt_valid_p1 && has_match_p1 && (rpt_p1.kind == RPT_EXEC)) begin
      cr_reg.symbol_id      <= match_data_p1.symbol_id;
      cr_reg.token_id       <= match_data_p1.token_id;
      cr_reg.side           <= match_data_p1.side;
      cr_reg.price          <= match_data_p1.price;
      cr_reg.intended_total <= match_data_p1.qty; 
    end else if (timeout_fire && !c_mem_full) begin  // FIX: Use immediate comb trigger
      cr_reg.symbol_id      <= out_tab[timeout_id].symbol_id;
      cr_reg.token_id       <= out_tab[timeout_id].token_id;
      cr_reg.side           <= out_tab[timeout_id].side;
      cr_reg.price          <= out_tab[timeout_id].price;
      cr_reg.intended_total <= out_tab[timeout_id].qty; 
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

    if (load_slot_0)  begin out_tab[0].symbol_id  <= pend_intent.symbol_id; out_tab[0].token_id  <= pend_token; safe_token_id[0]  <= pend_token; out_tab[0].side  <= pend_intent.side; out_tab[0].price  <= pend_intent.price; out_tab[0].qty  <= pend_intent.qty; out_tab[0].filled_tot  <= 32'd0; out_tab[0].cancel_sent  <= 1'b0; end
    if (load_slot_1)  begin out_tab[1].symbol_id  <= pend_intent.symbol_id; out_tab[1].token_id  <= pend_token; safe_token_id[1]  <= pend_token; out_tab[1].side  <= pend_intent.side; out_tab[1].price  <= pend_intent.price; out_tab[1].qty  <= pend_intent.qty; out_tab[1].filled_tot  <= 32'd0; out_tab[1].cancel_sent  <= 1'b0; end
    if (load_slot_2)  begin out_tab[2].symbol_id  <= pend_intent.symbol_id; out_tab[2].token_id  <= pend_token; safe_token_id[2]  <= pend_token; out_tab[2].side  <= pend_intent.side; out_tab[2].price  <= pend_intent.price; out_tab[2].qty  <= pend_intent.qty; out_tab[2].filled_tot  <= 32'd0; out_tab[2].cancel_sent  <= 1'b0; end
    if (load_slot_3)  begin out_tab[3].symbol_id  <= pend_intent.symbol_id; out_tab[3].token_id  <= pend_token; safe_token_id[3]  <= pend_token; out_tab[3].side  <= pend_intent.side; out_tab[3].price  <= pend_intent.price; out_tab[3].qty  <= pend_intent.qty; out_tab[3].filled_tot  <= 32'd0; out_tab[3].cancel_sent  <= 1'b0; end
    if (load_slot_4)  begin out_tab[4].symbol_id  <= pend_intent.symbol_id; out_tab[4].token_id  <= pend_token; safe_token_id[4]  <= pend_token; out_tab[4].side  <= pend_intent.side; out_tab[4].price  <= pend_intent.price; out_tab[4].qty  <= pend_intent.qty; out_tab[4].filled_tot  <= 32'd0; out_tab[4].cancel_sent  <= 1'b0; end
    if (load_slot_5)  begin out_tab[5].symbol_id  <= pend_intent.symbol_id; out_tab[5].token_id  <= pend_token; safe_token_id[5]  <= pend_token; out_tab[5].side  <= pend_intent.side; out_tab[5].price  <= pend_intent.price; out_tab[5].qty  <= pend_intent.qty; out_tab[5].filled_tot  <= 32'd0; out_tab[5].cancel_sent  <= 1'b0; end
    if (load_slot_6)  begin out_tab[6].symbol_id  <= pend_intent.symbol_id; out_tab[6].token_id  <= pend_token; safe_token_id[6]  <= pend_token; out_tab[6].side  <= pend_intent.side; out_tab[6].price  <= pend_intent.price; out_tab[6].qty  <= pend_intent.qty; out_tab[6].filled_tot  <= 32'd0; out_tab[6].cancel_sent  <= 1'b0; end
    if (load_slot_7)  begin out_tab[7].symbol_id  <= pend_intent.symbol_id; out_tab[7].token_id  <= pend_token; safe_token_id[7]  <= pend_token; out_tab[7].side  <= pend_intent.side; out_tab[7].price  <= pend_intent.price; out_tab[7].qty  <= pend_intent.qty; out_tab[7].filled_tot  <= 32'd0; out_tab[7].cancel_sent  <= 1'b0; end
    if (load_slot_8)  begin out_tab[8].symbol_id  <= pend_intent.symbol_id; out_tab[8].token_id  <= pend_token; safe_token_id[8]  <= pend_token; out_tab[8].side  <= pend_intent.side; out_tab[8].price  <= pend_intent.price; out_tab[8].qty  <= pend_intent.qty; out_tab[8].filled_tot  <= 32'd0; out_tab[8].cancel_sent  <= 1'b0; end
    if (load_slot_9)  begin out_tab[9].symbol_id  <= pend_intent.symbol_id; out_tab[9].token_id  <= pend_token; safe_token_id[9]  <= pend_token; out_tab[9].side  <= pend_intent.side; out_tab[9].price  <= pend_intent.price; out_tab[9].qty  <= pend_intent.qty; out_tab[9].filled_tot  <= 32'd0; out_tab[9].cancel_sent  <= 1'b0; end
    if (load_slot_10) begin out_tab[10].symbol_id <= pend_intent.symbol_id; out_tab[10].token_id <= pend_token; safe_token_id[10] <= pend_token; out_tab[10].side <= pend_intent.side; out_tab[10].price <= pend_intent.price; out_tab[10].qty <= pend_intent.qty; out_tab[10].filled_tot <= 32'd0; out_tab[10].cancel_sent <= 1'b0; end
    if (load_slot_11) begin out_tab[11].symbol_id <= pend_intent.symbol_id; out_tab[11].token_id <= pend_token; safe_token_id[11] <= pend_token; out_tab[11].side <= pend_intent.side; out_tab[11].price <= pend_intent.price; out_tab[11].qty <= pend_intent.qty; out_tab[11].filled_tot <= 32'd0; out_tab[11].cancel_sent <= 1'b0; end
    if (load_slot_12) begin out_tab[12].symbol_id <= pend_intent.symbol_id; out_tab[12].token_id <= pend_token; safe_token_id[12] <= pend_token; out_tab[12].side <= pend_intent.side; out_tab[12].price <= pend_intent.price; out_tab[12].qty <= pend_intent.qty; out_tab[12].filled_tot <= 32'd0; out_tab[12].cancel_sent <= 1'b0; end
    if (load_slot_13) begin out_tab[13].symbol_id <= pend_intent.symbol_id; out_tab[13].token_id <= pend_token; safe_token_id[13] <= pend_token; out_tab[13].side <= pend_intent.side; out_tab[13].price <= pend_intent.price; out_tab[13].qty <= pend_intent.qty; out_tab[13].filled_tot <= 32'd0; out_tab[13].cancel_sent <= 1'b0; end
    if (load_slot_14) begin out_tab[14].symbol_id <= pend_intent.symbol_id; out_tab[14].token_id <= pend_token; safe_token_id[14] <= pend_token; out_tab[14].side <= pend_intent.side; out_tab[14].price <= pend_intent.price; out_tab[14].qty <= pend_intent.qty; out_tab[14].filled_tot <= 32'd0; out_tab[14].cancel_sent <= 1'b0; end
    if (load_slot_15) begin out_tab[15].symbol_id <= pend_intent.symbol_id; out_tab[15].token_id <= pend_token; safe_token_id[15] <= pend_token; out_tab[15].side <= pend_intent.side; out_tab[15].price <= pend_intent.price; out_tab[15].qty <= pend_intent.qty; out_tab[15].filled_tot <= 32'd0; out_tab[15].cancel_sent <= 1'b0; end

    if (rpt_valid_p1) begin
      for (int i = 0; i < MAX_OUT; i++) begin
        if (token_match_p1[i]) begin
          out_tab[i].filled_tot <= rpt_p1.filled_total;
          
          // FIX: Use aligned p1 data to determine if this was a partial fill!
          if (rpt_p1.kind == RPT_EXEC && (rpt_p1.filled_total < match_data_p1.qty) && !out_tab[i].cancel_sent) begin
             out_tab[i].cancel_sent <= 1'b1;
          end
          
        end
      end
    end

    // NEW: Mark the timed-out order so we don't spam cancels for it
    if (timeout_fire && !c_mem_full) begin // FIX: Use immediate comb trigger
      out_tab[timeout_id].cancel_sent <= 1'b1;
    end
  end

endmodule
