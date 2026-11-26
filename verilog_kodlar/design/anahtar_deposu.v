// =============================================================================
// Modül   : anahtar_deposu.v                                       (İster M-17)
// Proje   : FPGA Tabanlı Güvenli Anahtar Yönetimi ve Kripto Hızlandırıcı (5260007)
// -----------------------------------------------------------------------------
// Açıklama:
//   Anahtar slotu deposu. Kalıcı cihaz kimlik anahtarı ile geçici (ephemeral)
//   ECDHE anahtarının AYNI ANDA yaşamasını sağlar — drawio Akış 2 bunu şart
//   koşar: adım 2'de transient anahtar üretilirken, adım 11'de mTLS için
//   kalıcı kimlik anahtarıyla imza atılır. Tek bir d yazmacıyla bu mümkün
//   değildir; önceki sürümde ecdh_kex_top'ta tek bir d_r vardı ve her işlemde
//   TRNG'den yeniden dolduruluyordu.
//
// -----------------------------------------------------------------------------
// *** KALICILIK SINIRI — BU BAŞLIK RAPORA AYNEN GEÇMELİDİR ***
//
//   Bu modüldeki "KALICI" (persistent) nitelemesi OTURUM kalıcılığıdır:
//   anahtar reset'e kadar yaşar, GÜÇ KESİLİNCE KAYBOLUR.
//
//   Sebep mimari değil fizikseldir: FPGA'da kalıcı bellek (NVM) yoktur;
//   slotlar flip-flop dizisidir ve konfigürasyon silinince içerikleri gider.
//   Dolayısıyla bu tasarım, drawio Akış 1'in "cihaz bir kez provisioning
//   edilir, sertifikası ömür boyu geçerlidir" iddiasını TEK BAŞINA
//   KARŞILAMAZ: her güç çevriminde cihaz yeni bir kimlik üretir ve CA'nın
//   imzaladığı sertifika o kimliğe artık uymaz.
//
//   Gerçek kalıcılık için üç yoldan biri gerekir (bu fazın KAPSAMI DIŞINDA):
//     1) QSPI flash + anahtar sarmalama (wrapping). Sarmalama anahtarı
//        eFUSE'ta veya bitstream'de durmalıdır.
//     2) eFUSE / DNA_PORT kökünden KDF ile TÜRETME — anahtar hiç saklanmaz,
//        her açılışta yeniden üretilir. DNA gizli olmadığı için tek başına
//        yeterli değildir, ek gizli bir kökle harmanlanmalıdır.
//     3) Harici güvenli eleman (gerçek SE05x) — o zaman bu modül zaten gerekmez.
//
//   MİMARİ BUNA HAZIRDIR: slot arayüzü (üret / açık anahtar oku / politika /
//   zeroize) değişmeden kalır; NVM eklendiğinde yalnızca slotun ARKASINA
//   depolama bağlanır. Bu yüzden şimdi oturum-kalıcı ilerlemek, ileride
//   yeniden yazım gerektirmez.
//
// -----------------------------------------------------------------------------
// *** GİZLİ ANAHTARIN DIŞARI ÇIKMAMASI ***
//
//   Özel anahtar d için MODÜLDEN DIŞARI TEK BİR YOL vardır: c_ozel_d.
//   Bu port YALNIZCA scalar_multiplier'ın skaler girişine bağlanmalıdır;
//   başka hiçbir yere — TX tamponuna, UART yoluna, LED'e, hata ayıklama
//   sinyaline — bağlanmamalıdır.
//
//   Bu bir "kural" değil, DOĞRULANABİLİR bir iddiadır: TB-16 slotu bilinen
//   bir d ile doldurup modülün tüm diğer çıkışlarını tarar ve d'nin hiçbir
//   32-bit diliminin oralarda görünmediğini kanıtlar.
//
//   Politika bitleri arasında "OKUNABİLİR" DİYE BİR BİT YOKTUR ve
//   eklenmemelidir. Okuma izni kavramının kendisi, bir gün birinin o biti
//   set etmesine kapı açar. Yol yoksa izin de tartışılmaz.
//
// -----------------------------------------------------------------------------
// POLİTİKA — OLUŞTURMA ANINDA BAĞLANIR, SONRADAN DEĞİŞTİRİLEMEZ
//
//   drawio raporundaki düzeltme buydu: SE05x ailesinde nesne politikası
//   oluşturma anında bağlanır, sonradan uygulanamaz. Politika sonraya
//   bırakılırsa arada anahtarın korumasız olduğu bir pencere kalır.
//   Bu modülde politika g_uret ile AYNI çevrimde yazılır; politikayı
//   değiştiren başka hiçbir giriş yoktur.
//
//     bit0 IZIN_ECDH : slot ECDH ortak sır türetmede kullanılabilir
//     bit1 IZIN_IMZA : slot ECDSA imzalamada kullanılabilir (Faz 5)
//     bit2 KALICI    : zeroize bu slotu SİLMEZ (kimlik anahtarı)
//     bit7:3         : ayrılmış, 0 olmalı — sıfır değilse üretim reddedilir
//
//   KALICI slot bir kez üretildikten sonra YENİDEN ÜRETİLEMEZ. Aksi hâlde
//   saldırgan cihazın kimliğini sessizce değiştirebilirdi; sertifika ile
//   anahtar arasındaki bağ kopar ve bunu kimse fark etmez.
//
// -----------------------------------------------------------------------------
// SKALER GEÇERLİLİĞİ: d ∈ [1, n−1]
//   Üretim sırasında REDDETME ÖRNEKLEMESİ uygulanır (indirgeme DEĞİL).
//   İndirgeme (d mod n) dağılımı eğerdi; reddetme düzgün dağılımı korur ve
//   P-256'da reddedilme olasılığı ~2^-32'dir. Kontrol burada yapılır çünkü
//   anahtarın doğruluğu ÜRETİLDİĞİ yerde garanti edilmelidir.
//
// TRNG NOTU:
//   Bu modül entropiyi dışarıdan alır (g_trng_*). Kaynağın kriptografik
//   olması ÇAĞIRANIN sorumluluğudur. Mevcut LFSR demo içindir; ECDSA'ya
//   geçildiğinde gerçek TRNG ZORUNLUDUR.
//
// Kabul kriteri (TB-16):
//   Üretim/okuma turu; slot yalıtımı; politika bağlama ve değişmezliği;
//   kalıcı slotun yeniden üretilememesi; zeroize'ın transient'i silip
//   kalıcıyı korumasi; d ∈ [1,n-1] reddi; ayrılmış politika biti reddi;
//   *** gizli anahtarın hiçbir çıkışta görünmemesi ***.
//
// Standart : Verilog-2001 — sentezlenebilir, latch üretmez
// Tarih    : Temmuz 2026
// =============================================================================

