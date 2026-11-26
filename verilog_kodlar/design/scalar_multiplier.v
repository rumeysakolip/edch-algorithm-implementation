// =============================================================================
// Modül   : scalar_multiplier.v   (Montgomery Ladder + XOR-CSWAP; 32-bit BRAM)
// Proje   : FPGA Tabanlı Güvenli Anahtar Yönetimi ve Kripto Hızlandırıcı
// No      : 5260007 — Sakarya Uygulamalı Bilimler Üniversitesi
// -----------------------------------------------------------------------------
// Açıklama:
//   P-256 sabit-zamanlı 256-bit skaler nokta çarpımı (d·G / d·Q). Montgomery
//   Ladder + XOR tabanlı koşulsuz CSWAP (SCA korumalı). Fonksiyon ve port
//   arayüzü öncekiyle AYNIDIR.
//
// -----------------------------------------------------------------------------
// TEMMUZ 2026 — 32-BİT SÖZCÜK-ADRESLİ BRAM DÖNÜŞÜMÜ (Nihai Mimari, Adım 5)
//
//   ÖLÇÜM: Hiyerarşik sentez raporunda bu modül 4892 LUT / 4765 FF ile tek
//   başına en büyük LUT tüketicisiydi. Sebep mantık değil DEPOLAMA BİÇİMİYDİ:
//   18 adet 256-bit yazmaç + 24 adet `[cnt_r*32 +: 32]` part-select. Her
//   part-select 32 bitlik bir 8:1 mux'tur ve ~150-200 LUT'a mal olur; 24 tanesi
//   ≈ 4000 LUT eder. Tasarımdaki 165 part-selectin toplamı (~26K LUT) zaten
//   28K'lık bütçenin tamamına denk geliyordu.
//
//   ÇÖZÜM: Değerleri 256-bit yazmaçta tutup mux'la dilimlemek yerine, her
//   256-bit değeri 8 ARDIŞIK 32-BİT SÖZCÜK olarak tek bir Block RAM'de
//   tutmak. Adres = {slot, sözcük_indisi}. Böylece:
//     - okuma mux'u YOK          (BRAM adresli okur)
//     - yazma çözücüsü YOK       (BRAM adresli yazar)
//     - 256-bit flip-flop'lar YOK (FF de düşer)
//   FSM'ler zaten cnt_r 0..7 döngüsüyle sözcük-seri çalıştığı için bu yapıya
//   doğal uyarlar; tek maliyet BRAM'in 1 çevrimlik okuma gecikmesidir
//   (her transferde bir FETCH adımı).
//
//   *** ÖNEMLİ — cift_skaler_carpim'de yapılan hatanın tekrarlanmaması ***
//   BRAM 32 BİT GENİŞ olmalıdır. 256-bit geniş bir BRAM kullanılırsa değer
//   bellekten 256 bit çıkar ve part-select mux'u OLDUĞU GİBİ KALIR — LUT
//   kazancı gerçekleşmez (csc'de tam bu oldu: FF 5303->1357 düştü ama LUT
//   yalnızca 3945->1452'ye indi, çünkü 10 part-select duruyordu).
//
// -----------------------------------------------------------------------------
// *** SABİT ZAMANLILIK — CSWAP NEDEN HÂLÂ GÜVENLİ ***
//   Önceki sürümün başlığı "CSWAP'ı word-seri hale getirmek doğrulanmış
//   sabit-zamanlı SCA yolunu bozma riski taşır" diyordu. Bu KOD KARMAŞIKLIĞI
//   riskidir, matematiksel bir engel değildir; ve burada korunmuştur:
//
//     [1] ÇEVRİM SAYISI VERİDEN BAĞIMSIZ: CSWAP her koşulda 3 koordinat ×
//         8 sözcük × 5 çevrim = 120 çevrim sürer. d'nin biti ne olursa olsun
//         aynı durum dizisi, aynı sayıda çevrim işletilir.
//     [2] ADRES DİZİSİ VERİDEN BAĞIMSIZ: okunan/yazılan BRAM adresleri
//         yalnızca (koordinat, sözcük) sayaçlarına bağlıdır. Gizli bite göre
//         DEĞİŞEN BİR ADRES YOKTUR — yani "koşullu işaretçi takası"nın
//         (conditional pointer swap) adres sızıntısı burada oluşmaz.
//     [3] MASKE KOŞULSUZ UYGULANIR: t = {32{d_bit}} & (a ^ b); a^t ve b^t
//         her zaman hesaplanır ve her zaman geri yazılır. Dallanma yoktur.
//   Kısacası gizli bit yalnızca YAZILAN VERİYİ etkiler, hiçbir zaman kontrol
//   akışını veya adresi etkilemez — kayıtçılı sürümle aynı güvence.
//
//   MALİYET: ladder adımı başına 2 CSWAP × 120 = 240 çevrim; 256 adımda
//   ~61K çevrim. Toplam ~2,1 M çevrimin %3'ü. Kabul edilebilir.
//
// -----------------------------------------------------------------------------
// BRAM YERLEŞİMİ (128 sözcük × 32 bit — tek RAMB18'e sığar)
//   adres = {slot[3:0], sozcuk[2:0]}
//     slot 0 : mod p          slot 4 : R0.X     slot 7 : R1.X
//     slot 1 : B.X            slot 5 : R0.Y     slot 8 : R1.Y
//     slot 2 : B.Y            slot 6 : R0.Z     slot 9 : R1.Z
//     slot 3 : B.Z
//   Skaler d BRAM'E KONMAZ: kaydırmalı d_shift_r olarak kalır (MSB-önce bit
//   erişimi gerekir ve zaten mux'suz bir kaydırma yazmacıdır).
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
    // ══ PAYLAŞILAN PAU DIŞ ARAYÜZÜ (master) ══════════════════════════════
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
    input  wire         pi_err
);

