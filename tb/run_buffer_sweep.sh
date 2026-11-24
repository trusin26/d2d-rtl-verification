#!/usr/bin/env bash
set -euo pipefail

RTL=../RTL_design
OUT=buffer_sweep_out

mkdir -p "$OUT"

SRC=(
    "$RTL/cells.v"
    "$RTL/hop_control.v"
    "$RTL/release.v"
    "$RTL/packer.v"
    "$RTL/ready_mem.v"
    "$RTL/scores.v"
    "$RTL/scheduler_tree.v"
    "$RTL/hop_credit.v"
    "$RTL/phy_box.v"
    "$RTL/hop_unpack.v"
    "$RTL/hop_path.v"
    tb_hop_path.v
)

sha256sum "${SRC[@]}" > "$OUT/checksums.txt"

for k in 1 2 4 8 9 16; do
    for p in 0 1 2 3 4; do
        for a in 1 2; do

            name="k${k}_p${p}_a${a}"

            iverilog -g2012 \
                -s tb_hop_path \
                -Ptb_hop_path.SCEN=0 \
                -Ptb_hop_path.K="$k" \
                -Ptb_hop_path.POLICY="$p" \
                -Ptb_hop_path.D_PHY=4 \
                -Ptb_hop_path.N_TILES=2 \
                -Ptb_hop_path.W_LEN="$a" \
                -Ptb_hop_path.ADMIT_LIMIT="$a" \
                -o "$OUT/$name.vvp" \
                "${SRC[@]}"

            vvp "$OUT/$name.vvp" \
                > "$OUT/$name.log"

            echo "$name: $(grep SUMMARY "$OUT/$name.log")"

        done
    done
done

{
    cat "$OUT/checksums.txt"

    for f in "$OUT"/k*_p*_a*.log; do
        echo
        echo "===== $f ====="
        cat "$f"
    done
} > "$OUT/buffer_sweep_results.txt"

echo "Sweep completed."
