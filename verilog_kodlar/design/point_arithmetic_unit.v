// =============================================================================
// Modül   : point_arithmetic_unit.v   (SABİT ZAMANLI sürüm - SPA düzeltmesi)
// Proje   : FPGA Tabanlı Güvenli Anahtar Yönetimi ve Kripto Hızlandırıcı
// No      : 5260007 - Sakarya Uygulamalı Bilimler Üniversitesi
// -----------------------------------------------------------------------------
// BU SÜRÜMDEKİ DEĞİŞİKLİK (tek konu: zamanlama yan-kanalı)
//
//   SORUN:
//     Önceki sürümde ST_CHK_INF durumu, operandlardan biri sonsuz nokta ise
//     (Z = 0) 24 adımlık hesabın TAMAMINI atlayıp doğrudan çıkışa geçiyordu.
//     Montgomery Ladder, skalerin baştaki sıfır bitleri boyunca R0 = ∞ tuttuğu
//     için bu kısayol tam olarak "d'nin baştaki sıfır sayısı" kadar tetikleniyor
//     ve toplam süreyi anahtara bağlı hale getiriyordu.
//     Ölçüm (tb_ecdh_demo_top.sv, Senaryo 4): baştaki her sıfır biti için
//     7.766 çevrim kazanç → süreyi ölçen saldırgan d'nin bit uzunluğunu okur.
//     İkinci dal: ST_STORE içinde ADD adım 8'de H == 0 ise erken çıkış.
//
//   ÇÖZÜM (işi atlamak yerine yapıp sonucu atmak):
//     [1] ST_CHK_INF artık KOŞULSUZ olarak ST_INIT_P'ye geçer. Sonsuz-nokta
//         durumu ne olursa olsun 24 adımın tamamı çalışır.
//     [2] Özel durum seçimi ÇIKIŞ aşamasına taşındı: tx_base_w kombinasyonel
//         mux'u, okunacak BRAM slotunu p1z_nz_r / p2z_nz_r / h_sifir_r'ye göre
//         seçer. Kontrol akışı değil, yalnızca okunan adres değişir.
//     [3] ADD adım 8'deki H == 0 dalı kaldırıldı; yerine h_sifir_r bayrağı
//         kaydedilir, 24 adım her koşulda tamamlanır, sonuç çıkışta maskelenir.
//
//   ÇIKIŞ DEĞERLERİ BİT-BİREBİR AYNIDIR:
//     ADD, P1 = ∞  → P2 döner   (eskisi gibi)
//     ADD, P2 = ∞  → P1 döner   (eskisi gibi)
//     DBL, P1 = ∞  → P1 döner   (eskisi gibi; hesaplanan Z3 de zaten 0'dır)
//     Normal durumlar → değişiklik yok
//   Yalnızca ZAMANLAMA değişir. Fonksiyonel regresyon beklenmez.
//
//   TEK DAVRANIŞ FARKI (hata yolu):
//     ADD'de H == 0 (P = Q) durumunda o_err artık 8. adımda değil, işlem
//     tamamlandıktan sonra ST_DONE'da yükselir ve Z = 0 zorlanır. Bu durum
//     ECDH ladder'ında oluşmaz (R0 ile R1 daima P kadar farklıdır).
//
//   MALİYET:
//     En kötü durum süresi DEĞİŞMEZ. Baştaki sıfırı olan anahtarlar artık en
//     kötü durum kadar sürer → toplam süre sabitlenir (~2.133.646 çevrim).
//     Alan maliyeti yok; bir bayrak kayıtçısı ve küçük bir adres mux'u eklendi.
//
//   NOT: modular_alu.v incelendi, sabit zamanlıdır (MontMult daima 256
//        iterasyon; indirgeme borrow-select mux'u). Değişiklik gerekmez.
//        scalar_multiplier.v de temizdir; ladder döngüsü koşulsuz 256 turdur.
//
// -----------------------------------------------------------------------------
// ÖNCEKİ SÜRÜMÜN AÇIKLAMASI (BRAM scratchpad + wire/reg ayrımı) GEÇERLİDİR:
//   [1] ~40 adet 256-bit ara saklayıcı tek bir Block RAM'e (ara_mem[0:63])
//       taşındı; okuma adresi/yazma denetimi kombinasyonel, okuma çıkışı
//       kayıtlı (mem_rd_r) - kanonik BRAM inference şablonu.
//   [2] Tüm çıkış portları saf 'wire'; senkron değerler '*_r'de tutulur.
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
// =====================================================================
// Seçici / Opcode Sabitleri
// =====================================================================
localparam [2:0] PIX_MODP=3'd0, PIX_P1X=3'd1, PIX_P1Y=3'd2, PIX_P1Z=3'd3,
                 PIX_P2X=3'd4, PIX_P2Y=3'd5, PIX_P2Z=3'd6;
