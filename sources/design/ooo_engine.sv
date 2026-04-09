// =============================================================================
// File        : ooo_engine.sv
// Project     : Out-of-Order Execution Engine
// Author      : Vinayak Venkappa Pujeri (Vision)
// Tool        : Cadence Xcelium / irun 15.20
//
// Micro-architecture:
//   Fetch ? [IQ] ? Dispatch ? [RS] ? Execute ? Writeback (CDB) ? [ROB] ? Commit ? RF
//
// All sequential state lives in ONE always_ff block to avoid MULAXX
// multiple-driver elaboration errors.
//
// Opcodes: 8'h01=ADD  8'h02=SUB  8'h03=AND  8'h04=OR
// =============================================================================

module ooo_engine #(
  parameter IQ_DEPTH  = 4,
  parameter RS_DEPTH  = 4,
  parameter ROB_DEPTH = 4,
  parameter RF_SIZE   = 8
)(
  input  logic       clk,
  input  logic       rstn,

  // Fetch interface
  input  logic [7:0] if_opcode,
  input  logic [2:0] if_src1, if_src2, if_dest,
  input  logic       if_valid,
  output logic       if_ready,

  // Commit interface (for TB scoreboard)
  output logic       cm_valid,
  output logic [2:0] cm_dest,
  output logic [7:0] cm_data, cm_opcode,

  output logic       rob_full, iq_full
);


  // Type definitions

  typedef struct packed {
    logic [7:0] opcode;
    logic [2:0] src1, src2, dest;
    logic       valid;
  } iq_entry_t;

  typedef struct packed {
    logic [7:0] opcode;
    logic [2:0] dest;
    logic [1:0] rob_tag;
    logic [7:0] val1, val2;
    logic       rdy1, rdy2;
    logic [1:0] tag1, tag2;
    logic       valid;
  } rs_entry_t;

  typedef struct packed {
    logic [7:0] opcode;
    logic [2:0] dest;
    logic [7:0] result;
    logic       ready;
    logic       valid;
  } rob_entry_t;


  // State registers

  iq_entry_t  iq      [0:IQ_DEPTH-1];
  rs_entry_t  rs      [0:RS_DEPTH-1];
  rob_entry_t rob     [0:ROB_DEPTH-1];

  logic [7:0] rf         [0:RF_SIZE-1];
  logic       rf_busy    [0:RF_SIZE-1];
  logic [1:0] rf_rob_tag [0:RF_SIZE-1];

  logic [1:0] iq_head,  iq_tail;
  logic [2:0] iq_count;
  logic [1:0] rob_head, rob_tail;
  logic [2:0] rob_count;

  // Execute pipeline register
  logic        ex_valid;
  logic [7:0]  ex_opcode;
  logic [2:0]  ex_dest;
  logic [1:0]  ex_rob_tag;
  logic [7:0]  ex_val1, ex_val2;

  // Writeback bus (registered)
  logic        wb_valid;
  logic [1:0]  wb_rob_tag;
  logic [7:0]  wb_result;
  logic [2:0]  wb_dest;
  logic [7:0]  wb_opcode;


  // Combinational status

  assign iq_full  = (iq_count == IQ_DEPTH);
  assign rob_full = (rob_count == ROB_DEPTH);
  assign if_ready = !iq_full;

  // Commit output: combinational peek at ROB head
  assign cm_valid  = rob[rob_head].valid && rob[rob_head].ready;
  assign cm_dest   = rob[rob_head].dest;
  assign cm_data   = rob[rob_head].result;
  assign cm_opcode = rob[rob_head].opcode;

 
  // ALU function

  function automatic logic [7:0] alu_op(input logic [7:0] op, a, b);
    case (op)
      8'h01:   return a + b;
      8'h02:   return a - b;
      8'h03:   return a & b;
      8'h04:   return a | b;
      default: return 8'hFF;
    endcase
  endfunction


  // Single always_ff all pipeline stages in program order

  always_ff @(posedge clk or negedge rstn) begin


    // RESET

    if (!rstn) begin
      iq_head  <= 2'd0; iq_tail  <= 2'd0; iq_count  <= 3'd0;
      rob_head <= 2'd0; rob_tail <= 2'd0; rob_count <= 3'd0;
      ex_valid <= 1'b0;
      wb_valid <= 1'b0; wb_rob_tag <= 2'd0; wb_result <= 8'd0;
      wb_dest  <= 3'd0; wb_opcode  <= 8'd0;
      foreach (iq[i])      iq[i]      <= '0;
      foreach (rs[i])      rs[i]      <= '0;
      foreach (rob[i])     rob[i]     <= '0;
      foreach (rf[i])      rf[i]      <= 8'(i);   // r0=0, r1=1, ..., r7=7
      foreach (rf_busy[i]) rf_busy[i] <= 1'b0;
      foreach (rf_rob_tag[i]) rf_rob_tag[i] <= 2'd0;

    end else begin

     
      // STAGE 4 WRITEBACK: latch ALU result onto WB bus

      wb_valid   <= ex_valid;
      wb_rob_tag <= ex_rob_tag;
      wb_dest    <= ex_dest;
      wb_opcode  <= ex_opcode;
      wb_result  <= ex_valid ? alu_op(ex_opcode, ex_val1, ex_val2) : 8'd0;


      // STAGE 3 EXECUTE: pick one ready RS entry (lowest index first)

      ex_valid <= 1'b0;
      for (int i = 0; i < RS_DEPTH; i++) begin
        if (rs[i].valid && rs[i].rdy1 && rs[i].rdy2 && !ex_valid) begin
          ex_valid   <= 1'b1;
          ex_opcode  <= rs[i].opcode;
          ex_dest    <= rs[i].dest;
          ex_rob_tag <= rs[i].rob_tag;
          ex_val1    <= rs[i].val1;
          ex_val2    <= rs[i].val2;
          rs[i].valid <= 1'b0;     // free RS slot
        end
      end


      // CDB BROADCAST forward WB result to waiting RS entries
      // (use CURRENT wb_valid, i.e. the result committed last cycle)

      if (wb_valid) begin
        // Update ROB result
        rob[wb_rob_tag].result <= wb_result;
        rob[wb_rob_tag].ready  <= 1'b1;
        // Forward to RS entries waiting on this tag
        for (int i = 0; i < RS_DEPTH; i++) begin
          if (rs[i].valid) begin
            if (!rs[i].rdy1 && rs[i].tag1 == wb_rob_tag)
              begin rs[i].val1 <= wb_result; rs[i].rdy1 <= 1'b1; end
            if (!rs[i].rdy2 && rs[i].tag2 == wb_rob_tag)
              begin rs[i].val2 <= wb_result; rs[i].rdy2 <= 1'b1; end
          end
        end
      end


      // STAGE 5 COMMIT: retire ROB head in program order

      if (rob[rob_head].valid && rob[rob_head].ready) begin
        rf[rob[rob_head].dest] <= rob[rob_head].result;
        if (rf_rob_tag[rob[rob_head].dest] == rob_head)
          rf_busy[rob[rob_head].dest] <= 1'b0;
        rob[rob_head].valid <= 1'b0;
        rob_head  <= rob_head  + 2'd1;
        rob_count <= rob_count - 3'd1;
      end


      // STAGE 1 ISSUE: accept new instruction into IQ

      if (if_valid && !iq_full) begin
        iq[iq_tail] <= '{opcode: if_opcode,
                          src1:   if_src1,
                          src2:   if_src2,
                          dest:   if_dest,
                          valid:  1'b1};
        iq_tail  <= iq_tail  + 2'd1;
        iq_count <= iq_count + 3'd1;
      end


      // STAGE 2 DISPATCH: IQ head ? RS + ROB (when both have space)

      begin : dispatch
        // Find a free RS slot
        automatic int  rs_slot  = -1;
        automatic logic rs_found = 1'b0;
        for (int i = 0; i < RS_DEPTH; i++) begin
          if (!rs[i].valid && !rs_found) begin rs_slot = i; rs_found = 1'b1; end
        end

        if (iq[iq_head].valid && !rob_full && rs_found) begin
          automatic logic [1:0] rtag = rob_tail;
          automatic iq_entry_t  inst = iq[iq_head];

          // Allocate ROB entry
          rob[rtag] <= '{opcode: inst.opcode,
                          dest:   inst.dest,
                          result: 8'd0,
                          ready:  1'b0,
                          valid:  1'b1};
          rob_tail  <= rob_tail  + 2'd1;
          rob_count <= rob_count + 3'd1;

          // Resolve operands: check busy bits; forward from current WB if match
          begin : resolve
            automatic logic [7:0] v1, v2;
            automatic logic       r1, r2;
            automatic logic [1:0] t1, t2;

            // src1
            if (!rf_busy[inst.src1]) begin
              v1 = rf[inst.src1]; r1 = 1'b1; t1 = 2'd0;
            end else if (wb_valid && wb_rob_tag == rf_rob_tag[inst.src1]) begin
              v1 = wb_result;     r1 = 1'b1; t1 = 2'd0;   // WB forwarding
            end else begin
              v1 = 8'd0; r1 = 1'b0; t1 = rf_rob_tag[inst.src1];
            end

            // src2
            if (!rf_busy[inst.src2]) begin
              v2 = rf[inst.src2]; r2 = 1'b1; t2 = 2'd0;
            end else if (wb_valid && wb_rob_tag == rf_rob_tag[inst.src2]) begin
              v2 = wb_result;     r2 = 1'b1; t2 = 2'd0;   // WB forwarding
            end else begin
              v2 = 8'd0; r2 = 1'b0; t2 = rf_rob_tag[inst.src2];
            end

            rs[rs_slot] <= '{opcode:  inst.opcode,
                              dest:    inst.dest,
                              rob_tag: rtag,
                              val1: v1, val2: v2,
                              rdy1: r1, rdy2: r2,
                              tag1: t1, tag2: t2,
                              valid: 1'b1};
          end

          // Mark destination register busy
          rf_busy[inst.dest]    <= 1'b1;
          rf_rob_tag[inst.dest] <= rtag;

          // Consume IQ head
          iq[iq_head].valid <= 1'b0;
          iq_head  <= iq_head  + 2'd1;
          iq_count <= iq_count - 3'd1;
        end
      end

    end // else (not reset)
  end // always_ff

endmodule : ooo_engine

