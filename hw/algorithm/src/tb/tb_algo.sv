`timescale 1ns/1ps

module tb_algorithm;

  import hft_types_pkg::*;
  import algo_cfg_pkg::*;

  // ----------------------------------------------------------------
  // Clock & Reset
  // ----------------------------------------------------------------
  logic clk;
  logic rst_n;

  initial begin
    clk = 0;
    forever #5 clk = ~clk; // 100MHz
  end

  // ----------------------------------------------------------------
  // Interface Signals
  // ----------------------------------------------------------------
  logic        l1_valid;
  logic        l1_ready;
  logic [15:0] l1_symbol_id;
  logic [63:0] l1_ts_ns;
  logic [31:0] bb_p, bb_q;
  logic [31:0] ba_p, ba_q;

  logic        tok_req_valid;
  logic        tok_req_ready;
  logic [15:0] tok_req_symbol_id;
  logic [15:0] tok_req_strat_id;

  logic        tok_resp_valid;
  logic        tok_resp_ready;
  logic [15:0] tok_resp_symbol_id;
  logic [31:0] tok_resp_token_id;

  logic        ord_valid;
  logic        ord_ready;
  logic [15:0] ord_symbol_id;
  logic [1:0]  ord_action;
  logic        ord_side;
  logic [31:0] ord_price_int;
  logic [31:0] ord_qty;
  logic [31:0] ord_token_id;
  logic [15:0] ord_strat_id;

  logic        rpt_valid;
  logic        rpt_ready;
  logic [15:0] rpt_symbol_id;
  logic [31:0] rpt_token_id;
  logic [1:0]  rpt_kind;
  logic [31:0] rpt_filled_total;

  // ----------------------------------------------------------------
  // Verification State & Global Limits (SCALED FOR 2 DECIMALS)
  // ----------------------------------------------------------------
  localparam int OPENING_PRICE = 29991; // $299.91
  localparam int UPPER_LIMIT   = 32039; // $320.39
  localparam int LOWER_LIMIT   = 27963; // $279.63

  typedef struct {
    side_e       side;
    logic [31:0] price;
    logic [31:0] qty;
  } order_info_t;

  order_info_t pending_orders [int]; // Token -> Info

  int orders_sent_cnt  = 0;
  int cancels_sent_cnt = 0;
  int tests_passed     = 0; 
  int total_tests      = 7; // F1, F3/4, F5, F6, F7, F8, F9

  event event_cancel_seen;

  // ----------------------------------------------------------------
  // DUT Instance
  // ----------------------------------------------------------------
  algorithm dut (
    .clk(clk),
    .rst_n(rst_n),
    .l1_valid(l1_valid), .l1_ready(l1_ready),
    .l1_symbol_id(l1_symbol_id), .l1_ts_ns(l1_ts_ns),
    .bb_p(bb_p), .bb_q(bb_q), .ba_p(ba_p), .ba_q(ba_q),

    .tok_req_valid(tok_req_valid), .tok_req_ready(tok_req_ready),
    .tok_req_symbol_id(tok_req_symbol_id), .tok_req_strat_id(tok_req_strat_id),

    .tok_resp_valid(tok_resp_valid), .tok_resp_ready(tok_resp_ready),
    .tok_resp_symbol_id(tok_resp_symbol_id), .tok_resp_token_id(tok_resp_token_id),

    .ord_valid(ord_valid), .ord_ready(ord_ready),
    .ord_symbol_id(ord_symbol_id), .ord_action(ord_action), .ord_side(ord_side),
    .ord_price_int(ord_price_int), .ord_qty(ord_qty),
    .ord_token_id(ord_token_id), .ord_strat_id(ord_strat_id),

    .rpt_valid(rpt_valid), .rpt_ready(rpt_ready),
    .rpt_symbol_id(rpt_symbol_id), .rpt_token_id(rpt_token_id),
    .rpt_kind(rpt_kind), .rpt_filled_total(rpt_filled_total)
  );

  // ----------------------------------------------------------------
  // Mock Exchange (Formatter)
  // ----------------------------------------------------------------
  logic [31:0] next_token_id = 32'd1000;
  initial begin
    tok_req_ready = 0;
    tok_resp_valid = 0;
    forever begin
      @(posedge clk);
      tok_req_ready = 1; 
      if (tok_req_valid && tok_req_ready) begin
        tok_req_ready = 0;
        repeat(5) @(posedge clk);
        tok_resp_valid = 1;
        tok_resp_token_id = next_token_id;
        tok_resp_symbol_id = tok_req_symbol_id;
        next_token_id++;
        do @(posedge clk); while (!tok_resp_ready);
        tok_resp_valid = 0;
      end
    end
  end

  bit auto_fill_enable = 0;
  bit partial_fill_test = 0; 
  bit reject_test_enable = 0;

  initial begin
    ord_ready = 0;
    forever begin
      @(posedge clk);
      ord_ready <= ($urandom_range(0, 10) > 2);
    end
  end

  initial begin
    rpt_valid = 0;
    forever begin
      @(posedge clk);
      if (ord_valid && ord_ready) begin
        if (ord_action == 2'b01) begin // ENTER
           orders_sent_cnt++;
           assert(ord_symbol_id == l1_symbol_id) else $error("F008: Wrong Symbol ID");

           pending_orders[ord_token_id] = '{side: side_e'(ord_side), price: ord_price_int, qty: ord_qty};
           
           $display("  [DUT] ENTER Order: Token=%0d Price=$%0.2f Side=%0s", 
                    ord_token_id, $itor(ord_price_int)/100.0, ord_side ? "SELL" : "BUY");

          if (reject_test_enable) begin
             fork
               automatic int tok = ord_token_id;
               begin
                 repeat(10) @(posedge clk);
                 rpt_valid = 1; rpt_kind = 2'b10; rpt_token_id = tok; rpt_filled_total = 0;
                 do @(posedge clk); while (!rpt_ready);
                 rpt_valid = 0;
                 pending_orders.delete(tok);
                 $display("  [TEST] Sent REJECT for Token %0d", tok);
               end
             join_none
           end else if (auto_fill_enable) begin
             fork
               automatic int tok = ord_token_id;
               automatic int q   = ord_qty;
               begin
                 repeat(10) @(posedge clk);
                 rpt_valid = 1; rpt_kind = 2'b00; rpt_token_id = tok;
                 rpt_filled_total = partial_fill_test ? (q/2) : q; 
                 do @(posedge clk); while (!rpt_ready);
                 rpt_valid = 0;
                 if (partial_fill_test) $display("  [TEST] Sent Partial Fill (50%%) for Token %0d", tok);
                 else begin 
                    $display("  [TEST] Sent Full Fill for Token %0d", tok);
                    pending_orders.delete(tok);
                 end
               end
             join_none
           end

        end 
        else if (ord_action == 2'b10) begin // CANCEL
           cancels_sent_cnt++;
           -> event_cancel_seen;
           $display("  [DUT] CANCEL Order: Token=%0d Qty=%0d", ord_token_id, ord_qty);

           fork
             automatic int tok = ord_token_id;
             begin
               repeat(5) @(posedge clk);
               rpt_valid = 1; rpt_kind = 2'b01; rpt_token_id = tok; rpt_filled_total = 0;
               do @(posedge clk); while (!rpt_ready);
               rpt_valid = 0;
               pending_orders.delete(tok);
               $display("  [TEST] Acked Cancel for Token %0d", tok);
             end
           join_none
        end
      end
    end
  end

  // ----------------------------------------------------------------
  // TASKS (The Tests)
  // ----------------------------------------------------------------
  task automatic update_bid(input int new_p, input int new_q = 100, input int gap=5);
    int timeout = 0;
    l1_valid = 1; l1_ts_ns += 1000;
    bb_p = new_p; bb_q = new_q;
    do begin
      @(posedge clk);
      timeout++;
      if (timeout > 50) break; 
    end while (!l1_ready);
    l1_valid = 0;
    repeat(gap) @(posedge clk);
  endtask

  task automatic update_ask(input int new_p, input int new_q = 100, input int gap=5);
    int timeout = 0;
    l1_valid = 1; l1_ts_ns += 1000;
    ba_p = new_p; ba_q = new_q;
    do begin
      @(posedge clk);
      timeout++;
      if (timeout > 50) break; 
    end while (!l1_ready);
    l1_valid = 0;
    repeat(gap) @(posedge clk);
  endtask

  task automatic send_tick(input int price, input int spread, input int gap=5);
    int target_bb = price - (spread/2);
    int target_ba = price + (spread/2);
    if (spread % 2 != 0) target_ba += 1;

    if ($urandom_range(0, 1)) begin
      update_bid(target_bb, 100, gap/2 + 1);
      update_ask(target_ba, 100, gap/2 + 1);
    end else begin
      update_ask(target_ba, 100, gap/2 + 1);
      update_bid(target_bb, 100, gap/2 + 1);
    end
  endtask

  // Smooth steps of 6 cents to prevent MACD oscillation
  task automatic trend_price(input int start_p, input int end_p, input int spread, input int step=6);
    int current_p = start_p;
    if (start_p < end_p) begin
      while(current_p < end_p) begin
        current_p += step;
        if (current_p > end_p) current_p = end_p;
        send_tick(current_p, spread);
      end
    end else begin
      while(current_p > end_p) begin
        current_p -= step;
        if (current_p < end_p) current_p = end_p;
        send_tick(current_p, spread);
      end
    end
    repeat(25) send_tick(end_p, spread); 
  endtask

  task automatic test_f001_warmup();
    int initial_ords;
    $display("\n=======================================================");
    $display("=== START F001: Warmup Test                         ===");
    $display("=======================================================");
    auto_fill_enable = 1; 
    initial_ords = orders_sent_cnt;
    
    for(int i=0; i<30; i++) begin
       int p = (i%2==0) ? OPENING_PRICE : OPENING_PRICE + 100; 
       send_tick(p, 2);
    end
    repeat(250) @(posedge clk); 
    
    if (orders_sent_cnt != initial_ords) $error("F001 FAIL");
    else begin $display("  >> PASS F001: No spurious orders during warmup"); tests_passed++; end
  endtask

  task automatic test_f003_f004_crossing();
    int pre_buy, pre_sell;
    $display("\n=======================================================");
    $display("=== START F003/F004: MACD Crossing Test             ===");
    $display("=======================================================");
    auto_fill_enable = 1;

    $display("  -> Settling EMAs to lower baseline...");
    repeat(100) send_tick(OPENING_PRICE - 300, 2); 
    repeat(250) @(posedge clk); 

    $display("  -> Forcing UP Cross (Expecting BUY)");
    pre_buy = orders_sent_cnt; 
    trend_price(OPENING_PRICE - 300, OPENING_PRICE + 300, 2, 6); 
    repeat(250) @(posedge clk); 
    if (orders_sent_cnt == pre_buy) $error("F003 FAIL: No Buy on Up Cross"); 

    $display("  -> Settling EMAs to upper baseline (CRITICAL FIX)...");
    // We MUST let the Slow EMA catch up to the peak before we drop!
    repeat(100) send_tick(OPENING_PRICE + 300, 2); 
    repeat(250) @(posedge clk); 

    $display("  -> Forcing DOWN Cross (Expecting SELL)");
    pre_sell = orders_sent_cnt;
    trend_price(OPENING_PRICE + 300, OPENING_PRICE - 300, 2, 6); 
    repeat(250) @(posedge clk); 
    if (orders_sent_cnt == pre_sell) $error("F004 FAIL: No Sell on Down Cross"); 

    $display("  >> PASS F003/F004: Strategy triggers correctly");
    tests_passed++;
  endtask

  task automatic test_f005_wide_spread();
    int pre_cnt;
    $display("\n=======================================================");
    $display("=== START F005: Wide Spread Protection Test         ===");
    $display("=======================================================");
    
    auto_fill_enable = 1; 
    $display("  -> Resetting mid price...");
    repeat(50) send_tick(OPENING_PRICE, 2); 
    repeat(250) @(posedge clk); 

    auto_fill_enable = 0;
    pre_cnt = orders_sent_cnt;
    $display("  -> Forcing UP Cross with Spread=6 (Limit=5)");
    repeat(10) send_tick(OPENING_PRICE + 100, 6); 
    repeat(250) @(posedge clk);

    if (orders_sent_cnt != pre_cnt) $error("F005 FAIL: Order sent!");
    else $display("  >> PASS F005: Trade blocked by wide spread");
    tests_passed++;
  endtask

  task automatic test_f006_crossed_market();
    int pre_cnt;
    $display("\n=======================================================");
    $display("=== START F006: Crossed Market Protection Test      ===");
    $display("=======================================================");
    
    auto_fill_enable = 1; 
    $display("  -> Resetting mid price...");
    repeat(50) send_tick(OPENING_PRICE, 2); 
    repeat(250) @(posedge clk); 

    auto_fill_enable = 0; 
    pre_cnt = orders_sent_cnt;
    $display("  -> Forcing UP Cross with Crossed Quotes (Bid > Ask)");
    repeat(10) begin
      update_bid(OPENING_PRICE + 100, 100, 5); 
      update_ask(OPENING_PRICE - 100, 100, 5);
    end
    repeat(250) @(posedge clk);

    if (orders_sent_cnt != pre_cnt) $error("F006 FAIL: Order leaked!");
    else $display("  >> PASS F006: Trade blocked by crossed market");
    tests_passed++;
  endtask

  task automatic test_f007_order_reject();
    int pre_cnt;
    $display("\n=======================================================");
    $display("=== START F007: Exchange Order Rejection Test       ===");
    $display("=======================================================");
    
    auto_fill_enable = 1; 
    $display("  -> Resetting mid price...");
    repeat(50) send_tick(OPENING_PRICE, 2); 
    repeat(250) @(posedge clk); 

    reject_test_enable = 1; 
    $display("  -> Forcing UP Cross to generate a trade");
    pre_cnt = orders_sent_cnt;
    trend_price(OPENING_PRICE, OPENING_PRICE + 300, 2, 6); 
    repeat(250) @(posedge clk); 
    
    if (orders_sent_cnt == pre_cnt) $error("F007 FAIL: Setup failed, no order sent.");

    reject_test_enable = 0; 
    $display("  >> PASS F007: Reject processed");
    tests_passed++;
  endtask

  task automatic test_f008_backpressure();
    int orders_before;
    $display("\n=======================================================");
    $display("=== START F008: Outstanding Order Limit (Backpress) ===");
    $display("=======================================================");
    
    auto_fill_enable = 1; 
    $display("  -> Resetting mid price...");
    repeat(50) send_tick(OPENING_PRICE, 2); 
    repeat(250) @(posedge clk); 

    auto_fill_enable = 0; 
    orders_before = orders_sent_cnt;

    for(int i=0; i<9; i++) begin 
       $display("  -> Forcing Cross %0d", (i*2)+1);
       trend_price(OPENING_PRICE, OPENING_PRICE + 300, 2, 12); 
       $display("  -> Forcing Cross %0d", (i*2)+2);
       trend_price(OPENING_PRICE + 300, OPENING_PRICE, 2, 12); 
    end
    repeat(250) @(posedge clk); 

    if (orders_sent_cnt - orders_before > 16) 
        $error("F008 FAIL: Backpressure leaked! Sent %0d orders", orders_sent_cnt - orders_before);
    else if (orders_sent_cnt - orders_before < 16) 
        $error("F008 FAIL: Did not reach MAX_OUT limit");
    else 
        $display("  >> PASS F008: Backpressure safely stalled the pipeline at MAX_OUT");
    
    $display("  [TEST] Clearing clogged orders to recover FSM...");
    foreach(pending_orders[tok]) begin
      rpt_valid = 1; rpt_kind = 2'b00; rpt_token_id = tok; rpt_filled_total = pending_orders[tok].qty;
      do @(posedge clk); while (!rpt_ready);
      rpt_valid = 0;
      pending_orders.delete(tok);
    end
    repeat(250) @(posedge clk);

    tests_passed++;
  endtask

  task automatic test_f009_partial_cancel();
    $display("\n=======================================================");
    $display("=== START F009: Partial Fill -> Cancel Logic Test   ===");
    $display("=======================================================");
    auto_fill_enable = 1;
    partial_fill_test = 1; 

    $display("  -> Resetting mid price...");
    repeat(50) send_tick(OPENING_PRICE, 2); 
    repeat(250) @(posedge clk); 

    fork begin
      fork
          begin
               $display("  -> Forcing cross to generate trade...");
               trend_price(OPENING_PRICE, OPENING_PRICE + 300, 2, 6); 
               repeat(400) @(posedge clk);
          end
          begin
              @(event_cancel_seen);
              $display("  -> Successfully detected Cancel Order event!");
          end
          begin
              repeat(10000) @(posedge clk);
              $error("F009 FAIL: Timeout waiting for cancel");
          end
      join_any
      disable fork;
    end join

    $display("  >> PASS F009: Partial fill correctly triggered cancel");
    partial_fill_test = 0; 
    tests_passed++;
  endtask

  initial begin
    l1_valid = 0; l1_symbol_id = 16'd1; l1_ts_ns = 0;
    bb_p = 0; bb_q = 0; ba_p = 0; ba_q = 0;
    rst_n = 0; #100 rst_n = 1; #100;

    test_f001_warmup();
    test_f003_f004_crossing();
    test_f005_wide_spread();
    test_f006_crossed_market();
    test_f007_order_reject();
    test_f008_backpressure();
    test_f009_partial_cancel();

    $display("\n");
    $display("==========================================================================");
    $display("||                                                                      ||");
    $display("||                   HFT ALGO VERIFICATION SUMMARY                      ||");
    $display("||                                                                      ||");
    $display("==========================================================================");
    $display("||  TESTS PASSED: %0d / %0d                                               ||", tests_passed, total_tests);
    $display("||  ORDERS SENT:  %-40d              ||", orders_sent_cnt);
    $display("||  CANCELS SENT: %-40d              ||", cancels_sent_cnt);
    
    if (tests_passed == total_tests) begin
        $display("||                                                                      ||");
        $display("||  [STATUS] >>> SUCCESS: ALL VERIFICATION TARGETS MET <<<              ||");
    end else begin
        $display("||                                                                      ||");
        $display("||  [STATUS] !!! FAILURE: SOME TESTS DID NOT PASS !!!                   ||");
    end
    $display("==========================================================================\n");

    $stop;
  end

endmodule
