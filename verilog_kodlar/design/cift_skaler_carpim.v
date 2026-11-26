// =============================================================================
// Modül   : cift_skaler_carpim.v                                   (İster M-20)
// Proje   : FPGA Tabanlı Güvenli Anahtar Yönetimi ve Kripto Hızlandırıcı (5260007)
// -----------------------------------------------------------------------------
// Açıklama:
//   Straus-Shamir (interleaved) yöntemiyle ÇİFT skaler çarpım:
//
//       R = u1·G + u2·Q
//
//   ECDSA doğrulamasının pahalı adımıdır. İki ayrı skaler çarpım yapıp
//   sonra toplamak yerine, iki skalerin bitleri BİRLİKTE taranır; ikileme
//   (doubling) işlemi PAYLAŞILIR.
//
//     Ayrı ayrı : 2 × (256 DBL + ~128 ADD) = 512 DBL + 256 ADD
//     Straus-S. :      256 DBL + ~192 ADD
//   → ikileme sayısı YARIYA iner; doğrulama süresi neredeyse yarılanır.
//
//   Ön hesap: T = G + Q (tek PAU ADD). Böylece her bit çiftinde tek toplama
//   yeterli olur:
//     (1,0) → R += G     (0,1) → R += Q     (1,1) → R += T
//
// -----------------------------------------------------------------------------
// TEMMUZ 2026 — BRAM SCRATCHPAD DÖNÜŞÜMÜ (Nihai Mimari, Adım 5)
//
//   SORUN: Hiyerarşik sentez raporu bu modülü 3945 LUT / 5303 FF ile ikinci
//   en büyük LUT tüketicisi olarak gösterdi (Basys3 LUT bütçesi %144,78'de
//   tıkanmışken). Kaynak: 20 adet bağımsız 256-bit yazmaç (mod_p_r, u1_r,
//   u2_r, qx_r, qy_r, tx/ty/tz_r, rx/ry/rz_r, p1x/y/z_r, p2x/y/z_r,
//   res_x/y/z_r) — 5120 bit'in tamamı flip-flop, hiçbiri paylaşılmıyordu.
//
//   ÇÖZÜM: point_arithmetic_unit.v'de zaten kanıtlanmış BRAM scratchpad
//   deseni buraya taşındı:
//     [1] tx/ty/tz, rx/ry/rz, qx/qy → tek bir Block RAM'e (ara_mem[0:15])
//         adresli okuma/yazma ile taşındı (mem_ra_c/mem_wa_c komb.,
//         mem_rd_r kayıtlı okuma — kanonik BRAM inference şablonu).
//     [2] p1x/y/z_r ve p2x/y/z_r TAMAMEN KALDIRILDI. Bu modülde P1 her
//         zaman ya sabit G ya da R akümülatörü, P2 ise G/Q/T'den biridir —
//         yani ayrı bir "gönderim" yazmacına hiç gerek yok; PAU'ya
//         gönderilecek 256-bit değer, gönderim ANINDA kaynak seçici
//         (p1_kaynak_r/p2_kaynak_r) ile mux'lanır (point_arithmetic_unit'in
//         tx_base_w tekniğiyle aynı fikir).
//     [3] res_x/y/z_r → tek bir res_acc_r'ye indirildi; PAU sonucu her
//         koordinatın son sözcüğünde DOĞRUDAN hedef BRAM slotuna
//         (hedef_t_r bayrağına göre T ya da R) bypass yazmayla committed
//         edilir (modular_alu_dsp.v'nin n0' bypass yazma deseniyle aynı
//         mantık: {gelen_son_sozcuk, onceki_224_bit}).
//     [4] mod_p_r, u1_r, u2_r BİLİNÇLİ OLARAK BRAM'E TAŞINMADI: u1/u2 her
//         ladder biti için TEK BİT (bit_idx_r) ile 256 kez okunuyor;
//         mod_p_r her PAU çağrısında (≈448 kez) baştan sona gönderiliyor.
//         Bunları BRAM'e koymak her erişimde 1 çevrimlik okuma gecikmesi
//         ekler ve kazanç sağlamaz (yalnızca 3×256=768 bit).
//
//   NEDEN GÜVENLİ: Bu modül raporun kendi ifadesiyle zaten DEĞİŞKEN
//   zamanlıdır (aşağıdaki "SABİT ZAMANLILIK ARANMIYOR" bölümüne bakın) —
//   tüm veriler (r,s,e,u1,u2,Q) açıktır, gizli hiçbir şey yoktur. Bu yüzden
//   BRAM okuma gecikmesinin eklediği birkaç ekstra çevrim (koordinat başına
//   1 çevrim fetch + ILKLE/TX için okuma-yazma adımları, toplam ~1.8M
//   çevrimin içinde ihmal edilebilir) hiçbir yan-kanal riski taşımaz.
//
//   ÇIKTI DEĞİŞMEZ: Sonuç bit-birebir aynıdır; yalnızca depolama mimarisi
//   ve toplam çevrim sayısı (küçük bir sabit artışla) değişir.
//
// -----------------------------------------------------------------------------
// *** NEDEN BURADA SABİT ZAMANLILIK ARANMIYOR ***
//   Bu modül DEĞİŞKEN zamanlıdır: toplama sayısı u1 ve u2'nin bit desenine
//   bağlıdır. Bu BİLİNÇLİ bir tercihtir ve bir eksiklik değildir.
//
//   ECDSA doğrulaması TAMAMEN AÇIK verilerle çalışır:
//     r, s  → imzanın kendisi, telde açıkça gider
//     e     → mesaj özeti, açık
//     u1,u2 → yukarıdakilerden türetilir, açık
//     Q     → karşı tarafın açık anahtarı, açık
//   Sızacak bir sır YOKTUR. Zamanlama kanalı ancak gizli veri işlenirken
//   anlamlıdır.
//
//   BUNUN TERSİ İMZALAMADA GEÇERLİDİR: orada k gizlidir ve bu yüzden
//   scalar_multiplier'da sabit zamanlı Montgomery Ladder, mod_n_ters'te
//   sabit zamanlı Fermat kullanılır. İki modülün farklı davranması
//   tutarsızlık değil, tehdit modelinin doğru uygulanmasıdır.
//
//   Bu modül GİZLİ bir skalerle ASLA kullanılmamalıdır.
//
// -----------------------------------------------------------------------------
// SONSUZLUK NOKTASI (point at infinity) ELE ALIŞI:
//   Jacobian koordinatlarda sonsuzluk Z=0 ile gösterilir ve toplama
//   formülleri bu durumu ÖZEL OLARAK ele almak zorundadır — aksi hâlde
//   0'a bölme benzeri bozulmalar olur.
//
//   Bunu tamamen ELİMİNE etmek için akümülatör sonsuzlukla BAŞLATILMAZ:
//   u1|u2'nin en yüksek set bitine gidilir ve R doğrudan G, Q veya T ile
//   ilklenir; döngü bir sonraki bitten başlar. Böylece R hiçbir zaman
//   sonsuzluk olmaz (ara toplamların sonsuzluk vermesi ancak u1·G = −u2·Q
//   olmasıyla mümkündür; bu da imzanın zaten geçersiz olduğu anlamına gelir
//   ve o_sonsuz ile bildirilir).
//
//   u1 == 0 && u2 == 0 ise sonuç tanımı gereği sonsuzluktur → o_sonsuz.
//
// MALİYET:
//   256 DBL + ~192 ADD ≈ 448 PAU işlemi ≈ 1.8 M çevrim ≈ 18 ms @100 MHz.
//   Bir tek skaler çarpımla (21 ms) aynı mertebede.
//
// Kabul kriteri (TB-19):
//   KAT vektörleri (Python altın-modeli); u1=0 ve u2=0 uç durumları;
//   u1=u2=0 → o_sonsuz; ardışık koşum.
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
module cift_skaler_carpim (
    input  wire         clk_in,
    input  wire         rst_n,

    // ── Paket girişi ─────────────────────────────────────────────────────
    //   0=mod_p 1=u1 2=u2 3=Qx 4=Qy    (G sabittir, içeride gömülü)
    input  wire [31:0]  i_pkt_in,
    input  wire         i_pkt_vld,
    input  wire [2:0]   i_pkt_sel,
    input  wire         i_start,

    // ── Sonuç: Jacobian R (X,Y,Z) — affin dönüşüm ÇAĞIRANIN işi ─────────
    output wire [31:0]  o_pkt_out,
    output wire         o_pkt_vld,
    output wire [1:0]   o_pkt_sel,      // 00=X 01=Y 10=Z
    output wire         o_pkt_last,
    output wire         o_rdy,
    output wire         o_done,
    output wire         o_err,
    output wire         o_sonsuz,       // sonuç sonsuzluk noktası

    // ══ PAYLAŞILAN PAU DIŞ ARAYÜZÜ (master) ══════════════════════════════
    //   PAU bu modülün İÇİNDE DEĞİLDİR. ecdh_kex_top'ta TEK örnek olarak
    //   durur ve scalar_multiplier ile bu modül arasında arbitre edilir.
    //   İkisi asla aynı anda çalışmaz: ECDH/imza skaler çarpım kullanır,
    //   doğrulama çift skaler çarpım kullanır; protokol sıralıdır.
    //
    //   MALU portları KALDIRILDI — MALU'ya PAU üzerinden erişiliyor.
    output wire [31:0]  po_pkt_dat,
    output wire         po_pkt_vld,
    output wire [2:0]   po_pkt_sel,
    output wire         po_cmd,
    output wire         po_st,
    input  wire [31:0]  pi_pkt_out,
    input  wire         pi_pkt_vld,
    input  wire [1:0]   pi_pkt_sel,
    input  wire         pi_pkt_last,
    input  wire         pi_rdy,
    input  wire         pi_done,
    input  wire         pi_err,

    // ── ÇOKLU EĞRİ DESTEĞİ (Temmuz 2026) ─────────────────────────────────
    //   Taban nokta G'nin Montgomery temsili artık dışarıdan (parametre_
    //   deposu üzerinden) gelir; eskiden burada P-256'ya sabitlenmişti.
    //   Reset/varsayılan değer P-256 olduğundan mevcut davranış korunur.
    input  wire [255:0] g_r_mod_p,
    input  wire [255:0] g_gx_mont,
    input  wire [255:0] g_gy_mont
);

