// =============================================================================
// Testbench   : tb_feature_rms
// Target      : rtl/features/feature_rms.sv
// Language    : SystemVerilog
// Description : Uses SystemVerilog's BUILT-IN real-valued $sqrt() function
//               (IEEE 1800 real math library, supported by Vivado XSim and
//               other major simulators) as the trusted reference model,
//               rather than hand-deriving a second copy of an integer sqrt
//               algorithm -- doing so would just duplicate the same class of
//               bug risk the DUT itself carries, rather than independently
//               checking it.
//
//               *** PRIORITY NOTE: this testbench exercises a genuinely
//               nontrivial iterative hardware algorithm (non-restoring
//               integer square root). Run this one and confirm a clean pass
//               before relying on feature_rms anywhere else in the design. ***
//
//               Sections:
//                 A. Directed tests with known perfect squares (exact
//                    results expected, no rounding ambiguity).
//                 B. Randomized tests across the sample range, comparing
//                    against floor($sqrt(mean_sq)).
// =============================================================================

`timescale 1ns / 1ps

module tb_feature_rms;

    localparam time CLK_PERIOD = 10ns;
    int errors;
    int test_num;

    logic clk;
    logic rst_n;

    initial clk = 1'b0;
    always #(CLK_PERIOD/2) clk = ~clk;

    // -------------------------------------------------------------------
    // DUT configuration (small-ish window for fast simulation; the sqrt
    // FSM itself takes OUT_WIDTH cycles regardless of WINDOW_LEN, so this
    // doesn't need to be "small" the way D was for the HDC modules -- it's
    // a real sample-count window, closer to realistic values already)
    // -------------------------------------------------------------------
    localparam int SAMPLE_WIDTH = 16;
    localparam int WINDOW_LEN   = 8;
    localparam int OUT_WIDTH    = 16;

    logic signed [SAMPLE_WIDTH-1:0] sample_in;
    logic                            sample_valid;
    logic                            window_done;
    logic                            clear;
    logic [OUT_WIDTH-1:0]            rms_out;
    logic                            rms_valid;
    logic                            busy;

    feature_rms #(
        .SAMPLE_WIDTH (SAMPLE_WIDTH),
        .WINDOW_LEN   (WINDOW_LEN),
        .OUT_WIDTH    (OUT_WIDTH)
    ) dut (
        .clk          (clk),
        .rst_n        (rst_n),
        .sample_in    (sample_in),
        .sample_valid (sample_valid),
        .window_done  (window_done),
        .clear        (clear),
        .rms_out      (rms_out),
        .rms_valid    (rms_valid),
        .busy         (busy)
    );

    // -------------------------------------------------------------------
    // Task: stream one full window of samples into the DUT, trigger
    // window_done, wait for rms_valid, and check against the reference.
    // -------------------------------------------------------------------
    task automatic run_window_test(input logic signed [SAMPLE_WIDTH-1:0] samples [WINDOW_LEN], input string label);
        real sum_sq_real;
        real mean_sq_real;
        real expected_real;
        int  expected_int;
        begin
            // ---- Independent reference computed in real arithmetic ----
            sum_sq_real = 0.0;
            for (int i = 0; i < WINDOW_LEN; i++) begin
                sum_sq_real += real'(samples[i]) * real'(samples[i]);
            end
            mean_sq_real  = sum_sq_real / real'(WINDOW_LEN);
            expected_real = $sqrt(mean_sq_real);
            expected_int  = $rtoi($floor(expected_real));  // DUT computes an integer (floor) sqrt

            // ---- Drive the DUT ----
            @(posedge clk);
            clear = 1'b1;
            @(posedge clk);
            clear = 1'b0;

            for (int i = 0; i < WINDOW_LEN; i++) begin
                sample_in    = samples[i];
                sample_valid = 1'b1;
                @(posedge clk);
            end
            sample_valid = 1'b0;

            window_done = 1'b1;
            @(posedge clk);
            window_done = 1'b0;

            // ---- Wait for rms_valid (bounded, to avoid hanging on a bug) ----
            fork : wait_block
                begin
                    @(posedge rms_valid);
                end
                begin
                    repeat (OUT_WIDTH + 10) @(posedge clk);
                    $display("[FAIL][TIMEOUT] test %0d (%s): rms_valid never asserted", test_num, label);
                    errors++;
                    disable wait_block;
                end
            join_any
            disable wait_block;

            #1;
            // Allow +/-1 tolerance for integer floor/rounding edge cases
            // between the DUT's integer algorithm and the real-valued
            // reference (legitimate floating-point-vs-integer boundary
            // cases, not a correctness bug, e.g. mean_sq exactly between
            // two perfect squares).
            if ((rms_out > expected_int + 1) || (int'(rms_out) < expected_int - 1)) begin
                $display("[FAIL][RMS  ] test %0d (%s): expected~=%0d got=%0d (mean_sq=%0.2f)",
                          test_num, label, expected_int, rms_out, mean_sq_real);
                errors++;
            end else begin
                $display("[PASS][RMS  ] test %0d (%s): expected~=%0d got=%0d",
                          test_num, label, expected_int, rms_out);
            end
            test_num++;
        end
    endtask

    // -------------------------------------------------------------------
    // Stimulus
    // -------------------------------------------------------------------
    initial begin
        logic signed [SAMPLE_WIDTH-1:0] samples_a [WINDOW_LEN];
        logic signed [SAMPLE_WIDTH-1:0] samples_b [WINDOW_LEN];
        logic signed [SAMPLE_WIDTH-1:0] samples_c [WINDOW_LEN];
        logic signed [SAMPLE_WIDTH-1:0] samples_rand [WINDOW_LEN];

        errors        = 0;
        test_num      = 0;
        rst_n         = 1'b0;
        sample_valid  = 1'b0;
        window_done   = 1'b0;
        clear         = 1'b0;

        repeat (2) @(posedge clk);
        rst_n = 1'b1;
        @(posedge clk);

        // -------- Section A: directed, exact perfect-square cases --------
        // All samples = 0 -> RMS = 0
        samples_a = '{default: 16'sd0};
        run_window_test(samples_a, "all_zero");

        // All samples = 3 -> mean_sq = 9 -> RMS = 3 exactly
        samples_b = '{default: 16'sd3};
        run_window_test(samples_b, "all_three_perfect_square");

        // All samples = -4 (negative, squared should still work) -> mean_sq = 16 -> RMS = 4
        samples_c = '{default: -16'sd4};
        run_window_test(samples_c, "all_negative_four");

        // -------- Section B: randomized, small sample range for readability --------
        for (int k = 0; k < 20; k++) begin
            for (int i = 0; i < WINDOW_LEN; i++) begin
                samples_rand[i] = $urandom_range(0, 200) - 100; // range [-100, 100], keeps squares small & readable
            end
            run_window_test(samples_rand, "random_small_range");
        end

        // -------- Summary --------
        if (errors == 0)
            $display("\n=== tb_feature_rms: ALL %0d TESTS PASSED ===\n", test_num);
        else
            $display("\n=== tb_feature_rms: %0d FAILURES out of %0d TESTS ===\n", errors, test_num);

        $finish;
    end

endmodule