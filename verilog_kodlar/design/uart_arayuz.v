// =============================================================================
// Modül   : uart_arayuz.v                                          (İster M-08)
// Proje   : FPGA Tabanlı Güvenli Anahtar Yönetimi ve Kripto Hızlandırıcı (5260007)
// -----------------------------------------------------------------------------
// Açıklama:
//   M-01..M-07'yi tek bir modülde birleştirir. Dışarıya YALNIZCA iki seri pin
//   ve temiz bir 32-bit komut/veri arayüzü gösterir. Üst katman (komut_yoneticisi)
//   UART'ın varlığından habersiz çalışabilir.
//
//   Zincir:
//     g_seri_rx -> uart_rx -> rx_fifo -> paket_cozucu -> c_komut / c_rx_word
//     c_seri_tx <- uart_tx <- tx_fifo <- paket_kurucu <- g_tx_word
//
// -----------------------------------------------------------------------------
// FIFO DERINLIKLERI — TX NEDEN 128:
//   Tam bir cerceve 64 veri + 4 ek = 68 BAYTTIR. TX FIFO 64 derinlikte olursa
//   cerceve sigmaz. paket_kurucu'nun geri basinci (g_bayt_hazir) bunu guvenli
//   kilar ama FIFO'yu 128 yapmak kurucuyu hic bekletmez ve TX'i surekli besler.
//   RX tarafinda cozucu her bayti aninda tuketir; 16 derinlik yeterlidir
//   (cozucu D_TESLIM'de en fazla 16 cevrim mesguldur, bir bayt ~540 cevrimde
//   gelir — cakisma pratikte imkansizdir, FIFO yine de sigortadir).
//
// -----------------------------------------------------------------------------
// FIFO ADAPTORLERI:
//   senk_fifo FWFT DEGILDIR — c_veri, g_oku'dan BIR saat sonra gecerlidir.
//   Bu yuzden her iki tarafta da kucuk bir okuma adaptoru vardir; okuma
//   darbesi bir cevrim geciktirilerek veri ile hizalanir.
//
// -----------------------------------------------------------------------------
// SAAT ALANI: Tek saat (g_saat). CDC YOKTUR (İster K-01).
//   g_seri_rx asenkrondur; senkronizasyon uart_rx icindedir.
//
// Kabul kriteri (TB-10):
//   Uctan uca echo; FIFO tikanma senaryosu; ardisik cerceveler.
//
// Standart : Verilog-2001 — sentezlenebilir, latch üretmez
// Tarih    : Temmuz 2026
// =============================================================================

