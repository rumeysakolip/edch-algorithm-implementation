// =============================================================================
// Modül   : ecdh_kex_top.v   (Uçtan uca ECDH KES; wire/reg ayrımı)
// Proje   : FPGA Tabanlı Güvenli Anahtar Yönetimi ve Kripto Hızlandırıcı
// No      : 5260007 — Sakarya Uygulamalı Bilimler Üniversitesi
// -----------------------------------------------------------------------------
// Açıklama:
//   NIST P-256 uçtan uca ECDH Anahtar Değişim Sistemi üst denetleyicisi.
//   Akış: TRNG'den d al → Qa=d·G (→Affin, çıkış) → Qb al → S=d·Qb (→Affin, çıkış).
//   Bu sürümde WIRE/REG AYRIMI: tüm çıkış portları saf 'wire'; senkron
//   değerler dahili '*_r'de tutulup portlara 'assign' ile aktarılır.
//
// -----------------------------------------------------------------------------
// TEMMUZ 2026 — GİRİŞ DOĞRULAMA SERTLEŞTİRMESİ (Faz 1)
//
//   [SEC-01] Qb TAM AÇIK-ANAHTAR DOĞRULAMASI
//     Yeni nokta_dogrula alt modülü, MALU'nun ÜÇÜNCÜ istemcisi olarak eklendi.
//     K_QB_VALIDATE artık aralık (x<p, y<p) ve eğri denklemi (y²=x³−3x+b)
//     kontrolü yapar. Önceki tek kontrol — (x==0 && y==0) — invalid-curve
//     saldırısına karşı KORUMASIZDI: Jacobian formülleri eğri sabiti b'yi
//     kullanmadığı için eğri dışı bir nokta sessizce işleniyor ve sonuç,
//     d'nin küçük asal mertebelere göre kalanını sızdırıyordu.
//     Maliyet: ~1900 çevrim (~19 µs), skaler çarpımın 34 ms'i yanında ihmal
//     edilebilir. Alan maliyeti MALU paylaşımı sayesinde çok düşüktür.
//
//   [SEC-02] SKALER ARALIK KONTROLÜ — d ∈ [1, n−1]
//     K_TRNG_CHK yalnız d != 0 sınıyordu. Artık n mertebesine karşı da
//     karşılaştırılır (K_D_CMP). d >= n ise İNDİRGENMEZ, reddetme örneklemesi
//     ile TRNG'den yeni aday çekilir (modulo bias'ı önler).
//     NIST SP 800-56A Rev.3 §5.6.1.2 uyumu.
//
//   [SEC-03] HATA NEDENİ AYRIMI — yeni o_err_kod[2:0] portu
//     Üst katman artık protokol hatasını (geçersiz nokta/skaler) donanım
//     arızasından ayırabilir; ikisi farklı ele alınmalıdır.
//
//   MALU ARBİTERİ 3 YOLLU oldu ve sahiplik aralıkları iki uçtan sınırlandı.
//   Eski owner_aff = (state_r >= K_AF_DMODP) ifadesi, affine durumlarının en
//   yüksek numaralılar olduğu varsayımına dayanıyordu; yeni durumlar eklenince
//   sessizce bozulurdu.
//
//   Hedef cihaz notu: 115 üst-seviye port, xq7a100t-cs324 (≥210 I/O) paketinde
//   yerleşir; port sayısı korunmuştur.
//
// -----------------------------------------------------------------------------
// TEMMUZ 2026 — DSP-MALU ENTEGRASYONU (Nihai Mimari, Adım 1)
//
//   shared_malu artık modular_alu_dsp.v örneği (DSP48E1 tabanlı CIOS
//   Montgomery). Port listesi modular_alu.v ile birebir aynı (drop-in),
//   arbiter mantığı (owner_* sinyalleri) DEĞİŞMEDİ. Kazanım: MontMult
//   259 çevrimden ~92-102 çevrime iner, çarpma LUT yerine DSP48E1'e taşınır.
//   modular_alu.v dosyası projeden ÇIKARILDI (Vivado sources_1), ancak
//   referans olarak diskte değiştirilmeden korunuyor; geri dönüş yolu açıktır.
//
// Standart : Verilog-2001 — sentezlenebilir
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
module ecdh_kex_top (
    input  wire         clk_in,
    input  wire         rst_n,
    input  wire         i_start,
    output wire         o_trng_req,
    input  wire         i_trng_vld,
    input  wire [31:0]  i_trng_pkt,
    input  wire [31:0]  i_pkt_in,
    input  wire         i_pkt_vld,
    // 0=Qb.x  1=Qb.y  2=r  3=s   (2 ve 3 yalnizca dogrulamada)
    input  wire [2:0]   i_pkt_sel,
    input  wire         i_qb_start,
    output wire [31:0]  o_pkt_out,
    output wire         o_pkt_vld,
    output wire [1:0]   o_pkt_sel,
    output wire         o_pkt_last,
    output wire [1:0]   o_stage,
    output wire         o_qa_done,
    output wire         o_rdy,
    output wire         o_done,
    output wire         o_err,
    // ── Hata nedeni (İster SEC-01) ────────────────────────────────────────
    //   o_err ile birlikte geçerlidir. Üst katmanın PROTOKOL hatasını
    //   (geçersiz nokta / geçersiz skaler) DONANIM arızasından ayırabilmesi
    //   için eklenmiştir; ikisi farklı ele alınmalıdır.
    output wire [2:0]   o_err_kod,

    // ══ FAZ 4: ANAHTAR SLOTU ARAYÜZÜ ═══════════════════════════════════
    //   Anahtar deposu BU MODÜLÜN İÇİNDEDİR. Komut katmanına konsaydı özel
    //   anahtar 256-bit bir yolla UART verisinin yaşadığı katmandan geçerdi
    //   ve TB-16'da ölçülen sızıntı garantisi orada çökerdi. Dışarıya yalnız
    //   slot numarası, politika ve darbeler girer; d asla çıkmaz.
    input  wire [1:0]   i_slot,        // hedef/kaynak anahtar slotu
    input  wire [7:0]   i_politika,    // yalnız üretimde anlamlı
    input  wire         i_zeroize,     // transient slotları sil
    output wire         o_slot_hata,   // slot/izin reddi (o_err ile birlikte)
    output wire [1:0]   o_uret_hata_kod,

    // ══ FAZ 5: ECDSA IMZALAMA ═══════════════════════════════════════════
    //   i_imzala darbesi: i_slot'taki anahtarla, i_hash ozeti uzerine imza.
    //   Nonce ICERIDE uretilir ve DISARI CIKMAZ.
    // "Slota anahtar uret ve BITIR". i_start'tan farki: i_start bir ECDH
    // OTURUMU baslatir ve Qa'dan sonra K_QB_WAIT'te karsi tarafin acik
    // anahtarini bekler; o_done vermez. Yalnizca anahtar uretmek isteyen
    // (ANAHTAR_URET komutu, ECDSA hazirligi) bu girisi kullanir ve islem
    // o_done ile temiz biter. Bu ayrim olmadan cekirdek K_QB_WAIT'te asili
    // kalir ve sonraki hicbir komutu isleyemez.
    input  wire         i_uret,
    input  wire         i_imzala,
    input  wire [31:0]  i_hash_pkt,    // e (mesaj ozeti), 8 paket LSB-once
    input  wire         i_hash_vld,
    output wire         o_imza_hazir,  // (r,s) akitiliyor
    output wire         o_imza_sel,    // 0 = r, 1 = s
    output wire         o_imza_tekrar, // r=0/s=0/k gecersiz -> YENIDEN dene

    // ══ FAZ 5c: ECDSA DOGRULAMA ═════════════════════════════════════════
    //   r ve s, i_pkt_sel=2/3 ile yuklenir; Q ise Qb yoluyla (i_pkt_sel=0/1)
    //   — dogrulamada Q zaten "karsi tarafin acik anahtari"dir, ECDH'deki
    //   Qb ile ayni sey. Ayri bir yol acmak gereksiz kopya olurdu.
    input  wire         i_dogrula,
    output wire         o_imza_gecerli,
    output wire         o_imza_aralik_hata,

    // ══ ENTEGRASYON DIKISI (İster INT-01) ═══════════════════════════════
    //   Simetrik katmanin (HKDF -> AEAD) baglanacagi yer. UART'a PARALEL
    //   calisir; UART yolu demo/teshis icindir, GERCEK kullanimda anahtar
    //   turetme bu portlardan beslenmelidir.
    //
    //   o_z_duz : Z = ortak noktanin x koordinati, DUZ (Montgomery DEGIL),
    //             SP 800-56A Rev.3 §5.7.1.2'ye uygun. Dogrudan HKDF-Extract
    //             girdisi olarak kullanilabilir.
    //   o_z_gecerli : Z hazir ve gecerli. Yeni bir ECDH baslayinca duser.
    output wire [255:0] o_z_duz,
    output wire         o_z_gecerli,
    //   o_dog_bitti : DOGRULAMA akisi bitti (1 cevrimlik darbe). o_done tek
    //   basina yetmez — ECDH ve uretim akislari da o_done uretir; tuketici
    //   hangi islemin bittigini ayirt edemezdi.
    output wire         o_dog_bitti,

    // ══ ÇOKLU EĞRİ DESTEĞİ (Temmuz 2026) — İster M-24 ═══════════════════
    //   komut_yoneticisi.v'nin parametre_deposu'ndan gelir. Reset/varsayılan
    //   P-256 olduğundan, host hiçbir EGRI_* komutu göndermezse davranış
    //   ESKİSİYLE BİREBİR AYNIDIR (bkz. parametre_deposu.v başlığı).
    input  wire [255:0] i_egri_p,
    input  wire [255:0] i_egri_r_mod_p,
    input  wire [255:0] i_egri_gx_mont,
    input  wire [255:0] i_egri_gy_mont,
    input  wire [255:0] i_egri_b_mont,
    input  wire [255:0] i_egri_n_order,
    input  wire [255:0] i_egri_mont_bir_n,
    input  wire [255:0] i_egri_r2n,
    input  wire [9:0]   i_egri_n_bit_uzunluk
);

// ── Hata nedeni kodları ────────────────────────────────────────────────
localparam [2:0] ERR_YOK    = 3'd0,
                 ERR_NOKTA  = 3'd1,   // Qb eğri üzerinde değil / aralık dışı
                 ERR_SKALER = 3'd2,   // d, [1, n-1] aralığına sokulamadı
                 ERR_CEKIRD = 3'd3,   // alt modül (SM / affine / dogrula) hatası
                 ERR_WDOG   = 3'd4,   // watchdog — kilitlenme
                 ERR_SLOT   = 3'd5,   // slot geçersiz / üretim reddedildi
                 ERR_IZIN   = 3'd6;   // slot politikası bu kullanıma izin vermiyor

// ── Eğri sabitleri (Montgomery) — ARTIK GİRİŞ (İster M-24) ────────────────
//   Eskiden burada P-256'ya sabit `localparam`lardı; artık komut_yoneticisi
//   .v'nin parametre_deposu'ndan gelir. Reset/varsayılan P-256 olduğundan
//   davranış değişmez. Aynı isimler korunur ki bu dosyanın geri kalanı
//   (P256[cnt*32+:32] gibi kullanımlar) HİÇ değişmesin.
wire [255:0] P256    = i_egri_p;
wire [255:0] R_MOD_P = i_egri_r_mod_p;
wire [255:0] GX_MONT = i_egri_gx_mont;
wire [255:0] GY_MONT = i_egri_gy_mont;
wire [255:0] GZ_MONT = R_MOD_P;

// Eğri mertebesi n — ECDSA imza dispatch'inde ecdsa_imza'ya yuklenir.
// d in [1,n-1] reddetme ornekleme BURADA DEGIL, anahtar_deposu.v icindedir.
wire [255:0] N_ORDER = i_egri_n_order;

// NOT: d in [1,n-1] reddetme ornekleme artik
//      anahtar_deposu.v icindedir — anahtarin dogrulugu URETILDIGI yerde
//      garanti edilir, iki ayri yerde tutulmaz. Küçük n'li eğrilerde (ör.
//      P-192/P-224) bu artık i_egri_n_bit_uzunluk ile MASKELENİR — bkz.
//      anahtar_deposu.v başlığı.


localparam [2:0] SIX_MODP=3'd0, SIX_SCALAR=3'd1, SIX_BX=3'd2, SIX_BY=3'd3, SIX_BZ=3'd4;
localparam [2:0] AIX_MODP=3'd0, AIX_X=3'd1, AIX_Y=3'd2, AIX_Z=3'd3;
localparam [1:0] QBIX_X=2'b00, QBIX_Y=2'b01;
localparam [1:0] STAGE_NONE=2'b00, STAGE_QA=2'b01, STAGE_SS=2'b10;

