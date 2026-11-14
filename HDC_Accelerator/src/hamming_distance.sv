// =============================================================================
// Module      : hamming_distance
// Project     : MyoCortex HDC Accelerator
// Language    : SystemVerilog
// Description : Computes the Hamming distance between two D-bit hypervectors:
//                   distance = popcount(vec_a XOR vec_b)
//               i.e. the number of bit positions at which they differ
//               (Kanerva 2009, Sec 5.1). This is THE similarity metric used
//               in the associative memory's argmin classification step.
//
//               Deliberately a thin composition of the two primitives already
//               built and verified independently (xor_bind, popcount) rather
//               than a re-implementation -- this keeps the design's trust
//               base small: if xor_bind and popcount are each individually
//               correct, this module is correct by construction, and its own
//               testbench exists mainly to verify the WIRING, not to
//               re-derive XOR/counting correctness from scratch.
//
//               Useful interpretation for the report/viva: for D-bit random,
//               unrelated hypervectors, the expected distance concentrates
//               tightly around D/2 (Kanerva Sec 5.1) -- this is exactly the
//               "no confident match" reference point the associative memory's
//               confidence check is built around.
// =============================================================================

module hamming_distance #(
    parameter int D               = 8192,   // hypervector dimension (small for unit testing; real D later)
    parameter bit REGISTER_OUTPUT = 1'b0 // 0 = combinational, 1 = registered distance output
)(
    input  logic                            clk,
    input  logic                            rst_n,
    input  logic [D-1:0]                    vec_a,
    input  logic [D-1:0]                    vec_b,
    output logic [$clog2(D+1)-1:0]          distance   // 0 .. D, number of differing bit positions
);

    localparam int DIST_WIDTH = $clog2(D + 1);

    // -------------------------------------------------------------------
    // Stage 1: binding/difference vector via the shared xor_bind primitive
    // -------------------------------------------------------------------
    logic [D-1:0] diff_vec;

    xor_bind #(
        .D (D)
    ) u_xor_bind (
        .vec_a     (vec_a),
        .vec_b     (vec_b),
        .bound_vec (diff_vec)
    );

    // -------------------------------------------------------------------
    // Stage 2: count the differing bits via the shared popcount primitive
    // -------------------------------------------------------------------
    popcount #(
        .WIDTH           (D),
        .REGISTER_OUTPUT (REGISTER_OUTPUT)
    ) u_popcount (
        .clk       (clk),
        .rst_n     (rst_n),
        .data_in   (diff_vec),
        .count_out (distance)
    );

endmodule