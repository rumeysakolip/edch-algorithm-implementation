// =============================================================================
// Modül   : tb_modular_alu_csa.sv
// Proje   : FPGA Tabanlı Güvenli Anahtar Yönetimi ve Kripto Hızlandırıcı
// No      : 5260007 — Sakarya Uygulamalı Bilimler Üniversitesi
// -----------------------------------------------------------------------------
// Açıklama:
//   Carry-Save (CSA) Montgomery çekirdeği modular_alu için öz-kontrollü birim
//   testbench. DUT çıkışları, SystemVerilog yerel 256/512-bit tamsayı
//   aritmetiğiyle kurulan bağımsız bir altın-referansla (modmul/modpow tabanlı
//   Montgomery) karşılaştırılır. Bilinen vektörlerin yanı sıra çok sayıda
//   RASTGELE 256-bit operand ile MM sonucu doğrulanır; ayrıca ModAdd/ModSub
//   ve mod_p=0 hata yolu sınanır.
//
//   Amaç: CSA yeniden yapılandırmasının radix-2 ile bit-birebir aynı
//   MM(A,B) = A·B·R^(-1) mod P sonucunu ürettiğini kanıtlamak.
//
// PAKETİ PROTOKOLÜ: 256-bit = 8 × 32-bit, LSB-önce
// ÇALIŞTIRMA (Vivado): run 300us
// Standart : SystemVerilog-2012
// =============================================================================