localparam [6:0]
    K_IDLE=7'd0,
    K_QA_SETUP=7'd4, K_QA_AFF_SETUP=7'd5, K_QA_TX_X=7'd6, K_QA_TX_Y=7'd7, K_QA_DONE=7'd8,
    K_QB_WAIT=7'd9, K_QB_VALIDATE=7'd10,
    K_SS_SETUP=7'd11, K_SS_AFF_SETUP=7'd12, K_SS_TX_X=7'd13, K_SS_TX_Y=7'd14, K_SS_DONE=7'd15,
    K_SM_DMODP=7'd16, K_SM_DSCLR=7'd17, K_SM_DBX=7'd18, K_SM_DBY=7'd19, K_SM_DBZ=7'd20,
    K_SM_DGO=7'd21, K_SM_DWAIT_X=7'd22, K_SM_DRX_X=7'd23, K_SM_DRX_Y=7'd24, K_SM_DRX_Z=7'd25,
    K_AF_DMODP=7'd26, K_AF_DX=7'd27, K_AF_DY=7'd28, K_AF_DZ=7'd29,
    K_AF_DGO=7'd30, K_AF_DWAIT_X=7'd31, K_AF_DRX_X=7'd32, K_AF_DRX_Y=7'd33,
    // ── Nokta doğrulama dispatch (İster SEC-01) ───────────────────────
    K_NV_DMODP=7'd34, K_NV_DX=7'd35, K_NV_DY=7'd36,
    K_NV_DGO=7'd37, K_NV_DWAIT=7'd38,
    // ── FAZ 4: anahtar slotu üretimi ──────────────────────────────────
    //   K_TRNG_* ve K_D_CMP durumlari KALDIRILDI: entropi toplama ve
    //   d ∈ [1,n-1] reddetme ornekleme artik anahtar_deposu'nun icinde.
    //   Anahtarin dogrulugu URETILDIGI yerde garanti edilmelidir; iki ayri
    //   yerde tutulan bir kural bir gun yalniz birinde guncellenir.
    K_UR_ISTE=7'd39, K_UR_BEK=7'd40,
    // ECDH oncesi slot izin kontrolu
    K_IZIN=7'd41,
    // ── FAZ 5: ECDSA imzalama akisi ───────────────────────────────────
    //   Nonce uretimi ve k*G hesabi MEVCUT yolu (K_UR_* -> K_QA_*) aynen
    //   kullanir; imza_modu_r bayragi K_QA_DONE'da akisi buraya cevirir.
    //   Boylece skaler carpim ve affin donusum TEK yerde kalir.
    K_IM_D_OKU=7'd42, K_IM_K_OKU=7'd43,
    K_IM_DMODN=7'd44, K_IM_DE=7'd45, K_IM_DRX=7'd46,
    K_IM_DD=7'd47,    K_IM_DK=7'd48, K_IM_GO=7'd49, K_IM_BEK=7'd50,
    K_IM_TX_R=7'd51,  K_IM_TX_S=7'd52, K_IM_DONE=7'd53,
    // ── Rx: Montgomery -> DUZ donusumu ────────────────────────────────
    //   affine_donusum Montgomery alaninda cikti verir; ecdsa_imza ise
    //   Rx'i DUZ bekler (TB-18 boyle dogrulandi). Donusum MM_p(Rx~,1)=Rx
    //   ile yapilir ve MODULUS p GEREKTIRIR — ecdsa_imza MALU'ya n
    //   yukledigi icin ORADA yapilamaz. Bu yuzden cagiran (bu modul)
    //   MALU'nun 6. istemcisi olur ve tek bir MontMult kosturur.
    //   Affine bittiginde MALU'da zaten p yuklu; yeniden yuklemeye gerek yok.
    K_IM_RX_TXA=7'd54, K_IM_RX_TXB=7'd55, K_IM_RX_GO=7'd56,
    K_IM_RX_WT=7'd57,  K_IM_RX_RX=7'd58,
    K_UR_DONE=7'd59,   // 'sadece uret' islemi temiz bitisi
    // ── FAZ 5c: ECDSA DOGRULAMA AKISI ─────────────────────────────────
    //   ecdsa_dogrula AS.1 (u1,u2) -> cift_skaler_carpim -> affine ->
    //   Rx duze cevir -> ecdsa_dogrula AS.2 (hukum).
    //   Affine ve Rx donusumu MEVCUT makineleri yeniden kullanir
    //   (aff_ret_r / rx_ret_r donus adresleri sayesinde).
    K_DG_DMODN=7'd60, K_DG_DE=7'd61, K_DG_DR=7'd62, K_DG_DS=7'd63,
    K_DG_GO=7'd64,    K_DG_BEK=7'd65,
    K_DG_CMODP=7'd66, K_DG_CU1=7'd67, K_DG_CU2=7'd68,
    K_DG_CQX=7'd69,   K_DG_CQY=7'd70, K_DG_CGO=7'd71, K_DG_CBEK=7'd72,
    K_DG_AFF=7'd73,   K_DG_RXP=7'd74, K_DG_DRX=7'd75,
    K_DG_HUK=7'd76,   K_DG_HBEK=7'd77, K_DG_DONE=7'd78,
    // ── Entegrasyon dikisi: Z'yi Montgomery'den duze cevir ──────────────
    K_SS_ZP=7'd79,    K_SS_ZAL=7'd80;

// Nonce icin ayrilmis slot. POLITIKASI 0'dir: hicbir izni yoktur, dolayisiyla
// biri bu slotu ECDH icin kullanmaya kalkarsa c_izin_var 0 doner ve reddedilir.
// Nonce'un yanlislikla kalici anahtar gibi kullanilmasi boylece imkansiz.
localparam [1:0] NONCE_SLOT = 2'd3;

reg [6:0] state_r;

localparam [23:0] SM_WDOG_MAX  = 24'd12_000_000;
localparam [19:0] AFF_WDOG_MAX = 20'd1_000_000;

// [DÜZELTME Temmuz 2026 — FF azaltma] bx/by/bz_src_r VE ax/ay/az_src_r
//   TAMAMEN KALDIRILDI. İkisi de gerçek depolama değil, gereksiz kopyaydı:
//     ax_src_r<=rj_x_r (K_QA_AFF_SETUP/K_DG_AFF/K_SS_AFF_SETUP'ta) yalnızca
//     rj_x_r'yi affine dispatch'e göndermeden önce kopyalıyordu; rj_x_r bu
//     süre boyunca hiç değişmediği için K_AF_DX/DY/DZ doğrudan rj_x/y/z_r'yi
//     okuyabilir — 3×256 bit kazanç, sıfır ek çevrim.
//     bx_src_r/by_src_r de ya sabit G ya da qb_x_r/qb_y_r'nin birebir
//     kopyasıydı; bz_src_r ise HER İKİ dalda da zaten R_MOD_P'ye eşitti
//     (GZ_MONT tanımı = R_MOD_P). sm_b_kaynak_r tek bitlik seçiciyle
//     K_SM_DBX/DBY/DBZ noktasında mux'lanıyor — 3×256 bit kazanç daha.
reg         sm_b_kaynak_r;  // 0 = G sabiti (Qa hesabı), 1 = Qb (paylaşılan sır)
reg [255:0] rj_x_r, rj_y_r, rj_z_r;
reg [255:0] fa_x_r, fa_y_r, qb_x_r, qb_y_r;
reg [2:0]   sm_cnt_r, aff_cnt_r, tx_cnt_r, qb_cnt_r;
// Operand yukleme indisi KENDINI HIZALAR: secici degistiginde 0'a doner.
// Boylece 8'lik paket dizileri arasinda bosluk olsa da, yukleme yanlis
// bir indisten baslasa da veri dogru yere yazilir. Ayni desen
// komut_yoneticisi'ndeki Qa/Sir yakalayicisinda da kullaniliyor.
reg [2:0]   qb_sel_r;
wire [2:0]  qb_idx_w = (i_pkt_sel != qb_sel_r) ? 3'd0 : qb_cnt_r;
// K_SM_DBX/DBY'nin okuma anındaki kaynak muxu (bz her zaman R_MOD_P):
wire [255:0] sm_bx_w = sm_b_kaynak_r ? qb_x_r : GX_MONT;
wire [255:0] sm_by_w = sm_b_kaynak_r ? qb_y_r : GY_MONT;
reg [6:0]   sm_ret_r, aff_ret_r, rx_ret_r;
reg [23:0]  sm_wdog_r;
reg [19:0]  aff_wdog_r;

// ── Nokta doğrulama (nokta_dogrula) dispatch kayıtçıları ───────────────
reg [2:0]   nv_cnt_r;        // paket sayacı (0..7)
reg [19:0]  nv_wdog_r;       // doğrulama ~1900 çevrim sürer; 1M bol paylı
localparam [19:0] NV_WDOG_MAX = 20'd1_000_000;

// ── FAZ 4: ANAHTAR DEPOSU ──────────────────────────────────────────────
//   d_r kaldirildi. Skaler artik slottan gelir ve BU MODULUN DISINA CIKMAZ:
//   kd_ozel_d yalnizca K_SM_DSCLR'da scalar_multiplier'a paketlenir.
reg         kd_uret_r, kd_acik_yaz_r;
reg  [1:0]  kd_kullanim_r;
wire        kd_uret_bitti_w, kd_uret_hata_w, kd_trng_iste_w;
wire [1:0]  kd_uret_hata_kod_w;
wire [255:0] kd_ozel_d_w;
wire        kd_ozel_gecerli_w, kd_izin_var_w;

reg [1:0]  o_uret_hata_kod_r;
// FAZ 5 — ECDSA imzalama kayitcilari
reg        imza_modu_r;         // akisi K_QA_DONE'dan imzaya cevirir
reg        uret_modu_r;         // 'sadece uret': K_QA_DONE -> K_UR_DONE
reg        dog_modu_r;          // ECDSA dogrulama akisi etkin
reg [255:0] r_dog_r, s_dog_r;   // dogrulanacak imza
reg [255:0] u1_r, u2_r;         // ecdsa_dogrula AS.1 ciktisi
reg [2:0]  dg_cnt_r; reg [1:0] dg_koord_r;
// DOGRULAMA WATCHDOG'U — GENISLIK KRITIK
//   Onceki surum: reg [19:0] + localparam [19:0] 20'd4_000_000
//   20 bit en fazla 1.048.575 tutar; 4.000.000 sessizce 854.272'ye KIRPILIR.
//   Cift skaler carpim tek basina ~1.8 M cevrim surdugunden dogrulama akisi
//   HER SEFERINDE ERR_WDOG ile olurdu. Vivado bunu yalnizca
//   [VRFC 10-8497] "literal value truncated" uyarisi olarak bildirir.
//   Sabitin degeri degil, TASIYICININ GENISLIGI hataliydi.
reg [22:0] dg_wdog_r;
localparam [22:0] DG_WDOG_MAX = 23'd4_000_000;
reg        ic_slot_gecerli_r;   // slot secimi iceriden mi
reg [1:0]  ic_slot_r;
reg [255:0] hash_r;             // e (mesaj ozeti)
reg [255:0] d_imza_r, k_imza_r; // slottan okunan ozel anahtar ve nonce
reg [255:0] rx_imza_r;          // (k*G).x  = fa_x_r
// ── Entegrasyon dikisi: KDF'ye verilecek DUZ ortak sir ───────────────────
reg [255:0] z_duz_r;            // Z = paylasilan noktanin x'i (DUZ, SP800-56A)
reg         z_gecerli_r;
reg         dog_bitti_r;   // dogrulama bitis darbesi
reg [255:0] imza_r_r, imza_s_r;
reg [2:0]   im_cnt_r;
reg [19:0]  im_wdog_r;
reg        o_imza_hazir_r, o_imza_sel_r, o_imza_tekrar_r;
reg [2:0]  hash_cnt_r;
assign o_imza_hazir  = o_imza_hazir_r;
assign o_imza_sel    = o_imza_sel_r;
assign o_imza_tekrar = o_imza_tekrar_r;
localparam [19:0] IM_WDOG_MAX = 20'd400_000;
// Bu modulun kendi MALU dispatch'i (Rx donusumu icin)
reg [31:0] kex_mo_dat_r; reg kex_mo_vld_r, kex_mo_st_r;
reg [1:0]  kex_mo_sel_r, kex_mo_opc_r;
wire [31:0] kex_mo_dat = kex_mo_dat_r;
wire        kex_mo_vld = kex_mo_vld_r;
wire [1:0]  kex_mo_sel = kex_mo_sel_r;
wire [1:0]  kex_mo_opc = kex_mo_opc_r;
wire        kex_mo_st  = kex_mo_st_r;
reg [11:0] kex_wdog_r;
localparam [11:0] KEX_WDOG_MAX = 12'd4000;
reg        o_slot_hata_r;
assign o_uret_hata_kod = o_uret_hata_kod_r;
assign o_slot_hata     = o_slot_hata_r;

anahtar_deposu #(.SLOT_SAY(4), .ID_BIT(2)) anahtar_dep (
    .g_saat(clk_in), .g_sifirla_n(rst_n),
    // ECDSA akisinda slot ICERIDEN secilir (nonce slotu / imza anahtari
    // slotu arasinda gecis gerekir). Normal ECDH'de disaridan gelen i_slot.
    .g_slot(ic_slot_gecerli_r ? ic_slot_r : i_slot),
    .g_uret(kd_uret_r),
    // Nonce slotu POLITIKASIZ uretilir (8'h00): hicbir izni yoktur, boylece
    // yanlislikla ECDH/imza anahtari gibi kullanilamaz — c_izin_var 0 doner.
    .g_politika(imza_modu_r ? 8'h00 : i_politika),
    .c_uret_bitti(kd_uret_bitti_w), .c_uret_hata(kd_uret_hata_w),
    .c_uret_hata_kod(kd_uret_hata_kod_w),
    // TRNG dogrudan gecirilir — entropi toplama depo icinde yapilir
    .c_trng_iste(kd_trng_iste_w),
    .g_trng_word(i_trng_pkt), .g_trng_vld(i_trng_vld),
    // Qa hesaplandiktan sonra slota geri yazilir
    .g_acik_yaz(kd_acik_yaz_r), .g_acik_x(fa_x_r), .g_acik_y(fa_y_r),
    .c_acik_x(), .c_acik_y(), .c_acik_gecerli(),
    // *** Ozel anahtar: TEK okuyucu K_SM_DSCLR'dir ***
    .c_ozel_d(kd_ozel_d_w), .c_ozel_gecerli(kd_ozel_gecerli_w),
    .c_politika(), .c_kalici(),
    .g_kullanim(kd_kullanim_r), .c_izin_var(kd_izin_var_w),
    .g_zeroize(i_zeroize),
    .g_n_order(N_ORDER), .g_n_bit_uzunluk(i_egri_n_bit_uzunluk)
);

