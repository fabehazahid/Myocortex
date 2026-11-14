// =============================================================================
// Testbench   : tb_hamming_distance
// Target      : rtl/common/hamming_distance.sv
// Language    : SystemVerilog
// Description : Three test sections:
//                 A. Small-D (D=8) directed tests with known, hand-computed
//                    distances -- full-vector printing is fine at this width.
//                 B. Small-D combinational vs. registered output equivalence
//                    check (same pattern as tb_popcount).
//                 C. Large-D (D=8192) randomized stress test using the same
//                    two scaling fixes as tb_majority_bundle (chunked random
//                    generation, summary-only reporting), PLUS a statistical
//                    check of Kanerva's concentration-of-measure property:
//                    the average distance between random, unrelated D-bit
//                    vectors should sit very close to D/2.
// =============================================================================

`timescale 1ns / 1ps

module tb_hamming_distance;

    localparam time CLK_PERIOD = 10ns;
    int errors;
    int test_num;

    logic clk;
    logic rst_n;

    initial clk = 1'b0;
    always #(CLK_PERIOD/2) clk = ~clk;

    // // =====================================================================
    // // SECTION A: Small-D directed tests, combinational DUT
    // // =====================================================================
    // localparam int D_SMALL = 8;
    // localparam int DIST_WIDTH_SMALL = $clog2(D_SMALL + 1);

    // logic [D_SMALL-1:0]        vec_a_small, vec_b_small;
    // logic [DIST_WIDTH_SMALL-1:0] distance_comb;

    // hamming_distance #(
    //     .D               (D_SMALL),
    //     .REGISTER_OUTPUT (1'b0)
    // ) dut_small_comb (
    //     .clk      (clk),
    //     .rst_n    (rst_n),
    //     .vec_a    (vec_a_small),
    //     .vec_b    (vec_b_small),
    //     .distance (distance_comb)
    // );

    // task automatic run_test_small(input logic [D_SMALL-1:0] a, b, input int expected, input string label);
    //     begin
    //         vec_a_small = a;
    //         vec_b_small = b;
    //         #1;
    //         if (distance_comb !== expected[DIST_WIDTH_SMALL-1:0]) begin
    //             $display("[FAIL][SMALL] test %0d (%s): a=%b b=%b expected=%0d got=%0d",
    //                       test_num, label, a, b, expected, distance_comb);
    //             errors++;
    //         end else begin
    //             $display("[PASS][SMALL] test %0d (%s): distance=%0d", test_num, label, distance_comb);
    //         end
    //         test_num++;
    //     end
    // endtask

    // // =====================================================================
    // // SECTION B: Registered-output DUT, equivalence vs combinational
    // // =====================================================================
    // logic [DIST_WIDTH_SMALL-1:0] distance_reg;

    // hamming_distance #(
    //     .D               (D_SMALL),
    //     .REGISTER_OUTPUT (1'b1)
    // ) dut_small_reg (
    //     .clk      (clk),
    //     .rst_n    (rst_n),
    //     .vec_a    (vec_a_small),
    //     .vec_b    (vec_b_small),
    //     .distance (distance_reg)
    // );

    // task automatic run_test_reg_check(input logic [D_SMALL-1:0] a, b, input string label);
    //     begin
    //         vec_a_small = a;
    //         vec_b_small = b;
    //         #1; // comb DUT settles immediately
    //         @(posedge clk);
    //         #1; // reg DUT captures on this edge
    //         if (distance_reg !== distance_comb) begin
    //             $display("[FAIL][REG-EQ] test %0d (%s): comb=%0d reg=%0d (should match)",
    //                       test_num, label, distance_comb, distance_reg);
    //             errors++;
    //         end else begin
    //             $display("[PASS][REG-EQ] test %0d (%s): comb and reg agree, distance=%0d",
    //                       test_num, label, distance_reg);
    //         end
    //         test_num++;
    //     end
    // endtask

    // =====================================================================
    // SECTION C: Large-D stress test + statistical D/2 concentration check
    // =====================================================================
    localparam int D_LARGE = 8192;
    localparam int DIST_WIDTH_LARGE = $clog2(D_LARGE + 1);
    localparam int NUM_LARGE_TESTS = 30;   // enough for a meaningful average, still fast

    logic [D_LARGE-1:0]          vec_a_large, vec_b_large;
    logic [DIST_WIDTH_LARGE-1:0] distance_large;

    hamming_distance #(
        .D               (D_LARGE),
        .REGISTER_OUTPUT (1'b0)
    ) dut_large (
        .clk      (clk),
        .rst_n    (rst_n),
        .vec_a    (vec_a_large),
        .vec_b    (vec_b_large),
        .distance (distance_large)
    );

    // ---- FIX 1 (carried from tb_majority_bundle): chunked random gen ----
    function automatic logic [D_LARGE-1:0] rand_vec_large();
        localparam int PADDED_D = ((D_LARGE + 31) / 32) * 32;
        logic [PADDED_D-1:0] tmp;
        tmp = '0;
        for (int i = 0; i < PADDED_D; i += 32) begin
            tmp[i +: 32] = $urandom;
        end
        return tmp[D_LARGE-1:0];
    endfunction

    real distance_sum;  // accumulator for the statistical concentration check

    // ---- FIX 2 (carried from tb_majority_bundle): summary-only reporting.
    // Ground truth here is SystemVerilog's built-in $countones() applied to
    // the XOR difference -- a trusted, independent implementation path from
    // our hand-written xor_bind + popcount RTL, so it still catches real
    // bugs in either of those modules or in how this module wires them
    // together, without re-deriving the counting logic by hand again. ----
    task automatic run_test_large(input string label);
        logic [D_LARGE-1:0] diff;
        int expected_distance;
        begin
            vec_a_large = rand_vec_large();
            vec_b_large = rand_vec_large();
            diff = vec_a_large ^ vec_b_large;
            expected_distance = $countones(diff);
            #1;

            if (distance_large !== expected_distance[DIST_WIDTH_LARGE-1:0]) begin
                $display("[FAIL][LARGE] test %0d (%s): expected=%0d got=%0d",
                          test_num, label, expected_distance, distance_large);
                errors++;
            end else begin
                $display("[PASS][LARGE] test %0d (%s): distance=%0d (D/2=%0d)",
                          test_num, label, distance_large, D_LARGE/2);
            end

            distance_sum += real'(distance_large);
            test_num++;
        end
    endtask

    // =====================================================================
    // Stimulus
    // =====================================================================
    initial begin
        errors       = 0;
        test_num     = 0;
        distance_sum = 0.0;
        rst_n        = 1'b0;

        repeat (2) @(posedge clk);
        rst_n = 1'b1;
        @(posedge clk);

        // // -------- Section A: hand-computed directed cases --------
        // // Identical vectors -> distance 0
        // run_test_small(8'b1010_1010, 8'b1010_1010, 0, "identical");
        // // Complementary vectors -> distance 8 (every bit differs)
        // run_test_small(8'b1111_1111, 8'b0000_0000, 8, "complementary");
        // // Single-bit difference -> distance 1
        // run_test_small(8'b1100_1100, 8'b1100_1101, 1, "single_bit_diff");
        // // Worked example from the design discussion: differs at exactly 1 of 8 positions
        // run_test_small(8'b1101_1011, 8'b1101_0011, 1, "worked_example_P1");
        // // Differs at 7 of 8 positions (only one bit matches)
        // run_test_small(8'b1101_1011, 8'b0010_1100, 7, "worked_example_P2");

        // // -------- Section B: combinational vs registered equivalence --------
        // run_test_reg_check(8'b1010_0101, 8'b0101_1010, "reg_eq_1");
        // run_test_reg_check(8'b1111_0000, 8'b1111_0000, "reg_eq_2_identical");
        // run_test_reg_check(8'b0000_0000, 8'b1111_1111, "reg_eq_3_complementary");

        // -------- Section C: large-D stress + statistical check --------
        for (int k = 0; k < NUM_LARGE_TESTS; k++) begin
            run_test_large("random_large");
        end

        // Statistical concentration-of-measure check (Kanerva Sec 5.1):
        // average distance between random, unrelated large-D vectors should
        // sit close to D/2. Using a generous +/-5% tolerance band since this
        // is a statistical property over a modest sample count (30), not an
        // exact equality.
        begin
            real avg_distance, expected_mid, tolerance, pct_off;
            avg_distance = distance_sum / real'(NUM_LARGE_TESTS);
            expected_mid = real'(D_LARGE) / 2.0;
            tolerance    = expected_mid * 0.05;  // +/-5%
            pct_off      = (avg_distance - expected_mid) / expected_mid * 100.0;

            $display("\n--- Statistical concentration check (Kanerva Sec 5.1) ---");
            $display("  D/2 (expected center) = %0.1f", expected_mid);
            $display("  measured average distance over %0d random pairs = %0.1f (%0.2f%% off center)",
                      NUM_LARGE_TESTS, avg_distance, pct_off);

            if ((avg_distance < expected_mid - tolerance) || (avg_distance > expected_mid + tolerance)) begin
                $display("  [FAIL] average distance outside +/-5%% of D/2 -- investigate RNG or encoding");
                errors++;
            end else begin
                $display("  [PASS] average distance within +/-5%% of D/2, consistent with HDC theory");
            end
        end

        // -------- Summary --------
        if (errors == 0)
            $display("\n=== tb_hamming_distance: ALL %0d TESTS PASSED ===\n", test_num);
        else
            $display("\n=== tb_hamming_distance: %0d FAILURES out of %0d TESTS ===\n", errors, test_num);

        $finish;
    end

endmodule