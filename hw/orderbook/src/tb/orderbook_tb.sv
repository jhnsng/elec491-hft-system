`timescale 1ns/1ps

module orderbook_tb;

    import _pkg::*;

    // Parameters - match DUT
    localparam BUFFER_SIZE = 4096;
    localparam LIMIT_DOWN_PRICE = 27963;  // Match orderbook.sv
    localparam PRICE_WIDTH = 32;
    localparam QTY_WIDTH = 32;
    localparam CLK_PERIOD = 10;
    localparam NUM_M10K_BLOCKS = BUFFER_SIZE / 256;
    
    // Latency calculation: RMW (3) + REDUCE_SCAN (5 cycles: skip first + read 4 addresses) + REDUCE_TREE (5 cycles: 16→8→4→2→1→latch) = 13 cycles
    localparam ORDER_LATENCY = 13;

    // DUT signals
    logic                     clk;
    logic                     rst_n;
    side_t                    side_in;
    logic [PRICE_WIDTH-1:0]   price_in;
    logic [QTY_WIDTH-1:0]     delta_qty_in;
    logic                     valid_in;
    logic                     valid_out;
    order_info_t              order_out;
    logic [PRICE_WIDTH-1:0]   best_bid_price;
    logic [QTY_WIDTH-1:0]     best_bid_qty;
    logic                     best_bid_valid;
    logic [PRICE_WIDTH-1:0]   best_ask_price;
    logic [QTY_WIDTH-1:0]     best_ask_qty;
    logic                     best_ask_valid;

    // Test variables
    int test_passed = 0;
    int test_failed = 0;

    // Instantiate DUT
    orderbook #(
        .BUFFER_SIZE(BUFFER_SIZE),
        .LIMIT_DOWN_PRICE(LIMIT_DOWN_PRICE),
        .PRICE_WIDTH(PRICE_WIDTH),
        .QTY_WIDTH(QTY_WIDTH),
        .NUM_M10K_BLOCKS(NUM_M10K_BLOCKS)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .side_in(side_in),
        .price_in(price_in),
        .delta_qty_in(delta_qty_in),
        .valid_in(valid_in),
        .valid_out(valid_out),
        .order_out(order_out),
        .best_bid_price(best_bid_price),
        .best_bid_qty(best_bid_qty),
        .best_bid_valid(best_bid_valid),
        .best_ask_price(best_ask_price),
        .best_ask_qty(best_ask_qty),
        .best_ask_valid(best_ask_valid)
    );

    // Clock generation
    initial begin
        clk = 0;
        forever #(CLK_PERIOD/2) clk = ~clk;
    end

    // Task to add an order
    task add_order(
        input side_t side,
        input logic [PRICE_WIDTH-1:0] price,
        input logic [QTY_WIDTH-1:0] qty
    );
        @(posedge clk);
        side_in <= side;
        price_in <= price;
        delta_qty_in <= qty;
        valid_in <= 1'b1;
        @(posedge clk);
        valid_in <= 1'b0;
        // Wait for full pipeline: RMW (3) + REDUCE_SCAN (256) + REDUCE_TREE (4) = 263 cycles
        repeat(ORDER_LATENCY + 5) @(posedge clk);
    endtask

    // Task to check best bid
    task check_best_bid(
        input logic [PRICE_WIDTH-1:0] expected_price,
        input logic [QTY_WIDTH-1:0] expected_qty,
        input logic expected_valid,
        input string test_name
    );
        if (best_bid_price === expected_price && 
            best_bid_qty === expected_qty && 
            best_bid_valid === expected_valid) begin
            $display("PASS: %s - Best Bid: Price=%0d, Qty=%0d, Valid=%0b", 
                     test_name, best_bid_price, best_bid_qty, best_bid_valid);
            test_passed++;
        end else begin
            $display("FAIL: %s", test_name);
            $display("  Expected: Price=%0d, Qty=%0d, Valid=%0b", 
                     expected_price, expected_qty, expected_valid);
            $display("  Got:      Price=%0d, Qty=%0d, Valid=%0b", 
                     best_bid_price, best_bid_qty, best_bid_valid);
            test_failed++;
        end
    endtask

    // Task to check best ask
    task check_best_ask(
        input logic [PRICE_WIDTH-1:0] expected_price,
        input logic [QTY_WIDTH-1:0] expected_qty,
        input logic expected_valid,
        input string test_name
    );
        if (best_ask_price === expected_price && 
            best_ask_qty === expected_qty && 
            best_ask_valid === expected_valid) begin
            $display("PASS: %s - Best Ask: Price=%0d, Qty=%0d, Valid=%0b", 
                     test_name, best_ask_price, best_ask_qty, best_ask_valid);
            test_passed++;
        end else begin
            $display("FAIL: %s", test_name);
            $display("  Expected: Price=%0d, Qty=%0d, Valid=%0b", 
                     expected_price, expected_qty, expected_valid);
            $display("  Got:      Price=%0d, Qty=%0d, Valid=%0b", 
                     best_ask_price, best_ask_qty, best_ask_valid);
            test_failed++;
        end
    endtask

    // Main test sequence
    initial begin
        $display("=== Orderbook Testbench Started (Testing first 4 addresses per block) ===");
        $display("Valid address ranges: Block_N addresses [N*256 to N*256+3]");
        $display("Block 0: prices 27963-27966, Block 1: prices 28219-28222, etc.");
        
        // Initialize signals
        rst_n = 0;
        side_in = SIDE_BID;
        price_in = 0;
        delta_qty_in = 0;
        valid_in = 0;
        
        // Reset sequence
        repeat(5) @(posedge clk);
        rst_n = 1;
        repeat(2) @(posedge clk);
        
        $display("\n--- Test 1: Add single bid in Block 0 ---");
        add_order(SIDE_BID, 27963, 100); // Block 0, addr 0
        check_best_bid(27963, 100, 1'b1, "Single bid in block 0");
        
        $display("\n--- Test 2: Add higher bid in same block ---");
        add_order(SIDE_BID, 27965, 150); // Block 0, addr 2 (higher price)
        check_best_bid(27965, 150, 1'b1, "Higher bid in block 0");
        
        $display("\n--- Test 3: Add bid in Block 1 (should be highest) ---");
        add_order(SIDE_BID, 28219, 200); // Block 1, addr 256 (even higher)
        check_best_bid(28219, 200, 1'b1, "Bid in block 1 is highest");
        
        $display("\n--- Test 4: Add even higher bid in Block 2 ---");
        add_order(SIDE_BID, 28476, 75); // Block 2, addr 513
        check_best_bid(28476, 75, 1'b1, "Bid in block 2 is highest");
        
        $display("\n--- Test 5: Add ask in Block 1 ---");
        add_order(SIDE_ASK, 28220, 100); // Block 1, addr 257
        check_best_ask(28220, 100, 1'b1, "Single ask in block 1");
        
        $display("\n--- Test 6: Add lower ask in Block 0 (should be best) ---");
        add_order(SIDE_ASK, 27964, 125); // Block 0, addr 1 (lower price)
        check_best_ask(27964, 125, 1'b1, "Lower ask in block 0");
        
        $display("\n--- Test 7: Add another ask in Block 0 ---");
        add_order(SIDE_ASK, 27966, 175); // Block 0, addr 3
        check_best_ask(27964, 125, 1'b1, "Best ask unchanged");
        
        $display("\n--- Test 8: Update existing bid quantity in Block 1 ---");
        add_order(SIDE_BID, 28219, 50); // Add to existing at Block 1, addr 256
        check_best_bid(28476, 75, 1'b1, "Best bid unchanged after qty update");
        
        $display("\n--- Test 9: Remove best bid in Block 2 ---");
        add_order(SIDE_BID, 28476, -75); // Remove Block 2, addr 513
        check_best_bid(28219, 250, 1'b1, "Best bid now in block 1");
        
        $display("\n--- Test 10: Test across multiple blocks ---");
        add_order(SIDE_BID, 28475, 50);  // Block 2, addr 512
        add_order(SIDE_BID, 28731, 60);  // Block 3, addr 768
        add_order(SIDE_BID, 28987, 70);  // Block 4, addr 1024
        check_best_bid(28987, 70, 1'b1, "Highest bid in block 4");
        
        $display("\n--- Test 11: Add asks in multiple blocks ---");
        add_order(SIDE_ASK, 28477, 40);  // Block 2, addr 514
        add_order(SIDE_ASK, 28733, 45);  // Block 3, addr 770
        check_best_ask(27964, 125, 1'b1, "Best ask still in block 0");
        
        $display("\n--- Test 12: Test spread ---");
        $display("Current spread: %0d (Bid: %0d, Ask: %0d)", 
                 best_ask_price - best_bid_price, best_bid_price, best_ask_price);
        
        $display("\n--- Test 13: Multiple updates to Block 5 ---");
        add_order(SIDE_BID, 29243, 100); // Block 5, addr 1280
        add_order(SIDE_BID, 29244, 100); // Block 5, addr 1281
        add_order(SIDE_BID, 29245, 100); // Block 5, addr 1282
        check_best_bid(29245, 100, 1'b1, "Highest bid in block 5");
        
        $display("\n--- Test 14: Remove best and check new best ---");
        add_order(SIDE_BID, 29245, -100); // Remove Block 5, addr 1282
        check_best_bid(29244, 100, 1'b1, "New best after removal");
        
        // Summary
        $display("\n=== Test Summary ===");
        $display("Tests Passed: %0d", test_passed);
        $display("Tests Failed: %0d", test_failed);
        
        if (test_failed == 0) begin
            $display("\n*** ALL TESTS PASSED ***");
        end else begin
            $display("\n*** SOME TESTS FAILED ***");
        end
        
        $display("\n=== Orderbook Testbench Completed ===");
        $finish;
    end

    // Timeout watchdog (increased for longer reduction pipeline)
    initial begin
        #1000000;  // 1ms timeout (each order takes ~2.6us at 10ns period)
        $display("\nERROR: Testbench timeout!");
        $finish;
    end

endmodule
