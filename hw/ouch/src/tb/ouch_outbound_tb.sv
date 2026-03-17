`timescale 1ns/1ps

module ouch_outbound_tb;

    // -------------------------------------------------------------------------
    // 1. Signals & DUT
    // -------------------------------------------------------------------------
    logic clk = 0;
    always #5 clk = ~clk; // 100MHz clock
    logic rst_n;

    // Avalon-ST Interface
    logic [31:0] st_data;
    logic        st_valid;
    logic        st_ready;
    logic        st_startofpacket;
    logic        st_endofpacket;
    logic [1:0]  st_empty;

    // Algo Outputs
    logic        algo_valid;
    logic [1:0]  algo_msg_type;
    logic [63:0] algo_timestamp;
    logic [31:0] algo_userref;
    logic [31:0] algo_qty;
    logic [63:0] algo_price;
    logic [63:0] algo_symbol;
    logic [7:0]  algo_side;
    logic [63:0] algo_order_ref;
    logic [63:0] algo_match_id;
    logic [7:0]  algo_reason;

    // Instantiate DUT
    ouch_outbound dut (.*);

    // -------------------------------------------------------------------------
    // 2. Helper Functions (Packet Builders)
    // -------------------------------------------------------------------------
    typedef byte byteq_t[$];

    // Helper: Pack string to 8 bytes
    function automatic logic [63:0] s2b(string s);
        logic [7:0] b[8];
        for (int i = 0; i < 8; i++)
            b[i] = (i < s.len()) ? s[i] : 8'h20;
        return {b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7]};
    endfunction

    // Builder: Order Accepted ('A') -- 62 bytes (no 2-byte appendage)
    function automatic byteq_t pkt_accepted(
        int uref, string side, int qty, string sym, longint price, longint oref
    );
        byteq_t q;
        byte s_bytes[8];
        s_bytes = {>>byte{sym}};
        
        q.push_back(8'h41); // 'A'
        repeat (8) q.push_back($urandom); // Timestamp
        q.push_back(uref[31:24]);
        q.push_back(uref[23:16]);
        q.push_back(uref[15:8]);
        q.push_back(uref[7:0]);

        if (side == "B") q.push_back("B");
        else             q.push_back("S");

        q.push_back(qty[31:24]);
        q.push_back(qty[23:16]);
        q.push_back(qty[15:8]);
        q.push_back(qty[7:0]);

        foreach (s_bytes[i]) q.push_back(s_bytes[i]);

        q.push_back(price[63:56]);
        q.push_back(price[55:48]);
        q.push_back(price[47:40]);
        q.push_back(price[39:32]);
        q.push_back(price[31:24]);
        q.push_back(price[23:16]);
        q.push_back(price[15:8]);
        q.push_back(price[7:0]);

        q.push_back(0); // TIF
        q.push_back(0); // Display

        q.push_back(oref[63:56]);
        q.push_back(oref[55:48]);
        q.push_back(oref[47:40]);
        q.push_back(oref[39:32]);
        q.push_back(oref[31:24]);
        q.push_back(oref[23:16]);
        q.push_back(oref[15:8]);
        q.push_back(oref[7:0]);

        q.push_back(0); // Cap
        q.push_back(0); // IMS
        q.push_back(0); // Cross
        q.push_back(0); // State

        repeat (14) q.push_back(" "); // ClOrdID

        // No appendage length field

        return q;
    endfunction

    // Builder: Order Executed ('E') -- 34 bytes (no 2-byte appendage, total requested = 34)
    function automatic byteq_t pkt_executed(
        int uref, int qty, longint price, longint match
    );
        byteq_t q;

        q.push_back(8'h45); // 'E'
        repeat (8) q.push_back(0); // Timestamp

        q.push_back(uref[31:24]);
        q.push_back(uref[23:16]);
        q.push_back(uref[15:8]);
        q.push_back(uref[7:0]);

        q.push_back(qty[31:24]);
        q.push_back(qty[23:16]);
        q.push_back(qty[15:8]);
        q.push_back(qty[7:0]);

        q.push_back(price[63:56]);
        q.push_back(price[55:48]);
        q.push_back(price[47:40]);
        q.push_back(price[39:32]);
        q.push_back(price[31:24]);
        q.push_back(price[23:16]);
        q.push_back(price[15:8]);
        q.push_back(price[7:0]);

        q.push_back(0); // Liq Flag

        q.push_back(match[63:56]);
        q.push_back(match[55:48]);
        q.push_back(match[47:40]);
        q.push_back(match[39:32]);
        q.push_back(match[31:24]);
        q.push_back(match[23:16]);
        q.push_back(match[15:8]);
        q.push_back(match[7:0]);

        // Two remaining bytes to make total = 34
        q.push_back(0);
        q.push_back(0);

        return q;
    endfunction

    // Builder: Order Canceled ('C') -- 18 bytes (no 2-byte appendage)
    function automatic byteq_t pkt_canceled(
        int uref, int dec_qty, string reason_str
    );
        byteq_t q;
        byte reason_byte;

        reason_byte = reason_str[0];

        q.push_back(8'h43); // 'C'
        repeat (8) q.push_back(0); // Timestamp

        q.push_back(uref[31:24]);
        q.push_back(uref[23:16]);
        q.push_back(uref[15:8]);
        q.push_back(uref[7:0]);

        q.push_back(dec_qty[31:24]);
        q.push_back(dec_qty[23:16]);
        q.push_back(dec_qty[15:8]);
        q.push_back(dec_qty[7:0]);

        q.push_back(reason_byte);

        // No appendage length field

        return q;
    endfunction

    // -------------------------------------------------------------------------
    // 3. Driver Logic
    // -------------------------------------------------------------------------
    task automatic drive_bus_packet(
        input byteq_t bq,
        input bit back_to_back_start = 0,
        input bit back_to_back_end   = 0
    );
        int words;
        int rem;

        words = (bq.size() + 3) / 4;
        rem   = bq.size() % 4;

        for (int i = 0; i < words; i++) begin
            st_valid         <= 1;
            st_startofpacket <= (i == 0);
            st_endofpacket   <= (i == words - 1);

            // Payload
            st_data[7:0]   <= (i*4   < bq.size()) ? bq[i*4]   : 0;
            st_data[15:8]  <= (i*4+1 < bq.size()) ? bq[i*4+1] : 0;
            st_data[23:16] <= (i*4+2 < bq.size()) ? bq[i*4+2] : 0;
            st_data[31:24] <= (i*4+3 < bq.size()) ? bq[i*4+3] : 0;

            // Empty
            if (i == words - 1)
                st_empty <= (rem == 0) ? 0 : (4 - rem);
            else
                st_empty <= 0;

            // Wait for ready
            do @(posedge clk); while (!st_ready);
        end

        if (!back_to_back_end) begin
            st_valid         <= 0;
            st_startofpacket <= 0;
            st_endofpacket   <= 0;
            st_empty         <= 0;
        end
    endtask

    // -------------------------------------------------------------------------
    // 4. Test Scenarios
    // -------------------------------------------------------------------------
    initial begin
        longint EXP_REF_1   = 10;
        longint EXP_REF_2   = 10;
        longint EXP_MATCH_2 = 64'h11223344;

        rst_n             = 0;
        st_valid          = 0;
        st_startofpacket  = 0;
        st_endofpacket    = 0;
        st_empty          = 0;
        st_data           = '0;

        repeat (5) @(posedge clk);
        rst_n = 1;
        repeat (5) @(posedge clk);

        $display("\n=== TEST 1: Accepted Order (Buy Side) ===");
        $display("Expected bytes = 62, expected final st_empty = 2");
        drive_bus_packet(pkt_accepted(1, "B", 100, "AAPL", 1500000, 9901));

        @(posedge algo_valid);
        if (algo_msg_type == 1 && algo_userref == 1 && algo_side == "B")
            $display("PASS: TEST 1 Accepted Buy decoded correctly");
        else begin
            $error("FAIL: TEST 1 Accepted Buy decode mismatch");
            $display("      Expected: msg_type=1 userref=1 side='B'");
            $display("      Actual  : msg_type=%0d userref=%0d side=%s",
                     algo_msg_type, algo_userref, algo_side);
        end

        while (algo_valid) @(posedge clk);

        // -----------------------------------------------------

        $display("\n=== TEST 2: Canceled Order ===");
        $display("Expected bytes = 18, expected final st_empty = 2");
        drive_bus_packet(pkt_canceled(1, 50, "U"));

        @(posedge algo_valid);
        if (algo_msg_type == 2 && algo_qty == 50 && algo_reason == "U")
            $display("PASS: TEST 2 Canceled decoded correctly");
        else begin
            $error("FAIL: TEST 2 Canceled decode mismatch");
            $display("      Expected: msg_type=2 qty=50 reason='U'");
            $display("      Actual  : msg_type=%0d qty=%0d reason=%s",
                     algo_msg_type, algo_qty, algo_reason);
        end

        while (algo_valid) @(posedge clk);

        // -----------------------------------------------------

        $display("\n=== TEST 3: Executed Order ===");
        $display("Expected bytes = 34, expected final st_empty = 2");
        drive_bus_packet(pkt_executed(1, 25, 1500000, 64'hAABBCCDD));

        @(posedge algo_valid);
        if (algo_msg_type == 3 && algo_qty == 25 && algo_match_id == 64'hAABBCCDD)
            $display("PASS: TEST 3 Executed decoded correctly");
        else begin
            $error("FAIL: TEST 3 Executed decode mismatch");
            $display("      Expected: msg_type=3 qty=25 match_id=%h", 64'hAABBCCDD);
            $display("      Actual  : msg_type=%0d qty=%0d match_id=%h",
                     algo_msg_type, algo_qty, algo_match_id);
        end

        while (algo_valid) @(posedge clk);

        // -----------------------------------------------------

        $display("\n=== TEST 4: Accepted Order (Sell Side) ===");
        $display("Expected bytes = 62, expected final st_empty = 2");
        drive_bus_packet(pkt_accepted(2, "S", 200, "MSFT", 2000000, 9902));

        @(posedge algo_valid);
        if (algo_msg_type == 1 && algo_userref == 2 && algo_side == "S")
            $display("PASS: TEST 4 Accepted Sell decoded correctly");
        else begin
            $error("FAIL: TEST 4 Accepted Sell decode mismatch");
            $display("      Expected: msg_type=1 userref=2 side='S'");
            $display("      Actual  : msg_type=%0d userref=%0d side=%s",
                     algo_msg_type, algo_userref, algo_side);
        end

        while (algo_valid) @(posedge clk);

        // -----------------------------------------------------

        $display("\n=== TEST 5: Back-to-Back Packets (Zero Latency) ===");
        $display("Expected: Accepted final st_empty = 2, Executed final st_empty = 2");

        fork
            begin
                drive_bus_packet(pkt_accepted(EXP_REF_1, "B", 1000, "Z_LAT   ", 5000, 888), 0, 1);
                drive_bus_packet(pkt_executed(EXP_REF_2, 500, 5000, EXP_MATCH_2), 0, 0);
            end

            begin
                fork
                    begin
                        @(posedge algo_valid);
                    end
                    begin
                        repeat (200) @(posedge clk);
                    end
                join_any
                disable fork;

                if (!algo_valid) begin
                    $error("FAIL: TEST 5 Packet 1 timeout waiting for Accepted");
                end else if (algo_msg_type !== 1 || algo_userref !== EXP_REF_1) begin
                    $error("FAIL: TEST 5 Packet 1 Accepted mismatch");
                    $display("      Expected: msg_type=1 userref=%0d", EXP_REF_1);
                    $display("      Actual  : msg_type=%0d userref=%0d",
                             algo_msg_type, algo_userref);
                end else begin
                    $display("PASS: TEST 5 Packet 1 Accepted decoded correctly");
                end

                while (algo_valid) @(posedge clk);

                fork
                    begin
                        @(posedge algo_valid);
                    end
                    begin
                        repeat (200) @(posedge clk);
                    end
                join_any
                disable fork;

                if (!algo_valid) begin
                    $error("FAIL: TEST 5 Packet 2 timeout waiting for Executed");
                end else if (algo_msg_type !== 3 || algo_match_id !== EXP_MATCH_2) begin
                    $error("FAIL: TEST 5 Packet 2 Executed mismatch");
                    $display("      Expected: msg_type=3 match_id=%h", EXP_MATCH_2);
                    $display("      Actual  : msg_type=%0d match_id=%h",
                             algo_msg_type, algo_match_id);
                end else begin
                    $display("PASS: TEST 5 Packet 2 Executed decoded correctly");
                end
            end
        join

        repeat (20) @(posedge clk);
        $display("\n--- All Tests Complete ---");
        $stop;
    end

endmodule