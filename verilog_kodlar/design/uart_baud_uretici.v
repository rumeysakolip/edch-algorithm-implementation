// =============================================================================
// Modül   : uart_baud_uretici.v                                    (İster M-01)
// Proje   : FPGA Tabanlı Güvenli Anahtar Yönetimi ve Kripto Hızlandırıcı (5260007)
// -----------------------------------------------------------------------------
// Açıklama:
//   Sistem saatinden (100 MHz) UART için 16x aşırı-örnekleme (oversampling)
//   darbesi üretir. Hem uart_rx hem uart_tx bu tek kaynağı kullanır; böylece
//   iki uçta ayrı bölücü tutmaktan doğan sapma riski ortadan kalkar.
//
//   c_ort_tik: BOLUCU saat çevriminde bir kez, TEK saat genişliğinde yükselir.
//   16 adet c_ort_tik = 1 bit süresi.
//
// Parametre notu (İster K-02):
//   Varsayılan 115200 baud @ 100 MHz  → BOLUCU = 100e6/(115200*16) = 54.25 → 54
//   Gerçekleşen baud = 100e6/(54*16)  = 115740.7  → hata = +%0.47
//   8N1'de toplam hata bütçesi ~%2'dir (10 bit boyunca kümülatif), bu değer
//   güvenli paydadır. Karşı taraf %0 sapmalı olsa bile sorun çıkmaz.
//
//   SİMÜLASYON: BAUD_HIZI'nı üst modülden büyütün (örn. 12_500_000 → BOLUCU=1).
//   115200'de tek bir 64 baytlık çerçeve ~5.5 ms sim süresi tüketir.
//
// Kabul kriteri (TB-01):
//   Ölçülen tik periyodu teorik değerden < %0.5 sapmalı.
//
// Standart : Verilog-2001 — sentezlenebilir, latch üretmez
// Tarih    : Temmuz 2026
// =============================================================================

`timescale 1ns / 1ps

module uart_baud_uretici #(
    parameter integer SAAT_HZ   = 100_000_000,   // sistem saati
    parameter integer BAUD_HIZI = 115_200,       // hedef baud
    parameter integer ORNEKLEME = 16             // aşırı-örnekleme katsayısı
)(
    input  wire g_saat,
    input  wire g_sifirla_n,     // asenkron, aktif-DÜŞÜK
    output wire c_ort_tik        // 16x baud darbesi (1 saat genişliğinde)
);

// ── Bölücü hesabı (sentez sırasında sabit katlanır) ────────────────────────
//   +ORNEKLEME*BAUD_HIZI/2 terimi en yakına yuvarlama içindir (kırpma değil).
localparam integer BOLUCU =
    (SAAT_HZ + (ORNEKLEME * BAUD_HIZI) / 2) / (ORNEKLEME * BAUD_HIZI);

// Sayaç genişliği: BOLUCU-1'e kadar saymak yeterli.
localparam integer SAYAC_GEN = (BOLUCU <= 1) ? 1 : $clog2(BOLUCU);

// Karşılaştırma sabiti — boyutlandırılmış (integer/reg işaret karışıklığını önler)
localparam [SAYAC_GEN-1:0] SON_DEGER = BOLUCU - 1;

// ── Derleme zamanı kontrolleri ────────────────────────────────────────────
// synthesis translate_off
initial begin
    if (BOLUCU < 1) begin
        $display("HATA [uart_baud_uretici]: BOLUCU=%0d < 1. ", BOLUCU,
                 "BAUD_HIZI (%0d) sistem saati (%0d) icin cok yuksek.",
                 BAUD_HIZI, SAAT_HZ);
        $finish;
    end
end
// synthesis translate_on

// ── Serbest koşan bölücü sayacı ───────────────────────────────────────────
reg [SAYAC_GEN-1:0] sayac_r;
reg                 tik_r;

always @(posedge g_saat or negedge g_sifirla_n) begin
    if (!g_sifirla_n) begin
        sayac_r <= {SAYAC_GEN{1'b0}};
        tik_r   <= 1'b0;
    end else if (sayac_r == SON_DEGER) begin
        sayac_r <= {SAYAC_GEN{1'b0}};
        tik_r   <= 1'b1;                    // tek saat genişliğinde darbe
    end else begin
        sayac_r <= sayac_r + 1'b1;
        tik_r   <= 1'b0;
    end
end

assign c_ort_tik = tik_r;

endmodule