localparam [1:0] POX_PX=2'd0, POX_PY=2'd1, POX_PZ=2'd2;
localparam [1:0] MADD=2'b00, MSUB=2'b01, MMUL=2'b10;
localparam [1:0] MSEL_A=2'b00, MSEL_B=2'b01, MSEL_P=2'b10;
// =====================================================================
// BRAM Scratchpad Slot Adresleri (operand id - 6-bit)
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
    A_Y3T2A=6'd48,A_Y3T3A=6'd49,A_ZT1A=6'd50,
    A_MODP =6'd51;   // [YENİ] mod p artık BRAM'de (mod_p_r yazmacı elendi)
// =====================================================================
// FSM Durumları (5-bit)
// =====================================================================
localparam [4:0]
    ST_IDLE=5'd0, ST_CHK_INF=5'd1, ST_INITP_RD=5'd2, ST_EXEC_SET=5'd3,
    ST_INITP_TX=5'd4, ST_TXA_RD=5'd5, ST_TX_A=5'd6, ST_TX_B=5'd7,
    ST_MALU_GO=5'd8, ST_MALU_WT=5'd9, ST_RX_RES=5'd10, ST_STORE=5'd11,
    ST_OUT_RA=5'd12, ST_TXB_RD=5'd13, ST_OUT_TX=5'd14, ST_DONE=5'd15;
reg [4:0] state_r;
localparam [11:0] MALU_WDOG_MAX = 12'd4000;
// =====================================================================
// Block RAM Scratchpad - KOMBİNASYONEL adres/yazma + kayıtlı okuma çıkışı
// =====================================================================
// =============================================================================
// TEMMUZ 2026 — BELLEK 32 BİT GENİŞLİĞE ÇEVRİLDİ (Nihai Mimari, Adım 5)
//
//   ÖNCEKİ DURUM: Bellek zaten Block RAM'di ama 256 BİT GENİŞTİ. Değer
//   bellekten 256 bit çıkıp `[mdsp_cnt_r*32 +: 32]` ile dilimlendiği için
//   part-select mux'ları OLDUĞU GİBİ duruyordu — LUT kazancı gerçekleşmemişti
//   (1348 LUT / 1641 FF, 7 part-select). Ayrıca 64×256 bit = 16 Kbit, 256-bit
//   genişlikte 4 RAMB36 işgal ediyordu (genişlik sınırı yüzünden).
//
//   YAPILAN: adres = {slot[5:0], sozcuk[2:0]} — 512 sözcük × 32 bit.
//     - okuma mux'u ve yazma çözücüsü YOK
//     - mdsp_a_r / mdsp_b_r / mdsp_res_r / out_r / mod_p_r / asm_r elendi
//       (6 × 256 = 1536 FF)
//     - aynı 16 Kbit artık TEK RAMB18'e sığar (4 RAMB36 -> 1 RAMB18)
//
//   mod_p artık BRAM'de A_MODP slotunda durur (eskiden ayrı yazmaçtı).
//
//   *** BRAM 1 ÇEVRİM GECİKMELİDİR: okuma adresi FETCH *VE* KULLANIM
//   durumunun İKİSİNDE de tutulur; RD/TX durumları ALMAŞIK olmak zorundadır ***
//
//   SABİT ZAMANLILIK KORUNDU: tx_base_w seçimi ve 24 adımlık koşulsuz akış
//   aynen duruyor; yalnızca depolama biçimi değişti.
// =============================================================================
(* ram_style = "block" *) reg [31:0] ara_mem [0:511];
reg [31:0] mem_rd_r;
reg [8:0]  mem_ra_c;
reg        mem_we_c;
reg [8:0]  mem_wa_c;
reg [31:0] mem_wd_c;
always @(posedge clk_in) begin
    if (mem_we_c) ara_mem[mem_wa_c] <= mem_wd_c;
    mem_rd_r <= ara_mem[mem_ra_c];
