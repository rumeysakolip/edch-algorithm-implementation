// =============================================================================
// Modül   : paket_kurucu.v                                         (İster M-07)
// Proje   : FPGA Tabanlı Güvenli Anahtar Yönetimi ve Kripto Hızlandırıcı (5260007)
// -----------------------------------------------------------------------------
// Açıklama:
//   32-bit word akışını protokol çerçevesine sarar ve bayt akışı üretir.
//   paket_cozucu'nun AYNASIDIR - ikisi TB-09'da karşılıklı sınanır.
//
//   Çıkış çerçevesi (İster PROT-02):
//     [0x5A BASLIK][DURUM:1][UZUNLUK:1][VERI:0..64][CRC8:1]
//
//   CRC kapsamı: BASLIK dahil, VERI'nin son baytına kadar TÜM baytlar.
//
// -----------------------------------------------------------------------------
// ENDIANNESS (İster K-05, K-06):
//   Word'ün EN DÜŞÜK baytı hatta İLK çıkar.
//     bayt sirasi = word[7:0], word[15:8], word[23:16], word[31:24]
//   paket_cozucu'nun tersidir; TB-09 ikisinin uyumunu kilitler.
//
// -----------------------------------------------------------------------------
// GERİ BASINÇ (g_bayt_hazir) - NEDEN ZORUNLU:
//   Tam bir çerçeve 64 veri + 4 ek = 68 bayttır. TX FIFO derinliği 64 ise
//   çerçeve FIFO'ya SIĞMAZ. g_bayt_hazir (FIFO dolu değil) olmadan son
//   baytlar sessizce kaybolur. Bu sinyal bağlanmadan modül kullanılmamalıdır.
//   (uart_arayuz'da TX FIFO derinliği 128 seçilerek ayrıca pay bırakılmıştır.)
//
// -----------------------------------------------------------------------------
// WORD EL SIKIŞMASI - c_word_iste bir DARBEDIR, seviye DEGILDIR:
//   Her word icin TEK cevrimlik bir istek darbesi uretilir. Uretici
//   g_word + g_word_gecerli ile yanitlar; kurucu word'u yakalar, 4 baytini
//   basar, sonra bir sonraki darbeyi uretir.
//
//   NEDEN DARBE (ilk surumdeki hata):
//     Istek SEVIYE olarak tutulursa, cikis yazmac oldugundan uretici yanit
//     verdikten sonra da bir cevrim daha yuksek kalir. Uretici bunu yeni bir
//     istek sanip IKINCI bir word gonderir; kurucu o an D_VERI'ye gecmis
//     oldugundan ikinci word SESSIZCE KAYBOLUR.
//     Belirti: word1 atlanir, yerine word2 basilir; cerceve yarim kalir.
//     (TB-07 T1/T4/T6/T7 bu sekilde takilmisti.)
//
//   ISTEK_YENILE: uretici darbeyi kacirirsa kilitlenmemek icin istek belirli
//   araliklarla yenilenir. Normal akista devreye girmez.
//
// Kabul kriteri (TB-07):
//   Çerçeve alanları doğru; c_word_iste el sıkışması; g_uzunluk=0 durumu;
//   geri basınç altında bayt kaybı yok.
//   (TB-09: üretilen çerçeve paket_cozucu tarafından hatasız çözülebilmeli.)
//
// Standart : Verilog-2001 - sentezlenebilir, latch üretmez
// Tarih    : Temmuz 2026
// =============================================================================

