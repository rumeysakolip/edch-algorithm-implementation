// =============================================================================
// Modül   : tb_anahtar_deposu.sv                                      (TB-16)
// Proje   : FPGA Tabanlı Güvenli Anahtar Yönetimi ve Kripto Hızlandırıcı (5260007)
// -----------------------------------------------------------------------------
// AMAÇ:
//   anahtar_deposu.v'nin iki şeyi birden yapmasını kanıtlamak:
//     (a) DOĞRU çalışması  — üretim, slot yalıtımı, politika, zeroize
//     (b) SIZDIRMAMASI     — özel anahtarın c_ozel_d dışında hiçbir çıkışta
//                            görünmemesi
//
//   (b) bu TB'nin asıl sebebidir. "Gizli anahtarı okuyan komut yok" bir
//   iddiadır; TB bunu ÖLÇER. Bilinen bir d slota yerleştirilir, sonra
//   modülün tüm diğer çıkışları d'nin her 32-bit dilimine karşı taranır.
//   Bir gün biri hata ayıklama amacıyla d'yi bir çıkışa bağlarsa bu test
//   kalır — kod incelemesinin gözden kaçırabileceği tam olarak budur.
//
// -----------------------------------------------------------------------------
// KAPSANAN SENARYOLAR:
//   A) Üretim turu       : TRNG'den anahtar üretilir, slot geçerli olur.
//   B) Slot yalıtımı     : bir slota üretim komşuyu BOZMAZ.
//   C) Politika bağlama  : politika üretimle aynı anda yazılır; izin sorgusu
//                          (c_izin_var) doğru cevap verir.
//   D) *** KALICI SLOT YENİDEN ÜRETİLEMEZ *** — cihaz kimliğinin sessizce
//      değiştirilmesini engeller. Reddedilmezse sertifika-anahtar bağı kopar.
//   E) Ayrılmış politika biti reddi (maskelenmiyor).
//   F) d ∈ [1, n−1] : d=0 ve d>=n adayları REDDEDİLİR, yeni aday çekilir.
//      Reddetme örneklemesi çalışıyor mu — indirgeme yapılmıyor mu.
//   G) ZEROIZE       : transient slotlar SİLİNİR (bayrak değil, malzeme),
//                      KALICI slot korunur.
//   H) *** SIZINTI TARAMASI *** — d hiçbir başka çıkışta görünmemeli.
//
// ÇALIŞTIRMA (Vivado xsim):
//   xvlog -sv tb_anahtar_deposu.sv
//   xvlog anahtar_deposu.v
//   xelab -debug typical tb_anahtar_deposu -s sim_ad
//   xsim sim_ad -R
//
// Standart : SystemVerilog-2012
// Tarih    : Temmuz 2026
// =============================================================================

