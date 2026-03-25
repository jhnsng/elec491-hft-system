`timescale 1ns/1ps

module test_controller_tb;

	// Bring generated vectors into TB scope for expected-value checks.
	`include "../rtl/orderbook_vectors_generated.svh"

	localparam int CLK_PERIOD_NS = 10;

	logic        clk;
	logic        reset_n;
	logic [9:0]  SW;
	logic [3:0]  KEY;
	logic [9:0]  LEDR;
	logic        side_out;
	logic [31:0] price_out;
	logic [31:0] delta_qty_out;
	logic        valid_out;

	int pass_count;
	int fail_count;

	orderbook_test_controller dut (
		.clk(clk),
		.reset_n(reset_n),
		.SW(SW),
		.KEY(KEY),
		.LEDR(LEDR),
		.side_out(side_out),
		.price_out(price_out),
		.delta_qty_out(delta_qty_out),
		.valid_out(valid_out)
	);

	// -----------------------------
	// Clock generation
	// -----------------------------
	initial begin
		clk = 1'b0;
		forever #(CLK_PERIOD_NS/2) clk = ~clk;
	end

	// -----------------------------
	// Helpers
	// -----------------------------
	function automatic int vec_count(input logic [6:0] seq);
		case (seq)
			7'd1: vec_count = ORDERBOOK_VECTOR_COUNT1;
			7'd2: vec_count = ORDERBOOK_VECTOR_COUNT2;
			7'd3: vec_count = ORDERBOOK_VECTOR_COUNT3;
			default: vec_count = 0;
		endcase
	endfunction

	task automatic get_expected(
		input  logic [6:0] seq,
		input  int idx,
		output logic exp_side,
		output logic [31:0] exp_price,
		output logic [31:0] exp_delta
	);
		begin
			exp_side = 1'b0;
			exp_price = 32'd0;
			exp_delta = 32'd0;

			case (seq)
				7'd1: begin
					exp_side  = ORDERBOOK_VECTORS1[idx].side;
					exp_price = ORDERBOOK_VECTORS1[idx].price;
					exp_delta = ORDERBOOK_VECTORS1[idx].delta_qty;
				end
				7'd2: begin
					exp_side  = ORDERBOOK_VECTORS2[idx].side;
					exp_price = ORDERBOOK_VECTORS2[idx].price;
					exp_delta = ORDERBOOK_VECTORS2[idx].delta_qty;
				end
				7'd3: begin
					exp_side  = ORDERBOOK_VECTORS3[idx].side;
					exp_price = ORDERBOOK_VECTORS3[idx].price;
					exp_delta = ORDERBOOK_VECTORS3[idx].delta_qty;
				end
				default: begin
					exp_side = 1'b0;
					exp_price = 32'd0;
					exp_delta = 32'd0;
				end
			endcase
		end
	endtask

	task automatic pulse_key1;
		begin
			// KEY is active-low. Create a clean falling edge across a clock.
			@(negedge clk);
			KEY[1] <= 1'b0;
			@(posedge clk);
			#1;
			@(negedge clk);
			KEY[1] <= 1'b1;
		end
	endtask

	task automatic check_outputs(
		input string name,
		input logic exp_side,
		input logic [31:0] exp_price,
		input logic [31:0] exp_delta,
		input logic exp_valid
	);
		begin
			if ((side_out === exp_side) &&
				(price_out === exp_price) &&
				(delta_qty_out === exp_delta) &&
				(valid_out === exp_valid)) begin
				$display("[PASS] %s", name);
				pass_count++;
			end else begin
				$display("[FAIL] %s", name);
				$display("       exp: valid=%0b side=%0b price=%0d delta=%0d",
					exp_valid, exp_side, exp_price, $signed(exp_delta));
				$display("       got: valid=%0b side=%0b price=%0d delta=%0d",
					valid_out, side_out, price_out, $signed(delta_qty_out));
				fail_count++;
			end
		end
	endtask

	task automatic do_debug_step_and_check(input logic [6:0] seq, input int idx);
		logic exp_side;
		logic [31:0] exp_price;
		logic [31:0] exp_delta;
		begin
			get_expected(seq, idx, exp_side, exp_price, exp_delta);

			pulse_key1();
			#1;
			check_outputs($sformatf("Debug seq=%0d idx=%0d", seq, idx),
				exp_side, exp_price, exp_delta, 1'b1);

			// valid should drop when no new message is emitted.
			@(posedge clk);
			#1;
			if (valid_out !== 1'b0) begin
				$display("[FAIL] Debug valid deassert after seq=%0d idx=%0d", seq, idx);
				fail_count++;
			end else begin
				$display("[PASS] Debug valid deassert after seq=%0d idx=%0d", seq, idx);
				pass_count++;
			end
		end
	endtask

	task automatic run_stream_and_check(input logic [6:0] seq);
		logic exp_side;
		logic [31:0] exp_price;
		logic [31:0] exp_delta;
		int i;
		int count;
		bit started;
		begin
			count = vec_count(seq);
			started = 1'b0;

			// Arm stream mode and selected sequence before pressing KEY1.
			SW[9] <= 1'b1;
			SW[8:2] <= seq;
			@(posedge clk);

			pulse_key1();

			// Wait for first valid in stream.
			for (i = 0; i < 20; i++) begin
				@(posedge clk);
				#1;
				if (valid_out) begin
					started = 1'b1;
					disable wait_done;
				end
			end
			wait_done: begin end

			if (!started) begin
				$display("[FAIL] Stream seq=%0d did not start", seq);
				fail_count++;
				return;
			end

			// We are currently at idx 0 on first valid cycle.
			for (i = 0; i < count; i++) begin
				// Change selection during stream to prove latched selection behavior.
				if (i == 5) begin
					SW[8:2] <= 7'd3;
				end

				get_expected(seq, i, exp_side, exp_price, exp_delta);
				check_outputs($sformatf("Stream seq(latched)=%0d idx=%0d", seq, i),
					exp_side, exp_price, exp_delta, 1'b1);

				@(posedge clk);
				#1;
			end

			// After final message, stream should return to idle/debug with valid low.
			if (valid_out !== 1'b0) begin
				$display("[FAIL] Stream seq=%0d valid did not drop at end", seq);
				fail_count++;
			end else begin
				$display("[PASS] Stream seq=%0d valid dropped at end", seq);
				pass_count++;
			end

			if (LEDR[8] !== 1'b0) begin
				$display("[FAIL] Stream seq=%0d did not return to idle (LEDR[8])", seq);
				fail_count++;
			end else begin
				$display("[PASS] Stream seq=%0d returned to idle", seq);
				pass_count++;
			end
		end
	endtask

	// -----------------------------
	// Test sequence
	// -----------------------------
	initial begin
		pass_count = 0;
		fail_count = 0;

		// Defaults
		SW = 10'd0;
		KEY = 4'b1111;
		reset_n = 1'b0;

		// Reset
		repeat (4) @(posedge clk);
		reset_n = 1'b1;
		repeat (2) @(posedge clk);

		$display("\n=== TEST: Debug mode stepping (SW9=0) ===");
		SW[9] <= 1'b0;
		SW[8:2] <= 7'd1;
		@(posedge clk);

		do_debug_step_and_check(7'd1, 0);
		do_debug_step_and_check(7'd1, 1);

		// Change selection in debug: index should restart at 0.
		SW[8:2] <= 7'd2;
		@(posedge clk);
		do_debug_step_and_check(7'd2, 0);

		$display("\n=== TEST: Streaming mode full run (SW9=1) ===");
		run_stream_and_check(7'd1);

		// After stream completion, verify we can still debug-step.
		$display("\n=== TEST: Back to debug after stream ===");
		SW[9] <= 1'b0;
		SW[8:2] <= 7'd3;
		@(posedge clk);
		do_debug_step_and_check(7'd3, 0);

		$display("\n=== SUMMARY ===");
		$display("PASS = %0d", pass_count);
		$display("FAIL = %0d", fail_count);

		if (fail_count == 0) begin
			$display("ALL TESTS PASSED");
		end else begin
			$display("TESTS FAILED");
		end

		$finish;
	end

	// Timeout watchdog
	initial begin
		#5_000_000;
		$display("[FAIL] TB timeout");
		$finish;
	end

endmodule

