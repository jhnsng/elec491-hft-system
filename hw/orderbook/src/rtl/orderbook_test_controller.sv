//-----------------------------------------------------
// Design Name : Orderbook Test Controller
// File Name   : orderbook_test_controller.sv
// Function    : Drives orderbook inputs from generated test vectors
// Controls    : Run mode streams vectors; debug mode steps one vector/button press
//-----------------------------------------------------

module orderbook_test_controller (
    input  logic        clk,
    input  logic        reset_n,
    
    // Physical inputs from DE1-SoC
    input  logic [9:0]  SW,          // Switches
    input  logic [3:0]  KEY,         // Pushbuttons (active low)
    output logic [9:0]  LEDR,        // LEDs for status
    
    // Outputs to orderbook
    output logic        side_out,
    output logic [31:0] price_out,
    output logic [31:0] delta_qty_out,
    output logic        valid_out
);

    // Generated vector include
    `include "orderbook_vectors_generated.svh"

    // Switch usage:
    // SW[9]   = Debug mode enable (1=step one vector per button press, 0=run continuously)
    // SW[8:2] = Start vector index
    // SW[1:0] = Reserved for display controller
    
    // KEY[0] = Reset (already used globally)
    // KEY[1] = Start stream (run mode) / step one vector (debug mode)
    
    logic debug_mode;
    logic [6:0] start_idx_sel;

    // Button and switch edge detection
    logic key1_prev;
    logic key1_pressed;
    logic [6:0] sw_idx_prev;
    logic sw_idx_changed;

    // Playback state
    logic stream_active;
    integer stream_index;
    integer debug_index;
    
    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            key1_prev <= 1'b1;
            sw_idx_prev <= 7'd0;
        end else begin
            key1_prev <= KEY[1];
            sw_idx_prev <= SW[8:2];
        end
    end

    assign debug_mode = SW[9];
    assign start_idx_sel = SW[8:2];
    assign key1_pressed = (key1_prev && !KEY[1]);
    assign sw_idx_changed = (sw_idx_prev != SW[8:2]);

    // Playback control and outputs
    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            stream_active <= 1'b0;
            stream_index <= 0;
            debug_index <= 0;

            side_out <= 1'b0;
            price_out <= 32'd0;
            delta_qty_out <= 32'sd0;
            valid_out <= 1'b0;
        end else begin
            // Latch valid high after first KEY[1] press; clear only on reset.
            if (key1_pressed) begin
                valid_out <= 1'b1;
            end

            if (debug_mode) begin
                // Keep run mode inactive while debugging.
                stream_active <= 1'b0;

                // If start index switch changes, move debug pointer.
                if (sw_idx_changed) begin
                    debug_index <= start_idx_sel;
                end

                // One message per button press.
                if (key1_pressed) begin
                    if ((ORDERBOOK_VECTOR_COUNT > 0) && (debug_index < ORDERBOOK_VECTOR_COUNT)) begin
                        side_out <= ORDERBOOK_VECTORS[debug_index].side;
                        price_out <= ORDERBOOK_VECTORS[debug_index].price;
                        delta_qty_out <= ORDERBOOK_VECTORS[debug_index].delta_qty;
                        debug_index <= debug_index + 1;
                    end
                end
            end else begin
                // KEY press starts continuous playback from selected index.
                if (key1_pressed) begin
                    if ((ORDERBOOK_VECTOR_COUNT > 0) && (start_idx_sel < ORDERBOOK_VECTOR_COUNT)) begin
                        stream_active <= 1'b1;
                        stream_index <= start_idx_sel;
                    end else begin
                        stream_active <= 1'b0;
                    end
                end

                // Stream one vector every clock cycle.
                if (stream_active) begin
                    if (stream_index < ORDERBOOK_VECTOR_COUNT) begin
                        side_out <= ORDERBOOK_VECTORS[stream_index].side;
                        price_out <= ORDERBOOK_VECTORS[stream_index].price;
                        delta_qty_out <= ORDERBOOK_VECTORS[stream_index].delta_qty;
                        stream_index <= stream_index + 1;
                    end else begin
                        stream_active <= 1'b0;
                    end
                end
            end
        end
    end

    // LED display: keep switch visibility and indicate stream activity.
    always_comb begin
        LEDR = SW;
        LEDR[8] = stream_active;
    end
    
endmodule
