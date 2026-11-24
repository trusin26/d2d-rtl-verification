`timescale 1ns/1ps
// ---------------------------------------------------------------------------
// tb_hop_path.v - testbench for one D2D hop (hop_path).
//
// Prints two kinds of lines:
//   [PASS]/[FAIL]  a property the design should satisfy (data integrity, ...)
//   [FINDING]      a behaviour worth discussing with the author; not
//                  necessarily a bug, may be a modelling choice.
//
// SCEN 0  one or more GEMM tiles, 1 byte/cycle, no other-stack traffic
//         -> data integrity, timing vs deadline, credit use, admission
// SCEN 1  four "other" flits with K=1 (credit starved) -> scheduler order
//         per POLICY, and credit round trip length
// SCEN 2  eight "other" flits back to back with K=1 -> slot overflow / drop
// SCEN 3  GEMM tile + one other flit injected while unpack is busy
//         -> does the other flit corrupt the GEMM byte stream?
// ---------------------------------------------------------------------------
module tb_hop_path;
    parameter integer SCEN        = 0;
    parameter integer POLICY      = 1;
    parameter integer K           = 16;
    parameter integer D_PHY       = 4;
    parameter integer N_TILES     = 1;
    parameter integer W_LEN       = 1;
    parameter integer ADMIT_LIMIT = 1;
    parameter integer C_TILE      = 16;
    parameter integer MAXCYC      = 40000;

    reg clk = 1'b0;
    reg rst = 1'b1;
    always #5 clk = ~clk;

    reg          panel_valid = 1'b0;
    reg  [7:0]   panel_byte  = 8'd0;
    reg  [7:0]   tile_id     = 8'd0;
    reg          panel_sel   = 1'b0;
    reg          other_valid = 1'b0;
    reg  [255:0] other_flit  = 256'd0;
    reg  [31:0]  other_deadline = 32'd0;

    wire         release_en, let_square, pass_en, square_finished, done;
    wire [7:0]   credit_count;
    wire         out_valid, out_is_gemm, out_panel_sel;
    wire [255:0] out_flit;
    wire [7:0]   out_tile;
    wire         byte_valid, byte_panel;
    wire [7:0]   byte_out, byte_tile;

    hop_path #(
        .POLICY(POLICY), .K(K), .D_PHY(D_PHY), .N_TILES(N_TILES),
        .W_LEN(W_LEN), .ADMIT_LIMIT(ADMIT_LIMIT), .C_TILE(C_TILE)
    ) dut (
        .clk(clk), .rst(rst),
        .panel_valid(panel_valid), .panel_byte(panel_byte),
        .tile_id(tile_id), .panel_sel(panel_sel),
        .other_valid(other_valid), .other_flit(other_flit),
        .other_deadline(other_deadline),
        .release_en(release_en), .let_square(let_square), .pass_en(pass_en),
        .credit_count(credit_count), .square_finished(square_finished),
        .done(done),
        .out_valid(out_valid), .out_is_gemm(out_is_gemm), .out_flit(out_flit),
        .out_tile(out_tile), .out_panel_sel(out_panel_sel),
        .byte_valid(byte_valid), .byte_out(byte_out),
        .byte_tile(byte_tile), .byte_panel(byte_panel)
    );

    // ------------------------------------------------------------------
    // bookkeeping
    // ------------------------------------------------------------------
    integer errors   = 0;
    integer findings = 0;
    integer cyc      = 0;

    task check;
        input cond;
        input [8*72-1:0] msg;
        begin
            if (cond) $display("[PASS]    %0s", msg);
            else begin
                $display("[FAIL]    %0s", msg);
                errors = errors + 1;
            end
        end
    endtask

    task finding;
        input [8*72-1:0] msg;
        begin
            $display("[FINDING] %0s", msg);
            findings = findings + 1;
        end
    endtask

    // Expected GEMM byte j of tile t.
    function [7:0] exp_byte;
        input integer t;
        input integer j;
        begin
            exp_byte = (j * 7 + t * 29 + 3) % 256;
        end
    endfunction

    // ------------------------------------------------------------------
    // GEMM byte feeder. One byte per cycle; the packer only takes a byte
    // when let_square && panel_valid, so the byte index advances on accept.
    // tile_id and panel_sel follow the byte index (A panel = first 8 flits).
    // ------------------------------------------------------------------
    reg     feed_en = 1'b0;
    integer acc_cnt = 0;

    always @(negedge clk) begin
        if (feed_en && !rst && acc_cnt < N_TILES * 512) begin
            panel_valid <= 1'b1;
            panel_byte  <= exp_byte(acc_cnt / 512, acc_cnt % 512);
            tile_id     <= acc_cnt / 512;
            panel_sel   <= (((acc_cnt % 512) / 32) >= 8);
        end else begin
            panel_valid <= 1'b0;
            panel_byte  <= 8'd0;
        end
    end

    // other-stack injection helpers (call from the initial block only)
    task send_other;
        input [7:0]  tag;
        input [31:0] dl;
        begin
            @(negedge clk);
            other_valid    <= 1'b1;
            other_flit     <= {248'd0, tag};
            other_deadline <= dl;
        end
    endtask

    task idle_other;
        begin
            @(negedge clk);
            other_valid <= 1'b0;
        end
    endtask

    // ------------------------------------------------------------------
    // monitor (all state updated with blocking assignments at posedge, the
    // stimulus changes only at negedge, so there is no race)
    // ------------------------------------------------------------------
    integer t_first_acc  [0:15];
    integer t_last_flit  [0:15];
    integer gem_flit_cnt = 0;
    integer other_out_cnt = 0;
    integer out_cnt = 0;
    integer other_inj_cnt = 0;
    integer rec_fire_cnt = 0;
    integer pass_cnt = 0;
    integer fin_cnt = 0;
    integer byte_cnt = 0;
    integer byte_mism = 0;
    integer first_mism = -1;
    integer extra_bytes = 0;
    integer flit_mism = 0;
    integer min_credit = 255;
    integer max_credit = 0;
    integer last_pass_cyc = -1000;
    integer min_gap = 100000;
    integer max_occ = 0;
    integer max_distinct = 0;
    integer other_order [0:15];
    integer i, j, b, f, tl, distinct, seen;
    reg [255:0] w;

    initial begin
        for (i = 0; i < 16; i = i + 1) begin
            t_first_acc[i] = -1;
            t_last_flit[i] = -1;
            other_order[i] = -1;
        end
    end

    always @(posedge clk) begin
        if (rst) begin
            cyc = 0;
        end else begin
            cyc = cyc + 1;

            if (let_square && panel_valid) begin
                if ((acc_cnt % 512) == 0) t_first_acc[acc_cnt / 512] = cyc;
                acc_cnt = acc_cnt + 1;
            end

            if (dut.u_packer.rec_valid) rec_fire_cnt = rec_fire_cnt + 1;
            if (other_valid)            other_inj_cnt = other_inj_cnt + 1;

            if (pass_en) begin
                pass_cnt = pass_cnt + 1;
                if ((cyc - last_pass_cyc) < min_gap) min_gap = cyc - last_pass_cyc;
                last_pass_cyc = cyc;
            end
            if (square_finished) fin_cnt = fin_cnt + 1;

            if (credit_count < min_credit) min_credit = credit_count;
            if (credit_count > max_credit) max_credit = credit_count;

            // occupancy and number of distinct GEMM tiles waiting
            if (dut.u_ready.count_q > max_occ) max_occ = dut.u_ready.count_q;
            distinct = 0;
            for (i = 0; i < 4; i = i + 1) begin
                if (dut.u_ready.occ[i] && dut.u_ready.slot_q[i][334]) begin
                    seen = 0;
                    for (j = 0; j < i; j = j + 1)
                        if (dut.u_ready.occ[j] && dut.u_ready.slot_q[j][334] &&
                            dut.u_ready.slot_q[j][263:256] == dut.u_ready.slot_q[i][263:256])
                            seen = 1;
                    if (!seen) distinct = distinct + 1;
                end
            end
            if (distinct > max_distinct) max_distinct = distinct;

            // flit arriving on the compute-die side
            if (out_valid) begin
                out_cnt = out_cnt + 1;
                if (out_is_gemm) begin
                    tl = gem_flit_cnt / 16;
                    f  = gem_flit_cnt % 16;
                    for (b = 0; b < 32; b = b + 1)
                        w[255 - 8*b -: 8] = exp_byte(tl, f * 32 + b);
                    if (out_flit !== w || out_tile !== tl[7:0] ||
                        out_panel_sel !== (f >= 8))
                        flit_mism = flit_mism + 1;
                    if (f == 15) t_last_flit[tl] = cyc;
                    gem_flit_cnt = gem_flit_cnt + 1;
                end else begin
                    if (other_out_cnt < 16) other_order[other_out_cnt] = out_flit[7:0];
                    other_out_cnt = other_out_cnt + 1;
                end
            end

            // byte stream out of unpack
            if (byte_valid) begin
                if (byte_cnt < N_TILES * 512) begin
                    if (byte_out !== exp_byte(byte_cnt / 512, byte_cnt % 512)) begin
                        byte_mism = byte_mism + 1;
                        if (first_mism < 0) first_mism = byte_cnt;
                    end
                end else begin
                    extra_bytes = extra_bytes + 1;
                end
                byte_cnt = byte_cnt + 1;
            end
        end
    end

    // ------------------------------------------------------------------
    // reports
    // ------------------------------------------------------------------
    task report_common;
        begin
            $display("---- common ----");
            $display("config: SCEN=%0d POLICY=%0d K=%0d D_PHY=%0d N_TILES=%0d W_LEN=%0d ADMIT_LIMIT=%0d",
                     SCEN, POLICY, K, D_PHY, N_TILES, W_LEN, ADMIT_LIMIT);
            $display("flits packed=%0d other injected=%0d delivered=%0d (gemm %0d, other %0d)",
                     rec_fire_cnt, other_inj_cnt, out_cnt, gem_flit_cnt, other_out_cnt);
            $display("sends=%0d min_gap_between_sends=%0d credit min=%0d max=%0d max_slots_used=%0d",
                     pass_cnt, min_gap, min_credit, max_credit, max_occ);
            check(max_credit <= K, "credit_count never exceeds K");
            check(credit_count == K, "credit_count returns to K when idle");
            check(out_cnt <= rec_fire_cnt + other_inj_cnt, "no flit appears from nowhere");
            if (out_cnt < rec_fire_cnt + other_inj_cnt) begin
                $display("         dropped flits = %0d", rec_fire_cnt + other_inj_cnt - out_cnt);
                finding("ready_mem dropped flits silently (no backpressure to packer/other source)");
            end
        end
    endtask

    task report_gemm;
        integer tt, dl;
        begin
            $display("---- gemm data path ----");
            check(gem_flit_cnt == 16 * N_TILES, "16 GEMM flits per tile reach the compute die");
            check(flit_mism == 0,               "flit payload / tile / panel match expected");
            check(pass_cnt == 16 * N_TILES + (SCEN == 3 ? other_inj_cnt : 0),
                  "number of sends equals flits injected");
            check(fin_cnt == N_TILES,           "square_finished once per tile");
            check(done === 1'b1,                "done asserted");
            if (SCEN == 0) begin
                check(byte_cnt == N_TILES * 512, "unpack outputs exactly 512 bytes per tile");
                check(byte_mism == 0,            "byte stream equals byte stream fed in");
            end
            for (tt = 0; tt < N_TILES; tt = tt + 1) begin
                dl = 16 * tt + 40;
                $display("tile %0d: first_byte_at=%0d last_flit_arrives=%0d deadline D=%0d lateness=%0d",
                         tt, t_first_acc[tt], t_last_flit[tt], dl, t_last_flit[tt] - dl);
                if (t_last_flit[tt] > dl)
                    finding("tile misses D_k = 16k+40 (byte lane is 1 byte/cycle, see report)");
            end
            if (t_last_flit[0] > 0)
                $display("avg cycles per flit, tile 0 = %0d (model assumes 1)",
                         (t_last_flit[0] - t_first_acc[0]) / 16);
            $display("max distinct GEMM tiles waiting in ready_mem = %0d", max_distinct);
            if (max_distinct <= 1)
                finding("only one tile waits at a time: tie-break fields L/P/C never decide");
            if (min_credit >= 1 && K >= 2 * D_PHY + 1)
                finding("credit never reached 0: K is not 'shallow' relative to the credit RTT");
        end
    endtask

    task report_scen1;
        reg ok;
        begin
            $display("---- scheduler order (K=1) ----");
            $display("send order of tags: %0d %0d %0d %0d  (injected 0,1,2,3 with D = 500,100,300,200)",
                     other_order[0], other_order[1], other_order[2], other_order[3]);
            if (POLICY == 0)
                ok = (other_order[0]==0 && other_order[1]==1 && other_order[2]==2 && other_order[3]==3);
            else
                ok = (other_order[0]==0 && other_order[1]==1 && other_order[2]==3 && other_order[3]==2);
            check(ok, "send order matches the policy (FCFS = arrival, others = earliest D)");
            check(other_out_cnt == 4, "all four flits delivered");
            $display("measured gap between sends with K=1: %0d cycles (2*D_PHY = %0d)",
                     min_gap, 2 * D_PHY);
            check(min_gap >= 2 * D_PHY, "credit never returns earlier than 2*D_PHY");
            if (min_gap == 2 * D_PHY + 1)
                finding("effective credit RTT = 2*D_PHY + 1 (one extra register); K >= 9 needed for 1 flit/cycle");
        end
    endtask

    task report_scen2;
        begin
            $display("---- overflow (K=1, 8 flits back to back) ----");
            $display("injected %0d, delivered %0d", other_inj_cnt, other_out_cnt);
            if (other_out_cnt < other_inj_cnt)
                finding("flits lost when 4 slots are full; no backpressure signal exists");
            else
                $display("no loss observed");
        end
    endtask

    task report_scen3;
        begin
            $display("---- other flit during unpack (K=16) ----");
            $display("bytes out=%0d (expected %0d), mismatches=%0d, extra=%0d, first mismatch at byte %0d",
                     byte_cnt, N_TILES * 512, byte_mism, extra_bytes, first_mism);
            if (byte_mism != 0 || byte_cnt != N_TILES * 512)
                finding("unpack takes non-GEMM flits and overwrites the GEMM flit it is streaming");
            else
                $display("GEMM byte stream intact");
        end
    endtask

    task finish_all;
        begin
            report_common;
            if (SCEN == 0 || SCEN == 3) report_gemm;
            if (SCEN == 1) report_scen1;
            if (SCEN == 2) report_scen2;
            if (SCEN == 3) report_scen3;
            $display("SUMMARY: SCEN=%0d POLICY=%0d K=%0d errors=%0d findings=%0d",
                     SCEN, POLICY, K, errors, findings);
            $finish;
        end
    endtask

    // ------------------------------------------------------------------
    // stimulus
    // ------------------------------------------------------------------
    initial begin
        repeat (4) @(negedge clk);
        rst = 1'b0;

        case (SCEN)
            0: begin
                feed_en = 1'b1;
                wait (done === 1'b1);
                repeat (80) @(negedge clk);
            end
            1: begin
                send_other(8'd0, 32'd500);
                send_other(8'd1, 32'd100);
                send_other(8'd2, 32'd300);
                send_other(8'd3, 32'd200);
                idle_other;
                wait (other_out_cnt >= 4);
                repeat (30) @(negedge clk);
            end
            2: begin
                send_other(8'd0, 32'd100);
                send_other(8'd1, 32'd101);
                send_other(8'd2, 32'd102);
                send_other(8'd3, 32'd103);
                send_other(8'd4, 32'd104);
                send_other(8'd5, 32'd105);
                send_other(8'd6, 32'd106);
                send_other(8'd7, 32'd107);
                idle_other;
                repeat (150) @(negedge clk);
            end
            3: begin
                feed_en = 1'b1;
                @(posedge byte_valid);
                repeat (3) @(negedge clk);
                send_other(8'hA5, 32'hFFFFFFFF);
                idle_other;
                wait (done === 1'b1);
                repeat (100) @(negedge clk);
            end
            default: ;
        endcase
        finish_all;
    end

    initial begin
        #(MAXCYC * 10);
        $display("[FAIL]    timeout after %0d cycles (done=%0b, bytes out=%0d)", MAXCYC, done, byte_cnt);
        errors = errors + 1;
        finish_all;
    end
endmodule
