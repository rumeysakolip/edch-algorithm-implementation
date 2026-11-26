// =============================================================================
// Modül   : uart_tx.v                                              (İster M-05)
// Proje   : FPGA Tabanlı Güvenli Anahtar Yönetimi ve Kripto Hızlandırıcı (5260007)
// -----------------------------------------------------------------------------
// Açıklama:
//   8N1 UART vericisi. uart_rx ile AYNI 16x tik kaynağını kullanır; kendi
//   içinde 16'ya bölerek bit süresi üretir. Ortak kaynak, iki uç arasında
//   bölücü sapması olasılığını sıfırlar.
//
//   Çerçeve: 1 start (0) + 8 veri (LSB-first) + 1 stop (1)
//
//   El sıkışma:
//     g_basla, c_mesgul düşükken bir saat çevrimi yüksek tutulur.
//     c_mesgul YÜKSEKKEN gelen g_basla YOK SAYILIR — gönderilmekte olan
//     bayt bozulmaz. Üst katman (paket_kurucu) c_mesgul'u beklemekle
//     yükümlüdür.
//
//   Boşta hat seviyesi '1'dir (UART kuralı). Reset sırasında da '1' sürülür;
//   aksi hâlde karşı taraf reset'i uzun bir break/start olarak yorumlar.
//
// Kabul kriteri (TB-05):
//   Bit zamanlaması, c_mesgul kilidi, boşta hat seviyesi, ardışık baytlar.
//
// Standart : Verilog-2001 — sentezlenebilir, latch üretmez
// Tarih    : Temmuz 2026
// =============================================================================

`timescale 1ns / 1ps

module uart_tx #(
    parameter integer ORNEKLEME = 16     // uart_baud_uretici ile AYNI olmalı
)(
    input  wire       g_saat,
    input  wire       g_sifirla_n,       // asenkron, aktif-DÜŞÜK
    input  wire [7:0] g_veri,
    input  wire       g_basla,           // 1 saat genişliğinde darbe
    input  wire       g_ort_tik,         // uart_baud_uretici'den (16x baud)

    output wire       c_seri,            // kart pinine
    output wire       c_mesgul
);

localparam integer TIK_GEN = $clog2(ORNEKLEME);
localparam [TIK_GEN-1:0] TAM_BIT = ORNEKLEME - 1;   // 15

// ── Durum kodlaması ───────────────────────────────────────────────────────
localparam [1:0] D_BOSTA = 2'd0,
                 D_START = 2'd1,
                 D_VERI  = 2'd2,
                 D_STOP  = 2'd3;

reg [1:0]         durum_r;
reg [TIK_GEN-1:0] tik_say_r;
reg [2:0]         bit_say_r;
reg [7:0]         kaydir_r;      // gönderim kaydırma yazmacı
reg               seri_r;
reg               mesgul_r;
reg               istek_r;       // g_basla yakalandı, tik hizası bekleniyor

always @(posedge g_saat or negedge g_sifirla_n) begin
    if (!g_sifirla_n) begin
        durum_r   <= D_BOSTA;
        tik_say_r <= {TIK_GEN{1'b0}};
        bit_say_r <= 3'd0;
        kaydir_r  <= 8'hFF;
        seri_r    <= 1'b1;        // boşta '1' — break olarak algılanmasın
        mesgul_r  <= 1'b0;
        istek_r   <= 1'b0;
    end else begin
        case (durum_r)

            // ── Boşta: g_basla bekleniyor ───────────────────────────────
            //   Start biti TİK HİZASINDA başlatılır. Aksi hâlde start biti
            //   15/16 bit süresi olur ve tüm çerçeve 1 tik kayar; baud
            //   toleransı boşuna daralır. Bekleme en fazla 1 tik (~0.54 us).
            D_BOSTA: begin
                seri_r    <= 1'b1;
                tik_say_r <= {TIK_GEN{1'b0}};
                bit_say_r <= 3'd0;

                if (g_basla && !istek_r) begin
                    kaydir_r <= g_veri;    // veriyi yakala
                    istek_r  <= 1'b1;
                    mesgul_r <= 1'b1;      // üst katman hemen bilsin
                end

                if (istek_r && g_ort_tik) begin
                    istek_r <= 1'b0;
                    seri_r  <= 1'b0;       // start biti, tik hizasında
                    durum_r <= D_START;
                end
            end

            // ── Start biti: bir tam bit süresi '0' ──────────────────────
            D_START: begin
                if (g_ort_tik) begin
                    if (tik_say_r == TAM_BIT) begin
                        tik_say_r <= {TIK_GEN{1'b0}};
                        seri_r    <= kaydir_r[0];   // ilk veri biti (LSB)
                        durum_r   <= D_VERI;
                    end else begin
                        tik_say_r <= tik_say_r + 1'b1;
                    end
                end
            end

            // ── 8 veri biti, LSB-first ──────────────────────────────────
            D_VERI: begin
                if (g_ort_tik) begin
                    if (tik_say_r == TAM_BIT) begin
                        tik_say_r <= {TIK_GEN{1'b0}};
                        kaydir_r  <= {1'b1, kaydir_r[7:1]};   // sağa kaydır
                        if (bit_say_r == 3'd7) begin
                            bit_say_r <= 3'd0;
                            seri_r    <= 1'b1;                // stop biti
                            durum_r   <= D_STOP;
                        end else begin
                            bit_say_r <= bit_say_r + 1'b1;
                            seri_r    <= kaydir_r[1];         // sonraki bit
                        end
                    end else begin
                        tik_say_r <= tik_say_r + 1'b1;
                    end
                end
            end

            // ── Stop biti: bir tam bit süresi '1' ───────────────────────
            D_STOP: begin
                if (g_ort_tik) begin
                    if (tik_say_r == TAM_BIT) begin
                        tik_say_r <= {TIK_GEN{1'b0}};
                        mesgul_r  <= 1'b0;      // sıradaki bayt kabul edilebilir
                        durum_r   <= D_BOSTA;
                    end else begin
                        tik_say_r <= tik_say_r + 1'b1;
                    end
                end
            end

            default: begin      // erişilemez — kilitlenme koruması
                durum_r  <= D_BOSTA;
                seri_r   <= 1'b1;
                mesgul_r <= 1'b0;
                istek_r  <= 1'b0;
            end

        endcase
    end
end

assign c_seri   = seri_r;
assign c_mesgul = mesgul_r;

endmodule
