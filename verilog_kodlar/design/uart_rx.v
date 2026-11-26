// =============================================================================
// Modül   : uart_rx.v                                              (İster M-04)
// Proje   : FPGA Tabanlı Güvenli Anahtar Yönetimi ve Kripto Hızlandırıcı (5260007)
// -----------------------------------------------------------------------------
// Açıklama:
//   8N1 UART alıcısı. 16x aşırı-örnekleme ile orta-bit (mid-bit) örnekleme
//   yapar. Çerçeve: 1 start (0) + 8 veri (LSB-first) + 1 stop (1).
//
//   Kritik uygulama detayları:
//
//   1) METASTABİLİTE: g_seri kart pininden gelir ve sistem saatiyle ilgisizdir.
//      2-flop senkronizör ZORUNLUDUR. Bu olmadan tasarım rastgele hatalar
//      verir ve simülasyonda görünmez.
//
//   2) START-BİT YENİDEN DOĞRULAMA: Düşen kenar görüldüğünde hemen kabul
//      edilmez; 8 tik (yarım bit) beklenip hat HÂLÂ '0' mı diye bakılır.
//      Değilse gürültü sayılıp BEKLE'ye dönülür. Bu, hat üzerindeki kısa
//      darbelerin sahte bayt üretmesini engeller.
//
//   3) ORTA-BİT ÖRNEKLEME: Start doğrulandıktan sonra her 16 tikte bir
//      örneklenir. İlk örnekleme start'ın ortasından 16 tik sonra, yani
//      d0'ın tam ortasına denk gelir. Bu, baud sapmasına karşı en geniş
//      payı verir (her yönde +-8 tik = +-yarım bit).
//
//   4) ÇERÇEVE HATASI: Stop biti '1' değilse c_cerceve_hata yükselir ve
//      c_gecerli BASTIRILIR (bozuk bayt yukarı katmana verilmez). FSM
//      BEKLE'ye döner — kilitlenme yoktur (İster K-09 ruhu).
//
// Baud toleransı:
//   Örnekleme noktası bitin ortasındadır; 10 bitlik çerçeve boyunca biriken
//   sapma yarım bitten (%5) küçük kalmalıdır. Pratik hedef: +-%2 (İster M-04).
//
// Kabul kriteri (TB-04):
//   +-%2 baud sapmasında hatasız alım; bozuk stop-bitte c_cerceve_hata;
//   gürültü darbesi reddi; ardışık baytlarda kayıp yok.
//
// Standart : Verilog-2001 — sentezlenebilir, latch üretmez
// Tarih    : Temmuz 2026
// =============================================================================

