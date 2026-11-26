// =============================================================================
// Modül   : ecdsa_dogrula.v                                        (İster M-21)
// Proje   : FPGA Tabanlı Güvenli Anahtar Yönetimi ve Kripto Hızlandırıcı (5260007)
// -----------------------------------------------------------------------------
// Açıklama:
//   ECDSA imza doğrulamasının GF(n) ARİTMETİK yarısı.
//
//     w  = s^(-1) mod n
//     u1 = e·w mod n     u2 = r·w mod n
//     R  = u1·G + u2·Q                    ← cift_skaler_carpim (BURADA DEĞİL)
//     v  = R.x mod n
//     geçerli  ⟺  v == r
//
//   Çift skaler çarpım ve affin dönüşüm çağıranın (ecdh_kex_top) işidir;
//   böylece PAU ve affine_donusum tek yerde kalır. Bu modül İKİ AŞAMALI
//   çalışır:
//
//     AŞAMA 1 (i_start)  : (e,r,s) → aralık kontrolü + u1, u2 üretimi
//     AŞAMA 2 (i_hukum)  : Rx (düz) → v = Rx mod n → v == r hükmü
//
//   Aradaki adımı çağıran koşturur. Bu ayrım, PAU/affine dispatch'inin
//   ecdh_kex_top'ta zaten var olan makinesini yeniden kullanmayı sağlar —
//   aksi hâlde bu modülün dört ayrı master arayüzü olurdu.
//
// -----------------------------------------------------------------------------
// *** DOĞRULAMA AÇIK VERİYLE ÇALIŞIR — GİZLİ ANAHTAR YOKTUR ***
//   r, s (imza), e (özet), Q (karşı tarafın açık anahtarı) — hepsi açıktır.
//   Bu yüzden burada sabit zamanlılık ARANMAZ ve cift_skaler_carpim'in
//   değişken zamanlı olması bir eksiklik değildir (bkz. o dosyanın başlığı).
//
//   Buna karşılık mod_n_ters yine sabit zamanlıdır — çünkü AYNI ÖRNEK
//   imzalamada k^(-1) için de kullanılır ve ORADA girdi gizlidir. Tek örneği
//   paylaşmanın bedeli, doğrulamada gereğinden güvenli olmaktır; tersi
//   (imzalamada gereğinden hızlı olmak) kabul edilemezdi.
//
// -----------------------------------------------------------------------------
// MONTGOMERY ALAN AKIŞI:
//   MontMult(ã,b) = a·b mod n  (operandlardan biri düzse sonuç düz çıkar)
//     1) s̃  = MM(s, R2N)      → Montgomery
//     2) w̃  = mod_n_ters(s̃)   → (s^-1)~
//     3) u1 = MM(w̃, e)        → DÜZ  e·s^-1
//     4) u2 = MM(w̃, r)        → DÜZ  r·s^-1
//   Yalnız BİR dönüşüm gerekiyor; u1 ve u2 doğrudan düz çıkıyor.
//
// -----------------------------------------------------------------------------
// ARALIK KONTROLÜ (FIPS 186-4 §6.4.2, adım 1):
//   r ve s'nin [1, n-1] aralığında olması ŞARTTIR ve İLK sırada sınanır.
//   Bu kontrol atlanırsa s=0 gibi bir değer ters alma adımında tanımsız
//   davranışa yol açar; r=0 ise saldırgan v==r karşılaştırmasını
//   dejenere bir duruma sokabilir. Aralık dışı imza, hesaba hiç girmeden
//   reddedilir.
//
// Rx → v İNDİRGEMESİ:
//   Rx bir GF(p) elemanıdır, v ise GF(n). p < 2n olduğu için tek koşullu
//   çıkarma yeterlidir — ecdsa_imza'daki Rx→r indirgemesiyle aynı ilke.
//
// MALİYET:
//   1 MontMult + ters alma + 2 MontMult ≈ 3×290 + 122.675 ≈ 123.500 çevrim
//   ≈ 1.24 ms. Doğrulamanın süresini belirleyen şey çift skaler çarpımdır
//   (~18 ms), bu modül değil.
//
// Kabul kriteri (TB-21):
//   3 KAT vektörü (u1,u2 bit-birebir); r/s aralık dışı reddi; doğru ve
//   yanlış Rx ile hüküm; ardışık koşum.
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
module ecdsa_dogrula (
    input  wire         clk_in,
    input  wire         rst_n,

    // ── Paket girişi: 0=mod_n 1=e 2=r 3=s 4=Rx(düz) ──────────────────────
    input  wire [31:0]  i_pkt_in,
    input  wire         i_pkt_vld,
    input  wire [2:0]   i_pkt_sel,

    input  wire         i_start,       // AŞAMA 1: u1, u2 üret
    input  wire         i_hukum,       // AŞAMA 2: Rx ile hüküm ver

    // ── AŞAMA 1 çıkışı: u1, u2 (DÜZ) ─────────────────────────────────────
    output wire [31:0]  o_pkt_out,
    output wire         o_pkt_vld,
    output wire         o_pkt_sel,     // 0 = u1, 1 = u2
    output wire         o_pkt_last,

    output wire         o_rdy,
    output wire         o_done,
    output wire         o_err,

    // ── AŞAMA 2 çıkışı: hüküm ────────────────────────────────────────────
    output wire         o_gecerli,     // imza geçerli
    output wire         o_aralik_hata, // r veya s, [1,n-1] dışında

    // ── Paylaşılan mod_n_ters (master) ───────────────────────────────────
    output wire [31:0]  to_pkt_dat,
    output wire         to_pkt_vld,
    output wire [1:0]   to_pkt_sel,
    output wire         to_st,
    input  wire [31:0]  ti_pkt_out,
    input  wire         ti_pkt_vld,
    input  wire         ti_rdy,
    input  wire         ti_done,
    input  wire         ti_err,

    // ── Paylaşılan MALU (master) ─────────────────────────────────────────
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
    //   R2N (=R² mod n) dışarıdan gelir. Reset/varsayılan P-256'dır.
    input  wire [255:0] g_r2n
);

