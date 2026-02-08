`timescale 1ns/1ps

module tb_algo_sigs;

  import hft_types_pkg::*;
  import algo_cfg_pkg::*;

  // ----------------------------------------------------------------
  // Clock & Reset
  // ----------------------------------------------------------------
  logic clk;
  logic rst_n;

  initial begin
    clk = 0;
    forever #5 clk = ~clk; // 100MHz
  end

  // ----------------------------------------------------------------
  // Interface Signals
  // ----------------------------------------------------------------
  logic        l1_valid;
  logic        l1_ready;
  logic [15:0] l1_symbol_id;
  logic [63:0] l1_ts_ns;
  logic [31:0] bb_p, bb_q;
  logic [31:0] ba_p, ba_q;

  logic        tok_req_valid;
  logic        tok_req_ready;
  logic [15:0] tok_req_symbol_id;
  logic [15:0] tok_req_strat_id;

  logic        tok_resp_valid;
  logic        tok_resp_ready;
  logic [15:0] tok_resp_symbol_id;
  logic [31:0] tok_resp_token_id;

  logic        ord_valid;
  logic        ord_ready;
  logic [15:0] ord_symbol_id;
  logic [1:0]  ord_action;
  logic        ord_side;
  logic [31:0] ord_price_int;
  logic [31:0] ord_qty;
  logic [31:0] ord_token_id;
  logic [15:0] ord_strat_id;

  logic        rpt_valid;
  logic        rpt_ready;
  logic [15:0] rpt_symbol_id;
  logic [31:0] rpt_token_id;
  logic [1:0]  rpt_kind;
  logic [31:0] rpt_filled_total;

  // ----------------------------------------------------------------
  // PnL Scoreboard Variables
  // ----------------------------------------------------------------
  typedef struct {
    side_e       side;
    logic [31:0] price;
  } order_info_t;

  order_info_t pending_orders [int]; // Map: Token -> Info
  
  longint signed cash_balance = 0;
  longint signed position = 0;
  longint signed total_pnl = 0;

  // Helper to format PnL output
  function void print_pnl(input logic [31:0] current_mid);
    longint signed mtm_value;
    real cash_real, mtm_real, total_real; 
    
    mtm_value = position * current_mid;
    total_pnl = cash_balance + mtm_value;
    
    // Convert to float and scale down by 10,000 (assuming Q16 price units)
    cash_real  = $itor(cash_balance) / 10000.0;
    mtm_real   = $itor(mtm_value)    / 10000.0;
    total_real = $itor(total_pnl)    / 10000.0;
    
    $display("   [PnL UPDATE] Cash: $%0.2f | Pos: %0d | MktVal: $%0.2f | TOTAL PnL: $%0.2f", 
             cash_real, position, mtm_real, total_real);
  endfunction

  // ----------------------------------------------------------------
  // DUT Instance
  // ----------------------------------------------------------------
  algorithm dut (
    .clk(clk),
    .rst_n(rst_n),
    .l1_valid(l1_valid), .l1_ready(l1_ready),
    .l1_symbol_id(l1_symbol_id), .l1_ts_ns(l1_ts_ns),
    .bb_p(bb_p), .bb_q(bb_q), .ba_p(ba_p), .ba_q(ba_q),

    .tok_req_valid(tok_req_valid), .tok_req_ready(tok_req_ready),
    .tok_req_symbol_id(tok_req_symbol_id), .tok_req_strat_id(tok_req_strat_id),

    .tok_resp_valid(tok_resp_valid), .tok_resp_ready(tok_resp_ready),
    .tok_resp_symbol_id(tok_resp_symbol_id), .tok_resp_token_id(tok_resp_token_id),

    .ord_valid(ord_valid), .ord_ready(ord_ready),
    .ord_symbol_id(ord_symbol_id), .ord_action(ord_action), .ord_side(ord_side),
    .ord_price_int(ord_price_int), .ord_qty(ord_qty),
    .ord_token_id(ord_token_id), .ord_strat_id(ord_strat_id),

    .rpt_valid(rpt_valid), .rpt_ready(rpt_ready),
    .rpt_symbol_id(rpt_symbol_id), .rpt_token_id(rpt_token_id),
    .rpt_kind(rpt_kind), .rpt_filled_total(rpt_filled_total)
  );

  // ----------------------------------------------------------------
  // Mock Formatter / Exchange
  // ----------------------------------------------------------------
  
  // 1. Token Allocator
  logic [31:0] next_token_id = 32'd1000;
  
  initial begin
    tok_req_ready = 0;
    tok_resp_valid = 0;
    forever begin
      @(posedge clk);
      tok_req_ready = 1; 
      if (tok_req_valid && tok_req_ready) begin
        tok_req_ready = 0;
        repeat(2) @(posedge clk);
        tok_resp_valid = 1;
        tok_resp_token_id = next_token_id;
        tok_resp_symbol_id = tok_req_symbol_id;
        next_token_id++;
        do @(posedge clk); while (!tok_resp_ready);
        tok_resp_valid = 0;
      end
    end
  end

  // 2. Order Acceptor & Reporter & PnL Tracking
  initial begin
    ord_ready = 0;
    rpt_valid = 0;
    rpt_symbol_id = 0;
    rpt_token_id = 0;
    rpt_kind = 0;
    rpt_filled_total = 0;

    forever begin
      @(posedge clk);
      ord_ready = 1; 
      
      if (ord_valid && ord_ready) begin
        automatic logic [31:0] captured_tok = ord_token_id;
        automatic logic [31:0] captured_qty = ord_qty;
        automatic logic [15:0] captured_sym = ord_symbol_id;
        automatic logic [1:0]  captured_act = ord_action;
        automatic logic [31:0] captured_price = ord_price_int;
        automatic logic        captured_side  = ord_side;

        $display("[%0t] ORDER RECEIVED: Token=%0d Side=%0s Price=$%0.4f Qty=%0d Action=%0d", 
                 $time, captured_tok, (ord_side == SIDE_BUY ? "BUY" : "SELL"), 
                 $itor(ord_price_int)/10000.0, ord_qty, ord_action);

                if (captured_act == 2'b01) begin // ACT_ENTER
          
          // SCOREBOARD: Save order info
          order_info_t info;
          info.side  = side_e'(captured_side);
          info.price = captured_price;
          pending_orders[captured_tok] = info;

          // Wait a bit then fill it
          fork 
              // 1. Declare automatic variables for the thread capture
              automatic int t_tok = captured_tok;
              automatic int t_qty = captured_qty;
              automatic int t_sym = captured_sym;
              begin
                  repeat(20) @(posedge clk);
                  
                  rpt_valid = 1;
                  rpt_kind = 2'b00; // EXEC
                  rpt_token_id = t_tok;
                  rpt_symbol_id = t_sym;
                  rpt_filled_total = t_qty; // Full fill
                  
                  do @(posedge clk); while (!rpt_ready);
                  rpt_valid = 0;
                  
                  // PnL Calculation
                  if (pending_orders.exists(t_tok)) begin
                      // FIX: Declare variables first, then assign
                      automatic order_info_t f_info;
                      automatic longint trade_val;
                      
                      f_info = pending_orders[t_tok];      // Assignment separated
                      trade_val = f_info.price * t_qty;    // Assignment separated
                      
                      if (f_info.side == SIDE_BUY) begin
                         cash_balance = cash_balance - trade_val;
                         position     = position + t_qty;
                      end else begin
                         cash_balance = cash_balance + trade_val;
                         position     = position - t_qty;
                      end
                      
                      // Use current DUT mid price for MTM
                      print_pnl(dut.u_core.u_feat.mid);
                      pending_orders.delete(t_tok);
                  end
                  $display("[%0t] ORDER FILLED: Token=%0d", $time, t_tok);
              end
          join_none

        end
      end
    end
  end

  // ----------------------------------------------------------------
  // Stimulus Generation (Sine Wave Market Data)
  // ----------------------------------------------------------------
  localparam int NUM_SAMPLES = 300;
  logic [31:0] price_pattern [NUM_SAMPLES] = '{
    100000, 100125, 100250, 100374, 100497, 100618, 100736, 100851, 100963, 101071, 
    101175, 101274, 101369, 101457, 101541, 101618, 101688, 101752, 101809, 101859, 
    101902, 101937, 101964, 101984, 101996, 102000, 101996, 101984, 101964, 101937, 
    101902, 101859, 101809, 101752, 101688, 101618, 101541, 101457, 101369, 101274, 
    101175, 101071, 100963, 100851, 100736, 100618, 100497, 100374, 100250, 100125, 
    100000, 99874, 99749, 99625, 99502, 99381, 99263, 99148, 99036, 98928, 98824, 
    98725, 98630, 98542, 98458, 98381, 98311, 98247, 98190, 98140, 98097, 98062, 
    98035, 98015, 98003, 98000, 98003, 98015, 98035, 98062, 98097, 98140, 98190, 
    98247, 98311, 98381, 98458, 98542, 98630, 98725, 98824, 98928, 99036, 99148, 
    99263, 99381, 99502, 99625, 99749, 99874, 100000, 100125, 100250, 100374, 100497, 
    100618, 100736, 100851, 100963, 101071, 101175, 101274, 101369, 101457, 101541, 
    101618, 101688, 101752, 101809, 101859, 101902, 101937, 101964, 101984, 101996, 
    102000, 101996, 101984, 101964, 101937, 101902, 101859, 101809, 101752, 101688, 
    101618, 101541, 101457, 101369, 101274, 101175, 101071, 100963, 100851, 100736, 
    100618, 100497, 100374, 100250, 100125, 100000, 99874, 99749, 99625, 99502, 
    99381, 99263, 99148, 99036, 98928, 98824, 98725, 98630, 98542, 98458, 98381, 
    98311, 98247, 98190, 98140, 98097, 98062, 98035, 98015, 98003, 98000, 98003, 
    98015, 98035, 98062, 98097, 98140, 98190, 98247, 98311, 98381, 98458, 
    98542, 98630, 98725, 98824, 98928, 99036, 99148, 99263, 99381, 99502, 99625, 
    99749, 99874, 100000, 100125, 100250, 100374, 100497, 100618, 100736, 100851, 
    100963, 101071, 101175, 101274, 101369, 101457, 101541, 101618, 101688, 101752, 
    101809, 101859, 101902, 101937, 101964, 101984, 101996, 102000, 101996, 101984, 
    101964, 101937, 101902, 101859, 101809, 101752, 101688, 101618, 101541, 101457, 
    101369, 101274, 101175, 101071, 100963, 100851, 100736, 100618, 100497, 100374, 
    100250, 100125, 100000, 99874, 99749, 99625, 99502, 99381, 99263, 99148, 99036, 
    98928, 98824, 98725, 98630, 98542, 98458, 98381, 98311, 98247, 98190, 98140, 
    98097, 98062, 98035, 98015, 98003, 98000, 98003, 98015, 98035, 98062, 98097, 
    98140, 98190, 98247, 98311, 98381, 98458, 98542, 98630, 98725, 98824, 98928, 
    99036, 99148, 99263, 99381, 99502, 99625, 99749, 99874
  };

  initial begin
    l1_valid = 0; l1_symbol_id = 16'd1; l1_ts_ns = 0;
    bb_p = 0; bb_q = 0; ba_p = 0; ba_q = 0;
    rst_n = 0;
    #100;
    rst_n = 1;
    #100;
    
    $display("Starting Market Data Feed (Sine Wave)...");

    for (int i = 0; i < NUM_SAMPLES; i++) begin
      l1_valid = 1;
      l1_ts_ns = l1_ts_ns + 1000;
      
      bb_p = price_pattern[i] - 5; 
      ba_p = price_pattern[i] + 5; 
      
      bb_q = 100 + (i%10);
      ba_q = 100 + (i%10);
      
      do begin
        @(posedge clk);
      end while (!l1_ready);
      
      l1_valid = 0;
      repeat(5) @(posedge clk);
    end
    
    repeat(500) @(posedge clk);
    $display("Test Complete");
    $stop;
  end
  
  // ----------------------------------------------------------------
  // Monitor / Debug
  // ----------------------------------------------------------------
  always @(posedge clk) begin
    if (dut.u_core.u_feat.snap_en) begin
       $display("T=%0t | Mid=$%0.4f | EMA_Fast=%0d | EMA_Slow=%0d | MACD=%0d", 
                $time, 
                $itor(dut.u_core.u_feat.mid)/10000.0,
                dut.u_core.u_feat.ema_fast, 
                dut.u_core.u_feat.ema_slow,
                dut.u_core.u_feat.macd);
    end
  end

  // ----------------------------------------------------------------
  // Latency Measurement
  // ----------------------------------------------------------------
  longint ts_history [$]; 
  
  always @(posedge clk) begin
    if (l1_valid && l1_ready) begin
      ts_history.push_back($time);
      if (ts_history.size() > 20) void'(ts_history.pop_front());
    end

    if (ord_valid && ord_ready) begin
      automatic longint t_egress = $time;
      automatic longint real_latency = 0;
      
      foreach (ts_history[i]) begin
         automatic longint delta = t_egress - ts_history[i];
         // Hardware latency window: 50ns - 10000ns
         if (delta >= 50 && delta <= 10000) begin
            real_latency = delta;
            $display("[LATENCY MATCH] Order at %0t linked to Input at %0t. Latency: %0d ns (%0d cycles)", 
                     t_egress, ts_history[i], real_latency, real_latency/10);
            break;
         end
      end
    end
  end

endmodule
