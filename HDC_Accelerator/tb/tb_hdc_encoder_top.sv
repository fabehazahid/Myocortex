// =============================================================================
// Testbench   : tb_hdc_encoder_top
// Target      : rtl/encoder/hdc_encoder_top.sv
// Language    : SystemVerilog
// Description : Two test sections:
//                 A. Small-D (D=8), NUM_SLOTS=3 (odd, no tie-break),
//                    NUM_LEVELS=4 -- directed test. Since MEM_FILE is left
//                    empty at instantiation, id_rom/level_rom contents are
//                    preloaded directly via HIERARCHICAL REFERENCE into the
//                    DUT's internal ROM arrays (dut.u_id_rom.mem,
//                    dut.u_level_rom.mem) -- a standard verification
//                    technique for testing memory-backed modules before real
//                    mem_init/*.mem files exist. Mirrors the worked example
//                    structure from Benatti et al. Eq. 1 (E_i XOR V_l(i),
//                    bundled).
//                 B. Large-D (D=8192), NUM_SLOTS=8 (even -> tie-break
//                    path exercised), NUM_LEVELS=22 (the real Benatti
//                    quantization level count) -- realistic-scale randomized
//                    stress test, same chunked-random-generation and
//                    summary-only-reporting fixes as earlier testbenches.
// =============================================================================

