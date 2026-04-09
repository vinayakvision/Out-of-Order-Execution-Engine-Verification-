# Out-of-Order Execution Engine

**Author:** Vinayak Venkappa Pujeri (Vision)
**Tool:** Cadence Xcelium / irun 15.20

---

## Overview

A 4-entry Tomasulo-inspired Out-of-Order execution engine in synthesisable
SystemVerilog. Instructions are issued in-order, may execute out-of-order when
operands are ready, and commit in-order via the Reorder Buffer.

---

## Project Structure

```
ooo_engine/
├── rtl/
│   └── ooo_engine.sv       # Synthesisable OOO engine (5-stage pipeline)
├── tb/
│   └── ooo_engine_tb.sv    # Self-checking TB with software reference model
├── Makefile
└── README.md
```

---

## Micro-architecture

```
Fetch → [IQ] → Dispatch → [RS] → Execute → Writeback (CDB) → [ROB] → Commit → RF
```

| Structure | Depth | Role |
|---|---|---|
| Instruction Queue (IQ) | 4 | In-order fetch buffer |
| Reservation Station (RS) | 4 | OOO dispatch — fires when operands ready |
| ALU | 1 | 1-cycle ADD / SUB / AND / OR |
| Reorder Buffer (ROB) | 4 | In-order commit; holds results until head ready |
| Register File (RF) | 8×8-bit | Architectural state; updated at commit |

### Key mechanisms
- **Busy bits + ROB tags** on each RF register detect RAW hazards at dispatch
- **CDB broadcast** (Common Data Bus): WB result forwarded to all waiting RS entries
- **WB forwarding to dispatch**: if a result arrives on WB in the same cycle a
  dependent instruction is dispatched, the value is captured directly — no extra stall
- **In-order commit**: ROB head committed only when `ready` bit is set

---

## Supported Opcodes

| Opcode | Operation |
|---|---|
| `8'h01` | ADD  dest = src1 + src2 |
| `8'h02` | SUB  dest = src1 − src2 |
| `8'h03` | AND  dest = src1 & src2 |
| `8'h04` | OR   dest = src1 \| src2 |

---

## Test Cases

| TC | Scenario | What is verified |
|---|---|---|
| TC1 | Single ADD | Basic execution and commit |
| TC2 | Single SUB | SUB opcode, read-after-commit RF value |
| TC3 | RAW hazard: ADD → SUB on same dest/src | I2 stalls in RS until I1 writes back; commits in program order |
| TC4 | Two independent ADDs | May execute OOO; scoreboard checks program-order commit |
| TC5 | ADD, SUB, AND, OR chain | All four opcodes; chained RAW through r7 |

---

## Testbench Design

- **`send_instr` task**: drives the fetch interface; simultaneously updates a
  software reference model (sequential RF) to compute expected commit values
- **Scoreboard queue**: expected commits pushed in program order; commit monitor
  pops and checks each `cm_valid` pulse
- **`drain` task**: waits up to 40 cycles for all pending commits; reports
  timeout as FAIL if engine deadlocks
- **Watchdog**: hard `$finish` at 100 µs prevents infinite hang

---

## How to Run

```bash
make sim      # Cadence irun
make waves    # SimVision waveform viewer
make clean
```



