// =============================================================================
// Modül   : ecdsa_imza.v                                           (İster M-19)
// Proje   : FPGA Tabanlı Güvenli Anahtar Yönetimi ve Kripto Hızlandırıcı (5260007)
// -----------------------------------------------------------------------------
// Açıklama:
//   ECDSA imzasının GF(n) ARİTMETİK yarısı.
//
//     r = (k·G).x mod n
//     s = k^(-1) · (e + r·d) mod n
//
//   Skaler çarpım (k·G) BU MODÜLDE DEĞİLDİR; çağıran (ecdh_kex_top) mevcut
//   scalar_multiplier + affine_donusum zincirini kullanır ve sonucun X
//   koordinatını (Rx) buraya verir. Böylece skaler çarpım tek bir yerde
//   kalır; ECDH ve ECDSA aynı çekirdeği paylaşır.
//
// -----------------------------------------------------------------------------
// *** MONTGOMERY ALAN AKIŞI — TASARIMIN EN İNCE YERİ ***
//
//   MontMult(ã,b̃) = a·b·R^(-1) mod n olduğundan, operandlardan YALNIZ BİRİ
//   Montgomery alanındaysa sonuç DÜZ alanda çıkar. Bu özellik kullanılarak
//   dönüşüm sayısı ikiye indirilmiştir:
//
//     1) r̃  = MM(r,  R2N)   → Montgomery'ye taşı
//     2) t1 = MM(r̃, d)     → DÜZ  r·d      (R kendiliğinden iptal olur)
//     3) t2 = ModAdd(e, t1) → DÜZ  e + r·d
//     4) k̃  = MM(k,  R2N)   → Montgomery'ye taşı
//     5) k̃ⁱ = mod_n_ters(k̃) → (k^-1)~
//     6) s  = MM(k̃ⁱ, t2)   → DÜZ  k^(-1)·(e + r·d)
//
//   Naif yaklaşım e, r, d, k'yi ayrı ayrı taşır, çarpar, sonra geri taşırdı:
//   4 ileri + 1 geri = 5 fazladan MontMult. Bu düzende 2 dönüşüm yetiyor.
//
//   DOĞRULAMA: bu ADIM DİZİSİ Python'da birebir modellendi ve üretilen (r,s)
//   çiftleri BAĞIMSIZ bir ECDSA doğrulayıcısıyla sınandı — 6/6 geçti.
//   Modelin ilk hâli 5. adımı düz üs alma olarak yazmıştı ve doğrulama
//   başarısız oldu; mod_n_ters MONTGOMERY üs alması yapar, düz değil.
//   Bu ayrım kaçırılırsa imza sessizce geçersiz olur — hiçbir hata bayrağı
//   kalkmaz, yalnızca karşı taraf doğrulayamaz.
//
// -----------------------------------------------------------------------------
// Rx → r İNDİRGEMESİ:
//   Rx, GF(p) elemanıdır ve r, GF(n) elemanı olmalıdır. p < 2n olduğundan
//   (doğrulandı) TEK koşullu çıkarma yeterlidir:  r = (Rx >= n) ? Rx-n : Rx
//   Genel bir mod işlemi GEREKMEZ; bu, 256 çevrimlik bir bölme yerine
//   8 çevrimlik dilimli karşılaştırma + tek çıkarma demektir.
//
// -----------------------------------------------------------------------------
// *** NONCE (k) GÜVENLİĞİ — PROJE ŞARTNAMESİNİN EN KRİTİK MADDESİ ***
//   Bu modül k'yi ÜRETMEZ, dışarıdan alır. Üretim sorumluluğu çağırandadır
//   ve şu kurallar ZORUNLUDUR:
//
//     1. k HER İMZADA BENZERSİZ olmalıdır. Aynı k ile atılan iki imza,
//        özel anahtarı DOĞRUDAN verir:
//            s1 = k^-1(e1 + r·d),  s2 = k^-1(e2 + r·d)
//            k = (e1 - e2)/(s1 - s2)  →  d = (s1·k - e1)/r
//        Bu bir teori değil; Sony PS3 ve birçok Bitcoin cüzdanı tam olarak
//        böyle kırıldı.
//
//     2. k KISMEN BİLE tahmin edilebilir olmamalıdır. Nonce'un birkaç
//        bitinin sızması, birkaç yüz imza toplandığında kafes (lattice)
//        indirgeme ile özel anahtarı verir. Bu yüzden mod_n_ters'te
//        Fermat seçildi (sabit zamanlı) — bkz. o dosyanın başlığı.
//
//     3. MEVCUT LFSR-PRNG BU İŞ İÇİN YETERSİZDİR. ECDH'de zayıf bir d
//        yalnız o oturumu bozar; ECDSA'da zayıf bir k KALICI özel anahtarı
//        ifşa eder. Üretim bitstream'ine geçmeden önce gerçek entropi
//        kaynağı (ring-osilator TRNG + sağlık testi) ya da RFC 6979
//        deterministik nonce türetmesi ZORUNLUDUR.
//
//   Modül, k'nin [1, n-1] aralığında olduğunu kontrol EDER (aralık dışı
//   nonce reddedilir) ama BENZERSİZLİĞİNİ doğrulayamaz — bu bilgi burada
//   yoktur. Sorumluluk çağırandadır.
//
// -----------------------------------------------------------------------------
// YENİDEN DENEME KOŞULLARI (FIPS 186-4 §6.4):
//   r == 0 veya s == 0 çıkarsa imza GEÇERSİZDİR ve YENİ BİR k ile baştan
//   denenmelidir. Olasılık ~2^-128, pratikte hiç gerçekleşmez; ama sessizce
//   geçilirse doğrulanamayan bir imza üretilir. Modül bunu o_r_sifir /
//   o_s_sifir ile bildirir; çağıran yeni k ile tekrar çağırmalıdır.
//
// MALİYET:
//   5 MontMult + 1 ModAdd + 1 ters alma
//   ≈ 6×290 + 122.675 ≈ 124.400 çevrim ≈ 1.24 ms.
//   Skaler çarpım (k·G, ~21 ms) yanında %6 — imzanın süresini belirleyen
//   şey skaler çarpımdır, bu modül değil.
//
// Kabul kriteri (TB-18):
//   4 KAT vektörü (Python altın-modelinden, bağımsız doğrulayıcıyla sınanmış);
//   Rx >= n indirgemesi; r=0 ve s=0 bayrakları; sabit zamanlılık; ardışık koşum.
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
module ecdsa_imza (
    input  wire         clk_in,
    input  wire         rst_n,

    // ── Paket girişi (32-bit, LSB-önce) ──────────────────────────────────
    //   0 = mod_n | 1 = e (hash) | 2 = Rx ((k·G).x) | 3 = d (özel) | 4 = k
    input  wire [31:0]  i_pkt_in,
    input  wire         i_pkt_vld,
    input  wire [2:0]   i_pkt_sel,
    input  wire         i_start,

    // ── Sonuç: r ve s (DÜZ alan, 8'er paket) ─────────────────────────────
    output wire [31:0]  o_pkt_out,
    output wire         o_pkt_vld,
    output wire         o_pkt_sel,     // 0 = r, 1 = s
    output wire         o_pkt_last,
    output wire         o_rdy,
    output wire         o_done,
    output wire         o_err,

    // ── FIPS 186-4 §6.4 yeniden deneme bayrakları ────────────────────────
    output wire         o_r_sifir,     // r == 0 → YENİ k ile tekrar dene
    output wire         o_s_sifir,     // s == 0 → YENİ k ile tekrar dene
    output wire         o_k_gecersiz,  // k, [1, n-1] dışında

    // ══ PAYLAŞILAN mod_n_ters DIŞ ARAYÜZÜ (master) ══════════════════════
    //   mod_n_ters bu modülün İÇİNDE DEĞİLDİR. ecdh_kex_top'ta TEK örnek
    //   olarak durur; hem imzalama (k^-1) hem doğrulama (s^-1) onu kullanır.
    //   İçeride tutulsaydı doğrulama için ikinci bir kopya gerekirdi.
    //
    //   Yerel MALU arbitrasyonu da KALKTI: mod_n_ters artık üst seviyede
    //   MALU'nun bağımsız bir istemcisi. Bu modül MALU'yu doğrudan kullanır.
    output wire [31:0]  to_pkt_dat,
    output wire         to_pkt_vld,
    output wire [1:0]   to_pkt_sel,
    output wire         to_st,
    input  wire [31:0]  ti_pkt_out,
    input  wire         ti_pkt_vld,
    input  wire         ti_rdy,
    input  wire         ti_done,
    input  wire         ti_err,

    // ── Paylaşılan MALU dış arayüzü (master) ─────────────────────────────
    output wire [31:0]  mo_pkt_dat,
    output wire         mo_pkt_vld,
    output wire [1:0]   mo_pkt_sel,
    output wire [1:0]   mo_opc,
    output wire         mo_st,
    input  wire [31:0]  mi_pkt_out,
    input  wire         mi_pkt_vld,
    input  wire         mi_pkt_last,
    input  wire         mi_rdy,
    input  wire         mi_done,
    input  wire         mi_err,

    // ── ÇOKLU EĞRİ DESTEĞİ (Temmuz 2026) ─────────────────────────────────
    //   n ve R2N (=R² mod n) dışarıdan gelir. Reset/varsayılan P-256'dır.
    input  wire [255:0] g_n_order,
    input  wire [255:0] g_r2n
);