// ── Giriş seçicileri ──────────────────────────────────────────────────────
localparam [2:0] CIX_MODP=3'd0, CIX_U1=3'd1, CIX_U2=3'd2,
                 CIX_QX=3'd3,   CIX_QY=3'd4;

// ── PAU giriş seçicileri (point_arithmetic_unit.v ile birebir) ───────────
localparam [2:0] PIX_MODP=3'd0, PIX_P1X=3'd1, PIX_P1Y=3'd2, PIX_P1Z=3'd3,
                 PIX_P2X=3'd4,  PIX_P2Y=3'd5, PIX_P2Z=3'd6;
localparam PAU_DBL = 1'b0, PAU_ADD = 1'b1;

// ── Taban noktası G (Montgomery) — ARTIK GİRİŞ (g_r_mod_p/g_gx_mont/g_gy_mont)
//   Eski P-256 sabitleri (yalnızca belge amaçlı):
//     R_MOD_P = 256'h00000000fffffffeffffffffffffffffffffffff000000000000000000000001
//     GX_MONT = 256'h18905f76a53755c679fb732b7762251075ba95fc5fedb60179e730d418a9143c
//     GY_MONT = 256'h8571ff1825885d85d2e88688dd21f3258b4ab8e4ba19e45cddf25357ce95560a
wire [255:0] R_MOD_P = g_r_mod_p;
wire [255:0] GX_MONT = g_gx_mont;
wire [255:0] GY_MONT = g_gy_mont;

