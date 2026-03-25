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
    
    // Latency calculation: RMW (4 cycles with buffer) + REDUCE_SCAN (257 cycles: skip first + read 256 addresses) + REDUCE_TREE (5 cycles: 16→8→4→2→1→latch) = 266 cycles
    localparam ORDER_LATENCY = 266;

    // DUT signals
    logic                     clk;
    logic                     rst_n;
    side_t                    side_in;
    logic [PRICE_WIDTH-1:0]   price_in;
    logic [QTY_WIDTH-1:0]     delta_qty_in;
    logic                     valid_in;
    logic [PRICE_WIDTH-1:0]   best_bid_price;
    logic [QTY_WIDTH-1:0]     best_bid_qty;
    logic [PRICE_WIDTH-1:0]   best_ask_price;
    logic [QTY_WIDTH-1:0]     best_ask_qty;
    logic                     best_valid;

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
        .best_bid_price(best_bid_price),
        .best_bid_qty(best_bid_qty),
        .best_ask_price(best_ask_price),
        .best_ask_qty(best_ask_qty),
        .best_valid(best_valid)
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
        repeat(ORDER_LATENCY + 1.5) @(posedge clk);
    endtask

    // Task to check best bid
    task check_best_bid(
        input logic [PRICE_WIDTH-1:0] expected_price,
        input logic [QTY_WIDTH-1:0] expected_qty,
        input string test_name
    );
        if (best_bid_price === expected_price && 
            best_bid_qty === expected_qty && 
            best_valid === 1'b1) begin
            $display("PASS: %s - Best Bid: Price=%0d, Qty=%0d, Valid=%0b", 
                     test_name, best_bid_price, best_bid_qty, best_valid);
            test_passed++;
        end else begin
            $display("[%0t] FAIL: %s", $time, test_name);
            $display("  Expected: Price=%0d, Qty=%0d, Valid=1", 
                     expected_price, expected_qty);
            $display("  Got:      Price=%0d, Qty=%0d, Valid=%0b", 
                     best_bid_price, best_bid_qty, best_valid);
            test_failed++;
        end
    endtask

    // Task to check best ask
    task check_best_ask(
        input logic [PRICE_WIDTH-1:0] expected_price,
        input logic [QTY_WIDTH-1:0] expected_qty,
        input string test_name
    );
        if (best_ask_price === expected_price && 
            best_ask_qty === expected_qty && 
            best_valid === 1'b1) begin
            $display("PASS: %s - Best Ask: Price=%0d, Qty=%0d, Valid=%0b", 
                     test_name, best_ask_price, best_ask_qty, best_valid);
            test_passed++;
        end else begin
            $display("[%0t] FAIL: %s", $time, test_name);
            $display("  Expected: Price=%0d, Qty=%0d, Valid=1", 
                     expected_price, expected_qty);
            $display("  Got:      Price=%0d, Qty=%0d, Valid=%0b", 
                     best_ask_price, best_ask_qty, best_valid);
            test_failed++;
        end
    endtask

    // Main test sequence
    initial begin
        $display("=== Orderbook Testbench Started (Full 256 address scan per block) ===");
        $display("Each M10K block scans all 256 addresses");
        $display("Block 0: prices 27963-28218, Block 1: prices 28219-28474, etc.");
        
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
        
        $display("\n--- Test 1: Add single bid at start of Block 0 ---");
        add_order(SIDE_BID, 27963, 100); // Block 0, addr 0
        check_best_bid(27963, 100, "Single bid at block 0 start");
        
        $display("\n--- Test 2: Add higher bid in middle of Block 0 ---");
        add_order(SIDE_BID, 28090, 150); // Block 0, addr 127 (middle)
        check_best_bid(28090, 150, "Higher bid in middle of block 0");
        
        $display("\n--- Test 3: Add bid at end of Block 0 ---");
        add_order(SIDE_BID, 28218, 200); // Block 0, addr 255 (end)
        check_best_bid(28218, 200, "Bid at end of block 0 is highest");
        
        $display("\n--- Test 4: Add bid in middle of Block 2 ---");
        add_order(SIDE_BID, 28603, 75); // Block 2, addr 640 (128 into block 2)
        check_best_bid(28603, 75, "Bid in block 2 is highest");
        
        $display("\n--- Test 5: Add ask at start of Block 1 ---");
        add_order(SIDE_ASK, 28219, 100); // Block 1, addr 256
        check_best_ask(28219, 100, "Single ask at block 1 start");
        
        $display("\n--- Test 6: Add lower ask near start of Block 0 ---");
        add_order(SIDE_ASK, 27975, 125); // Block 0, addr 12
        check_best_ask(27975, 125, "Lower ask near start of block 0");
        
        $display("\n--- Test 7: Add another ask in Block 0 (not best) ---");
        add_order(SIDE_ASK, 28050, 175); // Block 0, addr 87
        check_best_ask(27975, 125, "Best ask unchanged");
        
        $display("\n--- Test 8: Update existing bid quantity ---");
        add_order(SIDE_BID, 28218, 50); // Add to existing at Block 0, addr 255
        check_best_bid(28603, 75, "Best bid unchanged after qty update");
        
        $display("\n--- Test 9: Remove best bid in Block 2 ---");
        add_order(SIDE_BID, 28603, -75); // Remove Block 2, addr 640
        check_best_bid(28218, 250, "Best bid now at end of block 0");
        
        $display("\n--- Test 10: Test across multiple blocks with varied addresses ---");
        add_order(SIDE_BID, 28550, 50);  // Block 2, addr 587
        add_order(SIDE_BID, 28800, 60);  // Block 3, addr 837
        add_order(SIDE_BID, 29100, 70);  // Block 4, addr 1137
        check_best_bid(29100, 70, "Highest bid in block 4");
        
        $display("\n--- Test 11: Add asks at various positions ---");
        add_order(SIDE_ASK, 28350, 40);  // Block 1, addr 387
        add_order(SIDE_ASK, 28700, 45);  // Block 2, addr 737
        check_best_ask(27975, 125, "Best ask still in block 0");
        
        $display("\n--- Test 12: Test spread ---");
        $display("Current spread: %0d (Bid: %0d, Ask: %0d)", 
                 best_ask_price - best_bid_price, best_bid_price, best_ask_price);
        
        $display("\n--- Test 13: Test high addresses in Block 15 ---");
        add_order(SIDE_BID, 31900, 100); // Block 15, addr 3937
        add_order(SIDE_BID, 32000, 150); // Block 15, addr 4037 (high end)
        check_best_bid(32000, 150, "Highest bid near end of address space");
        
        $display("\n--- Test 14: Add ask at very low address ---");
        add_order(SIDE_ASK, 27964, 80); // Block 0, addr 1
        check_best_ask(27964, 80, "Lowest ask at start of range");
        
        $display("\n--- Test 15: Remove best bid and check fallback ---");
        add_order(SIDE_BID, 32000, -150); // Remove highest
        check_best_bid(31900, 100, "Best bid falls back to previous");
        
        $display("\n--- Test 16: Test boundary between blocks ---");
        add_order(SIDE_BID, 28217, 90); // Block 0, addr 254 (near end)
        add_order(SIDE_BID, 28220, 95); // Block 1, addr 257 (just into block 1)
        check_best_bid(31900, 100, "Best bid still in block 15");
        
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
        #10000000;  // 10ms timeout (each order takes ~2.66us at 10ns period with 266 cycle latency)
        $display("\nERROR: Testbench timeout!");
        $finish;
    end

endmodule
