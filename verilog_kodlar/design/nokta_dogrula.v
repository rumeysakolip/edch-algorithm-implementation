// =============================================================================
// Modül   : nokta_dogrula.v                                        (İster M-14)
// Proje   : FPGA Tabanlı Güvenli Anahtar Yönetimi ve Kripto Hızlandırıcı (5260007)
// -----------------------------------------------------------------------------
// Açıklama:
//   Dışarıdan gelen bir eliptik eğri noktasının NIST P-256 eğrisi üzerinde
//   bulunup bulunmadığını doğrular. Paylaşılan modular_alu'yu (MALU) kullanan
//   bir ISTEMCI modüldür; arayüzü affine_donusum.v ile birebir aynı desende
//   kurulmuştur (mo_* master çıkışları / mi_* master girişleri), böylece
//   ecdh_kex_top içindeki MALU arbiterine üçüncü yol olarak eklenebilir.
//
// -----------------------------------------------------------------------------
// *** NEDEN GEREKLİ — İNVALİD-EĞRİ (INVALID-CURVE) SALDIRISI ***
//   ECDH'de S = d·Qb hesaplanırken Qb KARŞI TARAFTAN gelir; yani saldırganın
//   tam kontrolündedir. Qb'nin gerçekten P-256 üzerinde olduğu doğrulanmazsa,
//   saldırgan küçük mertebeli (small-order) noktalar barındıran BAŞKA bir
//   eğri üzerinden nokta gönderir. Jacobian toplama/ikileme formülleri eğri
//   sabiti b'yi kullanmadığı için donanım bu noktayı sessizce işler ve sonuç,
//   d'nin küçük bir asal moduna göre kalanını sızdırır. Saldırgan farklı
//   mertebelerle işlemi tekrarlayıp Çin Kalan Teoremi ile d'yi tamamen
//   toparlayabilir.
//
//   Bu saldırı yalnızca d TEKRAR KULLANILDIĞINDA tam etkilidir. Mevcut demo
//   akışında d her oturumda TRNG'den taze geldiği için hasar sınırlıdır;
//   ancak proje kalıcı cihaz kimlik anahtarına (drawio Akış 1) geçtiğinde
//   bu kontrol OLMAZSA OLMAZ hale gelir. Bu modül o geçişin ön koşuludur.
//
//   Referans: NIST SP 800-56A Rev.3, §5.6.2.3.3 "ECC Full Public-Key
//   Validation Routine" — kısmi (partial) değil TAM doğrulama hedeflenmiştir.
//
// -----------------------------------------------------------------------------
// YAPILAN KONTROLLER:
//   1. Aralık : 0 <= x < p  ve  0 <= y < p
//                Aksi hâlde nokta zaten GF(p) elemanı değildir. Montgomery
//                indirgemesi bu değerleri sessizce sarmalar; kontrol edilmezse
//                hata görünmez kalır.
//   2. Eğri   : y² == x³ − 3x + b   (mod p)
//                P-256'da a = −3 olduğu için 3x tek çıkarma ile halledilir.
//   3. Sonsuzluk: (0,0) gösterimi 2. kontrol tarafından ZATEN reddedilir
//                (0 != b). Ayrı bir duruma gerek yoktur — bu, üst modüldeki
//                mevcut (x==0 && y==0) kontrolünü kapsar ve gereksiz kılar.
//
//   YAPILMAYAN (bilinçli): n·Qb == O mertebe kontrolü. P-256'nın kofaktörü
//   h = 1 olduğundan, eğri üstünde bulunan HER nokta zaten n mertebeli asal
//   alt gruptadır; ayrı mertebe kontrolü matematiksel olarak gereksizdir ve
//   fazladan bir tam skaler çarpım (~34 ms) maliyeti getirirdi.
//
// -----------------------------------------------------------------------------
// MONTGOMERY ALANI NOTU (kritik):
//   Giriş noktası ecdh_kex_top'a Montgomery alanında gelir (x̃ = x·R mod p).
//   MALU'nun MontMult'u MM(ãb̃) = a·b·R mod p = (a·b)~ ürettiği için çarpma
//   alanı KORUR; ModAdd/ModSub zaten doğrusaldır ve alanı korur. Dolayısıyla
//   eğri denklemi Montgomery alanında OLDUĞU GİBİ yazılabilir — tek şart,
//   b sabitinin de Montgomery alanına taşınmış olmasıdır (B_MONT).
//
//   B_MONT = b · 2^256 mod p  olarak hesaplanmış ve G = (Gx,Gy) noktasıyla
//   Python'da doğrulanmıştır (aynı yöntemle üretilen GX_MONT/GY_MONT,
//   ecdh_kex_top.v'deki mevcut sabitlerle bit-birebir eşleşir).
//
// -----------------------------------------------------------------------------
// İSİMLENDİRME NOTU:
//   Bu modül i_*/o_* önekini kullanır (g_*/c_* değil). Sebep: kardeş MALU
//   istemcileri (scalar_multiplier, affine_donusum) ve modular_alu bu deseni
//   kullanıyor; nokta_dogrula onların yanına aynı arbitere bağlanıyor.
//   Kripto katmanında yerel tutarlılık korunmuştur. UART katmanı (g_*/c_*)
//   etkilenmez.
//
// MALIYET: 7 MALU çağrısı (3 MontMult + 3 ModAdd/Sub + 1 ModSub)
//          ≈ 7 × ~270 çevrim ≈ 1900 çevrim ≈ 19 µs @ 100 MHz.
//          Skaler çarpımın (~34 ms) yanında ölçülemez düzeyde küçüktür.
//
// Kabul kriteri (TB-14):
//   Geçerli P-256 noktaları kabul; eğri dışı nokta, küçük mertebeli sahte
//   nokta, x >= p, y >= p ve (0,0) reddedilir. Reddediliş o_gecerli=0 ile
//   raporlanır; o_err YALNIZCA donanım arızasında (MALU hatası/watchdog) kalkar.
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
module nokta_dogrula (
    input  wire         clk_in,
    input  wire         rst_n,

    // ── Paket girişi (32-bit, LSB-önce; 8 paket = 256 bit) ────────────────
    input  wire [31:0]  i_pkt_in,
    input  wire         i_pkt_vld,
    input  wire [2:0]   i_pkt_sel,     // NIX_* seçicileri
    input  wire         i_start,

    // ── Sonuç ─────────────────────────────────────────────────────────────
    output wire         o_gecerli,     // 1 = nokta P-256 üzerinde
    output wire         o_rdy,
    output wire         o_done,        // 1-çevrimlik bitiş darbesi
    output wire         o_err,         // YALNIZCA donanım arızası

    // ── Paylaşılan MALU dış arayüzü (master) ──────────────────────────────
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
    //   Eğri sabiti b'nin Montgomery temsili artık dışarıdan gelir; reset/
    //   varsayılan P-256 olduğundan mevcut davranış korunur.
    input  wire [255:0] g_b_mont
);

