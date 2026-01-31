import _pkg::*;

module orderbook #(
    parameter BUFFER_SIZE = 4096,  // Now supports 4096 entries using M10K blocks
    parameter LIMIT_DOWN_PRICE = 27963, // 279.63, opening price 299.91
    parameter PRICE_WIDTH = 32,
    parameter QTY_WIDTH = 32,
    parameter NUM_M10K_BLOCKS = BUFFER_SIZE / 256  // Number of M10K blocks needed
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

    logic [PRICE_WIDTH-1:0] buffer_index;
    always_comb begin
        buffer_index = (price_in - LIMIT_DOWN_PRICE);
    end

    typedef struct packed {
        logic [QTY_WIDTH-1:0]   qty;
        logic                   valid;
    } entry_t;

    // M10K memory interface signals (40-bit width for 33-bit entry_t)
    logic [39:0] bid_m10k_write_data [0:NUM_M10K_BLOCKS-1];
    logic [39:0] bid_m10k_read_data [0:NUM_M10K_BLOCKS-1];
    logic [39:0] ask_m10k_write_data [0:NUM_M10K_BLOCKS-1];
    logic [39:0] ask_m10k_read_data [0:NUM_M10K_BLOCKS-1];
    logic [7:0] bid_m10k_write_addr [0:NUM_M10K_BLOCKS-1];
    logic [7:0] bid_m10k_read_addr [0:NUM_M10K_BLOCKS-1];
    logic [7:0] ask_m10k_write_addr [0:NUM_M10K_BLOCKS-1];
    logic [7:0] ask_m10k_read_addr [0:NUM_M10K_BLOCKS-1];
    logic bid_m10k_we [0:NUM_M10K_BLOCKS-1];
    logic ask_m10k_we [0:NUM_M10K_BLOCKS-1];
    
    // Address decoding: upper bits select M10K block, lower 8 bits address within block
    localparam ADDR_MSB = $clog2(NUM_M10K_BLOCKS) + 7;  // Total address width
    logic [$clog2(NUM_M10K_BLOCKS)-1:0] write_block_sel;
    logic [7:0] write_block_addr;
    
    assign write_block_sel = buffer_index[ADDR_MSB:8];
    assign write_block_addr = buffer_index[7:0];
    
    // Instantiate M10K blocks for bid buffer
    genvar blk;
    generate
        for (blk = 0; blk < NUM_M10K_BLOCKS; blk++) begin : gen_bid_m10k
            M10K_256_40 bid_m10k (
                .q(bid_m10k_read_data[blk]),
                .d(bid_m10k_write_data[blk]),
                .write_address(bid_m10k_write_addr[blk]),
                .read_address(bid_m10k_read_addr[blk]),
                .we(bid_m10k_we[blk]),
                .clk(clk)
            );
        end
        
        // Instantiate M10K blocks for ask buffer
        for (blk = 0; blk < NUM_M10K_BLOCKS; blk++) begin : gen_ask_m10k
            M10K_256_40 ask_m10k (
                .q(ask_m10k_read_data[blk]),
                .d(ask_m10k_write_data[blk]),
                .write_address(ask_m10k_write_addr[blk]),
                .read_address(ask_m10k_read_addr[blk]),
                .we(ask_m10k_we[blk]),
                .clk(clk)
            );
        end
    endgenerate
    
    // Buffer read data (registered for 2-cycle read latency)
    entry_t bid_buffer_read_q [0:BUFFER_SIZE-1];
    entry_t ask_buffer_read_q [0:BUFFER_SIZE-1];
    
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
            // Initialize M10K control signals
            for (int i = 0; i < NUM_M10K_BLOCKS; i++) begin
                bid_m10k_we[i] <= 1'b0;
                ask_m10k_we[i] <= 1'b0;
                bid_m10k_write_data[i] <= '0;
                ask_m10k_write_data[i] <= '0;
                bid_m10k_write_addr[i] <= '0;
                ask_m10k_write_addr[i] <= '0;
            end
        end else begin
            valid_out <= 1'b0;
            
            // Default: disable all write enables
            for (int i = 0; i < NUM_M10K_BLOCKS; i++) begin
                bid_m10k_we[i] <= 1'b0;
                ask_m10k_we[i] <= 1'b0;
            end
            
            if (valid_in) begin
                if (!side_in) begin  // Bid
                    // Read-modify-write: need to read current value first
                    // For now, simplified approach - will need state machine for RMW
                    entry_t current_entry;
                    current_entry.qty = bid_buffer_read_q[buffer_index].qty + delta_qty_in;
                    current_entry.valid = (current_entry.qty > 0);
                    
                    bid_m10k_write_data[write_block_sel] <= {7'b0, current_entry};  // Pad to 40 bits
                    bid_m10k_write_addr[write_block_sel] <= write_block_addr;
                    bid_m10k_we[write_block_sel] <= 1'b1;
                end else begin  // Ask
                    entry_t current_entry;
                    current_entry.qty = ask_buffer_read_q[buffer_index].qty + delta_qty_in;
                    current_entry.valid = (current_entry.qty > 0);
                    
                    ask_m10k_write_data[write_block_sel] <= {7'b0, current_entry};  // Pad to 40 bits
                    ask_m10k_write_addr[write_block_sel] <= write_block_addr;
                    ask_m10k_we[write_block_sel] <= 1'b1;
                end
            end
            
            // Continuously read all entries for reduction tree (broadcast read addresses)
            for (int i = 0; i < NUM_M10K_BLOCKS; i++) begin
                for (int j = 0; j < 256; j++) begin
                    automatic int addr_idx = i * 256 + j;
                    bid_m10k_read_addr[i] <= j[7:0];
                    ask_m10k_read_addr[i] <= j[7:0];
                end
            end
            
            // Register M10K read outputs
            for (int i = 0; i < NUM_M10K_BLOCKS; i++) begin
                for (int j = 0; j < 256; j++) begin
                    automatic int addr_idx = i * 256 + j;
                    if (addr_idx < BUFFER_SIZE) begin
                        bid_buffer_read_q[addr_idx] <= bid_m10k_read_data[i][32:0];
                        ask_buffer_read_q[addr_idx] <= ask_m10k_read_data[i][32:0];
                    end
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

                bid_left_masked_addr = bid_buffer_read_q[bid_left_idx].valid ? bid_left_idx : '0;
                bid_right_masked_addr = bid_buffer_read_q[bid_right_idx].valid ? bid_right_idx : '0;

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

                ask_left_masked_addr = ask_buffer_read_q[ask_left_idx].valid ? ask_left_idx : {PRICE_WIDTH{1'b1}};
                ask_right_masked_addr = ask_buffer_read_q[ask_right_idx].valid ? ask_right_idx : {PRICE_WIDTH{1'b1}};

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
    assign best_bid_qty = bid_buffer_read_q[gen_reduction_arrays[NUM_STAGES].bid_stage[0]].qty;
    
    assign best_ask_price = gen_reduction_arrays[NUM_STAGES].ask_stage[0] + LIMIT_DOWN_PRICE;
    assign best_ask_qty = ask_buffer_read_q[gen_reduction_arrays[NUM_STAGES].ask_stage[0]].qty;
    
endmodule: orderbook