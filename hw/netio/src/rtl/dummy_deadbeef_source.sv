module dummy_deadbeef_source (
    input  logic        clk,
    input  logic        reset_n,

    output logic [31:0] avalon_st_data,
    output logic        avalon_st_valid,
    input  logic        avalon_st_ready,
    output logic        avalon_st_sop,
    output logic        avalon_st_eop,
    output logic [1:0]  avalon_st_empty
);

    typedef enum logic [1:0] {
        IDLE,
        SEND_DEAD,
        SEND_BEEF,
        DONE
    } state_t;

    logic reset_sync /* synthesis noprune */;

    always_ff @(posedge clk) begin
        reset_sync <= reset_n;
    end

    state_t state;

    always_ff @(posedge clk) begin
        if (!reset_n) begin
            state            <= IDLE;
            avalon_st_valid  <= 1'b0;
            avalon_st_sop    <= 1'b0;
            avalon_st_eop    <= 1'b0;
            avalon_st_empty  <= 2'd0;
            avalon_st_data   <= 32'd0;
        end else begin
            avalon_st_valid <= 1'b0;
            avalon_st_sop   <= 1'b0;
            avalon_st_eop   <= 1'b0;

            case (state)
                IDLE: begin
                    state <= SEND_DEAD;
                end

                SEND_DEAD: begin
                    if (avalon_st_ready) begin
                        avalon_st_valid <= 1'b1;
                        avalon_st_sop   <= 1'b1;
                        avalon_st_data  <= 32'h44454144; // "DEAD"
                        avalon_st_empty <= 2'd0;
                        state <= SEND_BEEF;
                    end
                end

                SEND_BEEF: begin
                    if (avalon_st_ready) begin
                        avalon_st_valid <= 1'b1;
                        avalon_st_eop   <= 1'b1;
                        avalon_st_data  <= 32'h42454546; // "BEEF"
                        avalon_st_empty <= 2'd0;
                        state <= DONE;
                    end
                end

                DONE: begin
                    // Hold forever (single packet test)
                    avalon_st_valid <= 1'b0;
                end
            endcase
        end
    end

endmodule
