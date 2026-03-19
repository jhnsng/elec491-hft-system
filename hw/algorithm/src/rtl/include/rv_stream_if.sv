interface rv_stream_if #(parameter int W = 32) (input logic clk, input logic rst_n);
  logic         valid;
  logic         ready;
  logic [W-1:0] data;

  modport src (input clk, rst_n, output valid, data, input ready);
  modport snk (input clk, rst_n, input valid, data, output ready);
endinterface