localparam [2:0] DIX_MODN=3'd0, DIX_E=3'd1, DIX_R=3'd2, DIX_S=3'd3, DIX_RX=3'd4;
localparam [1:0] MSEL_A=2'b00, MSEL_B=2'b01, MSEL_P=2'b10;
localparam [1:0] MADD=2'b00, MSUB=2'b01, MMUL=2'b10;

// R2N ARTIK GİRİŞTİR (g_r2n). Eski P-256 sabiti (belge amaçlı):
//   256'h66e12d94f3d956202845b2392b6bec594699799c49bd6fa683244c95be79eea2
wire [255:0] R2N = g_r2n;

// =============================================================================
// TEMMUZ 2026 — 32-BİT SÖZCÜK-ADRESLİ BRAM DÖNÜŞÜMÜ (Nihai Mimari, Adım 5)
//
//   Bu modül 2207 LUT / 3783 FF tutuyordu; kaynak 14 adet 256-bit yazmaç
//   (mod_n, e, r, s, rx, w, u1, u2, sm, v, ma, mb, mres, cmp_a = 3584 bit)
//   ve onları dilimleyen 16 part-select mux'uydu (her biri ~140-170 LUT).
//
//   Değerler artık 8 ardışık 32-bit sözcük olarak tek Block RAM'de durur:
//   adres = {slot[3:0], sozcuk[2:0]}.
//
//   *** SABİT ZAMANLILIK KORUNDU ***: aralık karşılaştırması (FIPS 186-4
//   6.4.2 adım 1) hâlâ HER ZAMAN 8 sözcük gezer — karar ilk farkta verilir
//   ama cmp_bitti_r ile kilitlenir, döngü kısalmaz. BRAM boru hattı her
//   sözcük için sabit 3 çevrim harcar; toplam yine veriden bağımsızdır.
//
//   *** BRAM 1 ÇEVRİM GECİKMELİDİR: okuma adresi FETCH *VE* KULLANIM
//   durumunun İKİSİNDE de tutulur *** (TB-19'da yakalanan hatanın dersi).
//
//   v = Rx mod n için KOPYA YAPILMAZ: koşullu çıkarma gerekmiyorsa v zaten
//   A_RX'tedir, gerekiyorsa A_RES'tedir; son karşılaştırma hangi slotun
//   geçerli olduğunu cmp_kucuk_r'den seçer (8 çevrimlik kopya elenir).
// =============================================================================
localparam [5:0]
    ST_IDLE     = 6'd0,
    ST_SENDP_RD = 6'd1,   // MALU'ya mod n: oku   (+ R2N'i BRAM'e yaz)
    ST_SENDP_TX = 6'd2,   //                gönder
    ST_CMP_RA   = 6'd3,   // karşılaştırma: slot1 adresle
    ST_CMP_RB   = 6'd4,   //                slot1 yakala + slot2 adresle
    ST_CMP_CK   = 6'd5,   //                karşılaştır
    ST_CMP_S    = 6'd6,   // s ∈ [1, n-1] ?
    ST_OP_SM    = 6'd7,   // s~ = MM(s, R2N)
    ST_TERS_NRD = 6'd8,   // ters modülüne mod_n yükle: oku
    ST_TERS_NTX = 6'd9,   //                            gönder
    ST_TERS_ARD = 6'd10,  // ters modülüne s~ yükle: oku
    ST_TERS_ATX = 6'd11,  //                        gönder + start
    ST_TERS_B   = 6'd12,  // bitişi bekle (sonuç A_W'ye yazılır)
    ST_OP_U1    = 6'd13,  // u1 = MM(w~, e)
    ST_OP_U2    = 6'd14,  // u2 = MM(w~, r)
    ST_TX_RD    = 6'd15,  // u1/u2 çıkışı: oku
    ST_TX_U1    = 6'd16,
    ST_TX_U2    = 6'd17,
    ST_DONE1    = 6'd18,
    // AŞAMA 2
    ST_CMP_RX  = 6'd19,   // Rx >= n ? karşılaştırmasını kur
    ST_RED_RX  = 6'd20,   // v = Rx - n
    ST_HUK_CMP = 6'd21,   // v == r ? karşılaştırmasını kur
    ST_DONE2   = 6'd22,
    ST_HATA    = 6'd23,
    // MALU dispatch (operandlar BRAM'den)
    ST_MA_ARD  = 6'd24,
    ST_MA_ATX  = 6'd25,
    ST_MA_BRD  = 6'd26,
    ST_MA_BTX  = 6'd27,
    ST_MA_GO   = 6'd28,
    ST_MA_WT   = 6'd29,
    ST_MA_RX   = 6'd30,
    ST_MA_WR   = 6'd31,
    ST_TX2_RD  = 6'd32;   // u2 çıkışı için fetch adımı

