# D2D RTL Verification

## Research Project

RTL Design of Credit- and Deadline-Aware Flow
Control for a Shallow-Buffer Die-to-Die Link
under Tiled GEMM Traffic.

## Objectives

- Verify functional correctness of the RTL.
- Identify architectural and implementation issues.
- Validate credit-based flow control.
- Verify five scheduling policies.
- Establish a reproducible verification baseline.
- Prepare for performance and OpenROAD PPA evaluation.

## Scheduling Policies

| ID | Policy |
|---|---|
| 0 | First Come First Served (FCFS) |
| 1 | Earliest Deadline First (EDF) |
| 2 | Shortest Remaining |
| 3 | Most Consumers |
| 4 | Longest Remaining |

## Architecture Parameters

| Parameter | Baseline configuration |
|---|---|
| Flit width | 256 bits |
| Ready memory | 4 slots |
| PHY latency | 4 cycles |
| Credit capacity | Configurable |
| GEMM tile | 16 flits |
| Packer interface | 1 byte/cycle |
| Unpacker interface | 1 byte/cycle |

## Verification Results - Baseline V1.0

| Verification stage | Scope |
|---|---|
| Baseline simulation | 10 configurations |
| Directed verification | 4 configurations |
| Scheduler verification | 1,011 vectors |
| Buffer and admission sweep | 60 configurations |
| Saturated credit and mixed traffic | 21 configurations |
| Reset and boundary verification | 6 configurations |

Summary:

- 101 simulation configurations, excluding scheduler vectors.
- 25,275 scheduler reference checks.
- Zero scheduler reference mismatches.
- Eight registered technical findings.
- Verification sign-off remains pending.

## Technical Findings

| ID | Finding | Priority |
|---|---|---|
| V01 | Deadline feasibility | P0 |
| V02 | Scheduling policy differentiation | P0 |
| V03 | Ready memory overflow | P0 |
| V04 | Unpacker data integrity | P0 |
| V05 | Credit return and reuse timing | P2 |
| V06 | Shallow-buffer conditions | P2 |
| V07 | Sequence number wrap-around | P1 |
| V08 | Credit model abstraction | P1 |

See the verification report in `docs/` for
experimental evidence, root cause analysis,
and proposed design review decisions.

## Repository Structure

- `RTL_design/`: Original baseline RTL.
- `tb/`: Verification scripts and testbench.
- `results/`: Consolidated simulation evidence.
- `docs/`: Technical verification reports.

## Reproduction

Requirements:

- Linux or WSL2
- Icarus Verilog
- Bash
- Python 3

Run the verification scripts from the `tb/`
directory:

    cd tb

    bash run_tests.sh
    bash run_directed.sh
    bash run_scheduler_verify.sh
    bash run_buffer_sweep.sh
    bash run_contention_verify.sh
    bash run_reset_boundary.sh

## Research Roadmap

- [x] Baseline simulation
- [x] RTL root cause analysis
- [x] Directed verification
- [x] Scheduler verification
- [x] Buffer and admission sweep
- [x] Mixed traffic verification
- [x] Reset and boundary verification
- [x] Verification findings report V1.0
- [ ] Team design review
- [ ] RTL revision
- [ ] Regression verification
- [ ] Golden model equivalence
- [ ] Scheduling performance evaluation
- [ ] OpenROAD PPA evaluation

## Current Status

The diagnostic verification campaign is complete.

The RTL baseline is preserved for reproducibility.
The identified findings remain subject to team
design review and specification agreement.

This baseline is not a verification sign-off release.

## Research Confidentiality

This repository contains ongoing research.
Redistribution requires authorization from
the project team.
