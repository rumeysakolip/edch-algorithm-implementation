// =============================================================================
// Modül   : point_arithmetic_unit.v   (BRAM-optimize + wire/reg ayrımı)
// Proje   : FPGA Tabanlı Güvenli Anahtar Yönetimi ve Kripto Hızlandırıcı
// No      : 5260007 - Sakarya Uygulamalı Bilimler Üniversitesi
// -----------------------------------------------------------------------------
// Açıklama:
//   Jacobian projektif koordinatlarda Nokta Katlama (DBL) ve Nokta Toplama (ADD)
//   işlemlerini modular_alu üzerinden gerçekleştiren birim. Fonksiyonel davranış
//   ve port arayüzü önceki sürümle birebir aynıdır; iki mimari optimizasyon:
//
//   [1] BLOCK RAM (BRAM) SCRATCHPAD:
//     Önceki tasarımdaki ~40 adet 256-bit ara koordinat saklayıcısı (delta,
//     gamma, ... U1, U2, S1, S2, H, R, ...) ve giriş/sonuç nokta koordinatları,
//     dağıtık kayıtçılar yerine tek bir senkron Block RAM'e (ara_mem[0:63],
//     256-bit) taşındı. Böylece:
//       - ~40×256 flip-flop depolaması BRAM'e devredildi (FF kazancı),
//       - adım operandını 40 saklayıcı arasından seçen dev 256-bit MUX ağacı
//         yerini 6-bit BRAM adres seçimine bıraktı (BÜYÜK LUT kazancı).
//     Okuma adresi ve yazma denetimi KOMBİNASYONEL sürülür; BRAM'in 1-çevrimlik
//     kayıtlı okuma çıkışı (mem_rd_r) gecikmeyi sağlar (kanonik inference şablonu).
//     Bağımlı adımlarda oku-yazma tehlikesi yoktur: yazma STORE kenarında, ilgili
//     okuma bir sonraki kenarda gerçekleşir.
//
//   [2] WIRE/REG AYRIMI:
//     Tüm çıkış portları saf 'wire'; senkron değerler dahili '*_r'de tutulup
//     portlara 'assign' ile kesintisiz aktarılır.
//
//   Adım operand/sonuç tabloları (DBL/ADD, 24'er adım) önceki sürümle aynıdır;
//   yalnızca 256-bit veri yerine 6-bit BRAM adresleri (opid) üretir.
//
// SENTEZ (Xilinx Vivado):
//   (* ram_style = "block" *) ara_mem → BRAM (senkron R/W).
//   Tüm yollar FSM ile kapılanır; default kolu → inferred latch yok.
//
// Standart : Verilog-2001 - sentezlenebilir
// Tarih    : Temmuz 2026
// =============================================================================