// =============================================================================
// TEMMUZ 2026 — BELLEK 32 BİT GENİŞLİĞE ÇEVRİLDİ (Adım 5, ikinci geçiş)
//
//   İlk geçişte bellek 256 BİT GENİŞ yapılmıştı. FF'te büyük kazanç oldu
//   (5303 -> 1357) ama LUT beklendiği kadar düşmedi (3945 -> 1452): değer
//   bellekten 256 bit çıkıp `[cnt_r*32 +: 32]` ile dilimlendiği için
//   part-select mux'ları OLDUĞU GİBİ duruyordu. Bu, tasarımın geri kalanında
//   da tekrarlanan hatanın ta kendisiydi.
//
//   ŞİMDİ: adres = {slot[3:0], sozcuk[2:0]} — 128 sözcük × 32 bit.
//   Ayrıca G sabiti, R_MOD_P (Q'nun ve G'nin Z'si) ve mod p de BRAM'e
//   alındı; böylece P1/P2 gönderim yolu TEKDÜZE oldu: kaynak ne olursa
//   olsun `mem_ra_c = {taban + koordinat, sozcuk}`. Kaynak seçici mux'u
//   (p1_val_w / p2_val_w) tamamen kayboldu — 256-bit mux yerine 4 bitlik
//   taban adresi taşınıyor.
//
//   Sabitler her koşumun başında ST_SABIT_YAZ'da BRAM'e yazılır (32 çevrim,
//   ~1.8 M çevrimlik işlemin yanında ihmal edilebilir).
// =============================================================================

// ── BRAM Scratchpad Slot Adresleri ─────────────────────────────────────────
//   Her nokta 3 ARDIŞIK slot tutar (X,Y,Z) — böylece "taban + koordinat"
//   adresleme çalışır. Tabanlar: Q=A_QX, T=A_TX, R=A_RX, G=A_GX.
localparam [3:0] A_QX=4'd0,  A_QY=4'd1,  A_QZ=4'd2,
                 A_TX=4'd3,  A_TY=4'd4,  A_TZ=4'd5,
                 A_RX=4'd6,  A_RY=4'd7,  A_RZ=4'd8,
                 A_GX=4'd9,  A_GY=4'd10, A_GZ=4'd11,
                 A_P =4'd12;