// ── Giriş paket seçicileri ────────────────────────────────────────────────
localparam [2:0] NIX_MODP = 3'd0,
                 NIX_X    = 3'd1,
                 NIX_Y    = 3'd2;

// ── MALU arayüz sabitleri (modular_alu.v ile birebir) ─────────────────────
localparam [1:0] MSEL_A = 2'b00, MSEL_B = 2'b01, MSEL_P = 2'b10;
localparam [1:0] MADD   = 2'b00, MSUB   = 2'b01, MMUL   = 2'b10;

// ── P-256 eğri sabiti b, Montgomery alanında ──────────────────────────────
//   b       = 5ac635d8 aa3a93e7 b3ebbd55 769886bc 651d06b0 cc53b0f6 3bce3c3e 27d2604b
//   B_MONT  = b · 2^256 mod p
// B_MONT ARTIK GİRİŞ (g_b_mont). Eski P-256 sabiti (belge amaçlı):
//   256'hdc30061d04874834e5a220abf7212ed6acf005cd78843090d89cdf6229c4bddf
wire [255:0] B_MONT = g_b_mont;

// =============================================================================
// TEMMUZ 2026 — 32-BİT SÖZCÜK-ADRESLİ BRAM DÖNÜŞÜMÜ (Nihai Mimari, Adım 5)
//
//   Bu modül 1629 LUT / 2398 FF tutuyordu; kaynak 9 adet 256-bit yazmaç
//   (mod_p_r, x_r, y_r, yy_r, xxx_r, ma_r, mb_r, mres_r, cmp_a_r = 2304 bit)
//   ve onları dilimleyen 9 part-select mux'uydu (her biri ~150-180 LUT).
//
//   Değerler artık 8 ardışık 32-bit sözcük olarak tek Block RAM'de durur:
//   adres = {slot[2:0], sozcuk[2:0]}. Karşılaştırma alt-FSM'i de BRAM'e
//   uyarlandı: iki slotu sözcük sözcük okur (RA -> RB -> CK boru hattı).
//
//   *** BRAM 1 ÇEVRİM GECİKMELİDİR: okuma adresi FETCH *VE* KULLANIM
//   durumunun İKİSİNDE de tutulur *** (TB-19'da yakalanan hatanın dersi).
// =============================================================================