`timescale 1ns / 1ps

module tb_hdc_encoder_top;

    localparam time CLK_PERIOD = 10ns;
    int errors;
    int test_num;

    logic clk;
    logic rst_n;

    initial clk = 1'b0;
    always #(CLK_PERIOD/2) clk = ~clk;

    // =====================================================================
    // SECTION A: Small-D directed test (odd NUM_SLOTS, no tie-break)
    // =====================================================================
    localparam int D_SMALL   = 8;
    localparam int NC_SMALL  = 3;
    localparam int NL_SMALL  = 4;
    localparam int LVL_W_SMALL = $clog2(NL_SMALL);

    logic [LVL_W_SMALL-1:0] level_idx_small [NC_SMALL];
    logic                   valid_in_small;
    logic [D_SMALL-1:0]     window_hv_small;
    logic                   valid_out_small;

    hdc_encoder_top #(
        .D                       (D_SMALL),
        .NUM_SLOTS            (NC_SMALL),
        .NUM_LEVELS              (NL_SMALL),
        .ENCODER_REGISTER_OUTPUT (1'b0),
        .ID_MEM_FILE             (""),   // left empty -> preloaded below via hierarchical reference
        .LEVEL_MEM_FILE          ("")
    ) dut_small (
        .clk                (clk),
        .rst_n              (rst_n),
        .level_idx_in       (level_idx_small),
        .valid_in           (valid_in_small),
        .window_hypervector (window_hv_small),
        .valid_out          (valid_out_small)
    );

    // Known, hand-chosen ID and level vectors for the directed test
    // (preloaded via hierarchical reference into the DUT's ROM arrays)
    logic [D_SMALL-1:0] known_id    [NC_SMALL];
    logic [D_SMALL-1:0] known_level [NL_SMALL];

    task automatic preload_small_roms;
        begin
            known_id[0] = 8'b1100_0011;
            known_id[1] = 8'b0011_1100;
            known_id[2] = 8'b1010_0101;

            known_level[0] = 8'b0000_0000;
            known_level[1] = 8'b1111_1111;
            known_level[2] = 8'b0110_1001;
            known_level[3] = 8'b1001_0110;

            for (int i = 0; i < NC_SMALL; i++)
                dut_small.u_id_rom.mem[i] = known_id[i];
            for (int i = 0; i < NL_SMALL; i++)
                dut_small.u_level_rom.mem[i] = known_level[i];
        end
    endtask

    // Independent reference model mirroring Benatti Eq. 1: bind each
    // channel's ID to its chosen level, then majority-vote bundle (odd
    // NUM_SLOTS here, so no tie-break term needed).
    function automatic logic [D_SMALL-1:0] expected_encode_small(input logic [LVL_W_SMALL-1:0] lvl_choice [NC_SMALL]);
        logic [D_SMALL-1:0] bound [NC_SMALL];
        logic [D_SMALL-1:0] result;
        int cnt;
        for (int c = 0; c < NC_SMALL; c++)
            bound[c] = known_id[c] ^ known_level[lvl_choice[c]];
        for (int b = 0; b < D_SMALL; b++) begin
            cnt = 0;
            for (int c = 0; c < NC_SMALL; c++) cnt += bound[c][b];
            result[b] = (cnt > (NC_SMALL/2));
        end
        return result;
    endfunction

    task automatic run_test_small(input logic [LVL_W_SMALL-1:0] lvl_choice [NC_SMALL], input string label);
        logic [D_SMALL-1:0] expected;
        begin
            expected = expected_encode_small(lvl_choice);

            // Drive 1ns AFTER the clock edge (avoids a testbench/DUT race at the
            // edge), then check while valid_in is STILL HIGH: the encoder is
            // combinational here, so valid_out == valid_in and would read 0
            // if we deasserted first.
            @(posedge clk);
            #1;
            for (int c = 0; c < NC_SMALL; c++)
                level_idx_small[c] = lvl_choice[c];
            valid_in_small = 1'b1;
            #1;

            if (!valid_out_small) begin
                $display("[FAIL][VALID] test %0d (%s): valid_out did not assert", test_num, label);
                errors++;
            end else if (window_hv_small !== expected) begin
                $display("[FAIL][ENC  ] test %0d (%s): expected=%b got=%b",
                          test_num, label, expected, window_hv_small);
                errors++;
            end else begin
                $display("[PASS][ENC  ] test %0d (%s): window_hypervector=%b",
                          test_num, label, window_hv_small);
            end
            @(posedge clk);
            #1;
            valid_in_small = 1'b0;
            test_num++;
        end
    endtask

    // =====================================================================
    // SECTION B: Large-D, realistic-scale stress test (even NUM_SLOTS,
    // tie-break path exercised, real NUM_LEVELS=22)
    // =====================================================================
    localparam int D_LARGE   = 8192;
    localparam int NC_LARGE  = 8;
    localparam int NL_LARGE  = 22;   // the real Benatti et al. quantization level count
    localparam int LVL_W_LARGE = $clog2(NL_LARGE);
    localparam int NUM_LARGE_TESTS = 6;

    logic [LVL_W_LARGE-1:0] level_idx_large [NC_LARGE];
    logic                   valid_in_large;
    logic [D_LARGE-1:0]     window_hv_large;
    logic                   valid_out_large;

    hdc_encoder_top #(
        .D                       (D_LARGE),
        .NUM_SLOTS            (NC_LARGE),
        .NUM_LEVELS              (NL_LARGE),
        .ENCODER_REGISTER_OUTPUT (1'b0),
        .ID_MEM_FILE             (""),
        .LEVEL_MEM_FILE          ("")
    ) dut_large (
        .clk                (clk),
        .rst_n              (rst_n),
        .level_idx_in       (level_idx_large),
        .valid_in           (valid_in_large),
        .window_hypervector (window_hv_large),
        .valid_out          (valid_out_large)
    );

    logic [D_LARGE-1:0] known_id_large    [NC_LARGE];
    logic [D_LARGE-1:0] known_level_large [NL_LARGE];

    // chunked random generation, carried from earlier testbenches
    function automatic logic [D_LARGE-1:0] rand_vec_large();
        localparam int PADDED_D = ((D_LARGE + 31) / 32) * 32;
        logic [PADDED_D-1:0] tmp;
        tmp = '0;
        for (int i = 0; i < PADDED_D; i += 32) begin
            tmp[i +: 32] = $urandom;
        end
        return tmp[D_LARGE-1:0];
    endfunction

    task automatic preload_large_roms;
        begin
            for (int i = 0; i < NC_LARGE; i++) begin
                known_id_large[i] = rand_vec_large();
                dut_large.u_id_rom.mem[i] = known_id_large[i];
            end
            for (int i = 0; i < NL_LARGE; i++) begin
                known_level_large[i] = rand_vec_large();
                dut_large.u_level_rom.mem[i] = known_level_large[i];
            end
        end
    endtask

    // Independent reference model: same Eq. 1 bind-then-bundle logic, now
    // including the even-NUM_SLOTS tie-break rule (XOR of the first two
    // BOUND vectors, matching majority_bundle.sv's semantics exactly --
    // the tie-break operates on bound_vecs, not on raw id/level vectors).
    task automatic run_test_large(input string label);
        logic [LVL_W_LARGE-1:0] lvl_choice [NC_LARGE];
        logic [D_LARGE-1:0]     bound [NC_LARGE];
        logic [D_LARGE-1:0]     tiebreak;
        logic [D_LARGE-1:0]     expected;
        int cnt;
        int mismatch_count;
        begin
            for (int c = 0; c < NC_LARGE; c++)
                lvl_choice[c] = $urandom_range(0, NL_LARGE - 1);  // small range, safe for $urandom_range

            for (int c = 0; c < NC_LARGE; c++)
                bound[c] = known_id_large[c] ^ known_level_large[lvl_choice[c]];

            tiebreak = bound[0] ^ bound[1];  // NC_LARGE=8 is even -> tie-break active, mirrors majority_bundle.sv

            for (int b = 0; b < D_LARGE; b++) begin
                cnt = 0;
                for (int c = 0; c < NC_LARGE; c++) cnt += bound[c][b];
                cnt += tiebreak[b];
                expected[b] = (cnt > ((NC_LARGE + 1) / 2));
            end

            @(posedge clk);
            #1;
            for (int c = 0; c < NC_LARGE; c++)
                level_idx_large[c] = lvl_choice[c];
            valid_in_large = 1'b1;
            #1;

            mismatch_count = $countones(expected ^ window_hv_large);

            if (!valid_out_large) begin
                $display("[FAIL][VALID] test %0d (%s): valid_out did not assert", test_num, label);
                errors++;
            end else if (mismatch_count != 0) begin
                $display("[FAIL][LARGE] test %0d (%s): %0d / %0d bits mismatched",
                          test_num, label, mismatch_count, D_LARGE);
                errors++;
            end else begin
                $display("[PASS][LARGE] test %0d (%s): all %0d bits match",
                          test_num, label, D_LARGE);
            end
            @(posedge clk);
            #1;
            valid_in_large = 1'b0;
            test_num++;
        end
    endtask

    // =====================================================================
    // Stimulus
    // =====================================================================
    initial begin
        logic [LVL_W_SMALL-1:0] choice_a [NC_SMALL];
        logic [LVL_W_SMALL-1:0] choice_b [NC_SMALL];
        logic [LVL_W_SMALL-1:0] choice_c [NC_SMALL];

        errors       = 0;
        test_num     = 0;
        rst_n        = 1'b0;
        valid_in_small = 1'b0;
        valid_in_large = 1'b0;

        repeat (2) @(posedge clk);
        rst_n = 1'b1;
        @(posedge clk);

        // -------- Section A --------
        preload_small_roms();

        choice_a = '{2, 0, 3};  // channel0->level2, channel1->level0, channel2->level3
        run_test_small(choice_a, "worked_example_1");

        choice_b = '{1, 1, 1};  // all channels at the same level
        run_test_small(choice_b, "same_level_all_channels");

        choice_c = '{3, 2, 1};
        run_test_small(choice_c, "worked_example_2");

        // -------- Section B --------
        preload_large_roms();
        for (int k = 0; k < NUM_LARGE_TESTS; k++) begin
            run_test_large("random_large_encode");
        end

        // -------- Summary --------
        if (errors == 0)
            $display("\n=== tb_hdc_encoder_top: ALL %0d TESTS PASSED ===\n", test_num);
        else
            $display("\n=== tb_hdc_encoder_top: %0d FAILURES out of %0d TESTS ===\n", errors, test_num);

        $finish;
    end

endmodule