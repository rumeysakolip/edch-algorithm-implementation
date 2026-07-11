// =============================================================================
// Modül   : affine_donusum.v   (BRAM scratchpad + wire/reg + PAYLAŞILAN MALU)
// Proje   : FPGA Tabanlı Güvenli Anahtar Yönetimi ve Kripto Hızlandırıcı
// No      : 5260007 — Sakarya Uygulamalı Bilimler Üniversitesi
// -----------------------------------------------------------------------------
// Açıklama:
//   Jacobian (Montgomery) → Affin dönüşümü; Z^(-1) Fermat (Z^(p-2)) ile.
//   Bu sürümde modular_alu ARTIK İÇERİDE ÖRNEKLENMEZ; üst modülle paylaşılan
//   tek MALU'ya mo_*/mi_* master arayüzü üzerinden bağlanır (alan tasarrufu:
//   skaler çarpım ve affine sıralı çalıştığından tek MALU yeterlidir).
//   BRAM scratchpad ve wire/reg ayrımı korunmuştur.
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
    input  wire         mi_err
);

localparam [255:0] MONT_BIR  =
    256'h00000000fffffffeffffffffffffffffffffffff000000000000000000000001;
localparam [255:0] FERMAT_US =
    256'hffffffff00000001000000000000000000000000fffffffffffffffffffffffd;

localparam [2:0] AIX_MODP=3'd0, AIX_X=3'd1, AIX_Y=3'd2, AIX_Z=3'd3;
localparam [1:0] MSEL_A=2'b00, MSEL_B=2'b01, MSEL_P=2'b10;
localparam [1:0] MMUL=2'b10;

localparam [3:0] A_XJ=4'd1, A_YJ=4'd2, A_ZJ=4'd3, A_ACC=4'd4,
                 A_ZINV2=4'd5, A_ZINV3=4'd6, A_XA=4'd7, A_YA=4'd8;

localparam [4:0]
    ST_IDLE=5'd0, ST_VALIDATE=5'd1, ST_SEND_P=5'd2, ST_INIT_ACC=5'd3,
    ST_EXP_SQ=5'd4, ST_EXP_SQ_COL=5'd5, ST_EXP_MUL=5'd6, ST_EXP_NEXT=5'd7,
    ST_ZINV2=5'd8, ST_ZINV3=5'd9, ST_XA=5'd10, ST_YA=5'd11,
    ST_OUT_RA=5'd12, ST_OUT_LAT=5'd13, ST_OUT_TX=5'd14, ST_DONE=5'd15,
    ST_MA_RA=5'd16, ST_MA_LA=5'd17, ST_MA_LB=5'd18, ST_MA_TXA=5'd19,
    ST_MA_TXB=5'd20, ST_MA_GO=5'd21, ST_MA_WT=5'd22, ST_MA_RX=5'd23, ST_MA_WR=5'd24;

reg [4:0] state_r;
localparam [11:0] MA_WDOG_MAX = 12'd4000;

// ── Block RAM Scratchpad ───────────────────────────────────────────────
(* ram_style = "block" *) reg [255:0] ara_mem [0:15];
reg [255:0] mem_rd_r;
reg [3:0]   mem_ra_c;
reg         mem_we_c;
reg [3:0]   mem_wa_c;
reg [255:0] mem_wd_c;
always @(posedge clk_in) begin
    if (mem_we_c) ara_mem[mem_wa_c] <= mem_wd_c;
    mem_rd_r <= ara_mem[mem_ra_c];
end

reg [255:0] mod_p_r, asm_r;
reg         zj_nz_r;
reg [8:0]   exp_idx_r;
reg [255:0] ma_r, mb_r, mres_r;
reg [3:0]   opid_a_r, opid_b_r, opid_res_r;
reg [4:0]   mret_r;
reg [2:0]   mcnt_r;
reg [11:0]  ma_wdog_r;
reg [2:0]   pkt_rx_cnt_r, pkt_tx_cnt_r;
reg [255:0] out_r;
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

reg [3:0] slot_w;
always @* begin
    case (i_pkt_sel)
        AIX_X: slot_w=A_XJ; AIX_Y: slot_w=A_YJ; AIX_Z: slot_w=A_ZJ;
        default: slot_w=A_XJ;
    endcase
end

