// =============================================================================
// Module      : assoc_memory_top
// Project     : MyoCortex HDC Accelerator
// Language    : SystemVerilog
// Description : The "classifier" stage. Holds NUM_CLASSES stored prototype
//               hypervectors (one per gesture, AXI-writable for training/
//               retraining) and, on `start`, compares an incoming query
//               hypervector against every stored prototype using a SINGLE
//               shared hamming_distance instance -- sequenced one class per
//               clock cycle by the FSM below, rather than instantiating
//               NUM_CLASSES parallel distance units.
//
//               This directly implements the resource-budget decision made
//               earlier in the design discussion: with NUM_CLASSES ~= 6-11
//               and a classification deadline set by the ~75-125ms window
//               rate (not by hardware speed), NUM_CLASSES extra clock cycles
//               (nanoseconds at 100MHz) is utterly negligible, while sharing
//               one Hamming unit instead of parallelizing saves roughly
//               NUM_CLASSES x the LUTs that a per-class Hamming distance
//               tree would cost.
//
//               Pipeline (Kanerva Sec 5.2 "autoassociative/item memory",
//               simplified to single-pass nearest-neighbour search -- no
//               iterative convergence loop, since we only ever compare
//               against a small, fixed set of stored prototypes, not search
//               an open-ended noisy memory):
//                 IDLE    -> latch query_vec, reset running-min tracking
//                 COMPARE -> one prototype compared per cycle, running
//                            minimum distance + winning class index updated
//                 DONE    -> assert result_valid with class_id + min_distance
// =============================================================================

module assoc_memory_top #(
    parameter int D           = 8,   // hypervector dimension (small for unit testing; real D later)
    parameter int NUM_CLASSES = 3    // number of stored gesture prototypes
)(
    input  logic                              clk,
    input  logic                              rst_n,

    // ---- Query interface: one window's encoded hypervector in ----
    input  logic [D-1:0]                      query_vec,
    input  logic                              start,        // one-cycle pulse: "query_vec is valid, classify it"
    output logic                              busy,         // high while a classification is in progress

    // ---- Result interface ----
    output logic                              result_valid, // one-cycle pulse: class_id/min_distance valid this cycle
    output logic [$clog2(NUM_CLASSES)-1:0]    class_id,     // winning (argmin) class index
    output logic [$clog2(D+1)-1:0]            min_distance, // winning Hamming distance (doubles as confidence: near D/2 = low confidence)

    // ---- Prototype write interface (for training / on-device retraining) ----
    input  logic                              proto_wr_en,
    input  logic [$clog2(NUM_CLASSES)-1:0]    proto_wr_addr,
    input  logic [D-1:0]                      proto_wr_data
);

    localparam int CLASS_IDX_WIDTH = $clog2(NUM_CLASSES);
    localparam int DIST_WIDTH      = $clog2(D + 1);

    // $clog2(1) = 0 would collapse class_id / proto_wr_addr to zero-width
    // ports, so a single-class memory is not supported (classification
    // between fewer than two classes is meaningless anyway).
    initial begin
        if (NUM_CLASSES < 2) begin
            $error("assoc_memory_top: NUM_CLASSES must be >= 2 (got %0d)", NUM_CLASSES);
        end
    end

    // -------------------------------------------------------------------
    // Prototype storage. Simple inferable memory: NUM_CLASSES entries,
    // each D bits wide. Synchronous write; combinational read (NUM_CLASSES
    // is small -- e.g. <=11 -- so this stays a small mux, not a deep one).
    // -------------------------------------------------------------------
    logic [D-1:0] prototype_mem [NUM_CLASSES];

    always_ff @(posedge clk) begin
        if (proto_wr_en) begin
            prototype_mem[proto_wr_addr] <= proto_wr_data;
        end
    end

    // -------------------------------------------------------------------
    // FSM state encoding
    // -------------------------------------------------------------------
    typedef enum logic [1:0] {
        S_IDLE,
        S_COMPARE,
        S_DONE
    } state_t;

    state_t state, state_next;

    // -------------------------------------------------------------------
    // Internal registers
    // -------------------------------------------------------------------
    logic [D-1:0]               query_vec_latched;
    logic [CLASS_IDX_WIDTH-1:0] class_idx;         // which prototype is being compared this cycle
    logic [CLASS_IDX_WIDTH-1:0] best_class_idx;    // running argmin
    logic [DIST_WIDTH-1:0]      best_distance;     // running minimum distance
    logic                       is_first_compare;  // true only on class_idx==0 of this run, to seed best_distance unconditionally

    // -------------------------------------------------------------------
    // Shared Hamming distance unit -- ONE instance, reused every cycle of
    // S_COMPARE against a different prototype_mem entry.
    // -------------------------------------------------------------------
    logic [DIST_WIDTH-1:0] current_distance;

    hamming_distance #(
        .D               (D),
        .REGISTER_OUTPUT (1'b0)   // combinational: distance available same cycle as class_idx changes. Switch to 1 if timing closure requires it (adds 1 cycle/class).
    ) u_hamming_distance (
        .clk      (clk),
        .rst_n    (rst_n),
        .vec_a    (query_vec_latched),
        .vec_b    (prototype_mem[class_idx]),
        .distance (current_distance)
    );

    // -------------------------------------------------------------------
    // FSM: state register
    // -------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            state <= S_IDLE;
        else
            state <= state_next;
    end

    // -------------------------------------------------------------------
    // FSM: next-state logic
    // -------------------------------------------------------------------
    always_comb begin
        state_next = state;
        case (state)
            S_IDLE: begin
                if (start)
                    state_next = S_COMPARE;
            end
            S_COMPARE: begin
                if (class_idx == NUM_CLASSES - 1)
                    state_next = S_DONE;
                // else stays in S_COMPARE, class_idx increments (see below)
            end
            S_DONE: begin
                state_next = S_IDLE;
            end
            default: state_next = S_IDLE;
        endcase
    end

    // -------------------------------------------------------------------
    // FSM: datapath / output registers
    // -------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            query_vec_latched <= '0;
            class_idx          <= '0;
            best_class_idx     <= '0;
            best_distance      <= '0;
            is_first_compare   <= 1'b1;
            result_valid       <= 1'b0;
            class_id           <= '0;
            min_distance       <= '0;
        end else begin
            result_valid <= 1'b0;  // default: deasserted unless explicitly pulsed below

            case (state)
                S_IDLE: begin
                    if (start) begin
                        query_vec_latched <= query_vec;
                        class_idx          <= '0;
                        is_first_compare   <= 1'b1;
                    end
                end

                S_COMPARE: begin
                    // current_distance reflects comparison of query_vec_latched
                    // against prototype_mem[class_idx] for the class_idx value
                    // already present at the start of this cycle (combinational
                    // hamming_distance has had a full cycle to settle).
                    if (is_first_compare || (current_distance < best_distance)) begin
                        best_distance   <= current_distance;
                        best_class_idx  <= class_idx;
                    end
                    is_first_compare <= 1'b0;

                    if (class_idx != NUM_CLASSES - 1)
                        class_idx <= class_idx + 1'b1;
                end

                S_DONE: begin
                    class_id      <= best_class_idx;
                    min_distance  <= best_distance;
                    result_valid  <= 1'b1;
                end

                default: ; // no action
            endcase
        end
    end

    assign busy = (state != S_IDLE);

endmodule