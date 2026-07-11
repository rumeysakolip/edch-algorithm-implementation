// =============================================================================
// Modül   : tb_point_arithmetic_unit.sv
// Proje   : FPGA Tabanlı Güvenli Anahtar Yönetimi ve Kripto Hızlandırıcı
// No      : 5260007 — Sakarya Uygulamalı Bilimler Üniversitesi
// -----------------------------------------------------------------------------
// Açıklama:
//   BRAM-optimize point_arithmetic_unit için öz-kontrollü birim testbench.
//   DUT'un Jacobian (Montgomery) çıkışı SV içinde Affin'e çevrilip, bağımsız
//   bir SV eliptik eğri altın-referansıyla (normal alan DBL/ADD) karşılaştırılır.
//   Böylece BRAM scratchpad yeniden yapılandırmasının fonksiyonel doğruluğu
//   (V-Modeli imza kapısı) doğrulanır.
//
//   Testler:
//     T1: DBL sonsuzluk (Z=0) → çıkış Z=0
//     T2: ADD(∞,G) → G   |   T3: ADD(G,∞) → G
//     T4: DBL(G) → 2G (Affin karşılaştırma)
//     T5: ADD(G, 2G) → 3G (Affin karşılaştırma)
//
// ÇALIŞTIRMA (Vivado): run 500us
// Standart : SystemVerilog-2012
// =============================================================================

