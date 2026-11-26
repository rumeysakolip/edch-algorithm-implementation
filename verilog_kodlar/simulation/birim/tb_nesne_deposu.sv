// =============================================================================
// Modül   : tb_nesne_deposu.sv                                        (TB-15)
// Proje   : FPGA Tabanlı Güvenli Anahtar Yönetimi ve Kripto Hızlandırıcı (5260007)
// -----------------------------------------------------------------------------
// AMAÇ:
//   nesne_deposu.v'nin sertifika/trust anchor saklama görevini doğru ve
//   GÜVENLİ yaptığını kanıtlamak. Bu modülde fonksiyonel doğruluk kadar
//   REDDETME davranışı da kritiktir: sınır aşımının kırpılarak kabul edilmesi
//   veya kilidin açılabilmesi, tek başına tüm güven zincirini çökertir.
//
// -----------------------------------------------------------------------------
// KAPSANAN SENARYOLAR:
//   A) Yaz/oku turu       : yazılan word'ler bit-birebir geri okunur.
//   B) Slot yalıtımı      : bir slota yazmak komşu slotları BOZMAMALI.
//                           Sabit slot adreslemesinde en olası hata, taban
//                           adres hesabının kayması ve komşu nesnenin (trust
//                           anchor!) üzerine yazılmasıdır.
//   C) Uzunluk anlambilimi: 4'ün katı OLMAYAN gerçek uzunluk (743 bayt gibi)
//                           doğru saklanmalı. Hat üzerindeki 4-hizalama ile
//                           nesnenin gerçek boyu farklı şeylerdir.
//   D) Sınır aşımı        : uzunluk > SLOT_BAYT REDDEDİLMELİ, kırpılmamalı.
//                           Kırpma kabul edilseydi taşan yazma komşu slota
//                           sızardı.
//   E) Kilit              : kilitli slota yazma reddedilir; kilit HİÇBİR
//                           komutla açılamaz; kilitli slot hâlâ OKUNABİLİR
//                           (sertifika gizli değildir, değiştirilemez olmalıdır).
//   F) Geçersiz FileID    : slot aralığı dışındaki ID sessizce maskelenmez,
//                           reddedilir. Maskelense FileID=5 → slot 1'e yazardı.
//   G) Reset              : reset sonrası tüm üst veri temiz olmalı.
//
// ÇALIŞTIRMA (Vivado xsim):
//   xvlog -sv tb_nesne_deposu.sv
//   xvlog nesne_deposu.v
//   xelab -debug typical tb_nesne_deposu -s sim_nd2
//   xsim sim_nd2 -R
//
// Standart : SystemVerilog-2012
// Tarih    : Temmuz 2026
// =============================================================================

