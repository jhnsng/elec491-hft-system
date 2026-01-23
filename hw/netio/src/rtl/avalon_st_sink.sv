module avalon_st_sink (
    input  logic        clk,
    input  logic        reset_n,

    input  logic [31:0] data,
    input  logic        valid,
    output logic        ready,
    input  logic        startofpacket,
    input  logic        endofpacket,
    input  logic [1:0]  empty
);
    assign ready = 1'b1; // always ready
endmodule
