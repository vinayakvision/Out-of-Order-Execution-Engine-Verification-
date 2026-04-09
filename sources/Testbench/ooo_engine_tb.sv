// =============================================================================
// File        : ooo_engine_tb.sv
// Project     : Out-of-Order Execution Engine
// Author      : Vinayak Venkappa Pujeri (Vision)
//
// Self-checking testbench. Drives instructions via the fetch interface;
// monitors the commit port; compares committed results against a software
// reference model computed in the testbench.
//
// Test Cases:
//   TC1 Single ADD instruction
//   TC2 Single SUB instruction
//   TC3 RAW hazard: ADD result consumed by SUB (must stall in RS
//          until ADD writeback, then execute in correct order)
//   TC4 Independent instructions: two ADDs with no dependency
//          (may execute out of order, both must commit in program order)
//   TC5 All four opcodes: ADD, SUB, AND, OR
// =============================================================================


module ooo_engine_tb;


  // Clock & Reset

  logic clk   = 0;
  logic rstn  = 0;
  always #5 clk = ~clk;


  // DUT signals

  logic [7:0] if_opcode;
  logic [2:0] if_src1, if_src2, if_dest;
  logic       if_valid, if_ready;
  logic       cm_valid;
  logic [2:0] cm_dest;
  logic [7:0] cm_data, cm_opcode;
  logic       rob_full, iq_full;

  ooo_engine #(
    .IQ_DEPTH(4), .RS_DEPTH(4), .ROB_DEPTH(4), .RF_SIZE(8)
  ) dut (
    .clk(clk), .rstn(rstn),
    .if_opcode(if_opcode), .if_src1(if_src1),
    .if_src2(if_src2),     .if_dest(if_dest),
    .if_valid(if_valid),   .if_ready(if_ready),
    .cm_valid(cm_valid),   .cm_dest(cm_dest),
    .cm_data(cm_data),     .cm_opcode(cm_opcode),
    .rob_full(rob_full),   .iq_full(iq_full)
  );


  // Software reference model
  //   Mirrors the DUT register file. Updated when we ISSUE an instruction
  //   (sequential model) so we can predict committed values.

  logic [7:0] ref_rf [0:7];

  function automatic logic [7:0] ref_alu(
    input logic [7:0] op, a, b);
    case (op)
      8'h01: return a + b;
      8'h02: return a - b;
      8'h03: return a & b;
      8'h04: return a | b;
      default: return 8'hFF;
    endcase
  endfunction


  // Scoreboard queue expected commits in program order

  typedef struct {
    logic [2:0] dest;
    logic [7:0] exp_data;
    logic [7:0] opcode;
    string      label;
  } expect_t;

  expect_t exp_q[$];    // SystemVerilog queue


  // Scoreboard counters

  int pass_cnt = 0, fail_cnt = 0;


  // Task: send one instruction; update reference model; push expected commit

  task automatic send_instr(
    input logic [7:0] opcode,
    input logic [2:0] src1, src2, dest,
    input string      label
  );
    // Wait for IQ space
    @(posedge clk);
    while (!if_ready) @(posedge clk);

    if_opcode <= opcode;
    if_src1   <= src1;
    if_src2   <= src2;
    if_dest   <= dest;
    if_valid  <= 1;

    @(posedge clk);
    if_valid <= 0;

    // Update reference model
    ref_rf[dest] = ref_alu(opcode, ref_rf[src1], ref_rf[src2]);

    // Push expected commit
    exp_q.push_back('{dest:     dest,
                      exp_data: ref_rf[dest],
                      opcode:   opcode,
                      label:    label});
    $display("  [SEND]  %-25s  dest=r%0d  exp=0x%02h",
             label, dest, ref_rf[dest]);
  endtask


  // Commit monitor runs continuously, checks against scoreboard

  initial begin
    forever begin
      @(posedge clk);
      if (cm_valid) begin
        if (exp_q.size() == 0) begin
          $display("  [FAIL]  Unexpected commit: dest=r%0d data=0x%02h",
                   cm_dest, cm_data);
          fail_cnt++;
        end else begin
          automatic expect_t e = exp_q.pop_front();
          if (cm_dest === e.dest && cm_data === e.exp_data) begin
            $display("  [PASS]  %-25s  dest=r%0d  got=0x%02h",
                     e.label, cm_dest, cm_data);
            pass_cnt++;
          end else begin
            $display("  [FAIL]  %-25s  dest=r%0d  got=0x%02h  exp=0x%02h",
                     e.label, cm_dest, cm_data, e.exp_data);
            fail_cnt++;
          end
        end
      end
    end
  end


  // Task: wait for all pending commits to drain

  task automatic drain(input int timeout_cycles = 40);
    int cnt = 0;
    while (exp_q.size() > 0 && cnt < timeout_cycles) begin
      @(posedge clk); cnt++;
    end
    if (exp_q.size() > 0) begin
      $display("  [FAIL]  Drain timeout: %0d commits still pending",
               exp_q.size());
      fail_cnt += exp_q.size();
      exp_q.delete();
    end
    repeat(4) @(posedge clk);
  endtask


  // Initialise reference RF to match DUT reset values (r[i] = i)

  initial foreach (ref_rf[i]) ref_rf[i] = 8'(i);


  // VCD dump

  initial begin
    $dumpfile("ooo_engine.vcd");
    $dumpvars(0, ooo_engine_tb);
  end


  // Main stimulus

  initial begin
    if_valid = 0; if_opcode = 0;
    if_src1  = 0; if_src2 = 0; if_dest = 0;

    // Reset
    rstn = 0; repeat(4) @(posedge clk); rstn = 1;
    repeat(2) @(posedge clk);
    $display("\n[%0t ns] Reset released  (r0=%0d r1=%0d r2=%0d r3=%0d)",
             $time/1000, 0, 1, 2, 3);

    // TC1 Single ADD:  r2 = r0 + r1  (0 + 1 = 1)

    $display("\n TC1: Single ADD ");
    send_instr(8'h01, 3'd0, 3'd1, 3'd2, "ADD r2=r0+r1");
    drain();


    // TC2 Single SUB:  r5 = r3 - r2  (3 - 1 = 2, r2 now=1 from TC1)

    $display("\n TC2: Single SUB ");
    send_instr(8'h02, 3'd3, 3'd2, 3'd5, "SUB r5=r3-r2");
    drain();


    // TC3 RAW hazard:
    //   I1: r4 = r1 + r2   (1 + 1 = 2)   produces r4
    //   I2: r6 = r4 - r3   (2 - 3 = -1)  consumes r4 (must wait for I1)
    //   I2 must stall in RS until I1 writes back r4.

    $display("\n TC3: RAW Hazard (I2 waits for I1) ");
    send_instr(8'h01, 3'd1, 3'd2, 3'd4, "ADD r4=r1+r2 (produces)");
    send_instr(8'h02, 3'd4, 3'd3, 3'd6, "SUB r6=r4-r3 (RAW on r4)");
    drain();


    // TC4 Independent instructions (may execute OOO, commit in order):
    //   I1: r0 = r1 + r2   (1 + 1 = 2)
    //   I2: r1 = r3 + r4   (3 + 2 = 5)

    $display("\n TC4: Independent OOO Instructions ");
    send_instr(8'h01, 3'd1, 3'd2, 3'd0, "ADD r0=r1+r2");
    send_instr(8'h01, 3'd3, 3'd4, 3'd1, "ADD r1=r3+r4");
    drain();


    // TC5 All four opcodes

    $display("\n TC5: All Four Opcodes ");
    send_instr(8'h01, 3'd0, 3'd1, 3'd7, "ADD r7=r0+r1");
    send_instr(8'h02, 3'd7, 3'd2, 3'd7, "SUB r7=r7-r2");
    send_instr(8'h03, 3'd7, 3'd3, 3'd7, "AND r7=r7&r3");
    send_instr(8'h04, 3'd7, 3'd4, 3'd7, "OR  r7=r7|r4");
    drain();

    // Summary

    $display("  SIMULATION COMPLETE  |  PASS: %0d  |  FAIL: %0d",
             pass_cnt, fail_cnt);

    if (fail_cnt == 0)
      $display("   ALL TESTS PASSED - DESIGN VERIFIED \n");
    else
      $display("   %0d TEST(S) FAILED \n", fail_cnt);

    $stop;
  end

  // Watchdog
  initial begin
    #100000;
    $display("[WATCHDOG] Simulation timeout at %0t ns", $time/1000);
    $finish;
  end
initial begin
        $shm_open("wave.shm");
        $shm_probe("ACTMF");
    end

endmodule : ooo_engine_tb

