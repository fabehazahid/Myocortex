// =============================================================================
// Testbench   : tb_hdc_accelerator_top
// Target      : rtl/top/hdc_accelerator_top.sv
// Language    : SystemVerilog
// Description : End-to-end check of level indices -> class_id.
//
//               Reference model: the testbench keeps its own copy of the ID
//               and level vectors, re-implements Benatti Eq. 1 (bind each
//               slot, majority-bundle with the XOR tie-break for even slot
//               counts) and does its own argmin with $countones(). It never
//               looks at the DUT's internals except to PRELOAD the ROMs.
//
//               Sections:
//                 A. Small-D (D=32), 4 slots, 8 levels, 3 classes, REGISTERED
//                    encoder output. Exact-pattern, one-slot-perturbed and
//                    random queries, plus an OVERRUN test (two back-to-back
//                    valid_in pulses -> exactly one result, exactly one
//                    overrun).
//                 B. Large-D (D=8192), 8 slots, 22 levels, 6 classes,
//                    COMBINATIONAL encoder output (the realistic
//                    configuration). Same scaling fixes as earlier
//                    testbenches: chunked random generation, summary-only
//                    reporting.
//
//               Driving convention for ALL testbenches from here on: change
//               inputs 1ns AFTER the clock edge (`@(posedge clk); #1;`), so
//               the DUT can never race the testbench at the edge.
// =============================================================================

