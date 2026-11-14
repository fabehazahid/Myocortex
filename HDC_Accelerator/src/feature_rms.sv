// =============================================================================
// Module      : feature_rms
// Project     : MyoCortex HDC Accelerator
// Language    : SystemVerilog
// Description : Computes the Root-Mean-Square (RMS) of one channel's window
//               of filtered EMG samples:
//
//                   RMS = sqrt( (1/WINDOW_LEN) * sum(sample[i]^2) )
//
//               RMS is the standard measure of overall muscle contraction
//               intensity in EMG feature extraction (see design-rationale
//               discussion: RMS/MAV capture contraction energy; WL/ZC
//               capture signal complexity/frequency-proxy information).
//
//               Implementation notes:
//                 - Samples are presented ONE AT A TIME, streamed in with
//                   sample_valid pulsed once per sample (matches the
//                   streamed-window-input decision made earlier in the
//                   design discussion). The module accumulates sum-of-
//                   squares internally; it does not require the full window
//                   to be stored anywhere else.
//                 - window_done is pulsed externally (e.g. by the control
//                   FSM) once WINDOW_LEN samples have been streamed in, to
//                   trigger the final divide + sqrt and produce rms_out.
//                 - The square root is implemented here via a simple
//                   iterative (non-restoring) integer square root -- cheap
//                   in LUTs, takes OUT_WIDTH cycles to complete, which is
//                   utterly negligible against the ~75-125ms window budget.
//                   A CORDIC-based or pipelined sqrt can replace this later
//                   if timing/throughput ever demands it; the interface
//                   (busy/done handshake) is written to make that swap
//                   transparent to whatever instantiates this module.
// =============================================================================
// =============================================================================
// Module      : feature_rms
// Project     : MyoCortex HDC Accelerator
// Language    : SystemVerilog
// Description : Fixed RMS unit with exact integer digit-by-digit square root.
// =============================================================================

module feature_rms #(
    parameter int SAMPLE_WIDTH = 16,   // Signed ADC sample width
    parameter int WINDOW_LEN   = 8,    // Samples per window
    parameter int OUT_WIDTH    = 16    // Width of RMS output (unsigned)
)(
    input  logic                         clk,
    input  logic                         rst_n,

    input  logic signed [SAMPLE_WIDTH-1:0] sample_in,
    input  logic                         sample_valid,
    input  logic                         window_done,
    input  logic                         clear,

    output logic [OUT_WIDTH-1:0]         rms_out,
    output logic                         rms_valid,
    output logic                         busy
);

    localparam int SQ_WIDTH  = SAMPLE_WIDTH * 2;
    localparam int ACC_WIDTH = SQ_WIDTH + $clog2(WINDOW_LEN + 1);

    logic [ACC_WIDTH-1:0] sum_sq_acc;
    logic [SQ_WIDTH-1:0]  sample_sq;

    assign sample_sq = sample_in * sample_in;

    // Accumulator
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sum_sq_acc <= '0;
        end else if (clear) begin
            sum_sq_acc <= '0;
        end else if (sample_valid) begin
            sum_sq_acc <= sum_sq_acc + sample_sq;
        end
    end

    // Mean of squares
    logic [ACC_WIDTH-1:0] mean_sq;
    assign mean_sq = sum_sq_acc / WINDOW_LEN;

    // -------------------------------------------------------------------
    // Digit-by-Digit Square Root
    // -------------------------------------------------------------------
    typedef enum logic [1:0] {
        SQRT_IDLE,
        SQRT_COMPUTE,
        SQRT_DONE
    } sqrt_state_t;

    sqrt_state_t sqrt_state;

    logic [ACC_WIDTH-1:0] x_rem;
    logic [OUT_WIDTH-1:0] q_res;
    int                   bit_idx; // Use standard integer to prevent bit-width truncation

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sqrt_state <= SQRT_IDLE;
            x_rem      <= '0;
            q_res      <= '0;
            bit_idx    <= 0;
            rms_valid  <= 1'b0;
            rms_out    <= '0;
        end else begin
            rms_valid <= 1'b0;

            case (sqrt_state)
                SQRT_IDLE: begin
                    if (window_done) begin
                        x_rem      <= mean_sq;
                        q_res      <= '0;
                        bit_idx    <= OUT_WIDTH - 1;
                        sqrt_state <= SQRT_COMPUTE;
                    end
                end

                SQRT_COMPUTE: begin
                    automatic logic [ACC_WIDTH-1:0] test_val;
                    test_val = (ACC_WIDTH'(q_res) | (ACC_WIDTH'(1) << bit_idx)) << bit_idx;

                    if (x_rem >= test_val) begin
                        x_rem <= x_rem - test_val;
                        q_res <= q_res | (OUT_WIDTH'(1) << bit_idx);
                    end

                    if (bit_idx == 0) begin
                        sqrt_state <= SQRT_DONE;
                    end else begin
                        bit_idx <= bit_idx - 1;
                    end
                end

                SQRT_DONE: begin
                    rms_out    <= q_res;
                    rms_valid  <= 1'b1;
                    sqrt_state <= SQRT_IDLE;
                end

                default: sqrt_state <= SQRT_IDLE;
            endcase
        end
    end

    assign busy = (sqrt_state != SQRT_IDLE);

endmodule