// ── BRAM okuma adresi / yazma denetimi (KOMBİNASYONEL) ─────────────────
always @* begin
    case (state_r)
        ST_MA_RA:  mem_ra_c = opid_a_r;
        ST_MA_LA:  mem_ra_c = opid_b_r;
        ST_OUT_RA: mem_ra_c = A_XA + {2'd0, out_coord_r};
        default:   mem_ra_c = 4'd0;
    endcase
    mem_we_c = 1'b0; mem_wa_c = 4'd0; mem_wd_c = 256'd0;
    if (state_r == ST_IDLE) begin
        if (i_pkt_vld && (i_pkt_sel != AIX_MODP) && (pkt_rx_cnt_r == 3'd7)) begin
            mem_we_c = 1'b1; mem_wa_c = slot_w; mem_wd_c = {i_pkt_in, asm_r[223:0]};
        end
    end else if (state_r == ST_INIT_ACC) begin
        mem_we_c = 1'b1; mem_wa_c = A_ACC; mem_wd_c = MONT_BIR;
    end else if (state_r == ST_MA_WR) begin
        mem_we_c = 1'b1; mem_wa_c = opid_res_r; mem_wd_c = mres_r;
    end
end

always @(posedge clk_in or negedge rst_n) begin
    if (!rst_n) begin
        state_r<=ST_IDLE;
        o_rdy_r<=1'b0; o_done_r<=1'b0; o_pkt_vld_r<=1'b0; o_err_r<=1'b0;
        o_pkt_out_r<=32'd0; o_pkt_sel_r<=2'd0; o_pkt_last_r<=1'b0;
        malu_pkt_vld_r<=1'b0; malu_pkt_dat_r<=32'd0; malu_pkt_sel_r<=2'd0;
        malu_opc_r<=2'd0; malu_st_r<=1'b0;
        mod_p_r<=256'd0; asm_r<=256'd0; zj_nz_r<=1'b0; exp_idx_r<=9'd255;
        ma_r<=256'd0; mb_r<=256'd0; mres_r<=256'd0;
        opid_a_r<=4'd0; opid_b_r<=4'd0; opid_res_r<=4'd0; mret_r<=5'd0;
        mcnt_r<=3'd0; ma_wdog_r<=12'd0;
        pkt_rx_cnt_r<=3'd0; pkt_tx_cnt_r<=3'd0;
        out_r<=256'd0; out_coord_r<=2'd0;
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
                    if (i_pkt_sel == AIX_MODP)
                        mod_p_r[pkt_rx_cnt_r*32 +: 32] <= i_pkt_in;
                    else
                        asm_r[pkt_rx_cnt_r*32 +: 32] <= i_pkt_in;
                    if (i_pkt_sel == AIX_Z)
                        zj_nz_r <= (pkt_rx_cnt_r==3'd0) ? (i_pkt_in!=32'd0)
                                                        : (zj_nz_r | (i_pkt_in!=32'd0));
                    pkt_rx_cnt_r <= pkt_rx_cnt_r + 3'd1;
                end
                if (i_start) begin o_rdy_r<=1'b0; state_r<=ST_VALIDATE; end
            end

            ST_VALIDATE: begin
                if (mod_p_r == 256'd0) begin o_err_r<=1'b1; o_rdy_r<=1'b1; state_r<=ST_IDLE; end
                else if (!zj_nz_r)     begin o_err_r<=1'b1; o_rdy_r<=1'b1; state_r<=ST_IDLE; end
                else begin mcnt_r<=3'd0; state_r<=ST_SEND_P; end
            end

            ST_SEND_P: begin
                malu_pkt_vld_r <= 1'b1;
                malu_pkt_dat_r <= mod_p_r[mcnt_r*32 +: 32];
                malu_pkt_sel_r <= MSEL_P;
                if (mcnt_r == 3'd7) begin mcnt_r<=3'd0; state_r<=ST_INIT_ACC; end
                else mcnt_r <= mcnt_r + 3'd1;
            end

            ST_INIT_ACC: begin exp_idx_r<=9'd255; state_r<=ST_EXP_SQ; end

            ST_EXP_SQ: begin
                opid_a_r<=A_ACC; opid_b_r<=A_ACC; opid_res_r<=A_ACC;
                malu_opc_r<=MMUL; mret_r<=ST_EXP_SQ_COL; state_r<=ST_MA_RA;
            end
            ST_EXP_SQ_COL: begin
                if (us_biti_w) state_r<=ST_EXP_MUL; else state_r<=ST_EXP_NEXT;
            end
            ST_EXP_MUL: begin
                opid_a_r<=A_ACC; opid_b_r<=A_ZJ; opid_res_r<=A_ACC;
                malu_opc_r<=MMUL; mret_r<=ST_EXP_NEXT; state_r<=ST_MA_RA;
            end
            ST_EXP_NEXT: begin
                if (exp_idx_r == 9'd0) state_r<=ST_ZINV2;
                else begin exp_idx_r<=exp_idx_r-9'd1; state_r<=ST_EXP_SQ; end
            end

            ST_ZINV2: begin
                opid_a_r<=A_ACC; opid_b_r<=A_ACC; opid_res_r<=A_ZINV2;
                malu_opc_r<=MMUL; mret_r<=ST_ZINV3; state_r<=ST_MA_RA;
            end
            ST_ZINV3: begin
                opid_a_r<=A_ZINV2; opid_b_r<=A_ACC; opid_res_r<=A_ZINV3;
                malu_opc_r<=MMUL; mret_r<=ST_XA; state_r<=ST_MA_RA;
            end
            ST_XA: begin
                opid_a_r<=A_XJ; opid_b_r<=A_ZINV2; opid_res_r<=A_XA;
                malu_opc_r<=MMUL; mret_r<=ST_YA; state_r<=ST_MA_RA;
            end
            ST_YA: begin
                opid_a_r<=A_YJ; opid_b_r<=A_ZINV3; opid_res_r<=A_YA;
                malu_opc_r<=MMUL; mret_r<=ST_OUT_RA; state_r<=ST_MA_RA;
                out_coord_r<=2'd0;
            end

            ST_OUT_RA:  state_r <= ST_OUT_LAT;
            ST_OUT_LAT: begin out_r<=mem_rd_r; pkt_tx_cnt_r<=3'd0; state_r<=ST_OUT_TX; end
            ST_OUT_TX: begin
                o_pkt_vld_r  <= 1'b1;
                o_pkt_sel_r  <= out_coord_r;
                o_pkt_out_r  <= out_r[pkt_tx_cnt_r*32 +: 32];
                o_pkt_last_r <= (pkt_tx_cnt_r == 3'd7);
                if (pkt_tx_cnt_r == 3'd7) begin
                    if (out_coord_r == 2'd1) state_r<=ST_DONE;
                    else begin out_coord_r<=2'd1; state_r<=ST_OUT_RA; end
                end else pkt_tx_cnt_r <= pkt_tx_cnt_r + 3'd1;
            end

            ST_DONE: begin o_done_r<=1'b1; o_rdy_r<=1'b1; state_r<=ST_IDLE; end

            // ── Paylaşılan MALU dispatch (BRAM operandlı) ────────────────
            ST_MA_RA: state_r <= ST_MA_LA;
            ST_MA_LA: begin ma_r<=mem_rd_r; state_r<=ST_MA_LB; end
            ST_MA_LB: begin mb_r<=mem_rd_r; mcnt_r<=3'd0; state_r<=ST_MA_TXA; end
            ST_MA_TXA: begin
                malu_pkt_vld_r<=1'b1; malu_pkt_dat_r<=ma_r[mcnt_r*32 +: 32];
                malu_pkt_sel_r<=MSEL_A; malu_opc_r<=MMUL;
                if (mcnt_r==3'd7) begin mcnt_r<=3'd0; state_r<=ST_MA_TXB; end
                else mcnt_r<=mcnt_r+3'd1;
            end
            ST_MA_TXB: begin
                malu_pkt_vld_r<=1'b1; malu_pkt_dat_r<=mb_r[mcnt_r*32 +: 32];
                malu_pkt_sel_r<=MSEL_B;
                if (mcnt_r==3'd7) begin mcnt_r<=3'd0; state_r<=ST_MA_GO; end
                else mcnt_r<=mcnt_r+3'd1;
            end
            ST_MA_GO: begin
                malu_st_r<=1'b1; malu_opc_r<=MMUL; ma_wdog_r<=12'd0; state_r<=ST_MA_WT;
            end
            ST_MA_WT: begin
                if (ma_wdog_r >= MA_WDOG_MAX) begin o_err_r<=1'b1; o_rdy_r<=1'b1; state_r<=ST_IDLE; end
                else if (malu_pkt_vld_w) begin
                    mres_r[0 +: 32]<=malu_pkt_out_w; mcnt_r<=3'd1; state_r<=ST_MA_RX;
                end else ma_wdog_r<=ma_wdog_r+12'd1;
            end
            ST_MA_RX: begin
                if (malu_pkt_vld_w) begin
                    mres_r[mcnt_r*32 +: 32]<=malu_pkt_out_w;
                    if (mcnt_r==3'd7) begin mcnt_r<=3'd0; state_r<=ST_MA_WR; end
                    else mcnt_r<=mcnt_r+3'd1;
                end
            end
            ST_MA_WR: state_r <= mret_r;

            default: state_r <= ST_IDLE;
        endcase
        end
    end
end

endmodule
