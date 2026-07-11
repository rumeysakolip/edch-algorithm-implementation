// =============================================================================
// Modül   : modular_alu.v   (DSP48E1 CIOS + wire/reg ayrımı)
// Proje   : FPGA Tabanlı Güvenli Anahtar Yönetimi ve Kripto Hızlandırıcı
// No      : 5260007 — Sakarya Uygulamalı Bilimler Üniversitesi
// -----------------------------------------------------------------------------
// Açıklama:
//   modular_alu biriminin DSP48E1 hızlandırmalı (word-tabanlı CIOS Montgomery)
//   sürümü. Port arayüzü ve dış davranış orijinal modular_alu ile birebir aynı.
//   16×16 çarpma-biriktirme hatları (* use_dsp *) ile DSP48E1'e yönlendirilir.
//
//   BU SÜRÜMDE EKLENEN: WIRE/REG AYRIMI — tüm çıkış portları saf 'wire'; senkron
//   değerler dahili '*_r'de tutulup portlara 'assign' ile aktarılır.
//
//   BRAM NOTU: CIOS akümülatörü t_r[0:17] yalnızca 18×16=288 bittir. Bu boyut
//   tek bir RAMB18 (18Kb) tile'ını verimli dolduramaz; ram_style="block"
//   zorlaması sentez uyarısı üretir ve dağıtık kalır. Bu nedenle t_r bilinçli
//   olarak dağıtık (LUT/FF) bırakıldı; BRAM kazancı, PAU ve affine_donusum'daki
//   büyük 256-bit ara saklayıcı bankalarında gerçekleştirilmiştir.
//
//   MATEMATİK: n0inv = -n[0]^(-1) mod 2^16; P-256 için n[0]=0xffff ⇒ N0INV=1.
//   MM(A,B) = A·B·R^(-1) mod P, R = 2^256. Sonuç radix-2 ile bit-birebir aynı.
//
// Standart : Verilog-2001 — sentezlenebilir
// Tarih    : Temmuz 2026
// =============================================================================

