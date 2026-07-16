// =============================================================================
// Modül   : scalar_multiplier.v   (Montgomery Ladder + XOR-CSWAP; wire/reg)
// Proje   : FPGA Tabanlı Güvenli Anahtar Yönetimi ve Kripto Hızlandırıcı
// No      : 5260007 — Sakarya Uygulamalı Bilimler Üniversitesi
// -----------------------------------------------------------------------------
// Açıklama:
//   P-256 sabit-zamanlı 256-bit skaler nokta çarpımı (d·G / d·Q). Montgomery
//   Ladder + XOR tabanlı koşulsuz CSWAP (SCA korumalı). Fonksiyon ve port
//   arayüzü öncekiyle aynı. Bu sürümde WIRE/REG AYRIMI uygulandı.
//
//   BRAM NOTU: R0/R1 merdiven noktaları (r0_x/y/z, r1_x/y/z) her iterasyonda
//   XOR-CSWAP ile TEK çevrimde ve tümü PARALEL güncellenir (6 okuma + 6 yazma).
//   2-port Block RAM bu paralel erişimi karşılayamaz; CSWAP'ı word-seri hale
//   getirmek doğrulanmış sabit-zamanlı SCA yolunu bozma riski taşır. Bu nedenle
//   merdiven saklayıcıları bilinçli olarak kayıtçı bırakıldı ("uygulanabilir
//   kısımlar" ilkesi). BRAM kazancı PAU/affine_donusum'un seri-erişimli büyük
//   ara saklayıcı bankalarında gerçekleştirildi.
//
// Standart : Verilog-2001 — sentezlenebilir
// Tarih    : Temmuz 2026
// =============================================================================