// ── Giriş seçicileri ──────────────────────────────────────────────────────
localparam [2:0] EIX_MODN = 3'd0, EIX_E = 3'd1, EIX_RX = 3'd2,
                 EIX_D    = 3'd3, EIX_K = 3'd4;

// ── MALU sabitleri ────────────────────────────────────────────────────────
localparam [1:0] MSEL_A = 2'b00, MSEL_B = 2'b01, MSEL_P = 2'b10;
localparam [1:0] MADD   = 2'b00, MSUB = 2'b01, MMUL = 2'b10;

// ── n ve R2N ARTIK GİRİŞTİR (g_n_order / g_r2n) ───────────────────────────
//   Eski P-256 sabitleri (belge amaçlı):
//     N_ORDER = 256'hffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551
//     R2N     = 256'h66e12d94f3d956202845b2392b6bec594699799c49bd6fa683244c95be79eea2
wire [255:0] N_ORDER = g_n_order;
wire [255:0] R2N     = g_r2n;

// ── Durum kodlaması ───────────────────────────────────────────────────────
// *** GENISLIK KRITIK ***: durum sayisi 32'yi asti (0..33), bu yuzden blok
//   basligi [4:0] -> [5:0] YAPILDI. Basligi 5 bit birakmak, icindeki 6'd32 ve
//   6'd33 sabitlerini SESSIZCE 0 ve 1'e kirpar (ST_MA_RX = ST_IDLE olur!) ve
//   FSM her MALU sonucunda IDLE'a dusup kilitlenir. Verilog bunu hata olarak
//   bildirmez; ilk kosumda tam bu yasandi (TB-18 tumuyle zaman asimina dustu).
//   Ayni tuzak dg_wdog_r'de de yasanmisti: sabitin degeri degil, TASIYICININ
//   genisligi hataliydi.
localparam [5:0]
    ST_IDLE     = 6'd0,
    ST_SENDP_RD = 6'd1,    // MALU'ya n yükle: oku (+ R2N'i BRAM'e yaz)
    ST_SENDP_TX = 6'd2,    //                  gönder
    ST_RED_RX   = 6'd3,    // r = Rx - n  (gerekiyorsa)
    ST_CHK_R    = 6'd4,    // r == 0 ?
    ST_OP_RM    = 6'd6,    // r~  = MM(r, R2N)
    ST_OP_T1    = 6'd7,    // t1  = MM(r~, d)     → DÜZ r·d
    ST_OP_T2    = 6'd8,    // t2  = ModAdd(e, t1) → DÜZ e+r·d
    ST_OP_KM    = 6'd9,    // k~  = MM(k, R2N)
    // ── Ters alma: HER DURUM TEK İŞ YAPAR ────────────────────────────
    //   İlk sürümde ST_TERS_BEK üç işi birden yapıyordu (mod_n gönder,
    //   a gönder, bitişi bekle) ve paketleri gönderdikten sonra mcnt_r'yi
    //   sıfırlayıp AYNI DURUMDA kalıyordu. Sonraki çevrimde mcnt_r < 7
    //   yine doğru olduğu için paketler baştan gönderiliyor, bitiş HİÇ
    //   beklenmiyordu → sonsuz döngü. FSM S_IDLE'a dönmediği için modül
    //   tamamen sağırlaşıyor ve sonraki tüm işlemler de düşüyordu.
    //   Ders: bir durumun sayaç sıfırlaması varsa, o durumdan ÇIKIŞ da
    //   aynı dalda olmalı.
    ST_TERS_NRD = 6'd10,   // mod_n'i ters modülüne yükle: oku
    ST_TERS_NTX = 6'd11,   //                              gönder
    ST_TERS_ARD = 6'd12,   // a (k~) yükle: oku
    ST_TERS_ATX = 6'd13,   //               gönder + start
    ST_TERS_BEK = 6'd14,   // YALNIZCA bekle
    ST_OP_S     = 6'd15,   // s   = MM(k~ⁱ, t2)   → DÜZ s
    ST_CHK_S    = 6'd16,   // s == 0 ?
    ST_TXR_RD   = 6'd17,
    ST_TX_R     = 6'd18,
    ST_TXS_RD   = 6'd19,
    ST_TX_S     = 6'd20,
    ST_DONE     = 6'd21,
    ST_HATA     = 6'd22,
    // Sözcük-seri karşılaştırma alt-FSM'i (slot1 ? slot2)
    ST_CMP_RA   = 6'd23,
    ST_CMP_RB   = 6'd24,
    ST_CMP_CK   = 6'd25,
    // MALU dispatch alt-FSM'i (operandlar BRAM'den)
    ST_MA_ARD   = 6'd26,
    ST_MA_ATX   = 6'd27,
    ST_MA_BRD   = 6'd28,
    ST_MA_BTX   = 6'd29,
    ST_MA_GO    = 6'd30,
    ST_MA_WT    = 6'd31,
    ST_MA_RX    = 6'd32,
    ST_MA_WR    = 6'd33;

