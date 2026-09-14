// ---------------------------------------------------------------------------
// wino_sram_1p — synchronous single-port SRAM black-box stub
//
// This is the memory macro that the WinoCNN external buffers (input, weight,
// output, params) map to in the ASIC flow.  It is intentionally an empty
// black-box: in the real run it is replaced by the PDK SRAM macro with the
// same port list and the appropriate word count / data width.
//
// Port semantics (1-cycle read latency):
//   - read : assert ce & ~we; rdata is valid on the next clk edge
//   - write: assert ce &  we; wdata is captured on the clk edge
//
// The HLS flow (hw_scripts/script_asic.tcl, -DWINO_ASIC) produces simple
// address/data/ce/we ports for each external buffer, which this macro binds.
// ---------------------------------------------------------------------------
`timescale 1ns / 1ps

module wino_sram_1p #(
    parameter integer ADDR_W = 19,          // words
    parameter integer DATA_W = 128           // bits per word
) (
    input  wire                clk,
    input  wire                ce,
    input  wire                we,
    input  wire [ADDR_W-1:0]   addr,
    input  wire [DATA_W-1:0]   wdata,
    output reg  [DATA_W-1:0]   rdata
);

    // Black-box: no behavioral model.  Genus must see this as an unresolved
    // instance and bind it to the technology memory library instead.
    (* black_box = "true" *) reg [DATA_W-1:0] unused;

endmodule
