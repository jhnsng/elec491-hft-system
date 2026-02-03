`timescale 1ns / 1ps

import _pkg::*;

module tb_orderbook_rmw;

    // Parameters
    parameter BUFFER_SIZE = 4096;
    parameter LIMIT_DOWN_PRICE = 27963;
    parameter PRICE_WIDTH = 25;
    parameter QTY_WIDTH = 32;
    parameter NUM_M10K_BLOCKS = BUFFER_SIZE / 256;
    
    // Clock period
    parameter CLK_PERIOD = 10;
    
    // DUT signals
    logic                     clk;
    logic                     rst_n;
    side_t                    side_in;
    logic [PRICE_WIDTH-1:0]   price_in;
    logic [QTY_WIDTH-1:0]     delta_qty_in;
    logic                     valid_in;
    logic [PRICE_WIDTH-1:0]   best_bid_price;
    logic [QTY_WIDTH-1:0]     best_bid_qty;
    logic                     best_bid_valid;
    logic [PRICE_WIDTH-1:0]   best_ask_price;
    logic [QTY_WIDTH-1:0]     best_ask_qty;
    logic                     best_ask_valid;
    
    // Testbench variables
    int test_count = 0;
    int pass_count = 0;
    int fail_count = 0;
    
    // DUT instantiation
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
    
    // Task to wait for clock cycles
    task wait_cycles(input int cycles);
        repeat(cycles) @(posedge clk);
    endtask
    
    // Task to reset the DUT
    task reset_dut();
        rst_n = 0;
        valid_in = 0;
        side_in = SIDE_BID;
        price_in = 0;
        delta_qty_in = 0;
        wait_cycles(5);
        rst_n = 1;
        wait_cycles(2);
        $display("[%0t] Reset complete, ready for testing", $time);
    endtask
    
    // Task to write to orderbook (non-blocking)
    task write_order(
        input side_t side,
        input logic [PRICE_WIDTH-1:0] price,
        input logic [QTY_WIDTH-1:0] delta_qty
    );
        @(posedge clk);
        side_in = side;
        price_in = price;
        delta_qty_in = delta_qty;
        valid_in = 1;
        @(posedge clk);
        valid_in = 0;
    endtask
    
    // Task to read quantity from memory (for verification)
    // Memory is 40-bit: [32:0] = entry_t {qty[31:0], valid[0]}, [39:33] = padding
    function logic [31:0] read_qty_from_mem(input int index, input side_t side);
        automatic int block_num = index / 256;
        automatic int block_addr = index % 256;
        automatic logic [39:0] mem_data;
        
        if (side == SIDE_BID) begin
            case (block_num)
                0:  mem_data = dut.gen_bid_m10k[0].bid_m10k.mem[block_addr];
                1:  mem_data = dut.gen_bid_m10k[1].bid_m10k.mem[block_addr];
                2:  mem_data = dut.gen_bid_m10k[2].bid_m10k.mem[block_addr];
                3:  mem_data = dut.gen_bid_m10k[3].bid_m10k.mem[block_addr];
                4:  mem_data = dut.gen_bid_m10k[4].bid_m10k.mem[block_addr];
                5:  mem_data = dut.gen_bid_m10k[5].bid_m10k.mem[block_addr];
                6:  mem_data = dut.gen_bid_m10k[6].bid_m10k.mem[block_addr];
                7:  mem_data = dut.gen_bid_m10k[7].bid_m10k.mem[block_addr];
                8:  mem_data = dut.gen_bid_m10k[8].bid_m10k.mem[block_addr];
                9:  mem_data = dut.gen_bid_m10k[9].bid_m10k.mem[block_addr];
                10: mem_data = dut.gen_bid_m10k[10].bid_m10k.mem[block_addr];
                11: mem_data = dut.gen_bid_m10k[11].bid_m10k.mem[block_addr];
                12: mem_data = dut.gen_bid_m10k[12].bid_m10k.mem[block_addr];
                13: mem_data = dut.gen_bid_m10k[13].bid_m10k.mem[block_addr];
                14: mem_data = dut.gen_bid_m10k[14].bid_m10k.mem[block_addr];
                15: mem_data = dut.gen_bid_m10k[15].bid_m10k.mem[block_addr];
                default: mem_data = 40'hDEADBEEF;
            endcase
        end else begin
            case (block_num)
                0:  mem_data = dut.gen_ask_m10k[0].ask_m10k.mem[block_addr];
                1:  mem_data = dut.gen_ask_m10k[1].ask_m10k.mem[block_addr];
                2:  mem_data = dut.gen_ask_m10k[2].ask_m10k.mem[block_addr];
                3:  mem_data = dut.gen_ask_m10k[3].ask_m10k.mem[block_addr];
                4:  mem_data = dut.gen_ask_m10k[4].ask_m10k.mem[block_addr];
                5:  mem_data = dut.gen_ask_m10k[5].ask_m10k.mem[block_addr];
                6:  mem_data = dut.gen_ask_m10k[6].ask_m10k.mem[block_addr];
                7:  mem_data = dut.gen_ask_m10k[7].ask_m10k.mem[block_addr];
                8:  mem_data = dut.gen_ask_m10k[8].ask_m10k.mem[block_addr];
                9:  mem_data = dut.gen_ask_m10k[9].ask_m10k.mem[block_addr];
                10: mem_data = dut.gen_ask_m10k[10].ask_m10k.mem[block_addr];
                11: mem_data = dut.gen_ask_m10k[11].ask_m10k.mem[block_addr];
                12: mem_data = dut.gen_ask_m10k[12].ask_m10k.mem[block_addr];
                13: mem_data = dut.gen_ask_m10k[13].ask_m10k.mem[block_addr];
                14: mem_data = dut.gen_ask_m10k[14].ask_m10k.mem[block_addr];
                15: mem_data = dut.gen_ask_m10k[15].ask_m10k.mem[block_addr];
                default: mem_data = 40'hDEADBEEF;
            endcase
        end
        
        // Extract qty from entry_t struct: bits [32:1] contain qty, bit [0] is valid
        return mem_data[32:1];
    endfunction
    
    // Function to read valid bit from memory
    function logic read_valid_from_mem(input int index, input side_t side);
        automatic int block_num = index / 256;
        automatic int block_addr = index % 256;
        automatic logic [39:0] mem_data;
        
        if (side == SIDE_BID) begin
            case (block_num)
                0:  mem_data = dut.gen_bid_m10k[0].bid_m10k.mem[block_addr];
                1:  mem_data = dut.gen_bid_m10k[1].bid_m10k.mem[block_addr];
                2:  mem_data = dut.gen_bid_m10k[2].bid_m10k.mem[block_addr];
                3:  mem_data = dut.gen_bid_m10k[3].bid_m10k.mem[block_addr];
                4:  mem_data = dut.gen_bid_m10k[4].bid_m10k.mem[block_addr];
                5:  mem_data = dut.gen_bid_m10k[5].bid_m10k.mem[block_addr];
                6:  mem_data = dut.gen_bid_m10k[6].bid_m10k.mem[block_addr];
                7:  mem_data = dut.gen_bid_m10k[7].bid_m10k.mem[block_addr];
                8:  mem_data = dut.gen_bid_m10k[8].bid_m10k.mem[block_addr];
                9:  mem_data = dut.gen_bid_m10k[9].bid_m10k.mem[block_addr];
                10: mem_data = dut.gen_bid_m10k[10].bid_m10k.mem[block_addr];
                11: mem_data = dut.gen_bid_m10k[11].bid_m10k.mem[block_addr];
                12: mem_data = dut.gen_bid_m10k[12].bid_m10k.mem[block_addr];
                13: mem_data = dut.gen_bid_m10k[13].bid_m10k.mem[block_addr];
                14: mem_data = dut.gen_bid_m10k[14].bid_m10k.mem[block_addr];
                15: mem_data = dut.gen_bid_m10k[15].bid_m10k.mem[block_addr];
                default: mem_data = 40'h0;
            endcase
        end else begin
            case (block_num)
                0:  mem_data = dut.gen_ask_m10k[0].ask_m10k.mem[block_addr];
                1:  mem_data = dut.gen_ask_m10k[1].ask_m10k.mem[block_addr];
                2:  mem_data = dut.gen_ask_m10k[2].ask_m10k.mem[block_addr];
                3:  mem_data = dut.gen_ask_m10k[3].ask_m10k.mem[block_addr];
                4:  mem_data = dut.gen_ask_m10k[4].ask_m10k.mem[block_addr];
                5:  mem_data = dut.gen_ask_m10k[5].ask_m10k.mem[block_addr];
                6:  mem_data = dut.gen_ask_m10k[6].ask_m10k.mem[block_addr];
                7:  mem_data = dut.gen_ask_m10k[7].ask_m10k.mem[block_addr];
                8:  mem_data = dut.gen_ask_m10k[8].ask_m10k.mem[block_addr];
                9:  mem_data = dut.gen_ask_m10k[9].ask_m10k.mem[block_addr];
                10: mem_data = dut.gen_ask_m10k[10].ask_m10k.mem[block_addr];
                11: mem_data = dut.gen_ask_m10k[11].ask_m10k.mem[block_addr];
                12: mem_data = dut.gen_ask_m10k[12].ask_m10k.mem[block_addr];
                13: mem_data = dut.gen_ask_m10k[13].ask_m10k.mem[block_addr];
                14: mem_data = dut.gen_ask_m10k[14].ask_m10k.mem[block_addr];
                15: mem_data = dut.gen_ask_m10k[15].ask_m10k.mem[block_addr];
                default: mem_data = 40'h0;
            endcase
        end
        
        // Extract valid bit from entry_t struct: bit [0] is valid
        return mem_data[0];
    endfunction
    
    // Task to verify result
    task verify_result(
        input string test_name,
        input int index,
        input side_t side,
        input logic [31:0] expected_qty,
        input logic expected_valid
    );
        logic [31:0] actual_qty;
        logic actual_valid;
        
        test_count++;
        
        actual_qty = read_qty_from_mem(index, side);
        actual_valid = read_valid_from_mem(index, side);
        
        if (actual_qty == expected_qty && actual_valid == expected_valid) begin
            $display("[PASS] %s: qty=%0d, valid=%0b (index=%0d, side=%s)", 
                     test_name, actual_qty, actual_valid, index, 
                     side == SIDE_BID ? "BID" : "ASK");
            pass_count++;
        end else begin
            $display("[FAIL] %s: Expected qty=%0d valid=%0b, Got qty=%0d valid=%0b (index=%0d, side=%s)",
                     test_name, expected_qty, expected_valid, actual_qty, actual_valid,
                     index, side == SIDE_BID ? "BID" : "ASK");
            fail_count++;
        end
    endtask
    
    // Main test sequence
    initial begin
        $display("========================================");
        $display("Orderbook Read-Modify-Write Testbench");
        $display("========================================");
        
        // Initialize
        reset_dut();
        
        // ====================================
        // Test 1: Write to new entry (3 cycles - RMW)
        // ====================================
        $display("\n[TEST 1] RMW - Write to new BID entry");
        write_order(SIDE_BID, LIMIT_DOWN_PRICE + 100, 1000);
        wait_cycles(4); // Wait for RMW to complete (3 cycles)
        verify_result("Test 1", 100, SIDE_BID, 1000, 1'b1);
        
        // ====================================
        // Test 2: Update existing entry (3 cycles - RMW)
        // ====================================
        $display("\n[TEST 2] RMW - Update existing BID entry");
        write_order(SIDE_BID, LIMIT_DOWN_PRICE + 100, 500);
        wait_cycles(4); // Wait for RMW to complete (3 cycles)
        verify_result("Test 2", 100, SIDE_BID, 1500, 1'b1);
        
        // ====================================
        // Test 3: Multiple updates to same address
        // ====================================
        $display("\n[TEST 3] Multiple updates to same address");
        write_order(SIDE_BID, LIMIT_DOWN_PRICE + 100, 250);
        wait_cycles(4);
        verify_result("Test 3a", 100, SIDE_BID, 1750, 1'b1);
        
        write_order(SIDE_BID, LIMIT_DOWN_PRICE + 100, -250);
        wait_cycles(4);
        verify_result("Test 3b", 100, SIDE_BID, 1500, 1'b1);
        
        // ====================================
        // Test 4: Write to zero
        // ====================================
        $display("\n[TEST 4] Write to zero quantity");
        write_order(SIDE_BID, LIMIT_DOWN_PRICE + 100, -1500);
        wait_cycles(4);
        verify_result("Test 4", 100, SIDE_BID, 0, 1'b0);
        
        // ====================================
        // Test 5: Write after clearing to zero
        // ====================================
        $display("\n[TEST 5] RMW - Write after clearing to zero");
        write_order(SIDE_BID, LIMIT_DOWN_PRICE + 100, 2000);
        wait_cycles(4);
        verify_result("Test 5", 100, SIDE_BID, 2000, 1'b1);
        
        // ====================================
        // Test 6: ASK side - RMW
        // ====================================
        $display("\n[TEST 6] ASK side - RMW");
        write_order(SIDE_ASK, LIMIT_DOWN_PRICE + 200, 3000);
        wait_cycles(4);
        verify_result("Test 6", 200, SIDE_ASK, 3000, 1'b1);
        
        // ====================================
        // Test 7: ASK side - Update existing entry
        // ====================================
        $display("\n[TEST 7] ASK side - Update existing entry (RMW)");
        write_order(SIDE_ASK, LIMIT_DOWN_PRICE + 200, 1000);
        wait_cycles(4);
        verify_result("Test 7", 200, SIDE_ASK, 4000, 1'b1);
        
        // ====================================
        // Test 8: Multiple different addresses
        // ====================================
        $display("\n[TEST 8] Multiple different addresses");
        write_order(SIDE_BID, LIMIT_DOWN_PRICE + 50, 100);
        wait_cycles(4);
        write_order(SIDE_BID, LIMIT_DOWN_PRICE + 150, 200);
        wait_cycles(4);
        write_order(SIDE_BID, LIMIT_DOWN_PRICE + 250, 300);
        wait_cycles(4);
        
        verify_result("Test 8a", 50, SIDE_BID, 100, 1'b1);
        verify_result("Test 8b", 150, SIDE_BID, 200, 1'b1);
        verify_result("Test 8c", 250, SIDE_BID, 300, 1'b1);
        
        // ====================================
        // Test 9: Cross M10K block boundary
        // ====================================
        $display("\n[TEST 9] Cross M10K block boundary");
        write_order(SIDE_BID, LIMIT_DOWN_PRICE + 255, 500);  // Block 0
        wait_cycles(4);
        write_order(SIDE_BID, LIMIT_DOWN_PRICE + 256, 600);  // Block 1
        wait_cycles(4);
        write_order(SIDE_BID, LIMIT_DOWN_PRICE + 512, 700);  // Block 2
        wait_cycles(4);
        
        verify_result("Test 9a", 255, SIDE_BID, 500, 1'b1);
        verify_result("Test 9b", 256, SIDE_BID, 600, 1'b1);
        verify_result("Test 9c", 512, SIDE_BID, 700, 1'b1);
        
        // ====================================
        // Test 10: Interleaved BID and ASK
        // ====================================
        $display("\n[TEST 10] Interleaved BID and ASK operations");
        write_order(SIDE_BID, LIMIT_DOWN_PRICE + 300, 1000);
        wait_cycles(4);
        write_order(SIDE_ASK, LIMIT_DOWN_PRICE + 300, 2000);
        wait_cycles(4);
        
        verify_result("Test 10a", 300, SIDE_BID, 1000, 1'b1);
        verify_result("Test 10b", 300, SIDE_ASK, 2000, 1'b1);
        
        // Update both
        write_order(SIDE_BID, LIMIT_DOWN_PRICE + 300, 500);
        wait_cycles(4);
        write_order(SIDE_ASK, LIMIT_DOWN_PRICE + 300, 500);
        wait_cycles(4);
        
        verify_result("Test 10c", 300, SIDE_BID, 1500, 1'b1);
        verify_result("Test 10d", 300, SIDE_ASK, 2500, 1'b1);
        
        // ====================================
        // Test Summary
        // ====================================
        $display("\n========================================");
        $display("Test Summary");
        $display("========================================");
        $display("Total Tests: %0d", test_count);
        $display("Passed:      %0d", pass_count);
        $display("Failed:      %0d", fail_count);
        $display("========================================");
        
        if (fail_count == 0) begin
            $display("ALL TESTS PASSED!");
        end else begin
            $display("SOME TESTS FAILED!");
        end
        
        $display("\nSimulation complete at time %0t", $time);
        $finish;
    end
    
    // Timeout watchdog
    initial begin
        #100000;
        $display("\n[ERROR] Simulation timeout!");
        $finish;
    end
    
    // Optional: Waveform dumping for debugging
    initial begin
        $dumpfile("tb_orderbook_rmw.vcd");
        $dumpvars(0, tb_orderbook_rmw);
    end

endmodule
