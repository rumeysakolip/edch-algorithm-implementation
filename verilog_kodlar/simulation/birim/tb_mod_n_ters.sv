// =============================================================================
// Modül   : tb_mod_n_ters.sv                                          (TB-17)
// Proje   : FPGA Tabanlı Güvenli Anahtar Yönetimi ve Kripto Hızlandırıcı (5260007)
// -----------------------------------------------------------------------------
// AMAÇ:
//   mod_n_ters.v'nin GF(n) modüler ters alma işlemini doğru yaptığını KAT
//   yöntemiyle kanıtlamak. Bu birim ECDSA'nın hem imzalama (k^-1) hem
//   doğrulama (s^-1) yolunda bulunur; hatası her iki tarafı da sessizce
//   bozar, o yüzden ayrı ve bağımsız doğrulanır.
//
//   DUT gerçek modular_alu'ya DOĞRUDAN bağlanır (bu TB'de tek sahip odur).
//   Böylece hem üs alma döngüsü hem MALU el sıkışması birlikte sınanır.
//
// -----------------------------------------------------------------------------
// *** BU TB AYNI ZAMANDA BİR MİMARİ İDDİAYI SINAR ***
//   modular_alu'nun modülü SEL_P ile dışarıdan yüklenir; sabit değildir.
//   Bu TB ona n yükler (p değil). Geçerse, aynı çarpanın hem GF(p) hem
//   GF(n) için kullanılabildiği KANITLANMIŞ olur — ECDSA için ayrı bir
//   çarpan yazmaya gerek kalmaz ve alan maliyeti düşük kalır.
//
// -----------------------------------------------------------------------------
// VEKTÖRLER (host/mod_n_vektor_uret.py, tohum 5260007):
//   Montgomery-n alanında (ã = a·R mod n). Beklenen sonuç Python'da
//   BAĞIMSIZ olarak pow(a, n-2, n) ile hesaplanmış, ardından Montgomery'ye
//   taşınmıştır — RTL'in izlediği kare-al-ve-çarp yolundan farklı bir yol.
//   Ortak bir hata iki tarafta birden aynı yöne kaymasın diye böyle yapıldı.
//
//   Kapsanan: a=1 (birim), a=2, a=3, küçük değer, a=n-1 (uç), 3 rastgele.
//
// SÜRE UYARISI:
//   Her ters alma ≈ 384 MALU çağrısı ≈ 124.000 çevrim ≈ 1.24 ms.
//   8 vektör ≈ 10 ms simülasyon zamanı. Sabırlı olun.
//
// ÇALIŞTIRMA (Vivado xsim):
//   xvlog -sv tb_mod_n_ters.sv
//   xvlog mod_n_ters.v modular_alu_dsp.v
//   xelab -debug typical tb_mod_n_ters -s sim_mnt
//   xsim sim_mnt -R
//
// Standart : SystemVerilog-2012
// Tarih    : Temmuz 2026
// =============================================================================

