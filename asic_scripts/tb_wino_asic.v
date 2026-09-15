`timescale 1ns/1ps
// ---------------------------------------------------------------------------
// WinoCNN ASIC-flow RTL testbench (micro config, 1 PE).
//
// Models the four external synchronous RAMs (ap_memory ports of
// wino_systolic_top), preloads them from $readmemh files produced by
// asic_scripts/bin2hex.py, runs one convolution, counts cycles and memory
// transactions, dumps the output DDR, and (under +define+XRUN) writes an SHM
// for Genus power analysis.
//
// The top port list below matches the generated RTL for
// WINO_WIDTH=1 (single weight port).  Re-generate/adapt if the config changes.
// ---------------------------------------------------------------------------
module tb;

  // Address spaces of the top ports (2^address_width).
  localparam IN_DEPTH  = 1 << 19;  // input_DDR0/1 : 128-bit
  localparam W_DEPTH   = 1 << 21;  // weight_DDR0  : 128-bit
  localparam OUT_DEPTH = 1 << 19;  // output_DDR0/1: 32-bit
  localparam P_DEPTH   = 1 << 16;  // mem_params   : 32-bit

  localparam OUT_DUMP_WORDS = 256;

  reg  ap_clk = 0;
  reg  ap_rst = 1;
  reg  ap_start = 0;
  wire ap_done, ap_idle, ap_ready;

  wire [18:0] in0_addr, in1_addr;
  wire        in0_ce, in1_ce;
  reg  [127:0] in0_q, in1_q;

  wire [20:0] w0_addr;
  wire        w0_ce;
  reg  [127:0] w0_q;

  wire [18:0] o0_addr, o1_addr;
  wire        o0_ce, o0_we, o1_ce, o1_we;
  wire [31:0] o0_d, o1_d;

  wire [15:0] p_addr;
  wire        p_ce;
  reg  [31:0] p_q;

  reg [127:0] mem_in0  [0:IN_DEPTH-1];
  reg [127:0] mem_in1  [0:IN_DEPTH-1];
  reg [127:0] mem_w0   [0:W_DEPTH-1];
  reg [31:0]  mem_out0 [0:OUT_DEPTH-1];
  reg [31:0]  mem_out1 [0:OUT_DEPTH-1];
  reg [31:0]  mem_p    [0:P_DEPTH-1];

  integer i;
  integer cycle_count;
  integer input_reads, weight_reads, param_reads, output_writes;
  integer max_in_addr, max_w_addr, in_oob, w_oob;
  integer max_out_addr;
  reg     counting;
  integer fd;

  // External RAM read model.  Vivado HLS schedules the ap_memory read of this
  // design with a 3-cycle latency (the generated cosim model AESL_automem_*
  // uses a 3-stage output pipeline); using 1 cycle here reads stale data and
  // produces a wrong result.
  reg [127:0] in0_d1, in0_d2, in1_d1, in1_d2, w0_d1, w0_d2;
  reg [31:0]  p_d1, p_d2;
`ifdef LAT0
  always @(*) begin
    in0_q = mem_in0[in0_addr];
    in1_q = mem_in1[in1_addr];
    w0_q  = mem_w0[w0_addr];
    p_q   = mem_p[p_addr];
  end