`timescale 1ns / 1ps

// [ALAN OPT. Temmuz 2026] keep_hierarchy KAPATILDI. Bu attribute yalnizca
// hiyerarsik raporlama granulerligini korur; PAYLASIMI ETKILEMEZ — tek MALU /
// tek PAU paylasimi RTL de YAPISALDIR (tek ornek + mux), sentez var olmayan
// ikinci bir ornek yaratamaz. Kapatmak, modul sinirlari arasinda sabit
// yayilimi ve olu mantik elemesini acar (~%5-15 LUT). Hiyerarsik rapor
// gerekirse satiri gecici olarak geri ac.
// (* keep_hierarchy = "yes" *)
module anahtar_deposu #(
    parameter integer SLOT_SAY = 4,
    parameter integer ID_BIT   = 2
)(
    input  wire                 g_saat,
    input  wire                 g_sifirla_n,

    // ── Slot seçimi (üst veri okuma bunun üzerinden kombinasyoneldir) ────
    input  wire [ID_BIT-1:0]    g_slot,

    // ── Anahtar üretimi ──────────────────────────────────────────────────
    input  wire                 g_uret,        // 1 çevrim darbe
    input  wire [7:0]           g_politika,    // oluşturma anında bağlanır
    output wire                 c_uret_bitti,
    output wire                 c_uret_hata,
    output wire [1:0]           c_uret_hata_kod,

    // ── TRNG arayüzü ─────────────────────────────────────────────────────
    output wire                 c_trng_iste,
    input  wire [31:0]          g_trng_word,
    input  wire                 g_trng_vld,

    // ── Açık anahtar geri yazma (kex çekirdeği d·G hesapladıktan sonra) ──
    input  wire                 g_acik_yaz,
    input  wire [255:0]         g_acik_x,
    input  wire [255:0]         g_acik_y,

    // ── Açık anahtar okuma — SERBEST (açık anahtar gizli değildir) ───────
    output wire [255:0]         c_acik_x,
    output wire [255:0]         c_acik_y,
    output wire                 c_acik_gecerli,

    // ── *** ÖZEL ANAHTAR — YALNIZCA scalar_multiplier'A BAĞLANIR *** ─────
    //   Bu portu başka bir yere bağlamak, modülün tüm güvenlik iddiasını
    //   geçersiz kılar. TB-16 bunu tarayarak doğrular.
    output wire [255:0]         c_ozel_d,
    output wire                 c_ozel_gecerli,

    // ── Politika / üst veri ──────────────────────────────────────────────
    output wire [7:0]           c_politika,
    output wire                 c_kalici,

    // İzin sorgusu: istenen kullanım bu slotta serbest mi?
    input  wire [1:0]           g_kullanim,    // bit0=ECDH, bit1=IMZA
    output wire                 c_izin_var,

    // ── Zeroize: transient slotları sil, KALICI olanlara dokunma ─────────
    input  wire                 g_zeroize,

    // ── ÇOKLU EĞRİ DESTEĞİ (Temmuz 2026) ─────────────────────────────────
    //   n ve n'nin bit-uzunluğu artık dışarıdan (parametre_deposu üzerinden,
    //   komut_yoneticisi.v'nin EGRI_* komutlarıyla) yüklenir; P-256 için
    //   sabit değer YOKTUR — reset'te parametre_deposu'nun kendi P-256
    //   varsayılanı geçerli olduğundan davranış değişmez.
    //   g_n_bit_uzunluk gereklidir çünkü TEK BAŞINA g_n_order'ı değiştirmek
    //   yetmez: aşağıdaki reddetme-örneklemesi ham TRNG adayını her zaman
    //   TAM 256 bit üretir; n, 256 bitten belirgin şekilde kısaysa (ör.
    //   P-192'de 192 bit, P-224'te 224 bit) bir adayın n'den küçük çıkma
    //   olasılığı akıl almaz derecede düşer (~2^-64 / ~2^-32) ve
    //   DENEME_MAX=8 bunu asla karşılayamaz — üretim pratikte hep UH_SKALER
    //   ile başarısız olur. Çözüm: adayı n'in bit-uzunluğuna maskelemek
    //   (üst bitleri sıfırlamak), böylece kabul olasılığı P-256'daki gibi
    //   ~2^-32 civarına geri döner. Bkz. aday_maskeli_w.
    input  wire [255:0]         g_n_order,
    input  wire [9:0]           g_n_bit_uzunluk
);

// ── Politika bitleri ──────────────────────────────────────────────────────
localparam integer P_ECDH   = 0,
                   P_IMZA   = 1,
                   P_KALICI = 2;
localparam [7:0]   P_AYRILMIS_MASK = 8'b1111_1000;   // 7:3 sıfır olmalı

// ── Üretim hata kodları ───────────────────────────────────────────────────
localparam [1:0] UH_YOK      = 2'd0,
                 UH_KALICI   = 2'd1,   // kalıcı slot yeniden üretilemez
                 UH_POLITIKA = 2'd2,   // ayrılmış bit set edilmiş
                 UH_SKALER   = 2'd3;   // d, [1,n-1] aralığına sokulamadı

// ── Eğri mertebesi n ARTIK GİRİŞTİR (g_n_order) — bkz. yukarıdaki not.
//   Eski sabit (yalnızca belge/karşılaştırma amacıyla saklanır):
//     P-256 N_ORDER = 256'hffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551

localparam [3:0] DENEME_MAX = 4'd8;

// ── Reddetme-örneklemesi maskesi (ÇOKLU EĞRİ DÜZELTMESİ) ─────────────────
//   Ham TRNG adayı (aday_r) her zaman 256 bit üretilir; n'in gerçek bit-
//   uzunluğundan (g_n_bit_uzunluk) uzun kalan ÜST bitler burada sıfırlanır.
//   P-256'da g_n_bit_uzunluk=256 olduğundan maske tamamen '1' kalır ve
//   davranış birebir korunur (aday_maskeli_w === aday_r).
wire [9:0]   ust_sifir_bit_w = 10'd256 - g_n_bit_uzunluk;   // 0..256, tek çıkarma
wire [255:0] bit_maske_w     = {256{1'b1}} >> ust_sifir_bit_w;
wire [255:0] aday_maskeli_w  = aday_r & bit_maske_w;

// ═════════════════════════════════════════════════════════════════════════
//  SLOT DEPOSU
// ═════════════════════════════════════════════════════════════════════════
//   Kayıtçı (BRAM değil) kullanılır. Sebep denetlenebilirliktir: BRAM'in
//   okuma portu bir veri yoludur ve sentez sonrası nereye gittiğini izlemek
//   zordur. Kayıtçıda özel anahtarın tek bir okuyucusu vardır ve bu, netlist
//   üzerinde doğrudan görülebilir. Maliyet ~3100 FF (%2.5) — kabul edilebilir.
reg [255:0] ozel_r      [0:SLOT_SAY-1];
reg [255:0] acik_x_r    [0:SLOT_SAY-1];
reg [255:0] acik_y_r    [0:SLOT_SAY-1];
reg [7:0]   politika_r  [0:SLOT_SAY-1];
reg         gecerli_r   [0:SLOT_SAY-1];   // özel anahtar mevcut
reg         acik_ger_r  [0:SLOT_SAY-1];   // açık anahtar hesaplanmış

// ── Üretim FSM'i ──────────────────────────────────────────────────────────
localparam [2:0] U_BOSTA = 3'd0,
                 U_ISTE  = 3'd1,
                 U_AL    = 3'd2,
                 U_SIFIR = 3'd3,   // d != 0 kontrolü
                 U_CMP   = 3'd4,   // d < n karşılaştırması
                 U_YAZ   = 3'd5,
                 U_BITTI = 3'd6,
                 U_HATA  = 3'd7;

reg [2:0]         durum_r;
reg [255:0]       aday_r;          // üretilen skaler adayı
reg [2:0]         word_say_r;
reg [2:0]         cmp_idx_r;
reg [3:0]         deneme_r;
reg [ID_BIT-1:0]  hedef_slot_r;
reg [7:0]         hedef_pol_r;

reg               trng_iste_r, uret_bitti_r, uret_hata_r;
reg [1:0]         uret_hata_kod_r;

assign c_trng_iste     = trng_iste_r;
assign c_uret_bitti    = uret_bitti_r;
assign c_uret_hata     = uret_hata_r;
assign c_uret_hata_kod = uret_hata_kod_r;

// ── Okuma yolları (g_slot ile kombinasyonel) ─────────────────────────────
assign c_acik_x       = acik_x_r  [g_slot];
assign c_acik_y       = acik_y_r  [g_slot];
assign c_acik_gecerli = acik_ger_r[g_slot];
assign c_politika     = politika_r[g_slot];
assign c_kalici       = politika_r[g_slot][P_KALICI];
assign c_ozel_d       = ozel_r    [g_slot];
assign c_ozel_gecerli = gecerli_r [g_slot];

// İzin sorgusu: istenen kullanımın TÜM bitleri politikada set olmalı.
// Slot geçersizse izin YOKTUR — boş slotun politikası anlamsızdır.
assign c_izin_var = gecerli_r[g_slot] &&
                    ((g_kullanim & politika_r[g_slot][1:0]) == g_kullanim);

// ── d < n karşılaştırma dilimleri (geniş elde zinciri yok) ───────────────
wire [31:0] cmp_d_dilim_w = aday_maskeli_w[cmp_idx_r*32 +: 32];
wire [31:0] cmp_n_dilim_w = g_n_order     [cmp_idx_r*32 +: 32];

// ── Üretim ön koşulları ───────────────────────────────────────────────────
//   KALICI ve zaten üretilmiş bir slot YENİDEN ÜRETİLEMEZ. Bu, cihaz
//   kimliğinin sessizce değiştirilmesini engeller.
wire kalici_dolu_w   = gecerli_r[g_slot] && politika_r[g_slot][P_KALICI];
wire politika_ok_w   = ((g_politika & P_AYRILMIS_MASK) == 8'd0);

integer i;

always @(posedge g_saat or negedge g_sifirla_n) begin
    if (!g_sifirla_n) begin
        for (i = 0; i < SLOT_SAY; i = i + 1) begin
            ozel_r    [i] <= 256'd0;
            acik_x_r  [i] <= 256'd0;
            acik_y_r  [i] <= 256'd0;
            politika_r[i] <= 8'd0;
            gecerli_r [i] <= 1'b0;
            acik_ger_r[i] <= 1'b0;
        end
        durum_r         <= U_BOSTA;
        aday_r          <= 256'd0;
        word_say_r      <= 3'd0;
        cmp_idx_r       <= 3'd7;
        deneme_r        <= 4'd0;
        hedef_slot_r    <= {ID_BIT{1'b0}};
        hedef_pol_r     <= 8'd0;
        trng_iste_r     <= 1'b0;
        uret_bitti_r    <= 1'b0;
        uret_hata_r     <= 1'b0;
        uret_hata_kod_r <= UH_YOK;
    end else begin
        uret_bitti_r <= 1'b0;
        uret_hata_r  <= 1'b0;

        // ── Açık anahtar geri yazma (üretimden bağımsız) ─────────────────
        if (g_acik_yaz) begin
            acik_x_r  [g_slot] <= g_acik_x;
            acik_y_r  [g_slot] <= g_acik_y;
            acik_ger_r[g_slot] <= 1'b1;
        end

        // ── ZEROIZE: transient slotları sil, KALICI olanlara dokunma ─────
        //   drawio Akış 2 adım 15: oturum kapanınca ephemeral anahtarlar ve
        //   traffic key'ler zeroize edilir. Kalıcı kimlik anahtarı KALIR.
        //   Silme sadece 'gecerli' bayrağını düşürmekle YAPILMAZ; anahtar
        //   malzemesinin kendisi sıfırlanır. Bayrak düşürmek, malzemeyi
        //   yazmaçlarda bırakır ve fiziksel saldırıya açık tutar.
        if (g_zeroize) begin
            for (i = 0; i < SLOT_SAY; i = i + 1) begin
                if (!politika_r[i][P_KALICI]) begin
                    ozel_r    [i] <= 256'd0;
                    acik_x_r  [i] <= 256'd0;
                    acik_y_r  [i] <= 256'd0;
                    politika_r[i] <= 8'd0;
                    gecerli_r [i] <= 1'b0;
                    acik_ger_r[i] <= 1'b0;
                end
            end
        end

        case (durum_r)

        U_BOSTA: begin
            trng_iste_r <= 1'b0;
            if (g_uret) begin
                hedef_slot_r <= g_slot;
                hedef_pol_r  <= g_politika;
                deneme_r     <= 4'd0;
                word_say_r   <= 3'd0;
                if (kalici_dolu_w) begin
                    // Kimlik anahtarı bir kez üretilir; degistirilemez.
                    uret_hata_kod_r <= UH_KALICI;  durum_r <= U_HATA;
                end else if (!politika_ok_w) begin
                    // Ayrilmis bitler sessizce maskelenmez, istek reddedilir.
                    uret_hata_kod_r <= UH_POLITIKA; durum_r <= U_HATA;
                end else begin
                    durum_r <= U_ISTE;
                end
            end
        end

        U_ISTE: begin
            trng_iste_r <= 1'b1;
            word_say_r  <= 3'd0;
            durum_r     <= U_AL;
        end

        U_AL: begin
            trng_iste_r <= 1'b1;
            if (g_trng_vld) begin
                aday_r[word_say_r*32 +: 32] <= g_trng_word;
                if (word_say_r == 3'd7) begin
                    word_say_r  <= 3'd0;
                    trng_iste_r <= 1'b0;
                    durum_r     <= U_SIFIR;
                end else begin
                    word_say_r <= word_say_r + 3'd1;
                end
            end
        end

        U_SIFIR: begin
            if (aday_maskeli_w == 256'd0) begin
                if (deneme_r >= DENEME_MAX) begin
                    uret_hata_kod_r <= UH_SKALER; durum_r <= U_HATA;
                end else begin
                    deneme_r <= deneme_r + 4'd1; durum_r <= U_ISTE;
                end
            end else begin
                cmp_idx_r <= 3'd7;
                durum_r   <= U_CMP;
            end
        end

        // d < n ? — MSB word'den LSB'ye dilim dilim. Reddetme örneklemesi:
        // d >= n ise İNDİRGENMEZ, yeni aday çekilir (modulo bias önlenir).
        U_CMP: begin
            if (cmp_d_dilim_w != cmp_n_dilim_w) begin
                if (cmp_d_dilim_w < cmp_n_dilim_w) begin
                    durum_r <= U_YAZ;                       // d < n : kabul
                end else if (deneme_r >= DENEME_MAX) begin
                    uret_hata_kod_r <= UH_SKALER; durum_r <= U_HATA;
                end else begin
                    deneme_r <= deneme_r + 4'd1; durum_r <= U_ISTE;
                end
            end else if (cmp_idx_r == 3'd0) begin
                // Tüm dilimler eşit → d == n, geçersiz (n·G = O)
                if (deneme_r >= DENEME_MAX) begin
                    uret_hata_kod_r <= UH_SKALER; durum_r <= U_HATA;
                end else begin
                    deneme_r <= deneme_r + 4'd1; durum_r <= U_ISTE;
                end
            end else begin
                cmp_idx_r <= cmp_idx_r - 3'd1;
            end
        end

        // Anahtar ve POLİTİKA aynı çevrimde yazılır — politika sonradan
        // uygulanamaz, arada korumasız pencere kalmaz.
        U_YAZ: begin
            // Depoya MASKELİ aday yazılır — n'den küçük eğrilerde ham 256-bit
            // TRNG çıktısının kullanılmayan üst bitleri asla anahtara karışmaz.
            ozel_r    [hedef_slot_r] <= aday_maskeli_w;
            politika_r[hedef_slot_r] <= hedef_pol_r;
            gecerli_r [hedef_slot_r] <= 1'b1;
            acik_ger_r[hedef_slot_r] <= 1'b0;   // açık anahtar henüz yok
            durum_r <= U_BITTI;
        end

        U_BITTI: begin
            uret_bitti_r <= 1'b1;
            durum_r      <= U_BOSTA;
        end

        U_HATA: begin
            uret_hata_r <= 1'b1;
            durum_r     <= U_BOSTA;
        end

        default: durum_r <= U_BOSTA;

        endcase
    end
end

endmodule
