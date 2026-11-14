// =============================================================================
// Testbench   : tb_popcount
// Target      : rtl/common/popcount.sv
// Language    : SystemVerilog
// Description : Self-checking testbench. Drives known bit patterns plus
//               randomized vectors at a small WIDTH (readable waveforms,
//               fast sim), computes the expected popcount independently of
//               the DUT's own implementation, and compares both the
//               combinational and registered DUT variants.
// =============================================================================

`timescale 1ns / 1ps

module tb_popcount;

    // -------------------------------------------------------------------
    // Test configuration
    // -------------------------------------------------------------------
    localparam int WIDTH            = 8192;                  // Scaled to 8192 bits
    localparam int OUT_WIDTH        = $clog2(WIDTH + 1);    // 14 bits needed for 0..8192
    localparam time CLK_PERIOD      = 10ns;
    localparam int NUM_RANDOM_TESTS = 20;                    // Kept smaller for fast sim execution

    // -------------------------------------------------------------------
    // DUT signals
    // -------------------------------------------------------------------
    logic                 clk;
    logic                 rst_n;
    logic [WIDTH-1:0]     data_in;

    logic [OUT_WIDTH-1:0] count_out_comb;   // DUT #1: combinational
    logic [OUT_WIDTH-1:0] count_out_reg;    // DUT #2: registered

    int errors;
    int test_num;

    // -------------------------------------------------------------------
    // DUT instantiations
    // -------------------------------------------------------------------
    popcount #(
        .WIDTH           (WIDTH),
        .REGISTER_OUTPUT (1'b0)
    ) dut_comb (
        .clk       (clk),
        .rst_n     (rst_n),
        .data_in   (data_in),
        .count_out (count_out_comb)
    );

    popcount #(
        .WIDTH           (WIDTH),
        .REGISTER_OUTPUT (1'b1)
    ) dut_reg (
        .clk       (clk),
        .rst_n     (rst_n),
        .data_in   (data_in),
        .count_out (count_out_reg)
    );

    // Clock generation
    initial clk = 1'b0;
    always #(CLK_PERIOD/2) clk = ~clk;

    // Reference model
    function automatic int expected_popcount(input logic [WIDTH-1:0] vec);
        int cnt = 0;
        for (int i = 0; i < WIDTH; i++)
            if (vec[i] == 1'b1)
                cnt++;
        return cnt;
    endfunction

    // 8192-bit Random Vector Generator
    function automatic logic [WIDTH-1:0] generate_wide_random();
        logic [WIDTH-1:0] rand_vec;
        for (int i = 0; i < WIDTH; i += 32) begin
            rand_vec[i +: 32] = $urandom();
        end
        return rand_vec;
    endfunction

    // Test execution task
    task automatic run_test(input logic [WIDTH-1:0] vec, input string label);
        int expected;
        begin
            data_in  = vec;
            expected = expected_popcount(vec);

            #1;
            if (count_out_comb !== expected[OUT_WIDTH-1:0]) begin
                $display("[FAIL][COMB] test %0d (%s): expected=%0d got=%0d",
                         test_num, label, expected, count_out_comb);
                errors++;
            end else begin
                $display("[PASS][COMB] test %0d (%s): count=%0d",
                         test_num, label, count_out_comb);
            end

            @(posedge clk);
            #1;
            if (count_out_reg !== expected[OUT_WIDTH-1:0]) begin
                $display("[FAIL][REG ] test %0d (%s): expected=%0d got=%0d",
                         test_num, label, expected, count_out_reg);
                errors++;
            end else begin
                $display("[PASS][REG ] test %0d (%s): count=%0d",
                         test_num, label, count_out_reg);
            end

            test_num++;
        end
    endtask

    // Stimulus
    initial begin
        errors   = 0;
        test_num = 0;
        rst_n    = 1'b0;
        data_in  = '0;

        repeat (2) @(posedge clk);
        rst_n = 1'b1;
        @(posedge clk);

        // Parametric Corner-Case Tests
        run_test('0,                  "all_zeros");
        run_test('1,                  "all_ones");
        run_test({(WIDTH/2){2'b10}},  "alternating_a");
        run_test({(WIDTH/2){2'b01}},  "alternating_b");
        run_test(1'b1,                "single_bit_lsb");
        run_test(1'b1 << (WIDTH-1),   "single_bit_msb");

        // Wide Random Tests
        for (int k = 0; k < NUM_RANDOM_TESTS; k++) begin
            run_test(generate_wide_random(), "random_wide");
        end

        // Summary
        if (errors == 0)
            $display("\n=== tb_popcount (WIDTH=%0d): ALL %0d TESTS PASSED ===\n", WIDTH, test_num);
        else
            $display("\n=== tb_popcount (WIDTH=%0d): %0d FAILURES out of %0d TESTS ===\n", WIDTH, errors, test_num);

        $finish;
    end

endmodule