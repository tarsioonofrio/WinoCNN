`timescale 1ns/1ps
// Access-count-only RTL testbench. External memories contain deterministic
// random words; output data is intentionally ignored (no golden comparison).
module tb;
  localparam IN_DEPTH = 1 << 19;
  localparam W_DEPTH  = 1 << 21;
  localparam P_DEPTH  = 1 << 16;
  localparam real EXT_MEM_TCO_NS = 0.20;

  reg ap_clk = 0, ap_rst = 1, ap_start = 0;
  wire ap_done, ap_idle, ap_ready;
  wire [18:0] in0_addr, in1_addr;
  wire in0_ce, in1_ce;
  reg [127:0] in0_q, in1_q;
  wire [20:0] w0_addr;
  wire w0_ce;
  reg [127:0] w0_q;
  wire [18:0] o0_addr, o1_addr;
  wire o0_ce, o0_we, o1_ce, o1_we;
  wire [31:0] o0_d, o1_d;
  wire [15:0] p_addr;
  wire p_ce;
  reg [31:0] p_q;

  reg [127:0] mem_in0 [0:IN_DEPTH-1];
  reg [127:0] mem_in1 [0:IN_DEPTH-1];
  reg [127:0] mem_w0 [0:W_DEPTH-1];
  reg [31:0] mem_p [0:P_DEPTH-1];

  reg [127:0] in0_d1, in0_d2, in1_d1, in1_d2, w0_d1, w0_d2;
  reg [31:0] p_d1, p_d2;
  integer cycles = 0;
  integer in0_reads = 0, in1_reads = 0, w0_reads = 0, p_reads = 0;
  integer o0_writes = 0, o1_writes = 0;
  integer sram_counter_file;
  integer max_in0_addr = 0, max_in1_addr = 0, max_w0_addr = 0, max_p_addr = 0;
  integer input_words = 0, weight_words = 0;
  integer init_index;
  reg counting = 0;
  reg report_sram_accesses = 0;

  always #1 ap_clk = ~ap_clk;

  always @(posedge ap_clk) begin
    if (ap_rst) begin
      in0_d1 <= 0; in0_d2 <= 0; in0_q <= 0;
      in1_d1 <= 0; in1_d2 <= 0; in1_q <= 0;
      w0_d1 <= 0; w0_d2 <= 0; w0_q <= 0;
      p_d1 <= 0; p_d2 <= 0; p_q <= 0;
    end else begin
      if (in0_ce) begin
        in0_d1 <= mem_in0[in0_addr]; in0_d2 <= in0_d1;
        in0_q <= #EXT_MEM_TCO_NS in0_d2;
      end
      if (in1_ce) begin
        in1_d1 <= mem_in1[in1_addr]; in1_d2 <= in1_d1;
        in1_q <= #EXT_MEM_TCO_NS in1_d2;
      end
      if (w0_ce) begin
        w0_d1 <= mem_w0[w0_addr]; w0_d2 <= w0_d1;
        w0_q <= #EXT_MEM_TCO_NS w0_d2;
      end
      if (p_ce) p_q <= #EXT_MEM_TCO_NS mem_p[p_addr];
    end
    if (counting) cycles <= cycles + 1;
    if (in0_ce === 1'b1) in0_reads <= in0_reads + 1;
    if (in1_ce === 1'b1) in1_reads <= in1_reads + 1;
    if (w0_ce === 1'b1) w0_reads <= w0_reads + 1;
    if (p_ce === 1'b1) p_reads <= p_reads + 1;
    if ((o0_ce === 1'b1) && (o0_we === 1'b1)) o0_writes <= o0_writes + 1;
    if ((o1_ce === 1'b1) && (o1_we === 1'b1)) o1_writes <= o1_writes + 1;
    if (in0_ce && (in0_addr > max_in0_addr)) max_in0_addr <= in0_addr;
    if (in1_ce && (in1_addr > max_in1_addr)) max_in1_addr <= in1_addr;
    if (w0_ce && (w0_addr > max_w0_addr)) max_w0_addr <= w0_addr;
    if (p_ce && (p_addr > max_p_addr)) max_p_addr <= p_addr;
  end

  wino_systolic_top dut (
    .ap_clk(ap_clk), .ap_rst(ap_rst), .ap_start(ap_start),
    .ap_done(ap_done), .ap_idle(ap_idle), .ap_ready(ap_ready),
    .input_DDR0_V_address0(in0_addr), .input_DDR0_V_ce0(in0_ce), .input_DDR0_V_q0(in0_q),
    .input_DDR1_V_address0(in1_addr), .input_DDR1_V_ce0(in1_ce), .input_DDR1_V_q0(in1_q),
    .weight_DDR0_V_address0(w0_addr), .weight_DDR0_V_ce0(w0_ce), .weight_DDR0_V_q0(w0_q),
    .output_DDR0_V_address0(o0_addr), .output_DDR0_V_ce0(o0_ce), .output_DDR0_V_we0(o0_we), .output_DDR0_V_d0(o0_d),
    .output_DDR1_V_address0(o1_addr), .output_DDR1_V_ce0(o1_ce), .output_DDR1_V_we0(o1_we), .output_DDR1_V_d0(o1_d),
    .mem_params_V_address0(p_addr), .mem_params_V_ce0(p_ce), .mem_params_V_q0(p_q)
  );

  initial begin
    if (!$value$plusargs("INPUT_WORDS=%d", input_words)) input_words = 0;
    if (!$value$plusargs("WEIGHT_WORDS=%d", weight_words)) weight_words = 0;
    for (init_index = 0; init_index < P_DEPTH; init_index = init_index + 1)
      mem_p[init_index] = 32'd0;
    $readmemh("input.hex", mem_in0);
    $readmemh("input.hex", mem_in1);
    $readmemh("weight.hex", mem_w0);
    $readmemh("param.hex", mem_p);
    sram_counter_file = $fopen("sram_access_counts.tsv", "w");
    if (!sram_counter_file) begin $display("ERROR: cannot open counters file"); $finish; end
    #20 ap_rst = 0;
    #20 ap_start = 1;
    counting = 1;
    #10 ap_start = 0;
    @(posedge ap_done);
    #20 counting = 0;
    $fwrite(sram_counter_file, "WINO_EXTERNAL_SRAM module=external name=input_DDR0 reads=%0d writes=0\n", in0_reads);
    $fwrite(sram_counter_file, "WINO_EXTERNAL_SRAM module=external name=input_DDR1 reads=%0d writes=0\n", in1_reads);
    $fwrite(sram_counter_file, "WINO_EXTERNAL_SRAM module=external name=weight_DDR0 reads=%0d writes=0\n", w0_reads);
    $fwrite(sram_counter_file, "WINO_EXTERNAL_SRAM module=external name=mem_params reads=%0d writes=0\n", p_reads);
    $fwrite(sram_counter_file, "WINO_EXTERNAL_SRAM module=external name=output_DDR0 reads=0 writes=%0d\n", o0_writes);
    $fwrite(sram_counter_file, "WINO_EXTERNAL_SRAM module=external name=output_DDR1 reads=0 writes=%0d\n", o1_writes);
    report_sram_accesses = 1;
    #1 report_sram_accesses = 0;
    #10;
    $fclose(sram_counter_file);
    $display("WINO_ACCESS_DONE cycles=%0d input_DDR0_reads=%0d input_DDR1_reads=%0d weight_DDR0_reads=%0d mem_params_reads=%0d output_DDR0_writes=%0d output_DDR1_writes=%0d",
      cycles, in0_reads, in1_reads, w0_reads, p_reads, o0_writes, o1_writes);
    $display("WINO_ACCESS_ADDR max_input0=%0d max_input1=%0d max_weight=%0d max_params=%0d input_words=%0d weight_words=%0d",
      max_in0_addr, max_in1_addr, max_w0_addr, max_p_addr, input_words, weight_words);
    if ((max_in0_addr >= input_words) || (max_in1_addr >= input_words) ||
        (max_w0_addr >= weight_words) || (max_p_addr >= P_DEPTH))
      $display("WINO_ACCESS_OOB external memory read exceeds randomized stimulus depth");
    $finish;
  end

  initial begin
    #200000000;
    $display("WINO_ACCESS_TIMEOUT cycles=%0d", cycles);
    $finish;
  end
endmodule
