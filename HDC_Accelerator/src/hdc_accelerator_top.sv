// =============================================================================
// Module      : hdc_accelerator_top
// Project     : MyoCortex HDC Accelerator
// Language    : SystemVerilog
// Description : Top level of the HDC accelerator. Scope is deliberately
//               narrow (see architecture discussion): it starts AFTER feature
//               extraction and quantization, and ends at a gesture class.
//
//                   level_idx_in[NUM_SLOTS] + valid_in
//                        |
//                        v
//                   hdc_encoder_top   (ID/level ROM lookup, XOR bind, majority bundle)
//                        |  window_hypervector + valid_out
//                        v
//                   assoc_memory_top  (time-multiplexed Hamming distance + argmin)
//                        |
//                        v
//                   class_id, min_distance, result_valid
//
//               A "slot" is one (channel, feature) pair, e.g. 2 channels x
//               4 features = 8 slots. Each slot owns one ID hypervector.
//
//               Why there is NO separate accel_ctrl_fsm: the encoder is a
//               pure datapath (combinational, or one register stage) and
//               assoc_memory_top already contains the only real sequencer
//               (S_IDLE / S_COMPARE / S_DONE). All that is left for a "top
//               level controller" is (a) turning the encoder's valid_out
//               into assoc_memory_top's start pulse and (b) refusing new
//               windows while a classification is in flight. Both are a few
//               gates, so they live here rather than in a dedicated FSM.
//
//               Overrun protection: windows arrive roughly every 100 ms and
//               a classification takes NUM_CLASSES + ~3 clock cycles, so a
//               collision should never happen in normal operation. If one
//               does (PS bug, wrong hop configuration), the new window is
//               DROPPED -- not queued, not allowed to corrupt the one in
//               flight -- and `overrun` pulses so the PS can count it.
//
//               Prototype loading: the prototype write port is passed
//               straight through to assoc_memory_top. The PS (over AXI-Lite)
//               or a testbench writes class prototypes there; prototypes are
//               generated offline (Member 3's Python pipeline) or bundled in
//               software on the PS for on-device retraining.
// =============================================================================

module hdc_accelerator_top #(
    parameter int    D                       = 8,     // hypervector dimension
    parameter int    NUM_SLOTS               = 3,      // number of (channel, feature) slots
    parameter int    NUM_LEVELS              = 4,      // quantization levels per slot (real design: 22)
    parameter int    NUM_CLASSES             = 3,      // number of gesture classes (>= 2)
    parameter bit    ENCODER_REGISTER_OUTPUT = 1'b0,    // 1 = register the encoder output (cuts the long encode->latch path at large D)
    parameter string ID_MEM_FILE             = "",      // $readmemb init file for the ID ROM   ("" = testbench preloads)
    parameter string LEVEL_MEM_FILE          = ""       // $readmemb init file for the level ROM ("" = testbench preloads)
)(
    input  logic                              clk,
    input  logic                              rst_n,

    // ---- Window input (from the feature-extraction front end) ----
    input  logic [$clog2(NUM_LEVELS)-1:0]     level_idx_in [NUM_SLOTS],  // quantized level per slot
    input  logic                              valid_in,                  // one-cycle pulse: level_idx_in is valid

    // ---- Prototype write port (PS / testbench) ----
    input  logic                              proto_wr_en,
    input  logic [$clog2(NUM_CLASSES)-1:0]    proto_wr_addr,
    input  logic [D-1:0]                      proto_wr_data,

    // ---- Status ----
    output logic                              busy,           // a window is being encoded/classified; new valid_in will be dropped
    output logic                              overrun,        // one-cycle pulse: a valid_in was dropped because busy was high

    // ---- Result ----
    output logic                              result_valid,   // one-cycle pulse: class_id / min_distance valid
    output logic [$clog2(NUM_CLASSES)-1:0]    class_id,       // winning gesture class
    output logic [$clog2(D+1)-1:0]            min_distance    // winning Hamming distance (confidence: close to D/2 = no good match)
);

    // -------------------------------------------------------------------
    // Internal signals
    // -------------------------------------------------------------------
    logic [D-1:0] window_hypervector;
    logic         enc_valid_in;
    logic         enc_valid_out;
    logic         assoc_busy;
    logic         blocked;

    // -------------------------------------------------------------------
    // busy / blocked logic.
    // If the encoder output is registered, there is one cycle in which the
    // window has left valid_in but assoc_memory_top has not started yet
    // (enc_valid_out high, assoc_busy still low); that cycle must also
    // count as busy. enc_valid_out is a flop output in that configuration,
    // so there is no combinational loop through enc_valid_in.
    // -------------------------------------------------------------------
    generate
        if (ENCODER_REGISTER_OUTPUT) begin : gen_blocked_registered
            assign blocked = assoc_busy | enc_valid_out;
        end else begin : gen_blocked_combinational
            assign blocked = assoc_busy;
        end
    endgenerate

    assign enc_valid_in = valid_in & ~blocked;
    assign busy         = blocked;

    // overrun: registered one-cycle pulse when a window arrives while blocked
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            overrun <= 1'b0;
        else
            overrun <= valid_in & blocked;
    end

    // -------------------------------------------------------------------
    // Spatial encoder (Benatti Eq. 1)
    // -------------------------------------------------------------------
    hdc_encoder_top #(
        .D                       (D),
        .NUM_SLOTS               (NUM_SLOTS),
        .NUM_LEVELS              (NUM_LEVELS),
        .ENCODER_REGISTER_OUTPUT (ENCODER_REGISTER_OUTPUT),
        .ID_MEM_FILE             (ID_MEM_FILE),
        .LEVEL_MEM_FILE          (LEVEL_MEM_FILE)
    ) u_encoder (
        .clk                (clk),
        .rst_n              (rst_n),
        .level_idx_in       (level_idx_in),
        .valid_in           (enc_valid_in),
        .window_hypervector (window_hypervector),
        .valid_out          (enc_valid_out)
    );

    // -------------------------------------------------------------------
    // Associative memory / classifier. Its `start` is simply the encoder's
    // valid_out; it latches window_hypervector on that same edge, so the
    // encoder output only has to be valid for that one cycle.
    // -------------------------------------------------------------------
    assoc_memory_top #(
        .D           (D),
        .NUM_CLASSES (NUM_CLASSES)
    ) u_assoc (
        .clk           (clk),
        .rst_n         (rst_n),
        .query_vec     (window_hypervector),
        .start         (enc_valid_out),
        .busy          (assoc_busy),
        .result_valid  (result_valid),
        .class_id      (class_id),
        .min_distance  (min_distance),
        .proto_wr_en   (proto_wr_en),
        .proto_wr_addr (proto_wr_addr),
        .proto_wr_data (proto_wr_data)
    );

endmodule