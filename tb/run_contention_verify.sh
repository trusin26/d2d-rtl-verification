#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
RTL=../RTL_design
OUT=contention_out
mkdir -p "$OUT"
SRC=("$RTL"/*.v)
sha256sum "${SRC[@]}" tb_hop_path.v > "$OUT/checksums.txt"
cat > "$OUT/tb_credit_sat.sv" <<'SV'
`timescale 1ns/1ps
module tb_credit_sat;
parameter integer K=1;
reg clk=0, rst=1, request=0;
always #5 clk=~clk;
wire [7:0] credit;
wire send, ret;
hop_credit #(.K(K),.DEPTH(8)) dut(.clk(clk),.rst(rst),.send_en(request),.grant_valid(request),.credit_count(credit),.pass_en(send),.credit_return(ret));
integer c=0, n=0, outstanding=0, errors=0, stalls=0;
reg [7:0] history=0;
always @(posedge clk) begin
 if(rst) begin c=0; outstanding=0; history=0; end
 else begin
  c=c+1;
  if(credit !== (K-outstanding) || ret !== history[7] || send !== (request && credit>0)) errors=errors+1;
  if(request && !send) stalls=stalls+1;
  if(request && send) n=n+1;
  outstanding=outstanding+(send?1:0)-(ret?1:0);
  history={history[6:0],send};
 end
end
initial begin
 repeat(4) @(negedge clk); rst=0; request=1;
 repeat(900) @(negedge clk); request=0;
 repeat(12) @(negedge clk);
 if(credit!==K || outstanding!=0 || n!=100*((K<9)?K:9)) errors=errors+1;
 $display("[CREDIT_SAT] K=%0d sends=%0d window=900 stalls=%0d errors=%0d",K,n,stalls,errors);
 if(errors) $fatal(1,"credit check failed");
 $finish;
end
endmodule
SV
python3 - "$OUT" <<'PY'
import pathlib,sys
out=pathlib.Path(sys.argv[1]); s=pathlib.Path('tb_hop_path.v').read_text()
start=s.index('            3: begin',s.index('// stimulus'))
end=s.index('            default:',start)
s=s[:start]+'''            3: begin
                feed_en = 1'b1;
                // Keep other traffic queued without intentionally overflowing.
                // Reserve at least one slot for a possible simultaneous GEMM record.
                while (stress_tag < 128) begin
                    @(negedge clk);
                    other_valid <= (dut.ready_count <= 2);
                    if (dut.ready_count <= 2) begin
                        other_flit <= {248'd0, stress_tag[7:0]};
                        case (stress_tag % 3)
                            0: other_deadline <= 40;
                            1: other_deadline <= 56;
                            2: other_deadline <= 1000;
                        endcase
                        stress_tag = stress_tag + 1;
                    end
                end
                idle_other;
                // Bounded drain, even if a tile is lost and done never asserts.
                repeat (2000) @(negedge clk);
            end
'''+s[end:]
# Replace original order-dependent verdict with observational reporting for stress.
s=s.replace('            if (SCEN == 0 || SCEN == 3) report_gemm;', '            if (SCEN == 0) report_gemm;')
s=s.replace('            if (SCEN == 3) report_scen3;', '''            if (SCEN == 3) begin
                $display("[MIXED_SUMMARY] policy=%0d K=%0d gemm_packed=%0d gemm_received=%0d other_in=%0d other_out=%0d done=%0d multi_grants=%0d credit_blocked=%0d other_dup=%0d other_missing=%0d", POLICY,K,rec_fire_cnt,gem_flit_cnt,other_inj_cnt,other_out_cnt,done,multi_grants,credit_blocked,other_dup,128-other_unique);
                $display("[POLICY_DIFF] vs_EDF P0=%0d P1=%0d P2=%0d P3=%0d P4=%0d",diff[0],diff[1],diff[2],diff[3],diff[4]);
                $display("[GEMM_OBSERVATION] ordered_flit_mism=%0d bytes_out=%0d ordered_byte_mism=%0d extra_bytes=%0d",flit_mism,byte_cnt,byte_mism,extra_bytes);
            end''')
insert='''
    integer stress_tag=0, multi_grants=0, credit_blocked=0, other_dup=0, other_unique=0;
    reg [127:0] received_other=0;
    integer diff[0:4];
    wire [47:0] alt_score[0:4][0:3];
    wire [7:0] alt_idx[0:4];
    wire alt_valid[0:4];
    genvar p;
    generate for(p=0;p<5;p=p+1) begin: alt
        score_link #(.POLICY(p)) a0(.record(dut.r0),.score(alt_score[p][0]));
        score_link #(.POLICY(p)) a1(.record(dut.r1),.score(alt_score[p][1]));
        score_link #(.POLICY(p)) a2(.record(dut.r2),.score(alt_score[p][2]));
        score_link #(.POLICY(p)) a3(.record(dut.r3),.score(alt_score[p][3]));
        scheduler_tree #(.WIDTH(48)) a4(.v0(dut.v0),.v1(dut.v1),.v2(dut.v2),.v3(dut.v3),.s0(alt_score[p][0]),.s1(alt_score[p][1]),.s2(alt_score[p][2]),.s3(alt_score[p][3]),.grant_valid(alt_valid[p]),.grant_idx(alt_idx[p]),.grant_score());
    end endgenerate
    integer q;
    initial for(integer z=0;z<5;z=z+1) diff[z]=0;
    always @(posedge clk) if(!rst) begin
        if(dut.grant_valid && credit_count==0) credit_blocked=credit_blocked+1;
        if(pass_en && dut.ready_count>1) begin
            multi_grants=multi_grants+1;
            for(q=0;q<5;q=q+1) if(alt_valid[q] && alt_valid[1] && alt_idx[q]!=alt_idx[1]) diff[q]=diff[q]+1;
            $display("[CONTENTION] occ=%0d selected=%0d EDF=%0d P0=%0d P2=%0d P3=%0d P4=%0d records=%h,%h,%h,%h",dut.ready_count,dut.grant_idx,alt_idx[1],alt_idx[0],alt_idx[2],alt_idx[3],alt_idx[4],dut.r0[335:256],dut.r1[335:256],dut.r2[335:256],dut.r3[335:256]);
        end
        if(out_valid && !out_is_gemm) begin
            if(out_flit[255:8]!=0 || out_flit[7:0]>=128) $display("[OTHER_BAD] payload=%h",out_flit);
            else if(received_other[out_flit[6:0]]) other_dup=other_dup+1;
            else begin received_other[out_flit[6:0]]=1; other_unique=other_unique+1; end
        end
    end
'''
s=s.replace('    // bookkeeping', '    // bookkeeping',1)
pos=s.index('    // ------------------------------------------------------------------\n    // bookkeeping'); s=s[:pos]+insert+s[pos:]
(out/'tb_mixed_stress.sv').write_text(s)
PY
for k in 1 2 4 8 9 16; do
  iverilog -g2012 -s tb_credit_sat -Ptb_credit_sat.K="$k" -o "$OUT/credit_k$k.vvp" "$RTL/cells.v" "$RTL/hop_credit.v" "$OUT/tb_credit_sat.sv"
  vvp "$OUT/credit_k$k.vvp" > "$OUT/credit_k$k.log"
  grep CREDIT_SAT "$OUT/credit_k$k.log"
done
for k in 1 4 16; do
 for p in 0 1 2 3 4; do
  n="mixed_k${k}_p${p}"
  iverilog -g2012 -s tb_hop_path -Ptb_hop_path.SCEN=3 -Ptb_hop_path.K="$k" -Ptb_hop_path.POLICY="$p" -Ptb_hop_path.N_TILES=2 -Ptb_hop_path.W_LEN=2 -Ptb_hop_path.ADMIT_LIMIT=2 -o "$OUT/$n.vvp" "${SRC[@]}" "$OUT/tb_mixed_stress.sv"
  vvp "$OUT/$n.vvp" > "$OUT/$n.log"
  grep -E 'MIXED_SUMMARY|POLICY_DIFF|GEMM_OBSERVATION' "$OUT/$n.log"
 done
done
{ cat "$OUT/checksums.txt"; for f in "$OUT"/credit_k*.log "$OUT"/mixed_k*.log; do echo "===== $f ====="; cat "$f"; done; } > "$OUT/contention_results.txt"
