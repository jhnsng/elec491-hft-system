`timescale 1ns/1ps

module orderbook_tb;

    import _pkg::*;

    // Parameters
    localparam BUFFER_SIZE = 4096;
    localparam LIMIT_DOWN_PRICE = 25895;
    localparam PRICE_WIDTH = 32;
    localparam QTY_WIDTH = 32;
    localparam CLK_PERIOD = 10;

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
        .QTY_WIDTH(QTY_WIDTH)
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
        @(posedge clk); // Wait for processing
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
        $display("=== Orderbook Testbench Started ===");
        
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
        
        $display("\n--- Test 1: Add single bid order ---");
        add_order(SIDE_BID, 29500, 100); // Price 295.00, Qty 100
        check_best_bid(29500, 100, 1'b1, "Single bid order");
        
        $display("\n--- Test 2: Add multiple bid orders ---");
        add_order(SIDE_BID, 29520, 150); // Price 295.20, Qty 150 (should be new best)
        check_best_bid(29520, 150, 1'b1, "Higher bid added");
        
        add_order(SIDE_BID, 29510, 200); // Price 295.10, Qty 200 (lower than current best)
        check_best_bid(29520, 150, 1'b1, "Lower bid added (best unchanged)");
        
        add_order(SIDE_BID, 29530, 75); // Price 295.30, Qty 75 (new highest)
        check_best_bid(29530, 75, 1'b1, "New highest bid");
        
        $display("\n--- Test 3: Add single ask order ---");
        add_order(SIDE_ASK, 29600, 100); // Price 296.00, Qty 100
        check_best_ask(29600, 100, 1'b1, "Single ask order");
        
        $display("\n--- Test 4: Add multiple ask orders ---");
        add_order(SIDE_ASK, 29580, 125); // Price 295.80, Qty 125 (should be new best - lower)
        check_best_ask(29580, 125, 1'b1, "Lower ask added");
        
        add_order(SIDE_ASK, 29590, 175); // Price 295.90, Qty 175 (higher than current best)
        check_best_ask(29580, 125, 1'b1, "Higher ask added (best unchanged)");
        
        add_order(SIDE_ASK, 29570, 90); // Price 295.70, Qty 90 (new lowest)
        check_best_ask(29570, 90, 1'b1, "New lowest ask");
        
        $display("\n--- Test 5: Update existing bid quantity ---");
        add_order(SIDE_BID, 29520, 50); // Add to existing order at 295.20
        check_best_bid(29530, 75, 1'b1, "Best bid unchanged after qty update");
        
        $display("\n--- Test 6: Remove order by making qty negative ---");
        add_order(SIDE_BID, 29530, -75); // Remove the best bid
        check_best_bid(29520, 200, 1'b1, "Best bid updated after removal");
        
        $display("\n--- Test 7: Add orders at price extremes ---");
        add_order(SIDE_BID, 29479, 50); // At limit down price (index 0)
        add_order(SIDE_BID, 29979, 60); // High price (index 500)
        check_best_bid(29979, 60, 1'b1, "Highest bid at high index");
        
        add_order(SIDE_ASK, 29480, 40); // Low ask (index 1)
        check_best_ask(29480, 40, 1'b1, "Lowest ask at low index");
        
        $display("\n--- Test 8: Test spread ---");
        $display("Current spread: %0d (Bid: %0d, Ask: %0d)", 
                 best_ask_price - best_bid_price, best_bid_price, best_ask_price);
        
        $display("\n--- Test 9: Multiple updates to same price level ---");
        add_order(SIDE_BID, 29550, 100);
        add_order(SIDE_BID, 29550, 100);
        add_order(SIDE_BID, 29550, 100);
        check_best_bid(29979, 60, 1'b1, "Best bid unchanged with mid-level updates");
        
        $display("\n--- Test 10: Remove best bid and check new best ---");
        add_order(SIDE_BID, 29979, -60); // Remove highest bid
        check_best_bid(29550, 300, 1'b1, "New best bid after top removal");
        
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

    // Timeout watchdog
    initial begin
        #100000;
        $display("\nERROR: Testbench timeout!");
        $finish;
    end

endmodule