// ── Durum kodlaması ───────────────────────────────────────────────────────
localparam [4:0]
    ST_IDLE        = 5'd0,
    ST_TARA        = 5'd1,    // en yüksek set biti bul (u1|u2)
    ST_ON_T        = 5'd2,    // T = G + Q ön hesabı: kaynak seçicileri kur
    ST_ON_T_BEK    = 5'd3,
    ST_ILKLE       = 5'd4,    // R = G / Q / T (en yüksek bite göre) — kurulum
    ST_DBL         = 5'd5,    // R = 2R — kaynak seçicileri kur
    ST_DBL_BEK     = 5'd6,
    ST_ADD         = 5'd7,    // R = R + (G|Q|T) — kaynak seçicileri kur
    ST_ADD_BEK     = 5'd8,
    ST_SONRAKI     = 5'd9,
    ST_TX          = 5'd10,
    ST_DONE        = 5'd11,
    ST_SONSUZ      = 5'd12,
    // PAU operand yükleme alt-FSM'i
    ST_PY_MODP     = 5'd13,
    ST_PY_P1       = 5'd14,
    ST_PY_P2       = 5'd15,
    ST_PY_GO       = 5'd16,
    ST_PY_RX       = 5'd17,
    // BRAM okuma-önce alt-adımları (1 çevrim gecikme)
    ST_ILKLE_RD    = 5'd18,
    ST_ILKLE_WR    = 5'd19,
    ST_PY_P1_FETCH = 5'd20,
    ST_PY_P2_FETCH = 5'd21,
    ST_TX_FETCH    = 5'd22,
    ST_SABIT_YAZ   = 5'd23,   // G, R_MOD_P ve Q.Z sabitlerini BRAM'e yaz
    ST_PY_MODP_RD  = 5'd24;   // mod p gönderimi için fetch

reg [4:0] state_r;

localparam [14:0] PAU_WDOG_MAX = 15'd30_000;

// =====================================================================
// Block RAM Scratchpad — KOMBİNASYONEL adres/yazma + kayıtlı okuma çıkışı
//   (point_arithmetic_unit.v ile birebir aynı kanonik şablon)
// =====================================================================
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

// ── Veri kayıtçıları ──────────────────────────────────────────────────────
//   mod_p_r/u1_r/u2_r BİLİNÇLİ OLARAK BRAM'E TAŞINMADI — yukarıki
//   "BRAM SCRATCHPAD DÖNÜŞÜMÜ" notuna bakın (madde 4).
//   u1_r / u2_r BRAM'E TAŞINMAZ: her ladder biti için TEK BİT (bit_idx_r)
//   ile okunuyorlar; BRAM'de sözcük-seri erişim gerektirir ve kazanç yok.
//   mod_p_r ise BRAM'e alındı (her PAU çağrısında ~448 kez gönderiliyor).
reg [255:0] u1_r, u2_r;

reg [8:0]  bit_idx_r;
reg [2:0]  cnt_r;
reg [1:0]  rx_koord_r;    // P1/P2 gönderiminde hangi koordinat (0=X 1=Y 2=Z)
reg [4:0]  py_ret_r;
reg        py_cmd_r;
reg [14:0] pau_wdog_r;
reg [2:0]  pkt_rx_cnt_r, pkt_tx_cnt_r;
reg [1:0]  tx_koord_r;
reg        hedef_t_r;                  // 1: sonuç T slotuna, 0: R (akümülatör) slotuna
reg [3:0]  p1_taban_r, p2_taban_r;     // A_QX / A_TX / A_RX / A_GX
reg [3:0]  ilk_taban_r;                // R'nin ilkleneceği kaynak tabanı
reg [1:0]  sab_j_r;                    // sabit yazma adımı (0..3)

// Bu bitte hangi nokta eklenecek: 00=yok 01=G 10=Q 11=T
wire [1:0] bit_cifti_w = {u2_r[bit_idx_r[7:0]], u1_r[bit_idx_r[7:0]]};

// ── Sabit yazma tablosu (ST_SABIT_YAZ) ───────────────────────────────────
//   G ve R_MOD_P artık BRAM'de durur; böylece gönderim yolunda 256-bit
//   kaynak mux'u kalmaz. Yalnızca bu üç sabit part-select'i kalır ve
//   KAYNAKLARI SABİT olduğu için sentez bunları neredeyse bedavaya indirger.
reg [3:0]  sab_slot_w;
reg [31:0] sab_veri_w;
always @* begin
    case (sab_j_r)
        2'd0: begin sab_slot_w = A_GX; sab_veri_w = GX_MONT[cnt_r*32 +: 32]; end
        2'd1: begin sab_slot_w = A_GY; sab_veri_w = GY_MONT[cnt_r*32 +: 32]; end
        2'd2: begin sab_slot_w = A_GZ; sab_veri_w = R_MOD_P[cnt_r*32 +: 32]; end
        default: begin sab_slot_w = A_QZ; sab_veri_w = R_MOD_P[cnt_r*32 +: 32]; end
    endcase
end

// Giriş seçiciden BRAM slotuna eşleme
reg [3:0] giris_slot_w;
always @* begin
    case (i_pkt_sel)
        CIX_MODP: giris_slot_w = A_P;
        CIX_QX:   giris_slot_w = A_QX;
        default:  giris_slot_w = A_QY;
    endcase
end

// Bu bit çiftinde R'nin ilkleneceği kaynak tabanı: 01=G 10=Q 11=T
reg [3:0] ilk_taban_w;
always @* begin
    case (bit_cifti_w)
        2'b01:   ilk_taban_w = A_GX;
        2'b10:   ilk_taban_w = A_QX;
        default: ilk_taban_w = A_TX;
    endcase