reg [5:0] state_r;

localparam [11:0] MA_WDOG_MAX  = 12'd4000;
localparam [19:0] TRS_WDOG_MAX = 20'd400_000;

// ── BRAM slot adresleri (her slot 8 x 32-bit sözcük) ─────────────────────
localparam [3:0] A_N=4'd0, A_E=4'd1, A_R=4'd2, A_S=4'd3, A_RX=4'd4,
                 A_W=4'd5, A_SM=4'd6, A_RES=4'd7, A_R2N=4'd8,
                 A_U1=4'd9, A_U2=4'd10;

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
reg [1:0]   opc_r;
reg [5:0]   mret_r;
reg [2:0]   mcnt_r;
reg [11:0]  ma_wdog_r;
reg [19:0]  trs_wdog_r;
reg [2:0]   pkt_rx_cnt_r, pkt_tx_cnt_r, trs_rx_cnt_r;
reg         r_nz_r, s_nz_r;   // r != 0 / s != 0  (256-bit == 0 yerine bayrak)

// Sabit zamanli sozcuk-seri karsilastirma (slot1 ? slot2)
reg [3:0]   cmp_s1_r, cmp_s2_r;
reg [31:0]  cmp_v1_r;
reg [2:0]   cmp_idx_r;
reg         cmp_kucuk_r, cmp_bitti_r, cmp_esit_r;
reg [5:0]   cmp_ret_r;

