module clock_divider #(
	parameter int DIVIDE = 200
) (
	input  logic clk,
	input  logic reset_n,
	output logic clk_div
);

	localparam int CNT_W = (DIVIDE > 1) ? $clog2(DIVIDE) : 1;
	localparam int HALF_DIV = (DIVIDE > 1) ? (DIVIDE/2) : 1;

	logic [CNT_W-1:0] div_count;

	always_ff @(posedge clk or negedge reset_n) begin
		if (!reset_n) begin
			div_count     <= '0;
			clk_div       <= 1'b0;
		end else begin
			if (div_count == (DIVIDE - 1)) begin
				div_count    <= '0;
				clk_div      <= ~clk_div;
			end else begin
				div_count <= div_count + 1'b1;

				if (div_count == (HALF_DIV - 1)) begin
					clk_div <= ~clk_div;
				end
			end
		end
	end

endmodule