`timescale 1ns / 1ps

(* keep_hierarchy = "yes" *)
module modular_alu (
    input  wire         clk_in,
    input  wire         rst_n,
    input  wire [31:0]  i_pkt_in,
    input  wire         i_pkt_vld,
    input  wire [1:0]   i_pkt_sel,
    input  wire [1:0]   i_opcode,
    input  wire         i_start,
    output wire [31:0]  o_pkt_out,
    output wire         o_pkt_vld,
    output wire         o_pkt_last,
    output wire         o_rdy,
    output wire         o_done,
    output wire         o_err
);

localparam [1:0] SEL_A=2'b00, SEL_B=2'b01, SEL_P=2'b10;

localparam [3:0]
    ST_IDLE=4'd0, ST_MUL=4'd1, ST_MUL_FIN=4'd2, ST_RED_M=4'd3,
    ST_RED_FIRST=4'd4, ST_RED=4'd5, ST_RED_FIN=4'd6, ST_FINAL=4'd7, ST_TX=4'd8;

reg [3:0] state_r;

localparam [15:0] N0INV = 16'd1;
localparam [11:0] WDOG_MAX = 12'd3000;

reg [255:0] op_a_r, op_b_r, mod_p_r, result_r;
reg [15:0]  t_r [0:17];
reg [4:0]   i_idx_r, j_idx_r;
reg [15:0]  carry_r, m_r;
reg [2:0]   pkt_rx_cnt_r, pkt_tx_cnt_r;
reg [11:0]  wdog_r;
integer k;

// ── Çıkış saklayıcıları → wire portlara assign ─────────────────────────
reg [31:0] o_pkt_out_r;
reg        o_pkt_vld_r, o_pkt_last_r, o_rdy_r, o_done_r, o_err_r;
assign o_pkt_out  = o_pkt_out_r;
assign o_pkt_vld  = o_pkt_vld_r;
assign o_pkt_last = o_pkt_last_r;
assign o_rdy      = o_rdy_r;
assign o_done     = o_done_r;
assign o_err      = o_err_r;

// ── ModAdd / ModSub (fabric) ───────────────────────────────────────────
wire [256:0] toplam_ham_w = {1'b0, op_a_r} + {1'b0, op_b_r};
wire [255:0] toplam_mod_w = (toplam_ham_w >= {1'b0, mod_p_r})
                            ? toplam_ham_w[255:0] - mod_p_r : toplam_ham_w[255:0];
wire [255:0] fark_mod_w   = (op_a_r >= op_b_r)
                            ? op_a_r - op_b_r : op_a_r - op_b_r + mod_p_r;

// ── DSP48E1'e yönlendirilen 16×16 MAC hatları ──────────────────────────
wire [15:0] a_w  = op_a_r [j_idx_r*16 +: 16];
wire [15:0] b_w  = op_b_r [i_idx_r*16 +: 16];
wire [15:0] n_w  = mod_p_r[j_idx_r*16 +: 16];
wire [15:0] n0_w = mod_p_r[15:0];
wire [15:0] t_j  = t_r[j_idx_r];

(* use_dsp = "yes" *) wire [31:0] mac_mul  = a_w * b_w  + {16'd0, t_j}     + {16'd0, carry_r};
(* use_dsp = "yes" *) wire [31:0] mac_red  = m_r * n_w  + {16'd0, t_j}     + {16'd0, carry_r};
(* use_dsp = "yes" *) wire [31:0] mac_red0 = m_r * n0_w + {16'd0, t_r[0]};
(* use_dsp = "yes" *) wire [31:0] m_mul    = t_r[0] * N0INV;

wire [16:0] mulfin_w = {1'b0, t_r[16]} + {1'b0, carry_r};
wire [16:0] redfin_w = {1'b0, t_r[16]} + {1'b0, carry_r};

wire [255:0] res_word_w = { t_r[15],t_r[14],t_r[13],t_r[12],t_r[11],t_r[10],t_r[9],t_r[8],
                            t_r[7], t_r[6], t_r[5], t_r[4], t_r[3], t_r[2], t_r[1],t_r[0] };
wire         fazla_w   = (t_r[16] != 16'd0) || (res_word_w >= mod_p_r);
wire [255:0] son_res_w = fazla_w ? (res_word_w - mod_p_r) : res_word_w;

// =====================================================================
// Ana FSM
// =====================================================================
always @(posedge clk_in or negedge rst_n) begin
    if (!rst_n) begin
        state_r<=ST_IDLE;
        o_rdy_r<=1'b1; o_done_r<=1'b0; o_pkt_vld_r<=1'b0; o_pkt_last_r<=1'b0;
        o_pkt_out_r<=32'd0; o_err_r<=1'b0;
        op_a_r<=256'd0; op_b_r<=256'd0; mod_p_r<=256'd0; result_r<=256'd0;
        i_idx_r<=5'd0; j_idx_r<=5'd0; carry_r<=16'd0; m_r<=16'd0;
        pkt_rx_cnt_r<=3'd0; pkt_tx_cnt_r<=3'd0; wdog_r<=12'd0;
        for (k=0;k<18;k=k+1) t_r[k]<=16'd0;
    end else begin
        o_done_r<=1'b0; o_pkt_vld_r<=1'b0; o_pkt_last_r<=1'b0; o_err_r<=1'b0;

        case (state_r)

            ST_IDLE: begin
                o_rdy_r <= 1'b1;
                if (i_pkt_vld) begin
                    case (i_pkt_sel)
                        SEL_A: op_a_r [pkt_rx_cnt_r*32 +: 32] <= i_pkt_in;
                        SEL_B: op_b_r [pkt_rx_cnt_r*32 +: 32] <= i_pkt_in;
                        SEL_P: mod_p_r[pkt_rx_cnt_r*32 +: 32] <= i_pkt_in;
                        default: ;
                    endcase
                    pkt_rx_cnt_r <= pkt_rx_cnt_r + 3'd1;
                end
                if (i_start) begin
                    if (mod_p_r == 256'd0) begin
                        o_err_r<=1'b1; o_rdy_r<=1'b1;
                    end else begin
                        o_rdy_r<=1'b0;
                        if (i_opcode == 2'b10) begin
                            for (k=0;k<18;k=k+1) t_r[k]<=16'd0;
                            i_idx_r<=5'd0; j_idx_r<=5'd0; carry_r<=16'd0; wdog_r<=12'd0;
                            state_r<=ST_MUL;
                        end else begin
                            result_r     <= (i_opcode==2'b00) ? toplam_mod_w : fark_mod_w;
                            o_done_r     <= 1'b1;
                            pkt_tx_cnt_r <= 3'd0;
                            state_r      <= ST_TX;
                        end
                    end
                end
            end

            ST_MUL: begin
                if (wdog_r >= WDOG_MAX) begin
                    o_err_r<=1'b1; o_rdy_r<=1'b1; state_r<=ST_IDLE;
                end else begin
                    wdog_r       <= wdog_r + 12'd1;
                    t_r[j_idx_r] <= mac_mul[15:0];
                    carry_r      <= mac_mul[31:16];
                    if (j_idx_r == 5'd15) state_r<=ST_MUL_FIN;
                    else j_idx_r <= j_idx_r + 5'd1;
                end
            end

            ST_MUL_FIN: begin
                t_r[16] <= mulfin_w[15:0];
                t_r[17] <= {15'd0, mulfin_w[16]};
                carry_r <= 16'd0;
                state_r <= ST_RED_M;
            end

            ST_RED_M: begin
                m_r     <= m_mul[15:0];
                carry_r <= 16'd0;
                state_r <= ST_RED_FIRST;
            end

            ST_RED_FIRST: begin
                carry_r <= mac_red0[31:16];
                j_idx_r <= 5'd1;
                state_r <= ST_RED;
            end

            ST_RED: begin
                t_r[j_idx_r-5'd1] <= mac_red[15:0];
                carry_r           <= mac_red[31:16];
                if (j_idx_r == 5'd15) state_r<=ST_RED_FIN;
                else j_idx_r <= j_idx_r + 5'd1;
            end

            ST_RED_FIN: begin
                t_r[15] <= redfin_w[15:0];
                t_r[16] <= t_r[17] + {15'd0, redfin_w[16]};
                t_r[17] <= 16'd0;
                if (i_idx_r == 5'd15) state_r<=ST_FINAL;
                else begin i_idx_r<=i_idx_r+5'd1; j_idx_r<=5'd0; carry_r<=16'd0; state_r<=ST_MUL; end
            end

            ST_FINAL: begin
                result_r     <= son_res_w;
                o_done_r     <= 1'b1;
                pkt_tx_cnt_r <= 3'd0;
                state_r      <= ST_TX;
            end

            ST_TX: begin
                o_rdy_r      <= 1'b0;
                o_pkt_vld_r  <= 1'b1;
                o_pkt_out_r  <= result_r[pkt_tx_cnt_r*32 +: 32];
                o_pkt_last_r <= (pkt_tx_cnt_r == 3'd7);
                if (pkt_tx_cnt_r == 3'd7) begin pkt_tx_cnt_r<=3'd0; state_r<=ST_IDLE; end
                else pkt_tx_cnt_r <= pkt_tx_cnt_r + 3'd1;
            end

            default: state_r <= ST_IDLE;

        endcase
    end
end

endmodule
