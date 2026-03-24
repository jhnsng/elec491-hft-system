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
    // SW[9]   = Streaming mode arm (1=KEY[1] starts full stream, 0=debug step mode)
    // SW[8:2] = Vector sequence selection (1=ORDERBOOK_VECTORS1, 2=ORDERBOOK_VECTORS2, ...)
    // SW[1:0] = Reserved for display controller
    
    // KEY[0] = Reset (already used globally)
    // KEY[1] = Start stream (when SW[9]=1) / step one message (when SW[9]=0)
    
    logic stream_mode;
    logic [6:0] vector_sel;

    // Button and switch edge detection
    logic key1_prev;
    logic key1_pressed;
    logic [6:0] sw_sel_prev;
    logic sw_sel_changed;

    // High for one cycle when a new vector is emitted.
    logic valid_emit;

    // Playback state
    typedef enum logic {
        ST_IDLE_DEBUG,
        ST_STREAMING
    } state_t;

    state_t current_state;
    state_t next_state;

    logic stream_active;
    integer stream_msg_index;
    integer debug_msg_index;
    logic [6:0] stream_vector_sel;

    function automatic int get_vector_count(input logic [6:0] seq_sel);
    case (seq_sel)
        7'd1:  get_vector_count = $size(ORDERBOOK_VECTORS1);
        7'd2:  get_vector_count = $size(ORDERBOOK_VECTORS2);
        7'd3:  get_vector_count = $size(ORDERBOOK_VECTORS3);
        7'd4:  get_vector_count = $size(ORDERBOOK_VECTORS4);
        7'd5:  get_vector_count = $size(ORDERBOOK_VECTORS5);
        7'd6:  get_vector_count = $size(ORDERBOOK_VECTORS6);
        7'd7:  get_vector_count = $size(ORDERBOOK_VECTORS7);
        7'd8:  get_vector_count = $size(ORDERBOOK_VECTORS8);
        7'd9:  get_vector_count = $size(ORDERBOOK_VECTORS9);
        7'd10: get_vector_count = $size(ORDERBOOK_VECTORS10);
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
            side      = 1'b0;
            price     = 32'd0;
            delta_qty = 32'd0;
            case (seq_sel)
                7'd1:  begin side = ORDERBOOK_VECTORS1[idx].side;  price = ORDERBOOK_VECTORS1[idx].price;  delta_qty = ORDERBOOK_VECTORS1[idx].delta_qty;  end
                7'd2:  begin side = ORDERBOOK_VECTORS2[idx].side;  price = ORDERBOOK_VECTORS2[idx].price;  delta_qty = ORDERBOOK_VECTORS2[idx].delta_qty;  end
                7'd3:  begin side = ORDERBOOK_VECTORS3[idx].side;  price = ORDERBOOK_VECTORS3[idx].price;  delta_qty = ORDERBOOK_VECTORS3[idx].delta_qty;  end
                7'd4:  begin side = ORDERBOOK_VECTORS4[idx].side;  price = ORDERBOOK_VECTORS4[idx].price;  delta_qty = ORDERBOOK_VECTORS4[idx].delta_qty;  end
                7'd5:  begin side = ORDERBOOK_VECTORS5[idx].side;  price = ORDERBOOK_VECTORS5[idx].price;  delta_qty = ORDERBOOK_VECTORS5[idx].delta_qty;  end
                7'd6:  begin side = ORDERBOOK_VECTORS6[idx].side;  price = ORDERBOOK_VECTORS6[idx].price;  delta_qty = ORDERBOOK_VECTORS6[idx].delta_qty;  end
                7'd7:  begin side = ORDERBOOK_VECTORS7[idx].side;  price = ORDERBOOK_VECTORS7[idx].price;  delta_qty = ORDERBOOK_VECTORS7[idx].delta_qty;  end
                7'd8:  begin side = ORDERBOOK_VECTORS8[idx].side;  price = ORDERBOOK_VECTORS8[idx].price;  delta_qty = ORDERBOOK_VECTORS8[idx].delta_qty;  end
                7'd9:  begin side = ORDERBOOK_VECTORS9[idx].side;  price = ORDERBOOK_VECTORS9[idx].price;  delta_qty = ORDERBOOK_VECTORS9[idx].delta_qty;  end
                7'd10: begin side = ORDERBOOK_VECTORS10[idx].side; price = ORDERBOOK_VECTORS10[idx].price; delta_qty = ORDERBOOK_VECTORS10[idx].delta_qty; end
                default: ;
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

    assign stream_mode = SW[9];
    assign vector_sel = SW[8:2];
    assign key1_pressed = (key1_prev && !KEY[1]);
    assign sw_sel_changed = (sw_sel_prev != SW[8:2]);
    assign valid_out = valid_emit;
    assign stream_active = (current_state == ST_STREAMING);

    // FSM next-state logic.
    always_comb begin
        next_state = current_state;

        case (current_state)
            ST_IDLE_DEBUG: begin
                if (stream_mode && key1_pressed && (get_vector_count(vector_sel) > 0)) begin
                    next_state = ST_STREAMING;
                end
            end

            ST_STREAMING: begin
                if (stream_msg_index >= get_vector_count(stream_vector_sel)) begin
                    next_state = ST_IDLE_DEBUG;
                end
            end

            default: begin
                next_state = ST_IDLE_DEBUG;
            end
        endcase
    end

    // Playback control and outputs (sequential actions by current state).
    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            current_state <= ST_IDLE_DEBUG;
            stream_msg_index <= 0;
            debug_msg_index <= 0;
            stream_vector_sel <= 7'd0;
            valid_emit <= 1'b0;

            side_out <= 1'b0;
            price_out <= 32'd0;
            delta_qty_out <= 32'sd0;
        end else begin
            current_state <= next_state;

            // Default low; set high only when a new vector is loaded.
            valid_emit <= 1'b0;

            case (current_state)
                ST_IDLE_DEBUG: begin
                    // Debug stepping only when SW[9] is low.
                    if (!stream_mode) begin
                        if (sw_sel_changed) begin
                            debug_msg_index <= 0;
                        end

                        if (key1_pressed) begin
                            if ((get_vector_count(vector_sel) > 0) && (debug_msg_index < get_vector_count(vector_sel))) begin
                                get_vector_fields(vector_sel, debug_msg_index, side_out, price_out, delta_qty_out);
                                valid_emit <= 1'b1;
                                debug_msg_index <= debug_msg_index + 1;
                            end
                        end
                    end
                end

                ST_STREAMING: begin
                    // Stream using latched selection captured at stream start.
                    if (stream_msg_index < get_vector_count(vector_sel)) begin
                        get_vector_fields(vector_sel, stream_msg_index, side_out, price_out, delta_qty_out);
                        valid_emit <= 1'b1;
                        stream_msg_index <= stream_msg_index + 1;
                    end
                end

                default: begin
                    // Safe default: hold registers, state recovery handled by next_state.
                end
            endcase
        end
    end

    // LED display: keep switch visibility and indicate stream activity.
    always_comb begin
        LEDR = SW;
        LEDR[8] = stream_active;
    end
    
endmodule
