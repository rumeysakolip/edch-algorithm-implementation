// =============================================================================
// Modül   : senk_fifo.v                                            (İster M-02)
// Proje   : FPGA Tabanlı Güvenli Anahtar Yönetimi ve Kripto Hızlandırıcı (5260007)
// -----------------------------------------------------------------------------
// Açıklama:
//   Parametrik senkron FIFO (tek saat alanı). UART (~11 KB/s) ile ECDH
//   çekirdeği (saat başına 1 word) arasındaki hız uçurumunu kapatır.
//
//   NEDEN ZORUNLU:
//     ecdh_kex_top, o_pkt_vld ile 8 word'ü ARDIŞIK saat çevrimlerinde basar.
//     uart_tx ise bir baytı ~87 us'de gönderir (115200 baud). FIFO olmadan
//     ilk bayt dışındaki her şey kaybolur. TX yolunda derinlik >= 64 olmalı
//     (64 bayt = bir tam koordinat çifti).
//
//   Uygulama: dairesel tampon + ayrı eleman sayacı (sayi_r).
//   Sayaç yaklaşımı, "bir slot boş bırak" yönteminin aksine tüm DERINLIK'i
//   kullanılabilir kılar ve dolu/boş ayrımı belirsizliğe düşmez.
//
//   Bellek çıkarımı: dizi 'reg' olarak tanımlıdır; Vivado küçük derinlikler
//   için dağıtık RAM (LUTRAM), büyük derinlikler için BRAM çıkarır.
//
// Koruma davranışı:
//   - Dolu iken g_yaz yok sayılır (mevcut veri BOZULMAZ)
//   - Boş iken g_oku yok sayılır (sahte veri üretilmez, sayaç eksiye düşmez)
//
// Okuma zamanlaması: FWFT DEĞİL — c_veri, g_oku'dan BİR saat sonra geçerlidir.
//   Kullanıcı tarafında (uart_arayuz) bu gecikme dikkate alınmıştır.
//
// Kabul kriteri (TB-02):
//   Dolu/boş bayrakları, sarma (wrap-around), eşzamanlı oku+yaz, taşma koruması.
//
// Standart : Verilog-2001 — sentezlenebilir, latch üretmez
// Tarih    : Temmuz 2026
// =============================================================================

`timescale 1ns / 1ps

module senk_fifo #(
    parameter integer GENISLIK = 8,     // veri genişliği (bit)
    parameter integer DERINLIK = 64     // eleman sayısı — 2'nin kuvveti olmalı
)(
    input  wire                       g_saat,
    input  wire                       g_sifirla_n,      // asenkron, aktif-DÜŞÜK

    // Yazma tarafı
    input  wire                       g_yaz,
    input  wire [GENISLIK-1:0]        g_veri,

    // Okuma tarafı
    input  wire                       g_oku,
    output wire [GENISLIK-1:0]        c_veri,           // g_oku'dan 1 saat sonra geçerli

    // Durum
    output wire                       c_bos,
    output wire                       c_dolu,
    output wire [$clog2(DERINLIK):0]  c_sayi            // 0..DERINLIK (bir bit fazla)
);

localparam integer ADRES_GEN = $clog2(DERINLIK);
localparam integer SAYI_GEN  = ADRES_GEN + 1;   // DERINLIK değerini de tutabilmeli

// ── Derleme zamanı kontrolü ───────────────────────────────────────────────
// synthesis translate_off
initial begin
    if (DERINLIK != (1 << ADRES_GEN)) begin
        $display("HATA [senk_fifo]: DERINLIK=%0d 2'nin kuvveti degil.", DERINLIK);
        $finish;
    end
end
// synthesis translate_on

// ── Depolama ve işaretçiler ───────────────────────────────────────────────
reg [GENISLIK-1:0]  bellek_r [0:DERINLIK-1];
reg [ADRES_GEN-1:0] yaz_ptr_r;
reg [ADRES_GEN-1:0] oku_ptr_r;
reg [SAYI_GEN-1:0]  sayi_r;
reg [GENISLIK-1:0]  oku_veri_r;

// ── Durum bayrakları ──────────────────────────────────────────────────────
wire bos_w  = (sayi_r == {SAYI_GEN{1'b0}});
wire dolu_w = (sayi_r == DERINLIK[SAYI_GEN-1:0]);

// ── Etkin işlem sinyalleri (koruma burada uygulanır) ──────────────────────
wire yaz_etkin_w = g_yaz & ~dolu_w;
wire oku_etkin_w = g_oku & ~bos_w;

// ── Yazma yolu ────────────────────────────────────────────────────────────
always @(posedge g_saat) begin
    if (yaz_etkin_w)
        bellek_r[yaz_ptr_r] <= g_veri;
end

// ── Okuma yolu (senkron okuma — BRAM/LUTRAM çıkarımına uygun) ─────────────
always @(posedge g_saat) begin
    if (oku_etkin_w)
        oku_veri_r <= bellek_r[oku_ptr_r];
end

// ── İşaretçiler ve eleman sayacı ──────────────────────────────────────────
always @(posedge g_saat or negedge g_sifirla_n) begin
    if (!g_sifirla_n) begin
        yaz_ptr_r <= {ADRES_GEN{1'b0}};
        oku_ptr_r <= {ADRES_GEN{1'b0}};
        sayi_r    <= {SAYI_GEN{1'b0}};
    end else begin
        if (yaz_etkin_w) yaz_ptr_r <= yaz_ptr_r + 1'b1;   // doğal sarma
        if (oku_etkin_w) oku_ptr_r <= oku_ptr_r + 1'b1;

        // Eşzamanlı oku+yaz durumunda sayaç değişmez
        case ({yaz_etkin_w, oku_etkin_w})
            2'b10:   sayi_r <= sayi_r + 1'b1;
            2'b01:   sayi_r <= sayi_r - 1'b1;
            default: sayi_r <= sayi_r;      // 2'b00 ve 2'b11 → değişmez
        endcase
    end
end

// ── Çıkış atamaları ───────────────────────────────────────────────────────
assign c_veri = oku_veri_r;
assign c_bos  = bos_w;
assign c_dolu = dolu_w;
assign c_sayi = sayi_r;

endmodule
