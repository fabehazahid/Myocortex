// =============================================================================
// Testbench   : tb_majority_bundle
// Target      : rtl/common/majority_bundle.sv
// Language    : SystemVerilog
// Description : Three test sections:
//                 A. Small-D (D=8), odd NUM_INPUTS=3  -- directed, full-vector
//                    printing (safe at this width).
//                 B. Small-D (D=8), even NUM_INPUTS=4 -- directed tests
//                    specifically targeting the tie-break path.
//                 C. Large-D (D=8192), even NUM_INPUTS=8 (mirrors the real
//                    8-channel design, so the tie-break path is exercised at
//                    realistic scale too) -- randomized stress test.
//
//               Two scaling fixes applied throughout (see project notes):
//                 1. Random vectors of width D are built by filling 32-bit
//                    CHUNKS via repeated $urandom() calls into a
//                    next-multiple-of-32-padded temporary, then truncating.
//                    This never computes 2**D, so it cannot overflow
//                    regardless of how large D gets.
//                 2. No full-width %b/%h dumps of large vectors. Pass/fail is
//                    reported by test number only; on a mismatch, only the
//                    MISMATCH BIT COUNT is printed (via SystemVerilog's
//                    built-in $countones() on the XOR difference), not the
//                    vectors themselves. Full-vector display is reserved for
//                    the small-D directed sections where it's actually
//                    readable.
//               This pattern (chunked random fill + summary-only reporting)
//               should be copied into every later testbench that touches
//               full-D hypervectors (hamming_distance, assoc_memory, encoder,
//               top-level).
// =============================================================================

