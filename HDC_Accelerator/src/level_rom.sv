// =============================================================================
// Module      : level_rom
// Project     : MyoCortex HDC Accelerator
// Language    : SystemVerilog
// Description : Continuous Item Memory (CIM) in Benatti terminology: one
//               hypervector per quantization level (e.g. 22 levels), with
//               NEARBY levels deliberately made similar to each other
//               (generated offline via interpolation between two orthogonal
//               endpoints -- see Benatti et al. Sec III-B). This ROM does not
//               enforce that similarity itself; it is a property of the
//               vectors Member 3's Python pipeline writes into MEM_FILE.
//
//               Unlike id_rom, every channel's quantized level is a genuine
//               RUNTIME value that differs window-to-window and channel-to-
//               channel, so this module provides NUM_SLOTS independent,
//               concurrently-addressed read ports into the SAME underlying
//               table. For the small table sizes involved here (NUM_LEVELS
//               ~= 22, D in the thousands), Vivado synthesizes this as
//               either replicated distributed ROM or multiple small BRAMs
//               automatically -- a standard, accepted pattern for small
//               multi-read-port ROMs; no manual replication needed in this
//               description.
//
//               MEM_FILE handling: same convention as id_rom.sv -- empty
//               string leaves the memory zero-initialized for testbench
//               hierarchical preloading before real mem_init/*.mem files
//               exist.
// =============================================================================

module level_rom #(
    parameter int    D            = 8,   // hypervector dimension
    parameter int    NUM_LEVELS   = 4,   // number of quantization levels stored (real design: 22, per Benatti et al.)
    parameter int    NUM_SLOTS = 3,   // number of concurrent read ports needed (one per channel)
    parameter string MEM_FILE     = ""   // path to $readmemb-format init file; "" = leave zero, testbench preloads
)(
    input  logic [$clog2(NUM_LEVELS)-1:0] level_idx [NUM_SLOTS],  // one quantized level index per channel, this cycle
    output logic [D-1:0]                  level_vecs [NUM_SLOTS]  // corresponding looked-up hypervector per channel
);

    logic [D-1:0] mem [NUM_LEVELS];

    initial begin
        if (MEM_FILE != "") begin
            $readmemb(MEM_FILE, mem);
        end
        // else: left at default (zero) initialization; testbench responsible
        // for preloading via hierarchical reference during unit tests.
    end

    // NUM_SLOTS independent combinational reads from the same table
    genvar gc;
    generate
        for (gc = 0; gc < NUM_SLOTS; gc++) begin : gen_read_port
            assign level_vecs[gc] = mem[level_idx[gc]];
        end
    endgenerate

endmodule