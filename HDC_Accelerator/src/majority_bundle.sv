// =============================================================================
// Module      : majority_bundle
// Project     : MyoCortex HDC Accelerator
// Language    : SystemVerilog
// Description : Implements HDC "bundling" via componentwise majority vote,
//               combining NUM_INPUTS hypervectors into ONE D-bit hypervector
//               that is similar to all of them (Kanerva 2009, Sec 6.3).
//
//               Structure: for every bit position independently, gather the
//               corresponding bit from every input vector into a small
//               TOTAL_INPUTS-wide word, and reuse the `popcount` primitive to
//               count how many of them are 1. If more than half are 1, the
//               output bit is 1. This means majority_bundle is built from D
//               parallel SMALL popcount instances (width = TOTAL_INPUTS,
//               e.g. 9), which is architecturally different from Hamming
//               distance's ONE LARGE popcount tree (width = D) -- the two
//               "popcount" uses in this design have very different resource
//               costs. Worth re-checking actual Vivado utilization for this
//               module specifically once synthesized, since D parallel
//               small-popcount instances can add up faster than a single
//               large reduction tree does.
//
//               Even/odd handling (Benatti et al., TBioCAS 2019, Sec IV-A):
//               majority vote needs an ODD number of inputs to avoid ties.
//               If NUM_INPUTS is even, one extra reproducible "tie-breaker"
//               hypervector is generated as XOR(vecs_in[0], vecs_in[1]) and
//               included in the vote, giving TOTAL_INPUTS = NUM_INPUTS + 1
//               (always odd).
// =============================================================================

module majority_bundle #(
    parameter int D              = 8192,    // hypervector dimension (small for unit testing; real D later)
    parameter int NUM_INPUTS     = 3,    // number of hypervectors to bundle (channels x features, etc.)
    parameter bit REGISTER_OUTPUT = 1'b0 // 0 = combinational output, 1 = registered (for timing closure at large D)
)(
    input  logic                  clk,
    input  logic                  rst_n,
    input  logic [D-1:0]          vecs_in [NUM_INPUTS],  // unpacked array of input hypervectors
    output logic [D-1:0]          bundled_vec            // majority-vote result
);

    // -------------------------------------------------------------------
    // Compile-time tie-break configuration
    // -------------------------------------------------------------------
    localparam bit NEEDS_TIEBREAK = (NUM_INPUTS % 2 == 0);
    localparam int TOTAL_INPUTS   = NEEDS_TIEBREAK ? (NUM_INPUTS + 1) : NUM_INPUTS;
    localparam int MAJORITY_THRESH = TOTAL_INPUTS / 2;  // output bit = 1 if count > MAJORITY_THRESH (TOTAL_INPUTS is always odd, so no tie is possible)
    localparam int CNT_WIDTH      = $clog2(TOTAL_INPUTS + 1);

    // sanity check -- at least 2 inputs expected in any real use of this module
    initial begin
        if (NUM_INPUTS < 2) begin
            $error("majority_bundle: NUM_INPUTS must be >= 2 (got %0d)", NUM_INPUTS);
        end
    end

    // -------------------------------------------------------------------
    // Tie-breaker hypervector (only generated when needed)
    // -------------------------------------------------------------------
    logic [D-1:0] tiebreak_vec;

    generate
        if (NEEDS_TIEBREAK) begin : gen_tiebreak
            assign tiebreak_vec = vecs_in[0] ^ vecs_in[1];
        end else begin : gen_no_tiebreak
            assign tiebreak_vec = '0;  // unused, tied off
        end
    endgenerate

    // -------------------------------------------------------------------
    // Per-bit-position majority vote.
    // D parallel instances, each gathering one bit from every input vector
    // (plus the tie-breaker bit if needed) and reusing the popcount
    // primitive to count how many are set.
    // -------------------------------------------------------------------
    logic [D-1:0] bundled_comb;

    genvar gi;
    generate
        for (gi = 0; gi < D; gi++) begin : gen_bit_majority

            logic [TOTAL_INPUTS-1:0] bit_slice;
            logic [CNT_WIDTH-1:0]    ones_count;

            // Gather bit `gi` from every input vector (+ tie-breaker bit)
            always_comb begin
                for (int ii = 0; ii < NUM_INPUTS; ii++) begin
                    bit_slice[ii] = vecs_in[ii][gi];
                end
                if (NEEDS_TIEBREAK) begin
                    bit_slice[NUM_INPUTS] = tiebreak_vec[gi];
                end
            end

            // Reuse the shared popcount primitive (small width here: TOTAL_INPUTS)
            popcount #(
                .WIDTH           (TOTAL_INPUTS),
                .REGISTER_OUTPUT (1'b0)
            ) u_popcount (
                .clk       (clk),
                .rst_n     (rst_n),
                .data_in   (bit_slice),
                .count_out (ones_count)
            );

            assign bundled_comb[gi] = (ones_count > MAJORITY_THRESH[CNT_WIDTH-1:0]);

        end
    endgenerate

    // -------------------------------------------------------------------
    // Optional output register, same pattern as popcount.sv
    // -------------------------------------------------------------------
    generate
        if (REGISTER_OUTPUT) begin : gen_registered_out
            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n)
                    bundled_vec <= '0;
                else
                    bundled_vec <= bundled_comb;
            end
        end else begin : gen_combinational_out
            assign bundled_vec = bundled_comb;
        end
    endgenerate

endmodule