`timescale 1ns / 1ps

module tb_point_arithmetic_unit;

localparam [255:0] P256    = 256'hffffffff00000001000000000000000000000000ffffffffffffffffffffffff;
localparam [255:0] R_MOD_P = 256'h00000000fffffffeffffffffffffffffffffffff000000000000000000000001;
localparam [255:0] GX_MONT = 256'h18905f76a53755c679fb732b7762251075ba95fc5fedb60179e730d418a9143c;
localparam [255:0] GY_MONT = 256'h8571ff1825885d85d2e88688dd21f3258b4ab8e4ba19e45cddf25357ce95560a;

localparam [2:0] PIX_MODP=3'd0, PIX_P1X=3'd1, PIX_P1Y=3'd2, PIX_P1Z=3'd3,
                 PIX_P2X=3'd4, PIX_P2Y=3'd5, PIX_P2Z=3'd6;
localparam integer CLK_NS=10, TIMEOUT=200000;

logic        clk_in, rst_n;
logic [31:0] i_pkt_in; logic i_pkt_vld; logic [2:0] i_pkt_sel;
logic        i_cmd, i_start;
logic [31:0] o_pkt_out; logic o_pkt_vld; logic [1:0] o_pkt_sel;
logic        o_pkt_last, o_rdy, o_done, o_err;
logic [255:0] rx_x, rx_y, rx_z;
int toplam_test, basarili_test;

// PAU artık MALU'yu dışarıdan alır → testbench bir modular_alu bağlar
wire [31:0] pm_dat; wire pm_vld; wire [1:0] pm_sel, pm_opc; wire pm_st;
wire [31:0] pm_out; wire pm_ovld, pm_last, pm_rdy, pm_done, pm_err;

point_arithmetic_unit dut (
    .clk_in(clk_in), .rst_n(rst_n), .i_pkt_in(i_pkt_in), .i_pkt_vld(i_pkt_vld),
    .i_pkt_sel(i_pkt_sel), .i_cmd(i_cmd), .i_start(i_start),
    .o_pkt_out(o_pkt_out), .o_pkt_vld(o_pkt_vld), .o_pkt_sel(o_pkt_sel),
    .o_pkt_last(o_pkt_last), .o_rdy(o_rdy), .o_done(o_done), .o_err(o_err),
    .mo_pkt_dat(pm_dat), .mo_pkt_vld(pm_vld), .mo_pkt_sel(pm_sel), .mo_opc(pm_opc), .mo_st(pm_st),
    .mi_pkt_out(pm_out), .mi_pkt_vld(pm_ovld), .mi_pkt_last(pm_last),
    .mi_rdy(pm_rdy), .mi_done(pm_done), .mi_err(pm_err)
);

modular_alu tb_malu (
    .clk_in(clk_in), .rst_n(rst_n),
    .i_pkt_in(pm_dat), .i_pkt_vld(pm_vld), .i_pkt_sel(pm_sel), .i_opcode(pm_opc), .i_start(pm_st),
    .o_pkt_out(pm_out), .o_pkt_vld(pm_ovld), .o_pkt_last(pm_last),
    .o_rdy(pm_rdy), .o_done(pm_done), .o_err(pm_err)
);

initial clk_in=1'b0; always #(CLK_NS/2) clk_in=~clk_in;

// ── Altın referans (normal alan) ───────────────────────────────────────
function automatic [255:0] modmul(input [255:0] a,b,p);
    logic [511:0] t; begin t={256'd0,a}*{256'd0,b}; modmul=t%{256'd0,p}; end
endfunction
function automatic [255:0] modadd(input [255:0] a,b,p);
    logic [257:0] t; begin t={2'd0,a}+{2'd0,b}; if (t>={2'd0,p}) t=t-{2'd0,p}; modadd=t[255:0]; end
endfunction
function automatic [255:0] modsub(input [255:0] a,b,p);
    logic [257:0] t; begin t=({2'd0,a}+{2'd0,p})-{2'd0,b}; t=t%{2'd0,p}; modsub=t[255:0]; end
endfunction
function automatic [255:0] modpow(input [255:0] base,e,p);
    logic [255:0] r,b; integer i;
    begin r=256'd1; b=base%p;
        for (i=255;i>=0;i=i-1) begin r=modmul(r,r,p); if (e[i]) r=modmul(r,b,p); end
        modpow=r; end
endfunction
function automatic [255:0] modinv(input [255:0] a,p); begin modinv=modpow(a,p-256'd2,p); end endfunction
function automatic [255:0] from_mont(input [255:0] am);
    begin from_mont=modmul(am, modinv(R_MOD_P,P256), P256); end
endfunction

// EC double (a=-3): {x3,y3}
function automatic [511:0] ec_double(input [255:0] x1,y1);
    logic [255:0] a_c, lam, num, den, x3, y3;
    begin
        a_c=modsub(256'd0,256'd3,P256);                     // a = -3
        num=modadd(modmul(256'd3,modmul(x1,x1,P256),P256), a_c, P256);
        den=modadd(y1,y1,P256);
        lam=modmul(num, modinv(den,P256), P256);
        x3=modsub(modsub(modmul(lam,lam,P256),x1,P256),x1,P256);
        y3=modsub(modmul(lam,modsub(x1,x3,P256),P256), y1, P256);
        ec_double={x3,y3};
    end
endfunction

// EC add (distinct): {x3,y3}
function automatic [511:0] ec_add(input [255:0] x1,y1,x2,y2);
    logic [255:0] lam,x3,y3;
    begin
        lam=modmul(modsub(y2,y1,P256), modinv(modsub(x2,x1,P256),P256), P256);
        x3=modsub(modsub(modmul(lam,lam,P256),x1,P256),x2,P256);
        y3=modsub(modmul(lam,modsub(x1,x3,P256),P256), y1, P256);
        ec_add={x3,y3};
    end
endfunction

// DUT Jacobian (Montgomery) → normal Affin
task automatic jac_to_affine(input [255:0] xm,ym,zm, output [255:0] xa, output [255:0] ya);
    logic [255:0] x,y,z,zinv,zinv2,zinv3;
    begin
        x=from_mont(xm); y=from_mont(ym); z=from_mont(zm);
        zinv=modinv(z,P256); zinv2=modmul(zinv,zinv,P256); zinv3=modmul(zinv2,zinv,P256);
        xa=modmul(x,zinv2,P256); ya=modmul(y,zinv3,P256);
    end
endtask

// ── Görevler ───────────────────────────────────────────────────────────
task automatic send256(input [255:0] deger, input [2:0] sel);
    integer k; begin
        for (k=0;k<8;k=k+1) begin @(posedge clk_in); #1; i_pkt_in=deger[k*32 +: 32]; i_pkt_vld=1'b1; i_pkt_sel=sel; end
        @(posedge clk_in); #1; i_pkt_vld=1'b0;
    end
endtask

task automatic recv_xyz(output logic [255:0] xx, output logic [255:0] yy, output logic [255:0] zz);
    integer k, bekle; begin
        xx=0; yy=0; zz=0; bekle=0;
        @(posedge clk_in);
        while (!(o_pkt_vld && o_pkt_sel==2'b00) && bekle<TIMEOUT) begin @(posedge clk_in); bekle++; end
        if (bekle>=TIMEOUT) begin $display("  [HATA] recv zaman asimi!"); disable recv_xyz; end
        for (k=0;k<8;k=k+1) begin while (!(o_pkt_vld && o_pkt_sel==2'b00)) @(posedge clk_in); xx[k*32 +: 32]=o_pkt_out; if (k<7) @(posedge clk_in); end
        for (k=0;k<8;k=k+1) begin while (!(o_pkt_vld && o_pkt_sel==2'b01)) @(posedge clk_in); yy[k*32 +: 32]=o_pkt_out; if (k<7) @(posedge clk_in); end
        for (k=0;k<8;k=k+1) begin while (!(o_pkt_vld && o_pkt_sel==2'b10)) @(posedge clk_in); zz[k*32 +: 32]=o_pkt_out; if (k<7) @(posedge clk_in); end
    end
endtask

task automatic dbl(input [255:0] x,y,z);
    begin
        send256(P256,PIX_MODP); send256(x,PIX_P1X); send256(y,PIX_P1Y); send256(z,PIX_P1Z);
        @(posedge clk_in); #1; i_cmd=1'b0; i_start=1'b1; @(posedge clk_in); #1; i_start=1'b0;
        recv_xyz(rx_x,rx_y,rx_z); repeat(4) @(posedge clk_in);
    end
endtask

task automatic add_pt(input [255:0] x1,y1,z1,x2,y2,z2);
    begin
        send256(P256,PIX_MODP);
        send256(x1,PIX_P1X); send256(y1,PIX_P1Y); send256(z1,PIX_P1Z);
        send256(x2,PIX_P2X); send256(y2,PIX_P2Y); send256(z2,PIX_P2Z);
        @(posedge clk_in); #1; i_cmd=1'b1; i_start=1'b1; @(posedge clk_in); #1; i_start=1'b0;
        recv_xyz(rx_x,rx_y,rx_z); repeat(4) @(posedge clk_in);
    end
endtask

task automatic karsilastir_affine(input [255:0] beklx, input [255:0] bekly, input string ad);
    logic [255:0] ax, ay;
    begin
        toplam_test++;
        if (rx_z==256'd0) begin $display("  [FAIL] %s — sonuc sonsuzluk (Z=0)!", ad); return; end
        jac_to_affine(rx_x, rx_y, rx_z, ax, ay);
        if (ax===beklx && ay===bekly) begin
            basarili_test++; $display("  [PASS] %s", ad);
            $display("         x=0x%064x", ax);
        end else begin
            $display("  [FAIL] %s", ad);
            $display("         x DUT=0x%064x  REF=0x%064x", ax, beklx);
            $display("         y DUT=0x%064x  REF=0x%064x", ay, bekly);
        end
    end
endtask

// ── Ana akış ────────────────────────────────────────────────────────────
initial begin
    logic [255:0] gx, gy, g2x, g2y, g3x, g3y;
    logic [511:0] tmp;
    logic [255:0] g2xm, g2ym;
    toplam_test=0; basarili_test=0;
    rst_n=1'b0; i_pkt_in=0; i_pkt_vld=0; i_pkt_sel=0; i_cmd=0; i_start=0;
    repeat(5) @(posedge clk_in); rst_n=1'b1; repeat(3) @(posedge clk_in);

    $display("\n============================================================");
    $display("  point_arithmetic_unit BIRIM TESTBENCH (BRAM scratchpad)");
    $display("============================================================");

    // Referans: G, 2G, 3G (normal Affin)
    gx=from_mont(GX_MONT); gy=from_mont(GY_MONT);
    tmp=ec_double(gx,gy); g2x=tmp[511:256]; g2y=tmp[255:0];
    tmp=ec_add(gx,gy,g2x,g2y); g3x=tmp[511:256]; g3y=tmp[255:0];
    // 2G'yi Montgomery Affin'e çevir (P2 girişi için, Z=Mont1)
    g2xm=modmul(g2x,R_MOD_P,P256); g2ym=modmul(g2y,R_MOD_P,P256);

    // T1: DBL sonsuzluk
    $display("\n[INFO] T1: DBL(inf) → inf (Z=0)");
    dbl(GX_MONT, GY_MONT, 256'd0);
    toplam_test++;
    if (rx_z===256'd0) begin basarili_test++; $display("  [PASS] T1 DBL sonsuzluk (Z=0)"); end
    else $display("  [FAIL] T1 — Z!=0");

    // T2: ADD(inf, G)
    $display("\n[INFO] T2: ADD(inf, G) → G");
    add_pt(GX_MONT,GY_MONT,256'd0, GX_MONT,GY_MONT,R_MOD_P);
    karsilastir_affine(gx, gy, "T2 ADD(inf,G)=G");

    // T3: ADD(G, inf)
    $display("\n[INFO] T3: ADD(G, inf) → G");
    add_pt(GX_MONT,GY_MONT,R_MOD_P, GX_MONT,GY_MONT,256'd0);
    karsilastir_affine(gx, gy, "T3 ADD(G,inf)=G");

    // T4: DBL(G) → 2G
    $display("\n[INFO] T4: DBL(G) → 2G");
    dbl(GX_MONT, GY_MONT, R_MOD_P);
    karsilastir_affine(g2x, g2y, "T4 DBL(G)=2G");

    // T5: ADD(G, 2G) → 3G
    $display("\n[INFO] T5: ADD(G, 2G) → 3G");
    add_pt(GX_MONT,GY_MONT,R_MOD_P, g2xm,g2ym,R_MOD_P);
    karsilastir_affine(g3x, g3y, "T5 ADD(G,2G)=3G");

    $display("\n============================================================");
    $display("  GENEL SONUC: %0d / %0d test basarili", basarili_test, toplam_test);
    if (basarili_test==toplam_test) $display("  >>> TUM TESTLER GECTI <<<  [PASS]");
    else $display("  !!! %0d TEST HATALI !!!    [FAIL]", toplam_test-basarili_test);
    $display("============================================================\n");
    $finish;
end

initial begin repeat(TIMEOUT*30) @(posedge clk_in); $fatal(1,"[HATA] Mutlak zaman asimi!"); end
initial begin $dumpfile("tb_point_arithmetic_unit.vcd"); $dumpvars(0, tb_point_arithmetic_unit); end

endmodule
