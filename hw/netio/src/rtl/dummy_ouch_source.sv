module dummy_ouch_source (
    input  logic        clk,
    input  logic        reset_n,

    output logic [31:0] avalon_st_data,
    output logic        avalon_st_valid,
    input  logic        avalon_st_ready,
    output logic        avalon_st_sop,
    output logic        avalon_st_eop,
    output logic [4:0]  avalon_st_empty
);

    // 45-byte dummy OUCH "O" message
    logic [7:0] msg [0:44];

    initial begin
        msg[0] = "O";
        for (int i = 1; i < 45; i++)
            msg[i] = i[7:0];
    end

    int byte_idx;
    logic sending;

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            byte_idx         <= 0;
            sending          <= 1'b1;
            avalon_st_valid  <= 1'b0;
            avalon_st_sop    <= 1'b0;
            avalon_st_eop    <= 1'b0;
            avalon_st_empty  <= 5'd0;
        end else begin
            avalon_st_valid <= 1'b0;
            avalon_st_sop   <= 1'b0;
            avalon_st_eop   <= 1'b0;

            if (sending && avalon_st_ready) begin
                avalon_st_valid <= 1'b1;

                avalon_st_data <= {
                    msg[byte_idx + 3],
                    msg[byte_idx + 2],
                    msg[byte_idx + 1],
                    msg[byte_idx + 0]
                };

                if (byte_idx == 0)
                    avalon_st_sop <= 1'b1;

                byte_idx <= byte_idx + 4;

                if (byte_idx + 4 >= 45) begin
                    avalon_st_eop <= 1'b1;
                    avalon_st_empty <= 4 - (45 - byte_idx);
                    sending <= 1'b0;
                end else begin
                    avalon_st_empty <= 5'd0;
                end
            end
        end
    end

endmodule