`timescale 1ns / 1ps

module uart_rx #(
    parameter integer ORNEKLEME = 16     // uart_baud_uretici ile AYNI olmalı
)(
    input  wire       g_saat,
    input  wire       g_sifirla_n,       // asenkron, aktif-DÜŞÜK
    input  wire       g_seri,            // kart pininden (asenkron!)
    input  wire       g_ort_tik,         // uart_baud_uretici'den (16x baud)

    output wire [7:0] c_veri,
    output wire       c_gecerli,         // 1 saat genişliğinde darbe
    output wire       c_cerceve_hata     // 1 saat genişliğinde darbe
);

localparam integer TIK_GEN  = $clog2(ORNEKLEME);
localparam [TIK_GEN-1:0] YARIM_BIT = ORNEKLEME/2 - 1;   // 7  (0..7 = 8 tik)
localparam [TIK_GEN-1:0] TAM_BIT   = ORNEKLEME   - 1;   // 15 (0..15 = 16 tik)

// ── Durum kodlaması ───────────────────────────────────────────────────────
localparam [1:0] D_BEKLE  = 2'd0,   // boşta, düşen kenar bekleniyor
                 D_START  = 2'd1,   // start-bit ortası doğrulanıyor
                 D_VERI   = 2'd2,   // 8 veri biti toplanıyor
                 D_STOP   = 2'd3;   // stop-bit kontrol ediliyor

reg [1:0]          durum_r;
reg [TIK_GEN-1:0]  tik_say_r;       // bit içi tik sayacı
reg [2:0]          bit_say_r;       // 0..7 veri biti indisi
reg [7:0]          kaydir_r;        // kaydırmalı alma yazmacı
reg [7:0]          veri_r;
reg                gecerli_r;
reg                hata_r;

// ── 2-flop metastabilite senkronizörü (ZORUNLU) ───────────────────────────
//   ASYNC_REG özniteliği: Vivado bu iki flop'u yan yana yerleştirir ve
//   metastabilite çözülme süresini iyileştirir.
(* ASYNC_REG = "TRUE" *) reg [1:0] senk_r;
always @(posedge g_saat or negedge g_sifirla_n) begin
    if (!g_sifirla_n) senk_r <= 2'b11;      // boşta hat '1' — sahte start olmasın
    else              senk_r <= {senk_r[0], g_seri};
end
wire seri_w = senk_r[1];

// ── Ana alıcı FSM ─────────────────────────────────────────────────────────
always @(posedge g_saat or negedge g_sifirla_n) begin
    if (!g_sifirla_n) begin
        durum_r   <= D_BEKLE;
        tik_say_r <= {TIK_GEN{1'b0}};
        bit_say_r <= 3'd0;
        kaydir_r  <= 8'd0;
        veri_r    <= 8'd0;
        gecerli_r <= 1'b0;
        hata_r    <= 1'b0;
    end else begin
        // Darbe çıkışları varsayılan olarak düşük — her saatte temizlenir
        gecerli_r <= 1'b0;
        hata_r    <= 1'b0;

        if (g_ort_tik) begin
            case (durum_r)

                // ── Boşta: start-bitin düşen kenarını bekle ──────────────
                D_BEKLE: begin
                    tik_say_r <= {TIK_GEN{1'b0}};
                    bit_say_r <= 3'd0;
                    if (~seri_w) durum_r <= D_START;   // olası start
                end

                // ── Start ortasında yeniden doğrula (gürültü reddi) ──────
                D_START: begin
                    if (tik_say_r == YARIM_BIT) begin
                        tik_say_r <= {TIK_GEN{1'b0}};
                        if (~seri_w) durum_r <= D_VERI;    // gerçek start
                        else         durum_r <= D_BEKLE;   // gürültüymüş
                    end else begin
                        tik_say_r <= tik_say_r + 1'b1;
                    end
                end

                // ── 8 veri biti, LSB-first, bit ortasında örnekle ────────
                D_VERI: begin
                    if (tik_say_r == TAM_BIT) begin
                        tik_say_r <= {TIK_GEN{1'b0}};
                        kaydir_r  <= {seri_w, kaydir_r[7:1]};   // sağa kaydır
                        if (bit_say_r == 3'd7) begin
                            bit_say_r <= 3'd0;
                            durum_r   <= D_STOP;
                        end else begin
                            bit_say_r <= bit_say_r + 1'b1;
                        end
                    end else begin
                        tik_say_r <= tik_say_r + 1'b1;
                    end
                end

                // ── Stop biti: '1' olmalı ───────────────────────────────
                D_STOP: begin
                    if (tik_say_r == TAM_BIT) begin
                        tik_say_r <= {TIK_GEN{1'b0}};
                        durum_r   <= D_BEKLE;
                        if (seri_w) begin
                            veri_r    <= kaydir_r;   // geçerli bayt
                            gecerli_r <= 1'b1;
                        end else begin
                            hata_r    <= 1'b1;       // çerçeve hatası
                            // c_gecerli BASTIRILIR — bozuk bayt yukarı gitmez
                        end
                    end else begin
                        tik_say_r <= tik_say_r + 1'b1;
                    end
                end

                default: durum_r <= D_BEKLE;   // erişilemez — latch/kilit koruması

            endcase
        end
    end
end

assign c_veri         = veri_r;
assign c_gecerli      = gecerli_r;
assign c_cerceve_hata = hata_r;

endmodule
