//-----------------------------------------------------
// Design Name : Orderbook Test Controller
// File Name   : orderbook_test_controller.sv
// Function    : Hardcoded test cases for orderbook testing on DE1-SoC
// Controls    : Switches select test case, button triggers valid signal
//-----------------------------------------------------

module orderbook_test_controller (
    input  logic        clk,
    input  logic        reset_n,
    
    // Physical inputs from DE1-SoC
    input  logic [9:0]  SW,          // Switches
    input  logic [3:0]  KEY,         // Pushbuttons (active low)
    output logic [9:0]  LEDR,        // LEDs for status
    
    // Outputs to orderbook
    output logic        side_out,
    output logic [31:0] price_out,
    output logic [31:0] delta_qty_out,
    output logic        valid_out
);

    // SW[9:2] = Test case selection (8 bits = 256 possible test cases)
    // SW[1:0] = Reserved for display controller
    
    // KEY[0] = Reset (already used globally)
    // KEY[1] = Trigger Valid pulse (press to send selected test case to orderbook)
    
    // Button edge detection
    logic key1_prev;
    logic key1_pressed;
    
    // Valid pulse counter
    logic [3:0] valid_pulse_counter;
    
    // Edge detection for KEY[1] (active low)
    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            key1_prev <= 1'b1;
        end else begin
            key1_prev <= KEY[1];
        end
    end
    
    assign key1_pressed = (key1_prev && !KEY[1]); // Falling edge
    
    // Valid pulse generation
    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            valid_pulse_counter <= 4'd0;
        end else begin
            if (key1_pressed) begin
                valid_pulse_counter <= 4'd10; // 10 clock cycles pulse
            end else if (valid_pulse_counter > 0) begin
                valid_pulse_counter <= valid_pulse_counter - 1'b1;
            end
        end
    end
    
    assign valid_out = (valid_pulse_counter > 0);
    
    // Hardcoded test cases based on SW[9:2]
    always_comb begin
        // Default values
        side_out = 1'b0;
        price_out = 32'd28000;
        delta_qty_out = 32'd100;
        
        case (SW[9:2])
            // BID orders (side = 0)
            8'd0:  begin side_out = 1'b0; price_out = 32'd28000; delta_qty_out = 32'd100;  end  // Add BID $280.00, qty 100
            8'd1:  begin side_out = 1'b0; price_out = 32'd28050; delta_qty_out = 32'd200;  end  // Add BID $280.50, qty 200
            8'd2:  begin side_out = 1'b0; price_out = 32'd28100; delta_qty_out = 32'd150;  end  // Add BID $281.00, qty 150
            8'd3:  begin side_out = 1'b0; price_out = 32'd28150; delta_qty_out = 32'd50;   end  // Add BID $281.50, qty 50
            8'd4:  begin side_out = 1'b0; price_out = 32'd27950; delta_qty_out = 32'd300;  end  // Add BID $279.50, qty 300
            8'd5:  begin side_out = 1'b0; price_out = 32'd28000; delta_qty_out = -32'sd50; end  // Cancel BID $280.00, qty 50
            8'd6:  begin side_out = 1'b0; price_out = 32'd28050; delta_qty_out = -32'sd100; end // Cancel BID $280.50, qty 100
            8'd7:  begin side_out = 1'b0; price_out = 32'd28200; delta_qty_out = 32'd500;  end  // Add BID $282.00, qty 500
            8'd8:  begin side_out = 1'b0; price_out = 32'd27900; delta_qty_out = 32'd75;   end  // Add BID $279.00, qty 75
            8'd9:  begin side_out = 1'b0; price_out = 32'd28250; delta_qty_out = 32'd250;  end  // Add BID $282.50, qty 250
            
            // ASK orders (side = 1)
            8'd10: begin side_out = 1'b1; price_out = 32'd28300; delta_qty_out = 32'd100;  end  // Add ASK $283.00, qty 100
            8'd11: begin side_out = 1'b1; price_out = 32'd28350; delta_qty_out = 32'd200;  end  // Add ASK $283.50, qty 200
            8'd12: begin side_out = 1'b1; price_out = 32'd28400; delta_qty_out = 32'd150;  end  // Add ASK $284.00, qty 150
            8'd13: begin side_out = 1'b1; price_out = 32'd28450; delta_qty_out = 32'd50;   end  // Add ASK $284.50, qty 50
            8'd14: begin side_out = 1'b1; price_out = 32'd28500; delta_qty_out = 32'd300;  end  // Add ASK $285.00, qty 300
            8'd15: begin side_out = 1'b1; price_out = 32'd28300; delta_qty_out = -32'sd50; end  // Cancel ASK $283.00, qty 50
            8'd16: begin side_out = 1'b1; price_out = 32'd28350; delta_qty_out = -32'sd100; end // Cancel ASK $283.50, qty 100
            8'd17: begin side_out = 1'b1; price_out = 32'd28250; delta_qty_out = 32'd500;  end  // Add ASK $282.50, qty 500
            8'd18: begin side_out = 1'b1; price_out = 32'd28600; delta_qty_out = 32'd75;   end  // Add ASK $286.00, qty 75
            8'd19: begin side_out = 1'b1; price_out = 32'd28550; delta_qty_out = 32'd250;  end  // Add ASK $285.50, qty 250
            
            // More test cases
            8'd20: begin side_out = 1'b0; price_out = 32'd29000; delta_qty_out = 32'd1000; end  // Large BID order
            8'd21: begin side_out = 1'b1; price_out = 32'd29100; delta_qty_out = 32'd1000; end  // Large ASK order
            8'd22: begin side_out = 1'b0; price_out = 32'd28000; delta_qty_out = 32'd1;    end  // Small BID order
            8'd23: begin side_out = 1'b1; price_out = 32'd28300; delta_qty_out = 32'd1;    end  // Small ASK order
            
            default: begin
                side_out = 1'b0;
                price_out = 32'd28000;
                delta_qty_out = 32'd0;  // No change
            end
        endcase
    end
    
    // LED display shows selected test case
    assign LEDR = SW[9:0];
    
endmodule