reg [31:0] o_pkt_out_r;
reg        o_pkt_vld_r, o_pkt_sel_r, o_pkt_last_r;
reg        o_rdy_r, o_done_r, o_err_r, o_gecerli_r, o_aralik_r;
reg [31:0] malu_pkt_dat_r; reg malu_pkt_vld_r, malu_st_r;
reg [1:0]  malu_pkt_sel_r, malu_opc_r;
reg [31:0] trs_pkt_dat_r; reg trs_pkt_vld_r, trs_st_r;
reg [1:0]  trs_pkt_sel_r;

assign o_pkt_out     = o_pkt_out_r;
assign o_pkt_vld     = o_pkt_vld_r;
assign o_pkt_sel     = o_pkt_sel_r;
assign o_pkt_last    = o_pkt_last_r;
assign o_rdy         = o_rdy_r;
assign o_done        = o_done_r;
assign o_err         = o_err_r;
assign o_gecerli     = o_gecerli_r;
assign o_aralik_hata = o_aralik_r;
assign mo_pkt_dat    = malu_pkt_dat_r;
assign mo_pkt_vld    = malu_pkt_vld_r;
assign mo_pkt_sel    = malu_pkt_sel_r;
assign mo_opc        = malu_opc_r;
assign mo_st         = malu_st_r;
assign to_pkt_dat    = trs_pkt_dat_r;
assign to_pkt_vld    = trs_pkt_vld_r;
assign to_pkt_sel    = trs_pkt_sel_r;
assign to_st         = trs_st_r;

// ── Giriş seçiciden BRAM slotuna eşleme ──────────────────────────────────
reg [3:0] giris_slot_w;
always @* begin
    case (i_pkt_sel)
        DIX_MODN: giris_slot_w = A_N;
        DIX_E:    giris_slot_w = A_E;
        DIX_R:    giris_slot_w = A_R;
        DIX_S:    giris_slot_w = A_S;
        default:  giris_slot_w = A_RX;
    endcase
end

// ── BRAM OKUMA ADRESİ (KOMBİNASYONEL) ────────────────────────────────────
//   Adres hem FETCH hem KULLANIM durumunda tutulur.
always @* begin
    case (state_r)
        ST_SENDP_RD, ST_SENDP_TX:  mem_ra_c = {A_N, mcnt_r};
        ST_TERS_NRD, ST_TERS_NTX:  mem_ra_c = {A_N, mcnt_r};
        ST_TERS_ARD, ST_TERS_ATX:  mem_ra_c = {A_SM, mcnt_r};
        ST_MA_ARD,   ST_MA_ATX:    mem_ra_c = {opid_a_r, mcnt_r};
        ST_MA_BRD,   ST_MA_BTX:    mem_ra_c = {opid_b_r, mcnt_r};
        ST_CMP_RA:                 mem_ra_c = {cmp_s1_r, cmp_idx_r};
        ST_CMP_RB:                 mem_ra_c = {cmp_s2_r, cmp_idx_r};
        ST_TX_RD,   ST_TX_U1:      mem_ra_c = {A_U1, pkt_tx_cnt_r};
        ST_TX2_RD,  ST_TX_U2:      mem_ra_c = {A_U2, pkt_tx_cnt_r};
        default:                   mem_ra_c = 7'd0;
    endcase
end

// ── BRAM YAZMA DENETİMİ (KOMBİNASYONEL) ──────────────────────────────────
always @* begin
    mem_we_c = 1'b0; mem_wa_c = 7'd0; mem_wd_c = 32'd0;
    if (state_r == ST_IDLE) begin
        if (i_pkt_vld && (i_pkt_sel <= DIX_RX)) begin
            mem_we_c = 1'b1;
            mem_wa_c = {giris_slot_w, pkt_rx_cnt_r};
            mem_wd_c = i_pkt_in;
        end
    end else if (state_r == ST_SENDP_TX) begin
        // mod n MALU'ya giderken (okuma portu) R2N sabiti de BRAM'e yazılır
        mem_we_c = 1'b1;
        mem_wa_c = {A_R2N, mcnt_r};
        mem_wd_c = R2N[mcnt_r*32 +: 32];
    end else if (state_r == ST_TERS_B) begin
        // mod_n_ters sonucu (w~) geldiği gibi A_W'ye yazılır
        if (ti_pkt_vld) begin
            mem_we_c = 1'b1;
            mem_wa_c = {A_W, trs_rx_cnt_r};
            mem_wd_c = ti_pkt_out;
        end
    end else if ((state_r == ST_MA_WT) || (state_r == ST_MA_RX)) begin
        if (mi_pkt_vld) begin
            mem_we_c = 1'b1;
            mem_wa_c = {opid_res_r, mcnt_r};
            mem_wd_c = mi_pkt_out;
        end
    end
