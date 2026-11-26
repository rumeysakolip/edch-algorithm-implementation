// =============================================================================
// Modül   : tb_ecdsa_akis.sv                                          (TB-20)
// Proje   : FPGA Tabanlı Güvenli Anahtar Yönetimi ve Kripto Hızlandırıcı (5260007)
// -----------------------------------------------------------------------------
// AMAÇ:
//   ecdh_kex_top içindeki ECDSA İMZALAMA AKIŞINI uçtan uca doğrulamak.
//   TB-18 yalnızca ecdsa_imza modülünün aritmetiğini sınamıştı; bu TB
//   orkestrasyonu sınar:
//
//     i_imzala → nonce üretimi (anahtar_deposu) → k·G (scalar_multiplier +
//     affine_donusum) → Rx Montgomery→düz dönüşümü → ecdsa_imza → (r,s)
//
//   Yani Faz 4a + Faz 5b'nin BİRLEŞİMİ. Aralarındaki arayüzlerin doğru
//   olduğunu ancak bu seviye gösterebilir.
//
// -----------------------------------------------------------------------------
// *** BU TB'NİN YAKALADIĞI SINIF: ALAN UYUŞMAZLIĞI ***
//   affine_donusum çıktısı MONTGOMERY alanındadır; ecdsa_imza ise Rx'i DÜZ
//   bekler (TB-18 öyle doğrulandı). Bu dönüşüm atlanırsa hiçbir hata bayrağı
//   kalkmaz — imza üretilir, "başarılı" görünür, ama GEÇERSİZDİR ve yalnızca
//   karşı taraf doğrulamaya çalıştığında anlaşılır.
//
//   Modül seviyesindeki testler (TB-16, TB-17, TB-18) bu hatayı YAKALAYAMAZ;
//   her biri kendi alan varsayımıyla tutarlıdır. Ancak entegrasyon seviyesi
//   gösterebilir. Bu, ayrı ayrı geçen testlerin sistemin doğruluğunu
//   garanti etmediğinin somut örneğidir.
//
// -----------------------------------------------------------------------------
// TRNG MOCK — SIRALI YANIT:
//   Akış TRNG'den İKİ KEZ değer ister:
//     1. istek → d (imza anahtarı),  i_start ile üretilir
//     2. istek → k (nonce),          i_imzala ile üretilir
//   Mock bir sayaçla sırayı takip eder; böylece (d,k) deterministik olur ve
//   beklenen (r,s) Python'da önceden hesaplanabilir.
//
//   Gerçek donanımda k her seferinde FARKLI olmalıdır — burada sabitlenmesi
//   YALNIZCA test amaçlıdır. Aynı k ile iki imza özel anahtarı verir
//   (bkz. ecdsa_imza.v başlığı).
//
// -----------------------------------------------------------------------------
// KAPSANAN SENARYOLAR:
//   A) İMZA        : (r,s) Python altın-modeliyle bit-birebir.
//                    Vektör, bağımsız bir ECDSA doğrulayıcısından geçirildi.
//   B) İZİN        : IMZA izni OLMAYAN slotla imza denemesi → ERR_IZIN,
//                    özel anahtar HİÇ okunmadan reddedilir.
//   C) ECDH BOZULMADI: imzadan sonra normal ECDH akışı hâlâ çalışıyor.
//
// SÜRE UYARISI:
//   Anahtar üretimi (d·G) ~2.1 M + nonce (k·G) ~2.1 M + ters alma ~0.12 M
//   ≈ 4.4 M çevrim ≈ 44 ms per imza. Toplam ~120 ms. UZUN SÜRER.
//
// ÇALIŞTIRMA (Vivado xsim):
//   xelab -debug typical tb_ecdsa_akis -s sim_akis && xsim sim_akis -R
//
// Standart : SystemVerilog-2012
// Tarih    : Temmuz 2026
// =============================================================================

