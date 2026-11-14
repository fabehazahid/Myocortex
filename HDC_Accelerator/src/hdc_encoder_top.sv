// =============================================================================
// Module      : hdc_encoder_top
// Project     : MyoCortex HDC Accelerator
// Language    : SystemVerilog
// Description : The "spatial encoder" -- implements Benatti et al. Eq. 1:
//
//                   S = (E_1 XOR V_l(1)) + (E_2 XOR V_l(2)) + ... + (E_N XOR V_l(N))
//
//               where E_i is channel i's ID hypervector (id_rom), V_l(i) is
//               the hypervector for channel i's quantized level (level_rom),
//               XOR is binding (xor_bind), and "+" is majority-vote bundling
//               (majority_bundle). One bound pair is formed per channel, then
//               all of them are bundled into a single D-bit hypervector
//               representing the entire window across all channels.
//
//               This module is purely combinational end-to-end (unless
//               ENCODER_REGISTER_OUTPUT is set), composed entirely from
//               already-independently-verified primitives: id_rom, level_rom,
//               xor_bind (x NUM_SLOTS), majority_bundle. Its own testbench
//               exists to verify the WIRING and the Eq. 1 ordering, not to
//               re-derive binding/bundling correctness again.
//
//               Temporal encoding (N-grams, Benatti Eq. 2) is deliberately
//               NOT included here -- per the design discussion, N=1 (no
//               temporal component) is sufficient for static, held-contraction
//               gestures, matching both the Benatti paper's final results and
//               our own scope decision. If temporal encoding is added later,
//               it would sit as an additional permutation+XOR stage consuming
//               this module's output across consecutive windows.
// =============================================================================

module hdc_encoder_top #(
    parameter int    D                       = 8,     // hypervector dimension
    parameter int    NUM_SLOTS            = 3,      // number of (channel, feature) slots, e.g. 2 channels x 4 features = 8
    parameter int    NUM_LEVELS              = 4,      // number of quantization levels (real design: 22)
    parameter bit    ENCODER_REGISTER_OUTPUT = 1'b0,    // 0 = fully combinational, 1 = registered window_hypervector output
    parameter string ID_MEM_FILE             = "",      // path for id_rom's $readmemb init file ("" = testbench preloads)
    parameter string LEVEL_MEM_FILE          = ""       // path for level_rom's $readmemb init file ("" = testbench preloads)
)(
    input  logic                              clk,
    input  logic                              rst_n,

    input  logic [$clog2(NUM_LEVELS)-1:0]     level_idx_in [NUM_SLOTS],  // quantized level index per channel, this window
    input  logic                              valid_in,                     // one-cycle pulse: level_idx_in is valid

    output logic [D-1:0]                      window_hypervector,           // encoded result for this window
    output logic                              valid_out                     // one-cycle pulse: window_hypervector is valid
);

    // -------------------------------------------------------------------
    // ID Memory (fixed per-channel role vectors, loaded once)
    // -------------------------------------------------------------------
    logic [D-1:0] id_vecs [NUM_SLOTS];

    id_rom #(
        .D            (D),
        .NUM_SLOTS (NUM_SLOTS),
        .MEM_FILE     (ID_MEM_FILE)
    ) u_id_rom (
        .id_vecs (id_vecs)
    );

    // -------------------------------------------------------------------
    // Continuous Item Memory (per-channel quantized-level filler vectors)
    // -------------------------------------------------------------------
    logic [D-1:0] level_vecs [NUM_SLOTS];

    level_rom #(
        .D            (D),
        .NUM_LEVELS   (NUM_LEVELS),
        .NUM_SLOTS (NUM_SLOTS),
        .MEM_FILE     (LEVEL_MEM_FILE)
    ) u_level_rom (
        .level_idx  (level_idx_in),
        .level_vecs (level_vecs)
    );

    // -------------------------------------------------------------------
    // Binding: one xor_bind per channel (role XOR filler)
    // -------------------------------------------------------------------
    logic [D-1:0] bound_vecs [NUM_SLOTS];

    genvar gch;
    generate
        for (gch = 0; gch < NUM_SLOTS; gch++) begin : gen_channel_bind
            xor_bind #(
                .D (D)
            ) u_xor_bind (
                .vec_a     (id_vecs[gch]),
                .vec_b     (level_vecs[gch]),
                .bound_vec (bound_vecs[gch])
            );
        end
    endgenerate

    // -------------------------------------------------------------------
    // Bundling: combine all NUM_SLOTS bound pairs into one hypervector.
    // majority_bundle internally handles the odd/even tie-break case
    // (see majority_bundle.sv), so NUM_SLOTS may be either parity here.
    // -------------------------------------------------------------------
    majority_bundle #(
        .D               (D),
        .NUM_INPUTS      (NUM_SLOTS),
        .REGISTER_OUTPUT (ENCODER_REGISTER_OUTPUT)
    ) u_majority_bundle (
        .clk         (clk),
        .rst_n       (rst_n),
        .vecs_in     (bound_vecs),
        .bundled_vec (window_hypervector)
    );

    // -------------------------------------------------------------------
    // valid_out alignment: if the bundler's output is registered, valid_out
    // must be delayed by one cycle to match; if combinational, pass straight
    // through. Same generate-based pattern used throughout this codebase.
    // -------------------------------------------------------------------
    generate
        if (ENCODER_REGISTER_OUTPUT) begin : gen_valid_registered
            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n)
                    valid_out <= 1'b0;
                else
                    valid_out <= valid_in;
            end
        end else begin : gen_valid_combinational
            assign valid_out = valid_in;
        end
    endgenerate

endmodule