`timescale 1ns / 1ps

module scalar_multiplier (
    input  wire         clk_in,
    input  wire         rst_n,
    input  wire [31:0]  i_pkt_in,
    input  wire         i_pkt_vld,
    input  wire [2:0]   i_pkt_sel,
    input  wire         i_start,
    input  wire [255:0] i_rand_seed,
    input  wire         i_rand_vld,
    output wire [31:0]  o_pkt_out,
    output wire         o_pkt_vld,
    output wire [1:0]   o_pkt_sel,
    output wire         o_pkt_last,
    output wire         o_rdy,
    output wire         o_done,
    output wire         o_err,
    // ── Paylaşılan MALU dış arayüzü (PAU'dan geçirilir) ───────────────────
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

wire unused_rand = i_rand_vld | (|i_rand_seed);

localparam [2:0] SIX_MODP=3'd0, SIX_SCALAR=3'd1, SIX_BX=3'd2, SIX_BY=3'd3, SIX_BZ=3'd4;
localparam [2:0] PIX_MODP=3'd0, PIX_P1X=3'd1, PIX_P1Y=3'd2, PIX_P1Z=3'd3,
                 PIX_P2X=3'd4, PIX_P2Y=3'd5, PIX_P2Z=3'd6;

localparam [4:0]
    ST_IDLE=5'd0, ST_INIT=5'd1, ST_SEND_MODP=5'd2, ST_PRE_CSWAP=5'd28,
    ST_ADD_P1X=5'd3, ST_ADD_P1Y=5'd4, ST_ADD_P1Z=5'd5,
    ST_ADD_P2X=5'd6, ST_ADD_P2Y=5'd7, ST_ADD_P2Z=5'd8,
    ST_ADD_START=5'd9, ST_ADD_WAIT_X=5'd10, ST_ADD_RX_X=5'd11,
    ST_ADD_RX_Y=5'd12, ST_ADD_RX_Z=5'd13, ST_ADD_LATCH=5'd14,
    ST_DBL_P1X=5'd15, ST_DBL_P1Y=5'd16, ST_DBL_P1Z=5'd17,
    ST_DBL_START=5'd18, ST_DBL_WAIT_X=5'd19, ST_DBL_RX_X=5'd20,
    ST_DBL_RX_Y=5'd21, ST_DBL_RX_Z=5'd22, ST_DBL_LATCH=5'd23,
    ST_POST_CSWAP=5'd29, ST_TX_X=5'd24, ST_TX_Y=5'd25, ST_TX_Z=5'd26, ST_DONE=5'd27;

reg [4:0] state_r;
localparam [14:0] PAU_WDOG_MAX = 15'd25000;

reg [255:0] p_r, d_r, bx_r, by_r, bz_r;
reg [255:0] d_shift_r;   // d skaler kaydırmalı register (256:1 mux'u eler; MSB-önce)
reg [255:0] r0_x_r, r0_y_r, r0_z_r, r1_x_r, r1_y_r, r1_z_r;
reg [255:0] add_x_r, add_y_r, add_z_r, dbl_x_r, dbl_y_r, dbl_z_r;
reg [8:0]   bit_idx_r;
reg [14:0]  pau_wdog_r;
reg [2:0]   pkt_rx_cnt_r, pkt_rx_cnt2_r, pkt_tx_cnt_r;

// ── Çıkış saklayıcıları → wire portlara assign ─────────────────────────
reg [31:0] o_pkt_out_r;
reg        o_pkt_vld_r;
reg [1:0]  o_pkt_sel_r;
reg        o_pkt_last_r, o_rdy_r, o_done_r, o_err_r;
assign o_pkt_out  = o_pkt_out_r;
assign o_pkt_vld  = o_pkt_vld_r;
assign o_pkt_sel  = o_pkt_sel_r;
assign o_pkt_last = o_pkt_last_r;
assign o_rdy      = o_rdy_r;
assign o_done     = o_done_r;
assign o_err      = o_err_r;

wire        cswap_bit_w = d_shift_r[255];   // 256:1 mux yerine kayan register biti (MSB)
wire [255:0] cswap_mx_w = {256{cswap_bit_w}} & (r0_x_r ^ r1_x_r);
wire [255:0] cswap_my_w = {256{cswap_bit_w}} & (r0_y_r ^ r1_y_r);
wire [255:0] cswap_mz_w = {256{cswap_bit_w}} & (r0_z_r ^ r1_z_r);

reg         pau_pkt_vld_r;
reg  [31:0] pau_pkt_dat_r;
reg  [2:0]  pau_pkt_sel_r;
reg         pau_cmd_r, pau_st_r;
wire [31:0] pau_pkt_out_w;
wire        pau_pkt_vld_w;
wire [1:0]  pau_pkt_sel_w;
wire        pau_pkt_last_w, pau_rdy_w, pau_done_w, pau_err_w;

point_arithmetic_unit pau_inst (
    .clk_in(clk_in), .rst_n(rst_n),
    .i_pkt_in(pau_pkt_dat_r), .i_pkt_vld(pau_pkt_vld_r), .i_pkt_sel(pau_pkt_sel_r),
    .i_cmd(pau_cmd_r), .i_start(pau_st_r),
    .o_pkt_out(pau_pkt_out_w), .o_pkt_vld(pau_pkt_vld_w), .o_pkt_sel(pau_pkt_sel_w),
    .o_pkt_last(pau_pkt_last_w), .o_rdy(pau_rdy_w), .o_done(pau_done_w), .o_err(pau_err_w),
    // ── MALU master arayüzü — SM portlarına doğrudan geçirilir ──
    .mo_pkt_dat(mo_pkt_dat), .mo_pkt_vld(mo_pkt_vld), .mo_pkt_sel(mo_pkt_sel),
    .mo_opc(mo_opc), .mo_st(mo_st),
    .mi_pkt_out(mi_pkt_out), .mi_pkt_vld(mi_pkt_vld), .mi_pkt_last(mi_pkt_last),
    .mi_rdy(mi_rdy), .mi_done(mi_done), .mi_err(mi_err)
);

always @(posedge clk_in or negedge rst_n) begin
    if (!rst_n) begin
        state_r<=ST_IDLE;
        o_rdy_r<=1'b0; o_done_r<=1'b0; o_pkt_vld_r<=1'b0; o_err_r<=1'b0;
        o_pkt_out_r<=32'd0; o_pkt_sel_r<=2'd0; o_pkt_last_r<=1'b0;
        pau_pkt_vld_r<=1'b0; pau_pkt_dat_r<=32'd0;
        pau_pkt_sel_r<=3'd0; pau_cmd_r<=1'b0; pau_st_r<=1'b0;
        p_r<=256'd0; d_r<=256'd0; bx_r<=256'd0; by_r<=256'd0; bz_r<=256'd0;
        r0_x_r<=256'd0; r0_y_r<=256'd0; r0_z_r<=256'd0;
        r1_x_r<=256'd0; r1_y_r<=256'd0; r1_z_r<=256'd0;
        add_x_r<=256'd0; add_y_r<=256'd0; add_z_r<=256'd0;
        dbl_x_r<=256'd0; dbl_y_r<=256'd0; dbl_z_r<=256'd0;
        bit_idx_r<=9'd255; pau_wdog_r<=15'd0; d_shift_r<=256'd0;
        pkt_rx_cnt_r<=3'd0; pkt_rx_cnt2_r<=3'd0; pkt_tx_cnt_r<=3'd0;
    end else begin
        o_done_r<=1'b0; o_pkt_vld_r<=1'b0; o_pkt_last_r<=1'b0; o_err_r<=1'b0;
        pau_st_r<=1'b0; pau_pkt_vld_r<=1'b0;

        if (pau_err_w) begin
            o_err_r<=1'b1; o_rdy_r<=1'b1; state_r<=ST_IDLE;
        end else begin
        case (state_r)

            ST_IDLE: begin
                o_rdy_r <= 1'b1;
                if (i_pkt_vld) begin
                    case (i_pkt_sel)
                        SIX_MODP:   p_r [pkt_rx_cnt_r*32 +: 32] <= i_pkt_in;
                        SIX_SCALAR: d_r [pkt_rx_cnt_r*32 +: 32] <= i_pkt_in;
                        SIX_BX:     bx_r[pkt_rx_cnt_r*32 +: 32] <= i_pkt_in;
                        SIX_BY:     by_r[pkt_rx_cnt_r*32 +: 32] <= i_pkt_in;
                        SIX_BZ:     bz_r[pkt_rx_cnt_r*32 +: 32] <= i_pkt_in;
                        default: ;
                    endcase
                    pkt_rx_cnt_r <= pkt_rx_cnt_r + 3'd1;
                end
                if (i_start) begin
                    if (d_r == 256'd0) begin o_err_r<=1'b1; o_rdy_r<=1'b1; end
                    else begin o_rdy_r<=1'b0; state_r<=ST_INIT; end
                end
            end

            ST_INIT: begin
                r0_x_r<=bx_r; r0_y_r<=by_r; r0_z_r<=256'd0;   // R0 = ∞
                r1_x_r<=bx_r; r1_y_r<=by_r; r1_z_r<=bz_r;      // R1 = G
                bit_idx_r<=9'd255; pkt_rx_cnt2_r<=3'd0; state_r<=ST_SEND_MODP;
                d_shift_r<=d_r;   // d'yi kaydırmalı register'a yükle (MSB-önce)
            end

            ST_SEND_MODP: begin
                pau_pkt_vld_r<=1'b1; pau_pkt_dat_r<=p_r[pkt_rx_cnt2_r*32 +: 32];
                pau_pkt_sel_r<=PIX_MODP;
                if (pkt_rx_cnt2_r==3'd7) begin pkt_rx_cnt2_r<=3'd0; state_r<=ST_PRE_CSWAP; end
                else pkt_rx_cnt2_r<=pkt_rx_cnt2_r+3'd1;
            end

            ST_PRE_CSWAP: begin
                r0_x_r<=r0_x_r^cswap_mx_w; r0_y_r<=r0_y_r^cswap_my_w; r0_z_r<=r0_z_r^cswap_mz_w;
                r1_x_r<=r1_x_r^cswap_mx_w; r1_y_r<=r1_y_r^cswap_my_w; r1_z_r<=r1_z_r^cswap_mz_w;
                state_r<=ST_ADD_P1X;
            end

            ST_ADD_P1X: begin pau_pkt_vld_r<=1'b1; pau_pkt_dat_r<=r0_x_r[pkt_rx_cnt2_r*32 +: 32]; pau_pkt_sel_r<=PIX_P1X;
                if (pkt_rx_cnt2_r==3'd7) begin pkt_rx_cnt2_r<=3'd0; state_r<=ST_ADD_P1Y; end else pkt_rx_cnt2_r<=pkt_rx_cnt2_r+3'd1; end
            ST_ADD_P1Y: begin pau_pkt_vld_r<=1'b1; pau_pkt_dat_r<=r0_y_r[pkt_rx_cnt2_r*32 +: 32]; pau_pkt_sel_r<=PIX_P1Y;
                if (pkt_rx_cnt2_r==3'd7) begin pkt_rx_cnt2_r<=3'd0; state_r<=ST_ADD_P1Z; end else pkt_rx_cnt2_r<=pkt_rx_cnt2_r+3'd1; end
            ST_ADD_P1Z: begin pau_pkt_vld_r<=1'b1; pau_pkt_dat_r<=r0_z_r[pkt_rx_cnt2_r*32 +: 32]; pau_pkt_sel_r<=PIX_P1Z;
                if (pkt_rx_cnt2_r==3'd7) begin pkt_rx_cnt2_r<=3'd0; state_r<=ST_ADD_P2X; end else pkt_rx_cnt2_r<=pkt_rx_cnt2_r+3'd1; end
            ST_ADD_P2X: begin pau_pkt_vld_r<=1'b1; pau_pkt_dat_r<=r1_x_r[pkt_rx_cnt2_r*32 +: 32]; pau_pkt_sel_r<=PIX_P2X;
                if (pkt_rx_cnt2_r==3'd7) begin pkt_rx_cnt2_r<=3'd0; state_r<=ST_ADD_P2Y; end else pkt_rx_cnt2_r<=pkt_rx_cnt2_r+3'd1; end
            ST_ADD_P2Y: begin pau_pkt_vld_r<=1'b1; pau_pkt_dat_r<=r1_y_r[pkt_rx_cnt2_r*32 +: 32]; pau_pkt_sel_r<=PIX_P2Y;
                if (pkt_rx_cnt2_r==3'd7) begin pkt_rx_cnt2_r<=3'd0; state_r<=ST_ADD_P2Z; end else pkt_rx_cnt2_r<=pkt_rx_cnt2_r+3'd1; end
            ST_ADD_P2Z: begin pau_pkt_vld_r<=1'b1; pau_pkt_dat_r<=r1_z_r[pkt_rx_cnt2_r*32 +: 32]; pau_pkt_sel_r<=PIX_P2Z;
                if (pkt_rx_cnt2_r==3'd7) begin pkt_rx_cnt2_r<=3'd0; state_r<=ST_ADD_START; end else pkt_rx_cnt2_r<=pkt_rx_cnt2_r+3'd1; end

            ST_ADD_START: begin pau_cmd_r<=1'b1; pau_st_r<=1'b1; pau_wdog_r<=15'd0; state_r<=ST_ADD_WAIT_X; end

            ST_ADD_WAIT_X: begin
                if (pau_wdog_r>=PAU_WDOG_MAX) begin o_err_r<=1'b1; o_rdy_r<=1'b1; state_r<=ST_IDLE; end
                else if (pau_pkt_vld_w && pau_pkt_sel_w==2'b00) begin add_x_r[0 +: 32]<=pau_pkt_out_w; pkt_rx_cnt2_r<=3'd1; state_r<=ST_ADD_RX_X; end
                else pau_wdog_r<=pau_wdog_r+15'd1;
            end
            ST_ADD_RX_X: begin if (pau_pkt_vld_w && pau_pkt_sel_w==2'b00) begin add_x_r[pkt_rx_cnt2_r*32 +: 32]<=pau_pkt_out_w;
                if (pkt_rx_cnt2_r==3'd7) begin pkt_rx_cnt2_r<=3'd0; state_r<=ST_ADD_RX_Y; end else pkt_rx_cnt2_r<=pkt_rx_cnt2_r+3'd1; end end
            ST_ADD_RX_Y: begin if (pau_pkt_vld_w && pau_pkt_sel_w==2'b01) begin add_y_r[pkt_rx_cnt2_r*32 +: 32]<=pau_pkt_out_w;
                if (pkt_rx_cnt2_r==3'd7) begin pkt_rx_cnt2_r<=3'd0; state_r<=ST_ADD_RX_Z; end else pkt_rx_cnt2_r<=pkt_rx_cnt2_r+3'd1; end end
            ST_ADD_RX_Z: begin if (pau_pkt_vld_w && pau_pkt_sel_w==2'b10) begin add_z_r[pkt_rx_cnt2_r*32 +: 32]<=pau_pkt_out_w;
                if (pkt_rx_cnt2_r==3'd7) begin pkt_rx_cnt2_r<=3'd0; state_r<=ST_ADD_LATCH; end else pkt_rx_cnt2_r<=pkt_rx_cnt2_r+3'd1; end end

            ST_ADD_LATCH: begin r1_x_r<=add_x_r; r1_y_r<=add_y_r; r1_z_r<=add_z_r; state_r<=ST_DBL_P1X; end

            ST_DBL_P1X: begin pau_pkt_vld_r<=1'b1; pau_pkt_dat_r<=r0_x_r[pkt_rx_cnt2_r*32 +: 32]; pau_pkt_sel_r<=PIX_P1X;
                if (pkt_rx_cnt2_r==3'd7) begin pkt_rx_cnt2_r<=3'd0; state_r<=ST_DBL_P1Y; end else pkt_rx_cnt2_r<=pkt_rx_cnt2_r+3'd1; end
            ST_DBL_P1Y: begin pau_pkt_vld_r<=1'b1; pau_pkt_dat_r<=r0_y_r[pkt_rx_cnt2_r*32 +: 32]; pau_pkt_sel_r<=PIX_P1Y;
                if (pkt_rx_cnt2_r==3'd7) begin pkt_rx_cnt2_r<=3'd0; state_r<=ST_DBL_P1Z; end else pkt_rx_cnt2_r<=pkt_rx_cnt2_r+3'd1; end
            ST_DBL_P1Z: begin pau_pkt_vld_r<=1'b1; pau_pkt_dat_r<=r0_z_r[pkt_rx_cnt2_r*32 +: 32]; pau_pkt_sel_r<=PIX_P1Z;
                if (pkt_rx_cnt2_r==3'd7) begin pkt_rx_cnt2_r<=3'd0; state_r<=ST_DBL_START; end else pkt_rx_cnt2_r<=pkt_rx_cnt2_r+3'd1; end

            ST_DBL_START: begin pau_cmd_r<=1'b0; pau_st_r<=1'b1; pau_wdog_r<=15'd0; state_r<=ST_DBL_WAIT_X; end

            ST_DBL_WAIT_X: begin
                if (pau_wdog_r>=PAU_WDOG_MAX) begin o_err_r<=1'b1; o_rdy_r<=1'b1; state_r<=ST_IDLE; end
                else if (pau_pkt_vld_w && pau_pkt_sel_w==2'b00) begin dbl_x_r[0 +: 32]<=pau_pkt_out_w; pkt_rx_cnt2_r<=3'd1; state_r<=ST_DBL_RX_X; end
                else pau_wdog_r<=pau_wdog_r+15'd1;
            end
            ST_DBL_RX_X: begin if (pau_pkt_vld_w && pau_pkt_sel_w==2'b00) begin dbl_x_r[pkt_rx_cnt2_r*32 +: 32]<=pau_pkt_out_w;
                if (pkt_rx_cnt2_r==3'd7) begin pkt_rx_cnt2_r<=3'd0; state_r<=ST_DBL_RX_Y; end else pkt_rx_cnt2_r<=pkt_rx_cnt2_r+3'd1; end end
            ST_DBL_RX_Y: begin if (pau_pkt_vld_w && pau_pkt_sel_w==2'b01) begin dbl_y_r[pkt_rx_cnt2_r*32 +: 32]<=pau_pkt_out_w;
                if (pkt_rx_cnt2_r==3'd7) begin pkt_rx_cnt2_r<=3'd0; state_r<=ST_DBL_RX_Z; end else pkt_rx_cnt2_r<=pkt_rx_cnt2_r+3'd1; end end
            ST_DBL_RX_Z: begin if (pau_pkt_vld_w && pau_pkt_sel_w==2'b10) begin dbl_z_r[pkt_rx_cnt2_r*32 +: 32]<=pau_pkt_out_w;
                if (pkt_rx_cnt2_r==3'd7) begin pkt_rx_cnt2_r<=3'd0; state_r<=ST_DBL_LATCH; end else pkt_rx_cnt2_r<=pkt_rx_cnt2_r+3'd1; end end

            ST_DBL_LATCH: begin r0_x_r<=dbl_x_r; r0_y_r<=dbl_y_r; r0_z_r<=dbl_z_r; state_r<=ST_POST_CSWAP; end

            ST_POST_CSWAP: begin
                r0_x_r<=r0_x_r^cswap_mx_w; r0_y_r<=r0_y_r^cswap_my_w; r0_z_r<=r0_z_r^cswap_mz_w;
                r1_x_r<=r1_x_r^cswap_mx_w; r1_y_r<=r1_y_r^cswap_my_w; r1_z_r<=r1_z_r^cswap_mz_w;
                if (bit_idx_r==9'd0) begin pkt_tx_cnt_r<=3'd0; state_r<=ST_TX_X; end
                else begin bit_idx_r<=bit_idx_r-9'd1; d_shift_r<=d_shift_r<<1; state_r<=ST_PRE_CSWAP; end
            end

            ST_TX_X: begin o_pkt_vld_r<=1'b1; o_pkt_sel_r<=2'b00; o_pkt_out_r<=r0_x_r[pkt_tx_cnt_r*32 +: 32]; o_pkt_last_r<=(pkt_tx_cnt_r==3'd7);
                if (pkt_tx_cnt_r==3'd7) begin pkt_tx_cnt_r<=3'd0; state_r<=ST_TX_Y; end else pkt_tx_cnt_r<=pkt_tx_cnt_r+3'd1; end
            ST_TX_Y: begin o_pkt_vld_r<=1'b1; o_pkt_sel_r<=2'b01; o_pkt_out_r<=r0_y_r[pkt_tx_cnt_r*32 +: 32]; o_pkt_last_r<=(pkt_tx_cnt_r==3'd7);
                if (pkt_tx_cnt_r==3'd7) begin pkt_tx_cnt_r<=3'd0; state_r<=ST_TX_Z; end else pkt_tx_cnt_r<=pkt_tx_cnt_r+3'd1; end
            ST_TX_Z: begin o_pkt_vld_r<=1'b1; o_pkt_sel_r<=2'b10; o_pkt_out_r<=r0_z_r[pkt_tx_cnt_r*32 +: 32]; o_pkt_last_r<=(pkt_tx_cnt_r==3'd7);
                if (pkt_tx_cnt_r==3'd7) begin pkt_tx_cnt_r<=3'd0; state_r<=ST_DONE; end else pkt_tx_cnt_r<=pkt_tx_cnt_r+3'd1; end

            ST_DONE: begin o_done_r<=1'b1; o_rdy_r<=1'b1; state_r<=ST_IDLE; end

            default: state_r <= ST_IDLE;
        endcase
        end
    end
end

endmodule