`timescale 1ns / 1ps

module point_arithmetic_unit (
    input  wire         clk_in,
    input  wire         rst_n,
    input  wire [31:0]  i_pkt_in,
    input  wire         i_pkt_vld,
    input  wire [2:0]   i_pkt_sel,
    input  wire         i_cmd,        // 0: DBL | 1: ADD
    input  wire         i_start,
    output wire [31:0]  o_pkt_out,
    output wire         o_pkt_vld,
    output wire [1:0]   o_pkt_sel,
    output wire         o_pkt_last,
    output wire         o_rdy,
    output wire         o_done,
    output wire         o_err,
    // ── Paylaşılan MALU dış arayüzü (master) ──────────────────────────────
    output wire [31:0]  mo_pkt_dat,   // → MALU i_pkt_in
    output wire         mo_pkt_vld,   // → MALU i_pkt_vld
    output wire [1:0]   mo_pkt_sel,   // → MALU i_pkt_sel
    output wire [1:0]   mo_opc,       // → MALU i_opcode
    output wire         mo_st,        // → MALU i_start
    input  wire [31:0]  mi_pkt_out,   // ← MALU o_pkt_out
    input  wire         mi_pkt_vld,   // ← MALU o_pkt_vld
    input  wire         mi_pkt_last,  // ← MALU o_pkt_last
    input  wire         mi_rdy,       // ← MALU o_rdy
    input  wire         mi_done,      // ← MALU o_done
    input  wire         mi_err        // ← MALU o_err
);

// =====================================================================
// Seçici / Opcode Sabitleri
// =====================================================================
localparam [2:0] PIX_MODP=3'd0, PIX_P1X=3'd1, PIX_P1Y=3'd2, PIX_P1Z=3'd3,
                 PIX_P2X=3'd4, PIX_P2Y=3'd5, PIX_P2Z=3'd6;
localparam [1:0] POX_PX=2'd0, POX_PY=2'd1, POX_PZ=2'd2;
localparam [1:0] MADD=2'b00, MSUB=2'b01, MMUL=2'b10;
localparam [1:0] MSEL_A=2'b00, MSEL_B=2'b01, MSEL_P=2'b10;

// =====================================================================
// BRAM Scratchpad Slot Adresleri (operand id — 6-bit)
//   Giriş/sonuç bitişik: P1(1..3), P2(4..6), sonuç(7..9) → tx_base ile okunur.
// =====================================================================
localparam [5:0]
    A_P1X=6'd1, A_P1Y=6'd2, A_P1Z=6'd3, A_P2X=6'd4, A_P2Y=6'd5, A_P2Z=6'd6,
    A_PX=6'd7,  A_PY=6'd8,  A_PZ=6'd9,
    A_DELTA=6'd10,A_GAMMA=6'd11,A_BETA=6'd12,A_TEKSI=6'd13,A_TARTI=6'd14,
    A_MARA=6'd15,A_MARA2=6'd16,A_W=6'd17,A_ALPHAK=6'd18,A_BETA2=6'd19,
    A_BETA4=6'd20,A_BETA8=6'd21,A_YZTOP=6'd22,A_YZKARE=6'd23,A_ZT1=6'd24,
    A_Y3T1=6'd25,A_Y3T2=6'd26,A_GAMMAK=6'd27,A_G2=6'd28,A_G4=6'd29,A_G8=6'd30,
    A_Z1K=6'd31,A_Z2K=6'd32,A_Z1KUP=6'd33,A_Z2KUP=6'd34,A_U1=6'd35,A_U2=6'd36,
    A_S1=6'd37,A_S2=6'd38,A_H=6'd39,A_R=6'd40,A_H2=6'd41,A_H3=6'd42,
    A_U1H2=6'd43,A_R2=6'd44,A_U1H2X2=6'd45,A_X3T1=6'd46,A_Y3T1A=6'd47,
    A_Y3T2A=6'd48,A_Y3T3A=6'd49,A_ZT1A=6'd50;

// =====================================================================
// FSM Durumları (5-bit)
// =====================================================================
localparam [4:0]
    ST_IDLE=5'd0, ST_CHK_INF=5'd1, ST_INIT_P=5'd2, ST_EXEC_SET=5'd3,
    ST_RD_A=5'd4, ST_RD_B=5'd5, ST_TX_A=5'd6, ST_TX_B=5'd7,
    ST_MALU_GO=5'd8, ST_MALU_WT=5'd9, ST_RX_RES=5'd10, ST_STORE=5'd11,
    ST_OUT_RA=5'd12, ST_OUT_LAT=5'd13, ST_OUT_TX=5'd14, ST_DONE=5'd15;

reg [4:0] state_r;

localparam [11:0] MALU_WDOG_MAX = 12'd4000;

// =====================================================================
// Block RAM Scratchpad — KOMBİNASYONEL adres/yazma + kayıtlı okuma çıkışı
// =====================================================================
(* ram_style = "block" *) reg [255:0] ara_mem [0:63];
reg [255:0] mem_rd_r;    // kayıtlı okuma çıkışı (1-çevrim gecikme)
reg [5:0]   mem_ra_c;    // kombinasyonel okuma adresi
reg         mem_we_c;    // kombinasyonel yazma etkin
reg [5:0]   mem_wa_c;    // kombinasyonel yazma adresi
reg [255:0] mem_wd_c;    // kombinasyonel yazma verisi

always @(posedge clk_in) begin
    if (mem_we_c) ara_mem[mem_wa_c] <= mem_wd_c;
    mem_rd_r <= ara_mem[mem_ra_c];
end

// =====================================================================
// Kayıtçılar
// =====================================================================
reg [255:0] mod_p_r;
reg         i_cmd_r;
reg [255:0] asm_r;
reg         p1z_nz_r, p2z_nz_r;
reg [255:0] mdsp_a_r, mdsp_b_r, mdsp_res_r;
reg [1:0]   mdsp_opc_r;
reg [2:0]   mdsp_cnt_r;
reg [5:0]   addr_b_r, addr_res_r;
reg         store_r;
reg [4:0]   step_r;
reg [11:0]  malu_wdog_r;
reg [2:0]   pkt_rx_cnt_r, pkt_tx_cnt_r;
reg [255:0] out_r;
reg [1:0]   out_coord_r;
reg [5:0]   tx_base_r;

// Çıkış saklayıcıları → wire portlara assign
reg [31:0] o_pkt_out_r;
reg        o_pkt_vld_r;
reg [1:0]  o_pkt_sel_r;
reg        o_pkt_last_r;
reg        o_rdy_r, o_done_r, o_err_r;

assign o_pkt_out  = o_pkt_out_r;
assign o_pkt_vld  = o_pkt_vld_r;
assign o_pkt_sel  = o_pkt_sel_r;
assign o_pkt_last = o_pkt_last_r;
assign o_rdy      = o_rdy_r;
assign o_done     = o_done_r;
assign o_err      = o_err_r;

// =====================================================================
// MALU Alt Modülü
// =====================================================================
reg         malu_pkt_vld_r;
reg  [31:0] malu_pkt_dat_r;
reg  [1:0]  malu_pkt_sel_r;
reg  [1:0]  malu_opc_r;
reg         malu_st_r;

// ── Paylaşılan MALU dış arayüzüne bağlanır (iç örnek YOK) ───────────────
assign mo_pkt_dat = malu_pkt_dat_r;
assign mo_pkt_vld = malu_pkt_vld_r;
assign mo_pkt_sel = malu_pkt_sel_r;
assign mo_opc     = malu_opc_r;
assign mo_st      = malu_st_r;
wire [31:0] malu_pkt_out_w  = mi_pkt_out;
wire        malu_pkt_vld_w  = mi_pkt_vld;
wire        malu_pkt_last_w = mi_pkt_last;
wire        malu_rdy_w      = mi_rdy;
wire        malu_done_w     = mi_done;
wire        malu_err_w      = mi_err;

// =====================================================================
// Giriş seçici → BRAM slot eşlemesi
// =====================================================================
reg [5:0] slot_w;
always @* begin
    case (i_pkt_sel)
        PIX_P1X: slot_w=A_P1X; PIX_P1Y: slot_w=A_P1Y; PIX_P1Z: slot_w=A_P1Z;
        PIX_P2X: slot_w=A_P2X; PIX_P2Y: slot_w=A_P2Y; PIX_P2Z: slot_w=A_P2Z;
        default: slot_w=A_P1X;
    endcase
end

// =====================================================================
// Adım operand/sonuç ÇÖZÜMÜ (kombinasyonel) — 6-bit BRAM adresleri
// =====================================================================
reg [5:0] addr_a_w, addr_b_w, addr_res_w;
reg [1:0] opc_w;
reg       store_w, dummy_w;

always @* begin
    addr_a_w=A_P1X; addr_b_w=A_P1X; addr_res_w=A_PX;
    opc_w=MADD; store_w=1'b1; dummy_w=1'b0;
    if (i_cmd_r == 1'b0) begin
        case (step_r)  // DBL
            5'd0:  begin opc_w=MMUL; addr_a_w=A_P1Z;    addr_b_w=A_P1Z;    addr_res_w=A_DELTA;  end
            5'd1:  begin opc_w=MMUL; addr_a_w=A_P1Y;    addr_b_w=A_P1Y;    addr_res_w=A_GAMMA;  end
            5'd2:  begin opc_w=MMUL; addr_a_w=A_P1X;    addr_b_w=A_GAMMA;  addr_res_w=A_BETA;   end
            5'd3:  begin opc_w=MSUB; addr_a_w=A_P1X;    addr_b_w=A_DELTA;  addr_res_w=A_TEKSI;  end
            5'd4:  begin opc_w=MADD; addr_a_w=A_P1X;    addr_b_w=A_DELTA;  addr_res_w=A_TARTI;  end
            5'd5:  begin opc_w=MMUL; addr_a_w=A_TEKSI;  addr_b_w=A_TARTI;  addr_res_w=A_MARA;   end
            5'd6:  begin opc_w=MADD; addr_a_w=A_MARA;   addr_b_w=A_MARA;   addr_res_w=A_MARA2;  end
            5'd7:  begin opc_w=MADD; addr_a_w=A_MARA2;  addr_b_w=A_MARA;   addr_res_w=A_W;      end
            5'd8:  begin opc_w=MMUL; addr_a_w=A_W;      addr_b_w=A_W;      addr_res_w=A_ALPHAK; end
            5'd9:  begin opc_w=MADD; addr_a_w=A_BETA;   addr_b_w=A_BETA;   addr_res_w=A_BETA2;  end
            5'd10: begin opc_w=MADD; addr_a_w=A_BETA2;  addr_b_w=A_BETA2;  addr_res_w=A_BETA4;  end
            5'd11: begin opc_w=MADD; addr_a_w=A_BETA4;  addr_b_w=A_BETA4;  addr_res_w=A_BETA8;  end
            5'd12: begin opc_w=MSUB; addr_a_w=A_ALPHAK; addr_b_w=A_BETA8;  addr_res_w=A_PX;     end
            5'd13: begin opc_w=MADD; addr_a_w=A_P1Y;    addr_b_w=A_P1Z;    addr_res_w=A_YZTOP;  end
            5'd14: begin opc_w=MMUL; addr_a_w=A_YZTOP;  addr_b_w=A_YZTOP;  addr_res_w=A_YZKARE; end
            5'd15: begin opc_w=MSUB; addr_a_w=A_YZKARE; addr_b_w=A_GAMMA;  addr_res_w=A_ZT1;    end
            5'd16: begin opc_w=MSUB; addr_a_w=A_ZT1;    addr_b_w=A_DELTA;  addr_res_w=A_PZ;     end
            5'd17: begin opc_w=MSUB; addr_a_w=A_BETA4;  addr_b_w=A_PX;     addr_res_w=A_Y3T1;   end
            5'd18: begin opc_w=MMUL; addr_a_w=A_W;      addr_b_w=A_Y3T1;   addr_res_w=A_Y3T2;   end
            5'd19: begin opc_w=MMUL; addr_a_w=A_GAMMA;  addr_b_w=A_GAMMA;  addr_res_w=A_GAMMAK; end
            5'd20: begin opc_w=MADD; addr_a_w=A_GAMMAK; addr_b_w=A_GAMMAK; addr_res_w=A_G2;     end
            5'd21: begin opc_w=MADD; addr_a_w=A_G2;     addr_b_w=A_G2;     addr_res_w=A_G4;     end
            5'd22: begin opc_w=MADD; addr_a_w=A_G4;     addr_b_w=A_G4;     addr_res_w=A_G8;     end
            5'd23: begin opc_w=MSUB; addr_a_w=A_Y3T2;   addr_b_w=A_G8;     addr_res_w=A_PY;     end
            default: ;
        endcase
    end else begin
        case (step_r)  // ADD
            5'd0:  begin opc_w=MMUL; addr_a_w=A_P1Z;    addr_b_w=A_P1Z;    addr_res_w=A_Z1K;    end
            5'd1:  begin opc_w=MMUL; addr_a_w=A_P2Z;    addr_b_w=A_P2Z;    addr_res_w=A_Z2K;    end
            5'd2:  begin opc_w=MMUL; addr_a_w=A_Z1K;    addr_b_w=A_P1Z;    addr_res_w=A_Z1KUP;  end
            5'd3:  begin opc_w=MMUL; addr_a_w=A_Z2K;    addr_b_w=A_P2Z;    addr_res_w=A_Z2KUP;  end
            5'd4:  begin opc_w=MMUL; addr_a_w=A_P1X;    addr_b_w=A_Z2K;    addr_res_w=A_U1;     end
            5'd5:  begin opc_w=MMUL; addr_a_w=A_P2X;    addr_b_w=A_Z1K;    addr_res_w=A_U2;     end
            5'd6:  begin opc_w=MMUL; addr_a_w=A_P1Y;    addr_b_w=A_Z2KUP;  addr_res_w=A_S1;     end
            5'd7:  begin opc_w=MMUL; addr_a_w=A_P2Y;    addr_b_w=A_Z1KUP;  addr_res_w=A_S2;     end
            5'd8:  begin opc_w=MSUB; addr_a_w=A_U2;     addr_b_w=A_U1;     addr_res_w=A_H;      end
            5'd9:  begin opc_w=MSUB; addr_a_w=A_S2;     addr_b_w=A_S1;     addr_res_w=A_R;      end
            5'd10: begin opc_w=MMUL; addr_a_w=A_H;      addr_b_w=A_H;      addr_res_w=A_H2;     end
            5'd11: begin opc_w=MMUL; addr_a_w=A_H2;     addr_b_w=A_H;      addr_res_w=A_H3;     end
            5'd12: begin opc_w=MMUL; addr_a_w=A_U1;     addr_b_w=A_H2;     addr_res_w=A_U1H2;   end
            5'd13: begin opc_w=MMUL; addr_a_w=A_R;      addr_b_w=A_R;      addr_res_w=A_R2;     end
            5'd14: begin opc_w=MADD; addr_a_w=A_U1H2;   addr_b_w=A_U1H2;   addr_res_w=A_U1H2X2; end
            5'd15: begin opc_w=MSUB; addr_a_w=A_R2;     addr_b_w=A_H3;     addr_res_w=A_X3T1;   end
            5'd16: begin opc_w=MSUB; addr_a_w=A_X3T1;   addr_b_w=A_U1H2X2; addr_res_w=A_PX;     end
            5'd17: begin opc_w=MSUB; addr_a_w=A_U1H2;   addr_b_w=A_PX;     addr_res_w=A_Y3T1A;  end
            5'd18: begin opc_w=MMUL; addr_a_w=A_R;      addr_b_w=A_Y3T1A;  addr_res_w=A_Y3T2A;  end
            5'd19: begin opc_w=MMUL; addr_a_w=A_S1;     addr_b_w=A_H3;     addr_res_w=A_Y3T3A;  end
            5'd20: begin opc_w=MSUB; addr_a_w=A_Y3T2A;  addr_b_w=A_Y3T3A;  addr_res_w=A_PY;     end
            5'd21: begin opc_w=MMUL; addr_a_w=A_H;      addr_b_w=A_P1Z;    addr_res_w=A_ZT1A;   end   // H·Z1
            5'd22: begin opc_w=MMUL; addr_a_w=A_ZT1A;   addr_b_w=A_P2Z;    addr_res_w=A_PZ;     end   // Z3 = H·Z1·Z2
            5'd23: begin opc_w=MADD; dummy_w=1'b1; store_w=1'b0; end                                    // SCA dummy (24 adım korunur)
            default: ;
        endcase
    end
end

// =====================================================================
// BRAM okuma adresi / yazma denetimi (KOMBİNASYONEL)
// =====================================================================
always @* begin
    // ── Okuma adresi ──────────────────────────────────────────────────
    case (state_r)
        ST_EXEC_SET: mem_ra_c = addr_a_w;
        ST_RD_A:     mem_ra_c = addr_b_r;
        ST_OUT_RA:   mem_ra_c = tx_base_r + {4'd0, out_coord_r};
        default:     mem_ra_c = 6'd0;
    endcase
    // ── Yazma ─────────────────────────────────────────────────────────
    mem_we_c = 1'b0; mem_wa_c = 6'd0; mem_wd_c = 256'd0;
    if (state_r == ST_IDLE) begin
        if (i_pkt_vld && (i_pkt_sel != PIX_MODP) && (pkt_rx_cnt_r == 3'd7)) begin
            mem_we_c = 1'b1; mem_wa_c = slot_w; mem_wd_c = {i_pkt_in, asm_r[223:0]};
        end
    end else if (state_r == ST_STORE) begin
        if (i_cmd_r==1'b1 && step_r==5'd8 && (mdsp_res_r==256'd0)) begin
            mem_we_c = 1'b1; mem_wa_c = A_PZ; mem_wd_c = 256'd0;   // P=Q: pz=0
        end else if (store_r) begin
            mem_we_c = 1'b1; mem_wa_c = addr_res_r; mem_wd_c = mdsp_res_r;
        end
    end
end

// =====================================================================
// Ana FSM
// =====================================================================
always @(posedge clk_in or negedge rst_n) begin
    if (!rst_n) begin
        state_r <= ST_IDLE;
        o_rdy_r<=1'b0; o_done_r<=1'b0; o_pkt_vld_r<=1'b0; o_err_r<=1'b0;
        o_pkt_out_r<=32'd0; o_pkt_sel_r<=2'd0; o_pkt_last_r<=1'b0;
        malu_pkt_vld_r<=1'b0; malu_pkt_dat_r<=32'd0;
        malu_pkt_sel_r<=2'd0; malu_opc_r<=2'd0; malu_st_r<=1'b0;
        mod_p_r<=256'd0; i_cmd_r<=1'b0; asm_r<=256'd0;
        p1z_nz_r<=1'b0; p2z_nz_r<=1'b0;
        mdsp_a_r<=256'd0; mdsp_b_r<=256'd0; mdsp_res_r<=256'd0;
        mdsp_opc_r<=2'd0; mdsp_cnt_r<=3'd0;
        addr_b_r<=6'd0; addr_res_r<=6'd0; store_r<=1'b1;
        step_r<=5'd0; malu_wdog_r<=12'd0;
        pkt_rx_cnt_r<=3'd0; pkt_tx_cnt_r<=3'd0;
        out_r<=256'd0; out_coord_r<=2'd0; tx_base_r<=A_PX;
    end else begin
        o_done_r<=1'b0; o_pkt_vld_r<=1'b0; o_pkt_last_r<=1'b0; o_err_r<=1'b0;
        malu_st_r<=1'b0; malu_pkt_vld_r<=1'b0;

        if (malu_err_w) begin
            o_err_r <= 1'b1;
            state_r <= ST_IDLE;
        end else begin

        case (state_r)

            ST_IDLE: begin
                o_rdy_r <= 1'b1;
                if (i_pkt_vld) begin
                    if (i_pkt_sel == PIX_MODP)
                        mod_p_r[pkt_rx_cnt_r*32 +: 32] <= i_pkt_in;
                    else
                        asm_r[pkt_rx_cnt_r*32 +: 32] <= i_pkt_in;   // BRAM yazma comb blokta
                    if (i_pkt_sel == PIX_P1Z)
                        p1z_nz_r <= (pkt_rx_cnt_r==3'd0) ? (i_pkt_in!=32'd0)
                                                         : (p1z_nz_r | (i_pkt_in!=32'd0));
                    if (i_pkt_sel == PIX_P2Z)
                        p2z_nz_r <= (pkt_rx_cnt_r==3'd0) ? (i_pkt_in!=32'd0)
                                                         : (p2z_nz_r | (i_pkt_in!=32'd0));
                    pkt_rx_cnt_r <= pkt_rx_cnt_r + 3'd1;
                end
                if (i_start) begin
                    o_rdy_r <= 1'b0; i_cmd_r <= i_cmd; step_r <= 5'd0;
                    state_r <= ST_CHK_INF;
                end
            end

            ST_CHK_INF: begin
                if (i_cmd_r == 1'b1) begin
                    if (!p1z_nz_r) begin tx_base_r<=A_P2X; out_coord_r<=2'd0; state_r<=ST_OUT_RA; end
                    else if (!p2z_nz_r) begin tx_base_r<=A_P1X; out_coord_r<=2'd0; state_r<=ST_OUT_RA; end
                    else begin mdsp_cnt_r<=3'd0; state_r<=ST_INIT_P; end
                end else begin
                    if (!p1z_nz_r) begin tx_base_r<=A_P1X; out_coord_r<=2'd0; state_r<=ST_OUT_RA; end
                    else begin mdsp_cnt_r<=3'd0; state_r<=ST_INIT_P; end
                end
            end

            ST_INIT_P: begin
                malu_pkt_vld_r <= 1'b1;
                malu_pkt_dat_r <= mod_p_r[mdsp_cnt_r*32 +: 32];
                malu_pkt_sel_r <= MSEL_P;
                if (mdsp_cnt_r == 3'd7) begin mdsp_cnt_r<=3'd0; state_r<=ST_EXEC_SET; end
                else mdsp_cnt_r <= mdsp_cnt_r + 3'd1;
            end

            ST_EXEC_SET: begin
                mdsp_opc_r <= opc_w;
                addr_res_r <= addr_res_w;
                store_r    <= store_w;
                mdsp_cnt_r <= 3'd0;
                if (dummy_w) begin
                    mdsp_a_r <= 256'd0; mdsp_b_r <= 256'd0;
                    state_r  <= ST_TX_A;
                end else begin
                    addr_b_r <= addr_b_w;   // mem_ra_c = addr_a_w (comb, bu çevrim)
                    state_r  <= ST_RD_A;
                end
            end

            ST_RD_A: begin
                mdsp_a_r <= mem_rd_r;       // ara_mem[addr_a]
                state_r  <= ST_RD_B;        // mem_ra_c = addr_b_r (comb, bu çevrim)
            end

            ST_RD_B: begin
                mdsp_b_r <= mem_rd_r;       // ara_mem[addr_b]
                state_r  <= ST_TX_A;
            end

            ST_TX_A: begin
                malu_pkt_vld_r <= 1'b1;
                malu_pkt_dat_r <= mdsp_a_r[mdsp_cnt_r*32 +: 32];
                malu_pkt_sel_r <= MSEL_A;
                malu_opc_r     <= mdsp_opc_r;
                if (mdsp_cnt_r == 3'd7) begin mdsp_cnt_r<=3'd0; state_r<=ST_TX_B; end
                else mdsp_cnt_r <= mdsp_cnt_r + 3'd1;
            end

            ST_TX_B: begin
                malu_pkt_vld_r <= 1'b1;
                malu_pkt_dat_r <= mdsp_b_r[mdsp_cnt_r*32 +: 32];
                malu_pkt_sel_r <= MSEL_B;
                if (mdsp_cnt_r == 3'd7) begin mdsp_cnt_r<=3'd0; state_r<=ST_MALU_GO; end
                else mdsp_cnt_r <= mdsp_cnt_r + 3'd1;
            end

            ST_MALU_GO: begin
                malu_st_r   <= 1'b1;
                malu_opc_r  <= mdsp_opc_r;
                malu_wdog_r <= 12'd0;
                state_r     <= ST_MALU_WT;
            end

            ST_MALU_WT: begin
                if (malu_wdog_r >= MALU_WDOG_MAX) begin
                    o_err_r<=1'b1; o_rdy_r<=1'b1; state_r<=ST_IDLE;
                end else if (malu_pkt_vld_w) begin
                    mdsp_res_r[0 +: 32] <= malu_pkt_out_w;
                    mdsp_cnt_r <= 3'd1;
                    state_r    <= ST_RX_RES;
                end else malu_wdog_r <= malu_wdog_r + 12'd1;
            end

            ST_RX_RES: begin
                if (malu_pkt_vld_w) begin
                    mdsp_res_r[mdsp_cnt_r*32 +: 32] <= malu_pkt_out_w;
                    if (mdsp_cnt_r == 3'd7) begin mdsp_cnt_r<=3'd0; state_r<=ST_STORE; end
                    else mdsp_cnt_r <= mdsp_cnt_r + 3'd1;
                end
            end

            ST_STORE: begin
                // BRAM yazma comb blokta gerçekleşir (bu çevrim kenarında)
                if (i_cmd_r==1'b1 && step_r==5'd8 && (mdsp_res_r==256'd0)) begin
                    o_err_r  <= 1'b1;   // P=Q → sonsuzluk (pz=0), çıkışa geç
                    tx_base_r<=A_PX; out_coord_r<=2'd0; state_r<=ST_OUT_RA;
                end else if (step_r == 5'd23) begin
                    tx_base_r<=A_PX; out_coord_r<=2'd0; state_r<=ST_OUT_RA;
                end else begin
                    step_r  <= step_r + 5'd1;
                    state_r <= ST_EXEC_SET;
                end
            end

            ST_OUT_RA: begin
                // mem_ra_c = tx_base_r + out_coord_r (comb, bu çevrim)
                state_r <= ST_OUT_LAT;
            end

            ST_OUT_LAT: begin
                out_r        <= mem_rd_r;
                pkt_tx_cnt_r <= 3'd0;
                state_r      <= ST_OUT_TX;
            end

            ST_OUT_TX: begin
                o_pkt_vld_r  <= 1'b1;
                o_pkt_sel_r  <= out_coord_r;
                o_pkt_out_r  <= out_r[pkt_tx_cnt_r*32 +: 32];
                o_pkt_last_r <= (pkt_tx_cnt_r == 3'd7);
                if (pkt_tx_cnt_r == 3'd7) begin
                    if (out_coord_r == 2'd2) state_r <= ST_DONE;
                    else begin out_coord_r <= out_coord_r + 2'd1; state_r <= ST_OUT_RA; end
                end else pkt_tx_cnt_r <= pkt_tx_cnt_r + 3'd1;
            end

            ST_DONE: begin
                o_done_r <= 1'b1;
                o_rdy_r  <= 1'b1;
                state_r  <= ST_IDLE;
            end

            default: state_r <= ST_IDLE;

        endcase
        end
    end
end

endmodule