// ── Durum kodlaması ───────────────────────────────────────────────────────
localparam [4:0]
    ST_IDLE      = 5'd0,
    ST_KAR_X     = 5'd1,   // x < p  karşılaştırması başlat
    ST_KAR_Y     = 5'd2,   // y < p  karşılaştırması başlat
    ST_SENDP_RD  = 5'd3,   // MALU'ya modülü yükle: oku
    ST_SENDP_TX  = 5'd4,   //                      gönder (+ B_MONT'u yaz)
    ST_OP_YY     = 5'd5,   // yy   = MM(y, y)
    ST_OP_XX     = 5'd6,   // xx   = MM(x, x)
    ST_OP_XXX    = 5'd7,   // xxx  = MM(xx, x)
    ST_OP_2X     = 5'd8,   // 2x   = x + x
    ST_OP_3X     = 5'd9,   // 3x   = 2x + x
    ST_OP_SUB    = 5'd10,  // rhs  = xxx − 3x
    ST_OP_ADDB   = 5'd11,  // rhs  = rhs + b
    ST_HUK_CMP   = 5'd12,  // yy == rhs ? karşılaştırmasını başlat
    ST_HUKUM     = 5'd13,
    ST_DONE      = 5'd14,
    // Karşılaştırma alt-FSM'i (slot1 ? slot2, MSB sözcükten LSB'ye)
    ST_CMP_RA    = 5'd15,
    ST_CMP_RB    = 5'd16,
    ST_CMP_CK    = 5'd17,
    // MALU dispatch alt-FSM'i (operandlar BRAM'den)
    ST_MA_ARD    = 5'd18,
    ST_MA_ATX    = 5'd19,
    ST_MA_BRD    = 5'd20,
    ST_MA_BTX    = 5'd21,
    ST_MA_GO     = 5'd22,
    ST_MA_WT     = 5'd23,
    ST_MA_RX     = 5'd24,
    ST_MA_WR     = 5'd25;

reg [4:0] state_r;

// Watchdog: tek bir MALU işlemi en fazla ~300 çevrim sürer (modular_alu
// WDOG_MAX=300). 4096 çevrim bol emniyet payıdır; kilitlenmede hata verir.
localparam [11:0] MA_WDOG_MAX = 12'd4000;

// ── BRAM slot adresleri (her slot 8 x 32-bit sözcük) ─────────────────────
localparam [2:0] A_P=3'd0, A_X=3'd1, A_Y=3'd2,
                 A_YY=3'd3, A_XXX=3'd4, A_RES=3'd5, A_B=3'd6;

