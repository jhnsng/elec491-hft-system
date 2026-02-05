//-----------------------------------------------------
// Design Name : CDC Single Bit Synchronizer
// File Name   : cdc_sync_bit.sv
// Function    : Synchronizes single bit across clock domains
//               Standard 2-FF synchronizer
//-----------------------------------------------------

module cdc_sync_bit (
    input  logic src_bit,
    input  logic dst_clk,
    input  logic dst_rst_n,
    output logic dst_bit
);

    (* ASYNC_REG = "TRUE" *) logic sync_ff1;
    (* ASYNC_REG = "TRUE" *) logic sync_ff2;

    always_ff @(posedge dst_clk or negedge dst_rst_n) begin
        if (!dst_rst_n) begin
            sync_ff1 <= 1'b0;
            sync_ff2 <= 1'b0;
        end else begin
            sync_ff1 <= src_bit;
            sync_ff2 <= sync_ff1;
        end
    end

    assign dst_bit = sync_ff2;

endmodule
