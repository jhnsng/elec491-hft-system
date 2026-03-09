`timescale 1ns/1ps

module ouch_inbound_tb;
  // Clock & Reset Generation
  logic clk = 0;
  always #5 clk = ~clk; // 100MHz
  logic rst_n;

  // --- DUT Interface Signals ---
  logic        algo_cmd_valid;
  logic        algo_cmd_ready;
  logic [1:0]  algo_cmd_type;
  logic [31:0] algo_qty;
  logic [1:0]  algo_side;
  logic [63:0] algo_symbol;
  logic [63:0] algo_price_ticks;
  logic [31:0] algo_orig_ref;

  // Outputs from DUT
  logic [31:0] st_data;
  logic        st_valid;
  logic        st_ready;
  logic        st_startofpacket;
  logic        st_endofpacket;
  logic [1:0]  st_empty;

  // Instantiate the Optimized DUT
  ouch_inbound dut (.*); 

  // --- Helpers ---
  function automatic [63:0] ascii8(input string s);
    byte b[8];
    for(int i=0; i<8; i++) b[i] = (i < s.len()) ? s[i] : 8'h20;
    ascii8 = {b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7]};
  endfunction

  typedef byte byteq_t[$];

  // --- Golden Packet Generators ---
  function automatic byteq_t golden_add(input [31:0] u, input [1:0] s, input [31:0] q, input [63:0] sym, input [63:0] p);
    byteq_t bq; 
    bq.push_back(8'h4F);
    bq.push_back(u[31:24]); bq.push_back(u[23:16]); bq.push_back(u[15:8]); bq.push_back(u[7:0]);
    bq.push_back((s==0) ? 8'h42 : 8'h53);
    bq.push_back(q[31:24]); bq.push_back(q[23:16]); bq.push_back(q[15:8]); bq.push_back(q[7:0]);
    bq.push_back(sym[63:56]); bq.push_back(sym[55:48]); bq.push_back(sym[47:40]); bq.push_back(sym[39:32]);
    bq.push_back(sym[31:24]); bq.push_back(sym[23:16]); bq.push_back(sym[15:8]); bq.push_back(sym[7:0]);
    bq.push_back(p[63:56]); bq.push_back(p[55:48]); bq.push_back(p[47:40]); bq.push_back(p[39:32]);
    bq.push_back(p[31:24]); bq.push_back(p[23:16]); bq.push_back(p[15:8]); bq.push_back(p[7:0]);
    bq.push_back(8'h30); bq.push_back(8'h59); bq.push_back(8'h50); bq.push_back(8'h4E); bq.push_back(8'h4E);
    repeat(14) bq.push_back(8'h20); 
    bq.push_back(8'h00); bq.push_back(8'h00); 
    return bq;
  endfunction

  function automatic byteq_t golden_cancel(input [31:0] u, input [31:0] q);
    byteq_t bq;
    bq.push_back(8'h58);
    bq.push_back(u[31:24]); bq.push_back(u[23:16]); bq.push_back(u[15:8]); bq.push_back(u[7:0]);
    bq.push_back(q[31:24]); bq.push_back(q[23:16]); bq.push_back(q[15:8]); bq.push_back(q[7:0]);
    bq.push_back(8'h00); bq.push_back(8'h00); 
    return bq;
  endfunction

  // --- Ready Signal Randomizer ---
  integer stall_countdown;
  always_ff @(posedge clk) begin
    if (!rst_n) st_ready <= 0;
    else begin
       if (stall_countdown > 0) begin 
           st_ready <= 0; 
           stall_countdown--; 
       end else begin 
           st_ready <= 1; 
           if ($urandom_range(0,100) < 10) 
               stall_countdown <= $urandom_range(1,4); 
       end
    end
  end

  // --- Monitor ---
  byteq_t expected_q[$];
  byteq_t current_pkt;
  logic in_pkt;
  int pkt_count;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      current_pkt.delete(); in_pkt <= 0; pkt_count <= 0;
    end else if (st_valid && st_ready) begin
      if (st_startofpacket) begin
        if (in_pkt) $fatal(1, "Error: SOP inside packet!");
        in_pkt <= 1; current_pkt.delete();
      end else if (!in_pkt) begin
         $fatal(1, "Error: Received valid data without SOP!");
      end
      
      // Read st_data in Little Endian order (LSB first) to reconstruct the stream
      current_pkt.push_back(st_data[7:0]);
      if (!st_endofpacket || st_empty < 3) current_pkt.push_back(st_data[15:8]);
      if (!st_endofpacket || st_empty < 2) current_pkt.push_back(st_data[23:16]);
      if (!st_endofpacket || st_empty < 1) current_pkt.push_back(st_data[31:24]);

      if (st_endofpacket) begin
         in_pkt <= 0; pkt_count++;
         if (expected_q.size() == 0) $fatal(1, "Error: Unexpected packet received!");
         else begin
            byteq_t exp; exp = expected_q.pop_front();
            if (current_pkt.size() != exp.size()) 
                $fatal(1, "Size mismatch. Got %0d, Exp %0d", current_pkt.size(), exp.size());
            foreach(exp[i]) begin
                if (current_pkt[i] !== exp[i]) 
                   $fatal(1, "Data mismatch at %0d: Got %02x Exp %02x", i, current_pkt[i], exp[i]);
            end
         end
      end
    end
  end

  // --- Tasks ---
  int next_userref_model = 1;
  localparam string SYM = "AAPL";

  task automatic drive_add(input [31:0] q, input [1:0] s, input [63:0] p);
    algo_cmd_type <= 0; 
    algo_qty <= q; 
    algo_side <= s; 
    algo_symbol <= ascii8(SYM); 
    algo_price_ticks <= p; 
    algo_cmd_valid <= 1;
    
    // Wait for acceptance
    do @(posedge clk); while (!algo_cmd_ready);
    
    expected_q.push_back(golden_add(next_userref_model++, s, q, ascii8(SYM), p)); 
    algo_cmd_valid <= 0;
  endtask

  task automatic drive_cancel(input [31:0] ref_id, input [31:0] q);
    algo_cmd_type <= 1; 
    algo_qty <= q; 
    algo_orig_ref <= ref_id; 
    algo_cmd_valid <= 1;
    
    do @(posedge clk); while (!algo_cmd_ready);
    
    expected_q.push_back(golden_cancel(ref_id, q));
    algo_cmd_valid <= 0;
  endtask

  // --- Stimulus ---
  initial begin
    rst_n = 0; algo_cmd_valid = 0;
    repeat(5) @(posedge clk); rst_n = 1; repeat(5) @(posedge clk);

    $display("--- Starting Simulation ---");

    // 1. Single ADD
    drive_add(100, 0, 12345);    
    
    // 2. Single CANCEL
    drive_cancel(1, 0);          
    
    // 3. Single ADD
    drive_add(999, 1, 55555);    
    
    // 4. Back-to-Back Sequences
    // Driven immediately after one another to test the 'bubble-less' logic
    drive_add(50, 0, 20000); // UserRef = 3
    drive_add(75, 1, 21000); // UserRef = 4

    // Wait for drain
    repeat(1000) @(posedge clk);
    
    if (pkt_count != 5) 
        $fatal(1, "Error: Missing packets! Got %0d, Expected 5", pkt_count);
        
    $display("PASS: All 5 packets matched successfully.");
    $finish;
  end

endmodule
