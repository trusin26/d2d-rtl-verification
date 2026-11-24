#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
RTL=../RTL_design
mkdir -p scheduler_out
cat > scheduler_out/tb_scheduler_verify.sv <<'SV'
`timescale 1ns/1ps
module tb_scheduler_verify;
reg [335:0] r[0:3];
wire [47:0] s[0:4][0:3];
wire [7:0] idx[0:4];
wire [47:0] win[0:4];
wire [4:0] valid;
integer p,j,n,best,checks=0,errors=0;
integer seed=123456;
reg [47:0] e,bs;
genvar a,b;
generate for(a=0;a<5;a=a+1) begin: pol
 for(b=0;b<4;b=b+1) begin: slot
 score_link #(.POLICY(a)) u(r[b],s[a][b]);
 end
 scheduler_tree u(r[0][335],r[1][335],r[2][335],r[3][335],s[a][0],s[a][1],s[a][2],s[a][3],valid[a],idx[a],win[a]);
end endgenerate
function automatic [335:0] rec(input bit v,input integer d,input integer q,input integer l,input integer panel,input integer c);
 reg [335:0] x;
 begin x=0; x[335]=v; x[312:281]=d; x[280:265]=q; x[317:313]=l; x[264]=panel; x[325:318]=c; rec=x; end
endfunction
function automatic [47:0] oracle(input integer policy,input [335:0] x);
 reg [47:0] d,q,l,c,pn;
 begin
 d=x[312:281]; q=x[280:265]; l=x[317:313]; c=x[325:318]; pn=x[264];
 case(policy)
 0: oracle=q;
 1: oracle=d*65536+q;
 2: oracle=d*65536+l*2048+(q%2048);
 3: oracle=d*65536+pn*32768+(255-c)*128+l*4+(q%4);
 4: oracle=d*65536+(31-l)*2048+(q%2048);
 endcase
 end
endfunction
task automatic verify(input string name,input bit verbose);
 integer i,k,w; reg [47:0] expected,minimum;
 begin
 #1;
 for(i=0;i<5;i=i+1) begin
 w=-1; minimum=48'hffffffffffff;
 for(k=0;k<4;k=k+1) begin
 expected=oracle(i,r[k]); checks=checks+1;
 if(s[i][k] !== expected) begin errors=errors+1; $display("[FAIL_SCORE] %s P=%0d slot=%0d got=%h expected=%h",name,i,k,s[i][k],expected); end
 if(r[k][335] && (w<0 || expected<minimum)) begin w=k; minimum=expected; end
 end
 checks=checks+1;
 if(valid[i] !== (w>=0) || (w>=0 && (idx[i] !== w[7:0] || win[i] !== minimum))) begin errors=errors+1; $display("[FAIL_GRANT] %s P=%0d got=%0d expected=%0d",name,i,idx[i],w); end
 if(verbose) $display("[DIRECTED] %s POLICY=%0d valid=%b winner=%0d expected=%0d score=%h",name,i,valid[i],idx[i],w,win[i]);
 end
 end
endtask
initial begin
 r[0]=0;r[1]=0;r[2]=0;r[3]=0;verify("all_invalid",1);
 r[0]=rec(0,0,0,0,0,0);r[3]=rec(1,100,9,4,1,2);verify("only_slot3_valid",1);
 r[0]=rec(1,100,1,8,0,1);r[1]=rec(1,80,2,2,1,9);r[3]=0;verify("deadline_vs_arrival",1);
 r[0]=rec(1,80,1,8,0,1);r[1]=rec(1,80,2,2,0,1);verify("remaining_tie",1);
 r[0]=rec(1,80,1,4,1,255);r[1]=rec(1,80,2,4,0,1);verify("panel_priority",1);
 r[0]=rec(1,80,1,4,0,1);r[1]=rec(1,80,2,4,0,9);verify("consumer_priority",1);
 r[0]=rec(1,80,1,8,0,9);r[1]=rec(1,80,2,2,0,9);verify("shared_remaining",1);
 r[0]=rec(1,80,3,4,0,1);r[1]=rec(1,80,4,4,0,1);verify("seq_wrap_3_4",1);
 r[0]=rec(1,80,2047,4,0,1);r[1]=rec(1,80,2048,4,0,1);verify("seq_wrap_2047_2048",1);
 r[0]=rec(1,80,65535,4,0,1);r[1]=rec(1,80,0,4,0,1);verify("seq_wrap_65535_0",1);
 r[0]=rec(1,80,1,4,0,1);r[1]=r[0];r[2]=r[0];r[3]=r[0];verify("exact_tie_leftmost",1);
 for(n=0;n<1000;n=n+1) begin
 for(j=0;j<4;j=j+1) begin
 r[j]=rec($random(seed), ($unsigned($random(seed))%4), $random(seed), $random(seed), $random(seed), $random(seed));
 end
 verify("random",0);
 end
 $display("[SCHEDULER_SUMMARY] vectors=1011 checks=%0d errors=%0d",checks,errors);
 if(errors) $fatal(1,"scheduler verification failed");
 $finish;
end
endmodule
SV
iverilog -g2012 -s tb_scheduler_verify -o scheduler_out/scheduler.vvp "$RTL/cells.v" "$RTL/scores.v" "$RTL/scheduler_tree.v" scheduler_out/tb_scheduler_verify.sv
vvp scheduler_out/scheduler.vvp | tee scheduler_out/scheduler_results.txt
