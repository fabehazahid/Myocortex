// =============================================================================
// Module      : popcount
// Project     : MyoCortex HDC Accelerator
// Language    : SystemVerilog (synthesizable subset, Vivado-compatible)
// Description : Counts the number of '1' bits in an input vector of width
//               WIDTH. This is THE core primitive reused everywhere in the
//               accelerator:
//                 - Hamming distance  = popcount(A ^ B)
//                 - Majority bundling = per-bit count of 1s across N input
//                   hypervectors, compared against a threshold
//
//               Implemented as a simple combinational summation. Vivado will
//               infer an efficient adder-tree (compressor-based) from this
//               description -- no need to hand-build the tree explicitly.
//               WIDTH is a compile-time parameter, so the for-loop below is
//               fully unrolled at elaboration time: standard, synthesizable
//               practice, not a simulation-only construct.
//
//               An optional output register is provided (REGISTER_OUTPUT) for
//               once WIDTH grows large (e.g. D = 2000+) and the combinational
//               popcount tree becomes the critical timing path. Leave at 0
//               for small-width unit testing.
// =============================================================================

module popcount #(
    parameter int WIDTH           = 8192,                // input vector width (small for unit tests, scaled later)
    parameter bit REGISTER_OUTPUT = 1'b0,              // 0 = pure combinational, 1 = registered (adds 1 cycle latency)
    parameter int OUT_WIDTH       = $clog2(WIDTH + 1)  // minimum bits needed to represent count 0..WIDTH
)(
    input  logic                  clk,       // only used if REGISTER_OUTPUT = 1
    input  logic                  rst_n,     // only used if REGISTER_OUTPUT = 1, active-low
    input  logic [WIDTH-1:0]      data_in,   // input bit vector to count 1s in
    output logic [OUT_WIDTH-1:0]  count_out  // number of 1 bits in data_in
);

    // -------------------------------------------------------------------
    // Combinational bit-counting function.
    // Synthesizable: WIDTH is a parameter (compile-time constant), so this
    // loop is fully unrolled per-instance at elaboration time.
    // -------------------------------------------------------------------
    function automatic logic [OUT_WIDTH-1:0] count_ones(input logic [WIDTH-1:0] vec);
        logic [OUT_WIDTH-1:0] sum;
        sum = '0;
        for (int i = 0; i < WIDTH; i++) begin
            sum += vec[i];
        end
        return sum;
    endfunction

    logic [OUT_WIDTH-1:0] count_comb;

    always_comb begin
        count_comb = count_ones(data_in);
    end

    // -------------------------------------------------------------------
    // Optional output register -- bypassed (wired straight through) when
    // REGISTER_OUTPUT = 0. generate/if keeps zero extra logic when unused.
    // -------------------------------------------------------------------
    generate
        if (REGISTER_OUTPUT) begin : gen_registered
            logic [OUT_WIDTH-1:0] count_reg;

            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n)
                    count_reg <= '0;
                else
                    count_reg <= count_comb;
            end

            assign count_out = count_reg;
        end else begin : gen_combinational
            assign count_out = count_comb;
        end
    endgenerate

endmodule


// Summary for MyoCortex Development StrategyKeep it combinational (REGISTER_OUTPUT = 0) initially: 
// This lets us verify module functionality quickly without worrying about cycle latency alignment across sub-modules
// .Evaluate in Vivado Timing Analysis later: Once the top-level accelerator is built, Vivado will highlight the critical path.
// Toggle REGISTER_OUTPUT = 1 if timing fails: If $D = 1024$ causes setup time violations at 100 MHz, 
// setting REGISTER_OUTPUT = 1 inserts pipeline registers automatically, immediately closing timing without requiring an RTL rewrite.