`timescale 1ns / 1ps

module tb_ecdsa_akis;

localparam int CLK_NS = 10;
localparam int TIMEOUT = 12_000_000;   // ~120 ms, olculen ~4.4M'e bol pay

// ── Python altin-modelinden (bagimsiz dogrulayiciyla sinandi) ───────────
localparam [255:0] D_ANAHTAR = 256'h5a1f3c9e2b7d48016fa3e5c8d90b247fe6183a5c7d2904bf83e61c5d7a94082b;
localparam [255:0] K_NONCE   = 256'h3e7b1a95c04d82f6e1b73d5a0928cf46b85e2071da39cf8e46b2057d1c93ae60;
localparam [255:0] HASH_E    = 256'h9f2c5e81a37b04d6e58c1930f7a26bd4508e73c19a6d02fb85341e7c092db6a5;
localparam [255:0] BEK_R     = 256'h41e864b2814d29f8f83b9b05ee148ce4d624f522970c259dc46b6340a4f8f7da;
localparam [255:0] BEK_S     = 256'hda616d1361a7858df02c1c850c9ec4014fca36bbb5c1714ed1682574f7057cc0;

// Politika bitleri (anahtar_deposu.v ile ayni)
localparam [7:0] POL_ECDH=8'h01, POL_IMZA=8'h02, POL_KALICI=8'h04;

logic clk_in = 1'b0, rst_n = 1'b0;
always #(CLK_NS/2) clk_in = ~clk_in;

// ── DUT sinyalleri ──────────────────────────────────────────────────────
logic        i_start, i_qb_start, i_imzala, i_zeroize, i_uret;
logic [31:0] i_pkt_in, i_trng_pkt, i_hash_pkt;
logic        i_pkt_vld, i_trng_vld, i_hash_vld;
logic [2:0]  i_pkt_sel;
logic [1:0]  i_slot;
logic [7:0]  i_politika;
wire  [31:0] o_pkt_out;
wire         o_pkt_vld, o_pkt_last, o_qa_done, o_rdy, o_done, o_err;
wire  [1:0]  o_pkt_sel, o_stage, o_uret_hata_kod;
wire  [2:0]  o_err_kod;
wire         o_trng_req, o_slot_hata, o_imza_hazir, o_imza_sel, o_imza_tekrar;

ecdh_kex_top dut (
    .clk_in(clk_in), .rst_n(rst_n), .i_start(i_start), .i_uret(i_uret), .i_dogrula(1'b0),
    .o_trng_req(o_trng_req), .i_trng_vld(i_trng_vld), .i_trng_pkt(i_trng_pkt),
    .i_pkt_in(i_pkt_in), .i_pkt_vld(i_pkt_vld), .i_pkt_sel(i_pkt_sel),
    .i_qb_start(i_qb_start),
    .o_pkt_out(o_pkt_out), .o_pkt_vld(o_pkt_vld), .o_pkt_sel(o_pkt_sel),
    .o_pkt_last(o_pkt_last), .o_stage(o_stage), .o_qa_done(o_qa_done),
    .o_rdy(o_rdy), .o_done(o_done), .o_err(o_err), .o_err_kod(o_err_kod),
    .i_slot(i_slot), .i_politika(i_politika), .i_zeroize(i_zeroize),
    .o_slot_hata(o_slot_hata), .o_uret_hata_kod(o_uret_hata_kod),
    .i_imzala(i_imzala), .i_hash_pkt(i_hash_pkt), .i_hash_vld(i_hash_vld),
    .o_imza_hazir(o_imza_hazir), .o_imza_sel(o_imza_sel),
    .o_imza_tekrar(o_imza_tekrar),
    .o_imza_gecerli(), .o_imza_aralik_hata(),
    // ── ÇOKLU EĞRİ DESTEĞİ (İster M-24) — P-256 sabit degerleri ──────────
    //   Bu TB ecdh_kex_top'u DOGRUDAN surdugu icin bu portlar P-256
    //   literalleriyle beslenmelidir; aksi halde bagsiz giris X yayar.
    .i_egri_p(256'hffffffff00000001000000000000000000000000ffffffffffffffffffffffff),
    .i_egri_r_mod_p(256'h00000000fffffffeffffffffffffffffffffffff000000000000000000000001),
    .i_egri_gx_mont(256'h18905f76a53755c679fb732b7762251075ba95fc5fedb60179e730d418a9143c),
    .i_egri_gy_mont(256'h8571ff1825885d85d2e88688dd21f3258b4ab8e4ba19e45cddf25357ce95560a),
    .i_egri_b_mont(256'hdc30061d04874834e5a220abf7212ed6acf005cd78843090d89cdf6229c4bddf),
    .i_egri_n_order(256'hffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551),
    .i_egri_mont_bir_n(256'h00000000ffffffff00000000000000004319055258e8617b0c46353d039cdaaf),
    .i_egri_r2n(256'h66e12d94f3d956202845b2392b6bec594699799c49bd6fa683244c95be79eea2),
    .i_egri_n_bit_uzunluk(10'd256)
);

// ── TRNG mock: 1. istek d, 2. istek k, sonrasi d ───────────────────────
int trng_istek_no = 0;
initial begin
    int j;
    logic [255:0] gonder;
    i_trng_vld = 1'b0; i_trng_pkt = 32'd0;
    forever begin
        @(posedge clk_in);
        if (o_trng_req && rst_n) begin
            gonder = (trng_istek_no == 0) ? D_ANAHTAR : K_NONCE;
            trng_istek_no++;
            for (j = 0; j < 8; j++) begin
                @(posedge clk_in); #1;
                i_trng_pkt = gonder[j*32 +: 32];
                i_trng_vld = 1'b1;
            end
            @(posedge clk_in); #1; i_trng_vld = 1'b0;
            while (o_trng_req) @(posedge clk_in);
        end
    end
end

// ── Imza toplayici ──────────────────────────────────────────────────────
logic [255:0] alinan_r, alinan_s;
int ri = 0, si = 0;
always @(posedge clk_in) begin
    if (o_imza_hazir && o_pkt_vld) begin
        if (!o_imza_sel) begin alinan_r[ri*32 +: 32] <= o_pkt_out; ri <= ri+1; end
        else             begin alinan_s[si*32 +: 32] <= o_pkt_out; si <= si+1; end
    end
end

int gecen = 0, kalan = 0;
task automatic kontrol(input string a, input logic k);
    if (k) begin $display("   gecti   %s", a); gecen++; end
    else   begin $display("   KALDI   %s   <<<", a); kalan++; end
endtask

task automatic hash_yaz(input logic [255:0] e);
    for (int i = 0; i < 8; i++) begin
        @(negedge clk_in); i_hash_pkt = e[i*32 +: 32]; i_hash_vld = 1'b1;
    end
    @(negedge clk_in); i_hash_vld = 1'b0;
endtask

// o_err, o_err_kod ve o_slot_hata DARBE sinyalleridir; yalnizca bir cevrim
// yuksek kalirlar ve BIRLIKTE ornekleniverek anlam kazanirlar.
// komut_yoneticisi de ayni sekilde yakalar:  if (g_kex_err) hata_kod_r <= ...
// TB'nin ilk surumu bunlara bekle_bitis DONDUKTEN SONRA bakiyordu; darbe
// coktan gecmis oluyordu. Artik hata anindaki degerler kilitleniyor.
logic       yak_slot_hata;
logic [2:0] yak_err_kod;

task automatic bekle_bitis(output logic ariza, output int cevrim);
    int c; c = 0; ariza = 1'b0;
    yak_slot_hata = 1'b0; yak_err_kod = 3'd0;
    forever begin
        @(posedge clk_in); c++;
        if (o_err)  begin
            ariza = 1'b1;
            yak_slot_hata = o_slot_hata;   // AYNI cevrimde yakala
            yak_err_kod   = o_err_kod;
            break;
        end
        if (o_done) break;
        if (c >= TIMEOUT) begin
            $display("     !! ZAMAN ASIMI (%0d cevrim)", c); ariza = 1'bx; break;
        end
    end
    cevrim = c;
    repeat (4) @(posedge clk_in);
endtask

logic ariza; int cevrim;

initial begin
    i_start=0; i_qb_start=0; i_imzala=0; i_zeroize=0; i_uret=0;
    i_pkt_in=0; i_pkt_vld=0; i_pkt_sel=0; i_slot=0; i_politika=0;
    i_hash_pkt=0; i_hash_vld=0;

    $display("");
    $display("==================================================================");
    $display(" TB-20  ECDSA IMZALAMA AKISI  (ecdh_kex_top uctan uca)");
    $display(" nonce uretimi -> k*G -> Rx donusumu -> ecdsa_imza -> (r,s)");
    $display(" UYARI: her imza ~44 ms, toplam ~120 ms. UZUN SURER.");
    $display("==================================================================");

    repeat (5) @(posedge clk_in); rst_n = 1'b1; repeat (5) @(posedge clk_in);

    // ── A) Imza anahtarini uret (slot 0, IMZA izinli) ────────────────────
    $display("\n SENARYO A — imza anahtari uretimi + imzalama");
    @(negedge clk_in); i_slot = 2'd0; i_politika = POL_ECDH | POL_IMZA;
    @(negedge clk_in); i_uret = 1'b1;
    @(negedge clk_in); i_uret = 1'b0;
    bekle_bitis(ariza, cevrim);
    kontrol($sformatf("imza anahtari uretildi (%0d cevrim)", cevrim), !ariza);

    // Hash yukle ve imzala
    hash_yaz(HASH_E);
    ri = 0; si = 0;
    @(negedge clk_in); i_imzala = 1'b1;
    @(negedge clk_in); i_imzala = 1'b0;
    bekle_bitis(ariza, cevrim);
    kontrol($sformatf("imza tamamlandi (%0d cevrim)", cevrim), !ariza);
    kontrol("yeniden deneme bayragi dusuk", o_imza_tekrar === 1'b0);
    kontrol("r ve s'nin 8'er paketi alindi", ri == 8 && si == 8);

    if (alinan_r !== BEK_R) begin
        $display("           r beklenen 0x%064x", BEK_R);
        $display("           r alinan   0x%064x", alinan_r);
    end
    kontrol("*** r golden model ile AYNI ***", alinan_r === BEK_R);
    if (alinan_s !== BEK_S) begin
        $display("           s beklenen 0x%064x", BEK_S);
        $display("           s alinan   0x%064x", alinan_s);
    end
    kontrol("*** s golden model ile AYNI ***", alinan_s === BEK_S);

    // ── B) IMZA izni olmayan slot ────────────────────────────────────────
    //   Slot 1'e YALNIZCA ECDH izinli anahtar uret, sonra imzalamaya calis.
    $display("\n SENARYO B — IMZA izni olmayan slotla imza denemesi");
    trng_istek_no = 0;
    @(negedge clk_in); i_slot = 2'd1; i_politika = POL_ECDH;   // IMZA YOK
    @(negedge clk_in); i_uret = 1'b1;
    @(negedge clk_in); i_uret = 1'b0;
    bekle_bitis(ariza, cevrim);
    kontrol("slot 1 anahtari uretildi (ECDH-only)", !ariza);

    hash_yaz(HASH_E);
    @(negedge clk_in); i_imzala = 1'b1;
    @(negedge clk_in); i_imzala = 1'b0;
    bekle_bitis(ariza, cevrim);
    kontrol("*** imza REDDEDILDI (izin yok) ***", ariza === 1'b1);
    kontrol("hata kodu = ERR_IZIN (6)", yak_err_kod === 3'd6);
    kontrol("slot hata bayragi kalkti", yak_slot_hata === 1'b1);

    // ── C) ECDH akisi bozulmadi mi ───────────────────────────────────────
    $display("\n SENARYO C — imzadan sonra ECDH hala calisiyor");
    trng_istek_no = 0;
    @(negedge clk_in); i_slot = 2'd2; i_politika = POL_ECDH;
    @(negedge clk_in); i_uret = 1'b1;
    @(negedge clk_in); i_uret = 1'b0;
    bekle_bitis(ariza, cevrim);
    kontrol("ECDH anahtar uretimi + Qa hesabi calisiyor", !ariza);

    $display("");
    $display("==================================================================");
    $display(" OZET:  %0d gecti / %0d kaldi   (toplam %0d dogrulama)",
             gecen, kalan, gecen + kalan);
    if (kalan == 0) $display(" SONUC: *** TB-20 BASARILI ***");
    else            $display(" SONUC: *** TB-20 BASARISIZ — %0d kaldi ***", kalan);
    $display("==================================================================");
    $display("");
    $finish;
end

initial begin
    #(CLK_NS * TIMEOUT * 6);
    $display(" !! TB-20 GENEL ZAMAN ASIMI");
    $finish;
end

endmodule
