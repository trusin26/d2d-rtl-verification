#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
RTL=../RTL_design
OUT=reset_boundary_out
mkdir -p "$OUT"
sha256sum "$RTL"/*.v > "$OUT/checksums.txt"
cat > "$OUT/tb_reset.sv" <<'SV'
`timescale 1ns/1ps
module tb_reset;
reg clk=0,rst=1,panel_valid=0,other_valid=0;
always #5 clk=~clk;
reg [255:0] other_flit=0;
wire [7:0] credit_count;
wire out_valid,byte_valid,pass_en,let_square,done;
integer errors=0,received=0,stale=0;
reg monitor=0;
hop_path #(.K(1),.D_PHY(4),.N_TILES(1)) dut(
.clk(clk),.rst(rst),.panel_valid(panel_valid),.panel_byte(8'h5a),.tile_id(8'd0),.panel_sel(1'b0),
.other_valid(other_valid),.other_flit(other_flit),.other_deadline(32'd100),
.credit_count(credit_count),.out_valid(out_valid),.byte_valid(byte_valid),.pass_en(pass_en),.let_square(let_square),.done(done));
task check(input bit cond,input string msg);
 if(cond) $display("[PASS] %s",msg); else begin errors=errors+1; $display("[FAIL] %s",msg); end
endtask
always @(posedge clk) if(!rst && monitor && out_valid) begin
 received=received+1;
 if(dut.out_flit!==256'hcafe || dut.out_is_gemm!==1'b0) stale=stale+1;
end
initial begin
 repeat(3) @(negedge clk); rst=0; panel_valid=1;
 repeat(10) @(negedge clk);
 other_valid=1; other_flit=256'h1111;
 @(negedge clk); other_flit=256'h2222;
 @(negedge clk); other_valid=0;
 // At this point first flit in PHY, second queued, partial GEMM packed.
 $display("[PRE_RESET] credit=%0d ready=%0d pack_count=%0d",credit_count,dut.ready_count,dut.u_packer.cnt_q);
 check(credit_count==0 && dut.ready_count==1 && dut.u_packer.cnt_q>0,"reset precondition: outstanding + queued + partial pack");
 rst=1; panel_valid=0;
 @(negedge clk);
 check(credit_count===8'd1 && dut.ready_count===9'd0 && out_valid===1'b0 && byte_valid===1'b0 && dut.u_packer.cnt_q===6'd0 && done===1'b0,"synchronous reset clears datapath state");
 rst=0; monitor=1;
 repeat(12) @(negedge clk);
 check(received==0 && credit_count===8'd1,"no stale PHY data or credit return after reset");
 other_flit=256'hcafe; other_valid=1;
 @(negedge clk); other_valid=0;
 repeat(45) @(negedge clk);
 check(received==1 && stale==0 && credit_count===8'd1 && !byte_valid,"fresh flit delivered exactly once after reset");
 $display("[RESET_SUMMARY] errors=%0d received=%0d stale=%0d",errors,received,stale); $finish;
end
endmodule
SV
cat > "$OUT/tb_unpack_boundary.sv" <<'SV'
`timescale 1ns/1ps
module tb_unpack_boundary;
parameter integer GAP=32;
reg clk=0,rst=1,in_valid=0;
always #5 clk=~clk;
reg [255:0] flit=0;
wire byte_valid;
wire [7:0] panel_byte;
integer n=0,mismatch=0;
hop_unpack dut(.clk(clk),.rst(rst),.in_valid(in_valid),.flit(flit),.tile(8'd0),.panel_sel(1'b0),.byte_valid(byte_valid),.panel_byte(panel_byte));
always @(posedge clk) if(!rst && byte_valid) begin
 if(panel_byte !== ((n<32)?8'h11:8'h22)) mismatch=mismatch+1;
 n=n+1;
end
initial begin
 repeat(3) @(negedge clk); rst=0; in_valid=1; flit={32{8'h11}};
 @(negedge clk); in_valid=0;
 repeat(GAP-1) @(negedge clk);
 in_valid=1; flit={32{8'h22}};
 @(negedge clk); in_valid=0;
 repeat(40) @(negedge clk);
 $display("[UNPACK_BOUNDARY] gap=%0d expected_bytes=64 observed_bytes=%0d ordered_mismatch=%0d integrity_pass=%0d",GAP,n,mismatch,(n==64 && mismatch==0));
 $finish;
end
endmodule
SV
iverilog -g2012 -s tb_reset -o "$OUT/reset.vvp" "$RTL"/*.v "$OUT/tb_reset.sv"
vvp "$OUT/reset.vvp" > "$OUT/reset.log"
for gap in 1 9 31 32 33; do
  iverilog -g2012 -s tb_unpack_boundary -Ptb_unpack_boundary.GAP="$gap" -o "$OUT/unpack_$gap.vvp" "$RTL/cells.v" "$RTL/hop_unpack.v" "$OUT/tb_unpack_boundary.sv"
  vvp "$OUT/unpack_$gap.vvp" > "$OUT/unpack_$gap.log"
done
{ cat "$OUT/checksums.txt"; cat "$OUT/reset.log"; for gap in 1 9 31 32 33; do cat "$OUT/unpack_$gap.log"; done; } > "$OUT/reset_boundary_results.txt"
cat "$OUT/reset_boundary_results.txt"