reg [5:0] state_r;

localparam [11:0] MA_WDOG_MAX  = 12'd4000;
localparam [19:0] TRS_WDOG_MAX = 20'd400_000;   // ters alma ~122.7k çevrim

// =============================================================================
// TEMMUZ 2026 — 32-BİT SÖZCÜK-ADRESLİ BRAM DÖNÜŞÜMÜ (Nihai Mimari, Adım 5)
//
//   Bu modül 2609 LUT / 3803 FF tutuyordu; kaynak 14 adet 256-bit yazmaç ve
//   onları dilimleyen 16 part-select mux'uydu (her biri ~150-170 LUT).
//
//   *** GİZLİ VERİ NOTU ***: d (özel anahtar) ve k (nonce) bu BRAM'de durur.
//   Bu YENİ bir maruziyet DEĞİLDİR — ikisi zaten bu modülün içinde düz
//   kayıtçılardaydı. BRAM MODÜLE ÖZELDİR; dışarı çıkan tek yol o_pkt_out'tur
//   ve oradan yalnızca (r, s) akar. Modülün port listesi değişmedi, yani
//   TB-16'nın "d dışarı sızmıyor" güvencesi aynen geçerlidir.
//
//   *** SABİT ZAMANLILIK KORUNDU ***: k ∈ [1,n-1] karşılaştırması hâlâ HER
//   ZAMAN 8 sözcük gezer (cmp_bitti_r kilidi), döngü kısalmaz. BRAM adresleri
//   yalnızca sayaçlara bağlıdır, nonce'a değil.
//
//   *** BRAM 1 ÇEVRİM GECİKMELİDİR: okuma adresi FETCH *VE* KULLANIM
//   durumunun İKİSİNDE de tutulur; RD/TX durumları ALMAŞIK olmak zorundadır ***
//   (TB-21'de yakalanan "çıktı bir sözcük kayması" hatasının dersi.)
//
//   KOPYA YOK: r, Rx < n ise A_RX'te, değilse A_R'dedir; hangi slotun geçerli
//   olduğu r_slot_r ile taşınır (8 çevrimlik kopya elenir).
// =============================================================================