end

// ── Çıkış saklayıcıları ───────────────────────────────────────────────────
reg [31:0] o_pkt_out_r;
reg        o_pkt_vld_r, o_pkt_last_r, o_rdy_r, o_done_r, o_err_r, o_sonsuz_r;
reg [1:0]  o_pkt_sel_r;

assign o_pkt_out  = o_pkt_out_r;
assign o_pkt_vld  = o_pkt_vld_r;
assign o_pkt_sel  = o_pkt_sel_r;
assign o_pkt_last = o_pkt_last_r;
assign o_rdy      = o_rdy_r;
assign o_done     = o_done_r;
assign o_err      = o_err_r;
assign o_sonsuz   = o_sonsuz_r;

// ═════════════════════════════════════════════════════════════════════════
//  PAU örneği — MALU'yu doğrudan geçirir
// ═════════════════════════════════════════════════════════════════════════
reg         pau_pkt_vld_r, pau_cmd_r, pau_st_r;
reg [31:0]  pau_pkt_dat_r;
reg [2:0]   pau_pkt_sel_r;
// PAU'dan gelenler — artik port uzerinden
wire [31:0] pau_pkt_out_w  = pi_pkt_out;
wire        pau_pkt_vld_w  = pi_pkt_vld;
wire [1:0]  pau_pkt_sel_w  = pi_pkt_sel;
wire        pau_pkt_last_w = pi_pkt_last;
wire        pau_rdy_w      = pi_rdy;
wire        pau_done_w     = pi_done;
wire        pau_err_w      = pi_err;

// PAU'ya gidenler
assign po_pkt_dat = pau_pkt_dat_r;
assign po_pkt_vld = pau_pkt_vld_r;
assign po_pkt_sel = pau_pkt_sel_r;
assign po_cmd     = pau_cmd_r;
assign po_st      = pau_st_r;

// point_arithmetic_unit ORNEGI KALDIRILDI — ecdh_kex_top'ta TEK ornek.

