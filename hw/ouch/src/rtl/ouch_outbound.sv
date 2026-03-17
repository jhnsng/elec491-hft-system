//================================================================================
// OUCH 5.0 Outbound Parser (Nasdaq) - Algorithm Interface
// Receives Avalon-ST (32-bit Little Endian) -> Outputs Algorithm Signals
//
// Messages Parsed:
//   'A' Order Accepted
//   'C' Order Canceled
//   'E' Order Executed
//
// Latency:
//   - Buffers full packet to ensure validity before asserting algo_valid.
//   - Output valid 1 cycle after EOP.
//================================================================================
`timescale 1ns/1ps

module ouch_outbound (
    input  logic        clk,
    input  logic        rst_n,

    //=== INPUT: Avalon-ST Sink (32-bit Little Endian) ===
    input  logic [31:0] st_data,
    input  logic        st_valid,
    output logic        st_ready,
    input  logic        st_startofpacket,
    input  logic        st_endofpacket,
    input  logic [1:0]  st_empty,

    //=== OUTPUT: Algorithm Block Signals ===
    output logic        algo_valid, // *
    output logic [1:0]  algo_msg_type, // *
    output logic [63:0] algo_timestamp,
    output logic [31:0] algo_userref,
    output logic [31:0] algo_qty, // *
    output logic [63:0] algo_price, // *
    output logic [63:0] algo_symbol,
    output logic [7:0]  algo_side, // 
    output logic [63:0] algo_order_ref, // *
    output logic [63:0] algo_match_id, //
    output logic [7:0]  algo_reason // *
);

    // 1) Constants
    localparam logic [7:0] TYPE_ACCEPTED = 8'h41; // 'A'
    localparam logic [7:0] TYPE_CANCELED = 8'h43; // 'C'
    localparam logic [7:0] TYPE_EXECUTED = 8'h45; // 'E'

    // 2) Packet Buffer
    // Max size estimate: 'A' is ~66 bytes + appendages. 128 bytes is safe.
    logic [7:0] pkt_buf [0:127];
    logic [6:0] byte_idx;
    
    // Internal signal to trigger output generation
    logic       packet_complete; 

    // 3) State Machine
    typedef enum logic { ST_IDLE, ST_GATHER } state_t;
    state_t state;

    // Zero-Latency: We are always ready to accept data.
    // The logic processes data at wire speed.
    assign st_ready = 1'b1; 

    // 4) Byte Capture Logic
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state      <= ST_IDLE;
            byte_idx   <= 0;
            packet_complete <= 0;
        end else begin
            packet_complete <= 0; // Default pulse low

            case (state)
                ST_IDLE: begin
                    if (st_valid && st_startofpacket) begin
                        // Capture first word
                        pkt_buf[0] <= st_data[7:0];
                        pkt_buf[1] <= st_data[15:8];
                        pkt_buf[2] <= st_data[23:16];
                        pkt_buf[3] <= st_data[31:24];
                        
                        if (st_endofpacket) begin
                            // 1-cycle packet (Rare, but possible)
                            packet_complete <= 1;
                            state <= ST_IDLE; // Stay in IDLE for next packet
                        end else begin
                            byte_idx <= 7'd4;
                            state    <= ST_GATHER;
                        end
                    end
                end

                ST_GATHER: begin
                    if (st_valid) begin
                        // Calculate valid bytes in this beat
                        int valid_bytes;
                        valid_bytes = st_endofpacket ? (4 - st_empty) : 4;

                        // Store bytes
                        if (valid_bytes >= 1) pkt_buf[byte_idx]   <= st_data[7:0];
                        if (valid_bytes >= 2) pkt_buf[byte_idx+1] <= st_data[15:8];
                        if (valid_bytes >= 3) pkt_buf[byte_idx+2] <= st_data[23:16];
                        if (valid_bytes == 4) pkt_buf[byte_idx+3] <= st_data[31:24];

                        byte_idx <= byte_idx + valid_bytes[6:0];

                        if (st_endofpacket) begin
                            // Packet finished. Trigger output logic next cycle.
                            packet_complete <= 1;
                            
                            // Handling Back-to-Back (Zero Latency):
                            // If a new packet starts immediately in the NEXT cycle, 
                            // state must be IDLE to catch it.
                            // If a new packet starts NOW (SOP && EOP overlapping), 
                            // it would be a 1-cycle packet handled above.
                            state <= ST_IDLE;
                        end
                    end
                end
            endcase
        end
    end

    // 5) Parsing Logic (Output Generation)
    // This logic runs on the cycle AFTER EOP, using the stable data in pkt_buf.
    // Since pkt_buf is registered, it holds the old packet data even if 
    // the capture logic starts overwriting index 0 for a new packet in this same cycle.
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            algo_valid <= 0;
            algo_msg_type <= 0;
            // Clear other fields for simulation cleanliness
            algo_timestamp <= 0; algo_userref <= 0; algo_qty <= 0;
            algo_price <= 0; algo_symbol <= 0; algo_side <= 0;
            algo_order_ref <= 0; algo_match_id <= 0; algo_reason <= 0;
        end else begin
            algo_valid <= 0; // Default pulse

            if (packet_complete) begin
                algo_valid <= 1;
                
                // Common Header Fields
                algo_timestamp <= {pkt_buf[1], pkt_buf[2], pkt_buf[3], pkt_buf[4], pkt_buf[5], pkt_buf[6], pkt_buf[7], pkt_buf[8]};
                algo_userref   <= {pkt_buf[9], pkt_buf[10], pkt_buf[11], pkt_buf[12]};
                
                // Message Type Parsing
                case (pkt_buf[0])
                    TYPE_ACCEPTED: begin // 'A'
                        algo_msg_type  <= 2'd1;
                        algo_side      <= pkt_buf[13];
                        algo_qty       <= {pkt_buf[14], pkt_buf[15], pkt_buf[16], pkt_buf[17]};
                        algo_symbol    <= {pkt_buf[18], pkt_buf[19], pkt_buf[20], pkt_buf[21], pkt_buf[22], pkt_buf[23], pkt_buf[24], pkt_buf[25]};
                        algo_price     <= {pkt_buf[26], pkt_buf[27], pkt_buf[28], pkt_buf[29], pkt_buf[30], pkt_buf[31], pkt_buf[32], pkt_buf[33]};
                        algo_order_ref <= {pkt_buf[36], pkt_buf[37], pkt_buf[38], pkt_buf[39], pkt_buf[40], pkt_buf[41], pkt_buf[42], pkt_buf[43]};
                    end

                    TYPE_CANCELED: begin // 'C'
                        algo_msg_type  <= 2'd2;
                        algo_qty       <= {pkt_buf[13], pkt_buf[14], pkt_buf[15], pkt_buf[16]}; 
                        algo_reason    <= pkt_buf[17];
                    end

                    TYPE_EXECUTED: begin // 'E'
                        algo_msg_type  <= 2'd3;
                        algo_qty       <= {pkt_buf[13], pkt_buf[14], pkt_buf[15], pkt_buf[16]}; 
                        algo_price     <= {pkt_buf[17], pkt_buf[18], pkt_buf[19], pkt_buf[20], pkt_buf[21], pkt_buf[22], pkt_buf[23], pkt_buf[24]};
                        algo_match_id  <= {pkt_buf[26], pkt_buf[27], pkt_buf[28], pkt_buf[29], pkt_buf[30], pkt_buf[31], pkt_buf[32], pkt_buf[33]};
                    end
                    
                    default: algo_msg_type <= 2'd0;
                endcase
            end
        end
    end

endmodule
