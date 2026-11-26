// =============================================================================
// Modül   : tb_parametre_deposu.sv                                    (TB-24)
// Proje   : FPGA Tabanlı Güvenli Anahtar Yönetimi ve Kripto Hızlandırıcı (5260007)
// -----------------------------------------------------------------------------
// AMAÇ:
//   parametre_deposu.v — Çoklu Eğri Desteği (İster M-24) — birim testi.
//
//   Bu modül, RTL'in eskiden 7 dosyaya elle gömülü P-256 sabitlerini TEK bir
//   merkezi register bankasında toplar ve UART üzerinden (komut_yoneticisi
//   .v'nin EGRI_* komutlarıyla) çalışma anında yeniden yüklenebilir kılar.
//   Bu TB, komut_yoneticisi'nin protokol katmanını ATLAYIP doğrudan
//   parametre_deposu'nun kendi arayüzünü (g_alan_*, g_uzunluk_*, g_uygula,
//   g_varsayilana_don) sürer — modülün KENDİ mantığını izole test eder.
//
// KAPSANAN SENARYOLAR:
//   A) RESET — çıkışlar P-256 fabrika varsayılanlarıyla BİREBİR eşleşmeli
//      (geriye dönük uyumluluk garantisi: hiçbir EGRI_* komutu gelmezse
//      davranış eskisiyle AYNI olmalıdır).
//   B) TEK ALAN YÜKLEME — bir alan yazılırken diğerleri ETKİLENMEMELİ;
//      c_gecerli yazma ANINDA 0'a düşmeli, g_uygula ile 1'e dönmeli.
//   C) TAM EĞRİ DEĞİŞİMİ — 8 alan + bit-uzunluk paketi P-192 değerleriyle
//      yüklenip UYGULA çağrıldığında TÜM çıkışlar P-192'ye dönmeli.
//   D) VARSAYILANA DÖNÜŞ — g_varsayilana_don, P-192'den P-256'ya TEK
//      darbede ve TUTARLI şekilde geri döndürmeli.
//   E) BİLİNMEYEN ALAN_ID — sessizce yok sayılmalı, mevcut alanlar BOZULMAMALI.
//   F) SÖZCÜK SIRASI — g_alan_indis=0 DAİMA bit[31:0] (LSB sözcük), indis=7
//      DAİMA bit[255:224] (MSB sözcük) olmalı (P256[cnt*32+:32] ile aynı
//      kural — bkz. ecdh_kex_top.v / komut_yoneticisi.v).
//
// ÇALIŞTIRMA (Vivado xsim):
//   xvlog -sv tb_parametre_deposu.sv
//   xvlog parametre_deposu.v
//   xelab -debug typical tb_parametre_deposu -s sim_pd
//   xsim sim_pd -R
//
// Standart : SystemVerilog-2012
// Tarih    : Temmuz 2026
// =============================================================================