// ── BRAM slot adresleri (her slot 8 x 32-bit sözcük) ─────────────────────
localparam [3:0] A_N=4'd0, A_E=4'd1, A_RX=4'd2, A_D=4'd3, A_K=4'd4,
                 A_R=4'd5, A_T2=4'd6, A_S=4'd7, A_KM=4'd8, A_KINV=4'd9,
                 A_RES=4'd10, A_R2N=4'd11;

// ── 32-bit geniş Block RAM scratchpad ────────────────────────────────────
(* ram_style = "block" *) reg [31:0] ara_mem [0:127];
reg [31:0] mem_rd_r;
reg [6:0]  mem_ra_c;
reg        mem_we_c;
reg [6:0]  mem_wa_c;
reg [31:0] mem_wd_c;
always @(posedge clk_in) begin
    if (mem_we_c) ara_mem[mem_wa_c] <= mem_wd_c;
    mem_rd_r <= ara_mem[mem_ra_c];
end

// ── Kayıtçılar — 256-bit olanların TAMAMI elendi ─────────────────────────
reg [3:0]   opid_a_r, opid_b_r, opid_res_r;
reg [3:0]   r_slot_r;      // r hangi slotta: A_RX (Rx<n) ya da A_R
reg [1:0]   opc_r;
reg [5:0]   mret_r;
reg [2:0]   mcnt_r;
reg [11:0]  ma_wdog_r;
reg [19:0]  trs_wdog_r;
reg [2:0]   pkt_rx_cnt_r, pkt_tx_cnt_r;
// 256-bit "== 0" karşılaştırmaları yerine sözcük sözcük biriken bayraklar
reg         rx_nz_r, k_nz_r, res_nz_r;

// Sözcük-seri karşılaştırma (slot1 ? slot2)
reg [3:0]   cmp_s1_r, cmp_s2_r;
reg [31:0]  cmp_v1_r;
reg [2:0]   cmp_idx_r;
reg         cmp_kucuk_r;
// SABIT ZAMANLI karsilastirma icin "karar verildi" bayragi.
//   Ilk farkli dilimde cikilsaydi cevrim sayisi, k ile n'in kac ust
//   word'unun ESLESTIGINE bagli olurdu — nonce hakkinda kucuk ama gercek
//   bir zamanlama kanali. Dongu HER ZAMAN 8 sozcuk gezer; karar ilk farkta
//   verilir ama sonuc kilitlenir ve kalan dilimler bosuna gezilir.
reg         cmp_bitti_r;
reg [5:0]   cmp_ret_r;

// ── Çıkış saklayıcıları ───────────────────────────────────────────────────
reg [31:0] o_pkt_out_r;
reg        o_pkt_vld_r, o_pkt_sel_r, o_pkt_last_r;
reg        o_rdy_r, o_done_r, o_err_r;
reg        o_r_sifir_r, o_s_sifir_r, o_k_gecersiz_r;
reg [31:0] malu_pkt_dat_r;
reg        malu_pkt_vld_r;
reg [1:0]  malu_pkt_sel_r, malu_opc_r;
reg        malu_st_r;

assign o_pkt_out    = o_pkt_out_r;
assign o_pkt_vld    = o_pkt_vld_r;
assign o_pkt_sel    = o_pkt_sel_r;
assign o_pkt_last   = o_pkt_last_r;
assign o_rdy        = o_rdy_r;
assign o_done       = o_done_r;
assign o_err        = o_err_r;
assign o_r_sifir    = o_r_sifir_r;
assign o_s_sifir    = o_s_sifir_r;
assign o_k_gecersiz = o_k_gecersiz_r;

// ── Ters alma modulune giden/gelen hatlar (ust seviyedeki TEK ornek) ────
//   Yerel arbitrasyon KALKTI; MALU dogrudan bu modulun.
assign mo_pkt_dat = malu_pkt_dat_r;
assign mo_pkt_vld = malu_pkt_vld_r;
assign mo_pkt_sel = malu_pkt_sel_r;
assign mo_opc     = malu_opc_r;
assign mo_st      = malu_st_r;

assign to_pkt_dat = trs_pkt_dat_r;
assign to_pkt_vld = trs_pkt_vld_r;
assign to_pkt_sel = trs_pkt_sel_r;
assign to_st      = trs_st_r;

wire        trs_pkt_vld_w = ti_pkt_vld;
wire [31:0] trs_pkt_out_w = ti_pkt_out;
wire        trs_done_w    = ti_done;
wire        trs_err_w     = ti_err;

reg         trs_pkt_vld_r, trs_st_r;
reg [31:0]  trs_pkt_dat_r;
reg [1:0]   trs_pkt_sel_r;

