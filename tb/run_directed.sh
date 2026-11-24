#!/usr/bin/env bash
# Run from tb/; does not modify original RTL or baseline testbench.
set -euo pipefail
cd -- "$(dirname -- "$0")"
mkdir -p directed_out
python3 - <<'PY'
from pathlib import Path
s=Path('tb_hop_path.v').read_text()
assert s.count('endmodule') == 1
s=s.replace('input [8*72-1:0] msg;', 'input [8*160-1:0] msg;')
# Add independent observation; do not alter stimulus.
s=s.replace('endmodule', r'''
    integer dc=0, phy_errors=0, credit_errors=0, overwrite_events=0;
    integer full_reject_other=0, full_reject_gemm=0;
    integer available, q, outstanding;
    reg [335:0] expected_phy [0:D_PHY-1];
    reg [2*D_PHY-1:0] expected_return;
    reg [255:0] injected_tags=0, received_tags=0;
    always @(posedge clk) begin
        if (rst) begin
            dc=0;
            expected_return=0;
            for(q=0;q<D_PHY;q=q+1) expected_phy[q]=0;
        end else begin
            dc=dc+1;
            if (out_valid !== expected_phy[D_PHY-1][335] ||
                (expected_phy[D_PHY-1][335] &&
                ({out_is_gemm,out_panel_sel,out_tile,out_flit} !==
                 {expected_phy[D_PHY-1][334],expected_phy[D_PHY-1][264],expected_phy[D_PHY-1][263:256],expected_phy[D_PHY-1][255:0]}))) begin
                phy_errors=phy_errors+1;
                $display("[PHY_FAIL] cycle=%0d",dc);
            end
            for(q=D_PHY-1;q>0;q=q-1) expected_phy[q]=expected_phy[q-1];
            expected_phy[0]=pass_en ? dut.record : 336'd0;
            outstanding=0;
            for(q=0;q<2*D_PHY;q=q+1) outstanding=outstanding+expected_return[q];
            if ((int'(credit_count)+outstanding != K) ||
                (dut.credit_return !== expected_return[2*D_PHY-1]) ||
                (pass_en && credit_count==0)) begin
                credit_errors=credit_errors+1;
                $display("[CREDIT_FAIL] cycle=%0d credit=%0d outstanding=%0d",dc,credit_count,outstanding);
            end
            if (pass_en || dut.credit_return)
                $display("[CREDIT_EVENT] cycle=%0d send=%b return=%b credit_pre=%0d",dc,pass_en,dut.credit_return,credit_count);
            expected_return={expected_return[2*D_PHY-2:0],pass_en};
            available=4-int'(dut.ready_count)+(pass_en ? 1 : 0);
            if(dut.rec_valid) begin
                if(available>0) available=available-1;
                else begin
                    full_reject_gemm=full_reject_gemm+1;
                    $display("[GEMM_REJECT_PREDICTED] cycle=%0d tile=%0d",dc,dut.rec_tile);
                end
            end
            if(other_valid) begin
                injected_tags[other_flit[7:0]]=1;
                $display("[OTHER_IN] cycle=%0d tag=%0d ready_count=%0d send=%b",dc,other_flit[7:0],dut.ready_count,pass_en);
                if(available<=0) begin
                    full_reject_other=full_reject_other+1;
                    $display("[OTHER_REJECT_PREDICTED] cycle=%0d tag=%0d",dc,other_flit[7:0]);
                end
            end
            if(out_valid && !out_is_gemm) begin
                if(received_tags[out_flit[7:0]]) $display("[DUPLICATE_OTHER] cycle=%0d tag=%0d",dc,out_flit[7:0]);
                received_tags[out_flit[7:0]]=1;
                $display("[OTHER_OUT] cycle=%0d tag=%0d",dc,out_flit[7:0]);
            end
            if(out_valid && dut.u_unpack.cnt_q>1) begin
                overwrite_events=overwrite_events+1;
                $display("[OVERWRITE_EVENT] cycle=%0d is_gemm=%b remaining_pre=%0d old_word=%h new_word=%h",dc,out_is_gemm,dut.u_unpack.cnt_q,dut.u_unpack.word_q,out_flit);
            end
        end
    end
    final begin
        $display("[DIRECTED_SUMMARY] phy_errors=%0d credit_errors=%0d overwrite_events=%0d predicted_other_reject=%0d predicted_gemm_reject=%0d",phy_errors,credit_errors,overwrite_events,full_reject_other,full_reject_gemm);
        for(integer tag=0;tag<256;tag=tag+1)
            if(injected_tags[tag] && !received_tags[tag]) $display("[MISSING_OTHER] tag=%0d",tag);
    end
endmodule''')
Path('directed_out/tb_trace.v').write_text(s)
PY
for spec in 'clean 0 16' 'credit 1 1' 'overflow 2 1' 'mixed 3 16'; do
    read -r name scen k <<< "$spec"
    iverilog -g2012 -s tb_hop_path -Ptb_hop_path.SCEN="$scen" -Ptb_hop_path.K="$k" -o "directed_out/$name.vvp" ../RTL_design/*.v directed_out/tb_trace.v
    vvp "directed_out/$name.vvp" > "directed_out/$name.log"
    echo "===== $name ====="
    grep -E 'SUMMARY|MISSING_OTHER|OVERWRITE_EVENT|REJECT_PREDICTED|PHY_FAIL|CREDIT_FAIL|DUPLICATE_OTHER' "directed_out/$name.log" || true
done
{
    sha256sum ../RTL_design/*.v tb_hop_path.v
    for f in directed_out/{clean,credit,overflow,mixed}.log; do echo "===== $f ====="; cat "$f"; done
} > directed_out/directed_results.txt
