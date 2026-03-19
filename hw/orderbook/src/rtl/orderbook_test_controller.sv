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
    // SW[8:2] = Vector sequence selection (1=ORDERBOOK_VECTORS1, 2=ORDERBOOK_VECTORS2, ...)
    // SW[1:0] = Reserved for display controller
    
    // KEY[0] = Reset (already used globally)
    // KEY[1] = Start selected stream (run mode) / step one message (debug mode)
    
    logic debug_mode;
    logic [6:0] vector_sel;

    // Button and switch edge detection
    logic key1_prev;
    logic key1_pressed;
    logic [6:0] sw_sel_prev;
    logic sw_sel_changed;

    // Valid pulse counter (reference behavior)
    logic [3:0] valid_pulse_counter;

    // Playback state
    logic stream_active;
    integer stream_msg_index;
    integer debug_msg_index;

    function automatic int get_vector_count(input logic [6:0] seq_sel);
        case (seq_sel)
            7'd1: get_vector_count = ORDERBOOK_VECTOR_COUNT1;
            7'd2: get_vector_count = ORDERBOOK_VECTOR_COUNT2;
            7'd3: get_vector_count = ORDERBOOK_VECTOR_COUNT3;
            default: get_vector_count = 0;
        endcase
    endfunction

    task automatic get_vector_fields(
        input  logic [6:0] seq_sel,
        input  integer idx,
        output logic side,
        output logic [31:0] price,
        output logic [31:0] delta_qty
    );
        begin
            side = 1'b0;
            price = 32'd0;
            delta_qty = 32'd0;
            case (seq_sel)
                7'd1: begin
                    side = ORDERBOOK_VECTORS1[idx].side;
                    price = ORDERBOOK_VECTORS1[idx].price;
                    delta_qty = ORDERBOOK_VECTORS1[idx].delta_qty;
                end
                7'd2: begin
                    side = ORDERBOOK_VECTORS2[idx].side;
                    price = ORDERBOOK_VECTORS2[idx].price;
                    delta_qty = ORDERBOOK_VECTORS2[idx].delta_qty;
                end
                7'd3: begin
                    side = ORDERBOOK_VECTORS3[idx].side;
                    price = ORDERBOOK_VECTORS3[idx].price;
                    delta_qty = ORDERBOOK_VECTORS3[idx].delta_qty;
                end
                default: begin
                    side = 1'b0;
                    price = 32'd0;
                    delta_qty = 32'd0;
                end
            endcase
        end
    endtask
    
    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            key1_prev <= 1'b1;
            sw_sel_prev <= 7'd0;
        end else begin
            key1_prev <= KEY[1];
            sw_sel_prev <= SW[8:2];
        end
    end

    assign debug_mode = SW[9];
    assign vector_sel = SW[8:2];
    assign key1_pressed = (key1_prev && !KEY[1]);
    assign sw_sel_changed = (sw_sel_prev != SW[8:2]);
    assign valid_out = (valid_pulse_counter > 0);

    // Playback control and outputs
    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            stream_active <= 1'b0;
            stream_msg_index <= 0;
            debug_msg_index <= 0;
            valid_pulse_counter <= 4'd0;

            side_out <= 1'b0;
            price_out <= 32'd0;
            delta_qty_out <= 32'sd0;
        end else begin
            // Reference behavior: KEY[1] triggers a fixed-width valid pulse.
            if (key1_pressed) begin
                valid_pulse_counter <= 4'd10;
            end else if (valid_pulse_counter > 0) begin
                valid_pulse_counter <= valid_pulse_counter - 1'b1;
            end

            if (debug_mode) begin
                // Keep run mode inactive while debugging.
                stream_active <= 1'b0;

                // If sequence selection changes, restart message index.
                if (sw_sel_changed) begin
                    debug_msg_index <= 0;
                end

                // One message per button press.
                if (key1_pressed) begin
                    if ((get_vector_count(vector_sel) > 0) && (debug_msg_index < get_vector_count(vector_sel))) begin
                        get_vector_fields(vector_sel, debug_msg_index, side_out, price_out, delta_qty_out);
                        debug_msg_index <= debug_msg_index + 1;
                    end
                end
            end else begin
                // If sequence selection changes, stop stream and reset index.
                if (sw_sel_changed) begin
                    stream_active <= 1'b0;
                    stream_msg_index <= 0;
                end

                // KEY press starts continuous playback of selected sequence from message 0.
                if (key1_pressed) begin
                    if (get_vector_count(vector_sel) > 0) begin
                        stream_active <= 1'b1;
                        stream_msg_index <= 0;
                    end else begin
                        stream_active <= 1'b0;
                    end
                end

                // Stream one vector every clock cycle.
                if (stream_active) begin
                    if (stream_msg_index <= get_vector_count(vector_sel)) begin
                        get_vector_fields(vector_sel, stream_msg_index, side_out, price_out, delta_qty_out);
                        stream_msg_index <= stream_msg_index + 1;
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
