// =============================================================================
// Module      : id_rom
// Project     : MyoCortex HDC Accelerator
// Language    : SystemVerilog
// Description : Item Memory (IM) in Kanerva/Benatti terminology: one fixed,
//               random, (nearly) orthogonal D-bit hypervector per channel,
//               generated OFFLINE by Member 3's Python/torchhd pipeline and
//               loaded here via $readmemb. These never change at runtime --
//               they are the "role" vectors that get bound to each channel's
//               "filler" (quantized amplitude level) in the encoder.
//
//               Since NUM_SLOTS is small and fixed at compile time, and
//               every channel's ID vector is needed simultaneously every
//               cycle (not addressed one-at-a-time like level_rom), this ROM
//               simply outputs ALL NUM_SLOTS vectors at once as an
//               unpacked array -- no address port needed at all. This keeps
//               the encoder's instantiation of this module trivial and
//               avoids any multi-port-read complexity.
//
//               MEM_FILE handling: if MEM_FILE is left as the default empty
//               string, the memory is left zero-initialized and is expected
//               to be preloaded by a testbench via hierarchical reference
//               (`dut.u_id_rom.mem[i] = ...`) for unit testing before real
//               mem_init/*.mem files exist. Once Member 3 hands off real
//               files, pass the actual path via MEM_FILE at instantiation.
// =============================================================================

module id_rom #(
    parameter int    D            = 8,   // hypervector dimension
    parameter int    NUM_SLOTS = 3,   // number of channel ID vectors stored
    parameter string MEM_FILE     = ""   // path to $readmemb-format init file; "" = leave zero, testbench preloads
)(
    output logic [D-1:0] id_vecs [NUM_SLOTS]  // all channel ID vectors, always available
);

    logic [D-1:0] mem [NUM_SLOTS];

    initial begin
        if (MEM_FILE != "") begin
            $readmemb(MEM_FILE, mem);
        end
        // else: left at default (zero) initialization; testbench responsible
        // for preloading via hierarchical reference during unit tests.
    end

    assign id_vecs = mem;

endmodule