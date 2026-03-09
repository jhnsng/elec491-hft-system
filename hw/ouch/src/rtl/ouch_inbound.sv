//================================================================================
// OUCH 5.0 Inbound Formatter (Nasdaq) - Enter Order 'O' + Cancel 'X'
// Avalon-ST output (byte stream), one OUCH message == one Avalon-ST "packet"
//
// Inbound messages implemented:
//   'O' Enter Order (47 bytes base, no appendage)
//   'X' Cancel Order (11 bytes base, no appendage)
//
// Outbound messages (from exchange) such as 'A','C','E' are NOT generated here
// They require a separate OUCH outbound parser module
//
// Avalon-ST refs:
// - valid/ready handshaking and packet signals sop/eop are defined by Avalon-ST
//================================================================================
`timescale 1ns/1ps

module ouch_inbound (
    input  logic        clk,
    input  logic        rst_n,

    //=== INPUT: Algorithm Block Commands ===
    input  logic        algo_cmd_valid,
    output logic        algo_cmd_ready,
    input  logic [1:0]  algo_cmd_type, // 0=Enter, 1=Cancel
    input  logic [31:0] algo_qty,
    input  logic [1:0]  algo_side,
    input  logic [63:0] algo_symbol,
    input  logic [63:0] algo_price_ticks,
    input  logic [31:0] algo_orig_ref,

    //=== OUTPUT: Avalon-ST Source (32-bit Little Endian) ===
    output logic [31:0] st_data,
    output logic        st_valid,
    input  logic        st_ready,
    output logic        st_startofpacket,
    output logic        st_endofpacket,
    output logic [1:0]  st_empty
);

    // 1) Constants
    localparam logic [7:0] OUCH_TYPE_ADD    = 8'h4F; // 'O'
    localparam logic [7:0] OUCH_TYPE_CANCEL = 8'h58; // 'X'
    
    localparam int unsigned ADD_MSG_BYTES    = 47; 
    localparam int unsigned CANCEL_MSG_BYTES = 11;

    localparam logic [7:0] TIF_DAY         = 8'h30; // 'O'
    localparam logic [7:0] DISPLAY_VISIBLE = 8'h59; // 'Y'
    localparam logic [7:0] CAPACITY_PRIN   = 8'h50; // 'P'
    localparam logic [7:0] IMS_INELIG      = 8'h4E; // 'N'
    localparam logic [7:0] CROSS_NORMAL    = 8'h4E; // 'N'
    localparam logic [7:0] SPACE           = 8'h20; // ' '

    // 2) FIFO Definitions
    typedef struct packed {
        logic [1:0]  cmd_type;
        logic [31:0] qty;
        logic [1:0]  side;
        logic [63:0] symbol;
        logic [63:0] price;
        logic [31:0] userref;
    } cmd_t;

    cmd_t fifo_mem [0:7];
    logic [2:0] wr_ptr, rd_ptr;
    logic [3:0] fifo_count;
    logic       fifo_full, fifo_empty;
    logic       push, pop; 
    logic [31:0] userref_counter;

    assign fifo_full      = (fifo_count == 4'd8);
    assign fifo_empty     = (fifo_count == 4'd0);
    assign algo_cmd_ready = ~fifo_full;
    assign push           = algo_cmd_valid && algo_cmd_ready;

    // FIFO Write Logic
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            wr_ptr          <= 3'd0;
            fifo_count      <= 4'd0;
            userref_counter <= 32'd1;
        end else begin
            if (push) begin
                fifo_mem[wr_ptr].cmd_type <= algo_cmd_type;
                fifo_mem[wr_ptr].qty      <= algo_qty;
                fifo_mem[wr_ptr].side     <= algo_side;
                fifo_mem[wr_ptr].symbol   <= algo_symbol;
                fifo_mem[wr_ptr].price    <= algo_price_ticks;
                fifo_mem[wr_ptr].userref  <= (algo_cmd_type == 2'b00) ? userref_counter : algo_orig_ref;
                
                wr_ptr <= wr_ptr + 3'd1;
                if (algo_cmd_type == 2'b00) userref_counter <= userref_counter + 32'd1;
            end

            // Count Update 
            if (push && !pop)      fifo_count <= fifo_count + 4'd1;
            else if (!push && pop) fifo_count <= fifo_count - 4'd1;
        end
    end

    // FIFO Read Pointer Update
    always_ff @(posedge clk) begin
        if (!rst_n) rd_ptr <= 3'd0;
        else if (pop) rd_ptr <= rd_ptr + 3'd1;
    end

    // 3) Serializer State Machine
    typedef enum logic [1:0] { ST_IDLE, ST_STREAM } state_t;
    state_t state;

    cmd_t        cmd_r;           
    logic [3:0]  word_count;      
    logic [3:0]  target_words;    
    logic [1:0]  final_empty;     

    // Helper to calculate packet length parameters
    function automatic void calc_packet_params(input logic [1:0] type_in, output logic [3:0] tw, output logic [1:0] fe);
        if (type_in == 2'b00) begin
            tw = (ADD_MSG_BYTES + 3) >> 2; 
            fe = 2'd1; 
        end else begin
            tw = (CANCEL_MSG_BYTES + 3) >> 2; 
            fe = 2'd1;
        end
    endfunction

    // Logic to load new command
    logic load_next;
    logic packet_done;
    
    assign packet_done = (state == ST_STREAM) && st_ready && (word_count == target_words - 1);

    // We pop when we are finishing a packet AND we are loading the NEXT one, 
    // OR when we are IDLE and starting the first one.
    // To simplify: Pop whenever we commit to consuming a FIFO entry.
    // In IDLE: Pop if !empty.
    // In STREAM: Pop if packet_done AND !empty (chaining).
    assign pop = (state == ST_IDLE && !fifo_empty) || (packet_done && !fifo_empty);

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state      <= ST_IDLE;
            word_count <= 0;
            cmd_r      <= '0;
        end else begin
            case (state)
                ST_IDLE: begin
                    if (!fifo_empty) begin
                        // Zero-latency start
                        cmd_r <= fifo_mem[rd_ptr];
                        calc_packet_params(fifo_mem[rd_ptr].cmd_type, target_words, final_empty);
                        
                        state <= ST_STREAM;
                        word_count <= 0;
                    end
                end

                ST_STREAM: begin
                    if (st_ready) begin
                        if (word_count == target_words - 1) begin
                            // Packet Complete. Check for chaining.
                            if (!fifo_empty) begin
                                // Chain immediately
                                cmd_r <= fifo_mem[rd_ptr];
                                calc_packet_params(fifo_mem[rd_ptr].cmd_type, target_words, final_empty);
                                word_count <= 0;
                                // State remains ST_STREAM
                            end else begin
                                state <= ST_IDLE;
                            end
                        end else begin
                            word_count <= word_count + 1;
                        end
                    end
                end
            endcase
        end
    end

    // 4) Byte Multiplexer (Combinational)
    logic [7:0] b0, b1, b2, b3;
    
    function automatic logic [7:0] get_ouch_byte(input [5:0] byte_idx);
        if (cmd_r.cmd_type == 2'b00) begin // === ENTER ORDER ===
            case (byte_idx)
                6'd0:  return OUCH_TYPE_ADD;
                6'd1:  return cmd_r.userref[31:24];
                6'd2:  return cmd_r.userref[23:16];
                6'd3:  return cmd_r.userref[15:8];
                6'd4:  return cmd_r.userref[7:0];
                6'd5:  return (cmd_r.side == 2'b00) ? 8'h42 : 8'h53; 
                6'd6:  return cmd_r.qty[31:24];
                6'd7:  return cmd_r.qty[23:16];
                6'd8:  return cmd_r.qty[15:8];
                6'd9:  return cmd_r.qty[7:0];
                // Symbol
                6'd10: return cmd_r.symbol[63:56];
                6'd11: return cmd_r.symbol[55:48];
                6'd12: return cmd_r.symbol[47:40];
                6'd13: return cmd_r.symbol[39:32];
                6'd14: return cmd_r.symbol[31:24];
                6'd15: return cmd_r.symbol[23:16];
                6'd16: return cmd_r.symbol[15:8];
                6'd17: return cmd_r.symbol[7:0];
                // Price
                6'd18: return cmd_r.price[63:56];
                6'd19: return cmd_r.price[55:48];
                6'd20: return cmd_r.price[47:40];
                6'd21: return cmd_r.price[39:32];
                6'd22: return cmd_r.price[31:24];
                6'd23: return cmd_r.price[23:16];
                6'd24: return cmd_r.price[15:8];
                6'd25: return cmd_r.price[7:0];
                // Fixed Fields
                6'd26: return TIF_DAY;
                6'd27: return DISPLAY_VISIBLE;
                6'd28: return CAPACITY_PRIN;
                6'd29: return IMS_INELIG;
                6'd30: return CROSS_NORMAL;
                // ClOrdID (Spaces)
                6'd31, 6'd32, 6'd33, 6'd34, 6'd35, 6'd36, 6'd37, 
                6'd38, 6'd39, 6'd40, 6'd41, 6'd42, 6'd43, 6'd44: return SPACE;
                // Appendage
                6'd45, 6'd46: return 8'h00;
                default: return 8'h00;
            endcase
        end else begin // === CANCEL ORDER ===
            case (byte_idx)
                6'd0:  return OUCH_TYPE_CANCEL;
                6'd1:  return cmd_r.userref[31:24];
                6'd2:  return cmd_r.userref[23:16];
                6'd3:  return cmd_r.userref[15:8];
                6'd4:  return cmd_r.userref[7:0];
                6'd5:  return cmd_r.qty[31:24];
                6'd6:  return cmd_r.qty[23:16];
                6'd7:  return cmd_r.qty[15:8];
                6'd8:  return cmd_r.qty[7:0];
                // Appendage
                6'd9, 6'd10: return 8'h00; 
                default: return 8'h00;
            endcase
        end
    endfunction

    // Muxing logic
    logic [5:0] base_idx;
    assign base_idx = {word_count, 2'b00}; 

    assign b0 = get_ouch_byte(base_idx);
    assign b1 = get_ouch_byte(base_idx + 1);
    assign b2 = get_ouch_byte(base_idx + 2);
    assign b3 = get_ouch_byte(base_idx + 3);

    // Output Assignment
    always_comb begin
        st_valid         = (state == ST_STREAM);
        st_startofpacket = (state == ST_STREAM && word_count == 0);
        st_endofpacket   = (state == ST_STREAM && word_count == target_words - 1);
        
        // For 32-bit Little Endian, the lowest byte address (Byte 0) maps to st_data[7:0].
        // OUCH Byte 0 (Type) -> st_data[7:0]
        st_data          = {b3, b2, b1, b0}; 
        
        st_empty         = st_endofpacket ? final_empty : 2'd0;
    end

endmodule