reg [2:0]   trs_rx_cnt_r;

// ── Giriş seçiciden BRAM slotuna eşleme ──────────────────────────────────
reg [3:0] giris_slot_w;
always @* begin
    case (i_pkt_sel)
        EIX_MODN: giris_slot_w = A_N;
        EIX_E:    giris_slot_w = A_E;
        EIX_RX:   giris_slot_w = A_RX;
        EIX_D:    giris_slot_w = A_D;
        default:  giris_slot_w = A_K;
    endcase
end

// ── BRAM OKUMA ADRESİ (KOMBİNASYONEL) ────────────────────────────────────
//   Adres hem FETCH hem KULLANIM durumunda tutulur.
always @* begin
    case (state_r)
        ST_SENDP_RD, ST_SENDP_TX:  mem_ra_c = {A_N, mcnt_r};
        ST_TERS_NRD, ST_TERS_NTX:  mem_ra_c = {A_N, mcnt_r};
        ST_TERS_ARD, ST_TERS_ATX:  mem_ra_c = {A_KM, mcnt_r};
        ST_MA_ARD,   ST_MA_ATX:    mem_ra_c = {opid_a_r, mcnt_r};
        ST_MA_BRD,   ST_MA_BTX:    mem_ra_c = {opid_b_r, mcnt_r};
        ST_CMP_RA:                 mem_ra_c = {cmp_s1_r, cmp_idx_r};
        ST_CMP_RB:                 mem_ra_c = {cmp_s2_r, cmp_idx_r};
        ST_TXR_RD,   ST_TX_R:      mem_ra_c = {r_slot_r, pkt_tx_cnt_r};
        ST_TXS_RD,   ST_TX_S:      mem_ra_c = {A_S, pkt_tx_cnt_r};
        default:                   mem_ra_c = 7'd0;
    endcase
end

// ── BRAM YAZMA DENETİMİ (KOMBİNASYONEL) ──────────────────────────────────
always @* begin
    mem_we_c = 1'b0; mem_wa_c = 7'd0; mem_wd_c = 32'd0;
    if (state_r == ST_IDLE) begin
        if (i_pkt_vld && (i_pkt_sel <= EIX_K)) begin
            mem_we_c = 1'b1;
            mem_wa_c = {giris_slot_w, pkt_rx_cnt_r};
            mem_wd_c = i_pkt_in;
        end
    end else if (state_r == ST_SENDP_TX) begin
        // mod n MALU'ya giderken (okuma portu) R2N sabiti de BRAM'e yazılır
        mem_we_c = 1'b1;
        mem_wa_c = {A_R2N, mcnt_r};
        mem_wd_c = R2N[mcnt_r*32 +: 32];
    end else if (state_r == ST_TERS_BEK) begin
        // mod_n_ters sonucu (k~ⁱ) geldiği gibi A_KINV'e yazılır
        if (trs_pkt_vld_w) begin
            mem_we_c = 1'b1;
            mem_wa_c = {A_KINV, trs_rx_cnt_r};
            mem_wd_c = trs_pkt_out_w;
        end
    end else if ((state_r == ST_MA_WT) || (state_r == ST_MA_RX)) begin
        if (mi_pkt_vld) begin
            mem_we_c = 1'b1;
            mem_wa_c = {opid_res_r, mcnt_r};
            mem_wd_c = mi_pkt_out;
        end
    end
end