wire unused_rand = i_rand_vld | (|i_rand_seed);

localparam [2:0] SIX_MODP=3'd0, SIX_SCALAR=3'd1, SIX_BX=3'd2, SIX_BY=3'd3, SIX_BZ=3'd4;
localparam [2:0] PIX_MODP=3'd0, PIX_P1X=3'd1, PIX_P1Y=3'd2, PIX_P1Z=3'd3,
                 PIX_P2X=3'd4, PIX_P2Y=3'd5, PIX_P2Z=3'd6;

// ── BRAM slot adresleri ───────────────────────────────────────────────────
localparam [3:0] S_P  =4'd0, S_BX =4'd1, S_BY =4'd2, S_BZ =4'd3,
                 S_R0X=4'd4, S_R0Y=4'd5, S_R0Z=4'd6,
                 S_R1X=4'd7, S_R1Y=4'd8, S_R1Z=4'd9;

// ── Durumlar ──────────────────────────────────────────────────────────────
localparam [4:0]
    ST_IDLE     = 5'd0,
    ST_CP_RD    = 5'd1,   // ilkleme kopyasi: oku
    ST_CP_WR    = 5'd2,   // ilkleme kopyasi: yaz
    ST_MODP_RD  = 5'd3,   // mod p gonderimi: oku
    ST_MODP_TX  = 5'd4,   // mod p gonderimi: yaz
    ST_CS_RA    = 5'd5,   // CSWAP: R0 adresini kur
    ST_CS_RB    = 5'd6,   // CSWAP: R0 sozcugunu yakala + R1 adresini kur
    ST_LOOP     = 5'd7,   // ladder adim sonu karari (devam / cikis)
    ST_CS_W0    = 5'd8,   // CSWAP: R0'i geri yaz
    ST_CS_W1    = 5'd9,   // CSWAP: R1'i geri yaz
    ST_SND_RD   = 5'd10,  // PAU'ya operand: oku
    ST_SND_TX   = 5'd11,  // PAU'ya operand: gonder
    ST_GO       = 5'd12,  // PAU tetikle
    ST_RX       = 5'd13,  // PAU sonucunu BRAM'e al
    ST_TX_RD    = 5'd14,  // cikis: oku
    ST_TX_SND   = 5'd15,  // cikis: gonder
    ST_DONE     = 5'd16;

reg [4:0] state_r;
localparam [14:0] PAU_WDOG_MAX = 15'd25000;

// =====================================================================
// 32-bit genis Block RAM scratchpad
//   KOMBINASYONEL adres/yazma + KAYITLI okuma cikisi (kanonik sablon)
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