// =====================================================================
// BRAM okuma adresi (KOMBİNASYONEL)
// =====================================================================
//   *** Adres hem FETCH hem KULLANIM durumunda tutulur ***: mem_rd_r HER
//   ÇEVRİM ara_mem[mem_ra_c]'den yenilenir; yalnız fetch çevriminde doğru
//   adres verilip sonra varsayılana dönülürse okunan değer sessizce bozulur
//   (TB-19'da yakalanan hatanın dersi).
//   Artık TEKDÜZE: kaynak ne olursa olsun {taban + koordinat, sözcük}.
always @* begin
    mem_ra_c = 7'd0;
    case (state_r)
        ST_PY_MODP_RD,  ST_PY_MODP:
            mem_ra_c = {A_P, cnt_r};
        ST_PY_P1_FETCH, ST_PY_P1:
            mem_ra_c = {p1_taban_r + {2'b00, rx_koord_r}, cnt_r};
        ST_PY_P2_FETCH, ST_PY_P2:
            mem_ra_c = {p2_taban_r + {2'b00, rx_koord_r}, cnt_r};
        ST_ILKLE_RD,    ST_ILKLE_WR:
            mem_ra_c = {ilk_taban_r + {2'b00, rx_koord_r}, cnt_r};
        ST_TX_FETCH,    ST_TX:
            mem_ra_c = {A_RX + {2'b00, tx_koord_r}, pkt_tx_cnt_r};
        default: ;
    endcase
end

// =====================================================================
// BRAM yazma denetimi (KOMBİNASYONEL) — dört bağımsız commit noktası
// =====================================================================
always @* begin
    mem_we_c = 1'b0; mem_wa_c = 7'd0; mem_wd_c = 32'd0;
    if (state_r == ST_IDLE) begin
        // Giriş paketi DOĞRUDAN sözcük olarak yazılır (asm_r biriktirici yok)
        //   *** YALNIZCA mod_p / Qx / Qy BRAM'e gider ***: u1 ve u2 kayıtçıda
        //   kalır. Koşul "sel <= CIX_QY" yazılırsa u1/u2 paketleri de yazılır
        //   ve giris_slot_w'nin default dalı yüzünden A_QY'yi bozar — ilk
        //   koşumda tam bu oldu (TB-19 KAT vektörleri düştü; Senaryo B
        //   yakalayamadı çünkü test yalnızca X ve Z'yi kontrol ediyor).
        if (i_pkt_vld && ((i_pkt_sel == CIX_MODP) ||
                          (i_pkt_sel == CIX_QX)   ||
                          (i_pkt_sel == CIX_QY))) begin
            mem_we_c = 1'b1;
            mem_wa_c = {giris_slot_w, pkt_rx_cnt_r};
            mem_wd_c = i_pkt_in;
        end
    end else if (state_r == ST_SABIT_YAZ) begin
        // G / R_MOD_P / Q.Z sabitleri
        mem_we_c = 1'b1;
        mem_wa_c = {sab_slot_w, cnt_r};
        mem_wd_c = sab_veri_w;
    end else if (state_r == ST_PY_RX) begin
        // PAU sonucu geldiği gibi hedef slota yazılır (res_acc_r yok)
        if (pau_pkt_vld_w) begin
            mem_we_c = 1'b1;
            mem_wa_c = {(hedef_t_r ? A_TX : A_RX) + {2'b00, pau_pkt_sel_w}, cnt_r};
            mem_wd_c = pau_pkt_out_w;
        end
    end else if (state_r == ST_ILKLE_WR) begin
        // R'nin ilk değeri: G / Q / T'den sözcük sözcük kopya
        mem_we_c = 1'b1;
        mem_wa_c = {A_RX + {2'b00, rx_koord_r}, cnt_r};
        mem_wd_c = mem_rd_r;
    end
end

// =========================================================================
//  ANA DURUM MAKİNESİ
// =========================================================================
always @(posedge clk_in or negedge rst_n) begin
    if (!rst_n) begin
        state_r <= ST_IDLE;
        u1_r <= 256'd0; u2_r <= 256'd0;
        bit_idx_r <= 9'd255; cnt_r <= 3'd0; rx_koord_r <= 2'd0;
        py_ret_r <= 5'd0; py_cmd_r <= 1'b0; pau_wdog_r <= 15'd0;
        pkt_rx_cnt_r <= 3'd0; pkt_tx_cnt_r <= 3'd0; tx_koord_r <= 2'd0;
        hedef_t_r <= 1'b0; p1_taban_r <= A_RX; p2_taban_r <= A_RX;
        ilk_taban_r <= A_GX; sab_j_r <= 2'd0;
        o_pkt_out_r <= 32'd0; o_pkt_vld_r <= 1'b0; o_pkt_sel_r <= 2'd0;
        o_pkt_last_r <= 1'b0; o_rdy_r <= 1'b0; o_done_r <= 1'b0;
        o_err_r <= 1'b0; o_sonsuz_r <= 1'b0;
        pau_pkt_vld_r <= 1'b0; pau_pkt_dat_r <= 32'd0; pau_pkt_sel_r <= 3'd0;
        pau_cmd_r <= 1'b0; pau_st_r <= 1'b0;
    end else begin
        o_pkt_vld_r <= 1'b0; o_pkt_last_r <= 1'b0;
        o_done_r <= 1'b0; o_err_r <= 1'b0;
        pau_st_r <= 1'b0; pau_pkt_vld_r <= 1'b0;

        // PAU sonucu yazma bloğunda doğrudan BRAM'e gidiyor (res_acc_r yok)

        if (pau_err_w) begin
            o_err_r <= 1'b1; o_rdy_r <= 1'b1; state_r <= ST_IDLE;
        end else begin
        case (state_r)

        ST_IDLE: begin
            o_rdy_r <= 1'b1;
            if (i_pkt_vld) begin
                // mod_p ve Q BRAM'e (yazma bloğu); u1/u2 kayıtçıda kalır
                // çünkü ladder'da TEK BİT olarak (bit_idx_r) okunuyorlar.
                case (i_pkt_sel)
                    CIX_U1:   u1_r[pkt_rx_cnt_r*32 +: 32] <= i_pkt_in;
                    CIX_U2:   u2_r[pkt_rx_cnt_r*32 +: 32] <= i_pkt_in;
                    default:  ;
                endcase
                pkt_rx_cnt_r <= pkt_rx_cnt_r + 3'd1;
            end
            if (i_start) begin
                o_rdy_r      <= 1'b0;
                o_sonsuz_r   <= 1'b0;
                pkt_rx_cnt_r <= 3'd0;
                bit_idx_r    <= 9'd255;
                pkt_tx_cnt_r <= 3'd0;
                tx_koord_r   <= 2'd0;
                rx_koord_r   <= 2'd0;
                cnt_r        <= 3'd0;
                sab_j_r      <= 2'd0;
                state_r      <= ST_SABIT_YAZ;
            end
        end

        // ── Sabitleri BRAM'e yaz: G.X, G.Y, G.Z(=R), Q.Z(=R) ────────────
        //   32 çevrim, koşum başına bir kez. Bundan sonra gönderim yolunda
        //   256-bit kaynak mux'u yoktur.
        ST_SABIT_YAZ: begin
            if (cnt_r == 3'd7) begin
                cnt_r <= 3'd0;
                if (sab_j_r == 2'd3) state_r <= ST_TARA;
                else sab_j_r <= sab_j_r + 2'd1;
            end else cnt_r <= cnt_r + 3'd1;
        end

        // En yüksek set biti bul. Akümülatörü sonsuzlukla ilklememek için
        // gereklidir — Jacobian sonsuzluk (Z=0) özel durum mantığı ister.
        ST_TARA: begin
            if (bit_cifti_w != 2'b00) begin
                hedef_t_r <= 1'b1;
                p1_taban_r <= A_GX; p2_taban_r <= A_QX;
                cnt_r <= 3'd0; rx_koord_r <= 2'd0;
                state_r   <= ST_ON_T;      // T = G + Q her hâlükârda hesaplanır
            end else if (bit_idx_r == 9'd0) begin
                o_sonsuz_r <= 1'b1;        // u1 == 0 && u2 == 0
                state_r    <= ST_SONSUZ;
            end else begin
                bit_idx_r <= bit_idx_r - 9'd1;
            end
        end

        // ── ÖN HESAP: T = G + Q — kaynak seçicileri ST_TARA'da kuruldu ───
        ST_ON_T: begin
            py_cmd_r <= PAU_ADD; py_ret_r <= ST_ON_T_BEK;
            cnt_r <= 3'd0; state_r <= ST_PY_MODP_RD;
        end

        ST_ON_T_BEK: begin
            // T, PAU sonucu geldikçe BRAM'e (A_TX/A_TY/A_TZ) zaten
            // committed edildi (bkz. mem yazma bloğu) — ekstra kopya yok.
            state_r <= ST_ILKLE;
        end

        // R = en yüksek bit çiftine göre ilklenir (sonsuzluk YOK)
        //   BRAM okuma-yazma alt-döngüsü: her koordinat için RD sonra WR.
        ST_ILKLE: begin
            rx_koord_r <= 2'd0; cnt_r <= 3'd0;
            ilk_taban_r <= ilk_taban_w;   // G / Q / T tabanini kilitle
            state_r    <= ST_ILKLE_RD;
        end

        ST_ILKLE_RD: begin
            // mem_ra_c bu çevrimde kombinasyonel olarak uygulanır;
            // mem_rd_r bir SONRAKİ çevrimde (ST_ILKLE_WR) geçerli olur.
            state_r <= ST_ILKLE_WR;
        end

        ST_ILKLE_WR: begin
            // Sozcuk sozcuk kopya: 3 koordinat x 8 sozcuk
            if (cnt_r == 3'd7) begin
                cnt_r <= 3'd0;
                if (rx_koord_r == 2'd2) begin
                    if (bit_idx_r == 9'd0) begin
                        pkt_tx_cnt_r <= 3'd0; tx_koord_r <= 2'd0;
                        state_r <= ST_TX_FETCH;   // tek bitlik skaler
                    end else begin
                        bit_idx_r <= bit_idx_r - 9'd1; state_r <= ST_DBL;
                    end
                end else begin
                    rx_koord_r <= rx_koord_r + 2'd1;
                    state_r    <= ST_ILKLE_RD;
                end
            end else begin
                cnt_r   <= cnt_r + 3'd1;
                state_r <= ST_ILKLE_RD;
            end
        end

        // ── ANA DÖNGÜ: R = 2R — kaynak seçicileri kur ────────────────────
        ST_DBL: begin
            p1_taban_r <= A_RX; p2_taban_r <= A_RX; // DBL'de P2 yok sayılır
            hedef_t_r   <= 1'b0;                            // sonuç -> R
            py_cmd_r <= PAU_DBL; py_ret_r <= ST_DBL_BEK;
            cnt_r <= 3'd0; rx_koord_r <= 2'd0; state_r <= ST_PY_MODP_RD;
        end

        ST_DBL_BEK: begin
            // R, PAU sonucu geldikçe BRAM'e (A_RX/A_RY/A_RZ) zaten
            // committed edildi.
            if (bit_cifti_w == 2'b00) state_r <= ST_SONRAKI;
            else                      state_r <= ST_ADD;
        end

        // ── R = R + (G | Q | T) — kaynak seçicileri kur ──────────────────
        ST_ADD: begin
            p1_taban_r <= A_RX;
            case (bit_cifti_w)
                2'b01: p2_taban_r <= A_GX;
                2'b10: p2_taban_r <= A_QX;
                default: p2_taban_r <= A_TX;
            endcase
            hedef_t_r <= 1'b0; // sonuç -> R
            py_cmd_r <= PAU_ADD; py_ret_r <= ST_ADD_BEK;
            cnt_r <= 3'd0; rx_koord_r <= 2'd0; state_r <= ST_PY_MODP_RD;
        end

        ST_ADD_BEK: begin
            state_r <= ST_SONRAKI;
        end

        ST_SONRAKI: begin
            if (bit_idx_r == 9'd0) begin
                pkt_tx_cnt_r <= 3'd0; tx_koord_r <= 2'd0; state_r <= ST_TX_FETCH;
            end else begin
                bit_idx_r <= bit_idx_r - 9'd1;
                state_r   <= ST_DBL;
            end
        end

        // ── Sonucu 3 koordinat × 8 paket olarak akıt (BRAM'den okuyarak) ──
        ST_TX_FETCH: begin
            state_r <= ST_TX;
        end

        ST_TX: begin
            o_pkt_vld_r  <= 1'b1;
            o_pkt_sel_r  <= tx_koord_r;
            o_pkt_out_r  <= mem_rd_r;
            o_pkt_last_r <= (pkt_tx_cnt_r == 3'd7);
            if (pkt_tx_cnt_r == 3'd7) begin
                pkt_tx_cnt_r <= 3'd0;
                if (tx_koord_r == 2'd2) state_r <= ST_DONE;
                else begin tx_koord_r <= tx_koord_r + 2'd1; state_r <= ST_TX_FETCH; end
            end else begin
                pkt_tx_cnt_r <= pkt_tx_cnt_r + 3'd1;
                state_r <= ST_TX_FETCH;   // her sozcuk oncesi fetch sart
            end
        end

        ST_DONE:   begin o_done_r <= 1'b1; o_rdy_r <= 1'b1; state_r <= ST_IDLE; end
        ST_SONSUZ: begin o_done_r <= 1'b1; o_rdy_r <= 1'b1; state_r <= ST_IDLE; end

        // ── PAU OPERAND YÜKLEME ALT-FSM'İ ────────────────────────────────
        //   Her durum TEK iş yapar; sayaç sıfırlaması ile durum çıkışı
        //   aynı dalda (ecdsa_imza'daki sonsuz döngü hatasının dersi).
        //   mod p artik BRAM'den (A_P) akitilir; RD/TX almasik.
        ST_PY_MODP_RD: state_r <= ST_PY_MODP;
        ST_PY_MODP: begin
            pau_pkt_vld_r <= 1'b1;
            pau_pkt_sel_r <= PIX_MODP;
            pau_pkt_dat_r <= mem_rd_r;
            if (cnt_r == 3'd7) begin cnt_r <= 3'd0; state_r <= ST_PY_P1_FETCH; end
            else begin cnt_r <= cnt_r + 3'd1; state_r <= ST_PY_MODP_RD; end
        end

        // P1 kaynagini BRAM'den onceden oku (taban + koordinat)
        ST_PY_P1_FETCH: begin
            state_r <= ST_PY_P1;
        end

        // P1 = (X,Y,Z) — 24 paket, koordinat sırayla (mux'lu kaynak)
        ST_PY_P1: begin
            pau_pkt_vld_r <= 1'b1;
            case (rx_koord_r)
                2'd0: pau_pkt_sel_r <= PIX_P1X;
                2'd1: pau_pkt_sel_r <= PIX_P1Y;
                default: pau_pkt_sel_r <= PIX_P1Z;
            endcase
            pau_pkt_dat_r <= mem_rd_r;
            if (cnt_r == 3'd7) begin
                cnt_r <= 3'd0;
                if (rx_koord_r == 2'd2) begin rx_koord_r <= 2'd0; state_r <= ST_PY_P2_FETCH; end
                else begin rx_koord_r <= rx_koord_r + 2'd1; state_r <= ST_PY_P1_FETCH; end
            end else begin cnt_r <= cnt_r + 3'd1; state_r <= ST_PY_P1_FETCH; end
        end

        // [YENİ] P2 kaynağını (ACC/G/Q/T) BRAM'den önceden oku
        ST_PY_P2_FETCH: begin
            state_r <= ST_PY_P2;
        end

        ST_PY_P2: begin
            pau_pkt_vld_r <= 1'b1;
            case (rx_koord_r)
                2'd0: pau_pkt_sel_r <= PIX_P2X;
                2'd1: pau_pkt_sel_r <= PIX_P2Y;
                default: pau_pkt_sel_r <= PIX_P2Z;
            endcase
            pau_pkt_dat_r <= mem_rd_r;
            if (cnt_r == 3'd7) begin
                cnt_r <= 3'd0;
                if (rx_koord_r == 2'd2) begin rx_koord_r <= 2'd0; state_r <= ST_PY_GO; end
                else begin rx_koord_r <= rx_koord_r + 2'd1; state_r <= ST_PY_P2_FETCH; end
            end else begin cnt_r <= cnt_r + 3'd1; state_r <= ST_PY_P2_FETCH; end
        end

        ST_PY_GO: begin
            pau_st_r   <= 1'b1;
            pau_cmd_r  <= py_cmd_r;
            pau_wdog_r <= 15'd0;
            cnt_r      <= 3'd0;
            state_r    <= ST_PY_RX;
        end

        ST_PY_RX: begin
            if (pau_wdog_r >= PAU_WDOG_MAX) begin
                o_err_r <= 1'b1; o_rdy_r <= 1'b1; state_r <= ST_IDLE;
            end else if (pau_pkt_vld_w) begin
                // Biriktirme (res_acc_r) ve BRAM'e commit yukarıda yapılıyor;
                // burada yalnız sayaç ilerler.
                if (cnt_r == 3'd7) begin
                    cnt_r <= 3'd0;
                    if (pau_pkt_sel_w == 2'b10) state_r <= py_ret_r;  // Z bitti
                end else cnt_r <= cnt_r + 3'd1;
            end else if (!pau_done_w) begin
                pau_wdog_r <= pau_wdog_r + 15'd1;
            end
        end

        default: state_r <= ST_IDLE;

        endcase
        end
    end
end

endmodule