`timescale 1ns / 1ps

module tb_anahtar_deposu;

localparam real SAAT_PERIYOT = 10.0;
localparam int  SLOT_SAY = 4;

localparam logic [255:0] N_ORDER =
    256'hffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551;

// Politika bitleri
localparam logic [7:0] POL_ECDH   = 8'b0000_0001,
                       POL_IMZA   = 8'b0000_0010,
                       POL_KALICI = 8'b0000_0100;

// Üretim hata kodlari
localparam logic [1:0] UH_YOK=2'd0, UH_KALICI=2'd1, UH_POLITIKA=2'd2, UH_SKALER=2'd3;

// Slot atamalari — drawio ile eslesir
localparam int SLOT_KIMLIK = 0;   // kalici cihaz kimlik anahtari
localparam int SLOT_EPH    = 1;   // gecici ECDHE anahtari

logic saat = 1'b0, sifirla_n = 1'b0;
always #(SAAT_PERIYOT/2.0) saat = ~saat;

// ── DUT bağlantıları ──────────────────────────────────────────────────────
logic [1:0]   g_slot;
logic         g_uret;
logic [7:0]   g_politika;
wire          c_uret_bitti, c_uret_hata;
wire  [1:0]   c_uret_hata_kod;
wire          c_trng_iste;
logic [31:0]  g_trng_word;
logic         g_trng_vld;
logic         g_acik_yaz;
logic [255:0] g_acik_x, g_acik_y;
wire  [255:0] c_acik_x, c_acik_y;
wire          c_acik_gecerli;
wire  [255:0] c_ozel_d;
wire          c_ozel_gecerli;
wire  [7:0]   c_politika;
wire          c_kalici;
logic [1:0]   g_kullanim;
wire          c_izin_var;
logic         g_zeroize;

anahtar_deposu #(.SLOT_SAY(SLOT_SAY), .ID_BIT(2)) dut (
    .g_saat(saat), .g_sifirla_n(sifirla_n),
    .g_slot(g_slot), .g_uret(g_uret), .g_politika(g_politika),
    .c_uret_bitti(c_uret_bitti), .c_uret_hata(c_uret_hata),
    .c_uret_hata_kod(c_uret_hata_kod),
    .c_trng_iste(c_trng_iste), .g_trng_word(g_trng_word), .g_trng_vld(g_trng_vld),
    .g_acik_yaz(g_acik_yaz), .g_acik_x(g_acik_x), .g_acik_y(g_acik_y),
    .c_acik_x(c_acik_x), .c_acik_y(c_acik_y), .c_acik_gecerli(c_acik_gecerli),
    .c_ozel_d(c_ozel_d), .c_ozel_gecerli(c_ozel_gecerli),
    .c_politika(c_politika), .c_kalici(c_kalici),
    .g_kullanim(g_kullanim), .c_izin_var(c_izin_var),
    .g_zeroize(g_zeroize),
    .g_n_order(g_n_order_tb),
    .g_n_bit_uzunluk(g_n_bit_uzunluk_tb)
);

// ── ÇOKLU EĞRİ DESTEĞİ (Temmuz 2026, İster M-24) ──────────────────────────
//   g_n_order / g_n_bit_uzunluk artık TB tarafından sürülür (eskiden sabit
//   P-256 literaliydi) ki SENARYO I bunları çalışma anında P-192'ye
//   değiştirip reddetme-örneklemesi maskelemesini test edebilsin.
logic [255:0] g_n_order_tb;
logic [9:0]   g_n_bit_uzunluk_tb;
localparam logic [255:0] P192_N_ORDER =
    256'h0000000000000000ffffffffffffffffffffffff99def836146bc9b1b4d22831;

// ── Puan tablosu ──────────────────────────────────────────────────────────
int gecen_r = 0, kalan_r = 0;
task automatic kontrol(input string ad, input logic kosul);
    if (kosul) begin $display("   gecti   %s", ad); gecen_r++; end
    else       begin $display("   KALDI   %s   <<<", ad); kalan_r++; end
endtask

// ── TRNG besleyici: sıradaki 8 word'ü TB belirler ────────────────────────
logic [255:0] trng_deger;
int           trng_idx;
logic         trng_aktif;

always @(posedge saat) begin
    g_trng_vld <= 1'b0;
    if (c_trng_iste && trng_aktif) begin
        g_trng_word <= trng_deger[trng_idx*32 +: 32];
        g_trng_vld  <= 1'b1;
        trng_idx    <= (trng_idx == 7) ? 0 : trng_idx + 1;
    end
end

task automatic trng_kur(input logic [255:0] v);
    trng_deger = v; trng_idx = 0; trng_aktif = 1'b1;
endtask

// ── Üretim görevi ─────────────────────────────────────────────────────────
task automatic uret(input int slot, input logic [7:0] pol,
                    output logic bitti, output logic hata, output logic [1:0] hk);
    int bek;
    @(negedge saat);
    g_slot = slot[1:0]; g_politika = pol; g_uret = 1'b1;
    @(negedge saat);
    g_uret = 1'b0;
    bitti = 0; hata = 0; hk = UH_YOK; bek = 0;
    forever begin
        @(posedge saat);
        bek++;
        if (c_uret_bitti) begin bitti = 1; break; end
        if (c_uret_hata)  begin hata = 1; hk = c_uret_hata_kod; break; end
        if (bek > 5000) begin
            $display("   !! uret() ZAMAN ASIMI (slot %0d)", slot); break;
        end
    end
    @(negedge saat);
endtask

task automatic slot_sec(input int slot);
    @(negedge saat); g_slot = slot[1:0]; @(posedge saat); #1;
endtask

// ── Sızıntı tarayıcı: d'nin 32-bit dilimlerini diğer çıkışlarda ara ──────
//   c_ozel_d HARİÇ tüm çıkışlar taranır. Bu, "d'yi okutan komut yok"
//   iddiasını ölçülebilir hâle getirir.
function automatic logic sizinti_var(input logic [255:0] d);
    logic [31:0] dilim;
    logic [255:0] toplu_x, toplu_y;
    sizinti_var = 1'b0;
    toplu_x = c_acik_x;
    toplu_y = c_acik_y;
    for (int w = 0; w < 8; w++) begin
        dilim = d[w*32 +: 32];
        if (dilim == 32'd0) continue;          // sifir dilim anlamsiz
        for (int b = 0; b < 8; b++) begin
            if (toplu_x[b*32 +: 32] == dilim) begin
                $display("     !! SIZINTI: d[%0d] c_acik_x[%0d] icinde", w, b);
                sizinti_var = 1'b1;
            end
            if (toplu_y[b*32 +: 32] == dilim) begin
                $display("     !! SIZINTI: d[%0d] c_acik_y[%0d] icinde", w, b);
                sizinti_var = 1'b1;
            end
        end
        if ({24'd0, c_politika} == dilim) begin
            $display("     !! SIZINTI: d[%0d] c_politika icinde", w);
            sizinti_var = 1'b1;
        end
    end
endfunction

// ═════════════════════════════════════════════════════════════════════════
//  ANA AKIŞ
// ═════════════════════════════════════════════════════════════════════════
logic bitti, hata;
logic [1:0] hk;
logic [255:0] d_kimlik, d_eph;

localparam logic [255:0] TEST_D1 = 256'h1111_2222_3333_4444_5555_6666_7777_8888_9999_aaaa_bbbb_cccc_dddd_eeee_ffff_0001;
localparam logic [255:0] TEST_D2 = 256'h0f0e_0d0c_0b0a_0908_0706_0504_0302_0100_f0e0_d0c0_b0a0_9080_7060_5040_3020_1000;

initial begin
    g_slot=0; g_uret=0; g_politika=0; g_trng_word=0; g_trng_vld=0;
    g_acik_yaz=0; g_acik_x=0; g_acik_y=0; g_kullanim=0; g_zeroize=0;
    trng_aktif=0; trng_idx=0; trng_deger=0;
    g_n_order_tb = N_ORDER; g_n_bit_uzunluk_tb = 10'd256;   // P-256 varsayilan

    $display("");
    $display("==================================================================");
    $display(" TB-16  anahtar_deposu.v  —  anahtar slotu ve politika");
    $display(" %0d slot | KALICILIK: oturum (guc kesilince kaybolur - bkz. baslik)",
             SLOT_SAY);
    $display("==================================================================");

    repeat (5) @(posedge saat);
    sifirla_n = 1'b1;
    repeat (5) @(posedge saat);

    // ── A) Kalici kimlik anahtari uretimi ────────────────────────────────
    $display("\n SENARYO A — kalici kimlik anahtari uretimi (slot 0)");
    trng_kur(TEST_D1);
    uret(SLOT_KIMLIK, POL_ECDH | POL_IMZA | POL_KALICI, bitti, hata, hk);
    kontrol("uretim tamamlandi", bitti && !hata);
    slot_sec(SLOT_KIMLIK);
    kontrol("ozel anahtar gecerli", c_ozel_gecerli === 1'b1);
    kontrol("uretilen d, TRNG degeriyle ayni", c_ozel_d === TEST_D1);
    kontrol("politika uretimle AYNI ANDA baglandi",
            c_politika === (POL_ECDH | POL_IMZA | POL_KALICI));
    kontrol("KALICI bayragi set", c_kalici === 1'b1);
    kontrol("acik anahtar henuz YOK", c_acik_gecerli === 1'b0);
    d_kimlik = c_ozel_d;

    // ── C) Politika izin sorgusu ─────────────────────────────────────────
    $display("\n SENARYO C — politika izin sorgusu");
    @(negedge saat); g_kullanim = 2'b01; @(posedge saat); #1;
    kontrol("ECDH izni VAR", c_izin_var === 1'b1);
    @(negedge saat); g_kullanim = 2'b10; @(posedge saat); #1;
    kontrol("IMZA izni VAR", c_izin_var === 1'b1);
    @(negedge saat); g_kullanim = 2'b00; @(posedge saat); #1;

    // ── Acik anahtar geri yazma ──────────────────────────────────────────
    @(negedge saat);
    g_acik_x = 256'hAAAA_0001; g_acik_y = 256'hBBBB_0001; g_acik_yaz = 1'b1;
    @(negedge saat); g_acik_yaz = 1'b0;
    slot_sec(SLOT_KIMLIK);
    kontrol("acik anahtar yazildi ve okunabiliyor",
            c_acik_gecerli === 1'b1 && c_acik_x === 256'hAAAA_0001);

    // ── B) Ikinci slot: gecici ECDHE anahtari ────────────────────────────
    $display("\n SENARYO B — gecici ECDHE anahtari (slot 1) + slot yalitimi");
    trng_kur(TEST_D2);
    uret(SLOT_EPH, POL_ECDH, bitti, hata, hk);       // KALICI DEGIL
    kontrol("transient uretim tamamlandi", bitti && !hata);
    slot_sec(SLOT_EPH);
    kontrol("slot 1 kendi d'sini tutuyor", c_ozel_d === TEST_D2);
    kontrol("slot 1 KALICI DEGIL", c_kalici === 1'b0);
    d_eph = c_ozel_d;
    @(negedge saat); g_kullanim = 2'b10; @(posedge saat); #1;
    kontrol("slot 1'de IMZA izni YOK (politika ECDH-only)", c_izin_var === 1'b0);
    @(negedge saat); g_kullanim = 2'b00; @(posedge saat); #1;

    slot_sec(SLOT_KIMLIK);
    kontrol("slot 1 uretimi slot 0'i BOZMADI", c_ozel_d === d_kimlik);
    kontrol("slot 0 acik anahtari korundu", c_acik_x === 256'hAAAA_0001);

    // ── D) *** KALICI SLOT YENIDEN URETILEMEZ *** ────────────────────────
    $display("\n SENARYO D — kalici slot yeniden uretilemez");
    trng_kur(256'hDEAD_BEEF_DEAD_BEEF_DEAD_BEEF_DEAD_BEEF_DEAD_BEEF_DEAD_BEEF_DEAD_BEEF_DEAD_BEEF);
    uret(SLOT_KIMLIK, POL_ECDH | POL_KALICI, bitti, hata, hk);
    kontrol("*** yeniden uretim REDDEDILDI ***", hata && !bitti);
    kontrol("hata kodu = KALICI", hk === UH_KALICI);
    slot_sec(SLOT_KIMLIK);
    kontrol("kimlik anahtari DEGISMEDI", c_ozel_d === d_kimlik);
    kontrol("politika da DEGISMEDI",
            c_politika === (POL_ECDH | POL_IMZA | POL_KALICI));

    // Transient slot ise yeniden uretilebilmeli
    trng_kur(256'h1234_5678_1234_5678_1234_5678_1234_5678_1234_5678_1234_5678_1234_5678_1234_5678);
    uret(SLOT_EPH, POL_ECDH, bitti, hata, hk);
    kontrol("transient slot yeniden URETILEBILIR", bitti && !hata);

    // ── E) Ayrilmis politika biti reddi ──────────────────────────────────
    $display("\n SENARYO E — ayrilmis politika biti");
    trng_kur(TEST_D2);
    uret(2, 8'b1000_0001, bitti, hata, hk);   // bit7 ayrilmis
    kontrol("ayrilmis bit -> uretim REDDEDILDI", hata && !bitti);
    kontrol("hata kodu = POLITIKA", hk === UH_POLITIKA);
    slot_sec(2);
    kontrol("slot 2 yazilmadi (sessizce maskelenmedi)", c_ozel_gecerli === 1'b0);

    // ── F) d in [1, n-1] reddetme ornekleme ──────────────────────────────
    $display("\n SENARYO F — d in [1, n-1] reddetme ornekleme");
    //   TRNG once d=0 verir; DUT reddedip yeni aday istemeli. TB ikinci
    //   turda gecerli deger besler.
    trng_kur(256'd0);
    fork
        begin
            uret(3, POL_ECDH, bitti, hata, hk);
        end
        begin
            // Ilk 8 word alindiktan sonra gecerli degere gec
            repeat (30) @(posedge saat);
            trng_kur(TEST_D1);
        end
    join
    kontrol("d=0 reddedildi, yeni aday ile uretim BASARILI", bitti && !hata);
    slot_sec(3);
    kontrol("slotta sifir DEGIL, gecerli d var", c_ozel_d !== 256'd0);

    //   d >= n adayi: n'in kendisi. Reddedilmeli.
    trng_kur(N_ORDER);
    fork
        begin
            uret(2, POL_ECDH, bitti, hata, hk);
        end
        begin
            repeat (30) @(posedge saat);
            trng_kur(TEST_D2);
        end
    join
    kontrol("d = n reddedildi, yeni aday ile uretim BASARILI", bitti && !hata);
    slot_sec(2);
    kontrol("slotta n DEGIL (indirgeme YAPILMADI)", c_ozel_d !== N_ORDER);

    // ── H) *** SIZINTI TARAMASI *** ──────────────────────────────────────
    $display("\n SENARYO H — ozel anahtar sizinti taramasi");
    slot_sec(SLOT_KIMLIK);
    kontrol("*** d hicbir diger cikista GORUNMUYOR ***", !sizinti_var(d_kimlik));
    slot_sec(SLOT_EPH);
    kontrol("transient d de sizmiyor", !sizinti_var(c_ozel_d));

    // ── I) COKLU EGRI: P-192 reddetme-orneklemesi maskeleme (Istek M-24) ──
    //   Duzeltme oncesi: aday_r HER ZAMAN 256 bit uretilir; P-192'de n
    //   yalnizca 192 bit oldugundan ham 256-bit bir adayin n'den kucuk
    //   cikma olasiligi ~2^-64'tur — DENEME_MAX=8 bunu ASLA karsilamaz.
    //   Duzeltme: aday_maskeli_w = aday_r & bit_maske_w, ust (256-n_bit)
    //   bit sifirlanir. Bu TB, TRNG'nin UST 64 bitine (word6,7) kasitli
    //   olarak COP (garbage) koyar; eger maskeleme calismiyorsa uretilen
    //   ozel anahtarin ust 64 biti SIFIR OLMAZDI.
    $display("\n SENARYO I — coklu egri: P-192 reddetme-orneklemesi maskeleme");
    g_n_order_tb       = P192_N_ORDER;
    g_n_bit_uzunluk_tb = 10'd192;

    // word0=32'h0000_0001 (dusuk anlamli, acikca n'den kucuk), word1..5=0,
    // word6/word7 = COP (256-192=64 bit -> tam olarak bu iki sozcuk).
    // Maskeleme CALISIYORSA: aday_maskeli_w = 256'h...0000_0001 (ust temiz).
    trng_kur({32'hDEAD_BEEF, 32'hFEED_FACE,             // word7, word6 = COP
              32'h0, 32'h0, 32'h0, 32'h0, 32'h0,        // word5..word1 = 0
              32'h0000_0001});                          // word0
    uret(3, POL_ECDH, bitti, hata, hk);
    kontrol("P-192 maskeli aday ile uretim BASARILI", bitti && !hata);
    slot_sec(3);
    kontrol("*** ust 64 bit MASKELENDI (cop sizmadi) ***",
            c_ozel_d[255:192] === 64'd0);
    kontrol("alt 192 bit HAM TRNG degeriyle ayni", c_ozel_d[191:0] === 192'd1);

    // Maskelenmis aday n'in KENDISINE esit olursa (d==n) reddedilmeli —
    // ust 64 bit yine COP, alt 192 bit TAM OLARAK P192_N_ORDER.
    trng_kur({32'hAAAA_AAAA, 32'hBBBB_BBBB, P192_N_ORDER[191:0]});
    fork
        begin
            uret(2, POL_ECDH, bitti, hata, hk);
        end
        begin
            // Sabit cevrim sayisi ile bekleme (repeat(N)) KIRILGANDIR: ilk
            // aday TUM 8 kelimesi esit oldugu icin U_CMP'nin EN KOTU
            // durumunu (cmp_idx 7->0, 8 cevrim) tetikler; TRNG yukleme +
            // bu 8 cevrim toplami sabit bir sayiyla YARISABILIR. Bunun
            // yerine DUT'un GERCEK reddetme anini (deneme_r'nin 0'dan
            // 1'e cikisi) hiyerarsik referansla (dut.deneme_r) bekleriz —
            // boylece anahtar_deposu.v'nin ic FSM zamanlamasi degisse bile
            // TB kirilmaz.
            wait (dut.deneme_r == 4'd1);
            trng_kur({32'hCCCC_CCCC, 32'hDDDD_DDDD,
                      32'h0, 32'h0, 32'h0, 32'h0, 32'h0, 32'h0000_0002});
        end
    join
    kontrol("maskeli d==n reddedildi, yeni aday ile uretim BASARILI",
            bitti && !hata);
    slot_sec(2);
    kontrol("slotta n DEGIL, maskeli 2 var",
            c_ozel_d === 256'd2 && c_ozel_d[255:192] === 64'd0);

    // Sonraki senaryolar P-256 varsayimiyla yazildigi icin egriyi geri al.
    g_n_order_tb       = N_ORDER;
    g_n_bit_uzunluk_tb = 10'd256;

    // ── G) ZEROIZE ───────────────────────────────────────────────────────
    $display("\n SENARYO G — zeroize: transient siler, KALICI korur");
    @(negedge saat); g_zeroize = 1'b1;
    @(negedge saat); g_zeroize = 1'b0;
    repeat (3) @(posedge saat);

    slot_sec(SLOT_EPH);
    kontrol("transient slot gecersiz", c_ozel_gecerli === 1'b0);
    kontrol("transient d SIFIRLANDI (bayrak degil, malzeme)",
            c_ozel_d === 256'd0);
    kontrol("transient politika da temizlendi", c_politika === 8'd0);
    kontrol("transient acik anahtar temizlendi", c_acik_gecerli === 1'b0);

    slot_sec(SLOT_KIMLIK);
    kontrol("*** KALICI kimlik anahtari KORUNDU ***", c_ozel_d === d_kimlik);
    kontrol("kalici slot hala gecerli", c_ozel_gecerli === 1'b1);
    kontrol("kalici slot politikasi korundu",
            c_politika === (POL_ECDH | POL_IMZA | POL_KALICI));
    kontrol("kalici slot acik anahtari korundu", c_acik_x === 256'hAAAA_0001);

    // Zeroize sonrasi transient slot yeniden kullanilabilmeli
    trng_kur(TEST_D2);
    uret(SLOT_EPH, POL_ECDH, bitti, hata, hk);
    kontrol("zeroize sonrasi transient slot yeniden uretilebilir", bitti && !hata);

    // ── ÖZET ─────────────────────────────────────────────────────────────
    $display("");
    $display("==================================================================");
    $display(" OZET:  %0d gecti / %0d kaldi   (toplam %0d dogrulama)",
             gecen_r, kalan_r, gecen_r + kalan_r);
    if (kalan_r == 0) $display(" SONUC: *** TB-16 BASARILI ***");
    else              $display(" SONUC: *** TB-16 BASARISIZ — %0d kaldi ***", kalan_r);
    $display("==================================================================");
    $display("");
    $finish;
end

initial begin
    #(SAAT_PERIYOT * 2_000_000);
    $display(" !! TB-16 GENEL ZAMAN ASIMI");
    $finish;
end

endmodule
