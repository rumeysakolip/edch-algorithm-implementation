// =============================================================================
// Modül   : ecdh_kex_top.v   (Uçtan uca ECDH KES; wire/reg ayrımı)
// Proje   : FPGA Tabanlı Güvenli Anahtar Yönetimi ve Kripto Hızlandırıcı
// No      : 5260007 — Sakarya Uygulamalı Bilimler Üniversitesi
// -----------------------------------------------------------------------------
// Açıklama:
//   NIST P-256 uçtan uca ECDH Anahtar Değişim Sistemi üst denetleyicisi.
//   Akış: TRNG'den d al → Qa=d·G (→Affin, çıkış) → Qb al → S=d·Qb (→Affin, çıkış).
//   Fonksiyon ve port arayüzü öncekiyle aynı. Bu sürümde WIRE/REG AYRIMI:
//   tüm çıkış portları saf 'wire'; senkron değerler dahili '*_r'de tutulup
//   portlara 'assign' ile aktarılır.
//
//   Hedef cihaz notu: 115 üst-seviye port, xq7a100t-cs324 (≥210 I/O) paketinde
//   yerleşir; port sayısı korunmuştur.
//
// Standart : Verilog-2001 — sentezlenebilir
// Tarih    : Temmuz 2026
// =============================================================================

