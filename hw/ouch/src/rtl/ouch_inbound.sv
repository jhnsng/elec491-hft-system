//================================================================================
// OUCH 5.0 Inbound Formatter (Nasdaq) - Enter Order 'O' + Cancel 'X'
// Avalon-ST output (byte stream), one OUCH message == one Avalon-ST "packet"
//
// Inbound messages implemented:
//   'O' Enter Order (45 bytes)
//   'X' Cancel Order (9 bytes)
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

    //=== OUTPUT: Avalon-ST Source (32-bit stream) ===
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
    
    // Modified lengths with appendage-length field removed
    localparam int unsigned ADD_MSG_BYTES    = 45;
    localparam int unsigned CANCEL_MSG_BYTES = 9;

    localparam logic [7:0] TIF_DAY         = 8'h30;
    localparam logic [7:0] DISPLAY_VISIBLE = 8'h59;
    localparam logic [7:0] CAPACITY_PRIN   = 8'h50;
    localparam logic [7:0] IMS_INELIG      = 8'h4E;
    localparam logic [7:0] CROSS_NORMAL    = 8'h4E;
    localparam logic [7:0] SPACE           = 8'h20;

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
                
                // FIXED: Divide by 256 to strip internal fractions, then multiply by 100 for OUCH spec!
                fifo_mem[wr_ptr].price    <= (algo_price_ticks) * 100;
                
                fifo_mem[wr_ptr].userref  <= (algo_cmd_type == 2'b00) ? userref_counter : algo_orig_ref;
                
                wr_ptr <= wr_ptr + 3'd1;
                if (algo_cmd_type == 2'b00)
                    userref_counter <= userref_counter + 32'd1;
            end

            if (push && !pop)      fifo_count <= fifo_count + 4'd1;
            else if (!push && pop) fifo_count <= fifo_count - 4'd1;
        end
    end

    // FIFO Read Pointer Update
    always_ff @(posedge clk) begin
        if (!rst_n)
            rd_ptr <= 3'd0;
        else if (pop)
            rd_ptr <= rd_ptr + 3'd1;
    end

    // 3) Serializer State Machine
    typedef enum logic [1:0] { ST_IDLE, ST_STREAM } state_t;
    state_t state;

    cmd_t        cmd_r;           
    logic [3:0]  word_count;      
    logic [3:0]  target_words;    
    logic [1:0]  final_empty;     

    function automatic void calc_packet_params(
        input  logic [1:0] type_in,
        output logic [3:0] tw,
        output logic [1:0] fe
    );
        if (type_in == 2'b00) begin
            // 45 bytes -> 12 words, 1 valid bytes in last word -> empty = 3
            tw = (ADD_MSG_BYTES + 3) >> 2;
            fe = 2'd3;
        end else begin
            // 9 bytes -> 3 words, 1 valid byte in last word -> empty = 3
            tw = (CANCEL_MSG_BYTES + 3) >> 2;
            fe = 2'd3;
        end
    endfunction

    logic packet_done;
    assign packet_done = (state == ST_STREAM) && st_ready && (word_count == target_words - 1);

    assign pop = (state == ST_IDLE && !fifo_empty) || (packet_done && !fifo_empty);

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state        <= ST_IDLE;
            word_count   <= 4'd0;
            target_words <= 4'd0;
            final_empty  <= 2'd0;
            cmd_r        <= '0;
        end else begin
            case (state)
                ST_IDLE: begin
                    if (!fifo_empty) begin
                        cmd_r <= fifo_mem[rd_ptr];
                        calc_packet_params(fifo_mem[rd_ptr].cmd_type, target_words, final_empty);
                        state      <= ST_STREAM;
                        word_count <= 4'd0;
                    end
                end

                ST_STREAM: begin
                    if (st_ready) begin
                        if (word_count == target_words - 1) begin
                            if (!fifo_empty) begin
                                cmd_r <= fifo_mem[rd_ptr];
                                calc_packet_params(fifo_mem[rd_ptr].cmd_type, target_words, final_empty);
                                word_count <= 4'd0;
                            end else begin
                                state <= ST_IDLE;
                            end
                        end else begin
                            word_count <= word_count + 4'd1;
                        end
                    end
                end

                default: begin
                    state <= ST_IDLE;
                end
            endcase
        end
    end

    // 4) Byte Multiplexer
    logic [7:0] b0, b1, b2, b3;

    function automatic logic [7:0] get_ouch_byte(input [5:0] byte_idx);
        if (cmd_r.cmd_type == 2'b00) begin
            // === ENTER ORDER === 45 bytes total
            case (byte_idx)
                6'd0:  return OUCH_TYPE_ADD;
                6'd1:  return cmd_r.userref[31:24];
                6'd2:  return cmd_r.userref[23:16];
                6'd3:  return cmd_r.userref[15:8];
                6'd4:  return cmd_r.userref[7:0];
                6'd5:  return (cmd_r.side == 2'b00) ? 8'h42 : 8'h53; // 'B' or 'S'
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

                // FIXED: Clean 1:1 Price byte mapping (no more lazy byte shifting!)
                6'd18: return cmd_r.price[63:56];
                6'd19: return cmd_r.price[55:48];
                6'd20: return cmd_r.price[47:40];
                6'd21: return cmd_r.price[39:32];
                6'd22: return cmd_r.price[31:24];
                6'd23: return cmd_r.price[23:16];
                6'd24: return cmd_r.price[15:8];
                6'd25: return cmd_r.price[7:0];

                // Fixed fields
                6'd26: return TIF_DAY;
                6'd27: return DISPLAY_VISIBLE;
                6'd28: return CAPACITY_PRIN;
                6'd29: return IMS_INELIG;
                6'd30: return CROSS_NORMAL;

                // ClOrdID (14 spaces)
                6'd31, 6'd32, 6'd33, 6'd34, 6'd35, 6'd36, 6'd37,
                6'd38, 6'd39, 6'd40, 6'd41, 6'd42, 6'd43, 6'd44:
                    return SPACE;

                default: return 8'h00;
            endcase
        end else begin
            // === CANCEL ORDER === 9 bytes total
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
                default: return 8'h00;
            endcase
        end
    endfunction

    logic [5:0] base_idx;
    assign base_idx = {word_count, 2'b00};

    assign b0 = get_ouch_byte(base_idx);
    assign b1 = get_ouch_byte(base_idx + 6'd1);
    assign b2 = get_ouch_byte(base_idx + 6'd2);
    assign b3 = get_ouch_byte(base_idx + 6'd3);

    // Output Assignment
    always_comb begin
        st_valid         = (state == ST_STREAM);
        st_startofpacket = (state == ST_STREAM && word_count == 4'd0);
        st_endofpacket   = (state == ST_STREAM && word_count == target_words - 1);

        // Byte 0 on st_data[31:24] in this packing
        st_data          = {b0, b1, b2, b3};

        st_empty         = st_endofpacket ? final_empty : 2'd0;
    end

endmodule