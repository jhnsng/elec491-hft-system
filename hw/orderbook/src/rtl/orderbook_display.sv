//-----------------------------------------------------
// Design Name : Orderbook Display Decoder
// File Name   : orderbook_display.sv
// Function    : Displays best bid/ask price/quantity on 7-segment displays
// Control     : SW[0] = Price(0)/Quantity(1), SW[1] = Bid(0)/Ask(1)
//-----------------------------------------------------

module orderbook_display (
    // 7-segment display outputs
    output logic [6:0] HEX0,
    output logic [6:0] HEX1,
    output logic [6:0] HEX2,
    output logic [6:0] HEX3,
    output logic [6:0] HEX4,
    output logic [6:0] HEX5,
    
    // Inputs from orderbook module
    input  logic [31:0] best_bid_price,
    input  logic [31:0] best_bid_qty,
    input  logic        best_bid_valid,
    input  logic [31:0] best_ask_price,
    input  logic [31:0] best_ask_qty,
    input  logic        best_ask_valid,
    
    // Control inputs
    input  logic        clk,
    input  logic        reset_n,
    input  logic        sw_price_qty,    // 0=price, 1=quantity
    input  logic        sw_bid_ask       // 0=bid, 1=ask
);

    // 7-segment encoding (active low)
    parameter logic [6:0] HEX_0 = 7'b1000000;  // 0
    parameter logic [6:0] HEX_1 = 7'b1111001;  // 1
    parameter logic [6:0] HEX_2 = 7'b0100100;  // 2
    parameter logic [6:0] HEX_3 = 7'b0110000;  // 3
    parameter logic [6:0] HEX_4 = 7'b0011001;  // 4
    parameter logic [6:0] HEX_5 = 7'b0010010;  // 5
    parameter logic [6:0] HEX_6 = 7'b0000010;  // 6
    parameter logic [6:0] HEX_7 = 7'b1111000;  // 7
    parameter logic [6:0] HEX_8 = 7'b0000000;  // 8
    parameter logic [6:0] HEX_9 = 7'b0011000;  // 9
    parameter logic [6:0] HEX_DASH = 7'b0111111;  // -
    parameter logic [6:0] HEX_BLANK = 7'b1111111; // blank
    parameter logic [6:0] HEX_E = 7'b0000110;  // E (for error)
    
    // Selected value to display
    logic [31:0] selected_value;
    logic        selected_valid;
    
    // BCD digits (6 digits for display)
    logic [3:0] digit[5:0];
    
    // Select which value to display based on switches
    always_comb begin
        case ({sw_bid_ask, sw_price_qty})
            2'b00: begin // Bid Price
                selected_value = best_bid_price;
                selected_valid = best_bid_valid;
            end
            2'b01: begin // Bid Quantity
                selected_value = best_bid_qty;
                selected_valid = best_bid_valid;
            end
            2'b10: begin // Ask Price
                selected_value = best_ask_price;
                selected_valid = best_ask_valid;
            end
            2'b11: begin // Ask Quantity
                selected_value = best_ask_qty;
                selected_valid = best_ask_valid;
            end
        endcase
    end
    
    // Binary to BCD conversion using double-dabble algorithm
    // For 32-bit input, we get up to 10 decimal digits
    // We'll extract the 6 least significant digits for display
    logic [31:0] binary_value;
    logic [43:0] bcd_temp; // 10 digits * 4 bits + 4 extra bits
    
    always_comb begin
        binary_value = selected_value;
        bcd_temp = 44'b0;
        
        // Double-dabble algorithm
        for (int i = 31; i >= 0; i--) begin
            // Add 3 to columns >= 5
            for (int j = 0; j < 11; j++) begin
                if (bcd_temp[j*4 +: 4] >= 5)
                    bcd_temp[j*4 +: 4] = bcd_temp[j*4 +: 4] + 3;
            end
            
            // Shift left
            bcd_temp = {bcd_temp[42:0], binary_value[i]};
        end
        
        // Extract 6 least significant decimal digits
        digit[0] = bcd_temp[3:0];   // Ones
        digit[1] = bcd_temp[7:4];   // Tens
        digit[2] = bcd_temp[11:8];  // Hundreds
        digit[3] = bcd_temp[15:12]; // Thousands
        digit[4] = bcd_temp[19:16]; // Ten thousands
        digit[5] = bcd_temp[23:20]; // Hundred thousands
    end
    
    // Determine if we need to show higher digits (overflow indicator)
    logic has_overflow;
    assign has_overflow = (bcd_temp[43:24] != 20'b0);
    
    // Convert BCD digits to 7-segment display
    function logic [6:0] bcd_to_7seg(input logic [3:0] bcd);
        case (bcd)
            4'h0: bcd_to_7seg = HEX_0;
            4'h1: bcd_to_7seg = HEX_1;
            4'h2: bcd_to_7seg = HEX_2;
            4'h3: bcd_to_7seg = HEX_3;
            4'h4: bcd_to_7seg = HEX_4;
            4'h5: bcd_to_7seg = HEX_5;
            4'h6: bcd_to_7seg = HEX_6;
            4'h7: bcd_to_7seg = HEX_7;
            4'h8: bcd_to_7seg = HEX_8;
            4'h9: bcd_to_7seg = HEX_9;
            default: bcd_to_7seg = HEX_BLANK;
        endcase
    endfunction
    
    // Update displays based on mode
    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            HEX0 <= HEX_BLANK;
            HEX1 <= HEX_BLANK;
            HEX2 <= HEX_BLANK;
            HEX3 <= HEX_BLANK;
            HEX4 <= HEX_BLANK;
            HEX5 <= HEX_BLANK;
        end else begin
            if (!selected_valid) begin
                // Display dashes when no valid data
                HEX0 <= HEX_DASH;
                HEX1 <= HEX_DASH;
                HEX2 <= HEX_DASH;
                HEX3 <= HEX_DASH;
                HEX4 <= HEX_DASH;
                HEX5 <= HEX_DASH;
            end else if (has_overflow) begin
                // Show "E" on highest display to indicate overflow
                HEX0 <= bcd_to_7seg(digit[0]);
                HEX1 <= bcd_to_7seg(digit[1]);
                HEX2 <= bcd_to_7seg(digit[2]);
                HEX3 <= bcd_to_7seg(digit[3]);
                HEX4 <= bcd_to_7seg(digit[4]);
                HEX5 <= HEX_E;  // Overflow indicator
            end else begin
                // Normal display
                HEX0 <= bcd_to_7seg(digit[0]);
                HEX1 <= bcd_to_7seg(digit[1]);
                HEX2 <= bcd_to_7seg(digit[2]);
                HEX3 <= bcd_to_7seg(digit[3]);
                HEX4 <= bcd_to_7seg(digit[4]);
                HEX5 <= bcd_to_7seg(digit[5]);
            end
        end
    end
    
endmodule
