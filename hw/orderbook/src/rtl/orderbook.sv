import _pkg::*;

module orderbook #(
    parameter BUFFER_SIZE = 4096,  // Now supports 4096 entries using M10K blocks
    parameter LIMIT_DOWN_PRICE = 27963, // 279.63, opening price 299.91
    parameter PRICE_WIDTH = 32,
    parameter QTY_WIDTH = 32,
    parameter M10K_BLOCK_SIZE = 256,  // Size of each M10K block
    parameter NUM_M10K_BLOCKS = BUFFER_SIZE / M10K_BLOCK_SIZE  // Number of M10K blocks needed
)(
    input  logic                     CLOCK_50,
    input  logic                     rst_n,
    input  side_t                    side_in,
    input  logic [PRICE_WIDTH-1:0]   price_in,
    input  logic [QTY_WIDTH-1:0]     delta_qty_in,
    input  logic                     valid_in,
    // Best bid outputs
    output logic [PRICE_WIDTH-1:0]   best_bid_price,
    output logic [QTY_WIDTH-1:0]     best_bid_qty,
    output logic                     best_bid_valid,
    // Best ask outputs
    output logic [PRICE_WIDTH-1:0]   best_ask_price,
    output logic [QTY_WIDTH-1:0]     best_ask_qty,
    output logic                     best_ask_valid
);

    // PLL signals
    logic clk;              // PLL output clock
    logic pll_locked;       // PLL lock status
    logic rst_n_sync;       // Synchronized reset: active when rst_n AND pll_locked
    
    // Instantiate PLL
    pll_ip u_pll (
        .clk_clk            (CLOCK_50),
        .reset_reset_n      (rst_n),
        .pll_0_outclk0_clk  (clk),
        .pll_0_locked_export(pll_locked)
    );
    
    // Combine external reset with PLL lock status
    // System stays in reset until PLL is locked and external reset is released
    assign rst_n_sync = rst_n & pll_locked;

    logic [PRICE_WIDTH-1:0] buffer_index;
    always_comb begin
        buffer_index = (price_in - LIMIT_DOWN_PRICE);
    end

    typedef struct packed {
        logic [QTY_WIDTH-1:0]   qty;
        logic                   valid;
    } entry_t;

    // Pre-computed block base addresses to reduce arithmetic in critical path
    localparam logic [PRICE_WIDTH-1:0] BLOCK_BASE_PRICE [0:NUM_M10K_BLOCKS-1] = '{
        LIMIT_DOWN_PRICE + (0 * M10K_BLOCK_SIZE),
        LIMIT_DOWN_PRICE + (1 * M10K_BLOCK_SIZE),
        LIMIT_DOWN_PRICE + (2 * M10K_BLOCK_SIZE),
        LIMIT_DOWN_PRICE + (3 * M10K_BLOCK_SIZE),
        LIMIT_DOWN_PRICE + (4 * M10K_BLOCK_SIZE),
        LIMIT_DOWN_PRICE + (5 * M10K_BLOCK_SIZE),
        LIMIT_DOWN_PRICE + (6 * M10K_BLOCK_SIZE),
        LIMIT_DOWN_PRICE + (7 * M10K_BLOCK_SIZE),
        LIMIT_DOWN_PRICE + (8 * M10K_BLOCK_SIZE),
        LIMIT_DOWN_PRICE + (9 * M10K_BLOCK_SIZE),
        LIMIT_DOWN_PRICE + (10 * M10K_BLOCK_SIZE),
        LIMIT_DOWN_PRICE + (11 * M10K_BLOCK_SIZE),
        LIMIT_DOWN_PRICE + (12 * M10K_BLOCK_SIZE),
        LIMIT_DOWN_PRICE + (13 * M10K_BLOCK_SIZE),
        LIMIT_DOWN_PRICE + (14 * M10K_BLOCK_SIZE),
        LIMIT_DOWN_PRICE + (15 * M10K_BLOCK_SIZE)
    };

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
    
    // State machine for read-modify-write and reduction
    typedef enum logic [2:0] {
        IDLE,
        READ_START,
        READ_WAIT,
        MODIFY_COMPUTE,
        MODIFY_WRITE,
        REDUCE_SCAN,
        REDUCE_TREE
    } state_t;
    
    state_t state, next_state;
    
    // Registered inputs for pipelined operation
    logic signed [QTY_WIDTH-1:0] delta_qty_reg;
    side_t side_reg;
    logic [$clog2(NUM_M10K_BLOCKS)-1:0] block_sel_reg;
    logic [7:0] block_addr_reg;
    
    // Entry unpacking/packing
    entry_t current_entry, new_entry;
    entry_t current_entry_reg;  // Pipeline register after mux
    logic signed [QTY_WIDTH-1:0] new_qty_signed;
    logic signed [QTY_WIDTH-1:0] new_qty_signed_reg;  // Pipeline register for addition result
    
    // Best bid/ask structures
    typedef struct packed {
        logic [PRICE_WIDTH-1:0] price;
        logic [QTY_WIDTH-1:0]   qty;
        logic                   valid;
    } best_entry_t;
    
    // Per-block best (16 blocks) - from scanning all 256 addresses
    best_entry_t bid_block[0:15];
    best_entry_t ask_block[0:15];
    
    // Reduction tree stages (hard-coded)
    best_entry_t bid_stage8[0:7];   // 16→8
    best_entry_t ask_stage8[0:7];
    best_entry_t bid_stage4[0:3];   // 8→4
    best_entry_t ask_stage4[0:3];
    best_entry_t bid_stage2[0:1];   // 4→2
    best_entry_t ask_stage2[0:1];
    best_entry_t bid_final;         // 2→1
    best_entry_t ask_final;
    
    // Scan counters
    logic [8:0] scan_addr;  // 0 to M10K_BLOCK_SIZE (scan all addresses in block)
    logic [8:0] scan_addr_delayed;  // Delayed version to avoid subtraction
    logic [3:0] tree_stage; // Which reduction stage we're in
    logic write_done;       // Buffer flag for MODIFY_WRITE state
    
    // State machine
    always_ff @(posedge clk) begin
        if (!rst_n_sync) begin
            state <= IDLE;
        end else begin
            state <= next_state;
        end
    end
    
    always_comb begin
        next_state = state;
        case (state)
            IDLE: begin
                if (valid_in) begin
                    next_state = READ_START;
                end
            end
            
            READ_START: begin
                next_state = READ_WAIT;
            end
            
            READ_WAIT: begin
                next_state = MODIFY_COMPUTE;
            end
            
            MODIFY_COMPUTE: begin
                next_state = MODIFY_WRITE;
            end
            
            MODIFY_WRITE: begin
                if (write_done) begin
                    next_state = REDUCE_SCAN;
                end
            end
            
            REDUCE_SCAN: begin
                if (scan_addr == M10K_BLOCK_SIZE[8:0]) begin  // After reading all addresses in block
                    next_state = REDUCE_TREE;
                end
            end
            
            REDUCE_TREE: begin
                if (tree_stage == 4'd5) begin  // After 5 stages (16→8→4→2→1→done)
                    next_state = IDLE;
                end
            end
            
            default: next_state = IDLE;
        endcase
    end
    
    // Control logic
    always_ff @(posedge clk) begin
        if (!rst_n_sync) begin
            delta_qty_reg <= '0;
            side_reg <= SIDE_BID;
            block_sel_reg <= '0;
            block_addr_reg <= '0;
            scan_addr <= '0;
            scan_addr_delayed <= '0;
            tree_stage <= '0;
            write_done <= 1'b0;
            current_entry_reg <= '0;
            new_qty_signed_reg <= '0;
            
            // Initialize outputs
            best_bid_price <= '0;
            best_bid_qty <= '0;
            best_bid_valid <= 1'b0;
            best_ask_price <= '0;
            best_ask_qty <= '0;
            best_ask_valid <= 1'b0;
            
            // Initialize all control signals
            for (int i = 0; i < NUM_M10K_BLOCKS; i++) begin
                bid_m10k_we[i] <= 1'b0;
                ask_m10k_we[i] <= 1'b0;
                bid_m10k_write_addr[i] <= '0;
                ask_m10k_write_addr[i] <= '0;
                bid_m10k_read_addr[i] <= '0;
                ask_m10k_read_addr[i] <= '0;
                bid_m10k_write_data[i] <= '0;
                ask_m10k_write_data[i] <= '0;
                
                bid_block[i] <= '{price: '0, qty: '0, valid: 1'b0};
                ask_block[i] <= '{price: '0, qty: '0, valid: 1'b0};
            end
            
        end else begin
            // Default: disable all write enables
            for (int i = 0; i < NUM_M10K_BLOCKS; i++) begin
                bid_m10k_we[i] <= 1'b0;
                ask_m10k_we[i] <= 1'b0;
            end
            
            case (state)
                IDLE: begin
                    if (valid_in) begin
                        // Register inputs
                        delta_qty_reg <= $signed(delta_qty_in);
                        side_reg <= side_in;
                        block_sel_reg <= write_block_sel;
                        block_addr_reg <= write_block_addr;
                        write_done <= 1'b0;
                        
                        // Initiate read
                        if (side_in == SIDE_BID) begin
                            bid_m10k_read_addr[write_block_sel] <= write_block_addr;
                        end else begin
                            ask_m10k_read_addr[write_block_sel] <= write_block_addr;
                        end
                    end
                end
                
                READ_START: begin
                    // Buffer stage - allow read address to settle
                end
                
                READ_WAIT: begin
                    // Register current_entry after the mux (pipeline stage)
                    if (side_reg == SIDE_BID) begin
                        current_entry_reg <= bid_m10k_read_data[block_sel_reg][32:0];
                    end else begin
                        current_entry_reg <= ask_m10k_read_data[block_sel_reg][32:0];
                    end
                end
                
                MODIFY_COMPUTE: begin
                    // Pipeline stage 1: Compute new quantity (adder only)
                    new_qty_signed_reg <= $signed(current_entry_reg.qty) + delta_qty_reg;
                end
                
                MODIFY_WRITE: begin
                    if (!write_done) begin
                        // Pipeline stage 2: Check validity and write (comparator + mux)
                        
                        // Pack new entry with valid bit
                        if (new_qty_signed_reg > 0) begin
                            new_entry.qty = new_qty_signed_reg[QTY_WIDTH-1:0];
                            new_entry.valid = 1'b1;
                        end else begin
                            new_entry.qty = '0;
                            new_entry.valid = 1'b0;
                        end
                        
                        // Write back
                        if (side_reg == SIDE_BID) begin
                            bid_m10k_we[block_sel_reg] <= 1'b1;
                            bid_m10k_write_addr[block_sel_reg] <= block_addr_reg;
                            bid_m10k_write_data[block_sel_reg] <= {7'b0, new_entry};
                        end else begin
                            ask_m10k_we[block_sel_reg] <= 1'b1;
                            ask_m10k_write_addr[block_sel_reg] <= block_addr_reg;
                            ask_m10k_write_data[block_sel_reg] <= {7'b0, new_entry};
                        end
                        
                        write_done <= 1'b1;  // Set flag for next cycle
                    end else begin
                        // Second cycle - initialize scan
                        scan_addr <= 9'd0;
                        for (int i = 0; i < NUM_M10K_BLOCKS; i++) begin
                            bid_block[i].valid <= 1'b0;
                            ask_block[i].valid <= 1'b0;
                            bid_m10k_read_addr[i] <= 8'd0;
                            ask_m10k_read_addr[i] <= 8'd0;
                        end
                    end
                end
                
                REDUCE_SCAN: begin
                    if (scan_addr > 9'd0) begin
                        // Scan all 256 addresses of each block
                        for (int i = 0; i < NUM_M10K_BLOCKS; i++) begin
                            automatic entry_t bid_entry = bid_m10k_read_data[i][32:0];
                            automatic entry_t ask_entry = ask_m10k_read_data[i][32:0];
                            automatic logic [PRICE_WIDTH-1:0] bid_price;
                            automatic logic [PRICE_WIDTH-1:0] ask_price;

                            // Calculate price level using pre-computed base and delayed address (avoids subtraction)
                            bid_price = BLOCK_BASE_PRICE[i] + scan_addr_delayed;
                            ask_price = BLOCK_BASE_PRICE[i] + scan_addr_delayed;

                            // Best bid: keep larger price
                            if (bid_entry.valid && (!bid_block[i].valid || bid_price > bid_block[i].price)) begin
                                bid_block[i].price <= bid_price;
                                bid_block[i].qty <= bid_entry.qty;
                                bid_block[i].valid <= 1'b1;
                            end

                            // Best ask: keep smaller price
                            if (ask_entry.valid && (!ask_block[i].valid || ask_price < ask_block[i].price)) begin
                                ask_block[i].price <= ask_price;
                                ask_block[i].qty <= ask_entry.qty;
                                ask_block[i].valid <= 1'b1;
                            end
                        end
                    end
                    
                    if (scan_addr == M10K_BLOCK_SIZE[8:0]) begin
                        tree_stage <= 4'd0;
                    end else begin
                        scan_addr <= scan_addr + 9'd1;
                        scan_addr_delayed <= scan_addr;
                        for (int i = 0; i < NUM_M10K_BLOCKS; i++) begin
                            bid_m10k_read_addr[i] <= scan_addr[7:0] + 8'd1;
                            ask_m10k_read_addr[i] <= scan_addr[7:0] + 8'd1;
                        end
                    end
                end
                
                REDUCE_TREE: begin
                    case (tree_stage)
                        4'd0: begin  // 16→8 reduction
                            // Hard-coded comparisons
                            // Compare block[0] vs block[1] → stage8[0]
                            if (bid_block[1].valid && (!bid_block[0].valid || bid_block[1].price > bid_block[0].price)) begin
                                bid_stage8[0] <= bid_block[1];
                            end else begin
                                bid_stage8[0] <= bid_block[0];
                            end
                            if (ask_block[1].valid && (!ask_block[0].valid || ask_block[1].price < ask_block[0].price)) begin
                                ask_stage8[0] <= ask_block[1];
                            end else begin
                                ask_stage8[0] <= ask_block[0];
                            end
                            
                            // block[2] vs block[3] → stage8[1]
                            if (bid_block[3].valid && (!bid_block[2].valid || bid_block[3].price > bid_block[2].price)) begin
                                bid_stage8[1] <= bid_block[3];
                            end else begin
                                bid_stage8[1] <= bid_block[2];
                            end
                            if (ask_block[3].valid && (!ask_block[2].valid || ask_block[3].price < ask_block[2].price)) begin
                                ask_stage8[1] <= ask_block[3];
                            end else begin
                                ask_stage8[1] <= ask_block[2];
                            end
                            
                            // block[4] vs block[5] → stage8[2]
                            if (bid_block[5].valid && (!bid_block[4].valid || bid_block[5].price > bid_block[4].price)) begin
                                bid_stage8[2] <= bid_block[5];
                            end else begin
                                bid_stage8[2] <= bid_block[4];
                            end
                            if (ask_block[5].valid && (!ask_block[4].valid || ask_block[5].price < ask_block[4].price)) begin
                                ask_stage8[2] <= ask_block[5];
                            end else begin
                                ask_stage8[2] <= ask_block[4];
                            end
                            
                            // block[6] vs block[7] → stage8[3]
                            if (bid_block[7].valid && (!bid_block[6].valid || bid_block[7].price > bid_block[6].price)) begin
                                bid_stage8[3] <= bid_block[7];
                            end else begin
                                bid_stage8[3] <= bid_block[6];
                            end
                            if (ask_block[7].valid && (!ask_block[6].valid || ask_block[7].price < ask_block[6].price)) begin
                                ask_stage8[3] <= ask_block[7];
                            end else begin
                                ask_stage8[3] <= ask_block[6];
                            end
                            
                            // block[8] vs block[9] → stage8[4]
                            if (bid_block[9].valid && (!bid_block[8].valid || bid_block[9].price > bid_block[8].price)) begin
                                bid_stage8[4] <= bid_block[9];
                            end else begin
                                bid_stage8[4] <= bid_block[8];
                            end
                            if (ask_block[9].valid && (!ask_block[8].valid || ask_block[9].price < ask_block[8].price)) begin
                                ask_stage8[4] <= ask_block[9];
                            end else begin
                                ask_stage8[4] <= ask_block[8];
                            end
                            
                            // block[10] vs block[11] → stage8[5]
                            if (bid_block[11].valid && (!bid_block[10].valid || bid_block[11].price > bid_block[10].price)) begin
                                bid_stage8[5] <= bid_block[11];
                            end else begin
                                bid_stage8[5] <= bid_block[10];
                            end
                            if (ask_block[11].valid && (!ask_block[10].valid || ask_block[11].price < ask_block[10].price)) begin
                                ask_stage8[5] <= ask_block[11];
                            end else begin
                                ask_stage8[5] <= ask_block[10];
                            end
                            
                            // block[12] vs block[13] → stage8[6]
                            if (bid_block[13].valid && (!bid_block[12].valid || bid_block[13].price > bid_block[12].price)) begin
                                bid_stage8[6] <= bid_block[13];
                            end else begin
                                bid_stage8[6] <= bid_block[12];
                            end
                            if (ask_block[13].valid && (!ask_block[12].valid || ask_block[13].price < ask_block[12].price)) begin
                                ask_stage8[6] <= ask_block[13];
                            end else begin
                                ask_stage8[6] <= ask_block[12];
                            end
                            
                            // block[14] vs block[15] → stage8[7]
                            if (bid_block[15].valid && (!bid_block[14].valid || bid_block[15].price > bid_block[14].price)) begin
                                bid_stage8[7] <= bid_block[15];
                            end else begin
                                bid_stage8[7] <= bid_block[14];
                            end
                            if (ask_block[15].valid && (!ask_block[14].valid || ask_block[15].price < ask_block[14].price)) begin
                                ask_stage8[7] <= ask_block[15];
                            end else begin
                                ask_stage8[7] <= ask_block[14];
                            end
                            
                            tree_stage <= 4'd1;
                        end
                        
                        4'd1: begin  // 8→4 reduction
                            // stage8[0] vs stage8[1] → stage4[0]
                            if (bid_stage8[1].valid && (!bid_stage8[0].valid || bid_stage8[1].price > bid_stage8[0].price)) begin
                                bid_stage4[0] <= bid_stage8[1];
                            end else begin
                                bid_stage4[0] <= bid_stage8[0];
                            end
                            if (ask_stage8[1].valid && (!ask_stage8[0].valid || ask_stage8[1].price < ask_stage8[0].price)) begin
                                ask_stage4[0] <= ask_stage8[1];
                            end else begin
                                ask_stage4[0] <= ask_stage8[0];
                            end
                            
                            // stage8[2] vs stage8[3] → stage4[1]
                            if (bid_stage8[3].valid && (!bid_stage8[2].valid || bid_stage8[3].price > bid_stage8[2].price)) begin
                                bid_stage4[1] <= bid_stage8[3];
                            end else begin
                                bid_stage4[1] <= bid_stage8[2];
                            end
                            if (ask_stage8[3].valid && (!ask_stage8[2].valid || ask_stage8[3].price < ask_stage8[2].price)) begin
                                ask_stage4[1] <= ask_stage8[3];
                            end else begin
                                ask_stage4[1] <= ask_stage8[2];
                            end
                            
                            // stage8[4] vs stage8[5] → stage4[2]
                            if (bid_stage8[5].valid && (!bid_stage8[4].valid || bid_stage8[5].price > bid_stage8[4].price)) begin
                                bid_stage4[2] <= bid_stage8[5];
                            end else begin
                                bid_stage4[2] <= bid_stage8[4];
                            end
                            if (ask_stage8[5].valid && (!ask_stage8[4].valid || ask_stage8[5].price < ask_stage8[4].price)) begin
                                ask_stage4[2] <= ask_stage8[5];
                            end else begin
                                ask_stage4[2] <= ask_stage8[4];
                            end
                            
                            // stage8[6] vs stage8[7] → stage4[3]
                            if (bid_stage8[7].valid && (!bid_stage8[6].valid || bid_stage8[7].price > bid_stage8[6].price)) begin
                                bid_stage4[3] <= bid_stage8[7];
                            end else begin
                                bid_stage4[3] <= bid_stage8[6];
                            end
                            if (ask_stage8[7].valid && (!ask_stage8[6].valid || ask_stage8[7].price < ask_stage8[6].price)) begin
                                ask_stage4[3] <= ask_stage8[7];
                            end else begin
                                ask_stage4[3] <= ask_stage8[6];
                            end
                            
                            tree_stage <= 4'd2;
                        end
                        
                        4'd2: begin  // 4→2 reduction
                            // stage4[0] vs stage4[1] → stage2[0]
                            if (bid_stage4[1].valid && (!bid_stage4[0].valid || bid_stage4[1].price > bid_stage4[0].price)) begin
                                bid_stage2[0] <= bid_stage4[1];
                            end else begin
                                bid_stage2[0] <= bid_stage4[0];
                            end
                            if (ask_stage4[1].valid && (!ask_stage4[0].valid || ask_stage4[1].price < ask_stage4[0].price)) begin
                                ask_stage2[0] <= ask_stage4[1];
                            end else begin
                                ask_stage2[0] <= ask_stage4[0];
                            end
                            
                            // stage4[2] vs stage4[3] → stage2[1]
                            if (bid_stage4[3].valid && (!bid_stage4[2].valid || bid_stage4[3].price > bid_stage4[2].price)) begin
                                bid_stage2[1] <= bid_stage4[3];
                            end else begin
                                bid_stage2[1] <= bid_stage4[2];
                            end
                            if (ask_stage4[3].valid && (!ask_stage4[2].valid || ask_stage4[3].price < ask_stage4[2].price)) begin
                                ask_stage2[1] <= ask_stage4[3];
                            end else begin
                                ask_stage2[1] <= ask_stage4[2];
                            end
                            
                            tree_stage <= 4'd3;
                        end
                        
                        4'd3: begin  // 2→1 reduction
                            // stage2[0] vs stage2[1] → final
                            if (bid_stage2[1].valid && (!bid_stage2[0].valid || bid_stage2[1].price > bid_stage2[0].price)) begin
                                bid_final <= bid_stage2[1];
                            end else begin
                                bid_final <= bid_stage2[0];
                            end
                            if (ask_stage2[1].valid && (!ask_stage2[0].valid || ask_stage2[1].price < ask_stage2[0].price)) begin
                                ask_final <= ask_stage2[1];
                            end else begin
                                ask_final <= ask_stage2[0];
                            end
                            
                            tree_stage <= 4'd4;
                        end
                        
                        4'd4: begin  // Latch outputs
                            best_bid_price <= bid_final.price;
                            best_bid_qty <= bid_final.qty;
                            best_bid_valid <= bid_final.valid;
                            best_ask_price <= ask_final.price;
                            best_ask_qty <= ask_final.qty;
                            best_ask_valid <= ask_final.valid;
                            
                            tree_stage <= 4'd5;
                        end
                        
                        default: begin
                            // Done, transition to IDLE
                        end
                    endcase
                end
            endcase
        end
    end
    
endmodule: orderbook