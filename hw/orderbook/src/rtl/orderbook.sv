module orderbook #(
    parameter BUFFER_SIZE = 512,
    parameter LIMIT_DOWN_PRICE = 29479, // 279.43, opening price 299.91
    parameter PRICE_WIDTH = 32,
    parameter QTY_WIDTH = 32
)(
    input  logic                     clk,
    input  logic                     rst_n,
    input  side_t                    side_in,
    input  logic [PRICE_WIDTH-1:0]   price_in,
    input  logic [QTY_WIDTH-1:0]     delta_qty_in,
    input  logic                     valid_in,
    output logic                     valid_out,
    output order_info_t              order_out,
    // Best bid outputs
    output logic [PRICE_WIDTH-1:0]   best_bid_price,
    output logic [QTY_WIDTH-1:0]     best_bid_qty,
    output logic                     best_bid_valid,
    // Best ask outputs
    output logic [PRICE_WIDTH-1:0]   best_ask_price,
    output logic [QTY_WIDTH-1:0]     best_ask_qty,
    output logic                     best_ask_valid
);

    import _pkg::*;

    logic [PRICE_WIDTH-1:0] buffer_index;
    always_comb begin
        buffer_index = (price_in - LIMIT_DOWN_PRICE);
    end

    typedef struct packed {
        logic [QTY_WIDTH-1:0]   qty;
        logic                   valid;
    } entry_t;

    entry_t bid_buffer [0:BUFFER_SIZE-1];
    entry_t ask_buffer [0:BUFFER_SIZE-1];
    
    // Calculate number of reduction stages needed
    localparam NUM_STAGES = $clog2(BUFFER_SIZE);
    
    // Reduction tree structures - properly sized for each stage
    // Stage i has BUFFER_SIZE >> i elements
    generate
        genvar s;
        for (s = 1; s <= NUM_STAGES; s++) begin : gen_reduction_arrays
            localparam STAGE_SIZE = BUFFER_SIZE >> s;
            logic bid_stage [0:STAGE_SIZE-1];
            logic ask_stage [0:STAGE_SIZE-1];
        end
    endgenerate
    
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            valid_out <= 1'b0;
            for (int i = 0; i < BUFFER_SIZE; i++) begin
                bid_buffer[i].valid <= '0;
                bid_buffer[i].qty <= '0;
                ask_buffer[i].valid <= '0;
                ask_buffer[i].qty <= '0;
            end
        end else begin
            valid_out <= 1'b0;
            if (!side_in) begin
                bid_buffer[buffer_index].qty <= bid_buffer[buffer_index].qty + delta_qty_in;
                if (bid_buffer[buffer_index].qty + delta_qty_in <= '0) begin
                    bid_buffer[buffer_index].valid <= 1'b0;
                end else begin
                    bid_buffer[buffer_index].valid <= 1'b1;
                end
            end
            else begin
                ask_buffer[buffer_index].qty <= ask_buffer[buffer_index].qty + delta_qty_in;
                if (ask_buffer[buffer_index].qty + delta_qty_in <= '0) begin
                    ask_buffer[buffer_index].valid <= 1'b0;
                end else begin
                    ask_buffer[buffer_index].valid <= 1'b1;
                end
            end
        end
    end
    
    // Stage 0 (first stage): Compare from bid/ask buffers with masking
    localparam STAGE1_PAIRS = BUFFER_SIZE >> 1;
    genvar idx;
    generate
        for (idx = 0; idx < STAGE1_PAIRS; idx++) begin : gen_stage0_bid
            always_comb begin
                automatic int bid_left_idx = idx * 2;
                automatic int bid_right_idx = idx * 2 + 1;
                automatic logic [PRICE_WIDTH-1:0] bid_left_masked_addr;
                automatic logic [PRICE_WIDTH-1:0] bid_right_masked_addr;

                bid_left_masked_addr = bid_buffer[bid_left_idx].valid ? bid_left_idx : '0;
                bid_right_masked_addr = bid_buffer[bid_right_idx].valid ? bid_right_idx : '0;

                if (bid_left_masked_addr >= bid_right_masked_addr) begin
                    gen_reduction_arrays[1].bid_stage[idx] = bid_left_idx;
                end else begin
                    gen_reduction_arrays[1].bid_stage[idx] = bid_right_idx;
                end
            end
        end
        
        for (idx = 0; idx < STAGE1_PAIRS; idx++) begin : gen_stage0_ask
            always_comb begin
                automatic int ask_left_idx = idx * 2;
                automatic int ask_right_idx = idx * 2 + 1;
                automatic logic [PRICE_WIDTH-1:0] ask_left_masked_addr;
                automatic logic [PRICE_WIDTH-1:0] ask_right_masked_addr;

                ask_left_masked_addr = ask_buffer[ask_left_idx].valid ? ask_left_idx : {PRICE_WIDTH{1'b1}};
                ask_right_masked_addr = ask_buffer[ask_right_idx].valid ? ask_right_idx : {PRICE_WIDTH{1'b1}};

                if (ask_left_masked_addr <= ask_right_masked_addr) begin
                    gen_reduction_arrays[1].ask_stage[idx] = ask_left_idx;
                end else begin
                    gen_reduction_arrays[1].ask_stage[idx] = ask_right_idx;
                end
            end
        end
    endgenerate
    
    // Remaining stages (stage 1 to NUM_STAGES-1): Compare from previous stage without masking
    genvar stage, i;
    generate
        for (stage = 1; stage < NUM_STAGES; stage++) begin : gen_remaining_stages
            localparam STAGE_PAIRS = BUFFER_SIZE >> (stage + 1);
            
            for (i = 0; i < STAGE_PAIRS; i++) begin : gen_compare
                always_comb begin
                    automatic int left_idx = i * 2;
                    automatic int right_idx = i * 2 + 1;
                    
                    if (gen_reduction_arrays[stage].bid_stage[left_idx] >= gen_reduction_arrays[stage].bid_stage[right_idx]) begin
                        gen_reduction_arrays[stage+1].bid_stage[i] = gen_reduction_arrays[stage].bid_stage[left_idx];
                    end else begin
                        gen_reduction_arrays[stage+1].bid_stage[i] = gen_reduction_arrays[stage].bid_stage[right_idx];
                    end
                    
                    if (gen_reduction_arrays[stage].ask_stage[left_idx] <= gen_reduction_arrays[stage].ask_stage[right_idx]) begin
                        gen_reduction_arrays[stage+1].ask_stage[i] = gen_reduction_arrays[stage].ask_stage[left_idx];
                    end else begin
                        gen_reduction_arrays[stage+1].ask_stage[i] = gen_reduction_arrays[stage].ask_stage[right_idx];
                    end
                end
            end
        end
    endgenerate

    assign best_bid_price = gen_reduction_arrays[NUM_STAGES].bid_stage[0] + LIMIT_DOWN_PRICE;
    assign best_bid_qty = bid_buffer[gen_reduction_arrays[NUM_STAGES].bid_stage[0]].qty;
    
    assign best_ask_price = gen_reduction_arrays[NUM_STAGES].ask_stage[0] + LIMIT_DOWN_PRICE;
    assign best_ask_qty = ask_buffer[gen_reduction_arrays[NUM_STAGES].ask_stage[0]].qty;
    
endmodule: orderbook