`timescale 1ns / 1ps

module tb_modular_alu_csa;

localparam [255:0] P256 =
    256'hffffffff00000001000000000000000000000000ffffffffffffffffffffffff;
localparam [255:0] R_MOD_P =
    256'h00000000fffffffeffffffffffffffffffffffff000000000000000000000001;
localparam [255:0] R2_MOD_P =
    256'h00000004fffffffdfffffffffffffffefffffffbffffffff0000000000000003;
localparam [255:0] GX_MONT =
    256'h18905f76a53755c679fb732b7762251075ba95fc5fedb60179e730d418a9143c;
localparam [255:0] GY_MONT =
    256'h8571ff1825885d85d2e88688dd21f3258b4ab8e4ba19e45cddf25357ce95560a;

localparam integer CLK_NS  = 10;
localparam integer TIMEOUT = 2000;   // CSA MM ~265 çevrim
localparam integer ERR_TO  = 40;
localparam integer N_RAND  = 40;     // rastgele MM test sayısı

logic        clk_in, rst_n;
logic [31:0] i_pkt_in;
logic        i_pkt_vld;
logic [1:0]  i_pkt_sel;
logic [1:0]  i_opcode;
logic        i_start;
logic [31:0] o_pkt_out;
logic        o_pkt_vld, o_pkt_last, o_rdy, o_done, o_err;

int toplam_test, basarili_test;

modular_alu dut (
    .clk_in(clk_in), .rst_n(rst_n),
    .i_pkt_in(i_pkt_in), .i_pkt_vld(i_pkt_vld), .i_pkt_sel(i_pkt_sel),
    .i_opcode(i_opcode), .i_start(i_start),
    .o_pkt_out(o_pkt_out), .o_pkt_vld(o_pkt_vld), .o_pkt_last(o_pkt_last),
    .o_rdy(o_rdy), .o_done(o_done), .o_err(o_err)
);

initial clk_in = 1'b0;
always #(CLK_NS/2) clk_in = ~clk_in;

// ── Altın referans ─────────────────────────────────────────────────────
function automatic [255:0] modmul(input [255:0] a, input [255:0] b, input [255:0] p);
    logic [511:0] t; begin t = {256'd0, a} * {256'd0, b}; modmul = t % {256'd0, p}; end
endfunction
function automatic [255:0] modpow(input [255:0] base, input [255:0] e, input [255:0] p);
    logic [255:0] r, b; integer i;
    begin r = 256'd1; b = base % p;
        for (i = 255; i >= 0; i = i - 1) begin r = modmul(r, r, p); if (e[i]) r = modmul(r, b, p); end
        modpow = r; end
endfunction
// MM(a,b) = a·b·R^(-1) mod P
function automatic [255:0] ref_mm(input [255:0] a, input [255:0] b);
    logic [255:0] rinv;
    begin rinv = modpow(R_MOD_P, P256 - 256'd2, P256);
          ref_mm = modmul(modmul(a, b, P256), rinv, P256); end
endfunction

function automatic [255:0] rand256();
    logic [255:0] v; integer k;
    begin for (k = 0; k < 8; k = k + 1) v[k*32 +: 32] = $urandom; rand256 = v % P256; end
endfunction

// ── Görevler ───────────────────────────────────────────────────────────
task automatic send256(input [255:0] deger, input [1:0] sel);
    integer k; begin
        for (k = 0; k < 8; k = k + 1) begin
            @(posedge clk_in); #1; i_pkt_in=deger[k*32 +: 32]; i_pkt_vld=1'b1; i_pkt_sel=sel; end
        @(posedge clk_in); #1; i_pkt_vld=1'b0;
    end
endtask

task automatic recv256(output logic [255:0] sonuc);
    integer k, bekle; begin
        sonuc=256'd0; bekle=0;
        @(posedge clk_in);
        while (!o_pkt_vld && bekle<TIMEOUT) begin @(posedge clk_in); bekle++; end
        if (bekle>=TIMEOUT) begin $display("  [HATA] recv256 zaman asimi!"); disable recv256; end
        for (k=0;k<8;k=k+1) begin
            while (!o_pkt_vld) @(posedge clk_in);
            sonuc[k*32 +: 32]=o_pkt_out;
            if (k<7) @(posedge clk_in);
        end
    end
endtask

task automatic islem(input [1:0] opc, input [255:0] a, input [255:0] b,
                     input [255:0] beklenen, input string ad, input bit sessiz=0);
    logic [255:0] sonuc; begin
        send256(a, 2'b00); send256(b, 2'b01);
        @(posedge clk_in); #1; i_opcode=opc; i_start=1'b1;
        @(posedge clk_in); #1; i_start=1'b0;
        recv256(sonuc);
        toplam_test++;
        if (sonuc === beklenen) begin basarili_test++;
            if (!sessiz) begin $display("  [PASS] %s", ad); $display("         0x%064x", sonuc); end
        end else begin
            $display("  [FAIL] %s", ad);
            $display("         Gelen   : 0x%064x", sonuc);
            $display("         Beklenen: 0x%064x", beklenen);
        end
        repeat(2) @(posedge clk_in);
    end
endtask

// ── Ana test akışı ──────────────────────────────────────────────────────
initial begin
    logic [255:0] a, b;
    integer i;
    toplam_test=0; basarili_test=0;
    rst_n=1'b0; i_pkt_in=32'd0; i_pkt_vld=1'b0; i_pkt_sel=2'd0; i_opcode=2'd0; i_start=1'b0;
    repeat(5) @(posedge clk_in); rst_n=1'b1; repeat(3) @(posedge clk_in);

    $display("\n============================================================");
    $display("  modular_alu BIRIM TESTBENCH (Carry-Save Montgomery)");
    $display("============================================================");

    send256(P256, 2'b10);   // mod_p yükle (kalıcı)

    // ── MontMult bilinen vektörler ────────────────────────────────────
    $display("\n[INFO] MontMult (CSA) bilinen vektorler...");
    islem(2'b10, R_MOD_P,  256'd1,  256'd1,          "MM(R_mod_P, 1) = 1");
    islem(2'b10, R2_MOD_P, 256'd1,  R_MOD_P,         "MM(R2_mod_P, 1) = R_mod_P");
    islem(2'b10, GX_MONT,  GY_MONT, ref_mm(GX_MONT,GY_MONT), "MM(Gx, Gy)");
    islem(2'b10, GX_MONT,  GX_MONT, ref_mm(GX_MONT,GX_MONT), "MM(Gx, Gx)");
    islem(2'b10, R_MOD_P,  R_MOD_P, ref_mm(R_MOD_P,R_MOD_P), "MM(R_mod_P, R_mod_P)");

    // ── MontMult rastgele vektörler ───────────────────────────────────
    $display("\n[INFO] MontMult (CSA) %0d rastgele vektor...", N_RAND);
    for (i=0;i<N_RAND;i=i+1) begin
        a=rand256(); b=rand256();
        islem(2'b10, a, b, ref_mm(a,b), $sformatf("rastgele MM #%0d", i), 1'b1);
    end
    $display("  [BILGI] Rastgele MM: %0d / %0d gecti (o ana kadar)", basarili_test, toplam_test);

    // ── ModAdd / ModSub ───────────────────────────────────────────────
    $display("\n[INFO] ModAdd / ModSub...");
    islem(2'b00, 256'd3,        256'd5, 256'd8,        "ModAdd 3+5 = 8");
    islem(2'b01, 256'd2,        256'd5, P256 - 256'd3, "ModSub 2-5 = P-3");
    islem(2'b00, P256 - 256'd1, 256'd1, 256'd0,        "ModAdd (P-1)+1 = 0");

    // ── Hata: mod_p=0 ─────────────────────────────────────────────────
    $display("\n[INFO] Hata testi: mod_p=0...");
    send256(256'd0, 2'b10);
    send256(256'd3, 2'b00); send256(256'd5, 2'b01);
    @(posedge clk_in); #1; i_opcode=2'b10; i_start=1'b1;
    @(posedge clk_in); #1; i_start=1'b0;
    begin
        int bekle; bekle=0; @(posedge clk_in);
        while (!o_err && bekle<ERR_TO) begin @(posedge clk_in); bekle++; end
        toplam_test++;
        if (bekle<ERR_TO) begin basarili_test++; $display("  [PASS] mod_p=0 -> o_err (%0d cevrim)", bekle); end
        else $display("  [FAIL] mod_p=0 -> o_err beklendi ama gelmedi!");
    end
    send256(P256, 2'b10);

    $display("\n============================================================");
    $display("  GENEL SONUC: %0d / %0d test basarili", basarili_test, toplam_test);
    if (basarili_test==toplam_test) $display("  >>> TUM TESTLER GECTI <<<  [PASS]");
    else $display("  !!! %0d TEST HATALI !!!    [FAIL]", toplam_test-basarili_test);
    $display("============================================================\n");
    $finish;
end

initial begin repeat(TIMEOUT*(N_RAND+20)) @(posedge clk_in);
    $fatal(1,"[HATA] Mutlak zaman asimi — modular_alu (CSA) yanit vermiyor!"); end
initial begin $dumpfile("tb_modular_alu_csa.vcd"); $dumpvars(0, tb_modular_alu_csa); end

endmodule
