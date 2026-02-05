//-----------------------------------------------------
// Design Name : CDC Bus Synchronizer
// File Name   : cdc_sync_bus.sv
// Function    : Synchronizes multi-bit buses across clock domains
//               Uses gray code for safe crossing
//-----------------------------------------------------

module cdc_sync_bus #(
    parameter WIDTH = 32
)(
    // Source clock domain
    input  logic             src_clk,
    input  logic             src_rst_n,
    input  logic [WIDTH-1:0] src_data,
    input  logic             src_valid,
    
    // Destination clock domain
    input  logic             dst_clk,
    input  logic             dst_rst_n,
    output logic [WIDTH-1:0] dst_data,
    output logic             dst_valid
);

    // Gray code conversion functions
    function logic [WIDTH-1:0] bin_to_gray(input logic [WIDTH-1:0] bin);
        bin_to_gray = bin ^ (bin >> 1);
    endfunction

    function logic [WIDTH-1:0] gray_to_bin(input logic [WIDTH-1:0] gray);
        automatic logic [WIDTH-1:0] bin;
        bin[WIDTH-1] = gray[WIDTH-1];
        for (int i = WIDTH-2; i >= 0; i--) begin
            bin[i] = bin[i+1] ^ gray[i];
        end
        gray_to_bin = bin;
    endfunction

    // Source clock domain: convert to gray and register
    logic [WIDTH-1:0] src_data_gray;
    always_ff @(posedge src_clk or negedge src_rst_n) begin
        if (!src_rst_n) begin
            src_data_gray <= '0;
        end else if (src_valid) begin
            src_data_gray <= bin_to_gray(src_data);
        end
    end

    // 2-FF synchronizer for gray-coded data
    logic [WIDTH-1:0] dst_data_gray_sync1, dst_data_gray_sync2;
    always_ff @(posedge dst_clk or negedge dst_rst_n) begin
        if (!dst_rst_n) begin
            dst_data_gray_sync1 <= '0;
            dst_data_gray_sync2 <= '0;
        end else begin
            dst_data_gray_sync1 <= src_data_gray;
            dst_data_gray_sync2 <= dst_data_gray_sync1;
        end
    end

    // Convert back to binary in destination domain
    logic [WIDTH-1:0] dst_data_bin;
    assign dst_data_bin = gray_to_bin(dst_data_gray_sync2);

    // Register output
    always_ff @(posedge dst_clk or negedge dst_rst_n) begin
        if (!dst_rst_n) begin
            dst_data <= '0;
        end else begin
            dst_data <= dst_data_bin;
        end
    end

    // Synchronize valid signal using 2-FF synchronizer
    logic src_valid_toggle;
    logic dst_valid_sync1, dst_valid_sync2, dst_valid_sync3;
    
    // Toggle in source domain on valid
    always_ff @(posedge src_clk or negedge src_rst_n) begin
        if (!src_rst_n) begin
            src_valid_toggle <= 1'b0;
        end else if (src_valid) begin
            src_valid_toggle <= ~src_valid_toggle;
        end
    end
    
    // Synchronize toggle to destination domain
    always_ff @(posedge dst_clk or negedge dst_rst_n) begin
        if (!dst_rst_n) begin
            dst_valid_sync1 <= 1'b0;
            dst_valid_sync2 <= 1'b0;
            dst_valid_sync3 <= 1'b0;
        end else begin
            dst_valid_sync1 <= src_valid_toggle;
            dst_valid_sync2 <= dst_valid_sync1;
            dst_valid_sync3 <= dst_valid_sync2;
        end
    end
    
    // Detect edge to generate valid pulse
    assign dst_valid = (dst_valid_sync2 != dst_valid_sync3);

endmodule