`else
  always @(posedge ap_clk) begin
    if (ap_rst) begin
      in0_d1 <= 0; in0_d2 <= 0; in0_q <= 0;
      in1_d1 <= 0; in1_d2 <= 0; in1_q <= 0;
      w0_d1 <= 0;  w0_d2 <= 0;  w0_q  <= 0;
      p_d1 <= 0;   p_d2 <= 0;   p_q   <= 0;
    end else begin
      if (in0_ce) begin
        in0_d1 <= mem_in0[in0_addr]; in0_d2 <= in0_d1; in0_q <= in0_d2;
      end
      if (in1_ce) begin
        in1_d1 <= mem_in1[in1_addr]; in1_d2 <= in1_d1; in1_q <= in1_d2;
      end
      if (w0_ce) begin
        w0_d1 <= mem_w0[w0_addr]; w0_d2 <= w0_d1; w0_q <= w0_d2;
      end
      // The parameter descriptor is read by a simple loop: 1-cycle latency.
      if (p_ce) begin
        p_q <= mem_p[p_addr];
      end
    end
  end
`endif

  // Synchronous write.
  always @(posedge ap_clk) begin
    if (o0_ce && o0_we) mem_out0[o0_addr] <= o0_d;
    if (o1_ce && o1_we) mem_out1[o1_addr] <= o1_d;
  end

  integer ow;
  initial ow = $fopen("out_writes.txt", "w");
  always @(posedge ap_clk) begin
    if (o0_ce && o0_we) $fwrite(ow, "0 %0d %08x\n", o0_addr, o0_d);
    if (o1_ce && o1_we) $fwrite(ow, "1 %0d %08x\n", o1_addr, o1_d);
  end

  // Memory traffic counters.
  always @(posedge ap_clk) begin
    input_reads   <= input_reads   + (in0_ce ? 1 : 0) + (in1_ce ? 1 : 0);
    weight_reads  <= weight_reads  + (w0_ce ? 1 : 0);
    param_reads   <= param_reads   + (p_ce ? 1 : 0);
    output_writes <= output_writes + ((o0_ce && o0_we) ? 1 : 0)
                                   + ((o1_ce && o1_we) ? 1 : 0);
    if (in0_ce) begin
      if (in0_addr > max_in_addr) max_in_addr <= in0_addr;
      if (in0_addr > 63) in_oob <= in_oob + 1;
    end
    if (in1_ce) begin
      if (in1_addr > max_in_addr) max_in_addr <= in1_addr;
      if (in1_addr > 63) in_oob <= in_oob + 1;
    end
    if (w0_ce) begin
      if (w0_addr > max_w_addr) max_w_addr <= w0_addr;
      if (w0_addr > 63) w_oob <= w_oob + 1;
    end
    if (o0_ce && o0_we) begin
      if (o0_addr > max_out_addr) max_out_addr <= o0_addr;
    end
    if (o1_ce && o1_we) begin
      if (o1_addr > max_out_addr) max_out_addr <= o1_addr;
    end
  end

  // Cycle counter (active from ap_start until ap_done).
  always @(posedge ap_clk) begin
    if (counting) cycle_count <= cycle_count + 1;
  end

  wino_systolic_top dut (
    .ap_clk(ap_clk),
    .ap_rst(ap_rst),
    .ap_start(ap_start),
    .ap_done(ap_done),
    .ap_idle(ap_idle),
    .ap_ready(ap_ready),
    .input_DDR0_V_address0(in0_addr),
    .input_DDR0_V_ce0(in0_ce),
    .input_DDR0_V_q0(in0_q),
    .input_DDR1_V_address0(in1_addr),
    .input_DDR1_V_ce0(in1_ce),
    .input_DDR1_V_q0(in1_q),
    .weight_DDR0_V_address0(w0_addr),
    .weight_DDR0_V_ce0(w0_ce),
    .weight_DDR0_V_q0(w0_q),
    .output_DDR0_V_address0(o0_addr),
    .output_DDR0_V_ce0(o0_ce),
    .output_DDR0_V_we0(o0_we),
    .output_DDR0_V_d0(o0_d),
    .output_DDR1_V_address0(o1_addr),
    .output_DDR1_V_ce0(o1_ce),
    .output_DDR1_V_we0(o1_we),
    .output_DDR1_V_d0(o1_d),
    .mem_params_V_address0(p_addr),
    .mem_params_V_ce0(p_ce),
    .mem_params_V_q0(p_q)
  );

  // 500 MHz (2 ns) clock.
  always #1 ap_clk = ~ap_clk;

  // Watchdog: abort if the DUT does not finish (e.g. wrong external RAM
  // latency makes the FSM loop).
  initial begin
    #200000;
    $display("WINO_SIM_TIMEOUT cycles=%0d", cycle_count);
    $finish;
  end

  initial begin
    cycle_count = 0;
    input_reads = 0;
    weight_reads = 0;
    param_reads = 0;
    output_writes = 0;
    max_in_addr = 0;
    max_w_addr = 0;
    in_oob = 0;
    w_oob = 0;
    max_out_addr = 0;
    counting = 0;

    for (i = 0; i < IN_DEPTH; i = i + 1) begin
      mem_in0[i] = 128'd0;
      mem_in1[i] = 128'd0;
    end
    for (i = 0; i < W_DEPTH; i = i + 1)
      mem_w0[i] = {128{1'b1}};
    for (i = 0; i < OUT_DEPTH; i = i + 1) begin
      mem_out0[i] = 32'd0;
      mem_out1[i] = 32'd0;
    end
    for (i = 0; i < P_DEPTH; i = i + 1)
      mem_p[i] = 32'd0;

    $readmemh("input.hex",  mem_in0);
    $readmemh("input.hex",  mem_in1);
    $readmemh("weight.hex", mem_w0);
    $readmemh("param.hex",  mem_p);

    $dumpfile("dump.vcd");
    $dumpvars(0, tb);
`ifdef XRUN
    $shm_open("dut.shm");
    $shm_probe(tb.dut, "ASM");
`endif

    ap_rst = 1;
    ap_start = 0;
    #20 ap_rst = 0;
    #20 ap_start = 1;
    counting = 1;
    #10 ap_start = 0;

    @(posedge ap_done);
    #20 counting = 0;
    #2000;

    $display("WINO_SIM_DONE cycles=%0d input_reads=%0d weight_reads=%0d param_reads=%0d output_writes=%0d",
             cycle_count, input_reads, weight_reads, param_reads, output_writes);
    $display("WINO_SIM_ADDR max_in_addr=%0d in_oob=%0d max_w_addr=%0d w_oob=%0d max_out_addr=%0d",
             max_in_addr, in_oob, max_w_addr, w_oob, max_out_addr);

    fd = $fopen("output_rtl.hex", "w");
    for (i = 0; i < OUT_DUMP_WORDS; i = i + 1)
      $fwrite(fd, "%08x\n", mem_out0[i]);
    $fclose(fd);

    fd = $fopen("output_rtl1.hex", "w");
    for (i = 0; i < OUT_DUMP_WORDS; i = i + 1)
      $fwrite(fd, "%08x\n", mem_out1[i]);
    $fclose(fd);

    $finish;
  end

endmodule