`timescale 1ns / 1ps

module tb_nesne_deposu;

localparam real SAAT_PERIYOT = 10.0;

localparam int SLOT_SAY  = 4;
localparam int SLOT_BAYT = 1024;
localparam int SLOT_WORD = SLOT_BAYT / 4;
localparam int WADR_BIT  = 8;
localparam int UZUN_BIT  = 11;

// Hata kodları (nesne_deposu.v ile aynı)
localparam logic [1:0] HK_YOK = 2'd0, HK_GECERSIZ = 2'd1,
                       HK_KILITLI = 2'd2, HK_SINIR = 2'd3;

// FileID atamaları — drawio Akış 1 ile eşleşir
localparam logic [7:0] ID_SERTIFIKA   = 8'd0;   // adım 9  : cihaz sertifikası
localparam logic [7:0] ID_TRUST       = 8'd1;   // adım 10 : trust anchor
localparam logic [7:0] ID_SERBEST     = 8'd2;
localparam logic [7:0] ID_GECERSIZ    = 8'd7;   // slot aralığı dışında

logic saat = 1'b0;
logic sifirla_n = 1'b0;
always #(SAAT_PERIYOT/2.0) saat = ~saat;

// ── DUT bağlantıları ──────────────────────────────────────────────────────
logic [7:0]          g_id;
logic [WADR_BIT-1:0] g_word_adr;
logic [31:0]         g_yaz_word;
logic                g_yaz_vld, g_oku_vld;
logic [UZUN_BIT-1:0] g_uzunluk;
logic                g_uzunluk_vld, g_kilitle;

wire [31:0]          c_oku_word;
wire                 c_oku_hazir;
wire [UZUN_BIT-1:0]  c_uzunluk;
wire                 c_kilit, c_gecerli, c_hata;
wire [1:0]           c_hata_kod;

nesne_deposu #(
    .SLOT_SAY(SLOT_SAY), .SLOT_BAYT(SLOT_BAYT),
    .SLOT_WORD(SLOT_WORD), .WADR_BIT(WADR_BIT), .UZUN_BIT(UZUN_BIT)
) dut (
    .g_saat(saat), .g_sifirla_n(sifirla_n),
    .g_id(g_id), .g_word_adr(g_word_adr),
    .g_yaz_word(g_yaz_word), .g_yaz_vld(g_yaz_vld), .g_oku_vld(g_oku_vld),
    .c_oku_word(c_oku_word), .c_oku_hazir(c_oku_hazir),
    .g_uzunluk(g_uzunluk), .g_uzunluk_vld(g_uzunluk_vld), .g_kilitle(g_kilitle),
    .c_uzunluk(c_uzunluk), .c_kilit(c_kilit), .c_gecerli(c_gecerli),
    .c_hata(c_hata), .c_hata_kod(c_hata_kod)
);

// ── Puan tablosu ──────────────────────────────────────────────────────────
int gecen_r = 0, kalan_r = 0;

task automatic kontrol(input string ad, input logic kosul);
    if (kosul) begin
        $display("   gecti   %s", ad);
        gecen_r++;
    end else begin
        $display("   KALDI   %s   <<<", ad);
        kalan_r++;
    end
endtask

// ── Sürücü görevleri ──────────────────────────────────────────────────────
task automatic bosalt();
    g_yaz_vld = 1'b0; g_oku_vld = 1'b0;
    g_uzunluk_vld = 1'b0; g_kilitle = 1'b0;
endtask

task automatic word_yaz(input logic [7:0] id,
                        input logic [WADR_BIT-1:0] adr,
                        input logic [31:0] veri);
    @(negedge saat);
    g_id = id; g_word_adr = adr; g_yaz_word = veri; g_yaz_vld = 1'b1;
    @(negedge saat);
    bosalt();
endtask

task automatic word_oku(input  logic [7:0] id,
                        input  logic [WADR_BIT-1:0] adr,
                        output logic [31:0] veri);
    @(negedge saat);
    g_id = id; g_word_adr = adr; g_oku_vld = 1'b1;
    @(negedge saat);
    bosalt();
    // BRAM çıkışı kayıtlı → sonuç bir sonraki çevrimde hazır
    @(posedge saat);
    veri = c_oku_word;
endtask

task automatic uzunluk_yaz(input logic [7:0] id, input logic [UZUN_BIT-1:0] uz);
    @(negedge saat);
    g_id = id; g_uzunluk = uz; g_uzunluk_vld = 1'b1;
    @(negedge saat);
    bosalt();
endtask

task automatic kilitle(input logic [7:0] id);
    @(negedge saat);
    g_id = id; g_kilitle = 1'b1;
    @(negedge saat);
    bosalt();
endtask

// Bir istek sırasında c_hata / c_hata_kod yakalar.
task automatic hata_yakala_uzunluk(input logic [7:0] id,
                                   input logic [UZUN_BIT-1:0] uz,
                                   output logic h, output logic [1:0] hk);
    @(negedge saat);
    g_id = id; g_uzunluk = uz; g_uzunluk_vld = 1'b1;
    @(posedge saat);
    #1 h = c_hata; hk = c_hata_kod;
    @(negedge saat);
    bosalt();
endtask

task automatic hata_yakala_yazma(input logic [7:0] id,
                                 input logic [WADR_BIT-1:0] adr,
                                 input logic [31:0] veri,
                                 output logic h, output logic [1:0] hk);
    @(negedge saat);
    g_id = id; g_word_adr = adr; g_yaz_word = veri; g_yaz_vld = 1'b1;
    @(posedge saat);
    #1 h = c_hata; hk = c_hata_kod;
    @(negedge saat);
    bosalt();
endtask

// ── Sahte sertifika üreteci (tekrar üretilebilir sözde-rastgele) ─────────
function automatic logic [31:0] sahte_veri(input int id, input int adr);
    return 32'hC0DE_0000 ^ (id << 24) ^ (adr * 32'h9E37_79B9);
endfunction

// ═════════════════════════════════════════════════════════════════════════
//  ANA AKIŞ
// ═════════════════════════════════════════════════════════════════════════
logic [31:0] okunan;
logic        h;
logic [1:0]  hk;
logic        tum_dogru;

initial begin
    g_id = 8'd0; g_word_adr = '0; g_yaz_word = 32'd0; g_uzunluk = '0;
    bosalt();

    $display("");
    $display("==================================================================");
    $display(" TB-15  nesne_deposu.v  —  ikili nesne deposu (sertifika/trust)");
    $display(" %0d slot x %0d bayt = %0d bayt toplam", SLOT_SAY, SLOT_BAYT,
             SLOT_SAY*SLOT_BAYT);
    $display("==================================================================");

    repeat (5) @(posedge saat);
    sifirla_n = 1'b1;
    repeat (5) @(posedge saat);

    // ── G) Reset sonrası temiz durum ─────────────────────────────────────
    $display("\n SENARYO G — reset sonrasi temiz durum");
    @(negedge saat); g_id = ID_SERTIFIKA; @(posedge saat); #1;
    kontrol("slot 0: uzunluk 0", c_uzunluk == '0);
    kontrol("slot 0: kilit acik", c_kilit == 1'b0);
    kontrol("slot 0: gecerli degil", c_gecerli == 1'b0);
    @(negedge saat); g_id = ID_TRUST; @(posedge saat); #1;
    kontrol("slot 1: kilit acik", c_kilit == 1'b0);

    // ── A) Yaz/oku turu ──────────────────────────────────────────────────
    $display("\n SENARYO A — yaz / oku turu (sertifika slotu)");
    for (int a = 0; a < 32; a++)
        word_yaz(ID_SERTIFIKA, a[WADR_BIT-1:0], sahte_veri(ID_SERTIFIKA, a));
    tum_dogru = 1'b1;
    for (int a = 0; a < 32; a++) begin
        word_oku(ID_SERTIFIKA, a[WADR_BIT-1:0], okunan);
        if (okunan !== sahte_veri(ID_SERTIFIKA, a)) begin
            $display("     adr=%0d beklenen=%08h okunan=%08h", a,
                     sahte_veri(ID_SERTIFIKA, a), okunan);
            tum_dogru = 1'b0;
        end
    end
    kontrol("32 word bit-birebir geri okundu", tum_dogru);

    // Slot sonu sınır word'ü de çalışmalı
    word_yaz(ID_SERTIFIKA, SLOT_WORD-1, 32'hDEAD_BEEF);
    word_oku(ID_SERTIFIKA, SLOT_WORD-1, okunan);
    kontrol("son word (slot siniri) yazilip okundu", okunan === 32'hDEAD_BEEF);

    // ── B) Slot yalıtımı ─────────────────────────────────────────────────
    $display("\n SENARYO B — slot yalitimi (trust anchor korunuyor mu)");
    for (int a = 0; a < 32; a++)
        word_yaz(ID_TRUST, a[WADR_BIT-1:0], sahte_veri(ID_TRUST, a));
    // Sertifika slotu bozuldu mu?
    tum_dogru = 1'b1;
    for (int a = 0; a < 32; a++) begin
        word_oku(ID_SERTIFIKA, a[WADR_BIT-1:0], okunan);
        if (okunan !== sahte_veri(ID_SERTIFIKA, a)) tum_dogru = 1'b0;
    end
    kontrol("slot 1'e yazmak slot 0'i BOZMADI", tum_dogru);
    // Trust slotu doğru mu?
    tum_dogru = 1'b1;
    for (int a = 0; a < 32; a++) begin
        word_oku(ID_TRUST, a[WADR_BIT-1:0], okunan);
        if (okunan !== sahte_veri(ID_TRUST, a)) tum_dogru = 1'b0;
    end
    kontrol("slot 1 kendi verisini dogru tutuyor", tum_dogru);
    // Yazılmamış slot 2 temiz mi (sertifika verisi sızmamış mı)
    word_oku(ID_SERBEST, 8'd0, okunan);
    kontrol("slot 2'de slot 0/1 verisi YOK",
            okunan !== sahte_veri(ID_SERTIFIKA, 0) &&
            okunan !== sahte_veri(ID_TRUST, 0));

    // ── C) Uzunluk anlambilimi ───────────────────────────────────────────
    $display("\n SENARYO C — gercek uzunluk (4'un kati olmayan)");
    uzunluk_yaz(ID_SERTIFIKA, 11'd743);      // tipik DER sertifika boyu
    @(negedge saat); g_id = ID_SERTIFIKA; @(posedge saat); #1;
    kontrol("uzunluk 743 saklandi (4'un kati degil)", c_uzunluk == 11'd743);
    kontrol("nesne artik gecerli", c_gecerli == 1'b1);

    uzunluk_yaz(ID_SERTIFIKA, 11'd1024);     // tam slot boyu — sinirda gecerli
    @(negedge saat); g_id = ID_SERTIFIKA; @(posedge saat); #1;
    kontrol("uzunluk 1024 (tam sinir) KABUL", c_uzunluk == 11'd1024);

    // ── D) Sınır aşımı ───────────────────────────────────────────────────
    $display("\n SENARYO D — sinir asimi REDDEDILMELI (kirpilmamali)");
    hata_yakala_uzunluk(ID_SERTIFIKA, 11'd1025, h, hk);
    kontrol("uzunluk 1025 -> hata bayragi", h === 1'b1);
    kontrol("hata kodu = SINIR", hk === HK_SINIR);
    @(negedge saat); g_id = ID_SERTIFIKA; @(posedge saat); #1;
    kontrol("eski uzunluk (1024) KORUNDU — kirpilmadi", c_uzunluk == 11'd1024);

    // ── F) Geçersiz FileID ───────────────────────────────────────────────
    $display("\n SENARYO F — gecersiz FileID sessizce maskelenmemeli");
    hata_yakala_yazma(ID_GECERSIZ, 8'd0, 32'hBADC_0DE1, h, hk);
    kontrol("FileID=7 yazma -> hata bayragi", h === 1'b1);
    kontrol("hata kodu = GECERSIZ", hk === HK_GECERSIZ);
    // FileID=7, maskelenseydi 7 & 2'b11 = 3 -> slot 3'e yazardi
    word_oku(8'd3, 8'd0, okunan);
    kontrol("slot 3'e SIZMA yok (7 -> 3 maskelenmemis)", okunan !== 32'hBADC_0DE1);
    // Geçersiz ID'de üst veri çöp değil, sıfır dönmeli
    @(negedge saat); g_id = ID_GECERSIZ; @(posedge saat); #1;
    kontrol("gecersiz ID'de uzunluk 0 doner", c_uzunluk == '0);
    kontrol("gecersiz ID'de kilit 0 doner", c_kilit == 1'b0);

    // ── E) Kilit ─────────────────────────────────────────────────────────
    $display("\n SENARYO E — trust anchor yazma kilidi");
    uzunluk_yaz(ID_TRUST, 11'd512);
    kilitle(ID_TRUST);
    @(negedge saat); g_id = ID_TRUST; @(posedge saat); #1;
    kontrol("slot 1 kilitlendi", c_kilit === 1'b1);

    // Kilitli slota yazma reddedilmeli
    hata_yakala_yazma(ID_TRUST, 8'd0, 32'hAAAA_5555, h, hk);
    kontrol("kilitli slota yazma -> hata bayragi", h === 1'b1);
    kontrol("hata kodu = KILITLI", hk === HK_KILITLI);
    word_oku(ID_TRUST, 8'd0, okunan);
    kontrol("kilitli slot verisi DEGISMEDI",
            okunan === sahte_veri(ID_TRUST, 0));

    // Kilitli slotun uzunluğu da değiştirilememeli
    hata_yakala_uzunluk(ID_TRUST, 11'd999, h, hk);
    kontrol("kilitli slotta uzunluk degisimi -> hata", h === 1'b1);
    @(negedge saat); g_id = ID_TRUST; @(posedge saat); #1;
    kontrol("kilitli slot uzunlugu (512) korundu", c_uzunluk == 11'd512);

    // *** EN KRITIK KONTROL: kilit ACILAMAMALI ***
    //   Kilidi acan bir yol varsa trust anchor garantisi yoktur. Burada
    //   mevcut TUM giris kombinasyonlari denenir; hicbiri kilidi dusurmemeli.
    kilitle(ID_TRUST);                       // tekrar kilitle
    uzunluk_yaz(ID_TRUST, 11'd0);            // uzunlugu sifirlamayi dene
    word_yaz(ID_TRUST, 8'd0, 32'd0);         // sifir yazmayi dene
    repeat (10) @(posedge saat);
    @(negedge saat); g_id = ID_TRUST; @(posedge saat); #1;
    kontrol("*** kilit hicbir komutla ACILMADI ***", c_kilit === 1'b1);
    kontrol("kilitli slot HALA OKUNABILIR (sertifika gizli degil)",
            c_uzunluk == 11'd512);

    // Kilitli slot komşusunu etkilemedi mi
    word_oku(ID_SERTIFIKA, 8'd0, okunan);
    kontrol("kilit slot 0'i etkilemedi",
            okunan === sahte_veri(ID_SERTIFIKA, 0));

    // ── ÖZET ─────────────────────────────────────────────────────────────
    $display("");
    $display("==================================================================");
    $display(" OZET:  %0d gecti / %0d kaldi   (toplam %0d kontrol)",
             gecen_r, kalan_r, gecen_r + kalan_r);
    if (kalan_r == 0)
        $display(" SONUC: *** TB-15 BASARILI ***");
    else
        $display(" SONUC: *** TB-15 BASARISIZ — %0d kontrol kaldi ***", kalan_r);
    $display("==================================================================");
    $display("");
    $finish;
end

// Emniyet kilidi
initial begin
    #(SAAT_PERIYOT * 500_000);
    $display(" !! TB GENEL ZAMAN ASIMI");
    $finish;
end

endmodule
