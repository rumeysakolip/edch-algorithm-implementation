// =============================================================================
// Modül   : tb_affine_donusum.sv
// Proje   : FPGA Tabanlı Güvenli Anahtar Yönetimi ve Kripto Hızlandırıcı
// No      : 5260007 — Sakarya Uygulamalı Bilimler Üniversitesi
// -----------------------------------------------------------------------------
// Açıklama:
//   affine_donusum (Jacobian → Affin, Fermat/FLT tabanlı) biriminin ayrıntılı
//   birim doğrulama testbench'i. Beyaz-kutu (white-box) yaklaşımıyla, tasarımın
//   Montgomery alanındaki tersleme (Z^(p-2)) ve son çarpım zincirini bağımsız
//   bir SystemVerilog altın-referans (golden reference) modeliyle karşılaştırır.
//
//   ÖZ-KONTROLLÜ REFERANS:
//     SystemVerilog yerel 256/512-bit tamsayı aritmetiği kullanılarak modüler
//     çarpma (modmul) ve modüler üs alma (modpow) fonksiyonları tanımlanmıştır.
//     Bu sayede KEYFİ Z değerleri için beklenen Affin çıktısı harici bir vektör
//     dosyasına ihtiyaç duyulmadan hesaplanır ve DUT çıktısıyla kıyaslanır.
//
//   TEST SENARYOLARI:
//     T1: Z = Montgomery(1) (R mod p), (X,Y)=G  → Affin çıkış = G          [özdeşlik]
//     T2: Z = keyfi (Gx_mont), (X,Y) çapraz     → non-trivial tersleme     [FLT]
//     T3: Z = keyfi (Gy_mont)                    → ikinci non-trivial vaka
//     T4: Z = 0 → o_err beklenir                  [sonsuzluk koruması]
//     T5: mod_p = 0 → o_err beklenir              [geçersiz alan]
//
// PAKETİ PROTOKOLÜ: 256-bit = 8 × 32-bit, LSB-önce (paket-0 = bits[31:0])
// ÇALIŞTIRMA (Vivado): run 6ms
// Standart : SystemVerilog-2012
// =============================================================================

