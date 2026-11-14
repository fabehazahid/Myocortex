// =============================================================================
// Module      : xor_bind
// Project     : MyoCortex HDC Accelerator
// Language    : SystemVerilog
// Description : Implements HDC "binding" via componentwise XOR, as per
//               Kanerva's MAP (Multiply-Add-Permute) framework and the
//               Benatti et al. EMG-HDC encoding scheme.
//
//               Used in the encoder to bind a channel/feature's ID
//               hypervector to its quantized-level hypervector:
//                   bound_vec = id_vec ^ level_vec
//               e.g. "channel 1 at amplitude level 21" -> E1 XOR V21
//
//               Properties relied upon elsewhere in the design (see
//               Kanerva 2009, Sec 6.4.1):
//                 - commutative:   A ^ B == B ^ A
//                 - self-inverse:  A ^ A == 0 (all-zero vector)
//                 - distance-preserving under mapping by the same vector
//               No binding-order ambiguity issue (A^A degeneracy) arises in
//               our usage since id_vec and level_vec are always distinct,
//               unrelated hypervectors.
//
//               Deliberately a single combinational module with no clock --
//               it is cheap enough (one XOR gate per bit) that registering
//               it separately is unnecessary; it will be absorbed into
//               whatever pipeline stage instantiates it.
// =============================================================================

module xor_bind #(
    parameter int D = 8192   // hypervector dimension (small for unit testing; set to real D, e.g. 2000, at integration)
)(
    input  logic [D-1:0] vec_a,      // e.g. channel/feature ID hypervector
    input  logic [D-1:0] vec_b,      // e.g. quantized-level hypervector
    output logic [D-1:0] bound_vec   // vec_a XOR vec_b
);

    always_comb begin
        bound_vec = vec_a ^ vec_b;
    end

endmodule