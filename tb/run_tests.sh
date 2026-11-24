#!/usr/bin/env bash
# Run from this folder. Needs Icarus Verilog (iverilog + vvp).
#   sudo apt install iverilog      (Linux)   |   brew install icarus-verilog (macOS)
# Edit RTL if your RTL_design folder is elsewhere.
RTL=../RTL_design
SRC="$RTL/cells.v $RTL/hop_control.v $RTL/release.v $RTL/packer.v $RTL/ready_mem.v \
     $RTL/scores.v $RTL/scheduler_tree.v $RTL/hop_credit.v $RTL/phy_box.v \
     $RTL/hop_unpack.v $RTL/hop_path.v tb_hop_path.v"

mkdir -p out
run() {            # run <name> <param=value> ...
  name=$1; shift
  P=""; for kv in "$@"; do P="$P -Ptb_hop_path.$kv"; done
  iverilog -g2012 -o out/$name.vvp $P $SRC || { echo "COMPILE FAILED: $name"; return; }
  vvp out/$name.vvp > out/$name.log
  echo "== $name: $(grep SUMMARY out/$name.log)"
}

# 0. data integrity + timing, one tile, default config
run s0_one_tile        SCEN=0 N_TILES=1 POLICY=1
# 0b. two tiles, only one allowed in flight (default ADMIT_LIMIT=1)
run s0_two_limit1      SCEN=0 N_TILES=2 W_LEN=1 ADMIT_LIMIT=1
# 0c. two tiles in flight (W_LEN and ADMIT_LIMIT must both be 2)
run s0_two_limit2      SCEN=0 N_TILES=2 W_LEN=2 ADMIT_LIMIT=2
# 1. scheduler order for the five policies, credit starved (K=1)
for p in 0 1 2 3 4; do run s1_policy$p SCEN=1 POLICY=$p K=1; done
# 2. slot overflow
run s2_overflow        SCEN=2 POLICY=1 K=1
# 3. other flit while unpack is busy
run s3_unpack_clobber  SCEN=3 POLICY=1 N_TILES=1

echo; echo "---- FAIL / FINDING lines ----"
grep -h "FAIL\|FINDING" out/*.log | sort | uniq -c
