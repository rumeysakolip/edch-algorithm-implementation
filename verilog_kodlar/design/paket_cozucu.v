// =============================================================================
// Modül   : paket_cozucu.v                                         (İster M-06)
// Proje   : FPGA Tabanlı Güvenli Anahtar Yönetimi ve Kripto Hızlandırıcı (5260007)
// -----------------------------------------------------------------------------
// Açıklama:
//   UART bayt akışını protokol çerçevelerine çözer ve 32-bit word akışı üretir.
//   Projenin EN HATA-YATKIN modülüdür: endianness ve zaman aşımı burada yaşar.
//
//   Giriş çerçevesi (İster PROT-01):
//     [0xA5 BASLIK][KOMUT:1][UZUNLUK:1][VERI:0..64][CRC8:1]
//
//   CRC kapsamı: BASLIK dahil, VERI'nin son baytına kadar TÜM baytlar.
//                CRC baytının kendisi hesaba KATILMAZ.
//
// -----------------------------------------------------------------------------
// TASARIM KARARI — NEDEN TAMPONLAMA VAR:
//   Word'ler çerçeve geldikçe DEĞİL, CRC doğrulandıktan SONRA çıkarılır.
//   Aksi hâlde bozuk bir çerçevenin ilk word'leri ECDH çekirdeğine sızar ve
//   geri alınamaz. 64 baytlık tampon bu yüzden zorunludur (İster PROT-05).
//
//   Akış:  BEKLE -> BASLIK -> KOMUT -> UZUNLUK -> VERI -> CRC -> TESLIM
//                                                          |
//                                          CRC hatali ise -+-> BEKLE (word YOK)
//
// -----------------------------------------------------------------------------
// ENDIANNESS (İster K-05, K-06) — BU MODÜLÜN EN KRİTİK SATIRI:
//   Hattan gelen ilk bayt, word'ün EN DÜŞÜK baytıdır.
//     word = { bayt[4i+3], bayt[4i+2], bayt[4i+1], bayt[4i] }
//   word0 = koordinatın bit[31:0]'i.
//   Host tarafi karsiligi: int.to_bytes(32, 'little')
//   Bu satır yanlışsa hata TB-12'ye kadar sessiz kalır. TB-09 bunu kilitler.
//
// -----------------------------------------------------------------------------
// GÜVENLİK NOTU:
//   CRC yalnızca hat gürültüsüne karşıdır; kimlik doğrulama DEĞİLDİR.
//   Bu modülden çıkan hiçbir veri "yetkili" kabul edilmemelidir.
//   Komut yetkilendirmesi komut_yoneticisi'nin sorumluluğundadır.
//
// Kabul kriteri (TB-06):
//   Geçerli çerçeve -> doğru word/sıra/endianness; CRC hatası -> word yok;
//   uzunluk hatası; yarım çerçeve + zaman aşımı; gövdede 0xA5 resenkronize etmez.
//
// Standart : Verilog-2001 — sentezlenebilir, latch üretmez
// Tarih    : Temmuz 2026
// =============================================================================

