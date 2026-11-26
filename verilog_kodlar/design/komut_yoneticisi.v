// =============================================================================
// Modül   : komut_yoneticisi.v                                     (İster M-09)
// Proje   : FPGA Tabanlı Güvenli Anahtar Yönetimi ve Kripto Hızlandırıcı (5260007)
// -----------------------------------------------------------------------------
// Açıklama:
//   UART protokolünü ecdh_kex_top denetimine çevirir. Qb tamponunu, sonuç
//   tamponlarını ve çekirdek el sıkışmasını yönetir.
//
//   KOMUT SETI (İster PROT-03):
//     0x01 QB_YUKLE    64 bayt (X||Y, Montgomery)  -> ACK
//     0x02 ECDH_BASLAT  0 bayt                     -> ACK (islem asenkron surer)
//     0x03 QA_OKU       0 bayt                     -> 64 bayt
//     0x04 SIR_OKU      0 bayt                     -> 64 bayt
//     0x05 DURUM_OKU    0 bayt                     -> 0 bayt, DURUM alani doludur
//     0x10 D_YUKLE     32 bayt  *** YALNIZ TEST_MODU ***
//
//   NESNE DEPOSU KOMUTLARI (İster OBJ-01..04) — drawio Akis 1 adim 9/10:
//     0x06 NESNE_YAZ   60 bayt  -> ACK
//          word0 : [7:0]=FileID [23:8]=Ofset(bayt) [31]=SON [30:24]=gecerli_bayt
//          word1..14 : 56 bayt veri
//     0x07 NESNE_OKU    4 bayt  -> 56 bayt
//          word0 : [7:0]=FileID [23:8]=Ofset(bayt)
//     0x08 NESNE_BILGI  4 bayt  ->  4 bayt
//          yanit : [10:0]=uzunluk [16]=kilit [17]=gecerli
//     0x09 NESNE_KILIT  4 bayt  -> ACK   *** TEK YONLU, GERI ALINAMAZ ***
//
//   NEDEN 56 BAYTLIK PARCALAR:
//     Sertifika ~700-800 bayttir ve tek cerceveye sigmaz. Cerceve formatini
//     buyutmek yerine (paket_cozucu projenin en hata-yatkin modulu) veri
//     parcalanir: 4 bayt baslik + 56 bayt veri = 60 bayt, yani 4'un kati ve
//     <=64. Boylece paket_cozucu, paket_kurucu, uart_arayuz ve crc8_hesap
//     DEGISMEDI; TB-06/07/08/09/12 gecerliligini korudu.
//     743 baytlik bir sertifika 14 cerceve = ~65 ms @115200 baud.
//
//   BUTUNLUK:
//     CRC-8 her cerceveyi ayri korur; cok parcali bir transferde tespit
//     edilemeyen hata olasiligi ihmal edilemez. Bu yuzden host, yazdiktan
//     SONRA NESNE_OKU ile geri okuyup karsilastirir. Bu ayni zamanda hattin
//     otesini de dogrular: verinin bellege gercekten dogru yazildigini.
//
//   PROTOKOL DEGISIKLIGI (uygulama sirasinda):
//     DURUM_OKU baslangicta 1 baytlik yanit dondurecekti; ancak protokol
//     uzunlugun 4'un kati olmasini sart kosuyor. Durum bayti zaten yanit
//     cercevesinin DURUM alaninda tasindigi icin veri uzunlugu 0 yapildi.
//     Boylece ek bir istisna kurali gerekmiyor.
//
//   YANIT DURUM KODLARI (İster PROT-05 + SEC-03):
//     0x00 OK
//     0xE1 CRC hatasi        0xE2 bilinmeyen komut   0xE3 uzunluk hatasi
//     0xE4 zaman asimi       0xE5 cekirdek arizasi
//     0xE6 GECERSIZ NOKTA    Qb egri uzerinde degil veya aralik disi
//     0xE7 GECERSIZ SKALER   d, [1, n-1] araligina 8 denemede sokulamadi
//
//   0xE6/0xE7 ile 0xE5 arasindaki fark ONEMLIDIR:
//     0xE5 donanim arizasidir  -> kart sifirlanmali, tekrar denenmeli.
//     0xE6/0xE7 protokol reddidir -> donanim saglamdir, GONDERILEN VERI
//     hatalidir. Host bunlari gorunce kartla ugrasmamali, kendi girdisini
//     duzeltmelidir. Ikisini ayni koda yikmak, invalid-curve saldirisi
//     denemesini siradan bir donanim hatasi gibi gostererek gizlerdi.
//
// -----------------------------------------------------------------------------
// *** GUVENLIK - İster PROT-06 (ZORUNLU) ***
//   1. Gizli anahtar d'yi OKUTAN HICBIR KOMUT YOKTUR ve eklenmemelidir.
//      d yalnizca yazilir (test modunda) veya on-chip uretilir; disari cikan
//      tek veri Qa (acik anahtar) ve Ortak Sir'dir.
//   2. 0x10 D_YUKLE yalnizca `ifdef TEST_MODU altinda derlenir. Uretim
//      bitstream'inde bu komut BILINMEYEN KOMUT olarak reddedilir ve ilgili
//      yol sentezde optimize edilip kaldirilir.
//   3. UART hatti GUVENILIR DEGILDIR. CRC yalnizca gurultuye karsidir;
//      kimlik dogrulama saglamaz. Buradan gelen hicbir komut yetki kaniti
//      olarak gorulmemelidir.
//
//   Ortak Sir'in UART'tan okunabiliyor olmasi BILINCLI bir demo tercihidir;
//   gercek bir dagitimda ortak sir cipten disari cikmamali, dogrudan simetrik
//   sifreleme motoruna beslenmelidir. Bu, dokumanda acikca belirtilmelidir.
//
// -----------------------------------------------------------------------------
// TRNG NOTU:
//   Dahili LFSR-PRNG **KRIPTOGRAFIK DEGILDIR** - yalnizca demo icindir.
//   Uretimde gercek bir entropi kaynagi (ring-osilator TRNG + saglik testi)
//   ile degistirilmelidir. ECDSA'ya gecildiginde nonce icin bu ZORUNLUDUR;
//   tekrarlanan nonce ozel anahtari dogrudan ifsa eder.
//
// Kabul kriteri (TB-11):
//   Sahte kex_top ile tum komut seti; bilinmeyen komut; sira disi komut;
//   TEST_MODU kapali iken 0x10 reddi.
//
// Standart : Verilog-2001 - sentezlenebilir, latch üretmez
// Tarih    : Temmuz 2026
// =============================================================================

