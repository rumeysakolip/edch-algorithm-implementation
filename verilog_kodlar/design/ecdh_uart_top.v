// =============================================================================
// Modül   : ecdh_uart_top.v                                        (İster M-10)
// Proje   : FPGA Tabanlı Güvenli Anahtar Yönetimi ve Kripto Hızlandırıcı (5260007)
// Kart    : Digilent Nexys A7-100T (xc7a100tcsg324-1)
// -----------------------------------------------------------------------------
// Açıklama:
//   UART'lı bitstream üst modülü. Gerçek ecdh_kex_top çekirdeğini UART
//   arayüzü ve komut yöneticisiyle birleştirir.
//
//   ecdh_demo_top.v SILINMEDI. Iki top yan yana durur:
//     - ecdh_demo_top : UART'siz, gomulu Qb, sadece buton+LED (referans)
//     - ecdh_uart_top : UART'li tam sistem (bu dosya)
//   Vivado'da  set_property top <isim> [current_fileset]  ile gecis yapilir.
//   Bir ariza ciktiginda "cekirdek mi bozuldu, UART mi" sorusunu ayirt
//   edebilmek icin bozulmamis referans bitstream SARTTIR.
//
// -----------------------------------------------------------------------------
// KOMUT AKISI (host tarafi):
//   1) 0x01 QB_YUKLE   : karsi tarafin acik anahtari Qb (64 bayt, Montgomery)
//   2) 0x02 ECDH_BASLAT: cekirdek d uretir, Qa = d.G hesaplar
//      -> Qa hazir olunca komut_yoneticisi Qb'yi OTOMATIK besler, S = d.Qb
//   3) 0x05 DURUM_OKU  : islem bitti mi
//   4) 0x03 QA_OKU     : Qa (64 bayt)
//   5) 0x04 SIR_OKU    : Ortak Sir (64 bayt)
//
//   btn_start ayrica manuel tetik saglar (adim 2 ile ayni). Qb yuklenmemisse
//   cekirdek Qa'yi uretir ama ikinci asamaya gecmez — bu beklenen davranistir.
//
// -----------------------------------------------------------------------------
// *** GUVENLIK NOTLARI — RAPORDA YER ALMALIDIR ***
//   1. Gizli anahtar d'yi disari veren komut YOKTUR (İster PROT-06).
//   2. 0x10 D_YUKLE yalnizca `TEST_MODU tanimliyken derlenir. URETIM
//      BITSTREAM'I TEST_MODU OLMADAN URETILMELIDIR.
//   3. Ortak Sir'in UART'tan okunabiliyor olmasi BILINCLI bir DEMO tercihidir.
//      Gercek dagitimda ortak sir cipten cikmamali, dogrudan simetrik sifreleme
//      motoruna beslenmelidir. Aksi halde ECDH'nin sagladigi gizlilik, seri
//      hattı dinleyen biri tarafindan tamamen ortadan kaldirilir.
//   4. Dahili LFSR-PRNG KRIPTOGRAFIK DEGILDIR. Uretimde gercek entropi
//      kaynagi (ring-osilator TRNG + saglik testi) gereklidir.
//
// -----------------------------------------------------------------------------
// LED HARITASI:
//   led[0]     busy (cekirdek mesgul — o_rdy dusuk)
//   led[1]     Qa hazir
//   led[2]     Ortak Sir hazir
//   led[3]     cekirdek hatasi (kalici)
//   led[4]     UART RX etkin
//   led[5]     UART TX etkin
//   led[6]     CRC hatasi (kalici)
//   led[7]     zaman asimi (kalici)
//   led[14:8]  Ortak Sir X'in dusuk 7 biti (gorsel veri)
//   led[15]    heartbeat
//
// Standart : Verilog-2001 — sentezlenebilir, latch üretmez
// Tarih    : Temmuz 2026
// =============================================================================