end
// =====================================================================
// Kayıtçılar
// =====================================================================
// mod_p_r / asm_r / mdsp_a_r / mdsp_b_r / mdsp_res_r / out_r KALDIRILDI
reg        res_nz_r;    // MALU sonucu sıfırdan farklı mı (h_sifir tespiti)
reg        dummy_r;     // sahte adım: operand olarak 0 gönderilir
reg         i_cmd_r;
reg         p1z_nz_r, p2z_nz_r;
reg         h_sifir_r;          // [YENİ] ADD adım 8'de H == 0 görüldü (P = Q)
reg [1:0]   mdsp_opc_r;
reg [2:0]   mdsp_cnt_r;
reg [5:0]   addr_a_r, addr_b_r, addr_res_r;
reg         store_r;
reg [4:0]   step_r;
reg [11:0]  malu_wdog_r;
reg [2:0]   pkt_rx_cnt_r, pkt_tx_cnt_r;
reg [1:0]   out_coord_r;
// NOT: tx_base_r kaldırıldı → kombinasyonel tx_base_w ile değiştirildi.
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
// MALU dış arayüzü
// =====================================================================
reg         malu_pkt_vld_r;
reg  [31:0] malu_pkt_dat_r;
reg  [1:0]  malu_pkt_sel_r;
reg  [1:0]  malu_opc_r;
reg         malu_st_r;
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
// [YENİ] SABİT ZAMANLI SONUÇ SEÇİMİ
//   Sonsuz-nokta ve P=Q durumları kontrol akışında DEĞİL, burada çözülür.
//   Hesap her koşulda 24 adım çalışır; yalnızca okunacak slot değişir.
//     ADD: P1 = ∞      → sonuç P2   (slot A_P2X..A_P2Z)
//          P2 = ∞      → sonuç P1   (slot A_P1X..A_P1Z)
//          H  = 0      → sonuç ∞    (A_PX..A_PZ, Z zorla 0)
//     DBL: P1 = ∞      → sonuç P1   (Z zaten 0; eski davranışla birebir)
// =====================================================================
reg [5:0] tx_base_w;
reg       zorla_inf_w;
always @* begin
    tx_base_w   = A_PX;
    zorla_inf_w = 1'b0;
    if (i_cmd_r == 1'b1) begin              // ── ADD ──
        if      (!p1z_nz_r) tx_base_w = A_P2X;
        else if (!p2z_nz_r) tx_base_w = A_P1X;
        else if (h_sifir_r) begin tx_base_w = A_PX; zorla_inf_w = 1'b1; end
    end else begin                          // ── DBL ──
        if (!p1z_nz_r) tx_base_w = A_P1X;
    end
end
// =====================================================================
// Adım operand/sonuç ÇÖZÜMÜ (kombinasyonel) - 6-bit BRAM adresleri
//   Adım tabloları önceki sürümle BİREBİR AYNIDIR.
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
            5'd21: begin opc_w=MMUL; addr_a_w=A_H;      addr_b_w=A_P1Z;    addr_res_w=A_ZT1A;   end
            5'd22: begin opc_w=MMUL; addr_a_w=A_ZT1A;   addr_b_w=A_P2Z;    addr_res_w=A_PZ;     end
            5'd23: begin opc_w=MADD; dummy_w=1'b1; store_w=1'b0; end
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
        //   Adres hem FETCH hem KULLANIM durumunda tutulur (BRAM 1 çevrim
        //   gecikmeli; yalnız fetch'te verilirse mem_rd_r sessizce bozulur).
        ST_INITP_RD, ST_INITP_TX: mem_ra_c = {A_MODP,   mdsp_cnt_r};
        ST_TXA_RD,   ST_TX_A:     mem_ra_c = {addr_a_r, mdsp_cnt_r};
        ST_TXB_RD,   ST_TX_B:     mem_ra_c = {addr_b_r, mdsp_cnt_r};
        ST_OUT_RA,   ST_OUT_TX:   mem_ra_c = {tx_base_w + {4'd0, out_coord_r},
                                              pkt_tx_cnt_r};
        default:     mem_ra_c = 9'd0;
    endcase
    // ── Yazma ─────────────────────────────────────────────────────────
    //   [DEĞİŞTİ] P=Q özel yazması kaldırıldı; artık çıkışta maskeleniyor.
    //   Giriş paketi ve MALU sonucu artık DOĞRUDAN sözcük olarak yazılır
    //   (asm_r / mdsp_res_r ara tamponları elendi).
    mem_we_c = 1'b0; mem_wa_c = 9'd0; mem_wd_c = 32'd0;
    if (state_r == ST_IDLE) begin
        if (i_pkt_vld) begin
            mem_we_c = 1'b1;
            mem_wa_c = {(i_pkt_sel == PIX_MODP) ? A_MODP : slot_w, pkt_rx_cnt_r};
            mem_wd_c = i_pkt_in;
        end
    end else if ((state_r == ST_MALU_WT) || (state_r == ST_RX_RES)) begin
        if (malu_pkt_vld_w && store_r) begin
            mem_we_c = 1'b1;
            mem_wa_c = {addr_res_r, mdsp_cnt_r};
            mem_wd_c = malu_pkt_out_w;
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
        i_cmd_r<=1'b0;
        p1z_nz_r<=1'b0; p2z_nz_r<=1'b0; h_sifir_r<=1'b0;
        res_nz_r<=1'b0; dummy_r<=1'b0;
        mdsp_opc_r<=2'd0; mdsp_cnt_r<=3'd0;
        addr_a_r<=6'd0; addr_b_r<=6'd0; addr_res_r<=6'd0; store_r<=1'b1;
        step_r<=5'd0; malu_wdog_r<=12'd0;
        pkt_rx_cnt_r<=3'd0; pkt_tx_cnt_r<=3'd0;
        out_coord_r<=2'd0;
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
                    // Veri BRAM'e yazma bloğunda gidiyor; burada bayraklar
                    if (i_pkt_sel == PIX_P1Z)
                        p1z_nz_r <= (pkt_rx_cnt_r==3'd0) ? (i_pkt_in!=32'd0)
                                                         : (p1z_nz_r | (i_pkt_in!=32'd0));
                    if (i_pkt_sel == PIX_P2Z)
                        p2z_nz_r <= (pkt_rx_cnt_r==3'd0) ? (i_pkt_in!=32'd0)
                                                         : (p2z_nz_r | (i_pkt_in!=32'd0));
                    pkt_rx_cnt_r <= pkt_rx_cnt_r + 3'd1;
                end
                if (i_start) begin
                    o_rdy_r   <= 1'b0; i_cmd_r <= i_cmd; step_r <= 5'd0;
                    h_sifir_r <= 1'b0;                 // [YENİ] bayrağı temizle
                    state_r   <= ST_CHK_INF;
                end
            end
            // ─────────────────────────────────────────────────────────
            // [DEĞİŞTİ] SABİT ZAMAN: sonsuz-nokta kısayolu KALDIRILDI.
            //   Eskiden burada 24 adım atlanıp ST_OUT_RA'ya gidiliyordu;
            //   bu, d'nin baştaki sıfır bitlerini zamanlamayla sızdırıyordu.
            //   Artık her koşulda hesabın tamamı çalışır; özel durum yalnızca
            //   çıkıştaki tx_base_w mux'uyla seçilir.
            //   Durum, ardışık düzeni (1 çevrim gecikme) bozmamak için korundu.
            // ─────────────────────────────────────────────────────────
            ST_CHK_INF: begin
                mdsp_cnt_r <= 3'd0;
                state_r    <= ST_INITP_RD;
            end
            //   mod p BRAM'den akıtılır (RD/TX almaşık — 1 çevrim gecikme)
            ST_INITP_RD: state_r <= ST_INITP_TX;
            ST_INITP_TX: begin
                malu_pkt_vld_r <= 1'b1;
                malu_pkt_dat_r <= mem_rd_r;
                malu_pkt_sel_r <= MSEL_P;
                if (mdsp_cnt_r == 3'd7) begin mdsp_cnt_r<=3'd0; state_r<=ST_EXEC_SET; end
                else begin mdsp_cnt_r <= mdsp_cnt_r + 3'd1; state_r<=ST_INITP_RD; end
            end
            ST_EXEC_SET: begin
                mdsp_opc_r <= opc_w;
                addr_res_r <= addr_res_w;
                store_r    <= store_w;
                mdsp_cnt_r <= 3'd0;
                //   Operandlar artık BRAM'den AKITILIR; mdsp_a_r/mdsp_b_r
                //   ara tamponları elendi. Sahte adımda (dummy) BRAM yerine
                //   sıfır gönderilir.
                addr_a_r <= addr_a_w;
                addr_b_r <= addr_b_w;
                dummy_r  <= dummy_w;
                state_r  <= ST_TXA_RD;
            end
            ST_TXA_RD: state_r <= ST_TX_A;
            ST_TX_A: begin
                malu_pkt_vld_r <= 1'b1;
                malu_pkt_dat_r <= dummy_r ? 32'd0 : mem_rd_r;
                malu_pkt_sel_r <= MSEL_A;
                malu_opc_r     <= mdsp_opc_r;
                if (mdsp_cnt_r == 3'd7) begin mdsp_cnt_r<=3'd0; state_r<=ST_TXB_RD; end
                else begin mdsp_cnt_r <= mdsp_cnt_r + 3'd1; state_r<=ST_TXA_RD; end
            end
            ST_TXB_RD: state_r <= ST_TX_B;
            ST_TX_B: begin
                malu_pkt_vld_r <= 1'b1;
                malu_pkt_dat_r <= dummy_r ? 32'd0 : mem_rd_r;
                malu_pkt_sel_r <= MSEL_B;
                if (mdsp_cnt_r == 3'd7) begin mdsp_cnt_r<=3'd0; state_r<=ST_MALU_GO; end
                else begin mdsp_cnt_r <= mdsp_cnt_r + 3'd1; state_r<=ST_TXB_RD; end
            end
            ST_MALU_GO: begin
                malu_st_r   <= 1'b1;
                malu_opc_r  <= mdsp_opc_r;
                malu_wdog_r <= 12'd0;
                mdsp_cnt_r  <= 3'd0;
                res_nz_r    <= 1'b0;   // yeni sonuç için sıfırla
                state_r     <= ST_MALU_WT;
            end
            ST_MALU_WT: begin
                // İlk sözcük yazma bloğunda BRAM'e gitti (mdsp_cnt_r = 0)
                if (malu_wdog_r >= MALU_WDOG_MAX) begin
                    o_err_r<=1'b1; o_rdy_r<=1'b1; state_r<=ST_IDLE;
                end else if (malu_pkt_vld_w) begin
                    res_nz_r   <= (malu_pkt_out_w != 32'd0);
                    mdsp_cnt_r <= 3'd1;
                    state_r    <= ST_RX_RES;
                end else malu_wdog_r <= malu_wdog_r + 12'd1;
            end
            ST_RX_RES: begin
                if (malu_pkt_vld_w) begin
                    res_nz_r <= res_nz_r | (malu_pkt_out_w != 32'd0);
                    if (mdsp_cnt_r == 3'd7) begin mdsp_cnt_r<=3'd0; state_r<=ST_STORE; end
                    else mdsp_cnt_r <= mdsp_cnt_r + 3'd1;
                end
            end
            // ─────────────────────────────────────────────────────────
            // [DEĞİŞTİ] ADD adım 8'deki H==0 erken çıkışı KALDIRILDI.
            //   Yerine bayrak kaydedilir; 24 adım her koşulda tamamlanır.
            // ─────────────────────────────────────────────────────────
            ST_STORE: begin
                // Sonuç zaten sözcük sözcük BRAM'e yazıldı; sıfır olup
                // olmadığı res_nz_r'de biriktirildi (256-bit "==0" yerine).
                if (i_cmd_r==1'b1 && step_r==5'd8 && !res_nz_r)
                    h_sifir_r <= 1'b1;          // P = Q → sonuç sonsuzluk
                if (step_r == 5'd23) begin
                    out_coord_r <= 2'd0; pkt_tx_cnt_r <= 3'd0;
                    state_r <= ST_OUT_RA;
                end else begin
                    step_r  <= step_r + 5'd1;
                    state_r <= ST_EXEC_SET;
                end
            end
            //   Çıkış BRAM'den akıtılır (RA/TX almaşık — 1 çevrim gecikme).
            //   out_r ara tamponu elendi.
            ST_OUT_RA: state_r <= ST_OUT_TX;
            ST_OUT_TX: begin
                o_pkt_vld_r  <= 1'b1;
                o_pkt_sel_r  <= out_coord_r;
                // [YENİ] P=Q durumunda Z koordinatı 0 olarak maskelenir
                o_pkt_out_r  <= (zorla_inf_w && (out_coord_r == POX_PZ))
                                ? 32'd0
                                : mem_rd_r;
                o_pkt_last_r <= (pkt_tx_cnt_r == 3'd7);
                if (pkt_tx_cnt_r == 3'd7) begin
                    pkt_tx_cnt_r <= 3'd0;
                    if (out_coord_r == 2'd2) state_r <= ST_DONE;
                    else begin out_coord_r <= out_coord_r + 2'd1; state_r <= ST_OUT_RA; end
                end else begin
                    pkt_tx_cnt_r <= pkt_tx_cnt_r + 3'd1;
                    state_r <= ST_OUT_RA;
                end
            end
            ST_DONE: begin
                o_done_r <= 1'b1;
                o_rdy_r  <= 1'b1;
                // [YENİ] P=Q hatası artık işlem sonunda bildirilir (sabit zaman).
                //   DİKKAT: h_sifir_r yerine zorla_inf_w ile kapılanır. Çünkü
                //   P1 = ∞ iken de H = U2 - U1 hesaplanır ve sonucu 0 çıkabilir;
                //   bu gerçek bir P=Q durumu DEĞİLDİR (sonuç zaten P2'dir).
                //   zorla_inf_w yalnızca iki nokta da sonlu iken 1 olur.
                if (zorla_inf_w) o_err_r <= 1'b1;
                state_r  <= ST_IDLE;
            end
            default: state_r <= ST_IDLE;
        endcase
        end
    end
end
endmodule