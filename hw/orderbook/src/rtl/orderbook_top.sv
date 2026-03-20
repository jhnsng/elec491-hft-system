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
    output logic [6:0]  HEX5,

    // Debug Virtual Pins for Algorithm I/O (Visible in SignalTap)
    output logic        debug_tok_req_valid,
    output logic        debug_ord_valid,
    output logic [1:0]  debug_ord_action,
    output logic        debug_ord_side,
    output logic [31:0] debug_ord_price,
    output logic [31:0] debug_ord_qty
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

    // Orderbook outputs (Kept for SignalTap visibility)
    (* keep = 1 *) logic [31:0] best_bid_price;
    (* keep = 1 *) logic [31:0] best_bid_qty;
    (* keep = 1 *) logic [31:0] best_ask_price;
    (* keep = 1 *) logic [31:0] best_ask_qty;
    (* keep = 1 *) logic        best_valid;

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
        .clk                (CLOCK_50),
        .rst_n              (rst_n_sync),

        // L1 Inputs from orderbook
        .l1_valid           (best_valid),
        .l1_ready           (),                 // Ignored by orderbook
        .l1_symbol_id       (16'd1),            // Hardcoded to AAPL ID
        .l1_ts_ns           (64'd0),            
        .bb_p               (best_bid_price),
        .bb_q               (best_bid_qty),
        .ba_p               (best_ask_price),
        .ba_q               (best_ask_qty),

        // Token Request Handshake
        .tok_req_valid      (debug_tok_req_valid),
        .tok_req_ready      (1'b1),             // MUST BE 1 to prevent FSM stall
        .tok_req_symbol_id  (),
        .tok_req_strat_id   (),

        // Token Response (Simulated Exchange)
        .tok_resp_valid     (1'b0),             
        .tok_resp_ready     (),
        .tok_resp_symbol_id (16'd0),
        .tok_resp_token_id  (32'd0),

        // Order Intent Handshake (Tied to Debug Virtual Pins)
        .ord_valid          (debug_ord_valid),
        .ord_ready          (1'b1),             // MUST BE 1 to prevent FSM stall
        .ord_symbol_id      (),
        .ord_action         (debug_ord_action),
        .ord_side           (debug_ord_side),
        .ord_price_int      (debug_ord_price),
        .ord_qty            (debug_ord_qty),
        .ord_token_id       (),
        
        // Order Report Feedback
        .rpt_valid          (1'b0),
        .rpt_ready          (),
        .rpt_symbol_id      (16'd0),
        .rpt_token_id       (32'd0),
        .rpt_kind           (2'b00),
        .rpt_filled_total   (32'd0)
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
