// M10K block configured for 40-bit x 256 to store 33-bit entry_t struct
// 32-bit qty + 1-bit valid, padded to 40 bits
module M10K_256_40( 
    output reg [39:0] q,
    input [39:0] d,
    input [7:0] write_address, read_address,
    input we, clk
);
    // Force M10K ram style with 40-bit width
    reg [39:0] mem [255:0] /* synthesis ramstyle = "no_rw_check, M10K" */;
    
    always @ (posedge clk) begin
        if (we) begin
            mem[write_address] <= d;
        end
        q <= mem[read_address]; // 2-cycle read latency (register + read)
    end
endmodule