`timescale 1ns / 1ps

module tb_parametre_deposu;

localparam real SAAT_PERIYOT = 10.0;

// ── Alan kimlikleri (parametre_deposu.v ile BİREBİR aynı olmalı) ──────────
localparam [3:0] ALN_P          = 4'd0,
                 ALN_R_MOD_P    = 4'd1,
                 ALN_GX_MONT    = 4'd2,
                 ALN_GY_MONT    = 4'd3,
                 ALN_B_MONT     = 4'd4,
                 ALN_N_ORDER    = 4'd5,
                 ALN_MONT_BIR_N = 4'd6,
                 ALN_R2N        = 4'd7;

// ── P-256 FABRİKA VARSAYILANLARI (parametre_deposu.v'deki ile BİREBİR) ────
localparam [255:0] P256_P          = 256'hffffffff00000001000000000000000000000000ffffffffffffffffffffffff;
localparam [255:0] P256_R_MOD_P    = 256'h00000000fffffffeffffffffffffffffffffffff000000000000000000000001;
localparam [255:0] P256_GX_MONT    = 256'h18905f76a53755c679fb732b7762251075ba95fc5fedb60179e730d418a9143c;
localparam [255:0] P256_GY_MONT    = 256'h8571ff1825885d85d2e88688dd21f3258b4ab8e4ba19e45cddf25357ce95560a;
localparam [255:0] P256_B_MONT     = 256'hdc30061d04874834e5a220abf7212ed6acf005cd78843090d89cdf6229c4bddf;
localparam [255:0] P256_N_ORDER    = 256'hffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551;
localparam [255:0] P256_MONT_BIR_N = 256'h00000000ffffffff00000000000000004319055258e8617b0c46353d039cdaaf;
localparam [255:0] P256_R2N        = 256'h66e12d94f3d956202845b2392b6bec594699799c49bd6fa683244c95be79eea2;
localparam [9:0]   P256_P_BIT      = 10'd256;
localparam [9:0]   P256_N_BIT      = 10'd256;

// ── P-192 (secp192r1) — R=2^256 ile hesaplanmış ve bağımsız doğrulanmış ───
//   (bkz. FINAL repo data/DATA.md — GX_MONT, R^-1 mod p ile geri çözülüp
//   Gx'e eşit olduğu Python'da doğrulandı)
localparam [255:0] P192_P          = 256'h0000000000000000fffffffffffffffffffffffffffffffeffffffffffffffff;
localparam [255:0] P192_R_MOD_P    = 256'h0000000000000000000000000000000100000000000000010000000000000000;
localparam [255:0] P192_GX_MONT    = 256'h00000000000000008a4bd3f776d12909a2d97c062701b9ff954cc8f9f3d218f7;
localparam [255:0] P192_GY_MONT    = 256'h0000000000000000de22b5248966f05ee53be0ba892fcad66a293d836aeda84d;
localparam [255:0] P192_B_MONT     = 256'h00000000000000007281cdb219076ae2d6a2d2cbfea3ebc973c8eec557c0b131;
localparam [255:0] P192_N_ORDER    = 256'h0000000000000000ffffffffffffffffffffffff99def836146bc9b1b4d22831;
localparam [255:0] P192_MONT_BIR_N = 256'h000000000000000000000000662107c9eb94364e4b2dd7cf0000000000000000;
localparam [255:0] P192_R2N        = 256'h0000000000000000126792c4cef5d8c5d69c6961caaf687f01d1770a83134c27;
localparam [9:0]   P192_P_BIT      = 10'd192;
localparam [9:0]   P192_N_BIT      = 10'd192;

logic saat = 1'b0, sifirla_n = 1'b0;
always #(SAAT_PERIYOT/2.0) saat = ~saat;

// ── DUT bağlantıları ───────────────────────────────────────────────────────
logic [3:0]  g_alan_id;
logic [2:0]  g_alan_indis;
logic [31:0] g_alan_word;
logic        g_alan_yaz;
logic [31:0] g_uzunluk_word;
logic        g_uzunluk_yaz;
logic        g_uygula;
logic        g_varsayilana_don;
wire         c_gecerli;
wire [255:0] c_p, c_r_mod_p, c_gx_mont, c_gy_mont, c_b_mont;
wire [255:0] c_n_order, c_mont_bir_n, c_r2n;
wire [9:0]   c_p_bit_uzunluk, c_n_bit_uzunluk;

parametre_deposu dut (
    .g_saat(saat), .g_sifirla_n(sifirla_n),
    .g_alan_id(g_alan_id), .g_alan_indis(g_alan_indis),
    .g_alan_word(g_alan_word), .g_alan_yaz(g_alan_yaz),
    .g_uzunluk_word(g_uzunluk_word), .g_uzunluk_yaz(g_uzunluk_yaz),
    .g_uygula(g_uygula), .g_varsayilana_don(g_varsayilana_don),
    .c_gecerli(c_gecerli),
    .c_p(c_p), .c_r_mod_p(c_r_mod_p),
    .c_gx_mont(c_gx_mont), .c_gy_mont(c_gy_mont),
    .c_b_mont(c_b_mont), .c_n_order(c_n_order),
    .c_mont_bir_n(c_mont_bir_n), .c_r2n(c_r2n),
    .c_p_bit_uzunluk(c_p_bit_uzunluk), .c_n_bit_uzunluk(c_n_bit_uzunluk)
);

// ── Puan tablosu (tb_anahtar_deposu.sv ile AYNI biçim) ────────────────────
int gecen_r = 0, kalan_r = 0;
task automatic kontrol(input string ad, input logic kosul);
    if (kosul) begin $display("   gecti   %s", ad); gecen_r++; end
    else       begin $display("   KALDI   %s   <<<", ad); kalan_r++; end
endtask

// ── Yardımcı görevler ──────────────────────────────────────────────────────
task automatic alan_yukle(input logic [3:0] id, input logic [255:0] deger);
    for (int w = 0; w < 8; w++) begin
        @(negedge saat);
        g_alan_id    = id;
        g_alan_indis = w[2:0];
        g_alan_word  = deger[w*32 +: 32];
        g_alan_yaz   = 1'b1;
        @(negedge saat);
        g_alan_yaz   = 1'b0;
    end
endtask

task automatic uzunluk_yukle(input logic [9:0] p_bit, input logic [9:0] n_bit);
    @(negedge saat);
    // parametre_deposu.v: n_bit_r <= word[9:0]; p_bit_r <= word[19:10];
    g_uzunluk_word = {12'd0, p_bit, n_bit};
    g_uzunluk_yaz  = 1'b1;
    @(negedge saat);
    g_uzunluk_yaz  = 1'b0;
endtask

task automatic uygula_ver();
    @(negedge saat); g_uygula = 1'b1;
    @(negedge saat); g_uygula = 1'b0;
endtask

task automatic varsayilana_don_ver();
    @(negedge saat); g_varsayilana_don = 1'b1;
    @(negedge saat); g_varsayilana_don = 1'b0;
endtask

task automatic kontrol_p256_varsayilan(input string etiket);
    kontrol({etiket, ": P"},          c_p          === P256_P);
    kontrol({etiket, ": R_MOD_P"},    c_r_mod_p    === P256_R_MOD_P);
    kontrol({etiket, ": GX_MONT"},    c_gx_mont    === P256_GX_MONT);
    kontrol({etiket, ": GY_MONT"},    c_gy_mont    === P256_GY_MONT);
    kontrol({etiket, ": B_MONT"},     c_b_mont     === P256_B_MONT);
    kontrol({etiket, ": N_ORDER"},    c_n_order    === P256_N_ORDER);
    kontrol({etiket, ": MONT_BIR_N"}, c_mont_bir_n === P256_MONT_BIR_N);
    kontrol({etiket, ": R2N"},        c_r2n        === P256_R2N);
    kontrol({etiket, ": p_bit"},      c_p_bit_uzunluk === P256_P_BIT);
    kontrol({etiket, ": n_bit"},      c_n_bit_uzunluk === P256_N_BIT);
    kontrol({etiket, ": gecerli"},    c_gecerli === 1'b1);
endtask

// ═════════════════════════════════════════════════════════════════════════
//  ANA AKIŞ
// ═════════════════════════════════════════════════════════════════════════
initial begin
    g_alan_id = 0; g_alan_indis = 0; g_alan_word = 0; g_alan_yaz = 0;
    g_uzunluk_word = 0; g_uzunluk_yaz = 0;
    g_uygula = 0; g_varsayilana_don = 0;

    $display("");
    $display("==================================================================");
    $display(" TB-24  parametre_deposu.v  —  Coklu Egri Destegi (Istek M-24)");
    $display("==================================================================");

    repeat (5) @(posedge saat);
    sifirla_n = 1'b1;
    repeat (5) @(posedge saat);

    // ── A) Reset sonrasi P-256 fabrika varsayilanlari ────────────────────
    $display("\n SENARYO A — reset sonrasi P-256 varsayilanlari");
    kontrol_p256_varsayilan("reset");

    // ── B) Tek alan yukleme: digerleri ETKILENMEMELI, gecerli dusup kalkmali
    $display("\n SENARYO B — tek alan yukleme (GX_MONT), izolasyon + gecerli bayragi");
    kontrol("yukleme ONCESI gecerli=1", c_gecerli === 1'b1);
    alan_yukle(ALN_GX_MONT, 256'hCAFE_BABE_0000_0000_1111_1111_2222_2222_3333_3333_4444_4444_5555_5555_6666_6666);
    kontrol("yazma SIRASINDA gecerli DUSTU", c_gecerli === 1'b0);
    kontrol("GX_MONT guncellendi", c_gx_mont === 256'hCAFE_BABE_0000_0000_1111_1111_2222_2222_3333_3333_4444_4444_5555_5555_6666_6666);
    kontrol("P etkilenmedi (hala P-256)", c_p === P256_P);
    kontrol("N_ORDER etkilenmedi (hala P-256)", c_n_order === P256_N_ORDER);
    uygula_ver();
    kontrol("UYGULA sonrasi gecerli=1", c_gecerli === 1'b1);

    // Bu alani P-256'ya elle geri koy (sonraki senaryolari kirletmesin)
    alan_yukle(ALN_GX_MONT, P256_GX_MONT);
    uygula_ver();
    kontrol("GX_MONT P-256'ya geri alindi", c_gx_mont === P256_GX_MONT);

    // ── F) Sozcuk sirasi: ayirt edici desenle P alanini yukle ────────────
    $display("\n SENARYO F — sozcuk sirasi (indis=0 -> LSB, indis=7 -> MSB)");
    alan_yukle(ALN_P, 256'h7777_0000_6666_0000_5555_0000_4444_0000_3333_0000_2222_0000_1111_0000_0000_0001);
    uygula_ver();
    kontrol("indis=0 sozcugu bit[31:0]'a yerlesti", c_p[31:0]   === 32'h0000_0001);
    kontrol("indis=7 sozcugu bit[255:224]'e yerlesti", c_p[255:224] === 32'h7777_0000);
    // P'yi P-256'ya geri al
    alan_yukle(ALN_P, P256_P);
    uygula_ver();
    kontrol("P P-256'ya geri alindi", c_p === P256_P);

    // ── C) Tam egri degisimi: P-192 ────────────────────────────────────────
    $display("\n SENARYO C — tam egri yuklemesi (P-192)");
    alan_yukle(ALN_P,          P192_P);
    alan_yukle(ALN_R_MOD_P,    P192_R_MOD_P);
    alan_yukle(ALN_GX_MONT,    P192_GX_MONT);
    alan_yukle(ALN_GY_MONT,    P192_GY_MONT);
    alan_yukle(ALN_B_MONT,     P192_B_MONT);
    alan_yukle(ALN_N_ORDER,    P192_N_ORDER);
    alan_yukle(ALN_MONT_BIR_N, P192_MONT_BIR_N);
    alan_yukle(ALN_R2N,        P192_R2N);
    uzunluk_yukle(P192_P_BIT, P192_N_BIT);
    kontrol("uzunluk yazarken de gecerli dustu", c_gecerli === 1'b0);
    uygula_ver();

    kontrol("P-192: P",          c_p          === P192_P);
    kontrol("P-192: R_MOD_P",    c_r_mod_p    === P192_R_MOD_P);
    kontrol("P-192: GX_MONT",    c_gx_mont    === P192_GX_MONT);
    kontrol("P-192: GY_MONT",    c_gy_mont    === P192_GY_MONT);
    kontrol("P-192: B_MONT",     c_b_mont     === P192_B_MONT);
    kontrol("P-192: N_ORDER",    c_n_order    === P192_N_ORDER);
    kontrol("P-192: MONT_BIR_N", c_mont_bir_n === P192_MONT_BIR_N);
    kontrol("P-192: R2N",        c_r2n        === P192_R2N);
    kontrol("P-192: p_bit=192",  c_p_bit_uzunluk === P192_P_BIT);
    kontrol("P-192: n_bit=192",  c_n_bit_uzunluk === P192_N_BIT);
    kontrol("P-192: gecerli=1",  c_gecerli === 1'b1);

    // ── E) Bilinmeyen alan_id: sessizce yok sayilmali ─────────────────────
    $display("\n SENARYO E — bilinmeyen alan_id (4'd9) yok sayilir");
    alan_yukle(4'd9, 256'hFFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF);
    uygula_ver();
    kontrol("P-192 degerleri BOZULMADI (P)",       c_p          === P192_P);
    kontrol("P-192 degerleri BOZULMADI (N_ORDER)", c_n_order    === P192_N_ORDER);
    kontrol("P-192 degerleri BOZULMADI (R2N)",     c_r2n        === P192_R2N);

    // ── D) Varsayilana donus: P-192'den P-256'ya TEK darbede ─────────────
    $display("\n SENARYO D — varsayilana donus (P-192 -> P-256)");
    varsayilana_don_ver();
    kontrol_p256_varsayilan("varsayilana-donus");

    // ── ÖZET ─────────────────────────────────────────────────────────────
    $display("");
    $display("==================================================================");
    $display(" OZET:  %0d gecti / %0d kaldi   (toplam %0d dogrulama)",
             gecen_r, kalan_r, gecen_r + kalan_r);
    if (kalan_r == 0) $display(" SONUC: *** TB-24 BASARILI ***");
    else              $display(" SONUC: *** TB-24 BASARISIZ — %0d kaldi ***", kalan_r);
    $display("==================================================================");
    $display("");
    $finish;
end

initial begin
    #(SAAT_PERIYOT * 200_000);
    $display(" !! TB-24 GENEL ZAMAN ASIMI");
    $finish;
end

endmodule