`timescale 1ns / 1ps

module tb_hdc_accelerator_top;

    localparam time CLK_PERIOD = 10ns;
    int errors;
    int test_num;

    logic clk;
    logic rst_n;

    initial clk = 1'b0;
    always #(CLK_PERIOD/2) clk = ~clk;

    // =====================================================================
    // SECTION A : small D, registered encoder, even slot count (tie-break)
    // =====================================================================
    localparam int D_S  = 32;
    localparam int NS_S = 4;
    localparam int NL_S = 8;
    localparam int NC_S = 3;
    localparam int LW_S = $clog2(NL_S);
    localparam int CW_S = $clog2(NC_S);
    localparam int DW_S = $clog2(D_S + 1);

    logic [LW_S-1:0] lvl_s [NS_S];
    logic            valid_in_s;
    logic            pw_en_s;
    logic [CW_S-1:0] pw_addr_s;
    logic [D_S-1:0]  pw_data_s;
    logic            busy_s, overrun_s, rv_s;
    logic [CW_S-1:0] cid_s;
    logic [DW_S-1:0] md_s;

    hdc_accelerator_top #(
        .D                       (D_S),
        .NUM_SLOTS               (NS_S),
        .NUM_LEVELS              (NL_S),
        .NUM_CLASSES             (NC_S),
        .ENCODER_REGISTER_OUTPUT (1'b1),
        .ID_MEM_FILE             (""),
        .LEVEL_MEM_FILE          ("")
    ) dut_small (
        .clk           (clk),
        .rst_n         (rst_n),
        .level_idx_in  (lvl_s),
        .valid_in      (valid_in_s),
        .proto_wr_en   (pw_en_s),
        .proto_wr_addr (pw_addr_s),
        .proto_wr_data (pw_data_s),
        .busy          (busy_s),
        .overrun       (overrun_s),
        .result_valid  (rv_s),
        .class_id      (cid_s),
        .min_distance  (md_s)
    );

    // Pulse counters (single driver each: only the always block writes them)
    int result_count_s  = 0;
    int overrun_count_s = 0;
    always @(posedge clk) begin
        if (rv_s)      result_count_s++;
        if (overrun_s) overrun_count_s++;
    end

    // Testbench-side copies of everything the reference model needs
    logic [D_S-1:0]  id_s      [NS_S];
    logic [D_S-1:0]  lvlvec_s  [NL_S];
    logic [D_S-1:0]  proto_s   [NC_S];
    logic [LW_S-1:0] pat_s     [NC_S][NS_S];   // one level pattern per class

    function automatic logic [D_S-1:0] rand_vec_s();
        localparam int PADDED_D = ((D_S + 31) / 32) * 32;
        logic [PADDED_D-1:0] tmp;
        tmp = '0;
        for (int i = 0; i < PADDED_D; i += 32) tmp[i +: 32] = $urandom;
        return tmp[D_S-1:0];
    endfunction

    // Benatti Eq. 1 reference. NS_S is even -> tie-break = bound[0]^bound[1].
    function automatic logic [D_S-1:0] encode_ref_s(input logic [LW_S-1:0] pat [NS_S]);
        logic [D_S-1:0] bound [NS_S];
        logic [D_S-1:0] tiebreak, result;
        int cnt;
        for (int c = 0; c < NS_S; c++) bound[c] = id_s[c] ^ lvlvec_s[pat[c]];
        tiebreak = bound[0] ^ bound[1];
        for (int b = 0; b < D_S; b++) begin
            cnt = 0;
            for (int c = 0; c < NS_S; c++) cnt += bound[c][b];
            cnt += tiebreak[b];
            result[b] = (cnt > ((NS_S + 1) / 2));
        end
        return result;
    endfunction

    task automatic load_proto_s(input int addr, input logic [D_S-1:0] data);
        begin
            @(posedge clk); #1;
            pw_en_s   = 1'b1;
            pw_addr_s = addr[CW_S-1:0];
            pw_data_s = data;
            @(posedge clk); #1;
            pw_en_s   = 1'b0;
            proto_s[addr] = data;
        end
    endtask

    // Reference argmin (strict '<', so the lowest index wins ties, same as the DUT)
    task automatic expected_s(input logic [LW_S-1:0] pat [NS_S], output int cls, output int dist);
        logic [D_S-1:0] q;
        int d;
        begin
            q = encode_ref_s(pat);
            dist = D_S + 1;
            cls  = 0;
            for (int k = 0; k < NC_S; k++) begin
                d = $countones(q ^ proto_s[k]);
                if (d < dist) begin
                    dist = d;
                    cls  = k;
                end
            end
        end
    endtask

    task automatic classify_s(input logic [LW_S-1:0] pat [NS_S], input string label);
        int exp_cls, exp_dist;
        begin
            expected_s(pat, exp_cls, exp_dist);

            @(posedge clk); #1;
            for (int c = 0; c < NS_S; c++) lvl_s[c] = pat[c];
            valid_in_s = 1'b1;
            @(posedge clk); #1;
            valid_in_s = 1'b0;

            fork : wait_s
                begin @(posedge rv_s); end
                begin
                    repeat (NC_S + 30) @(posedge clk);
                    $display("[FAIL][TIMEOUT] test %0d (%s): result_valid never asserted", test_num, label);
                    errors++;
                    disable wait_s;
                end
            join_any
            disable wait_s;
            #1;

            if (cid_s !== exp_cls[CW_S-1:0] || md_s !== exp_dist[DW_S-1:0]) begin
                $display("[FAIL][SMALL] test %0d (%s): expected class=%0d dist=%0d, got class=%0d dist=%0d",
                          test_num, label, exp_cls, exp_dist, cid_s, md_s);
                errors++;
            end else begin
                $display("[PASS][SMALL] test %0d (%s): class=%0d dist=%0d", test_num, label, cid_s, md_s);
            end

            // busy must drop again once the result has been delivered
            repeat (3) @(posedge clk);
            #1;
            if (busy_s) begin
                $display("[FAIL][BUSY ] test %0d (%s): busy still high after result", test_num, label);
                errors++;
            end
            test_num++;
        end
    endtask

    // =====================================================================
    // SECTION B : large D, combinational encoder, realistic configuration
    // =====================================================================
    localparam int D_L  = 8192;
    localparam int NS_L = 8;
    localparam int NL_L = 22;
    localparam int NC_L = 6;
    localparam int LW_L = $clog2(NL_L);
    localparam int CW_L = $clog2(NC_L);
    localparam int DW_L = $clog2(D_L + 1);
    localparam int NUM_RANDOM_QUERIES_L = 4;

    logic [LW_L-1:0] lvl_l [NS_L];
    logic            valid_in_l;
    logic            pw_en_l;
    logic [CW_L-1:0] pw_addr_l;
    logic [D_L-1:0]  pw_data_l;
    logic            busy_l, overrun_l, rv_l;
    logic [CW_L-1:0] cid_l;
    logic [DW_L-1:0] md_l;

    hdc_accelerator_top #(
        .D                       (D_L),
        .NUM_SLOTS               (NS_L),
        .NUM_LEVELS              (NL_L),
        .NUM_CLASSES             (NC_L),
        .ENCODER_REGISTER_OUTPUT (1'b0),
        .ID_MEM_FILE             (""),
        .LEVEL_MEM_FILE          ("")
    ) dut_large (
        .clk           (clk),
        .rst_n         (rst_n),
        .level_idx_in  (lvl_l),
        .valid_in      (valid_in_l),
        .proto_wr_en   (pw_en_l),
        .proto_wr_addr (pw_addr_l),
        .proto_wr_data (pw_data_l),
        .busy          (busy_l),
        .overrun       (overrun_l),
        .result_valid  (rv_l),
        .class_id      (cid_l),
        .min_distance  (md_l)
    );

    logic [D_L-1:0]  id_l     [NS_L];
    logic [D_L-1:0]  lvlvec_l [NL_L];
    logic [D_L-1:0]  proto_l  [NC_L];
    logic [LW_L-1:0] pat_l    [NC_L][NS_L];

    // chunked random generation: never computes 2**D (scaling fix #1)
    function automatic logic [D_L-1:0] rand_vec_l();
        localparam int PADDED_D = ((D_L + 31) / 32) * 32;
        logic [PADDED_D-1:0] tmp;
        tmp = '0;
        for (int i = 0; i < PADDED_D; i += 32) tmp[i +: 32] = $urandom;
        return tmp[D_L-1:0];
    endfunction

    function automatic logic [D_L-1:0] encode_ref_l(input logic [LW_L-1:0] pat [NS_L]);
        logic [D_L-1:0] bound [NS_L];
        logic [D_L-1:0] tiebreak, result;
        int cnt;
        for (int c = 0; c < NS_L; c++) bound[c] = id_l[c] ^ lvlvec_l[pat[c]];
        tiebreak = bound[0] ^ bound[1];            // NS_L = 8 is even -> tie-break active
        for (int b = 0; b < D_L; b++) begin
            cnt = 0;
            for (int c = 0; c < NS_L; c++) cnt += bound[c][b];
            cnt += tiebreak[b];
            result[b] = (cnt > ((NS_L + 1) / 2));
        end
        return result;
    endfunction

    task automatic load_proto_l(input int addr, input logic [D_L-1:0] data);
        begin
            @(posedge clk); #1;
            pw_en_l   = 1'b1;
            pw_addr_l = addr[CW_L-1:0];
            pw_data_l = data;
            @(posedge clk); #1;
            pw_en_l   = 1'b0;
            proto_l[addr] = data;
        end
    endtask

    // summary-only reporting (scaling fix #2): never prints a full vector
    task automatic classify_l(input logic [LW_L-1:0] pat [NS_L], input int intended_class, input string label);
        logic [D_L-1:0] q;
        int exp_cls, exp_dist, d;
        begin
            q = encode_ref_l(pat);
            exp_dist = D_L + 1;
            exp_cls  = 0;
            for (int k = 0; k < NC_L; k++) begin
                d = $countones(q ^ proto_l[k]);
                if (d < exp_dist) begin
                    exp_dist = d;
                    exp_cls  = k;
                end
            end

            @(posedge clk); #1;
            for (int c = 0; c < NS_L; c++) lvl_l[c] = pat[c];
            valid_in_l = 1'b1;
            @(posedge clk); #1;
            valid_in_l = 1'b0;

            fork : wait_l
                begin @(posedge rv_l); end
                begin
                    repeat (NC_L + 30) @(posedge clk);
                    $display("[FAIL][TIMEOUT] test %0d (%s): result_valid never asserted", test_num, label);
                    errors++;
                    disable wait_l;
                end
            join_any
            disable wait_l;
            #1;

            if (cid_l !== exp_cls[CW_L-1:0] || md_l !== exp_dist[DW_L-1:0]) begin
                $display("[FAIL][LARGE] test %0d (%s): expected class=%0d dist=%0d, got class=%0d dist=%0d",
                          test_num, label, exp_cls, exp_dist, cid_l, md_l);
                errors++;
            end else if (intended_class >= 0 && cid_l !== intended_class[CW_L-1:0]) begin
                // reference and DUT agree, but the query did not land on the class it was built from.
                // With D=8192 the margin is enormous, so this would point at a stimulus problem.
                $display("[FAIL][LARGE] test %0d (%s): DUT matches reference (class=%0d) but intended class was %0d",
                          test_num, label, cid_l, intended_class);
                errors++;
            end else begin
                $display("[PASS][LARGE] test %0d (%s): class=%0d dist=%0d (D/2=%0d)",
                          test_num, label, cid_l, md_l, D_L/2);
            end

            repeat (3) @(posedge clk);
            #1;
            if (busy_l) begin
                $display("[FAIL][BUSY ] test %0d (%s): busy still high after result", test_num, label);
                errors++;
            end
            test_num++;
        end
    endtask

    // =====================================================================
    // Stimulus
    // =====================================================================
    initial begin
        logic [LW_S-1:0] noisy_s [NS_S];
        logic [LW_S-1:0] rand_pat_s [NS_S];
        logic [LW_S-1:0] x_pat_s [NS_S];
        logic [LW_S-1:0] y_pat_s [NS_S];
        logic [LW_L-1:0] noisy_l [NS_L];
        logic [LW_L-1:0] rand_pat_l [NS_L];
        int rc0, oc0, exp_cls_x, exp_dist_x;

        errors = 0;
        test_num = 0;
        rst_n = 1'b0;
        valid_in_s = 1'b0;  pw_en_s = 1'b0;
        valid_in_l = 1'b0;  pw_en_l = 1'b0;
        for (int c = 0; c < NS_S; c++) lvl_s[c] = '0;
        for (int c = 0; c < NS_L; c++) lvl_l[c] = '0;

        repeat (3) @(posedge clk);
        #1 rst_n = 1'b1;
        repeat (2) @(posedge clk);

        // ================= SECTION A =================
        // preload ID / level ROMs through hierarchical reference
        for (int i = 0; i < NS_S; i++) begin
            id_s[i] = rand_vec_s();
            dut_small.u_encoder.u_id_rom.mem[i] = id_s[i];
        end
        for (int i = 0; i < NL_S; i++) begin
            lvlvec_s[i] = rand_vec_s();
            dut_small.u_encoder.u_level_rom.mem[i] = lvlvec_s[i];
        end

        // one random level pattern per class; its encoding becomes that class's prototype
        for (int k = 0; k < NC_S; k++) begin
            for (int c = 0; c < NS_S; c++) pat_s[k][c] = $urandom_range(0, NL_S - 1);
            load_proto_s(k, encode_ref_s(pat_s[k]));
        end

        // exact patterns -> must return their own class with distance 0
        for (int k = 0; k < NC_S; k++) classify_s(pat_s[k], $sformatf("exact_class_%0d", k));

        // one slot perturbed
        for (int k = 0; k < NC_S; k++) begin
            noisy_s = pat_s[k];
            noisy_s[k % NS_S] = (pat_s[k][k % NS_S] + $urandom_range(1, NL_S - 1)) % NL_S;
            classify_s(noisy_s, $sformatf("one_slot_perturbed_class_%0d", k));
        end

        // random patterns
        for (int r = 0; r < 5; r++) begin
            for (int c = 0; c < NS_S; c++) rand_pat_s[c] = $urandom_range(0, NL_S - 1);
            classify_s(rand_pat_s, "random_pattern");
        end

        // ---- OVERRUN test (registered encoder): two back-to-back valid_in pulses ----
        // Expect: exactly ONE result (for pattern X) and exactly ONE overrun pulse.
        x_pat_s = pat_s[0];
        y_pat_s = pat_s[1];
        expected_s(x_pat_s, exp_cls_x, exp_dist_x);
        rc0 = result_count_s;
        oc0 = overrun_count_s;

        @(posedge clk); #1;
        for (int c = 0; c < NS_S; c++) lvl_s[c] = x_pat_s[c];
        valid_in_s = 1'b1;
        @(posedge clk); #1;
        for (int c = 0; c < NS_S; c++) lvl_s[c] = y_pat_s[c];   // second window, one cycle later
        @(posedge clk); #1;
        valid_in_s = 1'b0;
        repeat (NC_S + 15) @(posedge clk);
        #1;

        if (result_count_s - rc0 != 1) begin
            $display("[FAIL][OVERRUN] test %0d: expected exactly 1 result, got %0d", test_num, result_count_s - rc0);
            errors++;
        end else if (overrun_count_s - oc0 != 1) begin
            $display("[FAIL][OVERRUN] test %0d: expected exactly 1 overrun pulse, got %0d", test_num, overrun_count_s - oc0);
            errors++;
        end else if (cid_s !== exp_cls_x[CW_S-1:0]) begin
            $display("[FAIL][OVERRUN] test %0d: result belongs to the wrong window (expected class %0d, got %0d)",
                      test_num, exp_cls_x, cid_s);
            errors++;
        end else begin
            $display("[PASS][OVERRUN] test %0d: 1 result (class %0d), 1 overrun, second window dropped cleanly",
                      test_num, cid_s);
        end
        test_num++;

        // ================= SECTION B =================
        for (int i = 0; i < NS_L; i++) begin
            id_l[i] = rand_vec_l();
            dut_large.u_encoder.u_id_rom.mem[i] = id_l[i];
        end
        for (int i = 0; i < NL_L; i++) begin
            lvlvec_l[i] = rand_vec_l();
            dut_large.u_encoder.u_level_rom.mem[i] = lvlvec_l[i];
        end

        for (int k = 0; k < NC_L; k++) begin
            for (int c = 0; c < NS_L; c++) pat_l[k][c] = $urandom_range(0, NL_L - 1);
            load_proto_l(k, encode_ref_l(pat_l[k]));
        end

        // one slot perturbed per class: must still land on the class it came from
        for (int k = 0; k < NC_L; k++) begin
            noisy_l = pat_l[k];
            noisy_l[k % NS_L] = (pat_l[k][k % NS_L] + $urandom_range(1, NL_L - 1)) % NL_L;
            classify_l(noisy_l, k, $sformatf("one_slot_perturbed_class_%0d", k));
        end

        // fully random patterns: DUT must agree with the reference (no intended class)
        for (int r = 0; r < NUM_RANDOM_QUERIES_L; r++) begin
            for (int c = 0; c < NS_L; c++) rand_pat_l[c] = $urandom_range(0, NL_L - 1);
            classify_l(rand_pat_l, -1, "random_pattern");
        end

        // ---- Summary ----
        if (errors == 0)
            $display("\n=== tb_hdc_accelerator_top: ALL %0d TESTS PASSED ===\n", test_num);
        else
            $display("\n=== tb_hdc_accelerator_top: %0d FAILURES out of %0d TESTS ===\n", errors, test_num);

        $finish;
    end

endmodule