`timescale 1ns / 1ps

module paket_cozucu #(
    parameter integer AZAMI_VERI  = 64,          // en büyük veri alanı (bayt)
    parameter integer ZAMAN_ASIMI = 5_000_000    // ~50 ms @ 100 MHz (İster K-09)
)(
    input  wire        g_saat,
    input  wire        g_sifirla_n,

    // uart_rx / rx_fifo tarafından
    input  wire [7:0]  g_bayt,
    input  wire        g_bayt_gecerli,

    // Çözülmüş komut (CRC doğrulandıktan SONRA darbelenir)
    output wire [7:0]  c_komut,
    output wire [7:0]  c_uzunluk,
    output wire        c_komut_gecerli,

    // Word akışı (komut darbesinden sonra ardışık çevrimlerde)
    output wire [31:0] c_word,
    output wire        c_word_gecerli,
    output wire [3:0]  c_word_indis,
    input  wire        g_word_hazir,      // tüketici geri basıncı (1 = hazır)

    // Hata bayrakları (1 saat genişliğinde darbe)
    output wire        c_crc_hata,
    output wire        c_uzunluk_hata,
    output wire        c_zaman_asimi,

    output wire        c_mesgul
);

localparam [7:0] BASLIK_BAYT = 8'hA5;

localparam integer TAMPON_ADRES = $clog2(AZAMI_VERI);          // 6
localparam integer AZAMI_WORD   = AZAMI_VERI / 4;              // 16
localparam integer ZA_GEN       = $clog2(ZAMAN_ASIMI + 1);     // 23

// ── Durum kodlaması ───────────────────────────────────────────────────────
localparam [2:0] D_BEKLE   = 3'd0,   // 0xA5 bekleniyor
                 D_KOMUT   = 3'd1,
                 D_UZUNLUK = 3'd2,
                 D_VERI    = 3'd3,
                 D_CRC     = 3'd4,
                 D_TESLIM  = 3'd5;   // tamponu word olarak boşalt

reg [2:0] durum_r;

// ── Çerçeve tamponu ve sayaçlar ───────────────────────────────────────────
reg [7:0]              tampon_r [0:AZAMI_VERI-1];
reg [TAMPON_ADRES:0]   veri_say_r;      // alınan veri baytı sayısı
reg [7:0]              komut_r;
reg [7:0]              uzunluk_r;
reg [4:0]              word_indis_r;    // 0..16 — 5 bit (16 degeri tasmasin)
reg [4:0]              word_adet_r;     // uzunluk/4  (0..16)
reg [3:0]              word_indis_cik_r;// YAYINLANAN word'un indisi (cikis icin)

// ── Çıkış saklayıcıları ───────────────────────────────────────────────────
reg [31:0] word_r;
reg        word_gecerli_r;
reg        komut_gecerli_r;
reg        crc_hata_r;
reg        uzunluk_hata_r;
reg        zaman_asimi_r;

// ── Zaman aşımı sayacı (İster K-09) ───────────────────────────────────────
//   BEKLE dışındaki her durumda koşar; her geçerli baytta sıfırlanır.
//   Süre dolarsa çerçeve terk edilir ve BEKLE'ye dönülür — KİLİTLENME YOK.
reg [ZA_GEN-1:0] za_sayac_r;

// ── CRC birimi ────────────────────────────────────────────────────────────
reg        crc_temizle_r;
reg        crc_besle_r;
reg  [7:0] crc_bayt_r;
wire [7:0] crc_w;

crc8_hesap #(.POLINOM(8'h07), .BASLANGIC(8'h00)) crc_birim (
    .g_saat      (g_saat),
    .g_sifirla_n (g_sifirla_n),
    .g_temizle   (crc_temizle_r),
    .g_veri      (crc_bayt_r),
    .g_gecerli   (crc_besle_r),
    .c_crc       (crc_w)
);

// ── Tampondan word oluşturma (ENDIANNESS — K-06) ──────────────────────────
//   İlk bayt = en düşük bayt.
wire [TAMPON_ADRES+1:0] taban_w = {word_indis_r[3:0], 2'b00};   // word_indis * 4
wire [31:0] tampon_word_w = { tampon_r[taban_w + 3],
                              tampon_r[taban_w + 2],
                              tampon_r[taban_w + 1],
                              tampon_r[taban_w + 0] };

// ── Uzunluk geçerlilik kontrolü ───────────────────────────────────────────
//   Kabul: 4'ün katı VE <= AZAMI_VERI. (Tüm komutlarımız 0, 32 veya 64.)
wire uzunluk_gecerli_w = (g_bayt <= AZAMI_VERI[7:0]) && (g_bayt[1:0] == 2'b00);

// ── Ana FSM ───────────────────────────────────────────────────────────────
always @(posedge g_saat or negedge g_sifirla_n) begin
    if (!g_sifirla_n) begin
        durum_r         <= D_BEKLE;
        veri_say_r      <= {(TAMPON_ADRES+1){1'b0}};
        komut_r         <= 8'd0;
        uzunluk_r       <= 8'd0;
        word_indis_r     <= 5'd0;
        word_adet_r      <= 5'd0;
        word_indis_cik_r <= 4'd0;
        word_r          <= 32'd0;
        word_gecerli_r  <= 1'b0;
        komut_gecerli_r <= 1'b0;
        crc_hata_r      <= 1'b0;
        uzunluk_hata_r  <= 1'b0;
        zaman_asimi_r   <= 1'b0;
        za_sayac_r      <= {ZA_GEN{1'b0}};
        crc_temizle_r   <= 1'b0;
        crc_besle_r     <= 1'b0;
        crc_bayt_r      <= 8'd0;
    end else begin
        // ── Darbe çıkışları varsayılan düşük ──────────────────────────────
        word_gecerli_r  <= 1'b0;
        komut_gecerli_r <= 1'b0;
        crc_hata_r      <= 1'b0;
        uzunluk_hata_r  <= 1'b0;
        zaman_asimi_r   <= 1'b0;
        crc_temizle_r   <= 1'b0;
        crc_besle_r     <= 1'b0;

        // ── Zaman aşımı sayacı ────────────────────────────────────────────
        if (durum_r == D_BEKLE || durum_r == D_TESLIM) begin
            za_sayac_r <= {ZA_GEN{1'b0}};
        end else if (g_bayt_gecerli) begin
            za_sayac_r <= {ZA_GEN{1'b0}};          // bayt geldi, sayacı sıfırla
        end else if (za_sayac_r == ZAMAN_ASIMI[ZA_GEN-1:0]) begin
            za_sayac_r    <= {ZA_GEN{1'b0}};
            zaman_asimi_r <= 1'b1;
            durum_r       <= D_BEKLE;              // çerçeveyi terk et
        end else begin
            za_sayac_r <= za_sayac_r + 1'b1;
        end

        // ── Durum makinesi ────────────────────────────────────────────────
        case (durum_r)

            // ── Başlık bekleniyor ─────────────────────────────────────────
            //   CRC KAPSAMI: baslik DAHIL (paket_kurucu ile simetrik olmali).
            //   crc8_hesap'ta g_temizle, g_gecerli'den onceliklidir; ikisi ayni
            //   cevrimde verilemez. Bu yuzden CRC bosta SUREKLI temizlenir ve
            //   baslik geldiginde dogrudan beslenir.
            D_BEKLE: begin
                veri_say_r   <= {(TAMPON_ADRES+1){1'b0}};
                word_indis_r <= 5'd0;
                if (g_bayt_gecerli && (g_bayt == BASLIK_BAYT)) begin
                    crc_bayt_r  <= g_bayt;         // basligi CRC'ye kat
                    crc_besle_r <= 1'b1;
                    durum_r     <= D_KOMUT;
                end else begin
                    crc_temizle_r <= 1'b1;         // bostayken CRC sifirda tutulur
                end
                // Başlık dışı bayt sessizce atılır (hat çöpü / senkron kaybı)
            end

            // ── Komut baytı ───────────────────────────────────────────────
            D_KOMUT: begin
                if (g_bayt_gecerli) begin
                    komut_r     <= g_bayt;
                    crc_bayt_r  <= g_bayt;
                    crc_besle_r <= 1'b1;
                    durum_r     <= D_UZUNLUK;
                end
            end

            // ── Uzunluk baytı ─────────────────────────────────────────────
            D_UZUNLUK: begin
                if (g_bayt_gecerli) begin
                    crc_bayt_r  <= g_bayt;
                    crc_besle_r <= 1'b1;
                    if (!uzunluk_gecerli_w) begin
                        uzunluk_hata_r <= 1'b1;
                        durum_r        <= D_BEKLE;     // çerçeveyi reddet
                    end else begin
                        uzunluk_r   <= g_bayt;
                        word_adet_r <= g_bayt[6:2];    // uzunluk / 4
                        if (g_bayt == 8'd0) durum_r <= D_CRC;   // verisiz komut
                        else                durum_r <= D_VERI;
                    end
                end
            end

            // ── Veri baytları → tampon ────────────────────────────────────
            //   NOT: Burada 0xA5 görülmesi resenkronizasyona sebep OLMAZ.
            //   Konum tabanlı ayrıştırma yapılır (İster M-06 kabul kriteri).
            D_VERI: begin
                if (g_bayt_gecerli) begin
                    tampon_r[veri_say_r[TAMPON_ADRES-1:0]] <= g_bayt;
                    crc_bayt_r  <= g_bayt;
                    crc_besle_r <= 1'b1;
                    if (veri_say_r == (uzunluk_r[TAMPON_ADRES:0] - 1'b1)) begin
                        durum_r <= D_CRC;
                    end else begin
                        veri_say_r <= veri_say_r + 1'b1;
                    end
                end
            end

            // ── CRC baytı — doğrulama ─────────────────────────────────────
            //   crc_w, son veri baytından sonra yerleşmiştir (UART yavaş).
            //   CRC baytının KENDİSİ hesaba katılmaz.
            D_CRC: begin
                if (g_bayt_gecerli) begin
                    if (g_bayt == crc_w) begin
                        komut_gecerli_r <= 1'b1;       // çerçeve GEÇERLİ
                        word_indis_r    <= 5'd0;
                        if (word_adet_r == 5'd0) durum_r <= D_BEKLE;  // verisiz
                        else                     durum_r <= D_TESLIM;
                    end else begin
                        crc_hata_r <= 1'b1;
                        durum_r    <= D_BEKLE;
                        // WORD ÇIKIŞI YOK — bozuk veri cekirdege ULASMAZ
                    end
                end
            end

            // ── Tamponu word olarak boşalt ────────────────────────────────
            D_TESLIM: begin
                if (g_word_hazir) begin
                    word_r           <= tampon_word_w;
                    word_gecerli_r   <= 1'b1;
                    word_indis_cik_r <= word_indis_r[3:0];   // YAYINLANAN indis
                    // 5-bit karsilastirma: word_adet_r = 16 iken tasma olmaz
                    if ((word_indis_r + 5'd1) == word_adet_r) begin
                        word_indis_r <= 5'd0;
                        durum_r      <= D_BEKLE;
                    end else begin
                        word_indis_r <= word_indis_r + 5'd1;
                    end
                end
            end

            default: durum_r <= D_BEKLE;    // erişilemez — kilit koruması

        endcase
    end
end

// ── Çıkış atamaları ───────────────────────────────────────────────────────
assign c_komut         = komut_r;
assign c_uzunluk       = uzunluk_r;
assign c_komut_gecerli = komut_gecerli_r;
assign c_word          = word_r;
assign c_word_gecerli  = word_gecerli_r;
assign c_word_indis    = word_indis_cik_r;   // c_word_gecerli ile HIZALI
assign c_crc_hata      = crc_hata_r;
assign c_uzunluk_hata  = uzunluk_hata_r;
assign c_zaman_asimi   = zaman_asimi_r;
assign c_mesgul        = (durum_r != D_BEKLE);

endmodule
