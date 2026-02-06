module avalon_st_sink_counter (
    input  logic        clk,
    input  logic        reset_n,

    input  logic [31:0] data,
    input  logic        valid,
    output logic        ready,
    input  logic        startofpacket,
    input  logic        endofpacket,
    input  logic [1:0]  empty,

    output logic [31:0] sop_count,
    output logic [31:0] eop_count,
    output logic [31:0] seq_error_count,
    output logic [31:0] packet_error_count
);

/* Trigger ideas:
Trigger on seq_error_count != 0
Trigger on packet_error_count != 0
Trigger on startofpacket && in_packet (illegal SOP)
Trigger on endofpacket && !in_packet */

    logic [15:0] curr_seq /* synthesis noprune */;

    //assign ready = 1'b1; // always ready

    // ---------------------------------------------------------
    // 1. Simple Toggle Logic for Ready
    // ---------------------------------------------------------
    logic ready_reg;

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            ready_reg <= 1'b0;
        end else begin
            ready_reg <= ~ready_reg; // Invert every cycle (25 MHz effective)
        end
    end

    assign ready = ready_reg;

    /* ----------------------------
     * Reset synchronizer (2-flop)
     * ---------------------------- */
    logic reset_ff1, reset_sync;

    always_ff @(posedge clk) begin
        reset_ff1  <= reset_n;
        reset_sync <= reset_ff1;
    end

    /* ----------------------------
     * Packet tracking
     * ---------------------------- */
    logic        in_packet;
    logic [15:0] last_seq /* synthesis noprune */;
    logic        seq_valid;

    always_ff @(posedge clk) begin
        if (!reset_sync) begin
            in_packet          <= 1'b0;
            sop_count          <= 0;
            eop_count          <= 0;
            packet_error_count <= 0;
        end else if (valid) begin
            if (startofpacket) begin
                sop_count <= sop_count + 1;

                if (in_packet) begin
                    // SOP while already in packet = malformed
                    packet_error_count <= packet_error_count + 1;
                end

                in_packet <= 1'b1;
            end

            if (endofpacket) begin
                eop_count <= eop_count + 1;

                if (!in_packet) begin
                    // EOP without SOP
                    packet_error_count <= packet_error_count + 1;
                end

                in_packet <= 1'b0;
            end
        end
    end

   // logic [31:0] data_be /* synthesis noprune */; 

/*     assign data_be = {
      data[7:0],
      data[15:8],
      data[23:16],
      data[31:24]
    }; */

    //assign curr_seq = data[15:8];

logic [15:0] eop_seen_count /* synthesis noprune */; 

    /* ----------------------------
     * Sequence checking
     * Sequence is injected in upper
     * 16 bits of EOP beat (data[31:16])
     * ---------------------------- */
    always_ff @(posedge clk) begin
        if (!reset_sync) begin
            last_seq        <= 0;
            seq_valid       <= 1'b0;
            seq_error_count <= 0;
        end else if (valid && endofpacket) begin
            //curr_seq <= data[15:8]; // only read sequence on EOP

            if (seq_valid && data[15:8] != last_seq + 1) begin
                seq_error_count <= seq_error_count + 1;
            end

            last_seq  <= data[15:8];
            seq_valid <= 1'b1;
        end
    end

    always_ff @(posedge clk) begin
        if (valid && endofpacket)
            eop_seen_count <= eop_seen_count + 1;
    end


endmodule