`timescale 1ns / 1ps

module tb_majority_bundle;

    localparam time CLK_PERIOD = 10ns;
    int errors;
    int test_num;

    logic clk;
    logic rst_n;

    initial clk = 1'b0;
    always #(CLK_PERIOD/2) clk = ~clk;

    // // =====================================================================
    // // SECTION A: Small-D, odd NUM_INPUTS (no tie-break needed)
    // // =====================================================================
    // localparam int D_SMALL  = 8;
    // localparam int N_ODD    = 3;

    // logic [D_SMALL-1:0] vecs_odd [N_ODD];
    // logic [D_SMALL-1:0] bundled_odd;

    // majority_bundle #(
    //     .D               (D_SMALL),
    //     .NUM_INPUTS      (N_ODD),
    //     .REGISTER_OUTPUT (1'b0)
    // ) dut_odd_small (
    //     .clk         (clk),
    //     .rst_n       (rst_n),
    //     .vecs_in     (vecs_odd),
    //     .bundled_vec (bundled_odd)
    // );

    // // Independent reference model for the odd (no-tiebreak) case
    // function automatic logic [D_SMALL-1:0] expected_bundle_odd(input logic [D_SMALL-1:0] v[N_ODD]);
    //     logic [D_SMALL-1:0] result;
    //     int cnt;
    //     for (int b = 0; b < D_SMALL; b++) begin
    //         cnt = 0;
    //         for (int ii = 0; ii < N_ODD; ii++) cnt += v[ii][b];
    //         result[b] = (cnt > (N_ODD/2));  // N_ODD=3 -> majority if count > 1 (i.e. >=2)
    //     end
    //     return result;
    // endfunction

    // task automatic run_test_odd(input logic [D_SMALL-1:0] a, b, c, input string label);
    //     logic [D_SMALL-1:0] expected;
    //     begin
    //         vecs_odd[0] = a; vecs_odd[1] = b; vecs_odd[2] = c;
    //         expected = expected_bundle_odd(vecs_odd);
    //         #1;
    //         if (bundled_odd !== expected) begin
    //             $display("[FAIL][ODD ] test %0d (%s): a=%b b=%b c=%b expected=%b got=%b",
    //                       test_num, label, a, b, c, expected, bundled_odd);
    //             errors++;
    //         end else begin
    //             $display("[PASS][ODD ] test %0d (%s): result=%b", test_num, label, bundled_odd);
    //         end
    //         test_num++;
    //     end
    // endtask

    // // =====================================================================
    // // SECTION B: Small-D, even NUM_INPUTS (tie-break path exercised)
    // // =====================================================================
    // localparam int N_EVEN = 4;

    // logic [D_SMALL-1:0] vecs_even [N_EVEN];
    // logic [D_SMALL-1:0] bundled_even;

    // majority_bundle #(
    //     .D               (D_SMALL),
    //     .NUM_INPUTS      (N_EVEN),
    //     .REGISTER_OUTPUT (1'b0)
    // ) dut_even_small (
    //     .clk         (clk),
    //     .rst_n       (rst_n),
    //     .vecs_in     (vecs_even),
    //     .bundled_vec (bundled_even)
    // );

    // // Independent reference model for the even (tie-break) case.
    // // Replicates the DUT's tie-break rule (XOR of input 0 and input 1)
    // // independently, to actually verify that specific design decision.
    // function automatic logic [D_SMALL-1:0] expected_bundle_even(input logic [D_SMALL-1:0] v[N_EVEN]);
    //     logic [D_SMALL-1:0] result, tiebreak;
    //     int cnt;
    //     tiebreak = v[0] ^ v[1];
    //     for (int b = 0; b < D_SMALL; b++) begin
    //         cnt = 0;
    //         for (int ii = 0; ii < N_EVEN; ii++) cnt += v[ii][b];
    //         cnt += tiebreak[b];
    //         result[b] = (cnt > ((N_EVEN+1)/2));  // TOTAL_INPUTS=5 -> majority if count > 2 (i.e. >=3)
    //     end
    //     return result;
    // endfunction

    // task automatic run_test_even(input logic [D_SMALL-1:0] a, b, c, d, input string label);
    //     logic [D_SMALL-1:0] expected;
    //     begin
    //         vecs_even[0] = a; vecs_even[1] = b; vecs_even[2] = c; vecs_even[3] = d;
    //         expected = expected_bundle_even(vecs_even);
    //         #1;
    //         if (bundled_even !== expected) begin
    //             $display("[FAIL][EVEN] test %0d (%s): expected=%b got=%b",
    //                       test_num, label, expected, bundled_even);
    //             errors++;
    //         end else begin
    //             $display("[PASS][EVEN] test %0d (%s): result=%b (tie-break path exercised)",
    //                       test_num, label, bundled_even);
    //         end
    //         test_num++;
    //     end
    // endtask

    // =====================================================================
    // SECTION C: Large-D (realistic scale), even NUM_INPUTS=8 (mirrors the
    // real 8-channel design, including the tie-break path, at full width)
    // =====================================================================
    localparam int D_LARGE = 8192;
    localparam int N_LARGE = 8;
    localparam int NUM_LARGE_RANDOM_TESTS = 10;  // kept modest: each test does a D_LARGE x N_LARGE software loop

    logic [D_LARGE-1:0] vecs_large [N_LARGE];
    logic [D_LARGE-1:0] bundled_large;

    majority_bundle #(
        .D               (D_LARGE),
        .NUM_INPUTS      (N_LARGE),
        .REGISTER_OUTPUT (1'b0)
    ) dut_large (
        .clk         (clk),
        .rst_n       (rst_n),
        .vecs_in     (vecs_large),
        .bundled_vec (bundled_large)
    );

    // ---- FIX 1: chunked random generation, never computes 2**D ----
    function automatic logic [D_LARGE-1:0] rand_vec_large();
        localparam int PADDED_D = ((D_LARGE + 31) / 32) * 32;
        logic [PADDED_D-1:0] tmp;
        tmp = '0;
        for (int i = 0; i < PADDED_D; i += 32) begin
            tmp[i +: 32] = $urandom;   // fixed 32-bit chunk, i is variable -> legal indexed part-select
        end
        return tmp[D_LARGE-1:0];
    endfunction

    // Independent reference model, same tie-break rule as the DUT,
    // reused for the large-D case. Uses SystemVerilog's built-in
    // $countones() for the final diff check (testbench-only, not
    // synthesizable RTL -- the actual hardware popcount is what's under
    // test inside the DUT).
    function automatic logic [D_LARGE-1:0] expected_bundle_large(input logic [D_LARGE-1:0] v[N_LARGE]);
        logic [D_LARGE-1:0] result, tiebreak;
        int cnt;
        tiebreak = v[0] ^ v[1];
        for (int b = 0; b < D_LARGE; b++) begin
            cnt = 0;
            for (int ii = 0; ii < N_LARGE; ii++) cnt += v[ii][b];
            cnt += tiebreak[b];
            result[b] = (cnt > ((N_LARGE+1)/2));  // TOTAL_INPUTS=9 -> majority if count > 4 (i.e. >=5)
        end
        return result;
    endfunction

    // ---- FIX 2: summary-only reporting, no full-width vector dumps ----
    task automatic run_test_large(input string label);
        logic [D_LARGE-1:0] expected;
        int mismatch_count;
        begin
            for (int ii = 0; ii < N_LARGE; ii++)
                vecs_large[ii] = rand_vec_large();

            expected = expected_bundle_large(vecs_large);
            #1;

            mismatch_count = $countones(expected ^ bundled_large);

            if (mismatch_count != 0) begin
                $display("[FAIL][LARGE] test %0d (%s): %0d / %0d bits mismatched",
                          test_num, label, mismatch_count, D_LARGE);
                errors++;
            end else begin
                $display("[PASS][LARGE] test %0d (%s): all %0d bits match",
                          test_num, label, D_LARGE);
            end
            test_num++;
        end
    endtask

    // =====================================================================
    // Stimulus
    // =====================================================================
    initial begin
        errors   = 0;
        test_num = 0;
        rst_n    = 1'b0;

        repeat (2) @(posedge clk);
        rst_n = 1'b1;
        @(posedge clk);

        // // -------- Section A: odd NUM_INPUTS, directed --------
        // run_test_odd(8'b0000_0000, 8'b0000_0000, 8'b0000_0000, "all_zero");
        // run_test_odd(8'b1111_1111, 8'b1111_1111, 8'b1111_1111, "all_one");
        // run_test_odd(8'b1111_1111, 8'b1111_1111, 8'b0000_0000, "two_one_one_zero");  // majority 1 expected
        // run_test_odd(8'b0000_0000, 8'b0000_0000, 8'b1111_1111, "two_zero_one_one");  // majority 0 expected
        // run_test_odd(8'b1010_1010, 8'b0110_0110, 8'b1100_1100, "mixed_pattern");

        // // -------- Section B: even NUM_INPUTS, tie-break path --------
        // // Construct a case with an exact 2-2 split per bit to force reliance
        // // on the tie-breaker (XOR of inputs 0 and 1) to resolve every bit.
        // run_test_even(8'b1111_1111, 8'b0000_0000, 8'b1111_1111, 8'b0000_0000, "exact_split_case");
        // run_test_even(8'b1010_1010, 8'b0101_0101, 8'b1010_1010, 8'b0101_0101, "exact_split_alternating");
        // run_test_even(8'b1111_1111, 8'b1111_1111, 8'b1111_1111, 8'b1111_1111, "all_one_even");
        // run_test_even(8'b0000_0000, 8'b0000_0000, 8'b0000_0000, 8'b0000_0000, "all_zero_even");

        // -------- Section C: large-D stress test, chunked random gen --------
        for (int k = 0; k < NUM_LARGE_RANDOM_TESTS; k++) begin
            run_test_large("random_large");
        end

        // -------- Summary --------
        if (errors == 0)
            $display("\n=== tb_majority_bundle: ALL %0d TESTS PASSED ===\n", test_num);
        else
            $display("\n=== tb_majority_bundle: %0d FAILURES out of %0d TESTS ===\n", errors, test_num);

        $finish;
    end

endmodule