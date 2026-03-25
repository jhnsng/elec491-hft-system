import _pkg::*;

module avalon_st_sink (
    input  logic        clk,
    input  logic        reset_n,

    // Avalon-ST interface
    input  logic [31:0] data,
    input  logic        valid,
    output logic        ready,
    input  logic        startofpacket,
    input  logic        endofpacket,
    input  logic [1:0]  empty,
    
    // Orderbook interface
    output logic               side_out,
    output logic [31:0]        price_out,
    output logic signed [31:0] delta_qty_out,  // Signed: positive=add, negative=cancel/execute
    output logic               valid_out
);

    // FSM states
    typedef enum logic [1:0] {
        IDLE,
        WAIT_HIGH,
        ERROR
    } state_t;
    
    state_t state, next_state;
    
    // Packet data storage
    logic [31:0] low_word;   // First word (quantity)
    logic [31:0] high_word;  // Second word (side + price>>2)
    
    // Output registers
    logic               side_reg;
    logic [31:0]        price_reg;
    logic signed [31:0] delta_qty_reg;  // Signed for cancel/execute
    logic               valid_reg;
    
    // Error tracking
    logic        error_flag;
    
    assign ready = 1'b1;  // Always ready to accept data
    
    // State machine
    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            state <= IDLE;
        end else begin
            state <= next_state;
        end
    end
    
    // Next state logic
    always_comb begin
        next_state = state;
        
        case (state)
            IDLE: begin
                if (valid && startofpacket && !endofpacket) begin
                    // Valid start of packet
                    next_state = WAIT_HIGH;
                end else if (valid && startofpacket && endofpacket) begin
                    // Error: SOP and EOP in same cycle (single-word packet)
                    next_state = ERROR;
                end else if (valid && endofpacket && !startofpacket) begin
                    // Error: EOP without SOP
                    next_state = ERROR;
                end
            end
            
            WAIT_HIGH: begin
                if (valid && endofpacket && !startofpacket) begin
                    // Valid end of packet
                    next_state = IDLE;
                end else if (valid && startofpacket) begin
                    // Error: unexpected SOP before EOP
                    next_state = ERROR;
                end
            end
            
            ERROR: begin
                // Return to IDLE on next valid SOP
                if (valid && startofpacket && !endofpacket) begin
                    next_state = WAIT_HIGH;
                end else if (!valid) begin
                    next_state = IDLE;
                end
            end
            
            default: next_state = IDLE;
        endcase
    end
    
    // Data capture and output generation
    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            low_word <= '0;
            high_word <= '0;
            side_reg <= 1'b0;
            price_reg <= '0;
            delta_qty_reg <= '0;
            valid_reg <= 1'b0;
            error_flag <= 1'b0;
            
        end else begin
            // Default: clear valid
            valid_reg <= 1'b0;
            
            case (state)
                IDLE: begin
                    error_flag <= 1'b0;
                    
                    if (valid && startofpacket && !endofpacket) begin
                        // Capture first word (quantity)
                        low_word <= data;
                    end else if (valid && (endofpacket || (startofpacket && endofpacket))) begin
                        // Error condition
                        error_flag <= 1'b1;
                    end
                end
                
                WAIT_HIGH: begin
                    if (valid && endofpacket && !startofpacket) begin
                        // Capture second word and decode
                        high_word <= data;
                        
                        // Byte swap from big-endian to little-endian
                        // Input data: 0x581b0000 = [31:24]=0x58, [23:16]=0x1b, [15:8]=0x00, [7:0]=0x00
                        // Swapped: 0x00001b58 = [31:24]=0x00, [23:16]=0x00, [15:8]=0x1b, [7:0]=0x58
                        // Bit reordering: {data[7:0], data[15:8], data[23:16], data[31:24]}
                        
                        side_reg <= data[7];  // MSB of swapped data (bit 31 after swap)
                        price_reg <= {data[5:0], data[15:8], data[23:16], data[31:24], 2'b00};  // Bits [29:0] of swapped, then << 2
                        delta_qty_reg <= low_word;
                        
                        // Assert valid output
                        valid_reg <= 1'b1;
                        
                    end else if (valid && startofpacket) begin
                        // Error: unexpected SOP
                        error_flag <= 1'b1;
                    end
                end
                
                ERROR: begin
                    // Stay in error state until recovery
                    error_flag <= 1'b1;
                    if (valid && startofpacket && !endofpacket) begin
                        low_word <= data;
                        error_flag <= 1'b0;
                    end
                end
            endcase
        end
    end
    
    // Output assignments
    assign side_out = side_reg;
    assign price_out = price_reg;
    assign delta_qty_out = delta_qty_reg;
    assign valid_out = valid_reg;

endmodule