// ── 32-bit geniş Block RAM scratchpad ────────────────────────────────────
(* ram_style = "block" *) reg [31:0] ara_mem [0:63];
reg [31:0] mem_rd_r;
reg [5:0]  mem_ra_c;
reg        mem_we_c;
reg [5:0]  mem_wa_c;
reg [31:0] mem_wd_c;
always @(posedge clk_in) begin
    if (mem_we_c) ara_mem[mem_wa_c] <= mem_wd_c;
    mem_rd_r <= ara_mem[mem_ra_c];
end

// ── Veri kayıtçıları — 256-bit olanların TAMAMI elendi ───────────────────
reg [2:0]   opid_a_r, opid_b_r, opid_res_r;
reg [1:0]   opc_r;          // çağıran tarafından kurulan opcode
reg [4:0]   mret_r;         // MALU dispatch dönüş adresi
reg [2:0]   mcnt_r;         // paket sayacı (0..7)
reg [11:0]  ma_wdog_r;
reg         modp_nz_r;      // mod p != 0 (mod_p_r yazmacının yerine bayrak)

// Karşılaştırma alt-FSM'i kayıtçıları
reg [2:0]   cmp_s1_r, cmp_s2_r;  // karşılaştırılacak iki slot
reg [31:0]  cmp_v1_r;            // slot1'in o anki sözcüğü
reg [2:0]   cmp_idx_r;           // 7 → 0, MSB sözcükten başlar
reg         cmp_kucuk_r;         // 1 = slot1 < slot2
reg         cmp_esit_r;          // 1 = tüm sözcükler eşit
reg [4:0]   cmp_ret_r;           // karşılaştırma sonrası dönülecek durum

reg [2:0]   pkt_rx_cnt_r;

// ── Çıkış saklayıcıları → wire portlara assign ────────────────────────────
reg        o_gecerli_r, o_rdy_r, o_done_r, o_err_r;
reg [31:0] malu_pkt_dat_r;
reg        malu_pkt_vld_r;
reg [1:0]  malu_pkt_sel_r;
reg [1:0]  malu_opc_r;
reg        malu_st_r;

assign o_gecerli  = o_gecerli_r;
assign o_rdy      = o_rdy_r;
assign o_done     = o_done_r;
assign o_err      = o_err_r;
assign mo_pkt_dat = malu_pkt_dat_r;
assign mo_pkt_vld = malu_pkt_vld_r;
assign mo_pkt_sel = malu_pkt_sel_r;
assign mo_opc     = malu_opc_r;
assign mo_st      = malu_st_r;

// ── Giriş seçiciden BRAM slotuna eşleme ──────────────────────────────────
reg [2:0] giris_slot_w;
always @* begin
    case (i_pkt_sel)
        NIX_MODP: giris_slot_w = A_P;
        NIX_X:    giris_slot_w = A_X;
        default:  giris_slot_w = A_Y;
    endcase
end

// ── BRAM OKUMA ADRESİ (KOMBİNASYONEL) ────────────────────────────────────
//   Adres hem FETCH hem KULLANIM durumunda tutulur.
//   Karşılaştırma boru hattı: RA'da slot1, RB'de slot2 adreslenir; böylece
//   slot1 sözcüğü RB'de, slot2 sözcüğü CK'da hazır olur.
always @* begin
    case (state_r)
        ST_SENDP_RD, ST_SENDP_TX: mem_ra_c = {A_P, mcnt_r};
        ST_MA_ARD,   ST_MA_ATX:   mem_ra_c = {opid_a_r, mcnt_r};
        ST_MA_BRD,   ST_MA_BTX:   mem_ra_c = {opid_b_r, mcnt_r};
        ST_CMP_RA:                mem_ra_c = {cmp_s1_r, cmp_idx_r};
        ST_CMP_RB:                mem_ra_c = {cmp_s2_r, cmp_idx_r};
        default:                  mem_ra_c = 6'd0;
    endcase
end