// =========================================================================
//  ANA DURUM MAKİNESİ
// =========================================================================
always @(posedge clk_in or negedge rst_n) begin
    if (!rst_n) begin
        state_r <= ST_IDLE;
        opid_a_r <= A_R; opid_b_r <= A_R2N; opid_res_r <= A_RES;
        r_slot_r <= A_RX;
        opc_r <= 2'd0; mret_r <= 6'd0; mcnt_r <= 3'd0;
        ma_wdog_r <= 12'd0; trs_wdog_r <= 20'd0;
        pkt_rx_cnt_r <= 3'd0; pkt_tx_cnt_r <= 3'd0; trs_rx_cnt_r <= 3'd0;
        rx_nz_r <= 1'b0; k_nz_r <= 1'b0; res_nz_r <= 1'b0;
        cmp_s1_r <= A_RX; cmp_s2_r <= A_N; cmp_v1_r <= 32'd0;
        cmp_idx_r <= 3'd7; cmp_kucuk_r <= 1'b0; cmp_ret_r <= 6'd0;
        cmp_bitti_r <= 1'b0;
        o_pkt_out_r <= 32'd0; o_pkt_vld_r <= 1'b0; o_pkt_sel_r <= 1'b0;
        o_pkt_last_r <= 1'b0; o_rdy_r <= 1'b0; o_done_r <= 1'b0; o_err_r <= 1'b0;
        o_r_sifir_r <= 1'b0; o_s_sifir_r <= 1'b0; o_k_gecersiz_r <= 1'b0;
        malu_pkt_dat_r <= 32'd0; malu_pkt_vld_r <= 1'b0;
        malu_pkt_sel_r <= 2'd0; malu_opc_r <= 2'd0; malu_st_r <= 1'b0;
        trs_pkt_dat_r <= 32'd0; trs_pkt_vld_r <= 1'b0;
        trs_pkt_sel_r <= 2'd0; trs_st_r <= 1'b0;
    end else begin
        o_pkt_vld_r <= 1'b0; o_pkt_last_r <= 1'b0;
        o_done_r <= 1'b0; o_err_r <= 1'b0;
        malu_st_r <= 1'b0; malu_pkt_vld_r <= 1'b0;
        trs_st_r <= 1'b0; trs_pkt_vld_r <= 1'b0;

        // Ters alma çıktısını topla (o modül kendi hızında akıtır)
        // Ters alma ciktisi yazma blogunda A_KINV'e gidiyor; sayac burada
        if (trs_pkt_vld_w) trs_rx_cnt_r <= trs_rx_cnt_r + 3'd1;

        if (mi_err) begin
            o_err_r <= 1'b1; o_rdy_r <= 1'b1; state_r <= ST_IDLE;
        end else if (trs_err_w) begin
            o_err_r <= 1'b1; o_rdy_r <= 1'b1; state_r <= ST_IDLE;
        end else begin
        case (state_r)

        ST_IDLE: begin
            o_rdy_r <= 1'b1;
            if (i_pkt_vld) begin
                case (i_pkt_sel)
                    // Veri BRAM'e yazma blogunda gidiyor; burada yalnizca
                    // "sifirdan farkli mi" bayraklari birikir.
                    EIX_RX: rx_nz_r <= (pkt_rx_cnt_r==3'd0) ? (i_pkt_in!=32'd0)
                                                            : (rx_nz_r | (i_pkt_in!=32'd0));
                    EIX_K:  k_nz_r  <= (pkt_rx_cnt_r==3'd0) ? (i_pkt_in!=32'd0)
                                                            : (k_nz_r  | (i_pkt_in!=32'd0));
                    default:  ;
                endcase
                pkt_rx_cnt_r <= pkt_rx_cnt_r + 3'd1;
            end
            if (i_start) begin
                o_rdy_r        <= 1'b0;
                o_r_sifir_r    <= 1'b0;
                o_s_sifir_r    <= 1'b0;
                o_k_gecersiz_r <= 1'b0;
                pkt_rx_cnt_r   <= 3'd0;
                trs_rx_cnt_r   <= 3'd0;
                mcnt_r         <= 3'd0;
                state_r        <= ST_SENDP_RD;
            end
        end

        // MALU'ya modül olarak n yüklenir — bu modülün tamamı GF(n) içinde.
        // mod n MALU'ya gonderilir; ayni 8 cevrimde R2N sabiti BRAM'e yazilir
        ST_SENDP_RD: state_r <= ST_SENDP_TX;
        ST_SENDP_TX: begin
            malu_pkt_vld_r <= 1'b1;
            malu_pkt_dat_r <= mem_rd_r;
            malu_pkt_sel_r <= MSEL_P;
            if (mcnt_r == 3'd7) begin
                mcnt_r    <= 3'd0;
                cmp_s1_r  <= A_RX; cmp_s2_r <= A_N;
                cmp_idx_r <= 3'd7;
                cmp_bitti_r <= 1'b0;
                cmp_kucuk_r <= 1'b0;   // tam esitlik -> 'kucuk degil'
                cmp_ret_r <= ST_RED_RX;
                state_r   <= ST_CMP_RA;
            end else begin mcnt_r <= mcnt_r + 3'd1; state_r <= ST_SENDP_RD; end
        end

        // Rx >= n ? — dilimli karşılaştırma (MSB word'den LSB'ye)
        // SABIT ZAMANLI: her zaman 8 cevrim. Bkz. cmp_bitti_r aciklamasi.
        // ── SOZCUK-SERI KARSILASTIRMA (slot1 ? slot2) ────────────────────
        //   BRAM boru hatti: RA slot1'i adresler, RB'de slot1 sozcugu hazir
        //   olur ve slot2 adreslenir, CK'da slot2 sozcugu hazir olur.
        //   SABIT ZAMANLI — k gizli nonce oldugu icin burada ozellikle
        //   onemli: dongu HER ZAMAN 8 sozcuk gezer, karar kilitlenir.
        ST_CMP_RA: state_r <= ST_CMP_RB;
        ST_CMP_RB: begin
            cmp_v1_r <= mem_rd_r;
            state_r  <= ST_CMP_CK;
        end
        ST_CMP_CK: begin
            if (!cmp_bitti_r && (cmp_v1_r != mem_rd_r)) begin
                cmp_kucuk_r <= (cmp_v1_r < mem_rd_r);
                cmp_bitti_r <= 1'b1;
            end
            if (cmp_idx_r == 3'd0) state_r <= cmp_ret_r;
            else begin
                cmp_idx_r <= cmp_idx_r - 3'd1;
                state_r   <= ST_CMP_RA;
            end
        end

        // p < 2n olduğu için TEK çıkarma yeter; genel mod işlemi gerekmez.
        //   KOPYA YOK: Rx < n ise r zaten A_RX'tedir, degilse A_R'ye yazilir.
        ST_RED_RX: begin
            if (cmp_kucuk_r) begin
                r_slot_r <= A_RX;                     // Rx < n
                state_r  <= ST_CHK_R;
            end else begin
                r_slot_r <= A_R;
                opid_a_r <= A_RX; opid_b_r <= A_N; opid_res_r <= A_R;
                opc_r <= MSUB;
                mret_r <= ST_CHK_R; mcnt_r <= 3'd0; state_r <= ST_MA_ARD;
            end
        end

        ST_CHK_R: begin
            // FIPS 186-4 §6.4: r == 0 ise YENİ k ile baştan denenmeli.
            //   256-bit "== 0" yerine sozcuk sozcuk biriken bayraklar:
            //   Rx yolundan gelindiyse rx_nz_r, ModSub yolundan res_nz_r.
            if (!(cmp_kucuk_r ? rx_nz_r : res_nz_r)) begin
                o_r_sifir_r <= 1'b1; state_r <= ST_HATA;
            end else begin
                // k ∈ [1, n-1] kontrolü. Benzersizliği DOĞRULANAMAZ.
                cmp_s1_r  <= A_K; cmp_s2_r <= A_N;
                cmp_idx_r <= 3'd7;
                cmp_bitti_r <= 1'b0;
                cmp_kucuk_r <= 1'b0;
                cmp_ret_r <= ST_OP_RM;
                state_r   <= ST_CMP_RA;
            end
        end

        // 1) r~ = MM(r, R2N)
        ST_OP_RM: begin
            if (!cmp_kucuk_r || !k_nz_r) begin
                o_k_gecersiz_r <= 1'b1; state_r <= ST_HATA;
            end else begin
                opid_a_r <= r_slot_r; opid_b_r <= A_R2N; opid_res_r <= A_RES;
                opc_r <= MMUL;
                mret_r <= ST_OP_T1; mcnt_r <= 3'd0; state_r <= ST_MA_ARD;
            end
        end

        // 2) t1 = MM(r~, d) → DÜZ r·d  (Montgomery R kendiliğinden iptal)
        ST_OP_T1: begin
            opid_a_r <= A_RES; opid_b_r <= A_D; opid_res_r <= A_RES;
            opc_r <= MMUL;
            mret_r <= ST_OP_T2; mcnt_r <= 3'd0; state_r <= ST_MA_ARD;
        end

        // 3) t2 = ModAdd(e, t1) → DÜZ e + r·d
        ST_OP_T2: begin
            opid_a_r <= A_E; opid_b_r <= A_RES; opid_res_r <= A_T2;
            opc_r <= MADD;
            mret_r <= ST_OP_KM; mcnt_r <= 3'd0; state_r <= ST_MA_ARD;
        end

        // 4) k~ = MM(k, R2N)
        ST_OP_KM: begin
            // t2 zaten A_T2'ye yazildi (ara yazmac yok)
            opid_a_r <= A_K; opid_b_r <= A_R2N; opid_res_r <= A_KM;
            opc_r <= MMUL;
            mret_r <= ST_TERS_NRD; mcnt_r <= 3'd0; state_r <= ST_MA_ARD;
        end

        // 5) k~ⁱ = mod_n_ters(k~)  — MALU sahipliği devrediliyor
        //    k~ bu noktada mres_r'dedir (ST_OP_KM'nin sonucu). Onu km_r'ye
        //    alıyoruz çünkü ters alma sırasında mres_r'ye dokunulmayacak
        //    olsa da, bağımlılığı açık tutmak sonradan okuyanı yanıltmaz.
        //   k~ zaten A_KM'ye yazildi (ara yazmac yok)
        ST_TERS_NRD: state_r <= ST_TERS_NTX;
        ST_TERS_NTX: begin
            trs_pkt_vld_r <= 1'b1;
            trs_pkt_sel_r <= 2'd0;                         // mod_n
            trs_pkt_dat_r <= mem_rd_r;
            if (mcnt_r == 3'd7) begin
                mcnt_r  <= 3'd0;
                state_r <= ST_TERS_ARD;
            end else begin mcnt_r <= mcnt_r + 3'd1; state_r <= ST_TERS_NRD; end
        end

        ST_TERS_ARD: state_r <= ST_TERS_ATX;
        ST_TERS_ATX: begin
            trs_pkt_vld_r <= 1'b1;
            trs_pkt_sel_r <= 2'd1;                         // a = k~
            trs_pkt_dat_r <= mem_rd_r;
            if (mcnt_r == 3'd7) begin
                trs_st_r     <= 1'b1;                      // son paketle start
                mcnt_r       <= 3'd0;
                trs_rx_cnt_r <= 3'd0;
                trs_wdog_r   <= 20'd0;
                state_r      <= ST_TERS_BEK;
            end else begin mcnt_r <= mcnt_r + 3'd1; state_r <= ST_TERS_ARD; end
        end

        // YALNIZCA bekler — paket göndermez, sayaç sıfırlamaz.
        ST_TERS_BEK: begin
            if (trs_wdog_r >= TRS_WDOG_MAX) begin
                o_err_r <= 1'b1; o_rdy_r <= 1'b1; state_r <= ST_IDLE;
            end else if (trs_done_w) begin
                state_r <= ST_OP_S;
            end else begin
                trs_wdog_r <= trs_wdog_r + 20'd1;
            end
        end

        // 6) s = MM(k~ⁱ, t2) → DÜZ s
        ST_OP_S: begin
            opid_a_r <= A_KINV; opid_b_r <= A_T2; opid_res_r <= A_S;
            opc_r <= MMUL;
            mret_r <= ST_CHK_S; mcnt_r <= 3'd0; state_r <= ST_MA_ARD;
        end

        ST_CHK_S: begin
            // s zaten A_S'ye yazildi. FIPS 186-4 §6.4: s == 0 ise YENI k
            // ile bastan denenmeli. (256-bit "==0" yerine res_nz_r bayragi)
            if (!res_nz_r) begin
                o_s_sifir_r <= 1'b1; state_r <= ST_HATA;
            end else begin
                pkt_tx_cnt_r <= 3'd0; state_r <= ST_TXR_RD;
            end
        end

        //   *** RD ve TX ALMASIK olmak ZORUNDA *** (BRAM 1 cevrim gecikmeli)
        ST_TXR_RD: state_r <= ST_TX_R;
        ST_TX_R: begin
            o_pkt_vld_r  <= 1'b1;
            o_pkt_sel_r  <= 1'b0;
            o_pkt_out_r  <= mem_rd_r;
            o_pkt_last_r <= (pkt_tx_cnt_r == 3'd7);
            if (pkt_tx_cnt_r == 3'd7) begin
                pkt_tx_cnt_r <= 3'd0; state_r <= ST_TXS_RD;
            end else begin
                pkt_tx_cnt_r <= pkt_tx_cnt_r + 3'd1; state_r <= ST_TXR_RD;
            end
        end

        ST_TXS_RD: state_r <= ST_TX_S;
        ST_TX_S: begin
            o_pkt_vld_r  <= 1'b1;
            o_pkt_sel_r  <= 1'b1;
            o_pkt_out_r  <= mem_rd_r;
            o_pkt_last_r <= (pkt_tx_cnt_r == 3'd7);
            if (pkt_tx_cnt_r == 3'd7) state_r <= ST_DONE;
            else begin
                pkt_tx_cnt_r <= pkt_tx_cnt_r + 3'd1; state_r <= ST_TXS_RD;
            end
        end

        ST_DONE: begin
            o_done_r <= 1'b1; o_rdy_r <= 1'b1; state_r <= ST_IDLE;
        end

        // Yeniden deneme gerektiren durumlar: o_err DEĞİL, ayrı bayraklar.
        // Bunlar donanım arızası değildir; çağıran YENİ k ile tekrar çağırmalı.
        ST_HATA: begin
            o_rdy_r <= 1'b1; o_done_r <= 1'b1; state_r <= ST_IDLE;
        end

        // ── MALU DISPATCH ALT-FSM'İ ───────────────────────────────────────
        //   ma_r / mb_r / mres_r ara yazmaclari TAMAMEN KALDIRILDI:
        //   operandlar BRAM'den akitilir, sonuc geldigi gibi BRAM'e yazilir.
        //   res_nz_r, sonucun sifirdan farkli olup olmadigini sozcuk sozcuk
        //   biriktirir (256-bit "== 0" karsilastirmasinin yerine gecer).
        ST_MA_ARD: state_r <= ST_MA_ATX;
        ST_MA_ATX: begin
            malu_pkt_vld_r <= 1'b1;
            malu_pkt_dat_r <= mem_rd_r;
            malu_pkt_sel_r <= MSEL_A;
            malu_opc_r     <= opc_r;
            if (mcnt_r == 3'd7) begin mcnt_r <= 3'd0; state_r <= ST_MA_BRD; end
            else begin mcnt_r <= mcnt_r + 3'd1; state_r <= ST_MA_ARD; end
        end

        ST_MA_BRD: state_r <= ST_MA_BTX;
        ST_MA_BTX: begin
            malu_pkt_vld_r <= 1'b1;
            malu_pkt_dat_r <= mem_rd_r;
            malu_pkt_sel_r <= MSEL_B;
            if (mcnt_r == 3'd7) begin mcnt_r <= 3'd0; state_r <= ST_MA_GO; end
            else begin mcnt_r <= mcnt_r + 3'd1; state_r <= ST_MA_BRD; end
        end

        ST_MA_GO: begin
            malu_st_r  <= 1'b1;
            malu_opc_r <= opc_r;
            ma_wdog_r  <= 12'd0;
            mcnt_r     <= 3'd0;
            res_nz_r   <= 1'b0;      // yeni sonuc icin sifirla
            state_r    <= ST_MA_WT;
        end

        ST_MA_WT: begin
            // Ilk sozcuk yazma blogunda BRAM'e gitti (mcnt_r = 0)
            if (ma_wdog_r >= MA_WDOG_MAX) begin
                o_err_r <= 1'b1; o_rdy_r <= 1'b1; state_r <= ST_IDLE;
            end else if (mi_pkt_vld) begin
                res_nz_r <= (mi_pkt_out != 32'd0);
                mcnt_r <= 3'd1; state_r <= ST_MA_RX;
            end else ma_wdog_r <= ma_wdog_r + 12'd1;
        end

        ST_MA_RX: begin
            if (mi_pkt_vld) begin
                res_nz_r <= res_nz_r | (mi_pkt_out != 32'd0);
                if (mcnt_r == 3'd7) begin mcnt_r <= 3'd0; state_r <= ST_MA_WR; end
                else                      mcnt_r <= mcnt_r + 3'd1;
            end
        end

        // Son yazmanin BRAM'e oturmasi icin 1 cevrimlik tampon
        ST_MA_WR: state_r <= mret_r;

        default: state_r <= ST_IDLE;

        endcase
        end
    end
end

endmodule
