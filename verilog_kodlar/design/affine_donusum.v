// =============================================================================
// Modül   : affine_donusum.v   (32-bit sözcük-adresli BRAM + PAYLAŞILAN MALU)
// Proje   : FPGA Tabanlı Güvenli Anahtar Yönetimi ve Kripto Hızlandırıcı
// No      : 5260007 — Sakarya Uygulamalı Bilimler Üniversitesi
// -----------------------------------------------------------------------------
// Açıklama:
//   Jacobian (Montgomery) → Affin dönüşümü; Z^(-1) Fermat (Z^(p-2)) ile.
//   modular_alu İÇERİDE ÖRNEKLENMEZ; üst modülle paylaşılan tek MALU'ya
//   mo_*/mi_* master arayüzü üzerinden bağlanır.
//
// -----------------------------------------------------------------------------
// TEMMUZ 2026 — 32-BİT SÖZCÜK-ADRESLİ BRAM DÖNÜŞÜMÜ (Nihai Mimari, Adım 5)
//
//   ÖNCEKİ DURUM: Modül zaten BRAM kullanıyordu ama BELLEK 256 BİT GENİŞTİ
//   (ara_mem[0:15]). Değer bellekten 256 bit çıkıp `[mcnt_r*32 +: 32]` ile
//   dilimlendiği için part-select mux'ları OLDUĞU GİBİ duruyordu — LUT
//   kazancı gerçekleşmemişti (1210 LUT / 1632 FF, 7 part-select).
//
//   YAPILAN: Bellek 32 BİT GENİŞ, sözcük-adresli hâle getirildi.
//   Adres = {slot[3:0], sozcuk[2:0]} (128 sözcük, tek RAMB18).
//     - okuma mux'u YOK   : MALU'ya gidecek sözcük doğrudan BRAM'den okunur
//     - yazma çözücüsü YOK: MALU'dan gelen sözcük doğrudan BRAM'e yazılır
//   ELENEN 256-BİT YAZMAÇLAR (6 adet = 1536 FF):
//     mod_p_r  -> BRAM slot A_P       (girişte doğrudan sözcük sözcük yazılır)
//     asm_r    -> gereksiz            (giriş paketi artık biriktirilmiyor)
//     ma_r/mb_r-> gereksiz            (operandlar BRAM'den akıtılıyor)
//     mres_r   -> gereksiz            (sonuç geldiği gibi BRAM'e yazılıyor)
//     out_r    -> gereksiz            (çıkış BRAM'den akıtılıyor)
//
//   *** BRAM 1 ÇEVRİM GECİKMELİDİR — ADRES FETCH *VE* KULLANIM DURUMUNDA
//   TUTULMALIDIR. *** mem_rd_r her çevrim ara_mem[mem_ra_c]'den yenilenir;
//   adres yalnızca fetch çevriminde doğru verilip sonraki çevrimde
//   varsayılana dönerse okunan değer sessizce bozulur. (TB-19'da yakalanan
//   hata tam olarak buydu; burada baştan doğru yazıldı.)
//
//   ÇIKTI DEĞİŞMEZ: sonuç bit-birebir aynıdır; yalnızca depolama biçimi ve
//   transfer başına +1 çevrimlik fetch maliyeti eklenir (Fermat üslemesinin
//   ~256 MontMult'i yanında ihmal edilebilir).
//
// Standart : Verilog-2001 — sentezlenebilir
// Tarih    : Temmuz 2026
// =============================================================================

