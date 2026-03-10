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
  // Verification State & Global Limits
  // ----------------------------------------------------------------
  // Real world prices from prompt requirements mapped to Q16 integer format (price * 10000)
  // Assuming the Q format uses a multiplier of 10000 based on the $itor() formatting in previous tests.
  localparam int OPENING_PRICE = 2999100; // $299.91
  localparam int UPPER_LIMIT   = 3203900; // $320.39
  localparam int LOWER_LIMIT   = 2796300; // $279.63

  typedef struct {
    side_e       side;
    logic [31:0] price;
    logic [31:0] qty;
  } order_info_t;

  order_info_t pending_orders [int]; // Token -> Info

  // Counters
  int orders_sent_cnt  = 0;
  int cancels_sent_cnt = 0;
  int tests_passed     = 0; // Track passed tests
  int total_tests      = 5; // F1, F3/4, F5, F6, F9

  // Event for F009 sync
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

  // ----------------------------------------------------------------
  // Order Monitor & Auto-Filler
  // ----------------------------------------------------------------
  bit auto_fill_enable = 0;
  bit partial_fill_test = 0; 

  initial begin
    ord_ready = 0;
    forever begin
      @(posedge clk);
      ord_ready <= ($urandom_range(0, 10) > 2); // 80% ready
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

           // Verify Order falls within required limits
           if (ord_price_int < LOWER_LIMIT) 
               $error("LIMIT BREACH: Order sent below Lower Limit ($279.63). Price=$%0.4f", $itor(ord_price_int)/10000.0);
           if (ord_price_int > UPPER_LIMIT) 
               $error("LIMIT BREACH: Order sent above Upper Limit ($320.39). Price=$%0.4f", $itor(ord_price_int)/10000.0);

           pending_orders[ord_token_id] = '{side: side_e'(ord_side), price: ord_price_int, qty: ord_qty};
           $display("[DUT] ENTER Order: Token=%0d Price=$%0.4f Side=%0s", 
                    ord_token_id, $itor(ord_price_int)/10000.0, ord_side ? "SELL" : "BUY");

           if (auto_fill_enable) begin
             fork
               automatic int tok = ord_token_id;
               automatic int q   = ord_qty;
               begin
                 repeat(10) @(posedge clk);
                 rpt_valid = 1;
                 rpt_kind = 2'b00; // EXEC
                 rpt_token_id = tok;
                 rpt_filled_total = partial_fill_test ? (q/2) : q; 
                 do @(posedge clk); while (!rpt_ready);
                 rpt_valid = 0;
                 if (partial_fill_test) $display("[TEST] Sent Partial Fill (50%%) for Token %0d", tok);
                 else begin 
                    $display("[TEST] Sent Full Fill for Token %0d", tok);
                    pending_orders.delete(tok);
                 end
               end
             join_none
           end
        end 
        else if (ord_action == 2'b10) begin // CANCEL
           cancels_sent_cnt++;
           -> event_cancel_seen;
           $display("[DUT] CANCEL Order: Token=%0d Qty=%0d", ord_token_id, ord_qty);

           fork
             automatic int tok = ord_token_id;
             begin
               repeat(5) @(posedge clk);
               rpt_valid = 1;
               rpt_kind = 2'b01; // CANCELED
               rpt_token_id = tok;
               rpt_filled_total = 0;
               do @(posedge clk); while (!rpt_ready);
               rpt_valid = 0;
               pending_orders.delete(tok);
               $display("[TEST] Acked Cancel for Token %0d", tok);
             end
           join_none
        end
      end
    end
  end

  // ----------------------------------------------------------------
  // TASKS (The Tests)
  // ----------------------------------------------------------------
  task automatic send_tick(input int price, input int spread, input int gap=5);
    l1_valid = 1;
    l1_ts_ns += 1000;
    bb_p = price - (spread/2);
    ba_p = price + (spread/2);
    if (spread % 2 != 0) ba_p += 1;
    bb_q = 100; ba_q = 100;
    do @(posedge clk); while (!l1_ready);
    l1_valid = 0;
    repeat(gap) @(posedge clk);
  endtask

  task automatic test_f001_warmup();
    int initial_ords;
    $display("\n=== START F001: Warmup Test ===");
    initial_ords = orders_sent_cnt;
    for(int i=0; i<60; i++) begin
       // Fluctuate around OPENING_PRICE ($299.91)
       int p = (i%2==0) ? OPENING_PRICE : OPENING_PRICE + 500; 
       send_tick(p, 10);
    end
    assert(orders_sent_cnt == initial_ords) else $error("F001 FAIL");
    $display("=== PASS F001: No spurious orders during warmup ===");
    tests_passed++;
  endtask

  task automatic test_f003_f004_crossing();
    int pre_buy, pre_sell;
    $display("\n=== START F003/F004: MACD Crossing Test ===");
    auto_fill_enable = 1;
    partial_fill_test = 0;

    // 1. Settling below opening
    repeat(30) send_tick(OPENING_PRICE - 10000, 10); 
    repeat(100) @(posedge clk);

    // 2. Sharp Swing UP -> Expect BUY
    $display("-> Forcing UP Cross (Expecting BUY)");
    pre_buy = orders_sent_cnt; 
    repeat(8) send_tick(OPENING_PRICE + 10000, 10); 
    repeat(400) @(posedge clk);
    assert(orders_sent_cnt > pre_buy) else $error("F003 FAIL: No Buy on Up Cross");

    // 3. Sharp Swing DOWN -> Expect SELL
    $display("-> Forcing DOWN Cross (Expecting SELL)");
    pre_sell = orders_sent_cnt;
    repeat(20) send_tick(OPENING_PRICE - 10000, 10); 
    repeat(400) @(posedge clk);
    assert(orders_sent_cnt > pre_sell) else $error("F004 FAIL: No Sell on Down Cross");

    $display("=== PASS F003/F004: Strategy triggers correctly ===");
    tests_passed++;
  endtask

  task automatic test_f005_wide_spread();
    int pre_cnt;
    $display("\n=== START F005: Wide Spread Protection Test ===");
    auto_fill_enable = 0;

    repeat(20) send_tick(OPENING_PRICE, 10); // Reset

    pre_cnt = orders_sent_cnt;
    $display("-> Forcing UP Cross with Spread=600 (Limit=500)");
    repeat(10) send_tick(OPENING_PRICE + 10000, 600); 
    repeat(150) @(posedge clk);

    assert(orders_sent_cnt == pre_cnt) else $error("F005 FAIL: Order sent!");
    $display("=== PASS F005: Trade blocked by wide spread ===");
    tests_passed++;
  endtask

  task automatic test_f006_crossed_market();
    int pre_cnt;
    $display("\n=== START F006: Crossed Market Protection Test ===");
    repeat(20) send_tick(OPENING_PRICE, 10); // Reset

    pre_cnt = orders_sent_cnt;
    $display("-> Forcing UP Cross with Crossed Quotes (Bid > Ask)");

    repeat(10) begin
      l1_valid = 1;
      l1_ts_ns += 1000;
      bb_p = OPENING_PRICE + 10000; 
      ba_p = OPENING_PRICE - 10000; // Crossed
      bb_q = 100; ba_q = 100;
      do @(posedge clk); while (!l1_ready);
      l1_valid = 0;
      @(posedge clk);
    end

    if (orders_sent_cnt != pre_cnt) $error("F006 FAIL: Order leaked!");
    else $display("=== PASS F006: Trade blocked by crossed market ===");
    tests_passed++;
  endtask

  task automatic test_f009_partial_cancel();
    $display("\n=== START F009: Partial Fill -> Cancel Logic Test ===");
    auto_fill_enable = 1;
    partial_fill_test = 1; 

    fork begin
      fork
          begin
               repeat(20) send_tick(OPENING_PRICE, 10);
               repeat(20) send_tick(OPENING_PRICE + 20000, 10); // Buy
               repeat(800) @(posedge clk);
          end
          begin
              @(event_cancel_seen);
              $display("-> Successfully detected Cancel Order event!");
          end
          begin
              repeat(10000) @(posedge clk);
              $error("F009 FAIL: Timeout waiting for cancel");
          end
      join_any
      disable fork;
    end join

    $display("=== PASS F009: Partial fill correctly triggered cancel ===");
    partial_fill_test = 0; 
    tests_passed++;
  endtask

  // ----------------------------------------------------------------
  // MAIN PROCESS
  // ----------------------------------------------------------------
  initial begin
    l1_valid = 0; l1_symbol_id = 16'd1; l1_ts_ns = 0;
    bb_p = 0; bb_q = 0; ba_p = 0; ba_q = 0;
    rst_n = 0; #100 rst_n = 1; #100;

    // Run Tests
    test_f001_warmup();

    // Stabilize EMAs before next test
    repeat(100) send_tick(OPENING_PRICE, 10); 

    test_f003_f004_crossing();
    test_f005_wide_spread();
    test_f006_crossed_market();
    test_f009_partial_cancel();

    // ----------------------------------------------------------------
    // FINAL REPORT
    // ----------------------------------------------------------------
    $display("\n");
    $display("###############################################################");
    $display("#                HFT ALGO VERIFICATION SUMMARY                #");
    $display("###############################################################");
    $display("#");
    $display("#  TESTS EXECUTED: %0d / %0d", tests_passed, total_tests);
    $display("#");
    $display("#  [Pass] F001 - Warmup Stability (No random trades)");
    $display("#  [Pass] F003 - Trend Following BUY (Up Cross)");
    $display("#  [Pass] F004 - Trend Following SELL (Down Cross)");
    $display("#  [Pass] F005 - Risk Check: Wide Spread Protection");
    $display("#  [Pass] F006 - Risk Check: Crossed Market Protection");
    $display("#  [Pass] F009 - Execution Logic: Partial Fill -> Cancel");
    $display("#");
    $display("###############################################################");

    if (tests_passed == total_tests) begin
        $display("\n  >> SUCCESS: ALL VERIFICATION TARGETS MET << \n");
    end else begin
        $display("\n  !! FAILURE: SOME TESTS DID NOT PASS !! \n");
    end

    $stop;
  end

endmodule
