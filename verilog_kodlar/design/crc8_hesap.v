// =============================================================================
// Modül   : crc8_hesap.v                                           (İster M-03)
// Proje   : FPGA Tabanlı Güvenli Anahtar Yönetimi ve Kripto Hızlandırıcı (5260007)
// -----------------------------------------------------------------------------
// Açıklama:
//   Bayt-seri CRC-8 hesaplayıcı. Çerçeve bütünlüğü kontrolü için kullanılır
//   (İster K-08). Tablo (LUT) kullanmaz; 8 kademe açılmış (unrolled) LFSR
//   mantığıdır → bayt başına TEK saat çevrimi, ~40 LUT.
//
//   Uzlaşım: CRC-8 / SMBus
//     Polinom      : 0x07  (x^8 + x^2 + x + 1)
//     Başlangıç    : 0x00
//     Giriş yansıma: yok
//     Çıkış yansıma: yok
//     Son XOR      : yok
//
//   Standart kontrol değeri: "123456789" → 0xF4
//   (Python referansı ile doğrulanmıştır — bkz. host/vektor_uret.py yanındaki
//    kontrol betiği ve TB-03.)
//
// KRİPTOGRAFİK NOT:
//   CRC yalnızca HAT GÜRÜLTÜSÜNE karşı bütünlük sağlar. Kasıtlı değişikliğe
//   karşı koruma DEĞİLDİR ve kimlik doğrulama sağlamaz. UART hattı güvenilir
//   kabul edilmemelidir; hattan gelen hiçbir veri yetki kanıtı değildir.
//
// Kullanım:
//   g_temizle   : CRC'yi başlangıç değerine (0x00) döndürür — çerçeve başında
//   g_gecerli   : g_veri'deki baytı CRC'ye dahil eder
//   c_crc       : o ana kadarki birikmiş CRC (kombinasyonel gecikme yok)
//
// Kabul kriteri (TB-03):
//   "123456789" → 0xF4, g_temizle davranışı, ardışık çerçevelerde sızıntı yok.
//
// Standart : Verilog-2001 — sentezlenebilir, latch üretmez
// Tarih    : Temmuz 2026
// =============================================================================

`timescale 1ns / 1ps

module crc8_hesap #(
    parameter [7:0] POLINOM  = 8'h07,
    parameter [7:0] BASLANGIC = 8'h00
)(
    input  wire       g_saat,
    input  wire       g_sifirla_n,     // asenkron, aktif-DÜŞÜK
    input  wire       g_temizle,       // senkron temizle (çerçeve başı)
    input  wire [7:0] g_veri,
    input  wire       g_gecerli,       // g_veri'yi CRC'ye dahil et
    output wire [7:0] c_crc
);

reg [7:0] crc_r;

// ── Tek bir bit kademesi ──────────────────────────────────────────────────
//   MSB 1 ise sola kaydır + polinom XOR, değilse sadece sola kaydır.
function [7:0] kademe;
    input [7:0] mevcut;
    begin
        kademe = mevcut[7] ? ((mevcut << 1) ^ POLINOM) : (mevcut << 1);
    end
endfunction

// ── Bir bayt = 8 kademe (açılmış) ─────────────────────────────────────────
function [7:0] bayt_isle;
    input [7:0] mevcut;
    input [7:0] yeni_bayt;
    reg   [7:0] gecici;
    integer i;
    begin
        gecici = mevcut ^ yeni_bayt;
        for (i = 0; i < 8; i = i + 1)
            gecici = kademe(gecici);
        bayt_isle = gecici;
    end
endfunction

// ── Kayıt güncelleme ──────────────────────────────────────────────────────
always @(posedge g_saat or negedge g_sifirla_n) begin
    if (!g_sifirla_n)
        crc_r <= BASLANGIC;
    else if (g_temizle)                       // temizle, g_gecerli'den önceliklidir
        crc_r <= BASLANGIC;
    else if (g_gecerli)
        crc_r <= bayt_isle(crc_r, g_veri);
    else
        crc_r <= crc_r;                       // açık tutma — latch riski yok
end

assign c_crc = crc_r;

endmodule