`timescale 1ns / 1ps

module affine_donusum (
    input  wire         clk_in,
    input  wire         rst_n,
    input  wire [31:0]  i_pkt_in,
    input  wire         i_pkt_vld,
    input  wire [2:0]   i_pkt_sel,
    input  wire         i_start,
    output wire [31:0]  o_pkt_out,
    output wire         o_pkt_vld,
    output wire [1:0]   o_pkt_sel,
    output wire         o_pkt_last,
    output wire         o_rdy,
    output wire         o_done,
    output wire         o_err,
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
    //   MONT_BIR (=R mod p) dışarıdan gelir; FERMAT_US (=p-2) modülüs p'den
    //   burada türetilir (ayrı bir sabit olarak TAŞINMAZ — tutarsız p/us
    //   çifti yüklenme riskini önler). Reset/varsayılan P-256'dır.
    input  wire [255:0] g_mont_bir,
    input  wire [255:0] g_p
);

wire [255:0] MONT_BIR  = g_mont_bir;
wire [255:0] FERMAT_US = g_p - 256'd2;
// Eski P-256 sabitleri (belge amaçlı):
//   MONT_BIR  = 256'h00000000fffffffeffffffffffffffffffffffff000000000000000000000001
//   FERMAT_US = 256'hffffffff00000001000000000000000000000000fffffffffffffffffffffffd

localparam [2:0] AIX_MODP=3'd0, AIX_X=3'd1, AIX_Y=3'd2, AIX_Z=3'd3;
localparam [1:0] MSEL_A=2'b00, MSEL_B=2'b01, MSEL_P=2'b10;
localparam [1:0] MMUL=2'b10;

// ── BRAM slot adresleri (her slot 8 x 32-bit sozcuk) ──────────────────────
localparam [3:0] A_P   =4'd0, A_XJ  =4'd1, A_YJ  =4'd2, A_ZJ  =4'd3,
                 A_ACC =4'd4, A_ZINV2=4'd5, A_ZINV3=4'd6,
                 A_XA  =4'd7, A_YA  =4'd8;

localparam [4:0]
    ST_IDLE=5'd0, ST_VALIDATE=5'd1,
    ST_SENDP_RD=5'd2, ST_SENDP_TX=5'd3, ST_INIT_ACC=5'd4,
    ST_EXP_SQ=5'd5, ST_EXP_SQ_COL=5'd6, ST_EXP_MUL=5'd7, ST_EXP_NEXT=5'd8,
    ST_ZINV2=5'd9, ST_ZINV3=5'd10, ST_XA=5'd11, ST_YA=5'd12,
    ST_OUT_RD=5'd13, ST_OUT_TX=5'd14, ST_DONE=5'd15,
    ST_MA_ARD=5'd16, ST_MA_ATX=5'd17, ST_MA_BRD=5'd18, ST_MA_BTX=5'd19,
    ST_MA_GO=5'd20, ST_MA_WT=5'd21, ST_MA_RX=5'd22, ST_MA_WR=5'd23;

reg [4:0] state_r;
localparam [11:0] MA_WDOG_MAX = 12'd4000;

// ── 32-bit genis Block RAM Scratchpad ─────────────────────────────────────
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

// ── Kayitcilar — 256-bit olanlarin TAMAMI elendi ─────────────────────────
reg         zj_nz_r;      // Z != 0 (girişte sözcük sözcük biriktirilir)
reg         modp_nz_r;    // mod p != 0 (mod_p_r yazmacinin yerine bayrak)
reg [8:0]   exp_idx_r;
reg [3:0]   opid_a_r, opid_b_r, opid_res_r;
reg [4:0]   mret_r;
reg [2:0]   mcnt_r;
reg [11:0]  ma_wdog_r;
reg [2:0]   pkt_rx_cnt_r, pkt_tx_cnt_r;
reg [1:0]   out_coord_r;

reg [31:0] o_pkt_out_r;
reg        o_pkt_vld_r;
reg [1:0]  o_pkt_sel_r;
reg        o_pkt_last_r, o_rdy_r, o_done_r, o_err_r;
assign o_pkt_out=o_pkt_out_r; assign o_pkt_vld=o_pkt_vld_r; assign o_pkt_sel=o_pkt_sel_r;
assign o_pkt_last=o_pkt_last_r; assign o_rdy=o_rdy_r; assign o_done=o_done_r; assign o_err=o_err_r;

// ── Paylaşılan MALU dış arayüzü (iç örnek YOK) ─────────────────────────
reg         malu_pkt_vld_r;
reg  [31:0] malu_pkt_dat_r;
reg  [1:0]  malu_pkt_sel_r;
reg  [1:0]  malu_opc_r;
reg         malu_st_r;
assign mo_pkt_dat=malu_pkt_dat_r; assign mo_pkt_vld=malu_pkt_vld_r;
assign mo_pkt_sel=malu_pkt_sel_r; assign mo_opc=malu_opc_r; assign mo_st=malu_st_r;
wire [31:0] malu_pkt_out_w  = mi_pkt_out;
wire        malu_pkt_vld_w  = mi_pkt_vld;
wire        malu_pkt_last_w = mi_pkt_last;
wire        malu_rdy_w      = mi_rdy;
wire        malu_done_w     = mi_done;
wire        malu_err_w      = mi_err;

wire us_biti_w = FERMAT_US[exp_idx_r[7:0]];

// Giris seciciden BRAM slotuna esleme
reg [3:0] giris_slot_w;
always @* begin
    case (i_pkt_sel)
        AIX_MODP: giris_slot_w = A_P;
        AIX_X:    giris_slot_w = A_XJ;
        AIX_Y:    giris_slot_w = A_YJ;
        default:  giris_slot_w = A_ZJ;
    endcase
end

// ── BRAM OKUMA ADRESI (KOMBINASYONEL) ─────────────────────────────────────
//   Adres hem FETCH hem KULLANIM durumunda tutulur (yukaridaki nota bak).
always @* begin
    case (state_r)
        ST_SENDP_RD, ST_SENDP_TX: mem_ra_c = {A_P, mcnt_r};
        ST_MA_ARD,   ST_MA_ATX:   mem_ra_c = {opid_a_r, mcnt_r};
        ST_MA_BRD,   ST_MA_BTX:   mem_ra_c = {opid_b_r, mcnt_r};
        ST_OUT_RD,   ST_OUT_TX:   mem_ra_c = {A_XA + {2'd0,out_coord_r}, pkt_tx_cnt_r};
        default:                  mem_ra_c = 7'd0;
    endcase
end

// ── BRAM YAZMA DENETIMI (KOMBINASYONEL) ──────────────────────────────────
always @* begin
    mem_we_c = 1'b0; mem_wa_c = 7'd0; mem_wd_c = 32'd0;
    if (state_r == ST_IDLE) begin
        // Giris paketi DOGRUDAN sozcuk olarak yazilir (asm_r biriktiricisi yok)
        if (i_pkt_vld) begin
            mem_we_c = 1'b1;
            mem_wa_c = {giris_slot_w, pkt_rx_cnt_r};
            mem_wd_c = i_pkt_in;
        end
    end else if (state_r == ST_INIT_ACC) begin
        // ACC = Montgomery bir  (sabit -> ucuz)
        mem_we_c = 1'b1;
        mem_wa_c = {A_ACC, mcnt_r};
        mem_wd_c = MONT_BIR[mcnt_r*32 +: 32];
    end else if ((state_r == ST_MA_WT) || (state_r == ST_MA_RX)) begin
        // MALU sonucu geldigi gibi hedef slota yazilir (mres_r yok)
        if (malu_pkt_vld_w) begin
            mem_we_c = 1'b1;
            mem_wa_c = {opid_res_r, mcnt_r};
            mem_wd_c = malu_pkt_out_w;
        end
    end
end

always @(posedge clk_in or negedge rst_n) begin
    if (!rst_n) begin
        state_r<=ST_IDLE;
        o_rdy_r<=1'b0; o_done_r<=1'b0; o_pkt_vld_r<=1'b0; o_err_r<=1'b0;
        o_pkt_out_r<=32'd0; o_pkt_sel_r<=2'd0; o_pkt_last_r<=1'b0;
        malu_pkt_vld_r<=1'b0; malu_pkt_dat_r<=32'd0; malu_pkt_sel_r<=2'd0;
        malu_opc_r<=2'd0; malu_st_r<=1'b0;
        zj_nz_r<=1'b0; modp_nz_r<=1'b0; exp_idx_r<=9'd255;
        opid_a_r<=4'd0; opid_b_r<=4'd0; opid_res_r<=4'd0; mret_r<=5'd0;
        mcnt_r<=3'd0; ma_wdog_r<=12'd0;
        pkt_rx_cnt_r<=3'd0; pkt_tx_cnt_r<=3'd0;
        out_coord_r<=2'd0;
    end else begin
        o_done_r<=1'b0; o_pkt_vld_r<=1'b0; o_pkt_last_r<=1'b0; o_err_r<=1'b0;
        malu_st_r<=1'b0; malu_pkt_vld_r<=1'b0;

        if (malu_err_w) begin
            o_err_r<=1'b1; o_rdy_r<=1'b1; state_r<=ST_IDLE;
        end else begin
        case (state_r)

            ST_IDLE: begin
                o_rdy_r <= 1'b1;
                if (i_pkt_vld) begin
                    // Veri BRAM'e yazma blogunda gidiyor; burada yalnizca
                    // sifirdan-farklilik bayraklari ve sayac tutulur.
                    if (i_pkt_sel == AIX_MODP)
                        modp_nz_r <= (pkt_rx_cnt_r==3'd0) ? (i_pkt_in!=32'd0)
                                                          : (modp_nz_r | (i_pkt_in!=32'd0));
                    if (i_pkt_sel == AIX_Z)
                        zj_nz_r <= (pkt_rx_cnt_r==3'd0) ? (i_pkt_in!=32'd0)
                                                        : (zj_nz_r | (i_pkt_in!=32'd0));
                    pkt_rx_cnt_r <= pkt_rx_cnt_r + 3'd1;
                end
                if (i_start) begin o_rdy_r<=1'b0; state_r<=ST_VALIDATE; end
            end

            ST_VALIDATE: begin
                // mod_p_r == 0 kontrolu, modp_nz_r bayragiyla ayni anlama gelir
                if (!modp_nz_r) begin o_err_r<=1'b1; o_rdy_r<=1'b1; state_r<=ST_IDLE; end
                else if (!zj_nz_r) begin o_err_r<=1'b1; o_rdy_r<=1'b1; state_r<=ST_IDLE; end
                else begin mcnt_r<=3'd0; state_r<=ST_SENDP_RD; end
            end

            // ── mod p'yi MALU'ya gonder (BRAM'den) ───────────────────────
            ST_SENDP_RD: state_r <= ST_SENDP_TX;
            ST_SENDP_TX: begin
                malu_pkt_vld_r <= 1'b1;
                malu_pkt_dat_r <= mem_rd_r;
                malu_pkt_sel_r <= MSEL_P;
                if (mcnt_r == 3'd7) begin mcnt_r<=3'd0; state_r<=ST_INIT_ACC; end
                else begin mcnt_r <= mcnt_r + 3'd1; state_r<=ST_SENDP_RD; end
            end

            // ── ACC = 1 (Montgomery) — 8 sozcuk yazilir ─────────────────
            ST_INIT_ACC: begin
                if (mcnt_r == 3'd7) begin
                    mcnt_r<=3'd0; exp_idx_r<=9'd255; state_r<=ST_EXP_SQ;
                end else mcnt_r <= mcnt_r + 3'd1;
            end

            // ── Fermat uslemesi: ACC = Z^(p-2) ─────────────────────────
            ST_EXP_SQ: begin
                opid_a_r<=A_ACC; opid_b_r<=A_ACC; opid_res_r<=A_ACC;
                malu_opc_r<=MMUL; mret_r<=ST_EXP_SQ_COL;
                mcnt_r<=3'd0; state_r<=ST_MA_ARD;
            end
            ST_EXP_SQ_COL: begin
                if (us_biti_w) state_r<=ST_EXP_MUL; else state_r<=ST_EXP_NEXT;
            end
            ST_EXP_MUL: begin
                opid_a_r<=A_ACC; opid_b_r<=A_ZJ; opid_res_r<=A_ACC;
                malu_opc_r<=MMUL; mret_r<=ST_EXP_NEXT;
                mcnt_r<=3'd0; state_r<=ST_MA_ARD;
            end
            ST_EXP_NEXT: begin
                if (exp_idx_r == 9'd0) state_r<=ST_ZINV2;
                else begin exp_idx_r<=exp_idx_r-9'd1; state_r<=ST_EXP_SQ; end
            end

            ST_ZINV2: begin
                opid_a_r<=A_ACC; opid_b_r<=A_ACC; opid_res_r<=A_ZINV2;
                malu_opc_r<=MMUL; mret_r<=ST_ZINV3;
                mcnt_r<=3'd0; state_r<=ST_MA_ARD;
            end
            ST_ZINV3: begin
                opid_a_r<=A_ZINV2; opid_b_r<=A_ACC; opid_res_r<=A_ZINV3;
                malu_opc_r<=MMUL; mret_r<=ST_XA;
                mcnt_r<=3'd0; state_r<=ST_MA_ARD;
            end
            ST_XA: begin
                opid_a_r<=A_XJ; opid_b_r<=A_ZINV2; opid_res_r<=A_XA;
                malu_opc_r<=MMUL; mret_r<=ST_YA;
                mcnt_r<=3'd0; state_r<=ST_MA_ARD;
            end
            ST_YA: begin
                opid_a_r<=A_YJ; opid_b_r<=A_ZINV3; opid_res_r<=A_YA;
                malu_opc_r<=MMUL; mret_r<=ST_OUT_RD;
                mcnt_r<=3'd0; out_coord_r<=2'd0; pkt_tx_cnt_r<=3'd0;
                state_r<=ST_MA_ARD;
            end

            // ── Cikis: Xa sonra Ya, 8'er sozcuk (BRAM'den) ─────────────
            ST_OUT_RD: state_r <= ST_OUT_TX;
            ST_OUT_TX: begin
                o_pkt_vld_r  <= 1'b1;
                o_pkt_sel_r  <= out_coord_r;
                o_pkt_out_r  <= mem_rd_r;
                o_pkt_last_r <= (pkt_tx_cnt_r == 3'd7);
                if (pkt_tx_cnt_r == 3'd7) begin
                    pkt_tx_cnt_r <= 3'd0;
                    if (out_coord_r == 2'd1) state_r<=ST_DONE;
                    else begin out_coord_r<=2'd1; state_r<=ST_OUT_RD; end
                end else begin
                    pkt_tx_cnt_r <= pkt_tx_cnt_r + 3'd1;
                    state_r <= ST_OUT_RD;
                end
            end

            ST_DONE: begin o_done_r<=1'b1; o_rdy_r<=1'b1; state_r<=ST_IDLE; end

            // ── Paylasilan MALU dispatch (operandlar BRAM'den akitilir) ──
            //   ma_r / mb_r / mres_r ara yazmaclari TAMAMEN KALDIRILDI.
            ST_MA_ARD: state_r <= ST_MA_ATX;
            ST_MA_ATX: begin
                malu_pkt_vld_r<=1'b1; malu_pkt_dat_r<=mem_rd_r;
                malu_pkt_sel_r<=MSEL_A; malu_opc_r<=MMUL;
                if (mcnt_r==3'd7) begin mcnt_r<=3'd0; state_r<=ST_MA_BRD; end
                else begin mcnt_r<=mcnt_r+3'd1; state_r<=ST_MA_ARD; end
            end
            ST_MA_BRD: state_r <= ST_MA_BTX;
            ST_MA_BTX: begin
                malu_pkt_vld_r<=1'b1; malu_pkt_dat_r<=mem_rd_r;
                malu_pkt_sel_r<=MSEL_B;
                if (mcnt_r==3'd7) begin mcnt_r<=3'd0; state_r<=ST_MA_GO; end
                else begin mcnt_r<=mcnt_r+3'd1; state_r<=ST_MA_BRD; end
            end
            ST_MA_GO: begin
                malu_st_r<=1'b1; malu_opc_r<=MMUL; ma_wdog_r<=12'd0;
                mcnt_r<=3'd0; state_r<=ST_MA_WT;
            end
            ST_MA_WT: begin
                // Ilk sozcuk yazma blogunda BRAM'e gitti (mcnt_r = 0)
                if (ma_wdog_r >= MA_WDOG_MAX) begin
                    o_err_r<=1'b1; o_rdy_r<=1'b1; state_r<=ST_IDLE;
                end else if (malu_pkt_vld_w) begin
                    mcnt_r<=3'd1; state_r<=ST_MA_RX;
                end else ma_wdog_r<=ma_wdog_r+12'd1;
            end
            ST_MA_RX: begin
                if (malu_pkt_vld_w) begin
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