// ── Kayitcilar (256-bit olanlar YALNIZCA skaler icin kaldi) ───────────────
reg [255:0] d_r;         // giristen kaydirmali alinir (yazma mux'u yok)
reg [255:0] d_shift_r;   // ladder tarama yazmaci (MSB-once)
reg [8:0]   bit_idx_r;
reg [14:0]  pau_wdog_r;
reg [2:0]   pkt_rx_cnt_r;   // giris paketi sayaci
reg [2:0]   cnt_r;          // sozcuk sayaci (0..7)
reg [2:0]   cp_j_r;         // ilkleme kopyasi adimi (0..5)
reg [2:0]   snd_j_r;        // gonderilen koordinat (0..5)
reg [2:0]   snd_max_r;      // 5 = ADD (P1+P2), 2 = DBL (yalniz P1)
reg [1:0]   cs_j_r;         // CSWAP koordinati (0..2)
reg [4:0]   cs_ret_r;       // CSWAP sonrasi donus durumu
reg [31:0]  cs_a_r, cs_b_r, cs_t_r;
reg [3:0]   rx_base_r;      // PAU sonucunun yazilacagi slot tabani
reg [1:0]   tx_j_r;         // cikis koordinati
reg         pau_cmd_r;      // 1 = ADD, 0 = DBL

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

// ── CSWAP maskesi: gizli bit YALNIZCA VERIYI etkiler ─────────────────────
wire        cswap_bit_w = d_shift_r[255];
wire [31:0] cs_mask_w   = {32{cswap_bit_w}};

reg         pau_pkt_vld_r;
reg  [31:0] pau_pkt_dat_r;
reg  [2:0]  pau_pkt_sel_r;
reg         pau_st_r;
wire [31:0] pau_pkt_out_w  = pi_pkt_out;
wire        pau_pkt_vld_w  = pi_pkt_vld;
wire [1:0]  pau_pkt_sel_w  = pi_pkt_sel;
wire        pau_pkt_last_w = pi_pkt_last;
wire        pau_rdy_w      = pi_rdy;
wire        pau_done_w     = pi_done;
wire        pau_err_w      = pi_err;

assign po_pkt_dat = pau_pkt_dat_r;
assign po_pkt_vld = pau_pkt_vld_r;
assign po_pkt_sel = pau_pkt_sel_r;
assign po_cmd     = pau_cmd_r;
assign po_st      = pau_st_r;

// =====================================================================
// Ilkleme kopya tablosu:  R0 = (Bx, By, 0)   R1 = (Bx, By, Bz)
//   j : 0=R0X<-BX  1=R0Y<-BY  2=R0Z<-SIFIR  3=R1X<-BX  4=R1Y<-BY  5=R1Z<-BZ
// =====================================================================
reg [3:0] cp_src_w, cp_dst_w;
reg       cp_sifir_w;
always @* begin
    case (cp_j_r)
        3'd0: begin cp_src_w=S_BX; cp_dst_w=S_R0X; cp_sifir_w=1'b0; end
        3'd1: begin cp_src_w=S_BY; cp_dst_w=S_R0Y; cp_sifir_w=1'b0; end
        3'd2: begin cp_src_w=S_BX; cp_dst_w=S_R0Z; cp_sifir_w=1'b1; end
        3'd3: begin cp_src_w=S_BX; cp_dst_w=S_R1X; cp_sifir_w=1'b0; end
        3'd4: begin cp_src_w=S_BY; cp_dst_w=S_R1Y; cp_sifir_w=1'b0; end
        default: begin cp_src_w=S_BZ; cp_dst_w=S_R1Z; cp_sifir_w=1'b0; end
    endcase
end

// Giris seciciden BRAM slotuna esleme
reg [3:0] giris_slot_w;
always @* begin
    case (i_pkt_sel)
        SIX_MODP: giris_slot_w = S_P;
        SIX_BX:   giris_slot_w = S_BX;
        SIX_BY:   giris_slot_w = S_BY;
        default:  giris_slot_w = S_BZ;
    endcase
end