`timescale 1ns / 1ps

module komut_yoneticisi #(
    parameter integer LFSR_TOHUM = 32'hACE1_2345
)(
    input  wire        g_saat,
    input  wire        g_sifirla_n,

    // ── uart_arayuz : RX yolu ─────────────────────────────────────────────
    input  wire [7:0]  g_komut,
    input  wire [7:0]  g_uzunluk,
    input  wire        g_komut_gecerli,

    // Kart uzerindeki butondan manuel tetik (UART'siz demo icin).
    // ECDH_BASLAT ile ayni etkiyi yapar ama UART yaniti URETMEZ.
    // Butonu dogrudan cekirdege baglamak YANLIS olurdu: o zaman qa_gecerli /
    // ss_gecerli / hata bayraklari temizlenmez ve bayat durum raporlanir.
    input  wire        g_manuel_basla,

    input  wire [31:0] g_rx_word,
    input  wire        g_rx_word_gecerli,
    input  wire [3:0]  g_rx_indis,
    output wire        c_rx_word_hazir,

    // ── uart_arayuz : TX yolu ─────────────────────────────────────────────
    output wire        c_yanit_basla,
    output wire [7:0]  c_yanit_durum,
    output wire [7:0]  c_yanit_uzunluk,
    output wire [31:0] c_tx_word,
    output wire        c_tx_word_gecerli,
    input  wire        g_tx_word_iste,

    // ── ecdh_kex_top : denetim ────────────────────────────────────────────
    output wire        c_kex_start,
    output wire        c_kex_qb_start,
    output wire [31:0] c_kex_pkt,
    output wire        c_kex_pkt_vld,
    // 0=Qb.x 1=Qb.y 2=r 3=s. r/s yalnizca DOGRULA komutunda kullanilir;
    // Q ise Qb yoluyla gelir — dogrulamada Q zaten karsi tarafin acik
    // anahtaridir, ECDH'deki Qb ile ayni sey.
    output wire [2:0]  c_kex_pkt_sel,

    // ── ecdh_kex_top : sonuc / durum ──────────────────────────────────────
    input  wire [31:0] g_kex_pkt_out,
    input  wire        g_kex_pkt_vld,
    input  wire [1:0]  g_kex_sel,
    input  wire [1:0]  g_kex_stage,
    input  wire        g_kex_qa_done,
    input  wire        g_kex_rdy,
    input  wire        g_kex_done,
    input  wire        g_kex_err,
    // Hata nedeni (İster SEC-03) — g_kex_err ile birlikte geçerlidir.
    // Host'un PROTOKOL hatasını DONANIM arızasından ayırabilmesi için.
    input  wire [2:0]  g_kex_err_kod,

    // ══ FAZ 4: ANAHTAR SLOTU DENETIMI ═══════════════════════════════════
    //   Bu katman yalnizca slot numarasi ve politika gonderir. Ozel anahtar
    //   ecdh_kex_top'un icinde kalir ve buraya HIC gelmez — TB-16'da olculen
    //   sizinti garantisi bu ayrima dayanir.
    output wire [1:0]  c_kex_slot,
    output wire [7:0]  c_kex_politika,
    output wire        c_kex_zeroize,
    // "Sadece anahtar uret" — ECDH oturumu ACMAZ. c_kex_start ile ayni yola
    // gitseydi cekirdek Qa'dan sonra K_QB_WAIT'te asili kalir ve sonraki
    // hicbir komut islenemezdi.
    output wire        c_kex_uret,
    input  wire        g_kex_slot_hata,
    input  wire [1:0]  g_kex_uret_hata_kod,

    // ══ FAZ 5c: ECDSA KOMUT ARAYUZU ═════════════════════════════════════
    //   Bu portlar olmadan imzalama ve dogrulama cekirdekte VAR ama disaridan
    //   ERISILEMEZ durumdaydi (ecdh_uart_top'ta i_imzala/i_dogrula sabit 0).
    //   Ozel anahtar yine bu katmana HIC gelmez; buradan yalnizca SLOT NUMARASI
    //   ve mesaj ozeti gider, geriye (r,s) veya bir hukum doner.
    output wire        c_kex_imzala,
    output wire        c_kex_dogrula,
    output wire [31:0] c_kex_hash_pkt,
    output wire        c_kex_hash_vld,
    input  wire        g_kex_imza_hazir,
    input  wire        g_kex_imza_sel,     // 0 = r, 1 = s
    input  wire        g_kex_imza_gecerli,
    input  wire        g_kex_imza_aralik,

    // ── ecdh_kex_top : TRNG ───────────────────────────────────────────────
    input  wire        g_trng_req,
    output wire [31:0] c_trng_pkt,
    output wire        c_trng_vld,

    // ══ ÇOKLU EĞRİ DESTEĞİ (Temmuz 2026) — İster M-24 ══════════════════════
    //   parametre_deposu bu modülde örneklenir (nesne_deposu ile aynı
    //   sahiplik mantığı: UART protokol katmanı, veri deposunu barındırır).
    //   Çıkışlar ecdh_kex_top.v'ye taşınır ve orada eski P-256 localparam'
    //   larının yerini alır.
    output wire [255:0] c_egri_p,
    output wire [255:0] c_egri_r_mod_p,
    output wire [255:0] c_egri_gx_mont,
    output wire [255:0] c_egri_gy_mont,
    output wire [255:0] c_egri_b_mont,
    output wire [255:0] c_egri_n_order,
    output wire [255:0] c_egri_mont_bir_n,
    output wire [255:0] c_egri_r2n,
    output wire [9:0]   c_egri_p_bit_uzunluk,
    output wire [9:0]   c_egri_n_bit_uzunluk,
    output wire         c_egri_gecerli,

    output wire [7:0]  c_durum
);

// ── Komut kodlari (İster PROT-03) ─────────────────────────────────────────
localparam [7:0] KOM_QB_YUKLE    = 8'h01,
                 KOM_ECDH_BASLAT = 8'h02,
                 KOM_QA_OKU      = 8'h03,
                 KOM_SIR_OKU     = 8'h04,
                 KOM_DURUM_OKU   = 8'h05,
                 KOM_D_YUKLE     = 8'h10,   // yalniz TEST_MODU
                 // ── Nesne deposu komutlari (İster OBJ-01..04) ────────────
                 KOM_NESNE_YAZ   = 8'h06,   // 60 bayt: baslik + 56 bayt veri
                 KOM_NESNE_OKU   = 8'h07,   //  4 bayt baslik -> 56 bayt veri
                 KOM_NESNE_BILGI = 8'h08,   //  4 bayt baslik ->  4 bayt bilgi
                 KOM_NESNE_KILIT = 8'h09,   //  4 bayt baslik -> ACK (TEK YONLU)
                 // ── Anahtar slotu komutlari (İster KEY-01..02) ───────────
                 KOM_ANAHTAR_URET= 8'h0A,   //  4 bayt: slot + politika -> ACK
                 KOM_ZEROIZE     = 8'h0B,   //  0 bayt -> ACK (transient sil)
                 // ── ECDSA komutlari (İster SIG-01..03) ──────────────────
                 //   IMZALA   : 36 bayt = [slot|0|0|0] + e(32) -> 64 bayt (r,s)
                 //   IMZA_YUKLE: 64 bayt = r(32) || s(32) -> ACK
                 //   DOGRULA  : 32 bayt = e(32) -> hukum DURUM bayti icinde
                 //
                 //   DOGRULA'nin operandlari TEK CERCEVEYE SIGMAZ:
                 //   Q(64) + r(32) + s(32) + e(32) = 160 bayt, cerceve siniri
                 //   64 bayt. Bu yuzden ucе bolunur:
                 //     1) 0x01 QB_YUKLE   -> Q  (ECDH'deki Qb ile AYNI sey;
                 //                           yeni komut acmaya gerek yok)
                 //     2) 0x0D IMZA_YUKLE -> r, s
                 //     3) 0x0E DOGRULA    -> e + tetik
                 KOM_IMZALA      = 8'h0C,
                 KOM_IMZA_YUKLE  = 8'h0D,
                 KOM_DOGRULA     = 8'h0E,
                 // ── ÇOKLU EĞRİ KOMUTLARI (İster M-24) ───────────────────
                 //   EGRI_ALAN_YUKLE : 36 bayt = baslik(4,[3:0]=alan_id) +
                 //                      deger(32, 8x32-bit, LSB sozcuk once)
                 //                      -> ACK. alan_id kodlari icin
                 //                      parametre_deposu.v basligina bakin.
                 //   EGRI_UZUNLUK_YUKLE: 4 bayt = {p_bit[19:10],n_bit[9:0]}
                 //                      -> ACK
                 //   EGRI_UYGULA     : 0 bayt -> ACK (yuklemeyi GECERLI say)
                 //   EGRI_VARSAYILAN : 0 bayt -> ACK (P-256 fabrika ayarina don)
                 KOM_EGRI_ALAN_YUKLE    = 8'h11,
                 KOM_EGRI_UZUNLUK_YUKLE = 8'h12,
                 KOM_EGRI_UYGULA        = 8'h13,
                 KOM_EGRI_VARSAYILAN    = 8'h14;

// ── Yanit durum kodlari (İster PROT-05) ───────────────────────────────────
localparam [7:0] YAN_OK          = 8'h00,
                 YAN_CRC_HATA    = 8'hE1,
                 YAN_BILINMEYEN  = 8'hE2,
                 YAN_UZUNLUK     = 8'hE3,
                 YAN_ZAMAN_ASIMI = 8'hE4,
                 YAN_CEKIRDEK    = 8'hE5,
                 // ── Yeni: giriş doğrulama reddi (İster SEC-03) ───────────
                 //   Bunlar donanım arızası DEĞİL, protokol seviyesi rettir.
                 //   Host bunları gördüğünde kartı sıfırlamamalı, gönderdiği
                 //   veriyi düzeltmelidir. YAN_CEKIRDEK ile karıştırılmamalı.
                 YAN_GECERSIZ_NOKTA  = 8'hE6,   // Qb eğri üzerinde değil
                 YAN_GECERSIZ_SKALER = 8'hE7,   // d, [1, n-1] aralığına giremedi
                 // ── Nesne deposu reddi (İster OBJ-05) ───────────────────
                 YAN_NESNE_ID     = 8'hE8,   // FileID slot araligi disinda
                 YAN_NESNE_KILIT  = 8'hE9,   // slot yazma korumali
                 YAN_NESNE_SINIR  = 8'hEA,   // ofset+uzunluk slot sinirini asiyor
                 YAN_NESNE_HIZA   = 8'hEB,   // ofset 4'un kati degil
                 // ── Anahtar slotu reddi (İster KEY-03) ──────────────────
                 YAN_SLOT         = 8'hEC,   // slot gecersiz / uretim reddi
                 YAN_IZIN         = 8'hED,   // slot politikasi izin vermiyor
                 // ── ECDSA dogrulama hukmu (İster SIG-03) ────────────────
                 //   Bunlar ARIZA DEGILDIR: donanim dogru calisti ve imzanin
                 //   GECERSIZ oldugunu bildirdi. Host bunlari gordugunde
                 //   kartla degil, imzayla/mesajla ilgilenmelidir.
                 YAN_IMZA_GECERSIZ = 8'hEE,  // v != r  -> imza tutmuyor
                 YAN_IMZA_ARALIK   = 8'hEF;  // r veya s, [1,n-1] disinda

// ── ecdh_kex_top hata nedeni kodları (ERR_* ile birebir) ─────────────────
localparam [2:0] KERR_NOKTA  = 3'd1,
                 KERR_SKALER = 3'd2,
                 KERR_SLOT   = 3'd5,
                 KERR_IZIN   = 3'd6;

// ── ecdh_kex_top asama kodlari ────────────────────────────────────────────
localparam [1:0] STAGE_QA = 2'b01, STAGE_SS = 2'b10;
localparam [1:0] QBIX_X   = 2'b00, QBIX_Y   = 2'b01;

// ═════════════════════════════════════════════════════════════════════════
//  TAMPONLAR
// ═════════════════════════════════════════════════════════════════════════
reg [31:0] qb_tampon_r [0:15];    // 0..7 = X, 8..15 = Y

// ── FAZ 5c: ECDSA kayitcilari ────────────────────────────────────────────
//   imza_tampon_r CIFT AMACLIDIR:
//     - IMZA_YUKLE ile disaridan (r,s) yazilir  -> DOGRULA girdisi
//     - IMZALA sonucu (r,s) buraya toplanir     -> yanit kaynagi
//   Paylasim bilinclidir: IMZALA'dan sonra DOGRULA cagrilirsa, uretilen imza
//   kendi uzerinde dogrulanir. Bu bir hata degil, kullanisli bir oz-testtir
//   (host betiginde imza_dogrula_kendi() bunu kullanir).
reg [31:0] imza_tampon_r [0:15];   // 0..7 = r, 8..15 = s
reg [31:0] hash_tampon_r [0:7];    // mesaj ozeti e
reg [31:0] imza_baslik_r;          // IMZALA baslik word'u ([1:0] = slot)
reg        kex_imzala_r, kex_dogrula_r;
reg [31:0] kex_hash_pkt_r;
reg        kex_hash_vld_r;
reg [3:0]  imza_yak_r;             // (r,s) toplama indisi
reg        imza_bitti_r;           // hukum/imza hazir
reg [7:0]  dog_yanit_r;            // dogrulama hukmu (DURUM bayti)
reg [31:0] qa_tampon_r [0:15];
reg [31:0] ss_tampon_r [0:15];
reg [31:0] d_tampon_r  [0:7];     // test modunda UART'tan yuklenen d

// ═════════════════════════════════════════════════════════════════════════
//  NESNE DEPOSU (İster OBJ-01) — sertifika / trust anchor saklama
// ═════════════════════════════════════════════════════════════════════════
//   Depo, komut katmanina AITTIR ve burada ornekle­nir. ecdh_uart_top'a
//   tasinsaydi 17 yeni port acmak gerekirdi; depo yalnizca bu modulun
//   komutlariyla erisildigi icin sahipligi burada tutmak daha temiz.
//
//   CERCEVE DUZENI (mevcut UART cercevesi DEGISMEDI — bkz. Faz 2 karari):
//     NESNE_YAZ verisi = 60 bayt = 15 word
//       word0  : [7:0]=FileID  [23:8]=Ofset(bayt)  [31:24]={SON, gecerli[6:0]}
//       word1..14 : 56 bayt veri
//     60 bayt 4'un kati ve <=64 oldugu icin paket_cozucu'nun uzunluk kurali
//     saglanir; 15 word indisi 0..14 olup 4-bit c_word_indis'e sigar.
//
//   Nesnenin GERCEK uzunlugu (orn. 743 bayt) SON bayragi geldiginde
//   ofset+gecerli_bayt olarak kaydedilir. Hattaki 4-hizalama ile nesnenin
//   gercek boyu AYRI seylerdir; bu ayrim sayesinde cerceve formatina hic
//   dokunulmadi.
localparam integer NESNE_SLOT_SAY  = 4;
localparam integer NESNE_SLOT_BAYT = 1024;
localparam integer NESNE_WADR_BIT  = 8;
localparam integer NESNE_UZUN_BIT  = 11;
localparam integer NESNE_VERI_WORD = 14;   // cerceve basina veri word'u (56 bayt)

// Yukaridaki 'integer' localparam'lar yalnizca ORNEKLEME parametresi olarak
// kullanilir. Karsilastirma/aritmetik icin ASLA bit-secimi (orn.
// NVERI_WORD_4) yapilmamalidir: Verilog-2001'de integer tipli bir
// parametre uzerinde part-select davranisi araclara gore degisir ve sessizce
// X uretebilir. X uretirse "==" karsilastirmalari asla saglanmaz ve FSM
// donguye girer. Bu yuzden gereken genislikte AYRI sabitler tanimlanir.
localparam [7:0]  NSLOT_SAY_8   = 8'd4;
localparam [15:0] NSLOT_BAYT_16 = 16'd1024;
localparam [3:0]  NVERI_WORD_4  = 4'd14;
localparam [3:0]  NVERI_SON_4   = 4'd13;   // NVERI_WORD_4 - 1

// RX ve TX tamponlari AYRIDIR. Tek tampon kullanilsaydi hem RX yakalama
// blogu hem ana FSM ayni reg'e yazacak, Verilog'da COKLU SURUCU hatasi
// olusacakti. Ayirmanin maliyeti 512 FF (%0.4) — kabul edilebilir.
// FAZ 4 — anahtar slotu denetim kayitcilari
reg [1:0]  slot_r;
reg [7:0]  slot_politika_r;
reg        zeroize_r;
reg        kex_uret_r;
assign c_kex_slot     = slot_r;
assign c_kex_politika = slot_politika_r;
assign c_kex_zeroize  = zeroize_r;
assign c_kex_uret     = kex_uret_r;
assign c_kex_imzala   = kex_imzala_r;
assign c_kex_dogrula  = kex_dogrula_r;
assign c_kex_hash_pkt = kex_hash_pkt_r;
assign c_kex_hash_vld = kex_hash_vld_r;

reg [31:0] nesne_rx_r [0:15];   // UART'tan gelen: baslik + yazilacak veri
reg [31:0] nesne_tx_r [0:15];   // depodan okunan: yanit cercevesine gidecek

// Depo arayuz kayitcilari
reg [7:0]                    dep_id_r;
reg [NESNE_WADR_BIT-1:0]     dep_wadr_r;
reg [31:0]                   dep_yaz_word_r;
reg                          dep_yaz_vld_r, dep_oku_vld_r;
reg [NESNE_UZUN_BIT-1:0]     dep_uzunluk_r;
reg                          dep_uzunluk_vld_r, dep_kilitle_r;

wire [31:0]                  dep_oku_word_w;
wire                         dep_oku_hazir_w;
wire [NESNE_UZUN_BIT-1:0]    dep_uzunluk_w;
wire                         dep_kilit_w, dep_gecerli_w, dep_hata_w;
wire [1:0]                   dep_hata_kod_w;

nesne_deposu #(
    .SLOT_SAY (NESNE_SLOT_SAY),
    .SLOT_BAYT(NESNE_SLOT_BAYT),
    .SLOT_WORD(NESNE_SLOT_BAYT/4),
    .WADR_BIT (NESNE_WADR_BIT),
    .UZUN_BIT (NESNE_UZUN_BIT)
) depo (
    .g_saat(g_saat), .g_sifirla_n(g_sifirla_n),
    .g_id(dep_id_r), .g_word_adr(dep_wadr_r),
    .g_yaz_word(dep_yaz_word_r), .g_yaz_vld(dep_yaz_vld_r),
    .g_oku_vld(dep_oku_vld_r),
    .c_oku_word(dep_oku_word_w), .c_oku_hazir(dep_oku_hazir_w),
    .g_uzunluk(dep_uzunluk_r), .g_uzunluk_vld(dep_uzunluk_vld_r),
    .g_kilitle(dep_kilitle_r),
    .c_uzunluk(dep_uzunluk_w), .c_kilit(dep_kilit_w), .c_gecerli(dep_gecerli_w),
    .c_hata(dep_hata_w), .c_hata_kod(dep_hata_kod_w)
);

// ── ÇOKLU EĞRİ DESTEĞİ: parametre_deposu örneği (İster M-24) ──────────────
reg [3:0]  pd_alan_id_r;
reg [2:0]  pd_alan_indis_r;
reg [31:0] pd_alan_word_r;
reg        pd_alan_yaz_r;
reg [31:0] pd_uzunluk_word_r;
reg        pd_uzunluk_yaz_r;
reg        pd_uygula_r;
reg        pd_varsayilan_r;

parametre_deposu param_depo (
    .g_saat(g_saat), .g_sifirla_n(g_sifirla_n),
    .g_alan_id(pd_alan_id_r), .g_alan_indis(pd_alan_indis_r),
    .g_alan_word(pd_alan_word_r), .g_alan_yaz(pd_alan_yaz_r),
    .g_uzunluk_word(pd_uzunluk_word_r), .g_uzunluk_yaz(pd_uzunluk_yaz_r),
    .g_uygula(pd_uygula_r), .g_varsayilana_don(pd_varsayilan_r),
    .c_gecerli(c_egri_gecerli),
    .c_p(c_egri_p), .c_r_mod_p(c_egri_r_mod_p),
    .c_gx_mont(c_egri_gx_mont), .c_gy_mont(c_egri_gy_mont),
    .c_b_mont(c_egri_b_mont), .c_n_order(c_egri_n_order),
    .c_mont_bir_n(c_egri_mont_bir_n), .c_r2n(c_egri_r2n),
    .c_p_bit_uzunluk(c_egri_p_bit_uzunluk), .c_n_bit_uzunluk(c_egri_n_bit_uzunluk)
);

// egri_sayac_r: EGRI_ALAN_YUKLE'nin 8 veri sozcugunu parametre_deposu'na
// tek tek surerken kullanilan sayac (S_NES_YAZ'daki nesne_sayac_r ile ayni
// idiom). alan_id_r: nesne_rx_r[0]'dan 1 cevrim gecikmeli okunan hedef alan.
reg [2:0] egri_sayac_r;
reg [3:0] alan_id_r;

// ── Baslik word'unun cozumu (nesne_rx_r[0]) ─────────────────────────────
wire [7:0]  nb_id_w      = nesne_rx_r[0][7:0];
wire [15:0] nb_ofset_w   = nesne_rx_r[0][23:8];
wire        nb_son_w     = nesne_rx_r[0][31];
wire [6:0]  nb_gecerli_w = nesne_rx_r[0][30:24];

// Ofset 4'un kati olmali; degilse word adresine cevrilemez.
// Host her zaman 56'nin (=14 word) katlarini gonderir, dolayisiyla bu kural
// normal akista hic tetiklenmez — bozuk/kotu niyetli istegi yakalar.
wire nb_hiza_ok_w = (nb_ofset_w[1:0] == 2'b00);

// ── Yazilacak word sayisi ────────────────────────────────────────────────
//   SON parcasi kismi olabilir. Her zaman 14 word yazilsaydi, 1024 baytlik
//   (tam slot) bir nesnenin son parcasi ofset 1008'e denk gelir ve 1008+56 =
//   1064 > 1024 olacagi icin REDDEDILIRDI; yani slotun son 16 bayti hicbir
//   zaman kullanilamazdi. Kismi yazma bunu cozer.
//   gecerli_bayt en fazla 56 -> (56+3)>>2 = 14, 4 bite sigar.
wire [3:0] nb_yaz_word_w = nb_son_w ? ((nb_gecerli_w + 7'd3) >> 2)
                                    : NVERI_WORD_4;

// Sinir: yazma yalnizca GERCEKTEN yazilacak word'ler kadar yer ister.
// KIRPMA YOK, ret var — kirpilsaydi tasan yazma komsu slota (trust anchor!)
// sizabilirdi.
wire nb_yaz_sinir_ok_w =
    ((nb_ofset_w + {10'd0, nb_yaz_word_w, 2'b00}) <= NSLOT_BAYT_16);

// Okuma HER ZAMAN 56 bayt dondurur (yanit cercevesi sabit boyutlu), bu yuzden
// okuma icin sinir kurali kati kalir. Aksi halde ofset 1008'den okuma slot
// sinirini asar ve KOMSU SLOTUN icerigi disari sizardi — bu bir yalitim
// ihlalidir. Host, nesnenin kuyrugunu ortusen (overlapping) bir okuma ile alir.
wire nb_oku_sinir_ok_w = ((nb_ofset_w + 16'd56) <= NSLOT_BAYT_16);

wire [NESNE_WADR_BIT-1:0] nb_wadr_taban_w = nb_ofset_w[NESNE_WADR_BIT+1:2];

reg        qb_gecerli_r;          // Qb yuklendi mi
reg        qa_gecerli_r;          // Qa hesaplandi mi
reg        ss_gecerli_r;          // Ortak Sir hesaplandi mi
reg        d_harici_r;            // d UART'tan mi geldi (test modu)
reg        hata_r;                // cekirdek hatasi yakalandi
reg [2:0]  hata_kod_r;            // hatanin nedeni (ecdh_kex_top ERR_* kodu)

// Hata nedenini UART yanit durum bayti'na cevirir. Bilinmeyen/genel nedenler
// eski davranisi korumak icin YAN_CEKIRDEK'e duser.
function [7:0] kod_yanit(input [2:0] kod);
    kod_yanit = (kod == KERR_NOKTA)  ? YAN_GECERSIZ_NOKTA  :
                (kod == KERR_SKALER) ? YAN_GECERSIZ_SKALER :
                (kod == KERR_SLOT)   ? YAN_SLOT            :
                (kod == KERR_IZIN)   ? YAN_IZIN            :
                                       YAN_CEKIRDEK;
endfunction

// YAKALANMIS hata (gecmis bir islemin nedeni) — QA_OKU / SIR_OKU icin.
wire [7:0] hata_yanit_w = kod_yanit(hata_kod_r);

// *** ANLIK hata — g_kex_err ile AYNI CEVRIMDE gecerli ***
//   hata_kod_r, g_kex_err_kod'u AYNI saat kenarinda yakalar; dolayisiyla
//   g_kex_err'in yuksek oldugu cevrimde hata_kod_r hâlâ ESKI degerdedir.
//   S_IMZ_BEK / S_DOG_BEK hatayi tam o cevrimde gordugu icin hata_yanit_w
//   kullanmak bir cevrim GERIDE kalir ve neden ne olursa olsun varsayilan
//   YAN_CEKIRDEK (0xE5) doner.
//
//   TB-25'te belirti tam olarak buydu: cekirdek err_kod = 6 (IZIN) verirken
//   UART'a 0xE5 (CEKIRDEK) basiliyordu. Teshisi yanlis yone cektigi icin
//   kok nedenden ayri, kendi basina duzeltilmesi gereken bir kusurdur.
wire [7:0] anlik_hata_yanit_w = kod_yanit(g_kex_err_kod);

// ═════════════════════════════════════════════════════════════════════════
//  GELEN WORD'LERI TAMPONA YAZ
// ═════════════════════════════════════════════════════════════════════════
reg [7:0] aktif_komut_r;          // isleneni takip et

always @(posedge g_saat or negedge g_sifirla_n) begin
    if (!g_sifirla_n) begin
        qb_gecerli_r <= 1'b0;
        d_harici_r   <= 1'b0;
        // Baslik word'u sifirlanir: bir komut baslik gondermeden bu tamponu
        // okursa X yerine TANIMLI bir deger gorur. X'ler dizi indisine
        // ulastiginda yazma sessizce atlanir ve hata, olustugu yerden cok
        // uzakta ortaya cikar (bkz. asagidaki ANAHTAR_URET notu).
        nesne_rx_r[0] <= 32'd0;
    end else begin
        if (g_rx_word_gecerli) begin
            if (aktif_komut_r == KOM_QB_YUKLE) begin
                qb_tampon_r[g_rx_indis] <= g_rx_word;
                if (g_rx_indis == 4'd15) qb_gecerli_r <= 1'b1;
            end
            // Nesne komutlarinin tamami ayni tamponu kullanir; NESNE_YAZ 15
            // word, digerleri yalnizca 1 word (baslik) gonderir.
            //
            // *** ANAHTAR_URET DE BU TAMPONU KULLANIR ***
            //   S_ANH_BEK, slot ve politikayi nesne_rx_r[0]'dan okur. Komut
            //   bu listede OLMADIGI icin baslik word'u tampona HIC yazilmiyor,
            //   S_ANH_BEK de nesne_rx_r[0]'in eski (ya da hic yazilmamissa X)
            //   degerini okuyordu.
            //
            //   BELIRTI ZINCIRI (TB-25 [D] bolumu):
            //     slot_r <= X, slot_politika_r <= X
            //       -> anahtar_deposu'nda hedef_slot_r = X
            //       -> "ozel_r[X] <= ..." Verilog'da SESSIZCE ATLANIR,
            //          hicbir slot guncellenmez
            //       -> ama c_uret_bitti YINE de darbelenir; cekirdek uretim
            //          basarili sanip 21 ms boyunca X skalerle d.G hesaplar
            //          (TB'nin "anahtar uretimi bitti (2137900 cevrim)" satiri
            //           tam olarak budur — bos yere yanan 21 ms)
            //       -> slot 0'in politikasi bir onceki ECDH_BASLAT'tan kalan
            //          8'h01 (yalniz IZIN_ECDH) olarak KALIR
            //       -> IMZALA, slot 0'da IZIN_IMZA arar, bulamaz
            //       -> ecdh_kex_top K_IM_D_OKU: ERR_IZIN (err_kod = 6)
            //
            //   Hatanin kaynagi imza matematiginde degil, TEK BIR EKSIK
            //   'or' teriminde. Yeni komut eklerken guncellenmesi gereken
            //   yerler artik DORT: beklenen_uzunluk_w + son_indis_w +
            //   S_BOSTA case + BU TAMPON DALI.
            else if (aktif_komut_r == KOM_NESNE_YAZ     ||
                     aktif_komut_r == KOM_NESNE_OKU     ||
                     aktif_komut_r == KOM_NESNE_BILGI   ||
                     aktif_komut_r == KOM_NESNE_KILIT   ||
                     aktif_komut_r == KOM_ANAHTAR_URET) begin
                nesne_rx_r[g_rx_indis] <= g_rx_word;
            end
            // ── EGRI_* komutlari da AYNI paylasimli tamponu kullanir ─────
            //   (nesne komutlariyla ES ZAMANLI ASLA calismazlar — aktif_komut_r
            //   tektir). EGRI_ALAN_YUKLE: word0=baslik([3:0]=alan_id),
            //   word1..8=deger. EGRI_UZUNLUK_YUKLE: word0=uzunluk paketi.
            else if (aktif_komut_r == KOM_EGRI_ALAN_YUKLE ||
                     aktif_komut_r == KOM_EGRI_UZUNLUK_YUKLE) begin
                nesne_rx_r[g_rx_indis] <= g_rx_word;
            end
            // ── ECDSA tamponlari (İster SIG-01..03) ──────────────────────
            //   IMZA_YUKLE : 16 word = r(0..7) || s(8..15)
            //   IMZALA     : word0 = baslik (slot), word1..8 = e
            //   DOGRULA    : word0..7 = e
            //
            //   *** KOM_IMZA_YUKLE DALI BURADAN KALDIRILDI ***
            //   imza_tampon_r'nin TEK yazari asagidaki ayri blok oldu.
            //   Gerekcesi icin o blogun basligina bakin — kisaca: bu dizi
            //   hem buradan hem ana FSM'in S_IMZ_BEK durumundan yaziliyordu
            //   ve sentez bunu reddediyordu.
            else if (aktif_komut_r == KOM_IMZALA) begin
                // slot_r'ye BURADAN yazilamaz: o kayitci ana FSM blogunda
                // suruluyor ve ayni reg'i iki always blogundan surmek
                // COKLU SURUCU hatasidir. Baslik ayri tutulur, ana FSM
                // S_IMZ_HASH'te slot_r'ye aktarir.
                if (g_rx_indis == 4'd0) imza_baslik_r <= g_rx_word;
                else hash_tampon_r[g_rx_indis[2:0] - 3'd1] <= g_rx_word;
            end
            else if (aktif_komut_r == KOM_DOGRULA) begin
                hash_tampon_r[g_rx_indis[2:0]] <= g_rx_word;
            end
`ifdef TEST_MODU
            else if (aktif_komut_r == KOM_D_YUKLE) begin
                d_tampon_r[g_rx_indis[2:0]] <= g_rx_word;
                if (g_rx_indis == 4'd7) d_harici_r <= 1'b1;
            end
`endif
        end
    end
end

// ═════════════════════════════════════════════════════════════════════════
//  imza_tampon_r — TEK YAZAR  (sentez hatasi duzeltmesi)
// -------------------------------------------------------------------------
//  SORUN:
//    Bu dizi İKİ AYRI always blogundan yaziliyordu:
//      1) RX tamponlama blogu   -> IMZA_YUKLE ile disaridan gelen (r,s)
//      2) Ana FSM / S_IMZ_BEK   -> cekirdegin urettigi (r,s)
//    Verilog bunu yasaklamaz (dizi bir net degil), ama iki sonucu vardir:
//      • SENTEZ: Vivado iki yazma portu gorup cift-portlu BRAM cikarmaya
//        calisir ve basaramaz:
//           [Synth 8-4557] Cannot dissolve ram ... because of more than 1 writes
//           [Synth 8-2913] Unsupported Dual Port Block-RAM template
//        Sentez BU YUZDEN duruyordu.
//      • SIMULASYON: iki blok ayni cevrimde yazarsa sonuc TANIMSIZDIR
//        (klasik yaris). Bugun durumlar ayrildigi icin carpismiyorlar, ama
//        bu bir garanti degil, tesadüf.
//
//  Ironi: 30 satir yukarida slot_r icin tam bu tuzak yazili — "ayni reg'i iki
//  always blogundan surmek COKLU SURUCU hatasidir". Kural dogru konmus,
//  imza_tampon_r'de uygulanmamis.
//
//  COZUM: adres/veri/etkin uclusu birlesimsel olarak secilir, yazma TEK
//  yerden yapilir. Oncelik UART'tadir; iki kaynak zaten ayni anda etkin
//  olamaz (biri S_VERI_BEK, digeri S_IMZ_BEK durumunda calisir).
//
//  NOT: Bu blokta ASENKRON RESET YOKTUR ve bu BILINCLIDIR. Dizi veri
//  tamponudur, sifirlanmasi anlamsizdir; reset'e duyarli olmasi ise
//  Vivado'nun RAM cikarimini engelliyordu (8-4767). Onceki surumde de
//  fiilen sifirlanmiyordu — davranis degismedi.
// ═════════════════════════════════════════════════════════════════════════
//  (Blogun KENDISI asagida, durum_r ve S_IMZ_BEK bildirildikten SONRA yer
//   alir — Verilog'da bildirimden once kullanim Vivado'da uyari uretir ve
//   bu derlemede zaten yeterince uyari var.)

// Cozucu her zaman bosaltilabilir (tampon yazma 1 cevrimlik)
assign c_rx_word_hazir = 1'b1;

// ═════════════════════════════════════════════════════════════════════════
//  CEKIRDEK CIKISINI YAKALA (Qa ve Ortak Sir)
// ═════════════════════════════════════════════════════════════════════════
//   ecdh_kex_top X icin 8, ardindan Y icin 8 word basar (o_pkt_sel degisir).
//   Indis = {sel[0], sayac} seklinde 0..15 olusturulur.
reg [2:0] yak_sayac_r;
reg [1:0] yak_sel_r;

wire [2:0] yak_simdi_w  = (g_kex_sel != yak_sel_r) ? 3'd0 : yak_sayac_r;
wire [3:0] yak_indis_w  = {g_kex_sel[0], yak_simdi_w};

always @(posedge g_saat or negedge g_sifirla_n) begin
    if (!g_sifirla_n) begin
        yak_sayac_r  <= 3'd0;
        yak_sel_r    <= 2'b00;
        qa_gecerli_r <= 1'b0;
        ss_gecerli_r <= 1'b0;
        hata_r       <= 1'b0;
        hata_kod_r   <= 3'd0;
    end else begin
        if (g_kex_pkt_vld) begin
            yak_sel_r   <= g_kex_sel;
            yak_sayac_r <= yak_simdi_w + 3'd1;

            if (g_kex_stage == STAGE_QA)      qa_tampon_r[yak_indis_w] <= g_kex_pkt_out;
            else if (g_kex_stage == STAGE_SS) ss_tampon_r[yak_indis_w] <= g_kex_pkt_out;
        end

        if (g_kex_qa_done) qa_gecerli_r <= 1'b1;
        if (g_kex_done)    ss_gecerli_r <= 1'b1;
        // Hata bayragi ile NEDENI birlikte yakalanir. Ilk hata kazanir:
        // sonraki cevrimlerde uretilen genel kodlar asil nedeni ezmemelidir.
        if (g_kex_err && !hata_r) begin
            hata_r     <= 1'b1;
            hata_kod_r <= g_kex_err_kod;
        end

        // Yeni islem baslarken bayraklari temizle
        if (kex_start_r) begin
            qa_gecerli_r <= 1'b0;
            ss_gecerli_r <= 1'b0;
            hata_r       <= 1'b0;
            hata_kod_r   <= 3'd0;
        end
        // *** DIGER CEKIRDEK ISLEMLERI DE HATAYI TEMIZLEMELIDIR ***
        //   Onceden yalnizca kex_start_r (ECDH) temizliyordu. Bir kez hata
        //   olustuktan sonra ANAHTAR_URET / IMZALA / DOGRULA hatayi
        //   sifirlamadigi icin hata_r kalici hâle geliyor ve sonraki
        //   QA_OKU / SIR_OKU komutlari, o islem basarili olsa bile eski
        //   hatayi rapor etmeye devam ediyordu ("hayalet hata").
        //   qa/ss gecerlilik bayraklari BURADA temizlenmez: uret ve imza
        //   ECDH ortak sirrini gecersiz kilmaz.
        else if (kex_uret_r || kex_imzala_r || kex_dogrula_r) begin
            hata_r     <= 1'b0;
            hata_kod_r <= 3'd0;
        end
    end
end

// ═════════════════════════════════════════════════════════════════════════
//  TRNG - LFSR MOCK  (*** KRIPTOGRAFIK DEGIL ***)
// ═════════════════════════════════════════════════════════════════════════
//   TEST_MODU'nda d_harici_r set ise UART'tan gelen d kullanilir; bu, golden
//   model ile bit-bit karsilastirma yapabilmenin TEK yoludur.
localparam [31:0] LFSR_TAPS = 32'hA300_0000;

reg [31:0] lfsr_r;
reg [1:0]  t_durum_r;
reg [2:0]  t_sayac_r;
reg [31:0] trng_pkt_r;
reg        trng_vld_r;

localparam [1:0] T_BOSTA = 2'd0, T_GONDER = 2'd1, T_BEKLE = 2'd2;

wire [31:0] lfsr_sonraki_w = (lfsr_r >> 1) ^ (lfsr_r[0] ? LFSR_TAPS : 32'd0);

always @(posedge g_saat or negedge g_sifirla_n) begin
    if (!g_sifirla_n) begin
        lfsr_r     <= LFSR_TOHUM[31:0];
        t_durum_r  <= T_BOSTA;
        t_sayac_r  <= 3'd0;
        trng_pkt_r <= 32'd0;
        trng_vld_r <= 1'b0;
    end else begin
        trng_vld_r <= 1'b0;
        case (t_durum_r)
            T_BOSTA: if (g_trng_req) begin
                t_sayac_r <= 3'd0;
                t_durum_r <= T_GONDER;
            end
            T_GONDER: begin
                trng_vld_r <= 1'b1;
`ifdef TEST_MODU
                trng_pkt_r <= d_harici_r ? d_tampon_r[t_sayac_r] : lfsr_r;
`else
                trng_pkt_r <= lfsr_r;
`endif
                lfsr_r <= lfsr_sonraki_w;
                if (t_sayac_r == 3'd7) t_durum_r <= T_BEKLE;
                else                   t_sayac_r <= t_sayac_r + 3'd1;
            end
            T_BEKLE: if (!g_trng_req) t_durum_r <= T_BOSTA;
            default: t_durum_r <= T_BOSTA;
        endcase
    end
end

assign c_trng_pkt = trng_pkt_r;
assign c_trng_vld = trng_vld_r;

// ═════════════════════════════════════════════════════════════════════════
//  ANA KOMUT FSM
// ═════════════════════════════════════════════════════════════════════════
// GENISLIK NOTU: durum sayisi 14'ten 22'ye cikti. Bildirim 4 bitte
// birakilirsa 16 ve uzeri sabitler SESSIZCE sarar (S_IMZ_BEK=16 -> 0 =
// S_BOSTA) ve FSM aciklanamaz sekilde bosta durumuna atlar. Ayni sinif hata
// ecdh_kex_top'ta localparam [5:0] olarak yasandi; orada K_DG_CGO(71),
// K_QA_TX_Y(7)'ye cakisip MALU'yu yanlis istemciye vermisti.
localparam [4:0] S_BOSTA    = 5'd0,
                 S_VERI_BEK = 5'd1,   // komutun veri word'lerini bekle
                 S_YANIT    = 5'd2,   // yanit cercevesini baslat
                 S_YANIT_BEK= 5'd3,   // kurucu bitene kadar bekle
                 S_QB_BESLE = 5'd4,   // Qb'yi cekirdege aktar
                 S_QB_GO    = 5'd5,
                 // ── Nesne deposu durumlari (İster OBJ-01..04) ────────────
                 S_NES_BEK  = 5'd6,   // tampon yerlesene kadar 1 cevrim bekle
                 S_NES_ISLE = 5'd7,   // dogrulama + komut ayrimi
                 S_NES_YAZ  = 5'd8,   // 14 word'u depoya yaz
                 S_NES_UZUN = 5'd9,   // SON bayragi geldiyse uzunlugu kaydet
                 S_NES_OKU_I= 5'd10,  // depodan word iste
                 S_NES_OKU_A= 5'd11,  // istenen word'u tampona al
                 // ── FAZ 4: anahtar uretimi ──────────────────────────────
                 S_ANH_BEK  = 5'd12,  // baslik yerlesene kadar bekle
                 S_ANH_GO   = 5'd13,  // cekirdege uretim darbesi ver
                 // ── FAZ 5c: ECDSA durumlari ─────────────────────────────
                 S_IMZ_HASH = 5'd14,  // ozet e'yi cekirdege besle
                 S_IMZ_GO   = 5'd15,  // i_imzala darbesi
                 S_IMZ_BEK  = 5'd16,  // (r,s) paketlerini topla
                 S_DOG_Q    = 5'd17,  // Q -> sel 0/1
                 S_DOG_RS   = 5'd18,  // r,s -> sel 2/3
                 S_DOG_HASH = 5'd19,  // ozet e
                 S_DOG_GO   = 5'd20,  // i_dogrula darbesi
                 S_DOG_BEK  = 5'd21,  // hukmu bekle
                 // ── Cekirdek MUSAIT olana kadar bekle (İster SIG-04) ────
                 //   ANAHTAR_URET ACK'i HEMEN doner ama cekirdek ~21 ms daha
                 //   anahtar uretir. Bu durumda gonderilen IMZALA/DOGRULA
                 //   darbesi cekirdek K_IDLE'da OLMADIGI icin YOK SAYILIR;
                 //   ardindan S_*_BEK, uretimin o_done'unu islemin bitisi
                 //   sanip BOS TAMPONU yanit olarak gonderir.
                 //   Belirti sinsidir: cerceve dogru, uzunluk dogru, durum
                 //   0x00 — ama veri tanimsizdir (simulasyonda X, kartta
                 //   eski/rastgele icerik).
                 S_IMZ_HAZ  = 5'd22,
                 S_DOG_HAZ  = 5'd23,
                 // ── ÇOKLU EĞRİ (İster M-24) ─────────────────────────────
                 S_EGRI_BEK = 5'd24,   // baslik (alan_id) yerlesene kadar bekle
                 S_EGRI_YAZ = 5'd25,   // 8 sozcugu parametre_deposu'na sur
                 S_EGRI_UZUN= 5'd26;   // uzunluk paketini sur

reg [3:0]  nesne_sayac_r;    // 0..13 (14 word)

// Bir komutun SON veri word'unun indisi. Onceki surumde bu, S_VERI_BEK icinde
// gomulu bir ucluydu (QB_YUKLE ? 15 : 7); yeni komutlar eklenince o ifade
// sessizce yanlis calisirdi — nesne komutlari 7. word'u hic gondermedigi icin
// FSM orada takilip kalirdi. Tablo haline getirildi.
reg [3:0]  son_indis_w;
always @(*) begin
    case (aktif_komut_r)
        KOM_QB_YUKLE:    son_indis_w = 4'd15;
        KOM_IMZA_YUKLE:  son_indis_w = 4'd15;   // r(8) + s(8)
        KOM_IMZALA:      son_indis_w = 4'd8;    // baslik + e(8)
        KOM_DOGRULA:     son_indis_w = 4'd7;    // e(8)
        KOM_NESNE_YAZ:   son_indis_w = 4'd14;
        KOM_NESNE_OKU,
        KOM_NESNE_BILGI,
        KOM_NESNE_KILIT,
        KOM_ANAHTAR_URET:son_indis_w = 4'd0;
        // ── ÇOKLU EĞRİ (İster M-24) ──────────────────────────────────────
        KOM_EGRI_ALAN_YUKLE:    son_indis_w = 4'd8;   // baslik + deger(8)
        KOM_EGRI_UZUNLUK_YUKLE: son_indis_w = 4'd0;   // yalniz baslik/veri
        default:         son_indis_w = 4'd7;    // D_YUKLE
    endcase
end

// Bu komut nesne deposuna mi gidiyor?
wire nesne_komutu_w = (aktif_komut_r == KOM_NESNE_YAZ)   ||
                      (aktif_komut_r == KOM_NESNE_OKU)   ||
                      (aktif_komut_r == KOM_NESNE_BILGI) ||
                      (aktif_komut_r == KOM_NESNE_KILIT);

reg [4:0]  durum_r;
reg [4:0]  besle_sayac_r;
reg [3:0]  tx_indis_r;
reg [4:0]  tx_cekilen_r;        // kurucunun cektigi word sayisi (0..16)
// GENISLIK: kaynak sayisi 3'ten 4'e cikti (imza tamponu eklendi).
// 2 bitte birakilirsa 4. kaynak secilemezdi.
reg [2:0]  tx_kaynak_r;         // 0=Qa, 1=SS, 2=nesne, 3=imza
reg        qb_besle_istek_r;    // Qa hazir + Qb yuklu -> besleme bekliyor

reg        kex_start_r, kex_qb_start_r;
reg [31:0] kex_pkt_r;
reg        kex_pkt_vld_r;
reg [2:0]  kex_pkt_sel_r;

// (ECDSA kayitcilari yukarida, RX tamponlarinin yaninda bildirildi)

reg        yanit_basla_r;
reg [7:0]  yanit_durum_r;
reg [7:0]  yanit_uzunluk_r;
reg [31:0] tx_word_r;
reg        tx_word_vld_r;

// ── imza_tampon_r TEK YAZARI (gerekcesi RX tamponlama blogunun altinda) ──
wire imz_yaz_uart_w = g_rx_word_gecerli && (aktif_komut_r == KOM_IMZA_YUKLE);
wire imz_yaz_kex_w  = (durum_r == S_IMZ_BEK) && g_kex_imza_hazir && g_kex_pkt_vld;

wire [3:0]  imz_adr_w = imz_yaz_uart_w ? g_rx_indis
                                       : {g_kex_imza_sel, imza_yak_r[2:0]};
wire [31:0] imz_dat_w = imz_yaz_uart_w ? g_rx_word : g_kex_pkt_out;

always @(posedge g_saat) begin
    if (imz_yaz_uart_w || imz_yaz_kex_w)
        imza_tampon_r[imz_adr_w] <= imz_dat_w;
end

// Beklenen veri uzunlugu / komut gecerliligi
reg        komut_bilinen_w;
reg [7:0]  beklenen_uzunluk_w;

always @(*) begin
    case (g_komut)
        KOM_QB_YUKLE:    begin komut_bilinen_w = 1'b1; beklenen_uzunluk_w = 8'd64; end
        KOM_ECDH_BASLAT: begin komut_bilinen_w = 1'b1; beklenen_uzunluk_w = 8'd0;  end
        KOM_QA_OKU:      begin komut_bilinen_w = 1'b1; beklenen_uzunluk_w = 8'd0;  end
        KOM_SIR_OKU:     begin komut_bilinen_w = 1'b1; beklenen_uzunluk_w = 8'd0;  end
        KOM_DURUM_OKU:   begin komut_bilinen_w = 1'b1; beklenen_uzunluk_w = 8'd0;  end
        // Nesne komutlari — 60 bayt (baslik+veri) veya 4 bayt (yalniz baslik)
        KOM_NESNE_YAZ:   begin komut_bilinen_w = 1'b1; beklenen_uzunluk_w = 8'd60; end
        KOM_NESNE_OKU:   begin komut_bilinen_w = 1'b1; beklenen_uzunluk_w = 8'd4;  end
        KOM_NESNE_BILGI: begin komut_bilinen_w = 1'b1; beklenen_uzunluk_w = 8'd4;  end
        KOM_NESNE_KILIT: begin komut_bilinen_w = 1'b1; beklenen_uzunluk_w = 8'd4;  end
        KOM_ANAHTAR_URET:begin komut_bilinen_w = 1'b1; beklenen_uzunluk_w = 8'd4;  end
        KOM_ZEROIZE:     begin komut_bilinen_w = 1'b1; beklenen_uzunluk_w = 8'd0;  end
        // ── ECDSA (İster SIG-01..03) ────────────────────────────────────
        KOM_IMZALA:      begin komut_bilinen_w = 1'b1; beklenen_uzunluk_w = 8'd36; end
        KOM_IMZA_YUKLE:  begin komut_bilinen_w = 1'b1; beklenen_uzunluk_w = 8'd64; end
        KOM_DOGRULA:     begin komut_bilinen_w = 1'b1; beklenen_uzunluk_w = 8'd32; end
        // ── ÇOKLU EĞRİ (İster M-24) ──────────────────────────────────────
        KOM_EGRI_ALAN_YUKLE:    begin komut_bilinen_w = 1'b1; beklenen_uzunluk_w = 8'd36; end
        KOM_EGRI_UZUNLUK_YUKLE: begin komut_bilinen_w = 1'b1; beklenen_uzunluk_w = 8'd4;  end
        KOM_EGRI_UYGULA:        begin komut_bilinen_w = 1'b1; beklenen_uzunluk_w = 8'd0;  end
        KOM_EGRI_VARSAYILAN:    begin komut_bilinen_w = 1'b1; beklenen_uzunluk_w = 8'd0;  end
`ifdef TEST_MODU
        KOM_D_YUKLE:     begin komut_bilinen_w = 1'b1; beklenen_uzunluk_w = 8'd32; end
`endif
        default:         begin komut_bilinen_w = 1'b0; beklenen_uzunluk_w = 8'd0;  end
    endcase
end

always @(posedge g_saat or negedge g_sifirla_n) begin
    if (!g_sifirla_n) begin
        durum_r         <= S_BOSTA;
        aktif_komut_r   <= 8'd0;
        besle_sayac_r   <= 5'd0;
        tx_indis_r      <= 4'd0;
        tx_cekilen_r    <= 5'd0;
        tx_kaynak_r     <= 3'd0;
        qb_besle_istek_r<= 1'b0;
        kex_start_r     <= 1'b0;
        kex_qb_start_r  <= 1'b0;
        kex_pkt_r       <= 32'd0;
        kex_pkt_vld_r   <= 1'b0;
        kex_pkt_sel_r   <= 3'd0;
        yanit_basla_r   <= 1'b0;
        yanit_durum_r   <= YAN_OK;
        yanit_uzunluk_r <= 8'd0;
        tx_word_r       <= 32'd0;
        tx_word_vld_r   <= 1'b0;
        nesne_sayac_r   <= 4'd0;
        dep_id_r        <= 8'd0;
        dep_wadr_r      <= {NESNE_WADR_BIT{1'b0}};
        dep_yaz_word_r  <= 32'd0;
        dep_yaz_vld_r   <= 1'b0;
        dep_oku_vld_r   <= 1'b0;
        dep_uzunluk_r   <= {NESNE_UZUN_BIT{1'b0}};
        dep_uzunluk_vld_r <= 1'b0;
        dep_kilitle_r   <= 1'b0;
        slot_r          <= 2'd0;
        slot_politika_r <= 8'd0;
        zeroize_r       <= 1'b0;
        kex_uret_r      <= 1'b0;
        kex_imzala_r    <= 1'b0;
        kex_dogrula_r   <= 1'b0;
        kex_hash_pkt_r  <= 32'd0;
        kex_hash_vld_r  <= 1'b0;
        imza_yak_r      <= 4'd0;
        imza_bitti_r    <= 1'b0;
        dog_yanit_r     <= 8'h00;
        pd_alan_id_r      <= 4'd0;
        pd_alan_indis_r   <= 3'd0;
        pd_alan_word_r    <= 32'd0;
        pd_alan_yaz_r     <= 1'b0;
        pd_uzunluk_word_r <= 32'd0;
        pd_uzunluk_yaz_r  <= 1'b0;
        pd_uygula_r       <= 1'b0;
        pd_varsayilan_r   <= 1'b0;
        egri_sayac_r      <= 3'd0;
        alan_id_r         <= 4'd0;
    end else begin
        // Darbe cikislari varsayilan dusuk
        kex_start_r    <= 1'b0;
        kex_qb_start_r <= 1'b0;
        kex_pkt_vld_r  <= 1'b0;
        yanit_basla_r  <= 1'b0;
        tx_word_vld_r  <= 1'b0;
        // Depo darbeleri de her cevrim dusurulur; ilgili durum tekrar kaldirir.
        // Bunlar dusurulmezse tek bir yazma istegi her cevrim tekrarlanir ve
        // adres sayaci ilerlerken bellek bosuna yeniden yazilirdi.
        dep_yaz_vld_r     <= 1'b0;
        dep_oku_vld_r     <= 1'b0;
        dep_uzunluk_vld_r <= 1'b0;
        dep_kilitle_r     <= 1'b0;
        zeroize_r         <= 1'b0;
        kex_uret_r        <= 1'b0;
        kex_imzala_r      <= 1'b0;
        kex_dogrula_r     <= 1'b0;
        kex_hash_vld_r    <= 1'b0;
        pd_alan_yaz_r     <= 1'b0;
        pd_uzunluk_yaz_r  <= 1'b0;
        pd_uygula_r       <= 1'b0;
        pd_varsayilan_r   <= 1'b0;

        // TX word istegi - her durumda yanitla (kurucu DARBE uretir)
        if (g_tx_word_iste) begin
            tx_word_r     <= (tx_kaynak_r == 3'd0) ? qa_tampon_r  [tx_indis_r] :
                             (tx_kaynak_r == 3'd1) ? ss_tampon_r  [tx_indis_r] :
                             (tx_kaynak_r == 3'd3) ? imza_tampon_r[tx_indis_r] :
                                                     nesne_tx_r   [tx_indis_r];
            tx_word_vld_r <= 1'b1;
            tx_indis_r    <= tx_indis_r + 4'd1;
            tx_cekilen_r  <= tx_cekilen_r + 5'd1;
        end

        // Qa hazir + Qb yuklu -> besleme istegini KAYDET (hemen uygulama).
        // Dogrudan durum_r'ye yazilirsa ayni cevrimde gelen bir komutu ezer.
        if (g_kex_qa_done && qb_gecerli_r) qb_besle_istek_r <= 1'b1;

        case (durum_r)

            // ── Komut bekleniyor ──────────────────────────────────────────
            //   Oncelik: UART komutu > manuel buton > bekleyen Qb beslemesi.
            S_BOSTA: begin
                if (g_komut_gecerli) begin
                    aktif_komut_r <= g_komut;

                    if (!komut_bilinen_w) begin
                        // Bilinmeyen komut - TEST_MODU kapaliyken 0x10 buraya duser
                        yanit_durum_r   <= YAN_BILINMEYEN;
                        yanit_uzunluk_r <= 8'd0;
                        durum_r         <= S_YANIT;
                    end else if (g_uzunluk != beklenen_uzunluk_w) begin
                        yanit_durum_r   <= YAN_UZUNLUK;
                        yanit_uzunluk_r <= 8'd0;
                        durum_r         <= S_YANIT;
                    end else begin
                        case (g_komut)
                            KOM_QB_YUKLE: durum_r <= S_VERI_BEK;
`ifdef TEST_MODU
                            KOM_D_YUKLE:  durum_r <= S_VERI_BEK;
`endif
                            // ── Nesne komutlari (İster OBJ-01..04) ────────
                            //   Dordu de once veri asamasina girer: NESNE_YAZ
                            //   15 word (baslik+veri), digerleri 1 word
                            //   (yalniz baslik). Ayrim son_indis_w tablosunda
                            //   yapilir; burada hepsi ayni yola gider.
                            //
                            //   NOT: Bu dal ilk yazimda ATLANMISTI. Komutlar
                            //   beklenen_uzunluk_w ve son_indis_w tablolarina
                            //   eklendigi hâlde buraya eklenmeyince default'a
                            //   dusup 0xE2 donuyordu — komut "biliniyor" ama
                            //   "yonlendirilmiyor"du. Yeni komut eklerken bu
                            //   UC yerin birlikte guncellenmesi gerekir.
                            KOM_NESNE_YAZ,
                            KOM_NESNE_OKU,
                            KOM_NESNE_BILGI,
                            KOM_NESNE_KILIT,
                            // ANAHTAR_URET de baslik word'u bekler (slot+politika)
                            KOM_ANAHTAR_URET,
                            // ── ECDSA komutlari ──────────────────────────
                            //   Ucu de once veri asamasina girer; ayrim
                            //   son_indis_w tablosunda yapilir.
                            //   (Yukaridaki UC-YER kuralini hatirla:
                            //    beklenen_uzunluk_w + son_indis_w + BU case)
                            KOM_IMZALA,
                            KOM_IMZA_YUKLE,
                            KOM_DOGRULA,
                            // ── ÇOKLU EĞRİ (İster M-24) — veri asamasina gir
                            KOM_EGRI_ALAN_YUKLE,
                            KOM_EGRI_UZUNLUK_YUKLE: durum_r <= S_VERI_BEK;

                            // ZEROIZE veri almaz: oturum kapanisinda transient
                            // anahtarlari siler. KALICI kimlik anahtari korunur
                            // (drawio Akis 2 adim 15).
                            KOM_ZEROIZE: begin
                                zeroize_r       <= 1'b1;
                                yanit_durum_r   <= YAN_OK;
                                yanit_uzunluk_r <= 8'd0;
                                durum_r         <= S_YANIT;
                            end
                            // ── ÇOKLU EĞRİ: anlık (0 bayt) komutlar ───────
                            KOM_EGRI_UYGULA: begin
                                pd_uygula_r     <= 1'b1;
                                yanit_durum_r   <= YAN_OK;
                                yanit_uzunluk_r <= 8'd0;
                                durum_r         <= S_YANIT;
                            end
                            KOM_EGRI_VARSAYILAN: begin
                                pd_varsayilan_r <= 1'b1;
                                yanit_durum_r   <= YAN_OK;
                                yanit_uzunluk_r <= 8'd0;
                                durum_r         <= S_YANIT;
                            end
                            // ── ECDH_BASLAT — eski (legacy) akis ──────────
                            //   Anlami: "slot 0'da GECICI bir ECDH anahtari
                            //   uret ve Qa = d.G hesapla". Yani
                            //   ANAHTAR_URET(slot=0, politika=ECDH) ile
                            //   esdegerdir; eski host betikleri calismaya
                            //   devam etsin diye korunmustur.
                            //
                            //   *** POLITIKA BURADA MUTLAKA KURULMALI ***
                            //   Kurulmazsa slot_politika_r reset degeri olan
                            //   0'da kalir; anahtar HICBIR IZNI OLMADAN
                            //   uretilir ve ardindan K_IZIN dogru sekilde
                            //   ECDH'yi reddeder. Belirti kafa karistiricidir:
                            //   Qa dogru hesaplanir (uretim calisir), ama
                            //   ortak sir asamasi hata verir.
                            //
                            //   KALICI DEGIL: her ECDH_BASLAT yeni bir gecici
                            //   anahtar uretebilsin diye. Kalici olsaydi
                            //   ikinci cagri UH_KALICI ile reddedilirdi.
                            KOM_ECDH_BASLAT: begin
                                slot_r          <= 2'd0;
                                slot_politika_r <= 8'h01;   // yalniz IZIN_ECDH
                                kex_start_r     <= 1'b1;
                                yanit_durum_r   <= YAN_OK;
                                yanit_uzunluk_r <= 8'd0;
                                durum_r         <= S_YANIT;
                            end
                            KOM_QA_OKU: begin
                                tx_kaynak_r     <= 3'd0;
                                tx_indis_r      <= 4'd0;
                                yanit_durum_r   <= hata_r ? hata_yanit_w : YAN_OK;
                                yanit_uzunluk_r <= 8'd64;
                                durum_r         <= S_YANIT;
                            end
                            KOM_SIR_OKU: begin
                                tx_kaynak_r     <= 3'd1;
                                tx_indis_r      <= 4'd0;
                                yanit_durum_r   <= hata_r ? hata_yanit_w : YAN_OK;
                                yanit_uzunluk_r <= 8'd64;
                                durum_r         <= S_YANIT;
                            end
                            KOM_DURUM_OKU: begin
                                yanit_durum_r   <= c_durum;   // durum DURUM alaninda
                                yanit_uzunluk_r <= 8'd0;
                                durum_r         <= S_YANIT;
                            end
                            default: begin
                                yanit_durum_r   <= YAN_BILINMEYEN;
                                yanit_uzunluk_r <= 8'd0;
                                durum_r         <= S_YANIT;
                            end
                        endcase
                    end
                end else if (g_manuel_basla) begin
                    // Buton tetigi: cekirdegi baslat, UART yaniti URETME.
                    // kex_start_r, yakalama blogunda bayraklari da temizler.
                    // Politika ECDH_BASLAT ile AYNI kurulmalidir; aksi halde
                    // butonla baslatilan islem izin kontrolunde reddedilir
                    // ve belirti yalnizca kartta gorulur (LED hata yanar),
                    // UART'ta hicbir iz kalmaz — teshisi cok zor bir hata.
                    slot_r          <= 2'd0;
                    slot_politika_r <= 8'h01;   // yalniz IZIN_ECDH
                    kex_start_r <= 1'b1;
                end else if (qb_besle_istek_r) begin
                    qb_besle_istek_r <= 1'b0;
                    besle_sayac_r    <= 5'd0;
                    durum_r          <= S_QB_BESLE;
                end
            end

            // ── Veri word'leri tamponlaniyor (yazma ayri blokta) ──────────
            S_VERI_BEK: begin
                if (g_rx_word_gecerli && (g_rx_indis == son_indis_w)) begin
                    if (aktif_komut_r == KOM_ANAHTAR_URET) begin
                        // Baslik bu cevrimde yaziliyor; bir cevrim bekle.
                        durum_r <= S_ANH_BEK;
                    end
                    // ── ECDSA: IMZALA ────────────────────────────────────
                    //   Ozet cekirdege beslenir, sonra i_imzala darbesi.
                    //   SIRA ONEMLI: cekirdek hash_cnt_r'yi i_imzala ile
                    //   sifirlar; ozet ONCE gitmelidir.
                    else if (aktif_komut_r == KOM_IMZALA) begin
                        besle_sayac_r <= 5'd0;
                        imza_yak_r    <= 4'd0;
                        imza_bitti_r  <= 1'b0;
                        durum_r       <= S_IMZ_HAZ;
                    end
                    // ── ECDSA: DOGRULA ───────────────────────────────────
                    //   Q (QB_YUKLE tamponundan) + r,s (IMZA_YUKLE
                    //   tamponundan) + e (bu cerceveden) beslenir.
                    else if (aktif_komut_r == KOM_DOGRULA) begin
                        besle_sayac_r <= 5'd0;
                        imza_bitti_r  <= 1'b0;
                        durum_r       <= S_DOG_HAZ;
                    end
                    else if (nesne_komutu_w) begin
                        // Baslik word'u bu cevrimde tampona YAZILIYOR (non-
                        // blocking), degeri henuz okunamaz. Bir cevrim beklenir.
                        durum_r <= S_NES_BEK;
                    end
                    // ── ÇOKLU EĞRİ (İster M-24) ───────────────────────────
                    //   Nesne komutlarindaki AYNI sebepten (non-blocking
                    //   yazma) 1 cevrim beklenir.
                    else if (aktif_komut_r == KOM_EGRI_ALAN_YUKLE) begin
                        egri_sayac_r <= 3'd0;
                        durum_r      <= S_EGRI_BEK;
                    end
                    else if (aktif_komut_r == KOM_EGRI_UZUNLUK_YUKLE) begin
                        durum_r <= S_EGRI_UZUN;
                    end
                    else begin
                        yanit_durum_r   <= YAN_OK;
                        yanit_uzunluk_r <= 8'd0;
                        durum_r         <= S_YANIT;
                    end
                end
            end

            // ── Nesne komutlari ───────────────────────────────────────────
            //   Tampon yerlesti; FileID'yi depoya sur ki bir sonraki cevrimde
            //   ust veri (uzunluk/kilit/gecerli) okunabilsin — bunlar
            //   dep_id_r uzerinden kombinasyoneldir.
            S_NES_BEK: begin
                dep_id_r       <= nb_id_w;
                nesne_sayac_r  <= 4'd0;
                durum_r        <= S_NES_ISLE;
            end

            //   TUM dogrulamalar burada, TEK yerde yapilir. Depo kendi
            //   icinde de sinir/kilit kontrolu yapar (savunma katmani), ama
            //   host'a ANLAMLI bir hata kodu donebilmek icin ayrimi burada
            //   yapmak gerekiyor: depo yalnizca 2-bit kod uretir.
            S_NES_ISLE: begin
                yanit_uzunluk_r <= 8'd0;
                tx_indis_r      <= 4'd0;

                if (nb_id_w >= NSLOT_SAY_8) begin
                    yanit_durum_r <= YAN_NESNE_ID;   durum_r <= S_YANIT;
                end
                // Kilit yalnizca YAZMA yolunu keser. Okuma ve bilgi serbesttir:
                // sertifika gizli degildir, yalnizca DEGISTIRILEMEZ olmalidir.
                else if ((aktif_komut_r == KOM_NESNE_YAZ) && dep_kilit_w) begin
                    yanit_durum_r <= YAN_NESNE_KILIT; durum_r <= S_YANIT;
                end
                else if ((aktif_komut_r == KOM_NESNE_YAZ ||
                          aktif_komut_r == KOM_NESNE_OKU) && !nb_hiza_ok_w) begin
                    yanit_durum_r <= YAN_NESNE_HIZA;  durum_r <= S_YANIT;
                end
                else if ((aktif_komut_r == KOM_NESNE_YAZ) && !nb_yaz_sinir_ok_w) begin
                    yanit_durum_r <= YAN_NESNE_SINIR; durum_r <= S_YANIT;
                end
                else if ((aktif_komut_r == KOM_NESNE_OKU) && !nb_oku_sinir_ok_w) begin
                    yanit_durum_r <= YAN_NESNE_SINIR; durum_r <= S_YANIT;
                end
                else begin
                    case (aktif_komut_r)
                        // Bos SON parcasi (gecerli_bayt=0) yazacak word
                        // birakmaz; dogrudan uzunluk kaydina gecilir.
                        KOM_NESNE_YAZ: durum_r <= (nb_yaz_word_w == 4'd0)
                                                  ? S_NES_UZUN : S_NES_YAZ;
                        KOM_NESNE_OKU: durum_r <= S_NES_OKU_I;
                        KOM_NESNE_BILGI: begin
                            // 4 baytlik bilgi word'u: uzunluk + bayraklar
                            nesne_tx_r[0]   <= {14'd0, dep_gecerli_w, dep_kilit_w,
                                                5'd0, dep_uzunluk_w};
                            tx_kaynak_r     <= 3'd2;
                            yanit_durum_r   <= YAN_OK;
                            yanit_uzunluk_r <= 8'd4;
                            durum_r         <= S_YANIT;
                        end
                        KOM_NESNE_KILIT: begin
                            // TEK YONLU. Kilidi acan bir komut YOKTUR ve
                            // eklenmemelidir; trust anchor garantisi buna dayanir.
                            dep_kilitle_r <= 1'b1;
                            yanit_durum_r <= YAN_OK;
                            durum_r       <= S_YANIT;
                        end
                        default: begin
                            yanit_durum_r <= YAN_BILINMEYEN; durum_r <= S_YANIT;
                        end
                    endcase
                end
            end

            // ── 14 word'u (56 bayt) depoya yaz ────────────────────────────
            //   word0 basliktir, veri word1'den baslar → tampon indisi +1.
            S_NES_YAZ: begin
                dep_wadr_r     <= nb_wadr_taban_w + {4'd0, nesne_sayac_r};
                dep_yaz_word_r <= nesne_rx_r[nesne_sayac_r + 4'd1];
                dep_yaz_vld_r  <= 1'b1;
                // BITIS KOSULU — ">=" kullanilir, "==" DEGIL.
                //   "==" ile nb_yaz_word_w beklenmedik bir deger alirsa
                //   (X, ya da sayacin hic ugramadigi bir sayi) esitlik ASLA
                //   saglanmaz; nesne_sayac_r 0..15 arasinda sonsuza kadar
                //   doner ve FSM S_NES_YAZ'da kilitlenir. Kilitlenen FSM
                //   S_BOSTA'ya donmedigi icin modul TAMAMEN saglirlasir —
                //   tek bir bozuk baslik butun arayuzu oldurur.
                //   ">=" ve ust sinir, bu sinifi tamamen ortadan kaldirir.
                if ((nesne_sayac_r >= nb_yaz_word_w - 4'd1) ||
                    (nesne_sayac_r >= NVERI_SON_4)) begin
                    nesne_sayac_r <= 4'd0;
                    durum_r       <= S_NES_UZUN;
                end else begin
                    nesne_sayac_r <= nesne_sayac_r + 4'd1;
                end
            end

            // ── ÇOKLU EĞRİ: baslikten alan_id oku (İster M-24) ────────────
            //   nesne_rx_r[0] bir onceki cevrimde (non-blocking) yazildi,
            //   burada ilk kez guvenle okunabilir (S_NES_BEK ile ayni idiom).
            S_EGRI_BEK: begin
                alan_id_r <= nesne_rx_r[0][3:0];
                durum_r   <= S_EGRI_YAZ;
            end

            // ── ÇOKLU EĞRİ: 8 sozcugu parametre_deposu'na sur ─────────────
            //   word1..8 -> alan_indis 0..7 (LSB sozcuk once, tum kod
            //   tabaninda kullanilan kural — bkz. P256[cnt*32+:32] deseni).
            S_EGRI_YAZ: begin
                pd_alan_id_r    <= alan_id_r;
                pd_alan_indis_r <= egri_sayac_r;
                pd_alan_word_r  <= nesne_rx_r[egri_sayac_r + 4'd1];
                pd_alan_yaz_r   <= 1'b1;
                if (egri_sayac_r == 3'd7) begin
                    egri_sayac_r    <= 3'd0;
                    yanit_durum_r   <= YAN_OK;
                    yanit_uzunluk_r <= 8'd0;
                    durum_r         <= S_YANIT;
                end else begin
                    egri_sayac_r <= egri_sayac_r + 3'd1;
                end
            end

            // ── ÇOKLU EĞRİ: bit-uzunluk paketini sur ──────────────────────
            S_EGRI_UZUN: begin
                pd_uzunluk_word_r <= nesne_rx_r[0];
                pd_uzunluk_yaz_r  <= 1'b1;
                yanit_durum_r     <= YAN_OK;
                yanit_uzunluk_r   <= 8'd0;
                durum_r           <= S_YANIT;
            end

            // ── FAZ 4: ANAHTAR URETIMI ────────────────────────────────────
            //   Baslik word0: [1:0]=slot  [15:8]=politika
            //   Slot ve politika cekirdege surulur, sonra i_start darbesi.
            //   Cekirdek d'yi uretir, Qa=d.G hesaplar ve Qa'yi slota geri yazar.
            //   Ozel anahtar bu katmana HIC gelmez.
            S_ANH_BEK: begin
                slot_r          <= nesne_rx_r[0][1:0];
                slot_politika_r <= nesne_rx_r[0][15:8];
                durum_r         <= S_ANH_GO;
            end

            S_ANH_GO: begin
                kex_uret_r      <= 1'b1;   // 'sadece uret', oturum ACMA
                yanit_durum_r   <= YAN_OK;   // uretim ASENKRON surer
                yanit_uzunluk_r <= 8'd0;
                durum_r         <= S_YANIT;
            end

            // ── SON parcasi ise nesnenin GERCEK uzunlugunu kaydet ─────────
            //   Hattaki 4-hizalama (56 bayt sabit) ile nesnenin gercek boyu
            //   (orn. 743 bayt) AYRI seylerdir. Gercek boy ancak SON bayragi
            //   ile birlikte gelen gecerli_bayt sayisindan bilinir.
            S_NES_UZUN: begin
                if (nb_son_w) begin
                    dep_uzunluk_r     <= nb_ofset_w[NESNE_UZUN_BIT-1:0]
                                       + {4'd0, nb_gecerli_w};
                    dep_uzunluk_vld_r <= 1'b1;
                end
                yanit_durum_r   <= YAN_OK;
                yanit_uzunluk_r <= 8'd0;
                durum_r         <= S_YANIT;
            end

            // ── Depodan 14 word on-getir (BRAM 1 cevrim gecikmeli) ────────
            //   Once tampona toplanir, sonra yanit baslar. Dogrudan TX yoluna
            //   baglansaydi BRAM gecikmesi ile kurucunun darbeli word istegi
            //   arasinda hizalama kurmak gerekirdi; on-getirme mevcut TX
            //   yolunu HIC degistirmeden calismasini sagliyor.
            S_NES_OKU_I: begin
                dep_wadr_r    <= nb_wadr_taban_w + {4'd0, nesne_sayac_r};
                dep_oku_vld_r <= 1'b1;
                durum_r       <= S_NES_OKU_A;
            end

            S_NES_OKU_A: begin
                if (dep_oku_hazir_w) begin
                    nesne_tx_r[nesne_sayac_r] <= dep_oku_word_w;
                    if (nesne_sayac_r == NVERI_SON_4) begin
                        nesne_sayac_r   <= 4'd0;
                        tx_kaynak_r     <= 3'd2;
                        tx_indis_r      <= 4'd0;
                        yanit_durum_r   <= YAN_OK;
                        yanit_uzunluk_r <= 8'd56;
                        durum_r         <= S_YANIT;
                    end else begin
                        nesne_sayac_r <= nesne_sayac_r + 4'd1;
                        durum_r       <= S_NES_OKU_I;
                    end
                end
            end

            // ── Yanit cercevesini baslat ──────────────────────────────────
            S_YANIT: begin
                yanit_basla_r <= 1'b1;
                tx_cekilen_r  <= 5'd0;         // cekilen word sayacini sifirla
                durum_r       <= S_YANIT_BEK;
            end

            //   BITIS KOSULU: cekilen word sayisi beklenen sayiya ulasmali.
            //   Ilk surumde "tx_indis_r == 0" kullanilmisti; bu, cerceve daha
            //   BASLAMADAN da dogru oldugu icin yanit aninda iptal oluyordu.
            S_YANIT_BEK: begin
                if (yanit_uzunluk_r == 8'd0)
                    durum_r <= S_BOSTA;
                else if (tx_cekilen_r == yanit_uzunluk_r[6:2])   // uzunluk/4
                    durum_r <= S_BOSTA;
            end

            // ── Qa hazir oldugunda Qb'yi cekirdege besle ──────────────────
            S_QB_BESLE: begin
                kex_pkt_vld_r <= 1'b1;
                kex_pkt_sel_r <= (besle_sayac_r < 5'd8) ? 3'd0 : 3'd1;
                kex_pkt_r     <= qb_tampon_r[besle_sayac_r[3:0]];
                if (besle_sayac_r == 5'd15) begin
                    besle_sayac_r <= 5'd0;
                    durum_r       <= S_QB_GO;
                end else begin
                    besle_sayac_r <= besle_sayac_r + 5'd1;
                end
            end

            S_QB_GO: begin
                kex_qb_start_r <= 1'b1;
                durum_r        <= S_BOSTA;
            end

            // ═══════════════════════════════════════════════════════════
            //  ECDSA IMZALAMA  (0x0C)
            // ═══════════════════════════════════════════════════════════
            // Cekirdek bosa dusene kadar bekle. g_kex_rdy YALNIZCA K_IDLE'da
            // ve islem sonunda yuksektir; boylece darbe kaybolmaz.
            S_IMZ_HAZ: begin
                if (g_kex_rdy) durum_r <= S_IMZ_HASH;
            end

            S_DOG_HAZ: begin
                if (g_kex_rdy) durum_r <= S_DOG_Q;
            end

            S_IMZ_HASH: begin
                kex_hash_vld_r <= 1'b1;
                kex_hash_pkt_r <= hash_tampon_r[besle_sayac_r[2:0]];
                slot_r         <= imza_baslik_r[1:0];
                if (besle_sayac_r == 5'd7) begin
                    besle_sayac_r <= 5'd0;
                    durum_r       <= S_IMZ_GO;
                end else besle_sayac_r <= besle_sayac_r + 5'd1;
            end

            S_IMZ_GO: begin
                kex_imzala_r <= 1'b1;
                durum_r      <= S_IMZ_BEK;
            end

            // Cekirdek (r,s)'yi 8'er word olarak basar; o_imza_sel ayirir.
            // Bu, ~44 ms suren bir islemdir — FSM burada uzun sure bekler,
            // bu sirada baska komut ISLENMEZ. Host bunu bilerek beklemelidir.
            S_IMZ_BEK: begin
                // imza_tampon_r'ye YAZMA BURADA DEGIL — tek yazar blogunda.
                // Burada yalnizca toplama indisi ilerletilir.
                if (g_kex_imza_hazir && g_kex_pkt_vld) begin
                    imza_yak_r <= imza_yak_r + 4'd1;
                end
                if (g_kex_err) begin
                    // Izin reddi burada yakalanir: IMZA politikasi olmayan
                    // bir slotla imza istenirse cekirdek ozel anahtari HIC
                    // okumadan reddeder (bkz. ecdh_kex_top K_IZIN).
                    // ANLIK kod kullanilir — hata_kod_r bu cevrimde henuz eski.
                    yanit_durum_r   <= anlik_hata_yanit_w;
                    yanit_uzunluk_r <= 8'd0;
                    durum_r         <= S_YANIT;
                end else if (g_kex_done) begin
                    tx_kaynak_r     <= 3'd3;      // imza_tampon_r
                    tx_indis_r      <= 4'd0;
                    yanit_durum_r   <= YAN_OK;
                    yanit_uzunluk_r <= 8'd64;     // r || s
                    durum_r         <= S_YANIT;
                end
            end

            // ═══════════════════════════════════════════════════════════
            //  ECDSA DOGRULAMA  (0x0E)
            // ═══════════════════════════════════════════════════════════
            //   Operand sirasi cekirdegin K_IDLE yukleyicisiyle uyumludur:
            //   sel 0=Q.x  1=Q.y  2=r  3=s ; e ayri hash yolundan gider.
            S_DOG_Q: begin
                kex_pkt_vld_r <= 1'b1;
                kex_pkt_sel_r <= (besle_sayac_r < 5'd8) ? 3'd0 : 3'd1;
                kex_pkt_r     <= qb_tampon_r[besle_sayac_r[3:0]];
                if (besle_sayac_r == 5'd15) begin
                    besle_sayac_r <= 5'd0;
                    durum_r       <= S_DOG_RS;
                end else besle_sayac_r <= besle_sayac_r + 5'd1;
            end

            S_DOG_RS: begin
                kex_pkt_vld_r <= 1'b1;
                kex_pkt_sel_r <= (besle_sayac_r < 5'd8) ? 3'd2 : 3'd3;
                kex_pkt_r     <= imza_tampon_r[besle_sayac_r[3:0]];
                if (besle_sayac_r == 5'd15) begin
                    besle_sayac_r <= 5'd0;
                    durum_r       <= S_DOG_HASH;
                end else besle_sayac_r <= besle_sayac_r + 5'd1;
            end

            S_DOG_HASH: begin
                kex_hash_vld_r <= 1'b1;
                kex_hash_pkt_r <= hash_tampon_r[besle_sayac_r[2:0]];
                if (besle_sayac_r == 5'd7) begin
                    besle_sayac_r <= 5'd0;
                    durum_r       <= S_DOG_GO;
                end else besle_sayac_r <= besle_sayac_r + 5'd1;
            end

            S_DOG_GO: begin
                kex_dogrula_r <= 1'b1;
                durum_r       <= S_DOG_BEK;
            end

            // HUKUM DURUM BAYTINDA TASINIR — veri uzunlugu 0.
            //   Protokol veri uzunlugunun 4'un kati olmasini sart kosuyor;
            //   1 baytlik bir yanit icin istisna acmak yerine DURUM_OKU ile
            //   ayni cozum kullanildi.
            //
            //   0x00 gecerli / 0xEE gecersiz / 0xEF aralik disi ayrimi
            //   ONEMLIDIR: 0xEF, imzanin matematigine HIC bakilmadigini
            //   soyler (r veya s [1,n-1] disinda), 0xEE ise bakildigini ve
            //   tutmadigini. Ikisi ayni koda yikilirsa host, bozuk bir
            //   cerceveyi gecersiz bir imzadan ayirt edemez.
            S_DOG_BEK: begin
                if (g_kex_err) begin
                    yanit_durum_r   <= anlik_hata_yanit_w;
                    yanit_uzunluk_r <= 8'd0;
                    durum_r         <= S_YANIT;
                end else if (g_kex_done) begin
                    yanit_durum_r   <= g_kex_imza_aralik  ? YAN_IMZA_ARALIK   :
                                       g_kex_imza_gecerli ? YAN_OK            :
                                                            YAN_IMZA_GECERSIZ;
                    yanit_uzunluk_r <= 8'd0;
                    durum_r         <= S_YANIT;
                end
            end

            default: durum_r <= S_BOSTA;

        endcase
    end
end

// ═════════════════════════════════════════════════════════════════════════
//  CIKIS ATAMALARI
// ═════════════════════════════════════════════════════════════════════════
assign c_kex_start      = kex_start_r;
assign c_kex_qb_start   = kex_qb_start_r;
assign c_kex_pkt        = kex_pkt_r;
assign c_kex_pkt_vld    = kex_pkt_vld_r;
assign c_kex_pkt_sel    = kex_pkt_sel_r;

assign c_yanit_basla    = yanit_basla_r;
assign c_yanit_durum    = yanit_durum_r;
assign c_yanit_uzunluk  = yanit_uzunluk_r;
assign c_tx_word        = tx_word_r;
assign c_tx_word_gecerli= tx_word_vld_r;

// Durum bayti (İster PROT-04)
assign c_durum = { 2'b00, g_kex_stage, hata_r, ss_gecerli_r, qa_gecerli_r, g_kex_rdy };

endmodule