`timescale 1ns / 1ps

module paket_kurucu #(
    parameter integer AZAMI_VERI   = 64,
    parameter integer ISTEK_YENILE = 256   // yanit gelmezse istegi yenileme araligi
)(
    input  wire        g_saat,
    input  wire        g_sifirla_n,

    // Çerçeve başlatma
    input  wire        g_basla,           // 1 saat genişliğinde darbe
    input  wire [7:0]  g_durum,           // DURUM alanı (İster PROT-05)
    input  wire [7:0]  g_uzunluk,         // veri bayt sayısı (4'ün katı, <=64)

    // Word kaynağı
    output wire        c_word_iste,
    input  wire [31:0] g_word,
    input  wire        g_word_gecerli,

    // Bayt çıkışı (tx_fifo'ya)
    output wire [7:0]  c_bayt,
    output wire        c_bayt_gecerli,
    input  wire        g_bayt_hazir,      // FIFO dolu DEGIL (geri basınç)

    output wire        c_mesgul,
    output wire        c_uzunluk_hata     // 1 saat genişliğinde darbe
);

localparam [7:0] BASLIK_BAYT = 8'h5A;

// ── Durum kodlaması ───────────────────────────────────────────────────────
localparam [2:0] D_BOSTA   = 3'd0,
                 D_BASLIK  = 3'd1,
                 D_DURUM   = 3'd2,
                 D_UZUNLUK = 3'd3,
                 D_WORD    = 3'd4,   // word iste / bekle
                 D_VERI    = 3'd5,   // yakalanan word'un 4 baytini bas
                 D_CRC_BEK = 3'd6,   // CRC yazmacinin yerlesmesini bekle
                 D_CRC     = 3'd7;

// ── D_CRC_BEK NEDEN VAR (ince ama olumcul hata) ───────────────────────────
//   bayt_gecerli_r, bayt_r ile AYNI cevrimde yukselir; crc8_hesap bu baytI
//   cevrimin SONUNDA yazmacina alir. Yani son veri baytI basildiktan hemen
//   sonra crc_w HENUZ o baytI icermez.
//   D_CRC'ye dogrudan gecilirse ESKI CRC gonderilir ve karsi taraf her
//   cerceveyi bozuk sayar. D_CRC_BEK bir cevrim bekleyerek bunu onler.
//   Ayni sorun paket_cozucu'da YOKTUR: oradaki CRC baytI, son veri baytIndan
//   en az 10 bit suresi (>=40 cevrim) sonra gelir - UART bunu garanti eder.

reg [2:0]  durum_r;
reg [7:0]  durum_alan_r;
reg [7:0]  uzunluk_r;
reg [4:0]  word_adet_r;     // uzunluk / 4  (0..16)
reg [4:0]  word_say_r;      // yayinlanan word sayisi
reg [31:0] word_tut_r;      // yakalanan word
reg [1:0]  bayt_say_r;      // word icindeki bayt indisi (0..3)

reg [7:0]  bayt_r;
reg        bayt_gecerli_r;
reg        word_iste_r;
reg        uzunluk_hata_r;

localparam integer YEN_GEN = $clog2(ISTEK_YENILE + 1);
reg [YEN_GEN-1:0] yenile_sayac_r;   // D_WORD'de yanit beklerken koşar

// ── CRC birimi ────────────────────────────────────────────────────────────
//   Basilan her bayt ayni anda CRC'ye beslenir.
reg        crc_temizle_r;
wire [7:0] crc_w;

crc8_hesap #(.POLINOM(8'h07), .BASLANGIC(8'h00)) crc_birim (
    .g_saat      (g_saat),
    .g_sifirla_n (g_sifirla_n),
    .g_temizle   (crc_temizle_r),
    .g_veri      (bayt_r),
    .g_gecerli   (bayt_gecerli_r),    // CRC baytinin KENDISI beslenmez (asagida)
    .c_crc       (crc_w)
);

// ── Uzunluk gecerlilik kontrolu ───────────────────────────────────────────
wire uzunluk_gecerli_w = (g_uzunluk <= AZAMI_VERI[7:0]) && (g_uzunluk[1:0] == 2'b00);

// ── Word icinden bayt secimi (ENDIANNESS - K-06) ──────────────────────────
//   bayt_say_r = 0 -> word[7:0]  (EN DUSUK bayt ILK cikar)
reg [7:0] secilen_bayt_w;
always @(*) begin
    case (bayt_say_r)
        2'd0:    secilen_bayt_w = word_tut_r[7:0];
        2'd1:    secilen_bayt_w = word_tut_r[15:8];
        2'd2:    secilen_bayt_w = word_tut_r[23:16];
        default: secilen_bayt_w = word_tut_r[31:24];
    endcase
end

// ── Ana FSM ───────────────────────────────────────────────────────────────
always @(posedge g_saat or negedge g_sifirla_n) begin
    if (!g_sifirla_n) begin
        durum_r        <= D_BOSTA;
        durum_alan_r   <= 8'd0;
        uzunluk_r      <= 8'd0;
        word_adet_r    <= 5'd0;
        word_say_r     <= 5'd0;
        word_tut_r     <= 32'd0;
        bayt_say_r     <= 2'd0;
        bayt_r         <= 8'd0;
        bayt_gecerli_r <= 1'b0;
        word_iste_r    <= 1'b0;
        uzunluk_hata_r <= 1'b0;
        crc_temizle_r  <= 1'b0;
        yenile_sayac_r <= {YEN_GEN{1'b0}};
    end else begin
        // Darbe cikislari varsayilan dusuk
        bayt_gecerli_r <= 1'b0;
        word_iste_r    <= 1'b0;
        uzunluk_hata_r <= 1'b0;
        crc_temizle_r  <= 1'b0;

        case (durum_r)

            // ── Bosta: g_basla bekleniyor ─────────────────────────────────
            D_BOSTA: begin
                bayt_say_r <= 2'd0;
                word_say_r <= 5'd0;
                if (g_basla) begin
                    if (!uzunluk_gecerli_w) begin
                        uzunluk_hata_r <= 1'b1;      // cerceve baslatilmaz
                    end else begin
                        durum_alan_r  <= g_durum;
                        uzunluk_r     <= g_uzunluk;
                        word_adet_r   <= g_uzunluk[6:2];   // uzunluk / 4
                        crc_temizle_r <= 1'b1;             // CRC'yi sifirla
                        durum_r       <= D_BASLIK;
                    end
                end
            end

            // ── Baslik baytI ──────────────────────────────────────────────
            D_BASLIK: begin
                if (g_bayt_hazir) begin
                    bayt_r         <= BASLIK_BAYT;
                    bayt_gecerli_r <= 1'b1;
                    durum_r        <= D_DURUM;
                end
            end

            // ── Durum baytI ───────────────────────────────────────────────
            D_DURUM: begin
                if (g_bayt_hazir) begin
                    bayt_r         <= durum_alan_r;
                    bayt_gecerli_r <= 1'b1;
                    durum_r        <= D_UZUNLUK;
                end
            end

            // ── Uzunluk baytI ─────────────────────────────────────────────
            D_UZUNLUK: begin
                if (g_bayt_hazir) begin
                    bayt_r         <= uzunluk_r;
                    bayt_gecerli_r <= 1'b1;
                    if (word_adet_r == 5'd0) begin
                        durum_r <= D_CRC_BEK;               // verisiz cerceve
                    end else begin
                        durum_r        <= D_WORD;
                        word_iste_r    <= 1'b1;             // ILK istek darbesi
                        yenile_sayac_r <= {YEN_GEN{1'b0}};
                    end
                end
            end

            // ── Word yanitini bekle ───────────────────────────────────────
            //   Istek darbesi bu duruma GIRERKEN uretilmistir; burada tekrar
            //   yukseltilmez (aksi halde uretici ikinci word gonderir ve o
            //   word kaybolur - modul basindaki nota bakin).
            D_WORD: begin
                if (g_word_gecerli) begin
                    word_tut_r     <= g_word;
                    bayt_say_r     <= 2'd0;
                    yenile_sayac_r <= {YEN_GEN{1'b0}};
                    durum_r        <= D_VERI;
                end else if (yenile_sayac_r == ISTEK_YENILE[YEN_GEN-1:0]) begin
                    word_iste_r    <= 1'b1;              // kilitlenme sigortasi
                    yenile_sayac_r <= {YEN_GEN{1'b0}};
                end else begin
                    yenile_sayac_r <= yenile_sayac_r + 1'b1;
                end
            end

            // ── Yakalanan word'un 4 baytIni bas ───────────────────────────
            D_VERI: begin
                if (g_bayt_hazir) begin
                    bayt_r         <= secilen_bayt_w;
                    bayt_gecerli_r <= 1'b1;
                    if (bayt_say_r == 2'd3) begin
                        bayt_say_r <= 2'd0;
                        if ((word_say_r + 5'd1) == word_adet_r) begin
                            durum_r <= D_CRC_BEK;
                        end else begin
                            word_say_r     <= word_say_r + 5'd1;
                            durum_r        <= D_WORD;
                            word_iste_r    <= 1'b1;      // SONRAKI istek darbesi
                            yenile_sayac_r <= {YEN_GEN{1'b0}};
                        end
                    end else begin
                        bayt_say_r <= bayt_say_r + 2'd1;
                    end
                end
            end

            // ── CRC yazmacinin yerlesmesini bekle (1 cevrim) ──────────────
            D_CRC_BEK: begin
                durum_r <= D_CRC;
            end

            // ── CRC baytI ─────────────────────────────────────────────────
            //   DIKKAT: bayt_gecerli_r ayni anda CRC birimini de besler.
            //   CRC baytinin KENDISI hesaba katilmamali; bu yuzden burada
            //   bayt_gecerli_r yerine ayri bir yol kullanilir (asagiya bakin).
            D_CRC: begin
                if (g_bayt_hazir) begin
                    bayt_r  <= crc_w;
                    durum_r <= D_BOSTA;
                end
            end

            default: durum_r <= D_BOSTA;    // erisilemez - kilit korumasi

        endcase
    end
end

// ── CRC baytInIn yayInlanmasI (CRC birimine BESLENMEZ) ────────────────────
//   D_CRC durumunda bayt_r'ye crc_w yazilir ama bayt_gecerli_r yukseltilmez;
//   aksi halde CRC kendi kendini yerdi. Bunun yerine ayri bir darbe uretilir.
reg crc_bayt_cik_r;
always @(posedge g_saat or negedge g_sifirla_n) begin
    if (!g_sifirla_n)                        crc_bayt_cik_r <= 1'b0;
    else if ((durum_r == D_CRC) && g_bayt_hazir) crc_bayt_cik_r <= 1'b1;
    else                                     crc_bayt_cik_r <= 1'b0;
end

// ── CIkIs atamalarI ───────────────────────────────────────────────────────
assign c_bayt         = bayt_r;
assign c_bayt_gecerli = bayt_gecerli_r | crc_bayt_cik_r;
assign c_word_iste    = word_iste_r;
assign c_mesgul       = (durum_r != D_BOSTA) | crc_bayt_cik_r;
assign c_uzunluk_hata = uzunluk_hata_r;

endmodule