`timescale 1ns / 1ps

module uart_arayuz #(
    parameter integer SAAT_HZ       = 100_000_000,
    parameter integer BAUD_HIZI     = 115_200,
    parameter integer ORNEKLEME     = 16,
    parameter integer AZAMI_VERI    = 64,
    parameter integer ZAMAN_ASIMI   = 5_000_000,   // ~50 ms @ 100 MHz
    parameter integer RX_DERINLIK   = 16,
    parameter integer TX_DERINLIK   = 128          // 68 baytlik cerceve icin
)(
    input  wire        g_saat,
    input  wire        g_sifirla_n,

    // ── Fiziksel seri pinler ──────────────────────────────────────────────
    input  wire        g_seri_rx,        // C4  (asenkron)
    output wire        c_seri_tx,        // D4

    // ── Alinan komut / veri (RX yolu) ─────────────────────────────────────
    output wire [7:0]  c_komut,
    output wire [7:0]  c_uzunluk,
    output wire        c_komut_gecerli,
    output wire [31:0] c_rx_word,
    output wire        c_rx_word_gecerli,
    output wire [3:0]  c_rx_indis,
    input  wire        g_rx_word_hazir,

    // ── Gonderilecek yanit (TX yolu) ──────────────────────────────────────
    input  wire        g_yanit_basla,
    input  wire [7:0]  g_yanit_durum,
    input  wire [7:0]  g_yanit_uzunluk,
    input  wire [31:0] g_tx_word,
    input  wire        g_tx_word_gecerli,
    output wire        c_tx_word_iste,

    // ── Durum / hata ──────────────────────────────────────────────────────
    output wire        c_mesgul,
    output wire [3:0]  c_hata            // {zaman_asimi, uzunluk, crc, cerceve}
);

// ═════════════════════════════════════════════════════════════════════════
//  ORTAK BAUD URETICI (M-01)
// ═════════════════════════════════════════════════════════════════════════
wire ort_tik_w;

uart_baud_uretici #(
    .SAAT_HZ(SAAT_HZ), .BAUD_HIZI(BAUD_HIZI), .ORNEKLEME(ORNEKLEME)
) baud_birim (
    .g_saat(g_saat), .g_sifirla_n(g_sifirla_n), .c_ort_tik(ort_tik_w)
);

// ═════════════════════════════════════════════════════════════════════════
//  RX YOLU :  uart_rx -> rx_fifo -> paket_cozucu
// ═════════════════════════════════════════════════════════════════════════
wire [7:0] rx_bayt_w;
wire       rx_gecerli_w;
wire       rx_cerceve_hata_w;

uart_rx #(.ORNEKLEME(ORNEKLEME)) rx_birim (
    .g_saat(g_saat), .g_sifirla_n(g_sifirla_n),
    .g_seri(g_seri_rx), .g_ort_tik(ort_tik_w),
    .c_veri(rx_bayt_w), .c_gecerli(rx_gecerli_w),
    .c_cerceve_hata(rx_cerceve_hata_w)
);

wire [7:0] rxf_veri_w;
wire       rxf_bos_w, rxf_dolu_w;
wire [$clog2(RX_DERINLIK):0] rxf_sayi_w;
reg        rxf_oku_r;

senk_fifo #(.GENISLIK(8), .DERINLIK(RX_DERINLIK)) rx_fifo (
    .g_saat(g_saat), .g_sifirla_n(g_sifirla_n),
    .g_yaz(rx_gecerli_w), .g_veri(rx_bayt_w),
    .g_oku(rxf_oku_r), .c_veri(rxf_veri_w),
    .c_bos(rxf_bos_w), .c_dolu(rxf_dolu_w), .c_sayi(rxf_sayi_w)
);

// ── RX okuma adaptoru ─────────────────────────────────────────────────────
//   senk_fifo senkron okur: c_veri, g_oku'dan 1 saat sonra gecerli.
//   coz_gecerli_r bu gecikmeyi telafi eder ve veri ile hizali darbe uretir.
reg coz_gecerli_r;

always @(posedge g_saat or negedge g_sifirla_n) begin
    if (!g_sifirla_n) begin
        rxf_oku_r     <= 1'b0;
        coz_gecerli_r <= 1'b0;
    end else begin
        coz_gecerli_r <= rxf_oku_r;          // veri ile hizali
        rxf_oku_r     <= 1'b0;
        // Bir okuma tamamlanmadan yenisi baslatilmaz
        if (!rxf_bos_w && !rxf_oku_r && !coz_gecerli_r)
            rxf_oku_r <= 1'b1;
    end
end

wire coz_crc_hata_w, coz_uzunluk_hata_w, coz_zaman_asimi_w, coz_mesgul_w;

paket_cozucu #(.AZAMI_VERI(AZAMI_VERI), .ZAMAN_ASIMI(ZAMAN_ASIMI)) cozucu_birim (
    .g_saat(g_saat), .g_sifirla_n(g_sifirla_n),
    .g_bayt(rxf_veri_w), .g_bayt_gecerli(coz_gecerli_r),
    .c_komut(c_komut), .c_uzunluk(c_uzunluk), .c_komut_gecerli(c_komut_gecerli),
    .c_word(c_rx_word), .c_word_gecerli(c_rx_word_gecerli),
    .c_word_indis(c_rx_indis), .g_word_hazir(g_rx_word_hazir),
    .c_crc_hata(coz_crc_hata_w), .c_uzunluk_hata(coz_uzunluk_hata_w),
    .c_zaman_asimi(coz_zaman_asimi_w), .c_mesgul(coz_mesgul_w)
);

// ═════════════════════════════════════════════════════════════════════════
//  TX YOLU :  paket_kurucu -> tx_fifo -> uart_tx
// ═════════════════════════════════════════════════════════════════════════
wire [7:0] kur_bayt_w;
wire       kur_bayt_gecerli_w;
wire       kur_mesgul_w;
wire       kur_uzunluk_hata_w;

wire [7:0] txf_veri_w;
wire       txf_bos_w, txf_dolu_w;
wire [$clog2(TX_DERINLIK):0] txf_sayi_w;
reg        txf_oku_r;

paket_kurucu #(.AZAMI_VERI(AZAMI_VERI)) kurucu_birim (
    .g_saat(g_saat), .g_sifirla_n(g_sifirla_n),
    .g_basla(g_yanit_basla), .g_durum(g_yanit_durum), .g_uzunluk(g_yanit_uzunluk),
    .c_word_iste(c_tx_word_iste), .g_word(g_tx_word), .g_word_gecerli(g_tx_word_gecerli),
    .c_bayt(kur_bayt_w), .c_bayt_gecerli(kur_bayt_gecerli_w),
    .g_bayt_hazir(~txf_dolu_w),          // GERI BASINC
    .c_mesgul(kur_mesgul_w), .c_uzunluk_hata(kur_uzunluk_hata_w)
);

senk_fifo #(.GENISLIK(8), .DERINLIK(TX_DERINLIK)) tx_fifo (
    .g_saat(g_saat), .g_sifirla_n(g_sifirla_n),
    .g_yaz(kur_bayt_gecerli_w), .g_veri(kur_bayt_w),
    .g_oku(txf_oku_r), .c_veri(txf_veri_w),
    .c_bos(txf_bos_w), .c_dolu(txf_dolu_w), .c_sayi(txf_sayi_w)
);

wire tx_mesgul_w;
reg  tx_basla_r;

// ── TX okuma adaptoru ─────────────────────────────────────────────────────
//   uart_tx bosta VE fifo dolu ise bir bayt cek; okuma gecikmesini telafi
//   etmek icin g_basla bir cevrim geciktirilir (veri ile hizali olur).
always @(posedge g_saat or negedge g_sifirla_n) begin
    if (!g_sifirla_n) begin
        txf_oku_r  <= 1'b0;
        tx_basla_r <= 1'b0;
    end else begin
        tx_basla_r <= txf_oku_r;             // veri ile hizali
        txf_oku_r  <= 1'b0;
        if (!txf_bos_w && !tx_mesgul_w && !txf_oku_r && !tx_basla_r)
            txf_oku_r <= 1'b1;
    end
end

uart_tx #(.ORNEKLEME(ORNEKLEME)) tx_birim (
    .g_saat(g_saat), .g_sifirla_n(g_sifirla_n),
    .g_veri(txf_veri_w), .g_basla(tx_basla_r), .g_ort_tik(ort_tik_w),
    .c_seri(c_seri_tx), .c_mesgul(tx_mesgul_w)
);

// ═════════════════════════════════════════════════════════════════════════
//  DURUM / HATA
// ═════════════════════════════════════════════════════════════════════════
//   Hata bayraklari 1 saat genisliginde DARBEDIR; ust katman yakalamalidir.
assign c_hata = { coz_zaman_asimi_w,
                  coz_uzunluk_hata_w | kur_uzunluk_hata_w,
                  coz_crc_hata_w,
                  rx_cerceve_hata_w };

//   Mesgul: herhangi bir yonde islem suruyor.
assign c_mesgul = coz_mesgul_w | kur_mesgul_w | tx_mesgul_w |
                  ~txf_bos_w   | ~rxf_bos_w;

endmodule