end

always @(posedge clk_in or negedge rst_n) begin
    if (!rst_n) begin
        state_r <= ST_IDLE;
        opid_a_r<=A_S; opid_b_r<=A_R2N; opid_res_r<=A_SM;
        opc_r<=2'd0; mret_r<=6'd0; mcnt_r<=3'd0;
        ma_wdog_r<=12'd0; trs_wdog_r<=20'd0;
        pkt_rx_cnt_r<=3'd0; pkt_tx_cnt_r<=3'd0; trs_rx_cnt_r<=3'd0;
        r_nz_r<=1'b0; s_nz_r<=1'b0;
        cmp_s1_r<=A_R; cmp_s2_r<=A_N; cmp_v1_r<=32'd0;
        cmp_idx_r<=3'd7; cmp_kucuk_r<=1'b0; cmp_bitti_r<=1'b0;
        cmp_esit_r<=1'b0; cmp_ret_r<=6'd0;
        o_pkt_out_r<=32'd0; o_pkt_vld_r<=1'b0; o_pkt_sel_r<=1'b0;
        o_pkt_last_r<=1'b0; o_rdy_r<=1'b0; o_done_r<=1'b0; o_err_r<=1'b0;
        o_gecerli_r<=1'b0; o_aralik_r<=1'b0;
        malu_pkt_dat_r<=32'd0; malu_pkt_vld_r<=1'b0; malu_st_r<=1'b0;
        malu_pkt_sel_r<=2'd0; malu_opc_r<=2'd0;
        trs_pkt_dat_r<=32'd0; trs_pkt_vld_r<=1'b0; trs_st_r<=1'b0;
        trs_pkt_sel_r<=2'd0;
    end else begin
        o_pkt_vld_r<=1'b0; o_pkt_last_r<=1'b0; o_done_r<=1'b0; o_err_r<=1'b0;
        malu_st_r<=1'b0; malu_pkt_vld_r<=1'b0;
        trs_st_r<=1'b0; trs_pkt_vld_r<=1'b0;

        // Ters alma ciktisi yazma blogunda A_W'ye gidiyor; sayac burada
        if (ti_pkt_vld) trs_rx_cnt_r <= trs_rx_cnt_r + 3'd1;

        if (mi_err || ti_err) begin
            o_err_r<=1'b1; o_rdy_r<=1'b1; state_r<=ST_IDLE;
        end else begin
        case (state_r)

        ST_IDLE: begin
            o_rdy_r <= 1'b1;
            if (i_pkt_vld) begin
                // Veri BRAM'e yazma blogunda gidiyor; burada bayrak + sayac.
                // 256-bit "== 0" kontrolu yerine sozcuk sozcuk OR bayragi.
                if (i_pkt_sel == DIX_R)
                    r_nz_r <= (pkt_rx_cnt_r==3'd0) ? (i_pkt_in!=32'd0)
                                                   : (r_nz_r | (i_pkt_in!=32'd0));
                if (i_pkt_sel == DIX_S)
                    s_nz_r <= (pkt_rx_cnt_r==3'd0) ? (i_pkt_in!=32'd0)
                                                   : (s_nz_r | (i_pkt_in!=32'd0));
                pkt_rx_cnt_r <= pkt_rx_cnt_r + 3'd1;
            end
            if (i_start) begin
                o_rdy_r<=1'b0; o_aralik_r<=1'b0; o_gecerli_r<=1'b0;
                pkt_rx_cnt_r<=3'd0; mcnt_r<=3'd0; trs_rx_cnt_r<=3'd0;
                state_r<=ST_SENDP_RD;
            end
            // ASAMA 2 — Rx zaten yuklendi, hukum ver
            else if (i_hukum) begin
                o_rdy_r<=1'b0; pkt_rx_cnt_r<=3'd0;
                state_r<=ST_CMP_RX;
            end
        end

        // mod n MALU'ya gonderilir; ayni 8 cevrimde R2N sabiti BRAM'e yazilir
        ST_SENDP_RD: state_r <= ST_SENDP_TX;
        ST_SENDP_TX: begin
            malu_pkt_vld_r<=1'b1; malu_pkt_sel_r<=MSEL_P;
            malu_pkt_dat_r<=mem_rd_r;
            if (mcnt_r==3'd7) begin
                mcnt_r<=3'd0;
                cmp_s1_r<=A_R; cmp_s2_r<=A_N; cmp_idx_r<=3'd7;
                cmp_bitti_r<=1'b0; cmp_kucuk_r<=1'b0; cmp_esit_r<=1'b0;
                cmp_ret_r<=ST_CMP_S; state_r<=ST_CMP_RA;
            end else begin mcnt_r<=mcnt_r+3'd1; state_r<=ST_SENDP_RD; end
        end

        // FIPS 186-4 6.4.2 adim 1: r,s in [1,n-1]. ILK sirada sinanir;
        // aralik disi imza hesaba HIC girmeden reddedilir.
        //   BRAM boru hatti: RA slot1'i adresler, RB'de slot1 sozcugu hazir
        //   olur ve slot2 adreslenir, CK'da slot2 sozcugu hazir olur.
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
            // SABIT ZAMANLI: her zaman 8 sozcuk gezilir. Karar ilk farkta
            // verilir ama cmp_bitti_r ile kilitlenir; dongu KISALMAZ.
            if (cmp_idx_r==3'd0) begin
                // *** cmp_bitti_r TEK BASINA YETMEZ ***: fark SON sozcukte
                // bulunduysa cmp_bitti_r bu cevrimde henuz 0'dir (non-blocking
                // atama bir sonraki cevrimde gecerli olur). Bu yuzden son
                // sozcugun esitligi de burada ACIKCA kontrol edilmelidir;
                // aksi halde yalnizca son sozcugu farkli olan iki deger
                // yanlislikla ESIT sayilirdi.
                cmp_esit_r <= !cmp_bitti_r && (cmp_v1_r == mem_rd_r);
                state_r    <= cmp_ret_r;
            end else begin
                cmp_idx_r <= cmp_idx_r-3'd1;
                state_r   <= ST_CMP_RA;
            end
        end

        ST_CMP_S: begin
            // r kontrolunun sonucu simdi belli
            if (!cmp_kucuk_r || !r_nz_r) begin
                o_aralik_r<=1'b1; state_r<=ST_HATA;
            end else begin
                cmp_s1_r<=A_S; cmp_s2_r<=A_N; cmp_idx_r<=3'd7;
                cmp_bitti_r<=1'b0; cmp_kucuk_r<=1'b0; cmp_esit_r<=1'b0;
                cmp_ret_r<=ST_OP_SM; state_r<=ST_CMP_RA;
            end
        end

        // 1) s~ = MM(s, R2N)  -> A_SM
        ST_OP_SM: begin
            if (!cmp_kucuk_r || !s_nz_r) begin
                o_aralik_r<=1'b1; state_r<=ST_HATA;
            end else begin
                opid_a_r<=A_S; opid_b_r<=A_R2N; opid_res_r<=A_SM; opc_r<=MMUL;
                mret_r<=ST_TERS_NRD; mcnt_r<=3'd0; state_r<=ST_MA_ARD;
            end
        end

        // 2) w~ = mod_n_ters(s~)  — operandlar BRAM'den akitilir
        ST_TERS_NRD: state_r <= ST_TERS_NTX;
        ST_TERS_NTX: begin
            trs_pkt_vld_r<=1'b1; trs_pkt_sel_r<=2'd0;
            trs_pkt_dat_r<=mem_rd_r;
            if (mcnt_r==3'd7) begin mcnt_r<=3'd0; state_r<=ST_TERS_ARD; end
            else begin mcnt_r<=mcnt_r+3'd1; state_r<=ST_TERS_NRD; end
        end
        ST_TERS_ARD: state_r <= ST_TERS_ATX;
        ST_TERS_ATX: begin
            trs_pkt_vld_r<=1'b1; trs_pkt_sel_r<=2'd1;
            trs_pkt_dat_r<=mem_rd_r;
            if (mcnt_r==3'd7) begin
                trs_st_r<=1'b1; mcnt_r<=3'd0;
                trs_rx_cnt_r<=3'd0; trs_wdog_r<=20'd0;
                state_r<=ST_TERS_B;
            end else begin mcnt_r<=mcnt_r+3'd1; state_r<=ST_TERS_ARD; end
        end
        ST_TERS_B: begin
            if (trs_wdog_r>=TRS_WDOG_MAX) begin
                o_err_r<=1'b1; o_rdy_r<=1'b1; state_r<=ST_IDLE;
            end else if (ti_done) begin
                state_r<=ST_OP_U1;
            end else trs_wdog_r<=trs_wdog_r+20'd1;
        end

        // 3) u1 = MM(w~, e) → DUZ,  A_U1'e
        ST_OP_U1: begin
            opid_a_r<=A_W; opid_b_r<=A_E; opid_res_r<=A_U1; opc_r<=MMUL;
            mret_r<=ST_OP_U2; mcnt_r<=3'd0; state_r<=ST_MA_ARD;
        end
        // 4) u2 = MM(w~, r) → DUZ,  A_U2'ye
        ST_OP_U2: begin
            opid_a_r<=A_W; opid_b_r<=A_R; opid_res_r<=A_U2; opc_r<=MMUL;
            mret_r<=ST_TX_RD; mcnt_r<=3'd0; pkt_tx_cnt_r<=3'd0;
            state_r<=ST_MA_ARD;
        end

        // Cikis: u1 sonra u2, 8'er sozcuk (BRAM'den, RD/TX almasik)
        //   *** RD ve TX ALMAŞIK olmak ZORUNDA ***: BRAM 1 çevrim gecikmeli
        //   olduğu için her sözcük öncesi bir fetch adımı gerekir. TX kendi
        //   üstüne dönerse aynı sözcük tekrar okunur ve çıktı bir sözcük
        //   kayar (ilk koşumda tam bu görüldü).
        ST_TX_RD: state_r <= ST_TX_U1;
        ST_TX_U1: begin
            o_pkt_vld_r<=1'b1; o_pkt_sel_r<=1'b0;
            o_pkt_out_r<=mem_rd_r;
            o_pkt_last_r<=(pkt_tx_cnt_r==3'd7);
            if (pkt_tx_cnt_r==3'd7) begin pkt_tx_cnt_r<=3'd0; state_r<=ST_TX2_RD; end
            else begin pkt_tx_cnt_r<=pkt_tx_cnt_r+3'd1; state_r<=ST_TX_RD; end
        end
        ST_TX2_RD: state_r <= ST_TX_U2;
        ST_TX_U2: begin
            o_pkt_vld_r<=1'b1; o_pkt_sel_r<=1'b1;
            o_pkt_out_r<=mem_rd_r;
            o_pkt_last_r<=(pkt_tx_cnt_r==3'd7);
            if (pkt_tx_cnt_r==3'd7) begin pkt_tx_cnt_r<=3'd0; state_r<=ST_DONE1; end
            else begin pkt_tx_cnt_r<=pkt_tx_cnt_r+3'd1; state_r<=ST_TX2_RD; end
        end
        ST_DONE1: begin o_done_r<=1'b1; o_rdy_r<=1'b1; state_r<=ST_IDLE; end

        // ── ASAMA 2: v = Rx mod n, sonra v == r ─────────────────────────
        ST_CMP_RX: begin
            cmp_s1_r<=A_RX; cmp_s2_r<=A_N; cmp_idx_r<=3'd7;
            cmp_bitti_r<=1'b0; cmp_kucuk_r<=1'b0; cmp_esit_r<=1'b0;
            cmp_ret_r<=ST_RED_RX; state_r<=ST_CMP_RA;
        end

        // p < 2n oldugu icin TEK kosullu cikarma yeter (ecdsa_imza ile ayni)
        //   KOPYA YOK: Rx < n ise v zaten A_RX'tedir; degilse A_RES'te olur.
        ST_RED_RX: begin
            if (cmp_kucuk_r) begin
                // v = Rx  -> karsilastirmayi dogrudan A_RX ile yap
                cmp_s1_r<=A_RX; cmp_s2_r<=A_R; cmp_idx_r<=3'd7;
                cmp_bitti_r<=1'b0; cmp_kucuk_r<=1'b0; cmp_esit_r<=1'b0;
                cmp_ret_r<=ST_DONE2; state_r<=ST_CMP_RA;
            end else begin
                opid_a_r<=A_RX; opid_b_r<=A_N; opid_res_r<=A_RES; opc_r<=MSUB;
                mret_r<=ST_HUK_CMP; mcnt_r<=3'd0; state_r<=ST_MA_ARD;
            end
        end

        // v (A_RES'te) == r ?
        ST_HUK_CMP: begin
            cmp_s1_r<=A_RES; cmp_s2_r<=A_R; cmp_idx_r<=3'd7;
            cmp_bitti_r<=1'b0; cmp_kucuk_r<=1'b0; cmp_esit_r<=1'b0;
            cmp_ret_r<=ST_DONE2; state_r<=ST_CMP_RA;
        end

        ST_DONE2: begin
            o_gecerli_r <= cmp_esit_r;
            o_done_r<=1'b1; o_rdy_r<=1'b1; state_r<=ST_IDLE;
        end

        // Aralik reddi ARIZA DEGILDIR: donanim saglam, imza gecersiz.
        ST_HATA: begin
            o_gecerli_r<=1'b0; o_done_r<=1'b1; o_rdy_r<=1'b1; state_r<=ST_IDLE;
        end

        // ── MALU DISPATCH (operandlar BRAM'den, sonuc BRAM'e) ───────────
        //   ma_r / mb_r / mres_r ara yazmaclari TAMAMEN KALDIRILDI.
        ST_MA_ARD: state_r <= ST_MA_ATX;
        ST_MA_ATX: begin
            malu_pkt_vld_r<=1'b1; malu_pkt_sel_r<=MSEL_A; malu_opc_r<=opc_r;
            malu_pkt_dat_r<=mem_rd_r;
            if (mcnt_r==3'd7) begin mcnt_r<=3'd0; state_r<=ST_MA_BRD; end
            else begin mcnt_r<=mcnt_r+3'd1; state_r<=ST_MA_ARD; end
        end
        ST_MA_BRD: state_r <= ST_MA_BTX;
        ST_MA_BTX: begin
            malu_pkt_vld_r<=1'b1; malu_pkt_sel_r<=MSEL_B;
            malu_pkt_dat_r<=mem_rd_r;
            if (mcnt_r==3'd7) begin mcnt_r<=3'd0; state_r<=ST_MA_GO; end
            else begin mcnt_r<=mcnt_r+3'd1; state_r<=ST_MA_BRD; end
        end
        ST_MA_GO: begin
            malu_st_r<=1'b1; malu_opc_r<=opc_r;
            ma_wdog_r<=12'd0; mcnt_r<=3'd0; state_r<=ST_MA_WT;
        end
        ST_MA_WT: begin
            // Ilk sozcuk yazma blogunda BRAM'e gitti (mcnt_r = 0)
            if (ma_wdog_r>=MA_WDOG_MAX) begin
                o_err_r<=1'b1; o_rdy_r<=1'b1; state_r<=ST_IDLE;
            end else if (mi_pkt_vld) begin
                mcnt_r<=3'd1; state_r<=ST_MA_RX;
            end else ma_wdog_r<=ma_wdog_r+12'd1;
        end
        ST_MA_RX: begin
            if (mi_pkt_vld) begin
                if (mcnt_r==3'd7) begin mcnt_r<=3'd0; state_r<=ST_MA_WR; end
                else mcnt_r<=mcnt_r+3'd1;
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