// ── Hata nedeni kayıtçısı ──────────────────────────────────────────────
reg [2:0]  o_err_kod_r;
assign o_err_kod = o_err_kod_r;

// ── Çıkış saklayıcıları → wire portlara assign ─────────────────────────
reg [31:0] o_pkt_out_r;
reg        o_pkt_vld_r;
reg [1:0]  o_pkt_sel_r;
reg        o_pkt_last_r;
reg [1:0]  o_stage_r;
reg        o_qa_done_r, o_rdy_r, o_done_r, o_err_r;
assign o_trng_req = kd_trng_iste_w;   // entropi istegi anahtar_deposu'ndan
assign o_pkt_out  = o_pkt_out_r;
assign o_pkt_vld  = o_pkt_vld_r;
assign o_pkt_sel  = o_pkt_sel_r;
assign o_pkt_last = o_pkt_last_r;
assign o_stage    = o_stage_r;
assign o_qa_done  = o_qa_done_r;
assign o_rdy      = o_rdy_r;
assign o_done     = o_done_r;
assign o_err      = o_err_r;

// ── PAYLAŞILAN TEK MALU + SAHİPLİK ARBİTERİ (3 YOLLU) ──────────────────
//   Skaler çarpım (SM), affine dönüşüm ve nokta doğrulama SIRALI çalışır —
//   hiçbir ikisi aynı anda MALU istemez → tek MALU örneği yeterlidir.
//   Bu, üç modular_alu yerine tek örnek kullanarak ciddi LUT/DSP tasarrufu
//   sağlar; nokta doğrulamanın alan maliyetini neredeyse sıfıra indirir.
//
//   ÖNEMLİ — sahiplik aralıkları AÇIK yazılmıştır:
//   Önceki sürümde owner_aff = (state_r >= K_AF_DMODP) idi. Bu, affine
//   durumlarının en yüksek numaralı durumlar olduğu VARSAYIMINA dayanıyordu.
//   Doğrulama durumları (34..38) eklenince o varsayım çöker ve affine, kendisi
//   çalışmadığı hâlde MALU'yu ele geçirirdi. Aralıklar artık iki uçtan da
//   sınırlıdır; ileride yeni durum eklendiğinde sessizce bozulmaz.
wire owner_aff = (state_r >= K_AF_DMODP) && (state_r <= K_AF_DRX_Y);  // 26..33
wire owner_nv  = (state_r >= K_NV_DMODP) && (state_r <= K_NV_DWAIT);  // 34..38
// ── ECDSA istemcileri ─────────────────────────────────────────────────
//   Modul ve arbiter BAGLANTILARI TAM; ancak ECDSA akis durumlari (imza /
//   dogrulama FSM'i) henuz eklenmedigi icin bu istemciler SECILMEZ.
//   4. adimda gercek kosullarla degistirilecek. Sabit 0 birakmak, o zamana
//   kadar mevcut ECDH yolunun BIT BIT ayni kalmasini garanti eder.
// ECDSA imza akisi K_IM_GO..K_IM_BEK arasinda MALU'ya ihtiyac duyar.
// ecdsa_imza kendi icinde mod_n_ters'i de tetikler; ters alma calisirken
// MALU onun olmalidir. mnt_rdy dususu bunu dogrudan gosterir.
wire owner_mnt = !mnt_rdy_w;
wire owner_imz = ((state_r >= K_IM_GO) && (state_r <= K_IM_BEK)) && mnt_rdy_w;
// ecdsa_dogrula MALU'yu AS.1 (K_DG_GO..K_DG_BEK) ve AS.2 (K_DG_HUK..HBEK)
// sirasinda kullanir; ters alma calisirken MALU onun degildir.
wire owner_dog = (((state_r >= K_DG_GO)  && (state_r <= K_DG_BEK)) ||
                  ((state_r >= K_DG_HUK) && (state_r <= K_DG_HBEK))) && mnt_rdy_w;
// cift_skaler_carpim PAU'yu yalnizca cift carpim asamasinda kullanir.
wire owner_csc = (state_r >= K_DG_CGO) && (state_r <= K_DG_CBEK);
// Bu modulun KENDISI de MALU istemcisi: Rx'i Montgomery'den duze cevirir.
wire owner_kex = (state_r >= K_IM_RX_TXA) && (state_r <= K_IM_RX_RX);

wire owner_pau = !owner_aff && !owner_nv && !owner_mnt && !owner_imz && !owner_kex && !owner_dog;

// ═════════════════════════════════════════════════════════════════════════
//  PAYLASILAN KAYNAK HATLARININ ILERI BILDIRIMI
// -------------------------------------------------------------------------
//  *** BU BLOK SILINEMEZ / ASAGI TASINAMAZ ***
//
//  Verilog'da bir port baglantisinda BILDIRILMEMIS bir isim gecerse derleyici
//  hata vermez: sessizce 1 BITLIK ORTUK (implicit) bir net yaratir. Ilerideki
//  gercek bildirim ise ayri bir nesne olur. Sonuc: 32 bitlik bir veri yolu
//  tek bite iner, ya da iki farkli net olusur ve arada hicbir baglanti kalmaz.
//  Sentez ve simulasyon araclari bu durumu FARKLI cozer — yani tasarim
//  "simulasyonda calisip kartta calismama" sinifina girer.
//
//  Vivado bunu yalnizca WARNING olarak bildirir:
//     [VRFC 10-2938] 'mnt_mo_dat' is already implicitly declared on line 365
//     [VRFC 10-3380] identifier 'mnt_rdy_w' is used before its declaration
//
//  Paylasilan kaynak mimarisinde (tek MALU / tek PAU / tek mod_n_ters) her
//  arbiter mux'i, istemci modul ORNEKLENMEDEN once onun hatlarina bakmak
//  zorundadir. Bu yuzden TUM paylasilan hatlar arbiterlerden ONCE, tek bir
//  yerde bildirilir. Yeni bir istemci eklendiginde hatlari BURAYA yazilmali.
// ═════════════════════════════════════════════════════════════════════════

// PAU (tek ornek) -> tum istemciler
wire [31:0] pau_out_w;
wire        pau_vld_w, pau_last_w, pau_rdy_w, pau_done_w, pau_err_w;
wire [1:0]  pau_sel_w;

// mod_n_ters (tek ornek) -> tum istemciler
wire [31:0] mnt_pkt_out_w; wire mnt_pkt_vld_w, mnt_pkt_last_w;
wire        mnt_rdy_w, mnt_done_w, mnt_err_w;

// MALU istemci master hatlari (mod_n_ters / ecdsa_imza / ecdsa_dogrula)
wire [31:0] mnt_mo_dat;  wire mnt_mo_vld, mnt_mo_st; wire [1:0] mnt_mo_sel, mnt_mo_opc;
wire [31:0] imz_mo_dat;  wire imz_mo_vld, imz_mo_st; wire [1:0] imz_mo_sel, imz_mo_opc;
wire [31:0] dog_mo_dat;  wire dog_mo_vld, dog_mo_st; wire [1:0] dog_mo_sel, dog_mo_opc;

// mod_n_ters istemci master hatlari (imza / dogrulama)
wire [31:0] imz_to_dat;  wire imz_to_vld, imz_to_st; wire [1:0] imz_to_sel;
wire [31:0] dog_to_dat;  wire dog_to_vld, dog_to_st; wire [1:0] dog_to_sel;

// cift_skaler_carpim -> PAU master hatlari
wire [31:0] csc_po_dat;  wire csc_po_vld, csc_po_cmd, csc_po_st; wire [2:0] csc_po_sel;

// scalar_multiplier -> PAU master hatlari
wire [31:0] sm_po_dat;  wire sm_po_vld, sm_po_cmd, sm_po_st;  wire [2:0] sm_po_sel;
// PAU -> MALU master hatlari
wire [31:0] pau_mo_dat; wire pau_mo_vld, pau_mo_st;  wire [1:0] pau_mo_sel, pau_mo_opc;

wire [31:0] aff_mo_dat, nv_mo_dat;
wire        aff_mo_vld, nv_mo_vld;
wire [1:0]  aff_mo_sel, nv_mo_sel;
wire [1:0]  aff_mo_opc, nv_mo_opc;
wire        aff_mo_st,  nv_mo_st;
wire [31:0] mal_out_w;
wire        mal_vld_w, mal_last_w, mal_rdy_w, mal_done_w, mal_err_w;

// [ADIM-1] DSP48E1 tabanli CIOS MALU — modular_alu.v ile port-port ayni
// (drop-in); MontMult 259 -> ~92-102 cevrime iner. Eski modular_alu.v
// projeden CIKARILDI, referans olarak degismeden korunuyor.
modular_alu_dsp shared_malu (
    .clk_in(clk_in), .rst_n(rst_n),
    // 5 YOLLU MUX — oncelik sirasi sabit ve tek yerde tanimli
    // 6 YOLLU MUX
    .i_pkt_in (owner_kex ? kex_mo_dat : owner_nv  ? nv_mo_dat  : owner_aff ? aff_mo_dat :
               owner_mnt ? mnt_mo_dat : owner_imz ? imz_mo_dat : owner_dog ? dog_mo_dat : pau_mo_dat),
    .i_pkt_vld(owner_kex ? kex_mo_vld : owner_nv  ? nv_mo_vld  : owner_aff ? aff_mo_vld :
               owner_mnt ? mnt_mo_vld : owner_imz ? imz_mo_vld : owner_dog ? dog_mo_vld : pau_mo_vld),
    .i_pkt_sel(owner_kex ? kex_mo_sel : owner_nv  ? nv_mo_sel  : owner_aff ? aff_mo_sel :
               owner_mnt ? mnt_mo_sel : owner_imz ? imz_mo_sel : owner_dog ? dog_mo_sel : pau_mo_sel),
    .i_opcode (owner_kex ? kex_mo_opc : owner_nv  ? nv_mo_opc  : owner_aff ? aff_mo_opc :
               owner_mnt ? mnt_mo_opc : owner_imz ? imz_mo_opc : owner_dog ? dog_mo_opc : pau_mo_opc),
    .i_start  (owner_kex ? kex_mo_st  : owner_nv  ? nv_mo_st   : owner_aff ? aff_mo_st  :
               owner_mnt ? mnt_mo_st  : owner_imz ? imz_mo_st  : owner_dog ? dog_mo_st  : pau_mo_st),
    .o_pkt_out(mal_out_w), .o_pkt_vld(mal_vld_w), .o_pkt_last(mal_last_w),
    .o_rdy(mal_rdy_w), .o_done(mal_done_w), .o_err(mal_err_w)
);