// =====================================================================
// BRAM OKUMA ADRESI (kombinasyonel)
//   *** FETCH ve KULLANIM durumlarinin IKISINDE de adres TUTULUR ***
//   mem_rd_r her cevrim ara_mem[mem_ra_c]'den yenilenir; adres yalnizca
//   fetch cevriminde dogru verilip sonraki cevrimde varsayilana donerse
//   okunan deger sessizce bozulur. (TB-19'da yakalanan hata tam olarak
//   buydu — burada bastan dogru yazildi.)
// =====================================================================
always @* begin
    mem_ra_c = 7'd0;
    case (state_r)
        ST_CP_RD, ST_CP_WR:     mem_ra_c = {cp_src_w, cnt_r};
        ST_MODP_RD, ST_MODP_TX: mem_ra_c = {S_P, cnt_r};
        ST_SND_RD, ST_SND_TX:   mem_ra_c = {S_R0X + {1'b0,snd_j_r}, cnt_r};
        ST_TX_RD, ST_TX_SND:    mem_ra_c = {S_R0X + {2'b00,tx_j_r}, cnt_r};
        // CSWAP okuma boru hatti (adresler gizli bitten BAGIMSIZ):
        //   ST_CS_RA'da R0 adresi kurulur -> ST_CS_RB'de R0 sozcugu hazir
        //   ST_CS_RB'de R1 adresi kurulur -> ST_CS_W0'da R1 sozcugu hazir
        ST_CS_RA:               mem_ra_c = {S_R0X + {2'b00,cs_j_r}, cnt_r};
        ST_CS_RB:               mem_ra_c = {S_R1X + {2'b00,cs_j_r}, cnt_r};
        default: ;
    endcase
end

// =====================================================================
// BRAM YAZMA DENETIMI (kombinasyonel)
// =====================================================================
always @* begin
    mem_we_c = 1'b0; mem_wa_c = 7'd0; mem_wd_c = 32'd0;
    if (state_r == ST_IDLE) begin
        if (i_pkt_vld && (i_pkt_sel != SIX_SCALAR)) begin
            mem_we_c = 1'b1;
            mem_wa_c = {giris_slot_w, pkt_rx_cnt_r};
            mem_wd_c = i_pkt_in;
        end
    end else if (state_r == ST_CP_WR) begin
        mem_we_c = 1'b1;
        mem_wa_c = {cp_dst_w, cnt_r};
        mem_wd_c = cp_sifir_w ? 32'd0 : mem_rd_r;
    end else if (state_r == ST_RX) begin
        if (pau_pkt_vld_w) begin
            mem_we_c = 1'b1;
            mem_wa_c = {rx_base_r + {2'b00,pau_pkt_sel_w}, cnt_r};
            mem_wd_c = pau_pkt_out_w;
        end
    end else if (state_r == ST_CS_W0) begin
        // R0' = a ^ (mask & (a ^ b))   — maske KOSULSUZ uygulanir
        mem_we_c = 1'b1;
        mem_wa_c = {S_R0X + {2'b00,cs_j_r}, cnt_r};
        mem_wd_c = cs_a_r ^ (cs_mask_w & (cs_a_r ^ mem_rd_r));
    end else if (state_r == ST_CS_W1) begin
        // R1' = b ^ t   (t bir onceki cevrimde saklandi)
        mem_we_c = 1'b1;
        mem_wa_c = {S_R1X + {2'b00,cs_j_r}, cnt_r};
        mem_wd_c = cs_b_r ^ cs_t_r;
    end
end

// =====================================================================
//  ANA DURUM MAKINESI
// =====================================================================
always @(posedge clk_in or negedge rst_n) begin
    if (!rst_n) begin
        state_r<=ST_IDLE;
        o_rdy_r<=1'b0; o_done_r<=1'b0; o_pkt_vld_r<=1'b0; o_err_r<=1'b0;
        o_pkt_out_r<=32'd0; o_pkt_sel_r<=2'd0; o_pkt_last_r<=1'b0;
        pau_pkt_vld_r<=1'b0; pau_pkt_dat_r<=32'd0;
        pau_pkt_sel_r<=3'd0; pau_cmd_r<=1'b0; pau_st_r<=1'b0;
        d_r<=256'd0; d_shift_r<=256'd0;
        bit_idx_r<=9'd255; pau_wdog_r<=15'd0;
        pkt_rx_cnt_r<=3'd0; cnt_r<=3'd0;
        cp_j_r<=3'd0; snd_j_r<=3'd0; snd_max_r<=3'd5;
        cs_j_r<=2'd0; cs_ret_r<=ST_IDLE;
        cs_a_r<=32'd0; cs_b_r<=32'd0; cs_t_r<=32'd0;
        rx_base_r<=S_R1X; tx_j_r<=2'd0;
    end else begin
        o_done_r<=1'b0; o_pkt_vld_r<=1'b0; o_pkt_last_r<=1'b0; o_err_r<=1'b0;
        pau_st_r<=1'b0; pau_pkt_vld_r<=1'b0;

        if (pau_err_w) begin
            o_err_r<=1'b1; o_rdy_r<=1'b1; state_r<=ST_IDLE;
        end else begin
        case (state_r)

            // ── BOSTA: operand yukleme ────────────────────────────────
            ST_IDLE: begin
                o_rdy_r <= 1'b1;
                if (i_pkt_vld) begin
                    // Skaler kaydirmali alinir: LSB-once gelen 8 sozcuk
                    // 8 kaydirmadan sonra dogru hizaya oturur. Boylece
                    // 256-bit indeksli yazma mux'u tamamen elenir.
                    if (i_pkt_sel == SIX_SCALAR)
                        d_r <= {i_pkt_in, d_r[255:32]};
                    // Diger operandlar dogrudan BRAM'e (yazma blogunda)
                    pkt_rx_cnt_r <= pkt_rx_cnt_r + 3'd1;
                end
                if (i_start) begin
                    if (d_r == 256'd0) begin o_err_r<=1'b1; o_rdy_r<=1'b1; end
                    else begin
                        o_rdy_r<=1'b0;
                        d_shift_r <= d_r;
                        bit_idx_r <= 9'd255;
                        cp_j_r<=3'd0; cnt_r<=3'd0;
                        state_r <= ST_CP_RD;
                    end
                end
            end

            // ── ILKLEME KOPYASI: R0=(Bx,By,0)  R1=(Bx,By,Bz) ──────────
            ST_CP_RD: state_r <= ST_CP_WR;
            ST_CP_WR: begin
                if (cnt_r == 3'd7) begin
                    cnt_r <= 3'd0;
                    if (cp_j_r == 3'd5) state_r <= ST_MODP_RD;
                    else begin cp_j_r <= cp_j_r + 3'd1; state_r <= ST_CP_RD; end
                end else begin
                    cnt_r <= cnt_r + 3'd1;
                    state_r <= ST_CP_RD;
                end
            end

            // ── mod p'yi PAU'ya bir kez gonder ────────────────────────
            ST_MODP_RD: state_r <= ST_MODP_TX;
            ST_MODP_TX: begin
                pau_pkt_vld_r <= 1'b1;
                pau_pkt_sel_r <= PIX_MODP;
                pau_pkt_dat_r <= mem_rd_r;
                if (cnt_r == 3'd7) begin
                    cnt_r <= 3'd0; cs_j_r <= 2'd0;
                    cs_ret_r <= ST_SND_RD;      // PRE-CSWAP -> ADD gonderimi
                    snd_j_r <= 3'd0; snd_max_r <= 3'd5; pau_cmd_r <= 1'b1;
                    rx_base_r <= S_R1X;
                    state_r <= ST_CS_RA;
                end else begin
                    cnt_r <= cnt_r + 3'd1;
                    state_r <= ST_MODP_RD;
                end
            end

            // ── CSWAP (sozcuk-seri, SABIT ZAMANLI) ───────────────────
            //   Adres dizisi ve cevrim sayisi gizli bitten BAGIMSIZDIR;
            //   bit yalnizca yazilan VERIYI etkiler.
            ST_CS_RA: state_r <= ST_CS_RB;   // R0 adresi kuruldu
            ST_CS_RB: begin
                cs_a_r  <= mem_rd_r;         // R0 sozcugu hazir; R1 adresi kuruldu
                state_r <= ST_CS_W0;
            end
            ST_CS_W0: begin
                // mem_rd_r = R1 sozcugu (yazma blogunda kullanildi)
                cs_b_r  <= mem_rd_r;
                cs_t_r  <= cs_mask_w & (cs_a_r ^ mem_rd_r);
                state_r <= ST_CS_W1;
            end
            ST_CS_W1: begin
                if (cnt_r == 3'd7) begin
                    cnt_r <= 3'd0;
                    if (cs_j_r == 2'd2) begin
                        cs_j_r  <= 2'd0;
                        state_r <= cs_ret_r;
                    end else begin
                        cs_j_r  <= cs_j_r + 2'd1;
                        state_r <= ST_CS_RA;
                    end
                end else begin
                    cnt_r   <= cnt_r + 3'd1;
                    state_r <= ST_CS_RA;
                end
            end

            // ── PAU'ya operand gonderimi ─────────────────────────────
            //   ADD: snd_j 0..5  -> P1X,P1Y,P1Z,P2X,P2Y,P2Z (slot 4..9)
            //   DBL: snd_j 0..2  -> P1X,P1Y,P1Z             (slot 4..6)
            ST_SND_RD: state_r <= ST_SND_TX;
            ST_SND_TX: begin
                pau_pkt_vld_r <= 1'b1;
                pau_pkt_sel_r <= PIX_P1X + snd_j_r;
                pau_pkt_dat_r <= mem_rd_r;
                if (cnt_r == 3'd7) begin
                    cnt_r <= 3'd0;
                    if (snd_j_r == snd_max_r) state_r <= ST_GO;
                    else begin snd_j_r <= snd_j_r + 3'd1; state_r <= ST_SND_RD; end
                end else begin
                    cnt_r <= cnt_r + 3'd1;
                    state_r <= ST_SND_RD;
                end
            end

            ST_GO: begin
                pau_st_r <= 1'b1; pau_wdog_r <= 15'd0;
                cnt_r <= 3'd0; state_r <= ST_RX;
            end

            // ── PAU sonucu dogrudan BRAM'e (ara tampon YOK) ──────────
            ST_RX: begin
                if (pau_wdog_r >= PAU_WDOG_MAX) begin
                    o_err_r<=1'b1; o_rdy_r<=1'b1; state_r<=ST_IDLE;
                end else if (pau_pkt_vld_w) begin
                    if (cnt_r == 3'd7) begin
                        cnt_r <= 3'd0;
                        if (pau_pkt_sel_w == 2'b10) begin
                            // Z bitti -> bu PAU islemi tamam
                            if (pau_cmd_r) begin
                                // ADD bitti -> simdi DBL
                                snd_j_r<=3'd0; snd_max_r<=3'd2;
                                pau_cmd_r<=1'b0; rx_base_r<=S_R0X;
                                state_r <= ST_SND_RD;
                            end else begin
                                // DBL bitti -> POST-CSWAP -> adim sonu karari
                                cs_j_r<=2'd0;
                                cs_ret_r <= ST_LOOP;
                                state_r  <= ST_CS_RA;
                            end
                        end
                    end else cnt_r <= cnt_r + 3'd1;
                end else pau_wdog_r <= pau_wdog_r + 15'd1;
            end

            // ── Ladder adim sonu: devam mi, cikis mi? ────────────────
            ST_LOOP: begin
                if (bit_idx_r != 9'd0) begin
                    bit_idx_r <= bit_idx_r - 9'd1;
                    d_shift_r <= d_shift_r << 1;
                    cs_j_r<=2'd0; cnt_r<=3'd0;
                    snd_j_r<=3'd0; snd_max_r<=3'd5;
                    pau_cmd_r<=1'b1; rx_base_r<=S_R1X;
                    cs_ret_r <= ST_SND_RD;      // PRE-CSWAP -> ADD
                    state_r  <= ST_CS_RA;
                end else begin
                    tx_j_r<=2'd0; cnt_r<=3'd0;
                    state_r <= ST_TX_RD;
                end
            end

            // ── Cikis: R0'i (X,Y,Z) 8'er paket akit ──────────────────
            //   RD ve SND ALMASIK calisir (BRAM 1 cevrim gecikmeli):
            //   RD adresi kurar, SND o sozcugu basar ve RD'ye doner.
            ST_TX_RD: state_r <= ST_TX_SND;

            ST_TX_SND: begin
                o_pkt_vld_r  <= 1'b1;
                o_pkt_sel_r  <= tx_j_r;
                o_pkt_out_r  <= mem_rd_r;
                o_pkt_last_r <= (cnt_r == 3'd7);
                if (cnt_r == 3'd7) begin
                    cnt_r <= 3'd0;
                    if (tx_j_r == 2'd2) state_r <= ST_DONE;
                    else begin tx_j_r <= tx_j_r + 2'd1; state_r <= ST_TX_RD; end
                end else begin
                    cnt_r   <= cnt_r + 3'd1;
                    state_r <= ST_TX_RD;
                end
            end

            ST_DONE: begin o_done_r<=1'b1; o_rdy_r<=1'b1; state_r<=ST_IDLE; end

            default: state_r <= ST_IDLE;
        endcase
        end
    end
end

endmodule
