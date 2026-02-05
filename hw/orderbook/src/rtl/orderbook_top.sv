import _pkg::*;

module orderbook_top (
    // Clock
    input  logic        CLOCK_50,
    
    // Pushbuttons
    input  logic [3:0]  KEY,
    
    // Switches
    input  logic [9:0]  SW,
    
    // LEDs
    output logic [9:0]  LEDR,
    
    // Seven Segment Displays
    output logic [6:0]  HEX0,
    output logic [6:0]  HEX1,
    output logic [6:0]  HEX2,
    output logic [6:0]  HEX3,
    output logic [6:0]  HEX4,
    output logic [6:0]  HEX5
);

    // PLL signals
    logic pll_clk_150;          // PLL output clock 150MHz for orderbook
    logic pll_locked;           // PLL lock status
    logic rst_n_sync;           // Synchronized reset: active when KEY[0] AND pll_locked
    
    // Instantiate PLL (configured for 150MHz output)
    // Use CLOCK_50 directly for 50MHz domain (test controller and display)
    pll_ip u_pll (
        .clk_clk            (CLOCK_50),
        .reset_reset_n      (KEY[0]),
        .pll_0_outclk0_clk  (pll_clk_150),  // 150MHz for orderbook
        .pll_0_locked_export(pll_locked)
    );
    
    // Combine external reset with PLL lock status
    // System stays in reset until PLL is locked and external reset is released
    assign rst_n_sync = KEY[0] & pll_locked;

    // Test controller outputs (50MHz domain)
    logic        test_side_50;
    logic [31:0] test_price_50;
    logic [31:0] test_qty_50;
    logic        test_valid_50;
    
    // Test controller outputs synchronized to 150MHz domain
    logic        test_side_150;
    logic [31:0] test_price_150;
    logic [31:0] test_qty_150;
    logic        test_valid_150;
    
    // Orderbook outputs (150MHz domain)
    logic [31:0] best_bid_price_150;
    logic [31:0] best_bid_qty_150;
    logic        best_bid_valid_150;
    logic [31:0] best_ask_price_150;
    logic [31:0] best_ask_qty_150;
    logic        best_ask_valid_150;
    
    // Orderbook outputs synchronized to 50MHz domain
    logic [31:0] best_bid_price_50;
    logic [31:0] best_bid_qty_50;
    logic        best_bid_valid_50;
    logic [31:0] best_ask_price_50;
    logic [31:0] best_ask_qty_50;
    logic        best_ask_valid_50;

    /* ================================
        Test Controller for Manual Input (50MHz domain)
        ================================ */
    orderbook_test_controller u_test_ctrl (
        .clk            (CLOCK_50),
        .reset_n        (rst_n_sync),
        .SW             (SW),
        .KEY            (KEY),
        .LEDR           (LEDR),
        .side_out       (test_side_50),
        .price_out      (test_price_50),
        .delta_qty_out  (test_qty_50),
        .valid_out      (test_valid_50)
    );
    
    /* ================================
        CDC: Test Controller (50MHz) -> Orderbook (150MHz)
        ================================ */
    // Synchronize single-bit side signal
    cdc_sync_bit u_cdc_side (
        .src_bit    (test_side_50),
        .dst_clk    (pll_clk_150),
        .dst_rst_n  (rst_n_sync),
        .dst_bit    (test_side_150)
    );
    
    // Synchronize price bus
    cdc_sync_bus #(.WIDTH(32)) u_cdc_price (
        .src_clk    (CLOCK_50),
        .src_rst_n  (rst_n_sync),
        .src_data   (test_price_50),
        .src_valid  (test_valid_50),
        .dst_clk    (pll_clk_150),
        .dst_rst_n  (rst_n_sync),
        .dst_data   (test_price_150),
        .dst_valid  (test_valid_150)
    );
    
    // Synchronize quantity bus
    cdc_sync_bus #(.WIDTH(32)) u_cdc_qty (
        .src_clk    (CLOCK_50),
        .src_rst_n  (rst_n_sync),
        .src_data   (test_qty_50),
        .src_valid  (test_valid_50),
        .dst_clk    (pll_clk_150),
        .dst_rst_n  (rst_n_sync),
        .dst_data   (test_qty_150),
        .dst_valid  ()  // Not used, valid comes from price
    );

    /* ================================
        Orderbook Module (150MHz domain)
        ================================ */
    orderbook u_orderbook (
        .clk             (pll_clk_150),
        .rst_n           (rst_n_sync),
        .side_in         (side_t'(test_side_150)),
        .price_in        (test_price_150),
        .delta_qty_in    (test_qty_150),
        .valid_in        (test_valid_150),
        .best_bid_price  (best_bid_price_150),
        .best_bid_qty    (best_bid_qty_150),
        .best_bid_valid  (best_bid_valid_150),
        .best_ask_price  (best_ask_price_150),
        .best_ask_qty    (best_ask_qty_150),
        .best_ask_valid  (best_ask_valid_150)
    );
    
    /* ================================
        CDC: Orderbook (150MHz) -> Display (50MHz)
        ================================ */
    // Synchronize bid price
    cdc_sync_bus #(.WIDTH(32)) u_cdc_bid_price (
        .src_clk    (pll_clk_150),
        .src_rst_n  (rst_n_sync),
        .src_data   (best_bid_price_150),
        .src_valid  (best_bid_valid_150),
        .dst_clk    (CLOCK_50),
        .dst_rst_n  (rst_n_sync),
        .dst_data   (best_bid_price_50),
        .dst_valid  ()
    );
    
    // Synchronize bid quantity
    cdc_sync_bus #(.WIDTH(32)) u_cdc_bid_qty (
        .src_clk    (pll_clk_150),
        .src_rst_n  (rst_n_sync),
        .src_data   (best_bid_qty_150),
        .src_valid  (best_bid_valid_150),
        .dst_clk    (CLOCK_50),
        .dst_rst_n  (rst_n_sync),
        .dst_data   (best_bid_qty_50),
        .dst_valid  ()
    );
    
    // Synchronize bid valid
    cdc_sync_bit u_cdc_bid_valid (
        .src_bit    (best_bid_valid_150),
        .dst_clk    (CLOCK_50),
        .dst_rst_n  (rst_n_sync),
        .dst_bit    (best_bid_valid_50)
    );
    
    // Synchronize ask price
    cdc_sync_bus #(.WIDTH(32)) u_cdc_ask_price (
        .src_clk    (pll_clk_150),
        .src_rst_n  (rst_n_sync),
        .src_data   (best_ask_price_150),
        .src_valid  (best_ask_valid_150),
        .dst_clk    (CLOCK_50),
        .dst_rst_n  (rst_n_sync),
        .dst_data   (best_ask_price_50),
        .dst_valid  ()
    );
    
    // Synchronize ask quantity
    cdc_sync_bus #(.WIDTH(32)) u_cdc_ask_qty (
        .src_clk    (pll_clk_150),
        .src_rst_n  (rst_n_sync),
        .src_data   (best_ask_qty_150),
        .src_valid  (best_ask_valid_150),
        .dst_clk    (CLOCK_50),
        .dst_rst_n  (rst_n_sync),
        .dst_data   (best_ask_qty_50),
        .dst_valid  ()
    );
    
    // Synchronize ask valid
    cdc_sync_bit u_cdc_ask_valid (
        .src_bit    (best_ask_valid_150),
        .dst_clk    (CLOCK_50),
        .dst_rst_n  (rst_n_sync),
        .dst_bit    (best_ask_valid_50)
    );

    /* ================================
        Orderbook Display (50MHz domain)
        ================================ */
    orderbook_display u_display (
        .HEX0            (HEX0),
        .HEX1            (HEX1),
        .HEX2            (HEX2),
        .HEX3            (HEX3),
        .HEX4            (HEX4),
        .HEX5            (HEX5),
        .best_bid_price  (best_bid_price_50),
        .best_bid_qty    (best_bid_qty_50),
        .best_bid_valid  (best_bid_valid_50),
        .best_ask_price  (best_ask_price_50),
        .best_ask_qty    (best_ask_qty_50),
        .best_ask_valid  (best_ask_valid_50),
        .clk             (CLOCK_50),
        .reset_n         (rst_n_sync),
        .sw_price_qty    (SW[0]),  // SW[0]: 0=Price, 1=Quantity
        .sw_bid_ask      (SW[1])   // SW[1]: 0=Bid, 1=Ask
    );

endmodule