// ── scalar_multiplier ──────────────────────────────────────────────────
reg  sm_pkt_vld_r; reg [31:0] sm_pkt_dat_r; reg [2:0] sm_pkt_sel_r; reg sm_st_r;
wire [31:0] sm_pkt_out_w; wire sm_pkt_vld_w; wire [1:0] sm_pkt_sel_w;
wire sm_pkt_last_w, sm_rdy_w, sm_done_w, sm_err_w;
scalar_multiplier sm_inst (
    .clk_in(clk_in), .rst_n(rst_n), .i_pkt_in(sm_pkt_dat_r), .i_pkt_vld(sm_pkt_vld_r),
    .i_pkt_sel(sm_pkt_sel_r), .i_start(sm_st_r), .i_rand_seed(256'd0), .i_rand_vld(1'b0),
    .o_pkt_out(sm_pkt_out_w), .o_pkt_vld(sm_pkt_vld_w), .o_pkt_sel(sm_pkt_sel_w),
    .o_pkt_last(sm_pkt_last_w), .o_rdy(sm_rdy_w), .o_done(sm_done_w), .o_err(sm_err_w),
    // PAU master — PAU artik bu modulun icinde degil, asagida TEK ornek
    .po_pkt_dat(sm_po_dat), .po_pkt_vld(sm_po_vld), .po_pkt_sel(sm_po_sel),
    .po_cmd(sm_po_cmd), .po_st(sm_po_st),
    .pi_pkt_out(pau_out_w), .pi_pkt_vld(pau_vld_w), .pi_pkt_sel(pau_sel_w),
    .pi_pkt_last(pau_last_w), .pi_rdy(pau_rdy_w), .pi_done(pau_done_w),
    .pi_err(!owner_csc ? pau_err_w : 1'b0)
);

// ═════════════════════════════════════════════════════════════════════════
//  PAYLASILAN TEK PAU + SAHIPLIK ARBITERI
// ═════════════════════════════════════════════════════════════════════════
//   PAU, 40+ ara degisken icin BRAM scratchpad kullanir; en pahali
//   kopyalanabilir birimdir. Onceden scalar_multiplier'in ICINDEYDI ve
//   ECDSA dogrulamasi (cift_skaler_carpim) eklendiginde IKINCI bir kopya
//   sentezlenecekti.
//
//   Skaler carpim (ECDH/ECDSA imza) ve cift skaler carpim (ECDSA dogrulama)
//   ASLA ayni anda calismaz — protokol siralidir. Bu yuzden tek ornek
//   yeterlidir.
//
//   Su an tek istemci var (scalar_multiplier); cift_skaler_carpim baglanana
//   kadar arbiter tek yolludur. Sahiplik ifadesi ACIK yazilmistir ki ikinci
//   istemci eklendiginde sessizce bozulmasin — MALU arbiterinde tam olarak
//   bu hata yasanmisti (owner_aff = state_r >= K_AF_DMODP varsayimi).


// (pau_* hatlari yukaridaki ileri bildirim blogunda tanimli)

point_arithmetic_unit pau_ortak (
    .clk_in(clk_in), .rst_n(rst_n),
    // 2 YOLLU MUX: skaler carpim (ECDH/imza) | cift skaler carpim (dogrulama)
    .i_pkt_in (owner_csc ? csc_po_dat : sm_po_dat),
    .i_pkt_vld(owner_csc ? csc_po_vld : sm_po_vld),
    .i_pkt_sel(owner_csc ? csc_po_sel : sm_po_sel),
    .i_cmd    (owner_csc ? csc_po_cmd : sm_po_cmd),
    .i_start  (owner_csc ? csc_po_st  : sm_po_st),
    .o_pkt_out(pau_out_w), .o_pkt_vld(pau_vld_w), .o_pkt_sel(pau_sel_w),
    .o_pkt_last(pau_last_w), .o_rdy(pau_rdy_w), .o_done(pau_done_w),
    .o_err(pau_err_w),
    // PAU, MALU'nun DORDUNCU istemcisidir
    .mo_pkt_dat(pau_mo_dat), .mo_pkt_vld(pau_mo_vld), .mo_pkt_sel(pau_mo_sel),
    .mo_opc(pau_mo_opc), .mo_st(pau_mo_st),
    .mi_pkt_out(mal_out_w), .mi_pkt_vld(mal_vld_w), .mi_pkt_last(mal_last_w),
    .mi_rdy(mal_rdy_w), .mi_done(mal_done_w),
    .mi_err(owner_pau ? mal_err_w : 1'b0)
);


// ── affine_donusum ─────────────────────────────────────────────────────
reg  aff_pkt_vld_r; reg [31:0] aff_pkt_dat_r; reg [2:0] aff_pkt_sel_r; reg aff_st_r;
wire [31:0] aff_pkt_out_w; wire aff_pkt_vld_w; wire [1:0] aff_pkt_sel_w;
wire aff_pkt_last_w, aff_rdy_w, aff_done_w, aff_err_w;
affine_donusum aff_inst (
    .clk_in(clk_in), .rst_n(rst_n), .i_pkt_in(aff_pkt_dat_r), .i_pkt_vld(aff_pkt_vld_r),
    .i_pkt_sel(aff_pkt_sel_r), .i_start(aff_st_r),
    .o_pkt_out(aff_pkt_out_w), .o_pkt_vld(aff_pkt_vld_w), .o_pkt_sel(aff_pkt_sel_w),
    .o_pkt_last(aff_pkt_last_w), .o_rdy(aff_rdy_w), .o_done(aff_done_w), .o_err(aff_err_w),
    .mo_pkt_dat(aff_mo_dat), .mo_pkt_vld(aff_mo_vld), .mo_pkt_sel(aff_mo_sel),
    .mo_opc(aff_mo_opc), .mo_st(aff_mo_st),
    .mi_pkt_out(mal_out_w), .mi_pkt_vld(mal_vld_w), .mi_pkt_last(mal_last_w),
    .mi_rdy(mal_rdy_w), .mi_done(mal_done_w), .mi_err(owner_aff ? mal_err_w : 1'b0),
    .g_mont_bir(R_MOD_P), .g_p(P256)
);

// ── nokta_dogrula — Qb tam açık-anahtar doğrulaması ────────────────────
//   ECDH'de Qb KARŞI TARAFTAN gelir; saldırganın tam kontrolündedir. Eğri
//   üstünde olduğu doğrulanmazsa invalid-curve saldırısıyla d sızdırılabilir
//   (bkz. nokta_dogrula.v başlığı). Bu örnek, MALU'nun üçüncü istemcisidir.
reg  nv_pkt_vld_r; reg [31:0] nv_pkt_dat_r; reg [2:0] nv_pkt_sel_r; reg nv_st_r;
wire nv_gecerli_w, nv_rdy_w, nv_done_w, nv_err_w;
nokta_dogrula nv_inst (
    .clk_in(clk_in), .rst_n(rst_n),
    .i_pkt_in(nv_pkt_dat_r), .i_pkt_vld(nv_pkt_vld_r),
    .i_pkt_sel(nv_pkt_sel_r), .i_start(nv_st_r),
    .o_gecerli(nv_gecerli_w), .o_rdy(nv_rdy_w),
    .o_done(nv_done_w), .o_err(nv_err_w),
    .mo_pkt_dat(nv_mo_dat), .mo_pkt_vld(nv_mo_vld), .mo_pkt_sel(nv_mo_sel),
    .mo_opc(nv_mo_opc), .mo_st(nv_mo_st),
    .mi_pkt_out(mal_out_w), .mi_pkt_vld(mal_vld_w), .mi_pkt_last(mal_last_w),
    .mi_rdy(mal_rdy_w), .mi_done(mal_done_w), .mi_err(owner_nv ? mal_err_w : 1'b0),
    .g_b_mont(i_egri_b_mont)
);

// ═════════════════════════════════════════════════════════════════════════
//  FAZ 5 — ECDSA BIRIMLERI  (her biri TEK ornek, MALU/PAU paylasimli)
// ═════════════════════════════════════════════════════════════════════════
//   Uc modul de 3. adimda BAGLANDI ama henuz TETIKLENMIYOR: ECDSA akis
//   durumlari 4. adimda eklenecek. Girisleri sifir surulur — bagsiz
//   birakilsa z -> x yayilir ve mevcut ECDH yolunu da bozardi.

// ── mod_n_ters: hem imzalama (k^-1) hem dogrulama (s^-1) kullanir ───────
reg  [31:0] mnt_pkt_dat_r; reg mnt_pkt_vld_r; reg [1:0] mnt_pkt_sel_r; reg mnt_st_r;
// (mnt_* hatlari yukaridaki ileri bildirim blogunda tanimli)

// mod_n_ters SAHIPLIGI:
//   Su an tek istemcisi ecdsa_imza'dir; ileride ecdsa_dogrula (s^-1) da
//   kullanacak. Mux SIMDIDEN konuldu ki ikinci istemci eklendiginde
//   baglanti degil yalnizca kosul degissin.
//
//   *** BU MUX ILK YAZIMDA ATLANMISTI ***: ecdsa_imza'nin to_* cikislari
//   imz_to_* tellerine baglanmis ama oradan mod_n_ters'e HIC goturulmemisti.
//   Modul, ecdh_kex_top'un kullanilmayan sifir kayitcilariyla besleniyordu;
//   ters alma hic baslamiyor, ecdsa_imza 400.000 cevrimde watchdog'a
//   dusuyordu. Belirti "imza zaman asimi" idi, sebep ise eksik bir teldi.
wire mnt_sahip_imz = imza_modu_r;
wire mnt_sahip_dog = dog_modu_r;

mod_n_ters mnt_ortak (
    .clk_in(clk_in), .rst_n(rst_n),
    .i_pkt_in (mnt_sahip_imz ? imz_to_dat : mnt_sahip_dog ? dog_to_dat : mnt_pkt_dat_r),
    .i_pkt_vld(mnt_sahip_imz ? imz_to_vld : mnt_sahip_dog ? dog_to_vld : mnt_pkt_vld_r),
    .i_pkt_sel(mnt_sahip_imz ? imz_to_sel : mnt_sahip_dog ? dog_to_sel : mnt_pkt_sel_r),
    .i_start  (mnt_sahip_imz ? imz_to_st  : mnt_sahip_dog ? dog_to_st  : mnt_st_r),
    .o_pkt_out(mnt_pkt_out_w), .o_pkt_vld(mnt_pkt_vld_w),
    .o_pkt_last(mnt_pkt_last_w), .o_rdy(mnt_rdy_w),
    .o_done(mnt_done_w), .o_err(mnt_err_w),
    .mo_pkt_dat(mnt_mo_dat), .mo_pkt_vld(mnt_mo_vld), .mo_pkt_sel(mnt_mo_sel),
    .mo_opc(mnt_mo_opc), .mo_st(mnt_mo_st),
    .mi_pkt_out(mal_out_w), .mi_pkt_vld(mal_vld_w), .mi_pkt_last(mal_last_w),
    .mi_rdy(mal_rdy_w), .mi_done(mal_done_w),
    .mi_err(owner_mnt ? mal_err_w : 1'b0),
    .g_n_order(N_ORDER), .g_mont_bir_n(i_egri_mont_bir_n)
);

// ── ecdsa_imza: s = k^-1 (e + r*d) mod n ────────────────────────────────
reg  [31:0] imz_pkt_dat_r; reg imz_pkt_vld_r; reg [2:0] imz_pkt_sel_r; reg imz_st_r;
wire [31:0] imz_pkt_out_w; wire imz_pkt_vld_w, imz_pkt_sel_w, imz_pkt_last_w;
wire        imz_rdy_w, imz_done_w, imz_err_w;
wire        imz_r0_w, imz_s0_w, imz_kgec_w;
// (imz_mo_* / imz_to_* hatlari yukaridaki ileri bildirim blogunda tanimli)

ecdsa_imza imza_inst (
    .clk_in(clk_in), .rst_n(rst_n),
    .i_pkt_in(imz_pkt_dat_r), .i_pkt_vld(imz_pkt_vld_r),
    .i_pkt_sel(imz_pkt_sel_r), .i_start(imz_st_r),
    .o_pkt_out(imz_pkt_out_w), .o_pkt_vld(imz_pkt_vld_w),
    .o_pkt_sel(imz_pkt_sel_w), .o_pkt_last(imz_pkt_last_w),
    .o_rdy(imz_rdy_w), .o_done(imz_done_w), .o_err(imz_err_w),
    .o_r_sifir(imz_r0_w), .o_s_sifir(imz_s0_w), .o_k_gecersiz(imz_kgec_w),
    .to_pkt_dat(imz_to_dat), .to_pkt_vld(imz_to_vld),
    .to_pkt_sel(imz_to_sel), .to_st(imz_to_st),
    .ti_pkt_out(mnt_pkt_out_w), .ti_pkt_vld(mnt_pkt_vld_w),
    .ti_rdy(mnt_rdy_w), .ti_done(mnt_done_w), .ti_err(mnt_err_w),
    .mo_pkt_dat(imz_mo_dat), .mo_pkt_vld(imz_mo_vld), .mo_pkt_sel(imz_mo_sel),
    .mo_opc(imz_mo_opc), .mo_st(imz_mo_st),
    .mi_pkt_out(mal_out_w), .mi_pkt_vld(mal_vld_w), .mi_pkt_last(mal_last_w),
    .mi_rdy(mal_rdy_w), .mi_done(mal_done_w),
    .mi_err(owner_imz ? mal_err_w : 1'b0),
    .g_n_order(N_ORDER), .g_r2n(i_egri_r2n)
);

// ── ecdsa_dogrula: w=s^-1, u1, u2, v==r hukmu ──────────────────────────
reg  [31:0] dog_pkt_dat_r; reg dog_pkt_vld_r; reg [2:0] dog_pkt_sel_r;
reg         dog_st_r, dog_huk_r;
wire [31:0] dog_pkt_out_w; wire dog_pkt_vld_w, dog_pkt_sel_w, dog_pkt_last_w;
wire        dog_rdy_w, dog_done_w, dog_err_w, dog_gecerli_w, dog_aralik_w;
// (dog_mo_* / dog_to_* hatlari yukaridaki ileri bildirim blogunda tanimli)

assign o_dog_bitti        = dog_bitti_r;
assign o_z_duz            = z_duz_r;
assign o_z_gecerli        = z_gecerli_r;
assign o_imza_gecerli     = dog_gecerli_w;
assign o_imza_aralik_hata = dog_aralik_w;

ecdsa_dogrula dogrula_inst (
    .clk_in(clk_in), .rst_n(rst_n),
    .i_pkt_in(dog_pkt_dat_r), .i_pkt_vld(dog_pkt_vld_r),
    .i_pkt_sel(dog_pkt_sel_r),
    .i_start(dog_st_r), .i_hukum(dog_huk_r),
    .o_pkt_out(dog_pkt_out_w), .o_pkt_vld(dog_pkt_vld_w),
    .o_pkt_sel(dog_pkt_sel_w), .o_pkt_last(dog_pkt_last_w),
    .o_rdy(dog_rdy_w), .o_done(dog_done_w), .o_err(dog_err_w),
    .o_gecerli(dog_gecerli_w), .o_aralik_hata(dog_aralik_w),
    .to_pkt_dat(dog_to_dat), .to_pkt_vld(dog_to_vld),
    .to_pkt_sel(dog_to_sel), .to_st(dog_to_st),
    .ti_pkt_out(mnt_pkt_out_w), .ti_pkt_vld(mnt_pkt_vld_w),
    .ti_rdy(mnt_rdy_w), .ti_done(mnt_done_w), .ti_err(mnt_err_w),
    .mo_pkt_dat(dog_mo_dat), .mo_pkt_vld(dog_mo_vld), .mo_pkt_sel(dog_mo_sel),
    .mo_opc(dog_mo_opc), .mo_st(dog_mo_st),
    .mi_pkt_out(mal_out_w), .mi_pkt_vld(mal_vld_w), .mi_pkt_last(mal_last_w),
    .mi_rdy(mal_rdy_w), .mi_done(mal_done_w),
    .mi_err(owner_dog ? mal_err_w : 1'b0),
    .g_r2n(i_egri_r2n)
);

// ── cift_skaler_carpim: R = u1*G + u2*Q  (PAU'nun 2. istemcisi) ────────
reg  [31:0] csc_pkt_dat_r; reg csc_pkt_vld_r; reg [2:0] csc_pkt_sel_r; reg csc_st_r;
wire [31:0] csc_pkt_out_w; wire csc_pkt_vld_w, csc_pkt_last_w;
wire [1:0]  csc_pkt_sel_w;
wire        csc_rdy_w, csc_done_w, csc_err_w, csc_sonsuz_w;
// (csc_po_* hatlari yukaridaki ileri bildirim blogunda tanimli)

cift_skaler_carpim csc_inst (
    .clk_in(clk_in), .rst_n(rst_n),
    .i_pkt_in(csc_pkt_dat_r), .i_pkt_vld(csc_pkt_vld_r),
    .i_pkt_sel(csc_pkt_sel_r), .i_start(csc_st_r),
    .o_pkt_out(csc_pkt_out_w), .o_pkt_vld(csc_pkt_vld_w),
    .o_pkt_sel(csc_pkt_sel_w), .o_pkt_last(csc_pkt_last_w),
    .o_rdy(csc_rdy_w), .o_done(csc_done_w), .o_err(csc_err_w),
    .o_sonsuz(csc_sonsuz_w),
    .po_pkt_dat(csc_po_dat), .po_pkt_vld(csc_po_vld), .po_pkt_sel(csc_po_sel),
    .po_cmd(csc_po_cmd), .po_st(csc_po_st),
    .pi_pkt_out(pau_out_w), .pi_pkt_vld(pau_vld_w), .pi_pkt_sel(pau_sel_w),
    .pi_pkt_last(pau_last_w), .pi_rdy(pau_rdy_w), .pi_done(pau_done_w),
    .pi_err(owner_csc ? pau_err_w : 1'b0),
    .g_r_mod_p(R_MOD_P), .g_gx_mont(GX_MONT), .g_gy_mont(GY_MONT)
);


always @(posedge clk_in or negedge rst_n) begin
    if (!rst_n) begin
        state_r<=K_IDLE;
        o_pkt_out_r<=32'd0; o_pkt_vld_r<=1'b0; o_pkt_sel_r<=2'd0; o_pkt_last_r<=1'b0;
        o_stage_r<=STAGE_NONE; o_qa_done_r<=1'b0; o_rdy_r<=1'b0; o_done_r<=1'b0; o_err_r<=1'b0;
        sm_pkt_vld_r<=1'b0; sm_pkt_dat_r<=32'd0; sm_pkt_sel_r<=3'd0; sm_st_r<=1'b0;
        aff_pkt_vld_r<=1'b0; aff_pkt_dat_r<=32'd0; aff_pkt_sel_r<=3'd0; aff_st_r<=1'b0;
        sm_b_kaynak_r<=1'b0;
        rj_x_r<=256'd0; rj_y_r<=256'd0; rj_z_r<=256'd0;
        fa_x_r<=256'd0; fa_y_r<=256'd0; qb_x_r<=256'd0; qb_y_r<=256'd0;
        sm_cnt_r<=3'd0; aff_cnt_r<=3'd0; tx_cnt_r<=3'd0; qb_cnt_r<=3'd0; qb_sel_r<=3'd7;
        sm_ret_r<=7'd0; aff_ret_r<=7'd0; rx_ret_r<=7'd0; sm_wdog_r<=24'd0; aff_wdog_r<=20'd0;
        nv_pkt_vld_r<=1'b0; nv_pkt_dat_r<=32'd0; nv_pkt_sel_r<=3'd0; nv_st_r<=1'b0;
        nv_cnt_r<=3'd0; nv_wdog_r<=20'd0;
        o_err_kod_r<=ERR_YOK;
        kd_uret_r<=1'b0; kd_acik_yaz_r<=1'b0; kd_kullanim_r<=2'd0;
        o_slot_hata_r<=1'b0; o_uret_hata_kod_r<=2'd0;
        // FAZ 5 dispatch kayitcilari — 4. adimda kullanilacak
        mnt_pkt_dat_r<=32'd0; mnt_pkt_vld_r<=1'b0; mnt_pkt_sel_r<=2'd0; mnt_st_r<=1'b0;
        imz_pkt_dat_r<=32'd0; imz_pkt_vld_r<=1'b0; imz_pkt_sel_r<=3'd0; imz_st_r<=1'b0;
        csc_pkt_dat_r<=32'd0; csc_pkt_vld_r<=1'b0; csc_pkt_sel_r<=3'd0; csc_st_r<=1'b0;
        imza_modu_r<=1'b0; uret_modu_r<=1'b0; ic_slot_gecerli_r<=1'b0; ic_slot_r<=2'd0;
        hash_r<=256'd0; hash_cnt_r<=3'd0;
        d_imza_r<=256'd0; k_imza_r<=256'd0; rx_imza_r<=256'd0;
        z_duz_r<=256'd0; z_gecerli_r<=1'b0; dog_bitti_r<=1'b0;
        imza_r_r<=256'd0; imza_s_r<=256'd0;
        im_cnt_r<=3'd0; im_wdog_r<=20'd0;
        o_imza_hazir_r<=1'b0; o_imza_sel_r<=1'b0; o_imza_tekrar_r<=1'b0;
        kex_mo_dat_r<=32'd0; kex_mo_vld_r<=1'b0; kex_mo_st_r<=1'b0;
        kex_mo_sel_r<=2'd0; kex_mo_opc_r<=2'd0; kex_wdog_r<=12'd0;
        dog_modu_r<=1'b0; r_dog_r<=256'd0; s_dog_r<=256'd0;
        u1_r<=256'd0; u2_r<=256'd0; dg_cnt_r<=3'd0; dg_koord_r<=2'd0;
        dg_wdog_r<=23'd0; rx_ret_r<=7'd0;
        dog_pkt_dat_r<=32'd0; dog_pkt_vld_r<=1'b0; dog_pkt_sel_r<=3'd0;
        dog_st_r<=1'b0; dog_huk_r<=1'b0;
    end else begin
        o_pkt_vld_r<=1'b0; o_pkt_last_r<=1'b0; o_done_r<=1'b0; o_err_r<=1'b0; o_qa_done_r<=1'b0;
        sm_st_r<=1'b0; sm_pkt_vld_r<=1'b0; aff_st_r<=1'b0; aff_pkt_vld_r<=1'b0;
        nv_st_r<=1'b0; nv_pkt_vld_r<=1'b0;
        kd_uret_r<=1'b0; kd_acik_yaz_r<=1'b0; o_slot_hata_r<=1'b0;
        o_imza_hazir_r<=1'b0;
        kex_mo_vld_r<=1'b0; kex_mo_st_r<=1'b0;
        dog_pkt_vld_r<=1'b0; dog_st_r<=1'b0; dog_huk_r<=1'b0;

        // Hash (e) paketleri her zaman yakalanir — imza baslamadan once
        // yuklenebilsin diye. 8 paket, LSB-once.
        if (i_hash_vld) begin
            hash_r[hash_cnt_r*32 +: 32] <= i_hash_pkt;
            hash_cnt_r <= hash_cnt_r + 3'd1;
        end
        dog_bitti_r<=1'b0;
        mnt_pkt_vld_r<=1'b0; mnt_st_r<=1'b0;
        imz_pkt_vld_r<=1'b0; imz_st_r<=1'b0;
        csc_pkt_vld_r<=1'b0; csc_st_r<=1'b0;

        // ── ALT MODUL ARIZASI — TEK NOKTADAN YAKALAMA ────────────────────
        //   Onceki surumde yalnizca SM / affine / nokta_dogrula izleniyordu.
        //   ECDSA istemcileri (imza, dogrulama, cift skaler carpim) listede
        //   yoktu; onlarin bir MALU/PAU arizasi hicbir yerde goze carpmaz,
        //   akis yalnizca watchdog dolana kadar (~4 M cevrim) asili kalirdi.
        //   Hata NEDENI de kaybolur, ERR_WDOG olarak raporlanirdi.
        //
        //   Bu modullerin o_err cikislari 1 CEVRIMLIK DARBEDIR (her cevrim
        //   varsayilan 0'a cekilirler), bu yuzden durumdan bagimsiz bir
        //   izleme yanlis tetiklenmez.
        if (sm_err_w || aff_err_w || nv_err_w ||
            imz_err_w || dog_err_w || csc_err_w) begin
            o_err_r<=1'b1; o_err_kod_r<=ERR_CEKIRD;
            o_rdy_r<=1'b1; state_r<=K_IDLE;
        end else begin
        case (state_r)

            K_IDLE: begin
                o_rdy_r<=1'b1; o_stage_r<=STAGE_NONE;

                // ── BOSTA OPERAND YUKLEME (Ister ECDSA-VER) ───────────────
                //   ECDSA DOGRULAMA, ECDH oturumu ACMADAN calisir: ne anahtar
                //   uretilir ne de K_QB_WAIT'e ugranir. Dolayisiyla Q, r ve s
                //   icin K_QB_WAIT'ten BASKA bir yukleme kapisi gerekir.
                //
                //   Bu eksik, dogrulama akisi bugune kadar HIC kosmadigi icin
                //   fark edilmemisti: i_dogrula K_IDLE'dan dogrudan
                //   K_DG_DMODN'e atliyor ve qb_x_r/r_dog_r/s_dog_r reset
                //   degerleriyle (sifir) hesaba giriyordu. Hicbir hata bayragi
                //   kalkmaz; imza sadece "gecersiz" cikardi.
                //
                //   GUVENLIK: burada YALNIZCA acik veriler yazilir (Q, r, s).
                //   Ozel anahtara giden bir yol YOKTUR; d yalnizca
                //   anahtar_deposu icinde uretilir ve orada kalir.
                if (i_pkt_vld) begin
                    case (i_pkt_sel)
                        3'd0: qb_x_r [qb_idx_w*32 +: 32]<=i_pkt_in;
                        3'd1: qb_y_r [qb_idx_w*32 +: 32]<=i_pkt_in;
                        3'd2: r_dog_r[qb_idx_w*32 +: 32]<=i_pkt_in;
                        3'd3: s_dog_r[qb_idx_w*32 +: 32]<=i_pkt_in;
                        default: ;
                    endcase
                    qb_sel_r<=i_pkt_sel;
                    qb_cnt_r<=qb_idx_w+3'd1;
                end

                // i_start artik "ANAHTAR URET + Qa hesapla" anlamina gelir.
                // Entropi toplama ve d in [1,n-1] kontrolu anahtar_deposu'nda.
                if (i_start) begin
                    o_rdy_r<=1'b0; imza_modu_r<=1'b0; uret_modu_r<=1'b0;
                    dog_modu_r<=1'b0;
                    ic_slot_gecerli_r<=1'b0;      // slot disaridan
                    // BAYAT Z SIZMASINI ONLE: yeni oturum baslar baslamaz
                    // eski ortak sir gecersiz sayilir. Aksi halde ECDH
                    // yarida kesilse (hata / zeroize) o_z_gecerli yuksek
                    // kalir ve KDF ONCEKI oturumun sirriyla anahtar turetir.
                    z_gecerli_r<=1'b0;
                    state_r<=K_UR_ISTE;
                end
                // Yalnizca anahtar uret, ECDH oturumu ACMA.
                else if (i_uret) begin
                    o_rdy_r<=1'b0; imza_modu_r<=1'b0; uret_modu_r<=1'b1;
                    ic_slot_gecerli_r<=1'b0;
                    state_r<=K_UR_ISTE;
                end
                // ── ECDSA IMZALA ──────────────────────────────────────
                //   Once NONCE_SLOT'a gecici anahtar (k) urettirilir; ayni
                //   yol k*G'yi de hesaplar. Politika 0 verilir: nonce slotu
                //   hicbir izne sahip olmaz, ECDH icin kullanilamaz.
                // ── ECDSA DOGRULA ────────────────────────────────────
                //   Q, Qb yoluyla zaten yuklu; r ve s i_pkt_sel=2/3 ile,
                //   e ise i_hash_* ile gelir.
                else if (i_dogrula) begin
                    o_rdy_r<=1'b0; dog_modu_r<=1'b1;
                    imza_modu_r<=1'b0; uret_modu_r<=1'b0;
                    dg_cnt_r<=3'd0; hash_cnt_r<=3'd0;
                    state_r<=K_DG_DMODN;
                end
                else if (i_imzala) begin
                    o_rdy_r<=1'b0; imza_modu_r<=1'b1; uret_modu_r<=1'b0;
                    dog_modu_r<=1'b0;
                    o_imza_tekrar_r<=1'b0;
                    ic_slot_gecerli_r<=1'b1;
                    ic_slot_r<=NONCE_SLOT;
                    hash_cnt_r<=3'd0;
                    state_r<=K_UR_ISTE;
                end
            end

            // ── FAZ 4: slota anahtar urettir ──────────────────────────────
            K_UR_ISTE: begin
                kd_uret_r <= 1'b1;
                state_r   <= K_UR_BEK;
            end

            K_UR_BEK: begin
                if (kd_uret_hata_w) begin
                    // Uretim reddedildi: kalici slot yeniden uretilemez,
                    // ayrilmis politika biti, ya da 8 denemede gecerli skaler
                    // bulunamadi. Hangisi oldugu o_uret_hata_kod ile bildirilir.
                    o_err_r<=1'b1; o_err_kod_r<=ERR_SLOT;
                    o_slot_hata_r<=1'b1; o_uret_hata_kod_r<=kd_uret_hata_kod_w;
                    o_rdy_r<=1'b1; state_r<=K_IDLE;
                end else if (kd_uret_bitti_w) begin
                    state_r <= K_QA_SETUP;
                end
            end

            K_QA_SETUP: begin
                sm_b_kaynak_r<=1'b0;   // G sabiti
                sm_ret_r<=K_QA_AFF_SETUP; sm_cnt_r<=3'd0; state_r<=K_SM_DMODP;
            end

            // [DUZELTME] N4 regresyonu — Qa KORUNUMU (imzalamadan etkilenmemeli)
            //   kd_acik_yaz_r<=!imza_modu_r duzeltmesi (Temmuz 2026) yalnizca
            //   anahtar_deposu'nun SLOT DEPOLAMASINI korur. Ama K_QA_TX_X/TX_Y
            //   nonce'un acik noktasini (k*G) da KOSULSUZCA STAGE_QA olarak
            //   yayinliyordu — komut_yoneticisi.v:576 STAGE_QA etiketli HER
            //   paketi (kim urettigine bakmadan) qa_tampon_r'a (QA_OKU
            //   onbellegi) yaziyor. Sonuc: slotun kendisi bozulmasa da, UART
            //   uzerinden okunan Qa her IMZALA sonrasi nonce'un noktasiyla
            //   degisiyordu (TB-27 N4e). Cozum: imza_modu_r'da STAGE_QA
            //   yayinini HIC yapma — K_QA_TX_X/TX_Y'yi atlayip dogrudan
            //   K_QA_DONE'a gec. Nonce'un x'i zaten imza r'sinde ayrica disari
            //   cikiyor; QA_OKU kanalinda tekrar gorunmesine gerek yok.
            K_QA_AFF_SETUP: begin
                aff_ret_r<=(imza_modu_r ? K_QA_DONE : K_QA_TX_X);
                aff_cnt_r<=3'd0; state_r<=K_AF_DMODP;
            end

            K_QA_TX_X: begin
                o_stage_r<=STAGE_QA; o_pkt_vld_r<=1'b1; o_pkt_sel_r<=2'b00;
                o_pkt_out_r<=fa_x_r[tx_cnt_r*32 +: 32]; o_pkt_last_r<=(tx_cnt_r==3'd7);
                if (tx_cnt_r==3'd7) begin tx_cnt_r<=3'd0; state_r<=K_QA_TX_Y; end else tx_cnt_r<=tx_cnt_r+3'd1;
            end
            K_QA_TX_Y: begin
                o_stage_r<=STAGE_QA; o_pkt_vld_r<=1'b1; o_pkt_sel_r<=2'b01;
                o_pkt_out_r<=fa_y_r[tx_cnt_r*32 +: 32]; o_pkt_last_r<=(tx_cnt_r==3'd7);
                if (tx_cnt_r==3'd7) begin tx_cnt_r<=3'd0; state_r<=K_QA_DONE; end else tx_cnt_r<=tx_cnt_r+3'd1;
            end

            // Qa hesaplandi: slota GERI YAZ ki ACIK_ANAHTAR_OKU 34 ms'lik
            // hesabi tekrarlamak zorunda kalmasin.
            K_QA_DONE: begin
                // *** IMZA MODUNDA ACIK ANAHTAR YAZILMAZ ***
                //   Bu durumda fa_x/fa_y, NONCE'un acik noktasidir (k.G) —
                //   saklanmasi gerekmez, r zaten fa_x_r'den turetilir.
                //   Daha kotusu: kd_acik_yaz_r ile ayni cevrimde ic_slot_r
                //   imza slotuna cekiliyor. Yazma bir sonraki cevrimde
                //   gerceklestigi icin k.G, IMZA ANAHTARININ slotuna
                //   yaziliyor ve o slotun gercek acik anahtari (Qa = d.G)
                //   sessizce eziliyordu. Sonraki ACIK_ANAHTAR_OKU / QA_OKU
                //   yanlis nokta dondurur; sertifika ile anahtar arasindaki
                //   bag kopar ve bunu kimse fark etmez.
                kd_acik_yaz_r<=!imza_modu_r;
                if (imza_modu_r) begin
                    // fa_x_r su anda (k*G).x — imzanin r'si buradan turer
                    // fa_x_r = (k*G).x MONTGOMERY alaninda. Once DUZE cevir.
                    ic_slot_r <= i_slot;          // imza anahtari slotuna gec
                    kd_kullanim_r <= 2'b10;       // IZIN_IMZA sorgusu
                    im_cnt_r  <= 3'd0;
                    rx_ret_r  <= K_IM_D_OKU;
                    state_r   <= K_IM_RX_TXA;
                end else if (uret_modu_r) begin
                    // Sadece uretim: Qa slota yazildi, islem BITTI.
                    o_qa_done_r<=1'b1; state_r<=K_UR_DONE;
                end else begin
                    o_qa_done_r<=1'b1; o_rdy_r<=1'b1; qb_cnt_r<=3'd0;
                    state_r<=K_QB_WAIT;
                end
            end

            // ── FAZ 5: ECDSA IMZALAMA ─────────────────────────────────────
            //   Ozel anahtar ve nonce anahtar deposundan okunur. Ikisi de
            //   BU MODULUN ICINDE kalir; komut katmanina veya UART'a giden
            //   hicbir yol yoktur.
            // ── Rx: MM_p(Rx~, 1) = Rx  (MALU'da p yuklu) ─────────────────
            K_IM_RX_TXA: begin
                kex_mo_vld_r<=1'b1; kex_mo_sel_r<=2'b00;   // SEL_A
                kex_mo_opc_r<=2'b10;                        // MontMult
                kex_mo_dat_r<=fa_x_r[im_cnt_r*32 +: 32];
                if (im_cnt_r==3'd7) begin im_cnt_r<=3'd0; state_r<=K_IM_RX_TXB; end
                else im_cnt_r<=im_cnt_r+3'd1;
            end
            K_IM_RX_TXB: begin
                kex_mo_vld_r<=1'b1; kex_mo_sel_r<=2'b01;   // SEL_B = 1
                kex_mo_dat_r<=(im_cnt_r==3'd0) ? 32'd1 : 32'd0;
                if (im_cnt_r==3'd7) begin im_cnt_r<=3'd0; state_r<=K_IM_RX_GO; end
                else im_cnt_r<=im_cnt_r+3'd1;
            end
            K_IM_RX_GO: begin
                kex_mo_st_r<=1'b1; kex_mo_opc_r<=2'b10;
                kex_wdog_r<=12'd0; im_cnt_r<=3'd0; state_r<=K_IM_RX_WT;
            end
            K_IM_RX_WT: begin
                if (kex_wdog_r>=KEX_WDOG_MAX) begin
                    o_err_r<=1'b1; o_err_kod_r<=ERR_WDOG; o_rdy_r<=1'b1;
                    imza_modu_r<=1'b0; state_r<=K_IDLE;
                end else if (mal_vld_w) begin
                    rx_imza_r<={mal_out_w,rx_imza_r[255:32]}; im_cnt_r<=3'd1;
                    state_r<=K_IM_RX_RX;
                end else kex_wdog_r<=kex_wdog_r+12'd1;
            end
            K_IM_RX_RX: begin
                if (mal_vld_w) begin
                    rx_imza_r<={mal_out_w,rx_imza_r[255:32]};
                    if (im_cnt_r==3'd7) begin im_cnt_r<=3'd0; state_r<=rx_ret_r; end
                    else im_cnt_r<=im_cnt_r+3'd1;
                end
            end

            K_IM_D_OKU: begin
                // ic_slot_r bir onceki cevrimde i_slot'a ayarlandi; deponun
                // kombinasyonel cikisi artik imza anahtarini gosteriyor.
                if (!kd_ozel_gecerli_w) begin
                    o_err_r<=1'b1; o_err_kod_r<=ERR_SLOT; o_slot_hata_r<=1'b1;
                    o_rdy_r<=1'b1; imza_modu_r<=1'b0; state_r<=K_IDLE;
                end
                // Slot politikasi IMZA'ya izin vermiyorsa ozel anahtar HIC
                // okunmaz. ECDH yolundaki K_IZIN ile ayni ilke: yetkisiz
                // kullanim, veriye dokunulmadan reddedilir.
                else if (!kd_izin_var_w) begin
                    o_err_r<=1'b1; o_err_kod_r<=ERR_IZIN; o_slot_hata_r<=1'b1;
                    o_rdy_r<=1'b1; imza_modu_r<=1'b0; state_r<=K_IDLE;
                end else begin
                    d_imza_r  <= kd_ozel_d_w;
                    ic_slot_r <= NONCE_SLOT;      // nonce slotuna geri don
                    state_r   <= K_IM_K_OKU;
                end
            end

            K_IM_K_OKU: begin
                k_imza_r <= kd_ozel_d_w;          // nonce
                im_cnt_r <= 3'd0;
                state_r  <= K_IM_DMODN;
            end

            // ── ecdsa_imza'ya operand yukleme (5 x 8 paket) ───────────────
            K_IM_DMODN: begin
                imz_pkt_vld_r<=1'b1; imz_pkt_sel_r<=3'd0;
                imz_pkt_dat_r<=N_ORDER[im_cnt_r*32 +: 32];
                if (im_cnt_r==3'd7) begin im_cnt_r<=3'd0; state_r<=K_IM_DE; end
                else im_cnt_r<=im_cnt_r+3'd1;
            end
            K_IM_DE: begin
                imz_pkt_vld_r<=1'b1; imz_pkt_sel_r<=3'd1;
                imz_pkt_dat_r<=hash_r[im_cnt_r*32 +: 32];
                if (im_cnt_r==3'd7) begin im_cnt_r<=3'd0; state_r<=K_IM_DRX; end
                else im_cnt_r<=im_cnt_r+3'd1;
            end
            K_IM_DRX: begin
                imz_pkt_vld_r<=1'b1; imz_pkt_sel_r<=3'd2;
                imz_pkt_dat_r<=rx_imza_r[31:0]; rx_imza_r<={rx_imza_r[31:0],rx_imza_r[255:32]};
                if (im_cnt_r==3'd7) begin im_cnt_r<=3'd0; state_r<=K_IM_DD; end
                else im_cnt_r<=im_cnt_r+3'd1;
            end
            K_IM_DD: begin
                imz_pkt_vld_r<=1'b1; imz_pkt_sel_r<=3'd3;
                imz_pkt_dat_r<=d_imza_r[im_cnt_r*32 +: 32];
                if (im_cnt_r==3'd7) begin im_cnt_r<=3'd0; state_r<=K_IM_DK; end
                else im_cnt_r<=im_cnt_r+3'd1;
            end
            K_IM_DK: begin
                imz_pkt_vld_r<=1'b1; imz_pkt_sel_r<=3'd4;
                imz_pkt_dat_r<=k_imza_r[im_cnt_r*32 +: 32];
                if (im_cnt_r==3'd7) begin im_cnt_r<=3'd0; state_r<=K_IM_GO; end
                else im_cnt_r<=im_cnt_r+3'd1;
            end

            K_IM_GO: begin
                imz_st_r<=1'b1; im_wdog_r<=20'd0; im_cnt_r<=3'd0;
                state_r<=K_IM_BEK;
            end

            K_IM_BEK: begin
                // (r,s) akiyor: r once (sel=0), sonra s (sel=1)
                if (imz_pkt_vld_w) begin
                    if (!imz_pkt_sel_w) imza_r_r <= {imz_pkt_out_w, imza_r_r[255:32]};
                    else                imza_s_r <= {imz_pkt_out_w, imza_s_r[255:32]};
                    im_cnt_r <= im_cnt_r + 3'd1;
                end
                if (im_wdog_r>=IM_WDOG_MAX) begin
                    o_err_r<=1'b1; o_err_kod_r<=ERR_WDOG; o_rdy_r<=1'b1;
                    imza_modu_r<=1'b0; state_r<=K_IDLE;
                end else if (imz_done_w) begin
                    // FIPS 186-4 6.4: r=0 / s=0 / gecersiz nonce -> YENIDEN
                    // dene. Bunlar ariza DEGIL; cagiran yeni imza istemeli.
                    if (imz_r0_w || imz_s0_w || imz_kgec_w) begin
                        o_imza_tekrar_r<=1'b1; o_rdy_r<=1'b1;
                        imza_modu_r<=1'b0; ic_slot_gecerli_r<=1'b0;
                        state_r<=K_IDLE;
                    end else begin
                        tx_cnt_r<=3'd0; state_r<=K_IM_TX_R;
                    end
                end else im_wdog_r<=im_wdog_r+20'd1;
            end

            K_IM_TX_R: begin
                o_imza_hazir_r<=1'b1; o_imza_sel_r<=1'b0;
                o_pkt_vld_r<=1'b1; o_pkt_sel_r<=2'b00;
                o_pkt_out_r<=imza_r_r[31:0]; imza_r_r<={imza_r_r[31:0],imza_r_r[255:32]};
                o_pkt_last_r<=(tx_cnt_r==3'd7);
                if (tx_cnt_r==3'd7) begin tx_cnt_r<=3'd0; state_r<=K_IM_TX_S; end
                else tx_cnt_r<=tx_cnt_r+3'd1;
            end
            K_IM_TX_S: begin
                o_imza_hazir_r<=1'b1; o_imza_sel_r<=1'b1;
                o_pkt_vld_r<=1'b1; o_pkt_sel_r<=2'b01;
                o_pkt_out_r<=imza_s_r[31:0]; imza_s_r<={imza_s_r[31:0],imza_s_r[255:32]};
                o_pkt_last_r<=(tx_cnt_r==3'd7);
                if (tx_cnt_r==3'd7) begin tx_cnt_r<=3'd0; state_r<=K_IM_DONE; end
                else tx_cnt_r<=tx_cnt_r+3'd1;
            end

            // ══ FAZ 5c: ECDSA DOGRULAMA AKISI ════════════════════════════
            //   AS.1 operandlari: mod_n, e, r, s
            K_DG_DMODN: begin
                dog_pkt_vld_r<=1'b1; dog_pkt_sel_r<=3'd0;
                dog_pkt_dat_r<=N_ORDER[dg_cnt_r*32 +: 32];
                if (dg_cnt_r==3'd7) begin dg_cnt_r<=3'd0; state_r<=K_DG_DE; end
                else dg_cnt_r<=dg_cnt_r+3'd1;
            end
            K_DG_DE: begin
                dog_pkt_vld_r<=1'b1; dog_pkt_sel_r<=3'd1;
                dog_pkt_dat_r<=hash_r[dg_cnt_r*32 +: 32];
                if (dg_cnt_r==3'd7) begin dg_cnt_r<=3'd0; state_r<=K_DG_DR; end
                else dg_cnt_r<=dg_cnt_r+3'd1;
            end
            K_DG_DR: begin
                dog_pkt_vld_r<=1'b1; dog_pkt_sel_r<=3'd2;
                dog_pkt_dat_r<=r_dog_r[dg_cnt_r*32 +: 32];
                if (dg_cnt_r==3'd7) begin dg_cnt_r<=3'd0; state_r<=K_DG_DS; end
                else dg_cnt_r<=dg_cnt_r+3'd1;
            end
            K_DG_DS: begin
                dog_pkt_vld_r<=1'b1; dog_pkt_sel_r<=3'd3;
                dog_pkt_dat_r<=s_dog_r[dg_cnt_r*32 +: 32];
                if (dg_cnt_r==3'd7) begin dg_cnt_r<=3'd0; state_r<=K_DG_GO; end
                else dg_cnt_r<=dg_cnt_r+3'd1;
            end
            K_DG_GO: begin
                dog_st_r<=1'b1; dg_wdog_r<=23'd0; dg_cnt_r<=3'd0;
                state_r<=K_DG_BEK;
            end
            K_DG_BEK: begin
                if (dog_pkt_vld_w) begin
                    if (!dog_pkt_sel_w) u1_r <= {dog_pkt_out_w, u1_r[255:32]};
                    else                u2_r <= {dog_pkt_out_w, u2_r[255:32]};
                    dg_cnt_r<=dg_cnt_r+3'd1;
                end
                if (dg_wdog_r>=DG_WDOG_MAX) begin
                    o_err_r<=1'b1; o_err_kod_r<=ERR_WDOG; o_rdy_r<=1'b1;
                    dog_modu_r<=1'b0; state_r<=K_IDLE;
                end else if (dog_done_w) begin
                    // Aralik hatasi: imza gecersiz, hesaba devam ETME.
                    if (dog_aralik_w) begin
                        o_done_r<=1'b1; o_rdy_r<=1'b1; dog_bitti_r<=1'b1;
                        dog_modu_r<=1'b0; state_r<=K_IDLE;
                    end else begin dg_cnt_r<=3'd0; state_r<=K_DG_CMODP; end
                end else dg_wdog_r<=dg_wdog_r+23'd1;
            end

            // ── cift_skaler_carpim: R = u1*G + u2*Q ─────────────────────
            K_DG_CMODP: begin
                csc_pkt_vld_r<=1'b1; csc_pkt_sel_r<=3'd0;
                csc_pkt_dat_r<=P256[dg_cnt_r*32 +: 32];
                if (dg_cnt_r==3'd7) begin dg_cnt_r<=3'd0; state_r<=K_DG_CU1; end
                else dg_cnt_r<=dg_cnt_r+3'd1;
            end
            K_DG_CU1: begin
                csc_pkt_vld_r<=1'b1; csc_pkt_sel_r<=3'd1;
                csc_pkt_dat_r<=u1_r[31:0]; u1_r<={u1_r[31:0],u1_r[255:32]};
                if (dg_cnt_r==3'd7) begin dg_cnt_r<=3'd0; state_r<=K_DG_CU2; end
                else dg_cnt_r<=dg_cnt_r+3'd1;
            end
            K_DG_CU2: begin
                csc_pkt_vld_r<=1'b1; csc_pkt_sel_r<=3'd2;
                csc_pkt_dat_r<=u2_r[31:0]; u2_r<={u2_r[31:0],u2_r[255:32]};
                if (dg_cnt_r==3'd7) begin dg_cnt_r<=3'd0; state_r<=K_DG_CQX; end
                else dg_cnt_r<=dg_cnt_r+3'd1;
            end
            K_DG_CQX: begin
                csc_pkt_vld_r<=1'b1; csc_pkt_sel_r<=3'd3;
                csc_pkt_dat_r<=qb_x_r[dg_cnt_r*32 +: 32];
                if (dg_cnt_r==3'd7) begin dg_cnt_r<=3'd0; state_r<=K_DG_CQY; end
                else dg_cnt_r<=dg_cnt_r+3'd1;
            end
            K_DG_CQY: begin
                csc_pkt_vld_r<=1'b1; csc_pkt_sel_r<=3'd4;
                csc_pkt_dat_r<=qb_y_r[dg_cnt_r*32 +: 32];
                if (dg_cnt_r==3'd7) begin dg_cnt_r<=3'd0; state_r<=K_DG_CGO; end
                else dg_cnt_r<=dg_cnt_r+3'd1;
            end
            K_DG_CGO: begin
                csc_st_r<=1'b1; dg_wdog_r<=23'd0;
                dg_cnt_r<=3'd0; dg_koord_r<=2'd0;
                state_r<=K_DG_CBEK;
            end
            K_DG_CBEK: begin
                // Jacobian R (X,Y,Z) toplanir -> affine girdisi
                if (csc_pkt_vld_w) begin
                    case (csc_pkt_sel_w)
                        2'b00: rj_x_r <= {csc_pkt_out_w, rj_x_r[255:32]};
                        2'b01: rj_y_r <= {csc_pkt_out_w, rj_y_r[255:32]};
                        default: rj_z_r <= {csc_pkt_out_w, rj_z_r[255:32]};
                    endcase
                    dg_cnt_r<=dg_cnt_r+3'd1;
                end
                if (dg_wdog_r>=DG_WDOG_MAX) begin
                    o_err_r<=1'b1; o_err_kod_r<=ERR_WDOG; o_rdy_r<=1'b1;
                    dog_modu_r<=1'b0; state_r<=K_IDLE;
                end else if (csc_done_w) begin
                    // Sonsuzluk -> imza gecersiz (hukum verilmez)
                    if (csc_sonsuz_w) begin
                        o_done_r<=1'b1; o_rdy_r<=1'b1; dog_bitti_r<=1'b1;
                        dog_modu_r<=1'b0; state_r<=K_IDLE;
                    end else state_r<=K_DG_AFF;
                end else dg_wdog_r<=dg_wdog_r+23'd1;
            end

            // MEVCUT affine makinesini yeniden kullan
            K_DG_AFF: begin
                aff_ret_r<=K_DG_RXP; aff_cnt_r<=3'd0; state_r<=K_AF_DMODP;
            end

            // MEVCUT Rx donusum makinesini yeniden kullan
            K_DG_RXP: begin
                im_cnt_r<=3'd0; rx_ret_r<=K_DG_DRX; state_r<=K_IM_RX_TXA;
            end

            K_DG_DRX: begin
                dog_pkt_vld_r<=1'b1; dog_pkt_sel_r<=3'd4;   // Rx (duz)
                dog_pkt_dat_r<=rx_imza_r[31:0]; rx_imza_r<={rx_imza_r[31:0],rx_imza_r[255:32]};
                if (dg_cnt_r==3'd7) begin dg_cnt_r<=3'd0; state_r<=K_DG_HUK; end
                else dg_cnt_r<=dg_cnt_r+3'd1;
            end
            K_DG_HUK: begin
                dog_huk_r<=1'b1; dg_wdog_r<=23'd0; state_r<=K_DG_HBEK;
            end
            K_DG_HBEK: begin
                if (dg_wdog_r>=DG_WDOG_MAX) begin
                    o_err_r<=1'b1; o_err_kod_r<=ERR_WDOG; o_rdy_r<=1'b1;
                    dog_modu_r<=1'b0; state_r<=K_IDLE;
                end else if (dog_done_w) state_r<=K_DG_DONE;
                else dg_wdog_r<=dg_wdog_r+23'd1;
            end
            K_DG_DONE: begin
                o_done_r<=1'b1; o_rdy_r<=1'b1; dog_bitti_r<=1'b1;
                dog_modu_r<=1'b0; state_r<=K_IDLE;
            end

            K_UR_DONE: begin
                o_done_r<=1'b1; o_rdy_r<=1'b1; uret_modu_r<=1'b0;
                state_r<=K_IDLE;
            end

            K_IM_DONE: begin
                o_done_r<=1'b1; o_rdy_r<=1'b1;
                imza_modu_r<=1'b0; ic_slot_gecerli_r<=1'b0;
                state_r<=K_IDLE;
            end

            K_QB_WAIT: begin
                o_rdy_r<=1'b1;
                if (i_pkt_vld) begin
                    case (i_pkt_sel)
                        3'd0: qb_x_r [qb_idx_w*32 +: 32]<=i_pkt_in;
                        3'd1: qb_y_r [qb_idx_w*32 +: 32]<=i_pkt_in;
                        3'd2: r_dog_r[qb_idx_w*32 +: 32]<=i_pkt_in;  // dogrulama
                        3'd3: s_dog_r[qb_idx_w*32 +: 32]<=i_pkt_in;
                        default: ;
                    endcase
                    qb_sel_r<=i_pkt_sel;
                    qb_cnt_r<=qb_idx_w+3'd1;
                end
                if (i_qb_start) begin o_rdy_r<=1'b0; kd_kullanim_r<=2'b01; state_r<=K_IZIN; end
            end

            // ── FAZ 4: SLOT IZIN KONTROLU ─────────────────────────────────
            //   Politika ECDH'ye izin vermiyorsa d ile HIC carpma yapilmaz.
            //   Bu kontrol nokta dogrulamasindan ONCE gelir: yetkisiz bir
            //   slota erisim denemesi, gonderilen noktanin gecerliligiyle
            //   ilgisiz bir sekilde reddedilmelidir.
            K_IZIN: begin
                if (!kd_ozel_gecerli_w) begin
                    o_err_r<=1'b1; o_err_kod_r<=ERR_SLOT; o_slot_hata_r<=1'b1;
                    o_rdy_r<=1'b1; state_r<=K_IDLE;
                end else if (!kd_izin_var_w) begin
                    o_err_r<=1'b1; o_err_kod_r<=ERR_IZIN; o_slot_hata_r<=1'b1;
                    o_rdy_r<=1'b1; state_r<=K_IDLE;
                end else begin
                    state_r<=K_QB_VALIDATE;
                end
            end

            // ── Qb TAM AÇIK-ANAHTAR DOĞRULAMASI (İster SEC-01) ────────────
            //   Önceki sürüm yalnızca (x==0 && y==0) sonsuzluk gösterimini
            //   eliyordu. Bu YETERSİZDİ: eğri üstünde olmayan bir Qb, Jacobian
            //   formülleri eğri sabiti b'yi kullanmadığı için sessizce işlenir
            //   ve sonuç d hakkında bilgi sızdırır (invalid-curve saldırısı).
            //
            //   Artık nokta_dogrula'ya devredilir: aralık (x<p, y<p) VE eğri
            //   denklemi (y² = x³ − 3x + b) sınanır. Sonsuzluk kontrolü de bu
            //   denklem tarafından KAPSANIR (0 != b), bu yüzden ayrı testi
            //   kaldırıldı — iki yerde tutulan bir kural, bir gün yalnız birinde
            //   güncellenir.
            K_QB_VALIDATE: begin
                nv_cnt_r<=3'd0; state_r<=K_NV_DMODP;
            end

            // ── Doğrulama dispatch: mod_p, Qb.x, Qb.y → nokta_dogrula ──────
            K_NV_DMODP: begin
                nv_pkt_vld_r<=1'b1; nv_pkt_dat_r<=P256[nv_cnt_r*32 +: 32]; nv_pkt_sel_r<=3'd0;
                if (nv_cnt_r==3'd7) begin nv_cnt_r<=3'd0; state_r<=K_NV_DX; end
                else nv_cnt_r<=nv_cnt_r+3'd1;
            end
            K_NV_DX: begin
                nv_pkt_vld_r<=1'b1; nv_pkt_dat_r<=qb_x_r[nv_cnt_r*32 +: 32]; nv_pkt_sel_r<=3'd1;
                if (nv_cnt_r==3'd7) begin nv_cnt_r<=3'd0; state_r<=K_NV_DY; end
                else nv_cnt_r<=nv_cnt_r+3'd1;
            end
            K_NV_DY: begin
                nv_pkt_vld_r<=1'b1; nv_pkt_dat_r<=qb_y_r[nv_cnt_r*32 +: 32]; nv_pkt_sel_r<=3'd2;
                if (nv_cnt_r==3'd7) begin nv_cnt_r<=3'd0; state_r<=K_NV_DGO; end
                else nv_cnt_r<=nv_cnt_r+3'd1;
            end
            K_NV_DGO: begin nv_st_r<=1'b1; nv_wdog_r<=20'd0; state_r<=K_NV_DWAIT; end

            K_NV_DWAIT: begin
                if (nv_wdog_r>=NV_WDOG_MAX) begin
                    o_err_r<=1'b1; o_err_kod_r<=ERR_WDOG; o_rdy_r<=1'b1; state_r<=K_IDLE;
                end else if (nv_done_w) begin
                    if (nv_gecerli_w) begin
                        // Nokta geçerli → skaler çarpıma devam
                        sm_b_kaynak_r<=1'b1;   // Qb
                        sm_ret_r<=K_SS_AFF_SETUP; sm_cnt_r<=3'd0; state_r<=K_SM_DMODP;
                    end else begin
                        // Nokta geçersiz → d ile ASLA çarpma. Protokol hatası.
                        o_err_r<=1'b1; o_err_kod_r<=ERR_NOKTA;
                        o_rdy_r<=1'b1; state_r<=K_IDLE;
                    end
                end else nv_wdog_r<=nv_wdog_r+20'd1;
            end

            K_SS_AFF_SETUP: begin
                aff_ret_r<=K_SS_TX_X; aff_cnt_r<=3'd0; state_r<=K_AF_DMODP;
            end

            K_SS_TX_X: begin
                o_stage_r<=STAGE_SS; o_pkt_vld_r<=1'b1; o_pkt_sel_r<=2'b00;
                o_pkt_out_r<=fa_x_r[tx_cnt_r*32 +: 32]; o_pkt_last_r<=(tx_cnt_r==3'd7);
                if (tx_cnt_r==3'd7) begin tx_cnt_r<=3'd0; state_r<=K_SS_TX_Y; end else tx_cnt_r<=tx_cnt_r+3'd1;
            end
            K_SS_TX_Y: begin
                o_stage_r<=STAGE_SS; o_pkt_vld_r<=1'b1; o_pkt_sel_r<=2'b01;
                o_pkt_out_r<=fa_y_r[tx_cnt_r*32 +: 32]; o_pkt_last_r<=(tx_cnt_r==3'd7);
                if (tx_cnt_r==3'd7) begin tx_cnt_r<=3'd0; state_r<=K_SS_ZP; end else tx_cnt_r<=tx_cnt_r+3'd1;
            end

            // ══ ENTEGRASYON DIKISI: Z (KDF girdisi) ═════════════════════
            //   Ortak sir UART'a MONTGOMERY alaninda basiliyor (fa_x_r).
            //   Bir KDF'ye verilecek deger ise DUZ olmak ZORUNDADIR:
            //
            //     NIST SP 800-56A Rev.3 §5.7.1.2 — ECC CDH ilkelinin ciktisi
            //     Z, paylasilan noktanin x KOORDINATIDIR ve tam sayi olarak
            //     (Montgomery gosterimi degil) fixed-length byte string'e
            //     cevrilip KDF'ye verilir.
            //
            //   Bu donusum atlanip Montgomery degeri HKDF'ye verilseydi:
            //   iki taraf yine AYNI degeri uretirdi (ikisi de ayni donanim),
            //   anahtarlar tutar, testler gecerdi. Hata ancak KARSI TARAF
            //   BASKA BIR UYGULAMA oldugunda ortaya cikardi — yani sahada,
            //   birlikte calisabilirlik testinde. Sessiz ve gec bulunan bir
            //   hata sinifi; bu yuzden donusum burada, kaynakta yapiliyor.
            //
            //   Y koordinati KASITLI OLARAK disari verilmez: SP 800-56A Z'yi
            //   yalnizca x olarak tanimlar. Y'yi de vermek, arkadaslarin
            //   yanlislikla onu da KDF'ye katmasina davetiye olurdu.
            //
            //   Maliyet: tek bir MontMult, ~290 cevrim. Mevcut Rx donusum
            //   makinesi (K_IM_RX_*) aynen yeniden kullaniliyor; o makine
            //   zaten fa_x_r'yi okuyor, ek kayitci gerekmedi.
            K_SS_ZP: begin
                im_cnt_r<=3'd0; rx_ret_r<=K_SS_ZAL; state_r<=K_IM_RX_TXA;
            end
            K_SS_ZAL: begin
                z_duz_r<=rx_imza_r; z_gecerli_r<=1'b1; state_r<=K_SS_DONE;
            end

            K_SS_DONE: begin o_done_r<=1'b1; o_rdy_r<=1'b1; state_r<=K_IDLE; end

            // ── SM dispatch ────────────────────────────────────────────
            K_SM_DMODP: begin sm_pkt_vld_r<=1'b1; sm_pkt_dat_r<=P256[sm_cnt_r*32 +: 32]; sm_pkt_sel_r<=SIX_MODP;
                if (sm_cnt_r==3'd7) begin sm_cnt_r<=3'd0; state_r<=K_SM_DSCLR; end else sm_cnt_r<=sm_cnt_r+3'd1; end
            K_SM_DSCLR: begin sm_pkt_vld_r<=1'b1; sm_pkt_dat_r<=kd_ozel_d_w[sm_cnt_r*32 +: 32]; sm_pkt_sel_r<=SIX_SCALAR;
                if (sm_cnt_r==3'd7) begin sm_cnt_r<=3'd0; state_r<=K_SM_DBX; end else sm_cnt_r<=sm_cnt_r+3'd1; end
            // [DÜZELTME] bx/by/bz_src_r kaldırıldı — sm_bx_w/sm_by_w mux'u
            // (G sabiti | Qb) ve bz için doğrudan R_MOD_P kullanılıyor
            // (GZ_MONT = R_MOD_P olduğu için iki dalda da zaten aynıydı).
            K_SM_DBX: begin sm_pkt_vld_r<=1'b1; sm_pkt_dat_r<=sm_bx_w[sm_cnt_r*32 +: 32]; sm_pkt_sel_r<=SIX_BX;
                if (sm_cnt_r==3'd7) begin sm_cnt_r<=3'd0; state_r<=K_SM_DBY; end else sm_cnt_r<=sm_cnt_r+3'd1; end
            K_SM_DBY: begin sm_pkt_vld_r<=1'b1; sm_pkt_dat_r<=sm_by_w[sm_cnt_r*32 +: 32]; sm_pkt_sel_r<=SIX_BY;
                if (sm_cnt_r==3'd7) begin sm_cnt_r<=3'd0; state_r<=K_SM_DBZ; end else sm_cnt_r<=sm_cnt_r+3'd1; end
            K_SM_DBZ: begin sm_pkt_vld_r<=1'b1; sm_pkt_dat_r<=R_MOD_P[sm_cnt_r*32 +: 32]; sm_pkt_sel_r<=SIX_BZ;
                if (sm_cnt_r==3'd7) begin sm_cnt_r<=3'd0; state_r<=K_SM_DGO; end else sm_cnt_r<=sm_cnt_r+3'd1; end
            K_SM_DGO: begin sm_st_r<=1'b1; sm_wdog_r<=24'd0; state_r<=K_SM_DWAIT_X; end
            K_SM_DWAIT_X: begin
                if (sm_wdog_r>=SM_WDOG_MAX) begin o_err_r<=1'b1; o_err_kod_r<=ERR_WDOG; o_rdy_r<=1'b1; state_r<=K_IDLE; end
                else if (sm_pkt_vld_w && sm_pkt_sel_w==2'b00) begin rj_x_r<={sm_pkt_out_w,rj_x_r[255:32]}; sm_cnt_r<=3'd1; state_r<=K_SM_DRX_X; end
                else sm_wdog_r<=sm_wdog_r+24'd1;
            end
            K_SM_DRX_X: begin if (sm_pkt_vld_w && sm_pkt_sel_w==2'b00) begin rj_x_r<={sm_pkt_out_w,rj_x_r[255:32]};
                if (sm_cnt_r==3'd7) begin sm_cnt_r<=3'd0; state_r<=K_SM_DRX_Y; end else sm_cnt_r<=sm_cnt_r+3'd1; end end
            K_SM_DRX_Y: begin if (sm_pkt_vld_w && sm_pkt_sel_w==2'b01) begin rj_y_r<={sm_pkt_out_w,rj_y_r[255:32]};
                if (sm_cnt_r==3'd7) begin sm_cnt_r<=3'd0; state_r<=K_SM_DRX_Z; end else sm_cnt_r<=sm_cnt_r+3'd1; end end
            K_SM_DRX_Z: begin if (sm_pkt_vld_w && sm_pkt_sel_w==2'b10) begin rj_z_r<={sm_pkt_out_w,rj_z_r[255:32]};
                if (sm_cnt_r==3'd7) begin sm_cnt_r<=3'd0; state_r<=sm_ret_r; end else sm_cnt_r<=sm_cnt_r+3'd1; end end

            // ── Affine dispatch ────────────────────────────────────────
            K_AF_DMODP: begin aff_pkt_vld_r<=1'b1; aff_pkt_dat_r<=P256[aff_cnt_r*32 +: 32]; aff_pkt_sel_r<=AIX_MODP;
                if (aff_cnt_r==3'd7) begin aff_cnt_r<=3'd0; state_r<=K_AF_DX; end else aff_cnt_r<=aff_cnt_r+3'd1; end
            // [DÜZELTME] ax/ay/az_src_r kaldırıldı — doğrudan rj_x/y/z_r okunuyor
            // (aralarında hiçbir yazma olmadığı için değeri birebir aynı).
            K_AF_DX: begin aff_pkt_vld_r<=1'b1; aff_pkt_dat_r<=rj_x_r[31:0]; rj_x_r<={rj_x_r[31:0],rj_x_r[255:32]}; aff_pkt_sel_r<=AIX_X;
                if (aff_cnt_r==3'd7) begin aff_cnt_r<=3'd0; state_r<=K_AF_DY; end else aff_cnt_r<=aff_cnt_r+3'd1; end
            K_AF_DY: begin aff_pkt_vld_r<=1'b1; aff_pkt_dat_r<=rj_y_r[31:0]; rj_y_r<={rj_y_r[31:0],rj_y_r[255:32]}; aff_pkt_sel_r<=AIX_Y;
                if (aff_cnt_r==3'd7) begin aff_cnt_r<=3'd0; state_r<=K_AF_DZ; end else aff_cnt_r<=aff_cnt_r+3'd1; end
            K_AF_DZ: begin aff_pkt_vld_r<=1'b1; aff_pkt_dat_r<=rj_z_r[31:0]; rj_z_r<={rj_z_r[31:0],rj_z_r[255:32]}; aff_pkt_sel_r<=AIX_Z;
                if (aff_cnt_r==3'd7) begin aff_cnt_r<=3'd0; state_r<=K_AF_DGO; end else aff_cnt_r<=aff_cnt_r+3'd1; end
            K_AF_DGO: begin aff_st_r<=1'b1; aff_wdog_r<=20'd0; state_r<=K_AF_DWAIT_X; end
            K_AF_DWAIT_X: begin
                if (aff_wdog_r>=AFF_WDOG_MAX) begin o_err_r<=1'b1; o_err_kod_r<=ERR_WDOG; o_rdy_r<=1'b1; state_r<=K_IDLE; end
                else if (aff_pkt_vld_w && aff_pkt_sel_w==2'b00) begin fa_x_r[0 +: 32]<=aff_pkt_out_w; aff_cnt_r<=3'd1; state_r<=K_AF_DRX_X; end
                else aff_wdog_r<=aff_wdog_r+20'd1;
            end
            K_AF_DRX_X: begin if (aff_pkt_vld_w && aff_pkt_sel_w==2'b00) begin fa_x_r[aff_cnt_r*32 +: 32]<=aff_pkt_out_w;
                if (aff_cnt_r==3'd7) begin aff_cnt_r<=3'd0; state_r<=K_AF_DRX_Y; end else aff_cnt_r<=aff_cnt_r+3'd1; end end
            K_AF_DRX_Y: begin if (aff_pkt_vld_w && aff_pkt_sel_w==2'b01) begin fa_y_r[aff_cnt_r*32 +: 32]<=aff_pkt_out_w;
                if (aff_cnt_r==3'd7) begin aff_cnt_r<=3'd0; tx_cnt_r<=3'd0; state_r<=aff_ret_r; end else aff_cnt_r<=aff_cnt_r+3'd1; end end

            default: state_r <= K_IDLE;
        endcase
        end
    end
end

endmodule
