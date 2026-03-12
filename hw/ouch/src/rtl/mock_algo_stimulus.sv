`timescale 1ns/1ps

//------------------------------------------------------------------------------
// Mock algorithm stimulus for ouch_inbound
//
// Purpose:
//   - After reset, automatically issue two back-to-back algorithm commands:
//       1) Enter Order  ('O' via ouch_inbound)
//       2) Cancel Order ('X' via ouch_inbound)
//------------------------------------------------------------------------------
module mock_algo_stimulus_ouch #(
    parameter logic [31:0] ENTER_QTY        = 32'd100,
    parameter logic [1:0]  ENTER_SIDE       = 2'b00,              // 00=Buy
    parameter logic [63:0] ENTER_SYMBOL     = 64'h4141504C20202020, // "AAPL    "
    parameter logic [63:0] ENTER_PRICE      = 64'd1852500,        // 185.2500
    parameter logic [31:0] CANCEL_NEW_QTY   = 32'd0,              // 0 => full cancel
    parameter int unsigned START_DELAY_CYC  = 4
) (
    input  logic        clk,
    input  logic        rst_n,

    // Connect these to ouch_inbound algorithm-side inputs
    output logic        algo_cmd_valid,
    input  logic        algo_cmd_ready,
    output logic [1:0]  algo_cmd_type,    // 0=Enter, 1=Cancel
    output logic [31:0] algo_qty,
    output logic [1:0]  algo_side,
    output logic [63:0] algo_symbol,
    output logic [63:0] algo_price_ticks,
    output logic [31:0] algo_orig_ref,

    // Optional completion indicator for TB/debug
    output logic        done
);

    typedef enum logic [2:0] {
        ST_RESET_DELAY,
        ST_SEND_ENTER,
        ST_SEND_CANCEL,
        ST_DONE
    } state_t;

    state_t state;

    logic [$clog2(START_DELAY_CYC+1)-1:0] delay_cnt;

    //--------------------------------------------------------------------------
    // Constant command payloads
    //--------------------------------------------------------------------------
    localparam logic [1:0] CMD_ENTER  = 2'd0;
    localparam logic [1:0] CMD_CANCEL = 2'd1;

    // Your ouch_inbound initializes userref_counter to 1 on reset and assigns:
    //   - Enter:  userref = userref_counter
    //   - Cancel: userref = algo_orig_ref
    //
    // So the first Enter will get ref 1, and the Cancel should target ref 1.
    localparam logic [31:0] FIRST_ENTER_REF = 32'd1;

    //--------------------------------------------------------------------------
    // Default driven values
    //--------------------------------------------------------------------------
    always_comb begin
        algo_cmd_valid      = 1'b0;
        algo_cmd_type       = CMD_ENTER;
        algo_qty            = 32'd0;
        algo_side           = ENTER_SIDE;
        algo_symbol         = ENTER_SYMBOL;
        algo_price_ticks    = ENTER_PRICE;
        algo_orig_ref       = 32'd0;
        done                = 1'b0;

        unique case (state)
            ST_RESET_DELAY: begin
                // hold defaults
            end

            ST_SEND_ENTER: begin
                algo_cmd_valid      = 1'b1;
                algo_cmd_type       = CMD_ENTER;
                algo_qty            = ENTER_QTY;
                algo_side           = ENTER_SIDE;
                algo_symbol         = ENTER_SYMBOL;
                algo_price_ticks    = ENTER_PRICE;
                algo_orig_ref       = 32'd0; // ignored for enter
            end

            ST_SEND_CANCEL: begin
                algo_cmd_valid      = 1'b1;
                algo_cmd_type       = CMD_CANCEL;
                algo_qty            = CANCEL_NEW_QTY;
                algo_side           = ENTER_SIDE;      // ignored by cancel
                algo_symbol         = ENTER_SYMBOL;    // ignored by cancel
                algo_price_ticks    = ENTER_PRICE;     // ignored by cancel
                algo_orig_ref       = FIRST_ENTER_REF; // cancel order ref #1
            end

            ST_DONE: begin
                done = 1'b1;
            end

            default: begin
                // safe defaults already assigned
            end
        endcase
    end

    //--------------------------------------------------------------------------
    // Sequencer
    //--------------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state     <= ST_RESET_DELAY;
            delay_cnt <= '0;
        end else begin
            unique case (state)
                ST_RESET_DELAY: begin
                    if (delay_cnt == START_DELAY_CYC-1) begin
                        state <= ST_SEND_ENTER;
                    end else begin
                        delay_cnt <= delay_cnt + 1'b1;
                    end
                end

                ST_SEND_ENTER: begin
                    if (algo_cmd_valid && algo_cmd_ready) begin
                        state <= ST_SEND_CANCEL;
                    end
                end

                ST_SEND_CANCEL: begin
                    if (algo_cmd_valid && algo_cmd_ready) begin
                        state <= ST_DONE;
                    end
                end

                ST_DONE: begin
                    state <= ST_DONE;
                end

                default: begin
                    state <= ST_RESET_DELAY;
                end
            endcase
        end
    end

endmodule