// ── BRAM YAZMA DENETİMİ (KOMBİNASYONEL) ──────────────────────────────────
always @* begin
    mem_we_c = 1'b0; mem_wa_c = 6'd0; mem_wd_c = 32'd0;
    if (state_r == ST_IDLE) begin
        if (i_pkt_vld && (i_pkt_sel <= NIX_Y)) begin
            mem_we_c = 1'b1;
            mem_wa_c = {giris_slot_w, pkt_rx_cnt_r};
            mem_wd_c = i_pkt_in;
        end
    end else if (state_r == ST_SENDP_TX) begin
        // mod p MALU'ya giderken (okuma portu) eğri sabiti b de BRAM'e
        // yazılır (yazma portu) — iki port bağımsız, aynı çevrimde olur.
        mem_we_c = 1'b1;
        mem_wa_c = {A_B, mcnt_r};
        mem_wd_c = B_MONT[mcnt_r*32 +: 32];
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
        state_r        <= ST_IDLE;
        o_gecerli_r    <= 1'b0;
        o_rdy_r        <= 1'b0;
        o_done_r       <= 1'b0;
        o_err_r        <= 1'b0;
        malu_pkt_dat_r <= 32'd0;
        malu_pkt_vld_r <= 1'b0;
        malu_pkt_sel_r <= 2'd0;
        malu_opc_r     <= 2'd0;
        malu_st_r      <= 1'b0;
        opid_a_r       <= A_X;
        opid_b_r       <= A_X;
        opid_res_r     <= A_RES;
        opc_r          <= 2'd0;
        mret_r         <= 5'd0;
        mcnt_r         <= 3'd0;
        ma_wdog_r      <= 12'd0;
        modp_nz_r      <= 1'b0;
        cmp_s1_r       <= A_X;
        cmp_s2_r       <= A_P;
        cmp_v1_r       <= 32'd0;
        cmp_idx_r      <= 3'd7;
        cmp_kucuk_r    <= 1'b0;
        cmp_esit_r     <= 1'b0;
        cmp_ret_r      <= 5'd0;
        pkt_rx_cnt_r   <= 3'd0;
    end else begin
        // Darbe sinyalleri her çevrim varsayılan olarak düşer
        o_done_r       <= 1'b0;
        o_err_r        <= 1'b0;
        malu_st_r      <= 1'b0;
        malu_pkt_vld_r <= 1'b0;

        // MALU arızası her durumu ezer
        if (mi_err) begin
            o_err_r     <= 1'b1;
            o_gecerli_r <= 1'b0;
            o_rdy_r     <= 1'b1;
            state_r     <= ST_IDLE;
        end else begin
        case (state_r)

        // -----------------------------------------------------------------
        // Paket alımı ve başlatma
        // -----------------------------------------------------------------
        ST_IDLE: begin
            o_rdy_r <= 1'b1;
            if (i_pkt_vld) begin
                // Veri BRAM'e yazma bloğunda gidiyor; burada bayrak + sayaç
                if (i_pkt_sel == NIX_MODP)
                    modp_nz_r <= (pkt_rx_cnt_r==3'd0) ? (i_pkt_in!=32'd0)
                                                      : (modp_nz_r | (i_pkt_in!=32'd0));
                pkt_rx_cnt_r <= pkt_rx_cnt_r + 3'd1;
            end
            if (i_start) begin
                o_rdy_r      <= 1'b0;
                o_gecerli_r  <= 1'b0;
                pkt_rx_cnt_r <= 3'd0;
                state_r      <= ST_KAR_X;
            end
        end

        // -----------------------------------------------------------------
        // KONTROL 1 — aralık: x < p, y < p
        // -----------------------------------------------------------------
        ST_KAR_X: begin
            if (!modp_nz_r) begin
                // Geçersiz alan parametresi: bu bir donanım/konfigürasyon
                // hatasıdır, noktanın suçu değildir → o_err.
                o_err_r <= 1'b1; o_rdy_r <= 1'b1; state_r <= ST_IDLE;
            end else begin
                cmp_s1_r  <= A_X; cmp_s2_r <= A_P;
                cmp_idx_r <= 3'd7;
                cmp_ret_r <= ST_KAR_Y;
                state_r   <= ST_CMP_RA;
            end
        end

        ST_KAR_Y: begin
            if (!cmp_kucuk_r) begin
                // x >= p → nokta GF(p) elemanı değil
                o_gecerli_r <= 1'b0; state_r <= ST_DONE;
            end else begin
                cmp_s1_r  <= A_Y; cmp_s2_r <= A_P;
                cmp_idx_r <= 3'd7;
                cmp_ret_r <= ST_SENDP_RD;
                mcnt_r    <= 3'd0;   // gönderim paket sayacını açıkça sıfırla
                state_r   <= ST_CMP_RA;
            end
        end

        // -----------------------------------------------------------------
        // KONTROL 2 — eğri denklemi. MALU'ya modül bir kez yüklenir.
        //   Aynı 8 çevrimde eğri sabiti b de BRAM'e yazılır (yazma bloğu).
        // -----------------------------------------------------------------
        ST_SENDP_RD: begin
            if (!cmp_kucuk_r) begin
                // y >= p
                o_gecerli_r <= 1'b0; state_r <= ST_DONE;
            end else state_r <= ST_SENDP_TX;
        end
        ST_SENDP_TX: begin
            malu_pkt_vld_r <= 1'b1;
            malu_pkt_dat_r <= mem_rd_r;
            malu_pkt_sel_r <= MSEL_P;
            if (mcnt_r == 3'd7) begin mcnt_r <= 3'd0; state_r <= ST_OP_YY; end
            // ST_SENDP_RD'ye dönmek güvenlidir: oradaki cmp_kucuk_r muhafızı
            // bu döngü boyunca değişmez (1'de sabit), yalnızca fetch yapar.
            else begin mcnt_r <= mcnt_r + 3'd1; state_r <= ST_SENDP_RD; end
        end

        // yy = MM(y, y)  -> A_YY
        ST_OP_YY: begin
            opid_a_r <= A_Y; opid_b_r <= A_Y; opid_res_r <= A_YY; opc_r <= MMUL;
            mret_r <= ST_OP_XX; mcnt_r <= 3'd0; state_r <= ST_MA_ARD;
        end

        // xx = MM(x, x)  -> A_RES
        ST_OP_XX: begin
            opid_a_r <= A_X; opid_b_r <= A_X; opid_res_r <= A_RES; opc_r <= MMUL;
            mret_r <= ST_OP_XXX; mcnt_r <= 3'd0; state_r <= ST_MA_ARD;
        end

        // xxx = MM(xx, x) -> A_XXX
        ST_OP_XXX: begin
            opid_a_r <= A_RES; opid_b_r <= A_X; opid_res_r <= A_XXX; opc_r <= MMUL;
            mret_r <= ST_OP_2X; mcnt_r <= 3'd0; state_r <= ST_MA_ARD;
        end

        // 2x = x + x -> A_RES
        ST_OP_2X: begin
            opid_a_r <= A_X; opid_b_r <= A_X; opid_res_r <= A_RES; opc_r <= MADD;
            mret_r <= ST_OP_3X; mcnt_r <= 3'd0; state_r <= ST_MA_ARD;
        end

        // 3x = 2x + x -> A_RES
        ST_OP_3X: begin
            opid_a_r <= A_RES; opid_b_r <= A_X; opid_res_r <= A_RES; opc_r <= MADD;
            mret_r <= ST_OP_SUB; mcnt_r <= 3'd0; state_r <= ST_MA_ARD;
        end

        // rhs = xxx − 3x   (P-256'da a = −3) -> A_RES
        ST_OP_SUB: begin
            opid_a_r <= A_XXX; opid_b_r <= A_RES; opid_res_r <= A_RES; opc_r <= MSUB;
            mret_r <= ST_OP_ADDB; mcnt_r <= 3'd0; state_r <= ST_MA_ARD;
        end

        // rhs = rhs + b -> A_RES   (b, ST_SENDP_TX'te A_B'ye yazılmıştı)
        ST_OP_ADDB: begin
            opid_a_r <= A_RES; opid_b_r <= A_B; opid_res_r <= A_RES; opc_r <= MADD;
            mret_r <= ST_HUK_CMP; mcnt_r <= 3'd0; state_r <= ST_MA_ARD;
        end

        // -----------------------------------------------------------------
        // HÜKÜM — y² == x³ − 3x + b ?  (sözcük-seri eşitlik karşılaştırması)
        // -----------------------------------------------------------------
        ST_HUK_CMP: begin
            cmp_s1_r  <= A_YY; cmp_s2_r <= A_RES;
            cmp_idx_r <= 3'd7;
            cmp_ret_r <= ST_HUKUM;
            state_r   <= ST_CMP_RA;
        end

        ST_HUKUM: begin
            o_gecerli_r <= cmp_esit_r;
            state_r     <= ST_DONE;
        end

        ST_DONE: begin
            o_done_r <= 1'b1;
            o_rdy_r  <= 1'b1;
            state_r  <= ST_IDLE;
        end

        // -----------------------------------------------------------------
        // KARŞILAŞTIRMA ALT-FSM'İ — cmp_a_r < mod_p_r ?
        //   MSB word'den (7) LSB word'e (0) iner. İlk farklı dilimde karar
        //   verilir. Tüm dilimler eşitse a == p demektir → "küçük" DEĞİL.
        // -----------------------------------------------------------------
        //   BRAM boru hattı: RA slot1'i adresler, RB'de slot1 sözcüğü hazır
        //   olur ve slot2 adreslenir, CK'da slot2 sözcüğü hazır olur.
        ST_CMP_RA: state_r <= ST_CMP_RB;

        ST_CMP_RB: begin
            cmp_v1_r <= mem_rd_r;    // slot1'in bu sözcüğü
            state_r  <= ST_CMP_CK;
        end

        ST_CMP_CK: begin
            // mem_rd_r = slot2'nin bu sözcüğü
            if (cmp_v1_r != mem_rd_r) begin
                cmp_kucuk_r <= (cmp_v1_r < mem_rd_r);
                cmp_esit_r  <= 1'b0;
                state_r     <= cmp_ret_r;
            end else if (cmp_idx_r == 3'd0) begin
                cmp_kucuk_r <= 1'b0;              // tam eşitlik
                cmp_esit_r  <= 1'b1;
                state_r     <= cmp_ret_r;
            end else begin
                cmp_idx_r   <= cmp_idx_r - 3'd1;
                state_r     <= ST_CMP_RA;
            end
        end

        // -----------------------------------------------------------------
        // MALU DISPATCH ALT-FSM'İ
        //   ma_r → SEL_A (8 paket), mb_r → SEL_B (8 paket), start, 8 paket al.
        //   Sonuç mres_r'ye yazılır, mret_r durumuna dönülür.
        // -----------------------------------------------------------------
        //   ma_r / mb_r / mres_r ara yazmaçları TAMAMEN KALDIRILDI:
        //   operandlar BRAM'den akıtılır, sonuç geldiği gibi BRAM'e yazılır.
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
            state_r    <= ST_MA_WT;
        end

        ST_MA_WT: begin
            // İlk sözcük yazma bloğunda BRAM'e gitti (mcnt_r = 0)
            if (ma_wdog_r >= MA_WDOG_MAX) begin
                o_err_r <= 1'b1; o_gecerli_r <= 1'b0; o_rdy_r <= 1'b1;
                state_r <= ST_IDLE;
            end else if (mi_pkt_vld) begin
                mcnt_r  <= 3'd1;
                state_r <= ST_MA_RX;
            end else begin
                ma_wdog_r <= ma_wdog_r + 12'd1;
            end
        end

        ST_MA_RX: begin
            if (mi_pkt_vld) begin
                if (mcnt_r == 3'd7) begin mcnt_r <= 3'd0; state_r <= ST_MA_WR; end
                else                      mcnt_r <= mcnt_r + 3'd1;
            end
        end

        // Son yazmanın BRAM'e oturması için 1 çevrimlik tampon
        ST_MA_WR: state_r <= mret_r;

        default: state_r <= ST_IDLE;

        endcase
        end
    end
end

endmodule
