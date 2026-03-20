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

    // Single clock/reset domain (50MHz)
    logic rst_n_sync;
    assign rst_n_sync = KEY[0];

    // Test controller outputs
    logic        test_side;
    logic [31:0] test_price;
    logic [31:0] test_qty;
    logic        test_valid;

    // Divided test-controller clock (200x slower edge rate than 50MHz).
    logic test_clk_div;

    // Orderbook outputs
    logic [31:0] best_bid_price;
    logic [31:0] best_bid_qty;
    logic [31:0] best_ask_price;
    logic [31:0] best_ask_qty;
    logic        best_valid;

    clock_divider #(
        .DIVIDE(200)
    ) u_test_ctrl_div (
        .clk         (CLOCK_50),
        .reset_n     (rst_n_sync),
        .clk_div     (test_clk_div)
    );

    /* ================================
        Test Controller (divided-clock domain)
        ================================ */
    orderbook_test_controller u_test_ctrl (
        .clk            (test_clk_div),
        .reset_n        (rst_n_sync),
        .SW             (SW),
        .KEY            (KEY),
        .LEDR           (LEDR),
        .side_out       (test_side),
        .price_out      (test_price),
        .delta_qty_out  (test_qty),
        .valid_out      (test_valid)
    );

    /* ================================
        Orderbook Module (50MHz domain)
        ================================ */
    orderbook u_orderbook (
        .clk             (CLOCK_50),
        .rst_n           (rst_n_sync),
        .side_in         (side_t'(test_side)),
        .price_in        (test_price),
        .delta_qty_in    (test_qty),
        .valid_in        (test_valid),
        .best_bid_price  (best_bid_price),
        .best_bid_qty    (best_bid_qty),
        .best_ask_price  (best_ask_price),
        .best_ask_qty    (best_ask_qty),
        .best_valid      (best_valid)
    );

    algorithm u_algorithm (
        .clk             (CLOCK_50),
        .rst_n           (rst_n_sync),

        .l1_valid       (best_valid),
        .l1_ready       (),
        .l1_symbol_id   (16'd0),
        .l1_ts_ns       (32'd0),
        .bb_p           (best_bid_price),
        .bb_q           (best_bid_qty),
        .ba_p           (best_ask_price),
        .ba_q           (best_ask_qty),

        .tok_req_valid  (),
        .tok_req_ready  (),
        .tok_req_symbol_id (),

        .tok_resp_valid (),
        .tok_resp_ready (),
        .tok_resp_symbol_id (),

        .ord_valid (),
        .ord_ready (),
        .ord_symbol_id (),
        .ord_action (),
        .ord_side (),
        .ord_price_int (),
        .ord_qty (),
        .ord_token_id (),
        
        .rpt_valid (),
        .rpt_ready (),
        .rpt_symbol_id (),
        .rpt_token_id (),
        .rpt_kind (),
        .rpt_filled_total ()
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
        .best_bid_price  (best_bid_price),
        .best_bid_qty    (best_bid_qty),
        .best_ask_price  (best_ask_price),
        .best_ask_qty    (best_ask_qty),
        .best_valid      (best_valid),
        .clk             (CLOCK_50),
        .reset_n         (rst_n_sync),
        .sw_price_qty    (SW[0]),  // SW[0]: 0=Price, 1=Quantity
        .sw_bid_ask      (SW[1])   // SW[1]: 0=Bid, 1=Ask
    );

endmodule