`timescale 1ns / 1ps

module tb_mod_n_ters;

localparam real SAAT_PERIYOT = 10.0;
localparam int  VEK_ZAMAN_ASIMI = 400_000;   // cevrim / vektor (~3x pay)

localparam logic [255:0] N_ORDER =
    256'hffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551;
// Montgomery 1 = R mod n — carpim kontrolunde beklenen sonuc
localparam logic [255:0] MONT_BIR =
    256'h00000000ffffffff00000000000000004319055258e8617b0c46353d039cdaaf;

localparam logic [1:0] TIX_MODN = 2'd0, TIX_A = 2'd1;

logic clk_in = 1'b0, rst_n = 1'b0;
always #(SAAT_PERIYOT/2.0) clk_in = ~clk_in;

// ── DUT ↔ MALU ────────────────────────────────────────────────────────────
logic [31:0] dut_pkt_in;
logic        dut_pkt_vld;
logic [1:0]  dut_pkt_sel;
logic        dut_start;
wire  [31:0] dut_pkt_out;
wire         dut_pkt_vld_o, dut_pkt_last, dut_rdy, dut_done, dut_err;

wire [31:0] mo_dat;  wire mo_vld;  wire [1:0] mo_sel, mo_opc;  wire mo_st;
wire [31:0] mi_out;  wire mi_vld, mi_last, mi_rdy, mi_done, mi_err;

mod_n_ters dut (
    .clk_in(clk_in), .rst_n(rst_n),
    .i_pkt_in(dut_pkt_in), .i_pkt_vld(dut_pkt_vld), .i_pkt_sel(dut_pkt_sel),
    .i_start(dut_start),
    .o_pkt_out(dut_pkt_out), .o_pkt_vld(dut_pkt_vld_o),
    .o_pkt_last(dut_pkt_last), .o_rdy(dut_rdy),
    .o_done(dut_done), .o_err(dut_err),
    .mo_pkt_dat(mo_dat), .mo_pkt_vld(mo_vld), .mo_pkt_sel(mo_sel),
    .mo_opc(mo_opc), .mo_st(mo_st),
    .mi_pkt_out(mi_out), .mi_pkt_vld(mi_vld), .mi_pkt_last(mi_last),
    .mi_rdy(mi_rdy), .mi_done(mi_done), .mi_err(mi_err),
    .g_n_order(256'hffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551),
    .g_mont_bir_n(256'h00000000ffffffff00000000000000004319055258e8617b0c46353d039cdaaf)
);

// *** MALU'ya n yuklenir, p DEGIL — mimari iddianin sinandigi yer burasi ***
// [ADIM-1] modular_alu -> modular_alu_dsp (port-port ayni, drop-in).
modular_alu_dsp malu (
    .clk_in(clk_in), .rst_n(rst_n),
    .i_pkt_in(mo_dat), .i_pkt_vld(mo_vld), .i_pkt_sel(mo_sel),
    .i_opcode(mo_opc), .i_start(mo_st),
    .o_pkt_out(mi_out), .o_pkt_vld(mi_vld), .o_pkt_last(mi_last),
    .o_rdy(mi_rdy), .o_done(mi_done), .o_err(mi_err)
);

// ── Test vektorleri (Montgomery-n alani) ─────────────────────────────────
localparam int VEK_SAY = 8;
string        ad [0:VEK_SAY-1];
logic [255:0] vg [0:VEK_SAY-1];   // giris  a~
logic [255:0] vb [0:VEK_SAY-1];   // beklenen a^-1~

initial begin
  ad[0]="a=1 (birim)";
  vg[0]=256'h00000000ffffffff00000000000000004319055258e8617b0c46353d039cdaaf;
  vb[0]=256'h00000000ffffffff00000000000000004319055258e8617b0c46353d039cdaaf;
  ad[1]="a=2";
  vg[1]=256'h00000001fffffffe000000000000000086320aa4b1d0c2f6188c6a7a0739b55e;
  vb[1]=256'h8000000000000000000000000000000000000000000000000000000000000000;
  ad[2]="a=3";
  vg[2]=256'h00000002fffffffd0000000000000000c94b0ff70ab9247124d29fb70ad6900d;
  vb[2]=256'h00000000555555550000000000000000165dac70c84d75d3aec211bf013448e5;
  ad[3]="a=0x12345678";
  vg[3]=256'h12345677edcba9880000000004c57a1eba7e8e86318875ce7171370d1c894c08;
  vb[3]=256'h96385eaff6a6c63ac6c1f3911970965130dd8e4e3d669ad6970929dcc9990905;
  ad[4]="a=n-1 (uc deger)";
  vg[4]=256'hfffffffe00000001ffffffffffffffff79cdf55b4e2f3d09e7739585f8c64aa2;
  vb[4]=256'hfffffffe00000001ffffffffffffffff79cdf55b4e2f3d09e7739585f8c64aa2;
  ad[5]="rastgele #1";
  vg[5]=256'hafa56dc3f3859ae0e8c12f43d3cd62b8b02a43ab300b521dbf25383b76336a49;
  vb[5]=256'h8d21f897b662c2ecb259883d859d30fe7ace5f9043f4c5532c044d289e498bf5;
  ad[6]="rastgele #2";
  vg[6]=256'h9b3a3583952b68b09cdf069c53d72b29fed714c5b8a99f61e776aea3a03c9287;
  vb[6]=256'h43d35c479873c7cfaad188d5fb2eb5a65313ef8d40a5752ada2a49b66471c726;
  ad[7]="rastgele #3";
  vg[7]=256'h1763af4eced746058bf0bae8580f937ab639502e32692fcaa657b659f173c6c2;
  vb[7]=256'h868b9aa93e394a668b89c7a30ac69a88ed24d122dff791f7322bed2ed902629d;
end

// ── Puan tablosu ──────────────────────────────────────────────────────────
int gecen_r = 0, kalan_r = 0;
task automatic kontrol(input string a, input logic k);
    if (k) begin $display("   gecti   %s", a); gecen_r++; end
    else   begin $display("   KALDI   %s   <<<", a); kalan_r++; end
endtask

// ── Surucu gorevleri ──────────────────────────────────────────────────────
task automatic paket_yaz(input logic [1:0] sel, input logic [255:0] deger);
    for (int i = 0; i < 8; i++) begin
        @(negedge clk_in);
        dut_pkt_in = deger[i*32 +: 32]; dut_pkt_sel = sel; dut_pkt_vld = 1'b1;
    end
    @(negedge clk_in); dut_pkt_vld = 1'b0;
endtask

task automatic ters_al(input  logic [255:0] a,
                       output logic [255:0] sonuc,
                       output logic         ariza,
                       output int           cevrim);
    int sayac, idx;
    paket_yaz(TIX_MODN, N_ORDER);
    paket_yaz(TIX_A,    a);
    @(negedge clk_in); dut_start = 1'b1;
    @(negedge clk_in); dut_start = 1'b0;

    sayac = 0; idx = 0; sonuc = 256'd0; ariza = 1'b0;
    forever begin
        @(posedge clk_in);
        sayac++;
        if (dut_pkt_vld_o) begin
            sonuc[idx*32 +: 32] = dut_pkt_out;
            idx++;
        end
        if (dut_err)  begin ariza = 1'b1; break; end
        if (dut_done) break;
        if (sayac >= VEK_ZAMAN_ASIMI) begin
            $display("     !! ZAMAN ASIMI (%0d cevrim)", sayac);
            ariza = 1'bx; break;
        end
    end
    cevrim = sayac;
    repeat (4) @(posedge clk_in);
    if (dut_rdy !== 1'b1)
        $display("     !! UYARI: kosum sonrasi o_rdy yukselmedi");
endtask

// ═════════════════════════════════════════════════════════════════════════
//  ANA AKIS
// ═════════════════════════════════════════════════════════════════════════
logic [255:0] sonuc;
logic         ariza;
int           cevrim, cev_min, cev_max;

initial begin
    dut_pkt_in = 32'd0; dut_pkt_vld = 1'b0; dut_pkt_sel = 2'd0; dut_start = 1'b0;
    cev_min = 1_000_000; cev_max = 0;

    $display("");
    $display("==================================================================");
    $display(" TB-17  mod_n_ters.v  —  GF(n) moduler ters alma (Fermat)");
    $display(" a^(-1) = a^(n-2) mod n   |   %0d KAT vektoru", VEK_SAY);
    $display(" NOT: MALU'ya n yuklenir (p degil) — ayni carpan her iki alanda");
    $display(" UYARI: her vektor ~1.24 ms surer, toplam ~10 ms");
    $display("==================================================================");

    repeat (5) @(posedge clk_in);
    rst_n = 1'b1;
    repeat (5) @(posedge clk_in);

    // [ADIM-1] ISINMA KOSUMU — modular_alu_dsp'nin n0' onbellegi resetten
    // sonra SOGUKTUR; ilk MontMult, Newton-Raphson icin +10 cevrim harcar
    // (bkz. modular_alu_dsp.v basligi). Bu maliyet yalnizca P'nin ilk kez
    // yuklenmesine baglidir, girdi 'a'dan BAGIMSIZDIR — ama isitilmadan
    // birakilirsa SENARYO A'daki ilk olculen vektore sahte bir fark biner.
    // Atilan bir ters alma ile onbellegi burada isitiyoruz.
    ters_al(vg[0], sonuc, ariza, cevrim);

    $display("\n SENARYO A — KAT dogrulamasi");
    for (int v = 0; v < VEK_SAY; v++) begin
        ters_al(vg[v], sonuc, ariza, cevrim);
        if (cevrim < cev_min) cev_min = cevrim;
        if (cevrim > cev_max) cev_max = cevrim;

        if (ariza !== 1'b0) begin
            $display("   KALDI   %-20s ARIZA (%0d cevrim)   <<<", ad[v], cevrim);
            kalan_r++;
        end else if (sonuc === vb[v]) begin
            $display("   gecti   %-20s (%0d cevrim)", ad[v], cevrim);
            gecen_r++;
        end else begin
            $display("   KALDI   %-20s   <<<", ad[v]);
            $display("           beklenen 0x%064x", vb[v]);
            $display("           cikan    0x%064x", sonuc);
            kalan_r++;
        end
    end

    // ── SENARYO B: sabit zamanlilik ──────────────────────────────────────
    //   Fermat'in secilme sebebi buydu: sure GIRDIDEN BAGIMSIZ olmali.
    //   Genisletilmis Oklid kullanilsaydi bu fark sifir olmaz, k^-1
    //   hesabinda gizli nonce hakkinda zamanlama kanali acilirdi.
    $display("\n SENARYO B — sabit zamanlilik (Fermat'in secilme sebebi)");
    $display("   en kisa = %0d cevrim | en uzun = %0d cevrim | yayilim = %0d",
             cev_min, cev_max, cev_max - cev_min);
    kontrol("*** sure girdiden BAGIMSIZ (yayilim = 0) ***",
            (cev_max - cev_min) == 0);

    // ── SENARYO C: ardisik kosum ─────────────────────────────────────────
    $display("\n SENARYO C — ardisik kosum (bayat durum avi)");
    ters_al(vg[3], sonuc, ariza, cevrim);
    kontrol("ilk vektor tekrar kosturuldu, sonuc ayni",
            !ariza && sonuc === vb[3]);

    $display("");
    $display("==================================================================");
    $display(" OZET:  %0d gecti / %0d kaldi   (toplam %0d dogrulama)",
             gecen_r, kalan_r, gecen_r + kalan_r);
    if (kalan_r == 0) $display(" SONUC: *** TB-17 BASARILI ***");
    else              $display(" SONUC: *** TB-17 BASARISIZ — %0d kaldi ***", kalan_r);
    $display("==================================================================");
    $display("");
    $finish;
end

initial begin
    #(SAAT_PERIYOT * VEK_ZAMAN_ASIMI * (VEK_SAY + 6));
    $display(" !! TB-17 GENEL ZAMAN ASIMI");
    $finish;
end

endmodule