`timescale 1ns / 1ps

module tb_affine_donusum;

// =====================================================================
// NIST P-256 (secp256r1) Sabitleri
// =====================================================================
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

// =====================================================================
// Seçici Sabitleri (affine_donusum AIX_*)
// =====================================================================
localparam [2:0] AIX_MODP = 3'd0;
localparam [2:0] AIX_X    = 3'd1;
localparam [2:0] AIX_Y    = 3'd2;
localparam [2:0] AIX_Z    = 3'd3;

localparam integer CLK_NS      = 10;
localparam integer AFF_TIMEOUT = 400_000;  // Fermat dönüşümü için maks çevrim
localparam integer ERR_TIMEOUT = 400;

// =====================================================================
// DUT Sinyalleri
// =====================================================================
logic        clk_in, rst_n;
logic [31:0] i_pkt_in;
logic        i_pkt_vld;
logic [2:0]  i_pkt_sel;
logic        i_start;
logic [31:0] o_pkt_out;
logic        o_pkt_vld;
logic [1:0]  o_pkt_sel;
logic        o_pkt_last;
logic        o_rdy, o_done, o_err;

logic [255:0] rx_xa, rx_ya;
int toplam_test, basarili_test;

// =====================================================================
// DUT
// =====================================================================
// affine artık MALU'yu dışarıdan alır → testbench bir modular_alu bağlar
wire [31:0] am_dat; wire am_vld; wire [1:0] am_sel, am_opc; wire am_st;
wire [31:0] am_out; wire am_ovld, am_last, am_rdy, am_done, am_err;

affine_donusum dut (
    .clk_in(clk_in), .rst_n(rst_n),
    .i_pkt_in(i_pkt_in), .i_pkt_vld(i_pkt_vld), .i_pkt_sel(i_pkt_sel),
    .i_start(i_start),
    .o_pkt_out(o_pkt_out), .o_pkt_vld(o_pkt_vld), .o_pkt_sel(o_pkt_sel),
    .o_pkt_last(o_pkt_last), .o_rdy(o_rdy), .o_done(o_done), .o_err(o_err),
    .mo_pkt_dat(am_dat), .mo_pkt_vld(am_vld), .mo_pkt_sel(am_sel), .mo_opc(am_opc), .mo_st(am_st),
    .mi_pkt_out(am_out), .mi_pkt_vld(am_ovld), .mi_pkt_last(am_last),
    .mi_rdy(am_rdy), .mi_done(am_done), .mi_err(am_err)
);

modular_alu tb_malu (
    .clk_in(clk_in), .rst_n(rst_n),
    .i_pkt_in(am_dat), .i_pkt_vld(am_vld), .i_pkt_sel(am_sel), .i_opcode(am_opc), .i_start(am_st),
    .o_pkt_out(am_out), .o_pkt_vld(am_ovld), .o_pkt_last(am_last),
    .o_rdy(am_rdy), .o_done(am_done), .o_err(am_err)
);

// =====================================================================
// Saat Üreteci — 100 MHz
// =====================================================================
initial clk_in = 1'b0;
always #(CLK_NS/2) clk_in = ~clk_in;

// =====================================================================
// ALTIN REFERANS — SystemVerilog yerel büyük tamsayı aritmetiği
// =====================================================================
// Modüler çarpma: (a·b) mod p  — 512-bit ara sonuç ile tam kesinlik
function automatic [255:0] modmul(input [255:0] a, input [255:0] b, input [255:0] p);
    logic [511:0] t;
    begin
        t = {256'd0, a} * {256'd0, b};   // Operandlar 512-bit'e genişletilir
        modmul = t % {256'd0, p};
    end
endfunction

// Modüler üs alma: base^e mod p  (soldan-sağa kare-al-ve-çarp)
function automatic [255:0] modpow(input [255:0] base, input [255:0] e, input [255:0] p);
    logic [255:0] r;
    logic [255:0] b;
    integer i;
    begin
        r = 256'd1;
        b = base % p;
        for (i = 255; i >= 0; i = i - 1) begin
            r = modmul(r, r, p);
            if (e[i]) r = modmul(r, b, p);
        end
        modpow = r;
    end
endfunction

// Montgomery alan yardımcıları
function automatic [255:0] from_mont(input [255:0] a_m, input [255:0] p);
    logic [255:0] rinv;
    begin
        // R^(-1) mod p = (R mod p)^(p-2) mod p ;  from_mont(a) = a·R^(-1) mod p
        rinv = modpow(R_MOD_P, p - 256'd2, p);
        from_mont = modmul(a_m, rinv, p);
    end
endfunction

function automatic [255:0] to_mont(input [255:0] a, input [255:0] p);
    begin
        to_mont = modmul(a, R_MOD_P, p);   // a·R mod p
    end
endfunction

// Beklenen Affin (Montgomery) koordinatları — Jacobian Montgomery girişten
task automatic ref_affine(input [255:0] xm, input [255:0] ym, input [255:0] zm,
                          output [255:0] exa, output [255:0] eya);
    logic [255:0] x, y, z, zinv, zinv2, zinv3, xa, ya;
    begin
        x = from_mont(xm, P256);
        y = from_mont(ym, P256);
        z = from_mont(zm, P256);
        zinv  = modpow(z, P256 - 256'd2, P256);
        zinv2 = modmul(zinv, zinv, P256);
        zinv3 = modmul(zinv2, zinv, P256);
        xa = modmul(x, zinv2, P256);
        ya = modmul(y, zinv3, P256);
        exa = to_mont(xa, P256);
        eya = to_mont(ya, P256);
    end
endtask

// =====================================================================
// GÖREV: 256-bit değeri 8 × 32-bit paket olarak DUT'a gönder
// =====================================================================
task automatic send256(input [255:0] deger, input [2:0] sel);
    integer k;
    begin
        for (k = 0; k < 8; k = k + 1) begin
            @(posedge clk_in); #1;
            i_pkt_in  = deger[k*32 +: 32];
            i_pkt_vld = 1'b1;
            i_pkt_sel = sel;
        end
        @(posedge clk_in); #1;
        i_pkt_vld = 1'b0;
    end
endtask

// =====================================================================
// GÖREV: Affin sonucu (x_a: sel=00, y_a: sel=01) topla
// =====================================================================
task automatic recv_affine(output logic [255:0] xa, output logic [255:0] ya);
    integer k, bekle;
    begin
        xa = 256'd0; ya = 256'd0;
        // x_a ilk paketine kadar bekle
        bekle = 0;
        @(posedge clk_in);
        while (!(o_pkt_vld && o_pkt_sel == 2'b00) && bekle < AFF_TIMEOUT) begin
            @(posedge clk_in); bekle++;
        end
        if (bekle >= AFF_TIMEOUT) begin
            $display("  [HATA] recv_affine: x_a zaman asimi!");
            disable recv_affine;
        end
        // x_a — 8 paket ardışık
        for (k = 0; k < 8; k = k + 1) begin
            while (!(o_pkt_vld && o_pkt_sel == 2'b00)) @(posedge clk_in);
            xa[k*32 +: 32] = o_pkt_out;
            if (k < 7) @(posedge clk_in);
        end
        // y_a — 8 paket ardışık
        for (k = 0; k < 8; k = k + 1) begin
            while (!(o_pkt_vld && o_pkt_sel == 2'b01)) @(posedge clk_in);
            ya[k*32 +: 32] = o_pkt_out;
            if (k < 7) @(posedge clk_in);
        end
    end
endtask

// =====================================================================
// GÖREV: Tam Jacobian→Affin dönüşüm testi (öz-kontrollü)
// =====================================================================
task automatic test_donusum(input [255:0] xm, input [255:0] ym, input [255:0] zm,
                            input string ad);
    logic [255:0] exa, eya;
    begin
        $display("\n[INFO] %s — mod_p, X, Y, Z yukleniyor...", ad);
        send256(P256, AIX_MODP);
        send256(xm,   AIX_X);
        send256(ym,   AIX_Y);
        send256(zm,   AIX_Z);
        @(posedge clk_in); #1; i_start = 1'b1;
        @(posedge clk_in); #1; i_start = 1'b0;

        ref_affine(xm, ym, zm, exa, eya);
        recv_affine(rx_xa, rx_ya);

        toplam_test++;
        if (rx_xa === exa && rx_ya === eya) begin
            basarili_test++;
            $display("  [PASS] %s", ad);
            $display("         x_a = 0x%064x", rx_xa);
            $display("         y_a = 0x%064x", rx_ya);
        end else begin
            $display("  [FAIL] %s", ad);
            $display("         x_a DUT: 0x%064x", rx_xa);
            $display("         x_a REF: 0x%064x", exa);
            $display("         y_a DUT: 0x%064x", rx_ya);
            $display("         y_a REF: 0x%064x", eya);
        end
        repeat(4) @(posedge clk_in);
    end
endtask

// =====================================================================
// GÖREV: o_err beklenen hata testi
// =====================================================================
task automatic test_hata(input [255:0] modp, input [255:0] xm,
                         input [255:0] ym, input [255:0] zm, input string ad);
    integer bekle;
    begin
        $display("\n[INFO] %s — hata bekleniyor...", ad);
        send256(modp, AIX_MODP);
        send256(xm,   AIX_X);
        send256(ym,   AIX_Y);
        send256(zm,   AIX_Z);
        @(posedge clk_in); #1; i_start = 1'b1;
        @(posedge clk_in); #1; i_start = 1'b0;
        bekle = 0;
        @(posedge clk_in);
        while (!o_err && bekle < ERR_TIMEOUT) begin @(posedge clk_in); bekle++; end
        toplam_test++;
        if (bekle < ERR_TIMEOUT) begin
            basarili_test++;
            $display("  [PASS] %s — o_err=1 alindi (%0d cevrim)", ad, bekle);
        end else begin
            $display("  [FAIL] %s — o_err beklendi ama gelmedi!", ad);
        end
        repeat(4) @(posedge clk_in);
        i_pkt_vld = 1'b0; i_start = 1'b0;
    end
endtask

// =====================================================================
// Ana Test Akışı
// =====================================================================
initial begin
    toplam_test = 0; basarili_test = 0;
    rst_n = 1'b0;
    i_pkt_in = 32'd0; i_pkt_vld = 1'b0; i_pkt_sel = 3'd0; i_start = 1'b0;
    repeat(5) @(posedge clk_in);
    rst_n = 1'b1;
    repeat(3) @(posedge clk_in);

    $display("\n============================================================");
    $display("  affine_donusum BIRIM TESTBENCH (Fermat/FLT)");
    $display("============================================================");

    // T1: Z = Montgomery(1) → Affin çıkış = giriş (X,Y) = G  [özdeşlik]
    test_donusum(GX_MONT, GY_MONT, R_MOD_P, "T1 Z=Mont(1) ozdeslik (G)");

    // T2: Z = keyfi (Gx_mont), koordinatlar çapraz → non-trivial FLT tersleme
    test_donusum(GY_MONT, GX_MONT, GX_MONT, "T2 Z=Gx_mont non-trivial");

    // T3: Z = keyfi (Gy_mont) → ikinci non-trivial doğrulama
    test_donusum(GX_MONT, GX_MONT, GY_MONT, "T3 Z=Gy_mont non-trivial");

    // T4: Z = 0 → sonsuzluk koruması
    test_hata(P256, GX_MONT, GY_MONT, 256'd0, "T4 Z=0 sonsuzluk hatasi");

    // T5: mod_p = 0 → geçersiz alan
    test_hata(256'd0, GX_MONT, GY_MONT, R_MOD_P, "T5 mod_p=0 hatasi");

    $display("\n============================================================");
    $display("  GENEL SONUC: %0d / %0d test basarili", basarili_test, toplam_test);
    if (basarili_test == toplam_test)
        $display("  >>> TUM TESTLER GECTI <<<  [PASS]");
    else
        $display("  !!! %0d TEST HATALI !!!    [FAIL]", toplam_test - basarili_test);
    $display("============================================================\n");
    $finish;
end

// =====================================================================
// Mutlak Zaman Aşımı
// =====================================================================
initial begin
    repeat(AFF_TIMEOUT * 6) @(posedge clk_in);
    $fatal(1, "[HATA] Mutlak simulasyon zaman asimi — affine_donusum yanit vermiyor!");
end

initial begin
    $dumpfile("tb_affine_donusum.vcd");
    $dumpvars(0, tb_affine_donusum);
end

endmodule
