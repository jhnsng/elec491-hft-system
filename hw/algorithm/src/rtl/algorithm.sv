module algorithm (
  input  logic clk,
  input  logic rst_n,

  // L1 snapshot input
  input  logic        l1_valid,
  output logic        l1_ready,
  input  logic [15:0] l1_symbol_id,
  input  logic [63:0] l1_ts_ns,
  input  logic [31:0] bb_p,
  input  logic [31:0] bb_q,
  input  logic [31:0] ba_p,
  input  logic [31:0] ba_q,

  // Token request output
  output logic        tok_req_valid,
  input  logic        tok_req_ready,
  output logic [15:0] tok_req_symbol_id,
  output logic [15:0] tok_req_strat_id,

  // Token response input
  input  logic        tok_resp_valid,
  output logic        tok_resp_ready,
  input  logic [15:0] tok_resp_symbol_id,
  input  logic [31:0] tok_resp_token_id,

  // Order intent output
  output logic        ord_valid,
  input  logic        ord_ready,
  output logic [15:0] ord_symbol_id,
  output logic [1:0]  ord_action,
  output logic        ord_side,
  output logic [31:0] ord_price_int,
  output logic [31:0] ord_qty,
  output logic [31:0] ord_token_id,
  output logic [15:0] ord_strat_id,

  // Order report input
  input  logic        rpt_valid,
  output logic        rpt_ready,
  input  logic [15:0] rpt_symbol_id,
  input  logic [31:0] rpt_token_id,
  input  logic [1:0]  rpt_kind,
  input  logic [31:0] rpt_filled_total
);

  import hft_types_pkg::*;

  // Internal interface
  algo_links_if link(.clk(clk), .rst_n(rst_n));

  // =====================================================================
  // 1. FAST INPUT REGISTERS (Forced into Physical IOEs)
  // =====================================================================
  (* useioff = 1 *) logic        l1_valid_reg;
  (* useioff = 1 *) logic [15:0] l1_symbol_id_reg;
  (* useioff = 1 *) logic [63:0] l1_ts_ns_reg;
  (* useioff = 1 *) logic [31:0] bb_p_reg, bb_q_reg, ba_p_reg, ba_q_reg;

  (* useioff = 1 *) logic        tok_resp_valid_reg;
  (* useioff = 1 *) logic [15:0] tok_resp_symbol_id_reg;
  (* useioff = 1 *) logic [31:0] tok_resp_token_id_reg;

  (* useioff = 1 *) logic        rpt_valid_reg;
  (* useioff = 1 *) logic [15:0] rpt_symbol_id_reg;
  (* useioff = 1 *) logic [31:0] rpt_token_id_reg;
  (* useioff = 1 *) logic [1:0]  rpt_kind_reg;
  (* useioff = 1 *) logic [31:0] rpt_filled_total_reg;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      l1_valid_reg <= 1'b0;
      tok_resp_valid_reg <= 1'b0;
      rpt_valid_reg <= 1'b0;
      l1_symbol_id_reg <= '0; l1_ts_ns_reg <= '0;
      bb_p_reg <= '0; bb_q_reg <= '0; ba_p_reg <= '0; ba_q_reg <= '0;
      tok_resp_symbol_id_reg <= '0; tok_resp_token_id_reg <= '0;
      rpt_symbol_id_reg <= '0; rpt_token_id_reg <= '0;
      rpt_kind_reg <= '0; rpt_filled_total_reg <= '0;
    end else begin
      l1_valid_reg <= l1_valid;
      l1_symbol_id_reg <= l1_symbol_id;
      l1_ts_ns_reg <= l1_ts_ns;
      bb_p_reg <= bb_p;
      bb_q_reg <= bb_q;
      ba_p_reg <= ba_p;
      ba_q_reg <= ba_q;

      tok_resp_valid_reg <= tok_resp_valid;
      tok_resp_symbol_id_reg <= tok_resp_symbol_id;
      tok_resp_token_id_reg <= tok_resp_token_id;

      rpt_valid_reg <= rpt_valid;
      rpt_symbol_id_reg <= rpt_symbol_id;
      rpt_token_id_reg <= rpt_token_id;
      rpt_kind_reg <= rpt_kind;
      rpt_filled_total_reg <= rpt_filled_total;
    end
  end

  assign link.l1_valid = l1_valid_reg;
  assign link.l1.symbol_id = l1_symbol_id_reg;
  assign link.l1.ts_ns     = l1_ts_ns_reg;
  assign link.l1.bb_p      = bb_p_reg;
  assign link.l1.bb_q      = bb_q_reg;
  assign link.l1.ba_p      = ba_p_reg;
  assign link.l1.ba_q      = ba_q_reg;

  assign link.tok_resp_valid    = tok_resp_valid_reg;
  assign link.tok_resp.symbol_id = tok_resp_symbol_id_reg;
  assign link.tok_resp.token_id  = tok_resp_token_id_reg;

  assign link.rpt_valid        = rpt_valid_reg;
  assign link.rpt.symbol_id    = rpt_symbol_id_reg;
  assign link.rpt.token_id     = rpt_token_id_reg;
  assign link.rpt.kind         = rpt_kind_e'(rpt_kind_reg);
  assign link.rpt.filled_total = rpt_filled_total_reg;

  // =====================================================================
  // 2. FAST OUTPUT REGISTERS (Forced into Physical IOEs)
  // =====================================================================
  (* useioff = 1 *) logic        tok_req_valid_out;
  (* useioff = 1 *) logic [15:0] tok_req_symbol_id_out;
  (* useioff = 1 *) logic [15:0] tok_req_strat_id_out;

  (* useioff = 1 *) logic        ord_valid_out;
  (* useioff = 1 *) logic [15:0] ord_symbol_id_out;
  (* useioff = 1 *) logic [1:0]  ord_action_out;
  (* useioff = 1 *) logic        ord_side_out;
  (* useioff = 1 *) logic [31:0] ord_price_int_out;
  (* useioff = 1 *) logic [31:0] ord_qty_out;
  (* useioff = 1 *) logic [31:0] ord_token_id_out;
  (* useioff = 1 *) logic [15:0] ord_strat_id_out;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      tok_req_valid_out <= 1'b0;
      ord_valid_out <= 1'b0;
      tok_req_symbol_id_out <= '0; tok_req_strat_id_out <= '0;
      ord_symbol_id_out <= '0; ord_action_out <= '0; ord_side_out <= '0;
      ord_price_int_out <= '0; ord_qty_out <= '0; ord_token_id_out <= '0; ord_strat_id_out <= '0;
    end else begin
      tok_req_valid_out <= link.tok_req_valid;
      tok_req_symbol_id_out <= link.tok_req.symbol_id;
      tok_req_strat_id_out <= link.tok_req.strat_id;

      ord_valid_out <= link.ord_valid;
      ord_symbol_id_out <= link.ord.symbol_id;
      ord_action_out <= link.ord.action;
      ord_side_out <= link.ord.side;
      ord_price_int_out <= link.ord.price_int;
      ord_qty_out <= link.ord.qty;
      ord_token_id_out <= link.ord.token_id;
      ord_strat_id_out <= link.ord.strat_id;
    end
  end

  assign tok_req_valid = tok_req_valid_out;
  assign tok_req_symbol_id = tok_req_symbol_id_out;
  assign tok_req_strat_id = tok_req_strat_id_out;

  assign ord_valid = ord_valid_out;
  assign ord_symbol_id = ord_symbol_id_out;
  assign ord_action = ord_action_out;
  assign ord_side = ord_side_out;
  assign ord_price_int = ord_price_int_out;
  assign ord_qty = ord_qty_out;
  assign ord_token_id = ord_token_id_out;
  assign ord_strat_id = ord_strat_id_out;

  // ---------------------------------------------------------
  // 3. BACKPRESSURE ROUTING (Combinational Feedthrough)
  // ---------------------------------------------------------
  assign l1_ready = link.l1_ready;
  assign link.tok_req_ready = tok_req_ready;
  assign tok_resp_ready = link.tok_resp_ready;
  assign link.ord_ready = ord_ready;
  assign rpt_ready = link.rpt_ready;

  // ----------------------------
  // Core Instantiation
  // ----------------------------
  algo_top u_core (.link(link));

endmodule