`timescale 1ns / 1ps

module ecdh_uart_top #(
    parameter integer SAAT_HZ   = 100_000_000,
    parameter integer BAUD_HIZI = 115_200,

    // ── RESET BUTONU KUTUPLUGU — KART BAGIMLI ─────────────────────────────
    //   1 = aktif-DUSUK  (Nexys A7: btnCpuReset, basili degilken '1')
    //   0 = aktif-YUKSEK (Basys 3 : normal buton,  basili degilken '0')
    //
    //   Basys 3'te AYRI BIR RESET BUTONU YOKTUR; 5 normal butondan biri
    //   kullanilir ve bunlar aktif-YUKSEKTIR. Bu parametre 1 birakilirsa
    //   rst_n surekli '0' kalir ve TASARIM HIC CALISMAZ (heartbeat LED'i
    //   bile yanmaz). Basys 3 icin 0 verilmelidir.
    // G4 duzeltmesi (Basys 3 kart getirme): hedef kart xc7a35tcpg236-1
    // (Basys 3) aktif-YUKSEK butona sahiptir; varsayilan artik 0.
    // Nexys A7'ye donmek icin bu parametreyi 1 olarak override et.
    parameter integer RESET_AKTIF_DUSUK = 0
)(
    input  wire        clk_100,      // Nexys A7: E3  | Basys 3: W5  (100 MHz)
    input  wire        btn_reset,    // Nexys A7: C12 | Basys 3: T18 (btnU)
    input  wire        btn_start,    // Nexys A7: N17 | Basys 3: U18 (btnC)
    input  wire        uart_rx_in,   // Nexys A7: C4  | Basys 3: B18 (RsRx)
    output wire        uart_tx_out,  // Nexys A7: D4  | Basys 3: A18 (RsTx)
    output wire [15:0] led,

    // ═════════════════════════════════════════════════════════════════════
    //  ENTEGRASYON DIKISI — SIMETRIK KATMAN ARAYUZU     (İster INT-01)
    // ---------------------------------------------------------------------
    //  *** BU PORTLAR PIN'E BAGLANMAZ ***
    //  Bunlar, HKDF / AES-GCM (AEAD) bloklarinin bu cekirdege baglanacagi
    //  yerdir. Kart uzerinde disari cikmazlar; ust seviyede baska bir
    //  modulun girisine gider. Yalniz ECC cekirdegi sentezlenirken bagsiz
    //  birakilabilirler (Vivado bunlari optimize eder).
    //
    //  drawio karsiligi:
    //    A2-7  "shared secret -> HKDF -> handshake traffic keys"  -> c_ent_* (sec=0)
    //    A2-11 "mTLS: ECDSASign ... CertificateVerify"            -> c_ent_* (sec=1,2)
    //    A2-10 "sunucu sertifika zinciri / CertificateVerify dogrula"
    //                                                            -> c_dog_*
    //
    //  UART yolu (SIR_OKU / IMZALA yaniti) BUNLARA PARALELDIR ve yalnizca
    //  demo ve teshis icindir. Gercek dagitimda ortak sir cipten disari
    //  cikmamali, buradan dogrudan KDF'ye gitmelidir.
    //
    //  26 Temmuz 2026 DUZELTMESI — 32-BIT SOZCUK ARAYUZUNE GECIS:
    //  Bu ucgen (c_z_duz/c_imza_r/c_imza_s) eskiden HAM 256-bit portlardi.
    //  "Vivado bunlari optimize eder" varsayimi YANLIS CIKTI: ecdh_uart_top
    //  gercek sentez top'u oldugunda bu 768 bit + led[15:0] + 9 tekil sinyal
    //  gercek IOB gerektiriyor (793 port) — xc7a35t'te (106 I/O) VE
    //  xc7a200t'nin en genis paketinde bile (285 I/O) place_design DRC
    //  hatasiyla duruyordu (bkz. G1_ozet.md). Cip buyutmek COZUM DEGIL;
    //  hicbir gercekci FPGA paketi 793 pin sunmaz. Cozum: ic imza
    //  toplayicisiyla (asagida imza_r_r/imza_s_r) AYNI desen — 32 bitlik
    //  sozcukler + secici + indis. Tuketici (ileride yazilacak HKDF/AES-GCM
    //  sarmalayicisi) 8 cevrimde bir degeri tekrar 256 bit'e birlestirir.
    // ═════════════════════════════════════════════════════════════════════

    // ── Entegrasyon dikisi — 32-bit SOZCUK ARAYUZU (PIN'E BAGLANMAZ) ─────
    //   c_ent_sec  : 0=z_duz (ECDH ortak sir) 1=imza_r 2=imza_s
    //   c_ent_indis: sozcuk sirasi, 0=en dusuk anlamli 32 bit ... 7=en yuksek
    //   c_ent_sozcuk: secili 32-bit sozcuk (surekli, serbest sayacla dolasir)
    //   Tam deger gecerliligi ayri tek-bitlik bayraklarla (asagida) bildirilir;
    //   sozcuk veri yolu bir kayit dosyasi gibi her zaman okunabilir.
    output wire [1:0]  c_ent_sec,
    output wire [2:0]  c_ent_indis,
    output wire [31:0] c_ent_sozcuk,

    // ── ECDH ortak sirri (KDF girdisi) — gecerlilik bayragi ──────────────
    //   Z = ortak noktanin x koordinati, DUZ tam sayi (Montgomery DEGIL),
    //   NIST SP 800-56A Rev.3 §5.7.1.2. c_ent_sec=0 secili sozcukler bunun.
    //   c_z_gecerli, yeni bir ECDH baslar baslamaz duser (bayat sir sizmaz).
    output wire         c_z_gecerli,

    // ── ECDSA imzasi (CertificateVerify icin) — gecerlilik bayragi ───────
    //   r (c_ent_sec=1) ve s (c_ent_sec=2) DUZ ve mod n'dir. c_imza_gecerli
    //   bir CEVRIMLIK DARBEDIR; tuketici tarafta kilitlenmelidir.
    output wire         c_imza_gecerli,

    // ── ECDSA dogrulama hukmu (sunucu sertifikasi icin) ──────────────────
    //   c_dog_bitti bir cevrimlik darbedir; c_dog_gecerli o anda okunmalidir.
    output wire         c_dog_gecerli,
    output wire         c_dog_bitti
);

// ═════════════════════════════════════════════════════════════════════════
//  RESET SENKRONIZASYONU  (ecdh_demo_top'tan tasinmistir)
// ═════════════════════════════════════════════════════════════════════════
reg [1:0] rst_senk_r;
wire      rst_n;

// Buton kutuplugunu normalize et: ic mantik daima aktif-DUSUK bekler.
wire btn_reset_n_w = (RESET_AKTIF_DUSUK != 0) ? btn_reset : ~btn_reset;

always @(posedge clk_100) rst_senk_r <= {rst_senk_r[0], btn_reset_n_w};
assign rst_n = rst_senk_r[1];

// ═════════════════════════════════════════════════════════════════════════
//  btn_start DEBOUNCE + YUKSELEN KENAR  (ecdh_demo_top'tan tasinmistir)
// ═════════════════════════════════════════════════════════════════════════
localparam [21:0] DB_AZAMI = 22'd2_000_000;   // ~20 ms @ 100 MHz

reg [1:0]  bs_senk_r;
reg [21:0] db_sayac_r;
reg        bs_kararli_r, bs_kararli_g_r;

always @(posedge clk_100 or negedge rst_n) begin
    if (!rst_n) begin
        bs_senk_r <= 2'b0; db_sayac_r <= 22'd0;
        bs_kararli_r <= 1'b0; bs_kararli_g_r <= 1'b0;
    end else begin
        bs_senk_r <= {bs_senk_r[0], btn_start};
        if (bs_senk_r[1] != bs_kararli_r) begin
            db_sayac_r <= db_sayac_r + 22'd1;
            if (db_sayac_r == DB_AZAMI) begin
                bs_kararli_r <= bs_senk_r[1];
                db_sayac_r   <= 22'd0;
            end
        end else begin
            db_sayac_r <= 22'd0;
        end
        bs_kararli_g_r <= bs_kararli_r;
    end
end

wire manuel_basla_w = bs_kararli_r & ~bs_kararli_g_r;

// ═════════════════════════════════════════════════════════════════════════
//  HEARTBEAT
// ═════════════════════════════════════════════════════════════════════════
reg [25:0] hb_r;
always @(posedge clk_100 or negedge rst_n) begin
    if (!rst_n) hb_r <= 26'd0;
    else        hb_r <= hb_r + 26'd1;
end

// ═════════════════════════════════════════════════════════════════════════
//  UART ARAYUZU (M-08)
// ═════════════════════════════════════════════════════════════════════════
wire [7:0]  ua_komut, ua_uzunluk;
wire        ua_komut_gecerli;
wire [31:0] ua_rx_word;
wire        ua_rx_word_gecerli;
wire [3:0]  ua_rx_indis;
wire        ky_rx_word_hazir;

wire        ky_yanit_basla;
wire [7:0]  ky_yanit_durum, ky_yanit_uzunluk;
wire [31:0] ky_tx_word;
wire        ky_tx_word_gecerli;
wire        ua_tx_word_iste;

wire        ua_mesgul;
wire [3:0]  ua_hata;

uart_arayuz #(
    .SAAT_HZ(SAAT_HZ), .BAUD_HIZI(BAUD_HIZI), .ORNEKLEME(16),
    .AZAMI_VERI(64), .ZAMAN_ASIMI(SAAT_HZ/20),   // ~50 ms
    .RX_DERINLIK(16), .TX_DERINLIK(128)
) arayuz (
    .g_saat(clk_100), .g_sifirla_n(rst_n),
    .g_seri_rx(uart_rx_in), .c_seri_tx(uart_tx_out),
    .c_komut(ua_komut), .c_uzunluk(ua_uzunluk),
    .c_komut_gecerli(ua_komut_gecerli),
    .c_rx_word(ua_rx_word), .c_rx_word_gecerli(ua_rx_word_gecerli),
    .c_rx_indis(ua_rx_indis), .g_rx_word_hazir(ky_rx_word_hazir),
    .g_yanit_basla(ky_yanit_basla), .g_yanit_durum(ky_yanit_durum),
    .g_yanit_uzunluk(ky_yanit_uzunluk),
    .g_tx_word(ky_tx_word), .g_tx_word_gecerli(ky_tx_word_gecerli),
    .c_tx_word_iste(ua_tx_word_iste),
    .c_mesgul(ua_mesgul), .c_hata(ua_hata)
);

// ═════════════════════════════════════════════════════════════════════════
//  KOMUT YONETICISI (M-09)
// ═════════════════════════════════════════════════════════════════════════
wire        ky_kex_start, ky_kex_qb_start;
wire [31:0] ky_kex_pkt;
wire        ky_kex_pkt_vld;
// GENISLIK NOTU: komut_yoneticisi.c_kex_pkt_sel ve ecdh_kex_top.i_pkt_sel
// FAZ 5'te 3 bite genisletildi (sel=2 -> r, sel=3 -> s, dogrulama yolu).
// Bu ara hat 2 bitte kalirsa Verilog SESSIZCE ust biti kirpar; ECDH yolu
// (sel=0/1) calismaya devam ettigi icin hata ancak dogrulama akisinda
// ortaya cikar. Genislik uyumu ZORUNLU.
wire [2:0]  ky_kex_pkt_sel;
wire [31:0] ky_trng_pkt;
wire        ky_trng_vld;
wire [7:0]  ky_durum;

wire [31:0] kex_pkt_out;
wire        kex_pkt_vld;
wire [1:0]  kex_sel, kex_stage;
wire        kex_pkt_last, kex_qa_done, kex_rdy, kex_done, kex_err, kex_trng_req;
wire [2:0]  kex_err_kod;   // hata nedeni (İster SEC-03)
// FAZ 4 — anahtar slotu denetimi. Komut katmani yalnizca slot numarasi ve
// politika gonderir; ozel anahtar ecdh_kex_top'un icinde kalir.
wire [1:0]  ky_slot;
wire [7:0]  ky_politika;
wire        ky_zeroize;
wire        ky_uret;
wire        kex_slot_hata;
wire [1:0]  kex_uret_hata_kod;
// ── FAZ 5c: ECDSA hatlari ──────────────────────────────────────────────
//   Bu hatlar baglanana kadar imzalama/dogrulama cekirdekte VAR ama
//   UART'tan ERISILEMEZ durumdaydi (i_imzala/i_dogrula sabit 1'b0 idi).
wire        ky_imzala, ky_dogrula, ky_hash_vld;
wire [31:0] ky_hash_pkt;
wire        kex_imza_hazir, kex_imza_sel;
wire        kex_imza_gecerli, kex_imza_aralik;
wire        kex_dog_bitti;
wire [255:0] kex_z_duz_w;   // ecdh_kex_top.o_z_duz — artik top porta degil, mux'a gider

// ── ÇOKLU EĞRİ DESTEĞİ (İster M-24) — komut_yoneticisi -> ecdh_kex_top ────
wire [255:0] ky_egri_p, ky_egri_r_mod_p, ky_egri_gx_mont, ky_egri_gy_mont;
wire [255:0] ky_egri_b_mont, ky_egri_n_order, ky_egri_mont_bir_n, ky_egri_r2n;
wire [9:0]   ky_egri_p_bit, ky_egri_n_bit;
wire         ky_egri_gecerli;

komut_yoneticisi yonetici (
    .g_saat(clk_100), .g_sifirla_n(rst_n),
    .g_komut(ua_komut), .g_uzunluk(ua_uzunluk),
    .g_komut_gecerli(ua_komut_gecerli),
    .g_manuel_basla(manuel_basla_w),
    .g_rx_word(ua_rx_word), .g_rx_word_gecerli(ua_rx_word_gecerli),
    .g_rx_indis(ua_rx_indis), .c_rx_word_hazir(ky_rx_word_hazir),
    .c_yanit_basla(ky_yanit_basla), .c_yanit_durum(ky_yanit_durum),
    .c_yanit_uzunluk(ky_yanit_uzunluk),
    .c_tx_word(ky_tx_word), .c_tx_word_gecerli(ky_tx_word_gecerli),
    .g_tx_word_iste(ua_tx_word_iste),
    .c_kex_start(ky_kex_start), .c_kex_qb_start(ky_kex_qb_start),
    .c_kex_pkt(ky_kex_pkt), .c_kex_pkt_vld(ky_kex_pkt_vld),
    .c_kex_pkt_sel(ky_kex_pkt_sel),
    .g_kex_pkt_out(kex_pkt_out), .g_kex_pkt_vld(kex_pkt_vld),
    .g_kex_sel(kex_sel), .g_kex_stage(kex_stage),
    .g_kex_qa_done(kex_qa_done), .g_kex_rdy(kex_rdy),
    .g_kex_done(kex_done), .g_kex_err(kex_err), .g_kex_err_kod(kex_err_kod),
    .c_kex_slot(ky_slot), .c_kex_politika(ky_politika), .c_kex_zeroize(ky_zeroize),
    .c_kex_uret(ky_uret),
    .g_kex_slot_hata(kex_slot_hata), .g_kex_uret_hata_kod(kex_uret_hata_kod),
    // ── FAZ 5c: ECDSA komut arayuzu ──────────────────────────────────
    .c_kex_imzala(ky_imzala), .c_kex_dogrula(ky_dogrula),
    .c_kex_hash_pkt(ky_hash_pkt), .c_kex_hash_vld(ky_hash_vld),
    .g_kex_imza_hazir(kex_imza_hazir), .g_kex_imza_sel(kex_imza_sel),
    .g_kex_imza_gecerli(kex_imza_gecerli),
    .g_kex_imza_aralik(kex_imza_aralik),
    .g_trng_req(kex_trng_req), .c_trng_pkt(ky_trng_pkt), .c_trng_vld(ky_trng_vld),
    // ── ÇOKLU EĞRİ DESTEĞİ (İster M-24) — parametre_deposu çıkışları ──────
    .c_egri_p(ky_egri_p), .c_egri_r_mod_p(ky_egri_r_mod_p),
    .c_egri_gx_mont(ky_egri_gx_mont), .c_egri_gy_mont(ky_egri_gy_mont),
    .c_egri_b_mont(ky_egri_b_mont), .c_egri_n_order(ky_egri_n_order),
    .c_egri_mont_bir_n(ky_egri_mont_bir_n), .c_egri_r2n(ky_egri_r2n),
    .c_egri_p_bit_uzunluk(ky_egri_p_bit), .c_egri_n_bit_uzunluk(ky_egri_n_bit),
    .c_egri_gecerli(ky_egri_gecerli),
    .c_durum(ky_durum)
);

// ═════════════════════════════════════════════════════════════════════════
//  GERCEK ECDH CEKIRDEGI
// ═════════════════════════════════════════════════════════════════════════
ecdh_kex_top kex (
    .clk_in(clk_100), .rst_n(rst_n),
    .i_start(ky_kex_start),
    .o_trng_req(kex_trng_req), .i_trng_vld(ky_trng_vld), .i_trng_pkt(ky_trng_pkt),
    .i_pkt_in(ky_kex_pkt), .i_pkt_vld(ky_kex_pkt_vld), .i_pkt_sel(ky_kex_pkt_sel),
    .i_qb_start(ky_kex_qb_start),
    .o_pkt_out(kex_pkt_out), .o_pkt_vld(kex_pkt_vld), .o_pkt_sel(kex_sel),
    .o_pkt_last(kex_pkt_last), .o_stage(kex_stage), .o_qa_done(kex_qa_done),
    .o_rdy(kex_rdy), .o_done(kex_done), .o_err(kex_err), .o_err_kod(kex_err_kod),
        .i_slot(ky_slot), .i_politika(ky_politika), .i_zeroize(ky_zeroize),
    // FAZ 5c — ECDSA komut entegrasyonu TAMAMLANDI.
    .i_dogrula(ky_dogrula), .i_uret(ky_uret), .i_imzala(ky_imzala),
    .i_hash_pkt(ky_hash_pkt), .i_hash_vld(ky_hash_vld),
    .o_imza_hazir(kex_imza_hazir), .o_imza_sel(kex_imza_sel), .o_imza_tekrar(),
    .o_imza_gecerli(kex_imza_gecerli), .o_imza_aralik_hata(kex_imza_aralik),
    .o_slot_hata(kex_slot_hata), .o_uret_hata_kod(kex_uret_hata_kod),
    // ── Entegrasyon dikisi ──────────────────────────────────────────
    //   o_z_duz artik dogrudan bir top-level porta degil, dahili bir hatta
    //   baglanir (kex_z_duz_w) — 32-bit sozcuk mux'i bunu okur (asagida).
    .o_z_duz(kex_z_duz_w), .o_z_gecerli(c_z_gecerli), .o_dog_bitti(kex_dog_bitti),
    // ── ÇOKLU EĞRİ DESTEĞİ (İster M-24) ─────────────────────────────────
    .i_egri_p(ky_egri_p), .i_egri_r_mod_p(ky_egri_r_mod_p),
    .i_egri_gx_mont(ky_egri_gx_mont), .i_egri_gy_mont(ky_egri_gy_mont),
    .i_egri_b_mont(ky_egri_b_mont), .i_egri_n_order(ky_egri_n_order),
    .i_egri_mont_bir_n(ky_egri_mont_bir_n), .i_egri_r2n(ky_egri_r2n),
    .i_egri_n_bit_uzunluk(ky_egri_n_bit)
);

// ═════════════════════════════════════════════════════════════════════════
//  IMZA TOPLAYICI (entegrasyon dikisi)
// -------------------------------------------------------------------------
//   Imzayi komut_yoneticisi'nin tamponundan almak yerine cekirdegin
//   cikisindan DOGRUDAN topluyoruz. Sebep: dikis, komut katmanindan BAGIMSIZ
//   olmali. Imza baska bir yoldan tetiklenirse (buton, ileride baska bir
//   MCU arayuzu) tampon dolmayabilir ama cekirdek yine (r,s) basar.
//
//   Cekirdek once r'nin 8 word'unu, sonra s'nin 8 word'unu basar; o_imza_sel
//   ikisini ayirir. Sayac secici DEGISINCE sifirlanir — ayni kendini
//   hizalayan desen komut_yoneticisi'ndeki Qa/Sir yakalayicisinda da var.
// ═════════════════════════════════════════════════════════════════════════
reg [255:0] imza_r_r, imza_s_r;
reg [2:0]   imza_cnt_r;
reg         imza_sel_gec_r;
reg         imza_gecerli_r;

wire [2:0] imza_idx_w = (kex_imza_sel != imza_sel_gec_r) ? 3'd0 : imza_cnt_r;

always @(posedge clk_100 or negedge rst_n) begin
    if (!rst_n) begin
        imza_r_r <= 256'd0; imza_s_r <= 256'd0;
        imza_cnt_r <= 3'd0; imza_sel_gec_r <= 1'b0;
        imza_gecerli_r <= 1'b0;
    end else begin
        imza_gecerli_r <= 1'b0;          // 1 cevrimlik darbe
        if (kex_imza_hazir && kex_pkt_vld) begin
            if (!kex_imza_sel) imza_r_r[imza_idx_w*32 +: 32] <= kex_pkt_out;
            else               imza_s_r[imza_idx_w*32 +: 32] <= kex_pkt_out;
            imza_sel_gec_r <= kex_imza_sel;
            imza_cnt_r     <= imza_idx_w + 3'd1;
            // s'nin son word'u yazildi -> imza tamam
            if (kex_imza_sel && (imza_idx_w == 3'd7)) imza_gecerli_r <= 1'b1;
        end
    end
end

assign c_imza_gecerli = imza_gecerli_r;
assign c_dog_gecerli  = kex_imza_gecerli;
assign c_dog_bitti    = kex_dog_bitti;

// ═════════════════════════════════════════════════════════════════════════
//  ENTEGRASYON DIKISI — 32-BIT SOZCUK IHRAC MUX'I  (26 Temmuz 2026)
// -------------------------------------------------------------------------
//   c_z_duz/c_imza_r/c_imza_s artik top-level'da HAM 256-bit port DEGIL —
//   793 IOB'a yol acan asil sebep buydu (bkz. G1_ozet.md). Bunun yerine
//   imza_r_r/imza_s_r/kex_z_duz_w kayitlarini 8'er 32-bit sozcuk halinde
//   surekli dolasan (free-running) bir sayacla disari sunuyoruz — tam
//   olarak imza toplayicisinin (yukarida) zaten kullandigi desen.
//   Sayac serbest caliisir; "hangi deger taze" sorusu ayri tek-bitlik
//   bayraklarla (c_z_gecerli / c_imza_gecerli) cevaplanir, sozcuk yolu
//   bir salt-okunur kayit dosyasi gibi her an okunabilir durumda kalir.
// ═════════════════════════════════════════════════════════════════════════
reg [4:0] ent_sayac_r;   // 0..23 dolasir: 0-7 z_duz, 8-15 imza_r, 16-23 imza_s

always @(posedge clk_100 or negedge rst_n) begin
    if (!rst_n) ent_sayac_r <= 5'd0;
    else        ent_sayac_r <= (ent_sayac_r == 5'd23) ? 5'd0 : (ent_sayac_r + 5'd1);
end

wire [1:0] ent_sec_w   = ent_sayac_r[4:3];   // 0,1,2 (3 hic uretilmez, 0..23 sinirlandigi icin)
wire [2:0] ent_indis_w = ent_sayac_r[2:0];

// secili 256-bit degerin secili 32-bit dilimi — imza_r_r/imza_s_r/kex_z_duz_w
// zaten aynen bu genislikte, dogrudan indis ile dilimlenir.
function [31:0] ent_dilim;
    input [255:0] deger;
    input [2:0]   indis;
    ent_dilim = deger[indis*32 +: 32];
endfunction

assign c_ent_sec    = ent_sec_w;
assign c_ent_indis  = ent_indis_w;
assign c_ent_sozcuk = (ent_sec_w == 2'd0) ? ent_dilim(kex_z_duz_w, ent_indis_w) :
                      (ent_sec_w == 2'd1) ? ent_dilim(imza_r_r,   ent_indis_w) :
                                            ent_dilim(imza_s_r,   ent_indis_w);

// ═════════════════════════════════════════════════════════════════════════
//  TESHIS: hata bayraklarini KILITLE (darbeler cok kisa, goze gorunmez)
// ═════════════════════════════════════════════════════════════════════════
reg crc_hata_kilit_r, za_kilit_r;
reg rx_etkin_r, tx_etkin_r;

// LED gostergesi icin RX hattinin senkronize kopyasi
(* ASYNC_REG = "TRUE" *) reg [1:0] rx_led_senk_r;
always @(posedge clk_100 or negedge rst_n) begin
    if (!rst_n) rx_led_senk_r <= 2'b11;
    else        rx_led_senk_r <= {rx_led_senk_r[0], uart_rx_in};
end

always @(posedge clk_100 or negedge rst_n) begin
    if (!rst_n) begin
        crc_hata_kilit_r <= 1'b0;
        za_kilit_r       <= 1'b0;
        rx_etkin_r       <= 1'b0;
        tx_etkin_r       <= 1'b0;
    end else begin
        if (ua_hata[1]) crc_hata_kilit_r <= 1'b1;   // CRC
        if (ua_hata[3]) za_kilit_r       <= 1'b1;   // zaman asimi
        // Yeni islem baslayinca teshis bayraklarini temizle
        if (ky_kex_start) begin
            crc_hata_kilit_r <= 1'b0;
            za_kilit_r       <= 1'b0;
        end
        // uart_rx_in ASENKRONDUR. Sadece LED surdugu icin metastabilite
        // zararsizdir, ama senkronize etmemek DRC/inceleme sirasinda hakli
        // olarak elestirilir. 2-flop zincirinden gecirilir.
        rx_etkin_r <= ~rx_led_senk_r[1];
        tx_etkin_r <= ~uart_tx_out;     // dahili kaynakli, senkron
    end
end

// ── Ortak Sir X'in dusuk baytini yakala (gorsel veri) ─────────────────────
localparam [1:0] STAGE_SS = 2'b10;

reg [6:0] ssx_bit_r;
reg       ssx_yakalandi_r;

always @(posedge clk_100 or negedge rst_n) begin
    if (!rst_n) begin
        ssx_bit_r <= 7'd0; ssx_yakalandi_r <= 1'b0;
    end else begin
        if (ky_kex_start) ssx_yakalandi_r <= 1'b0;
        if (kex_pkt_vld && (kex_stage == STAGE_SS) && (kex_sel == 2'b00)
            && !ssx_yakalandi_r) begin
            ssx_bit_r       <= kex_pkt_out[6:0];
            ssx_yakalandi_r <= 1'b1;
        end
    end
end

// ═════════════════════════════════════════════════════════════════════════
//  LED CIKISLARI
// ═════════════════════════════════════════════════════════════════════════
assign led[0]     = ~kex_rdy;          // busy
assign led[1]     = ky_durum[1];       // Qa hazir
assign led[2]     = ky_durum[2];       // Ortak Sir hazir
assign led[3]     = ky_durum[3];       // cekirdek hatasi
assign led[4]     = rx_etkin_r;
assign led[5]     = tx_etkin_r;
assign led[6]     = crc_hata_kilit_r;
assign led[7]     = za_kilit_r;
assign led[14:8]  = ssx_bit_r;
assign led[15]    = hb_r[25];          // heartbeat

endmodule
