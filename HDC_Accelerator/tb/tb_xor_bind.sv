// =============================================================================
// Testbench   : tb_xor_bind
// Target      : rtl/common/xor_bind.sv
// Language    : SystemVerilog
// Description : Self-checking testbench verifying:
//                 1. Basic XOR correctness against directed + randomized
//                    vector pairs.
//                 2. The self-inverse property:  A ^ A == 0.
//                 3. The commutative property:   A ^ B == B ^ A.
//               These three checks directly verify the mathematical
//               properties the rest of the design (encoder, unbinding
//               reasoning in the report) relies on.
// =============================================================================

`timescale 1ns / 1ps

module tb_xor_bind;

    localparam int D = 8192;               // Scaled to 8192 bits
    localparam int NUM_RANDOM_TESTS = 50;

    logic [D-1:0] vec_a, vec_b;
    logic [D-1:0] bound_vec;
    logic [D-1:0] bound_vec_swapped;

    int errors;
    int test_num;

    // DUT instantiations
    xor_bind #(.D(D)) dut (
        .vec_a     (vec_a),
        .vec_b     (vec_b),
        .bound_vec (bound_vec)
    );

    xor_bind #(.D(D)) dut_swapped (
        .vec_a     (vec_b),
        .vec_b     (vec_a),
        .bound_vec (bound_vec_swapped)
    );

    // 8192-bit Random Vector Generator
    function automatic logic [D-1:0] generate_wide_random();
        logic [D-1:0] rand_vec;
        for (int i = 0; i < D; i += 32) begin
            rand_vec[i +: 32] = $urandom();
        end
        return rand_vec;
    endfunction

    // Task using Hexadecimal (%h) formatting instead of Binary (%b)
    task automatic run_test(input logic [D-1:0] a, input logic [D-1:0] b, input string label);
        logic [D-1:0] expected;
        begin
            vec_a = a;
            vec_b = b;
            expected = a ^ b;
            #1;

            if (bound_vec !== expected) begin
                $display("[FAIL][XOR ] test %0d (%s): expected=%h got=%h",
                         test_num, label, expected, bound_vec);
                errors++;
            end else begin
                $display("[PASS][XOR ] test %0d (%s): matching expected result",
                         test_num, label);
            end

            if (bound_vec !== bound_vec_swapped) begin
                $display("[FAIL][COMM] test %0d (%s): commutativity failed", test_num, label);
                errors++;
            end else begin
                $display("[PASS][COMM] test %0d (%s): commutativity holds", test_num, label);
            end

            test_num++;
        end
    endtask

    initial begin
        errors   = 0;
        test_num = 0;

        // Directed corner cases for parameterized width D
        run_test('0, '0, "both_zero");
        run_test('1, '1, "both_ones");
        run_test({(D/2){2'b10}}, {(D/2){2'b01}}, "alternating_complementary");

        // Self-inverse test: A ^ A == 0
        vec_a = generate_wide_random();
        vec_b = vec_a;
        #1;
        if (bound_vec !== '0) begin
            $display("[FAIL][SELF-INV] A^A did not produce zero vector");
            errors++;
        end else begin
            $display("[PASS][SELF-INV] A^A == 0 confirmed for D=%0d", D);
        end
        test_num++;

        // Wide randomized tests
        for (int k = 0; k < NUM_RANDOM_TESTS; k++) begin
            run_test(generate_wide_random(), generate_wide_random(), "random_wide");
        end

        if (errors == 0)
            $display("\n=== tb_xor_bind (D=%0d): ALL %0d TESTS PASSED ===\n", D, test_num);
        else
            $display("\n=== tb_xor_bind (D=%0d): %0d FAILURES out of %0d TESTS ===\n", D, errors, test_num);

        $finish;
    end

endmodule