`timescale 1ns / 1ps

(* keep_hierarchy = "yes" *)
module ecdh_kex_top (
    input  wire         clk_in,
    input  wire         rst_n,
    input  wire         i_start,
    output wire         o_trng_req,
    input  wire         i_trng_vld,
    input  wire [31:0]  i_trng_pkt,
    input  wire [31:0]  i_pkt_in,
    input  wire         i_pkt_vld,
    input  wire [1:0]   i_pkt_sel,
    input  wire         i_qb_start,
    output wire [31:0]  o_pkt_out,
    output wire         o_pkt_vld,
    output wire [1:0]   o_pkt_sel,
    output wire         o_pkt_last,
    output wire [1:0]   o_stage,
    output wire         o_qa_done,
    output wire         o_rdy,
    output wire         o_done,
    output wire         o_err
);

// ── P-256 sabitleri (Montgomery) ───────────────────────────────────────
localparam [255:0] P256    = 256'hffffffff00000001000000000000000000000000ffffffffffffffffffffffff;
localparam [255:0] R_MOD_P = 256'h00000000fffffffeffffffffffffffffffffffff000000000000000000000001;
localparam [255:0] GX_MONT = 256'h18905f76a53755c679fb732b7762251075ba95fc5fedb60179e730d418a9143c;
localparam [255:0] GY_MONT = 256'h8571ff1825885d85d2e88688dd21f3258b4ab8e4ba19e45cddf25357ce95560a;
localparam [255:0] GZ_MONT = R_MOD_P;

localparam [2:0] SIX_MODP=3'd0, SIX_SCALAR=3'd1, SIX_BX=3'd2, SIX_BY=3'd3, SIX_BZ=3'd4;
localparam [2:0] AIX_MODP=3'd0, AIX_X=3'd1, AIX_Y=3'd2, AIX_Z=3'd3;
localparam [1:0] QBIX_X=2'b00, QBIX_Y=2'b01;
localparam [1:0] STAGE_NONE=2'b00, STAGE_QA=2'b01, STAGE_SS=2'b10;

localparam [5:0]
    K_IDLE=6'd0, K_TRNG_REQ=6'd1, K_TRNG_RX=6'd2, K_TRNG_CHK=6'd3,
    K_QA_SETUP=6'd4, K_QA_AFF_SETUP=6'd5, K_QA_TX_X=6'd6, K_QA_TX_Y=6'd7, K_QA_DONE=6'd8,
    K_QB_WAIT=6'd9, K_QB_VALIDATE=6'd10,
    K_SS_SETUP=6'd11, K_SS_AFF_SETUP=6'd12, K_SS_TX_X=6'd13, K_SS_TX_Y=6'd14, K_SS_DONE=6'd15,
    K_SM_DMODP=6'd16, K_SM_DSCLR=6'd17, K_SM_DBX=6'd18, K_SM_DBY=6'd19, K_SM_DBZ=6'd20,
    K_SM_DGO=6'd21, K_SM_DWAIT_X=6'd22, K_SM_DRX_X=6'd23, K_SM_DRX_Y=6'd24, K_SM_DRX_Z=6'd25,
    K_AF_DMODP=6'd26, K_AF_DX=6'd27, K_AF_DY=6'd28, K_AF_DZ=6'd29,
    K_AF_DGO=6'd30, K_AF_DWAIT_X=6'd31, K_AF_DRX_X=6'd32, K_AF_DRX_Y=6'd33;

reg [5:0] state_r;

localparam [23:0] SM_WDOG_MAX  = 24'd12_000_000;
localparam [19:0] AFF_WDOG_MAX = 20'd1_000_000;
localparam [3:0]  RETRY_MAX    = 4'd8;

reg [255:0] d_r, bx_src_r, by_src_r, bz_src_r;
reg [255:0] rj_x_r, rj_y_r, rj_z_r, ax_src_r, ay_src_r, az_src_r;
reg [255:0] fa_x_r, fa_y_r, qb_x_r, qb_y_r;
reg [2:0]   trng_cnt_r, sm_cnt_r, aff_cnt_r, tx_cnt_r, qb_cnt_r;
reg [3:0]   retry_r;
reg [5:0]   sm_ret_r, aff_ret_r;
reg [23:0]  sm_wdog_r;
reg [19:0]  aff_wdog_r;

// ── Çıkış saklayıcıları → wire portlara assign ─────────────────────────
reg        o_trng_req_r;
reg [31:0] o_pkt_out_r;
reg        o_pkt_vld_r;
reg [1:0]  o_pkt_sel_r;
reg        o_pkt_last_r;
reg [1:0]  o_stage_r;
reg        o_qa_done_r, o_rdy_r, o_done_r, o_err_r;
assign o_trng_req = o_trng_req_r;
assign o_pkt_out  = o_pkt_out_r;
assign o_pkt_vld  = o_pkt_vld_r;
assign o_pkt_sel  = o_pkt_sel_r;
assign o_pkt_last = o_pkt_last_r;
assign o_stage    = o_stage_r;
assign o_qa_done  = o_qa_done_r;
assign o_rdy      = o_rdy_r;
assign o_done     = o_done_r;
assign o_err      = o_err_r;

// ── PAYLAŞILAN TEK MALU + SAHİPLİK ARBİTERİ ────────────────────────────
//   Skaler çarpım (SM) ve affine dönüşüm SIRALI çalışır → tek MALU yeterli.
//   owner_aff: top FSM affine dispatch/compute durumlarında (26..33) 1 olur.
//   Bu, iki modular_alu yerine tek örnek kullanarak DSP ve LUT tasarrufu sağlar.
wire owner_aff = (state_r >= K_AF_DMODP);   // K_AF_DMODP=26 .. K_AF_DRX_Y=33

wire [31:0] sm_mo_dat, aff_mo_dat;
wire        sm_mo_vld, aff_mo_vld;
wire [1:0]  sm_mo_sel, aff_mo_sel, sm_mo_opc, aff_mo_opc;
wire        sm_mo_st,  aff_mo_st;
wire [31:0] mal_out_w;
wire        mal_vld_w, mal_last_w, mal_rdy_w, mal_done_w, mal_err_w;

modular_alu shared_malu (
    .clk_in(clk_in), .rst_n(rst_n),
    .i_pkt_in (owner_aff ? aff_mo_dat : sm_mo_dat),
    .i_pkt_vld(owner_aff ? aff_mo_vld : sm_mo_vld),
    .i_pkt_sel(owner_aff ? aff_mo_sel : sm_mo_sel),
    .i_opcode (owner_aff ? aff_mo_opc : sm_mo_opc),
    .i_start  (owner_aff ? aff_mo_st  : sm_mo_st),
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
    .mo_pkt_dat(sm_mo_dat), .mo_pkt_vld(sm_mo_vld), .mo_pkt_sel(sm_mo_sel),
    .mo_opc(sm_mo_opc), .mo_st(sm_mo_st),
    .mi_pkt_out(mal_out_w), .mi_pkt_vld(mal_vld_w), .mi_pkt_last(mal_last_w),
    .mi_rdy(mal_rdy_w), .mi_done(mal_done_w), .mi_err(owner_aff ? 1'b0 : mal_err_w)
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
    .mi_rdy(mal_rdy_w), .mi_done(mal_done_w), .mi_err(owner_aff ? mal_err_w : 1'b0)
);

always @(posedge clk_in or negedge rst_n) begin
    if (!rst_n) begin
        state_r<=K_IDLE; o_trng_req_r<=1'b0;
        o_pkt_out_r<=32'd0; o_pkt_vld_r<=1'b0; o_pkt_sel_r<=2'd0; o_pkt_last_r<=1'b0;
        o_stage_r<=STAGE_NONE; o_qa_done_r<=1'b0; o_rdy_r<=1'b0; o_done_r<=1'b0; o_err_r<=1'b0;
        sm_pkt_vld_r<=1'b0; sm_pkt_dat_r<=32'd0; sm_pkt_sel_r<=3'd0; sm_st_r<=1'b0;
        aff_pkt_vld_r<=1'b0; aff_pkt_dat_r<=32'd0; aff_pkt_sel_r<=3'd0; aff_st_r<=1'b0;
        d_r<=256'd0; bx_src_r<=256'd0; by_src_r<=256'd0; bz_src_r<=256'd0;
        rj_x_r<=256'd0; rj_y_r<=256'd0; rj_z_r<=256'd0;
        ax_src_r<=256'd0; ay_src_r<=256'd0; az_src_r<=256'd0;
        fa_x_r<=256'd0; fa_y_r<=256'd0; qb_x_r<=256'd0; qb_y_r<=256'd0;
        trng_cnt_r<=3'd0; sm_cnt_r<=3'd0; aff_cnt_r<=3'd0; tx_cnt_r<=3'd0; qb_cnt_r<=3'd0;
        retry_r<=4'd0; sm_ret_r<=6'd0; aff_ret_r<=6'd0; sm_wdog_r<=24'd0; aff_wdog_r<=20'd0;
    end else begin
        o_pkt_vld_r<=1'b0; o_pkt_last_r<=1'b0; o_done_r<=1'b0; o_err_r<=1'b0; o_qa_done_r<=1'b0;
        sm_st_r<=1'b0; sm_pkt_vld_r<=1'b0; aff_st_r<=1'b0; aff_pkt_vld_r<=1'b0;

        if (sm_err_w || aff_err_w) begin
            o_err_r<=1'b1; o_rdy_r<=1'b1; o_trng_req_r<=1'b0; state_r<=K_IDLE;
        end else begin
        case (state_r)

            K_IDLE: begin
                o_rdy_r<=1'b1; o_stage_r<=STAGE_NONE;
                if (i_start) begin o_rdy_r<=1'b0; retry_r<=4'd0; trng_cnt_r<=3'd0; state_r<=K_TRNG_REQ; end
            end

            K_TRNG_REQ: begin o_trng_req_r<=1'b1; trng_cnt_r<=3'd0; state_r<=K_TRNG_RX; end

            K_TRNG_RX: begin
                o_trng_req_r<=1'b1;
                if (i_trng_vld) begin
                    d_r[trng_cnt_r*32 +: 32] <= i_trng_pkt;
                    if (trng_cnt_r==3'd7) begin trng_cnt_r<=3'd0; o_trng_req_r<=1'b0; state_r<=K_TRNG_CHK; end
                    else trng_cnt_r<=trng_cnt_r+3'd1;
                end
            end

            K_TRNG_CHK: begin
                o_trng_req_r<=1'b0;
                if (d_r==256'd0) begin
                    if (retry_r>=RETRY_MAX) begin o_err_r<=1'b1; o_rdy_r<=1'b1; state_r<=K_IDLE; end
                    else begin retry_r<=retry_r+4'd1; state_r<=K_TRNG_REQ; end
                end else state_r<=K_QA_SETUP;
            end

            K_QA_SETUP: begin
                bx_src_r<=GX_MONT; by_src_r<=GY_MONT; bz_src_r<=GZ_MONT;
                sm_ret_r<=K_QA_AFF_SETUP; sm_cnt_r<=3'd0; state_r<=K_SM_DMODP;
            end

            K_QA_AFF_SETUP: begin
                ax_src_r<=rj_x_r; ay_src_r<=rj_y_r; az_src_r<=rj_z_r;
                aff_ret_r<=K_QA_TX_X; aff_cnt_r<=3'd0; state_r<=K_AF_DMODP;
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

            K_QA_DONE: begin o_qa_done_r<=1'b1; o_rdy_r<=1'b1; qb_cnt_r<=3'd0; state_r<=K_QB_WAIT; end

            K_QB_WAIT: begin
                o_rdy_r<=1'b1;
                if (i_pkt_vld) begin
                    case (i_pkt_sel)
                        QBIX_X: qb_x_r[qb_cnt_r*32 +: 32]<=i_pkt_in;
                        QBIX_Y: qb_y_r[qb_cnt_r*32 +: 32]<=i_pkt_in;
                        default: ;
                    endcase
                    qb_cnt_r<=qb_cnt_r+3'd1;
                end
                if (i_qb_start) begin o_rdy_r<=1'b0; state_r<=K_QB_VALIDATE; end
            end

            K_QB_VALIDATE: begin
                if (qb_x_r==256'd0 && qb_y_r==256'd0) begin o_err_r<=1'b1; o_rdy_r<=1'b1; state_r<=K_IDLE; end
                else begin
                    bx_src_r<=qb_x_r; by_src_r<=qb_y_r; bz_src_r<=R_MOD_P;
                    sm_ret_r<=K_SS_AFF_SETUP; sm_cnt_r<=3'd0; state_r<=K_SM_DMODP;
                end
            end

            K_SS_AFF_SETUP: begin
                ax_src_r<=rj_x_r; ay_src_r<=rj_y_r; az_src_r<=rj_z_r;
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
                if (tx_cnt_r==3'd7) begin tx_cnt_r<=3'd0; state_r<=K_SS_DONE; end else tx_cnt_r<=tx_cnt_r+3'd1;
            end

            K_SS_DONE: begin o_done_r<=1'b1; o_rdy_r<=1'b1; state_r<=K_IDLE; end

            // ── SM dispatch ────────────────────────────────────────────
            K_SM_DMODP: begin sm_pkt_vld_r<=1'b1; sm_pkt_dat_r<=P256[sm_cnt_r*32 +: 32]; sm_pkt_sel_r<=SIX_MODP;
                if (sm_cnt_r==3'd7) begin sm_cnt_r<=3'd0; state_r<=K_SM_DSCLR; end else sm_cnt_r<=sm_cnt_r+3'd1; end
            K_SM_DSCLR: begin sm_pkt_vld_r<=1'b1; sm_pkt_dat_r<=d_r[sm_cnt_r*32 +: 32]; sm_pkt_sel_r<=SIX_SCALAR;
                if (sm_cnt_r==3'd7) begin sm_cnt_r<=3'd0; state_r<=K_SM_DBX; end else sm_cnt_r<=sm_cnt_r+3'd1; end
            K_SM_DBX: begin sm_pkt_vld_r<=1'b1; sm_pkt_dat_r<=bx_src_r[sm_cnt_r*32 +: 32]; sm_pkt_sel_r<=SIX_BX;
                if (sm_cnt_r==3'd7) begin sm_cnt_r<=3'd0; state_r<=K_SM_DBY; end else sm_cnt_r<=sm_cnt_r+3'd1; end
            K_SM_DBY: begin sm_pkt_vld_r<=1'b1; sm_pkt_dat_r<=by_src_r[sm_cnt_r*32 +: 32]; sm_pkt_sel_r<=SIX_BY;
                if (sm_cnt_r==3'd7) begin sm_cnt_r<=3'd0; state_r<=K_SM_DBZ; end else sm_cnt_r<=sm_cnt_r+3'd1; end
            K_SM_DBZ: begin sm_pkt_vld_r<=1'b1; sm_pkt_dat_r<=bz_src_r[sm_cnt_r*32 +: 32]; sm_pkt_sel_r<=SIX_BZ;
                if (sm_cnt_r==3'd7) begin sm_cnt_r<=3'd0; state_r<=K_SM_DGO; end else sm_cnt_r<=sm_cnt_r+3'd1; end
            K_SM_DGO: begin sm_st_r<=1'b1; sm_wdog_r<=24'd0; state_r<=K_SM_DWAIT_X; end
            K_SM_DWAIT_X: begin
                if (sm_wdog_r>=SM_WDOG_MAX) begin o_err_r<=1'b1; o_rdy_r<=1'b1; state_r<=K_IDLE; end
                else if (sm_pkt_vld_w && sm_pkt_sel_w==2'b00) begin rj_x_r[0 +: 32]<=sm_pkt_out_w; sm_cnt_r<=3'd1; state_r<=K_SM_DRX_X; end
                else sm_wdog_r<=sm_wdog_r+24'd1;
            end
            K_SM_DRX_X: begin if (sm_pkt_vld_w && sm_pkt_sel_w==2'b00) begin rj_x_r[sm_cnt_r*32 +: 32]<=sm_pkt_out_w;
                if (sm_cnt_r==3'd7) begin sm_cnt_r<=3'd0; state_r<=K_SM_DRX_Y; end else sm_cnt_r<=sm_cnt_r+3'd1; end end
            K_SM_DRX_Y: begin if (sm_pkt_vld_w && sm_pkt_sel_w==2'b01) begin rj_y_r[sm_cnt_r*32 +: 32]<=sm_pkt_out_w;
                if (sm_cnt_r==3'd7) begin sm_cnt_r<=3'd0; state_r<=K_SM_DRX_Z; end else sm_cnt_r<=sm_cnt_r+3'd1; end end
            K_SM_DRX_Z: begin if (sm_pkt_vld_w && sm_pkt_sel_w==2'b10) begin rj_z_r[sm_cnt_r*32 +: 32]<=sm_pkt_out_w;
                if (sm_cnt_r==3'd7) begin sm_cnt_r<=3'd0; state_r<=sm_ret_r; end else sm_cnt_r<=sm_cnt_r+3'd1; end end

            // ── Affine dispatch ────────────────────────────────────────
            K_AF_DMODP: begin aff_pkt_vld_r<=1'b1; aff_pkt_dat_r<=P256[aff_cnt_r*32 +: 32]; aff_pkt_sel_r<=AIX_MODP;
                if (aff_cnt_r==3'd7) begin aff_cnt_r<=3'd0; state_r<=K_AF_DX; end else aff_cnt_r<=aff_cnt_r+3'd1; end
            K_AF_DX: begin aff_pkt_vld_r<=1'b1; aff_pkt_dat_r<=ax_src_r[aff_cnt_r*32 +: 32]; aff_pkt_sel_r<=AIX_X;
                if (aff_cnt_r==3'd7) begin aff_cnt_r<=3'd0; state_r<=K_AF_DY; end else aff_cnt_r<=aff_cnt_r+3'd1; end
            K_AF_DY: begin aff_pkt_vld_r<=1'b1; aff_pkt_dat_r<=ay_src_r[aff_cnt_r*32 +: 32]; aff_pkt_sel_r<=AIX_Y;
                if (aff_cnt_r==3'd7) begin aff_cnt_r<=3'd0; state_r<=K_AF_DZ; end else aff_cnt_r<=aff_cnt_r+3'd1; end
            K_AF_DZ: begin aff_pkt_vld_r<=1'b1; aff_pkt_dat_r<=az_src_r[aff_cnt_r*32 +: 32]; aff_pkt_sel_r<=AIX_Z;
                if (aff_cnt_r==3'd7) begin aff_cnt_r<=3'd0; state_r<=K_AF_DGO; end else aff_cnt_r<=aff_cnt_r+3'd1; end
            K_AF_DGO: begin aff_st_r<=1'b1; aff_wdog_r<=20'd0; state_r<=K_AF_DWAIT_X; end
            K_AF_DWAIT_X: begin
                if (aff_wdog_r>=AFF_WDOG_MAX) begin o_err_r<=1'b1; o_rdy_r<=1'b1; state_r<=K_IDLE; end
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
