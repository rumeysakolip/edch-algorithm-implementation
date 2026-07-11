// =============================================================================
// Modül   : ecdh_demo_top.v   (Board demo sarmalayıcısı — Nexys A7-100T)
// Proje   : FPGA Tabanlı Güvenli Anahtar Yönetimi ve Kripto Hızlandırıcı (5260007)
// -----------------------------------------------------------------------------
// Açıklama:
//   ecdh_kex_top çekirdeğini fiziksel kart kaynaklarına (buton/LED) bağlayan
//   sentezlenebilir demo üst modülü. Bit-stream bu modülden üretilir.
//
//   Demo akışı (butona basınca):
//     1. btn_start'a basılır → çekirdeğe i_start darbesi.
//     2. Çekirdek TRNG ister → on-chip LFSR-PRNG 8×32-bit gizli anahtar (d) sürer
//        (SADECE DEMO amaçlı sözde-rastgele; kriptografik değildir).
//     3. Çekirdek Qa = d·G hesaplar, Affin'e çevirir (o_qa_done).
//     4. Sarmalayıcı, karşı taraf anahtarı Qb = G'yi (gömülü sabit) besler ve
//        i_qb_start verir.
//     5. Çekirdek Ortak Sır = d·Qb = d·G hesaplar (o_done).
//     6. LED'ler durumu ve Ortak Sır'ın düşük baytını gösterir.
//
//   LED HARİTASI (led[15:0]):
//     led[0]      = busy (işlem sürüyor)
//     led[1]      = Qa hazır (o_qa_done yakalandı)
//     led[2]      = Ortak Sır hazır (o_done yakalandı)
//     led[3]      = hata (o_err yakalandı)
//     led[11:4]   = Ortak Sır X koordinatının düşük 8 biti (görsel veri)
//     led[15]     = heartbeat (yaşam işareti — yanıp söner)
//
//   NOT: Tam skaler çarpım 100 MHz'de ~on ms sürer; butona bastıktan sonra
//   busy LED'i kısa süre yanar, ardından "hazır" LED'i sabitlenir.
//
// Standart : Verilog-2001 — sentezlenebilir
// Tarih    : Temmuz 2026
// =============================================================================

`timescale 1ns / 1ps

module ecdh_demo_top (
    input  wire        clk_100,     // 100 MHz kart osilatörü (E3)
    input  wire        btn_reset,   // btnCpuReset — aktif-DÜŞÜK (C12)
    input  wire        btn_start,   // btnC — işlemi başlat (N17)
    output wire [15:0] led
);

// =====================================================================
// P-256 taban noktası G (Montgomery) — Qb için gömülü sabit
// =====================================================================
localparam [255:0] GX_MONT = 256'h18905f76a53755c679fb732b7762251075ba95fc5fedb60179e730d418a9143c;
localparam [255:0] GY_MONT = 256'h8571ff1825885d85d2e88688dd21f3258b4ab8e4ba19e45cddf25357ce95560a;
localparam [1:0]   QBIX_X = 2'b00, QBIX_Y = 2'b01;
localparam [1:0]   STAGE_SS = 2'b10;

// =====================================================================
// Reset senkronizasyonu (btn_reset aktif-düşük → rst_n)
// =====================================================================
reg [1:0] rst_sync_r;
wire      rst_n;
always @(posedge clk_100) rst_sync_r <= {rst_sync_r[0], btn_reset};
assign rst_n = rst_sync_r[1];

// =====================================================================
// btn_start debounce + yükselen kenar (start_pulse)
// =====================================================================
reg [1:0]  bs_sync_r;
reg [21:0] db_cnt_r;
reg        bs_stable_r, bs_stable_d_r;
localparam [21:0] DB_MAX = 22'd2_000_000;   // ~20 ms @ 100 MHz
always @(posedge clk_100 or negedge rst_n) begin
    if (!rst_n) begin
        bs_sync_r<=2'b0; db_cnt_r<=22'd0; bs_stable_r<=1'b0; bs_stable_d_r<=1'b0;
    end else begin
        bs_sync_r <= {bs_sync_r[0], btn_start};
        if (bs_sync_r[1] != bs_stable_r) begin
            db_cnt_r <= db_cnt_r + 22'd1;
            if (db_cnt_r == DB_MAX) begin bs_stable_r <= bs_sync_r[1]; db_cnt_r <= 22'd0; end
        end else db_cnt_r <= 22'd0;
        bs_stable_d_r <= bs_stable_r;
    end
end
wire start_pulse = bs_stable_r & ~bs_stable_d_r;

// =====================================================================
// Heartbeat (yaşam işareti)
// =====================================================================
reg [25:0] hb_r;
always @(posedge clk_100 or negedge rst_n) begin
    if (!rst_n) hb_r <= 26'd0; else hb_r <= hb_r + 26'd1;
end

// =====================================================================
// ecdh_kex_top örneği + bağlantı sinyalleri
// =====================================================================
reg         i_start_r, i_qb_start_r;
reg  [31:0] i_pkt_in_r;
reg         i_pkt_vld_r;
reg  [1:0]  i_pkt_sel_r;
reg  [31:0] i_trng_pkt_r;
reg         i_trng_vld_r;

wire        o_trng_req;
wire [31:0] o_pkt_out;
wire        o_pkt_vld;
wire [1:0]  o_pkt_sel;
wire        o_pkt_last;
wire [1:0]  o_stage;
wire        o_qa_done, o_rdy, o_done, o_err;

ecdh_kex_top kex_inst (
    .clk_in(clk_100), .rst_n(rst_n),
    .i_start(i_start_r),
    .o_trng_req(o_trng_req), .i_trng_vld(i_trng_vld_r), .i_trng_pkt(i_trng_pkt_r),
    .i_pkt_in(i_pkt_in_r), .i_pkt_vld(i_pkt_vld_r), .i_pkt_sel(i_pkt_sel_r),
    .i_qb_start(i_qb_start_r),
    .o_pkt_out(o_pkt_out), .o_pkt_vld(o_pkt_vld), .o_pkt_sel(o_pkt_sel),
    .o_pkt_last(o_pkt_last), .o_stage(o_stage), .o_qa_done(o_qa_done),
    .o_rdy(o_rdy), .o_done(o_done), .o_err(o_err)
);

// =====================================================================
// ON-CHIP TRNG MOCK — 32-bit Galois LFSR (DEMO; kriptografik DEĞİL)
//   o_trng_req yükseldiğinde 8×32-bit sözde-rastgele word sürer.
// =====================================================================
localparam [31:0] LFSR_TAPS = 32'hA3000000;   // maksimal uzunluk tap seti (demo)
reg [31:0] lfsr_r;
reg [1:0]  t_state_r;
reg [2:0]  t_cnt_r;
localparam [1:0] T_IDLE=2'd0, T_SEND=2'd1, T_WAIT=2'd2;

wire [31:0] lfsr_next = (lfsr_r >> 1) ^ (lfsr_r[0] ? LFSR_TAPS : 32'd0);

always @(posedge clk_100 or negedge rst_n) begin
    if (!rst_n) begin
        lfsr_r <= 32'hACE1_2345;   // sıfırdan farklı tohum
        t_state_r <= T_IDLE; t_cnt_r <= 3'd0;
        i_trng_vld_r <= 1'b0; i_trng_pkt_r <= 32'd0;
    end else begin
        i_trng_vld_r <= 1'b0;
        case (t_state_r)
            T_IDLE: if (o_trng_req) begin t_cnt_r <= 3'd0; t_state_r <= T_SEND; end
            T_SEND: begin
                i_trng_vld_r <= 1'b1;
                i_trng_pkt_r <= lfsr_r;
                lfsr_r       <= lfsr_next;
                if (t_cnt_r == 3'd7) t_state_r <= T_WAIT;
                else t_cnt_r <= t_cnt_r + 3'd1;
            end
            T_WAIT: if (!o_trng_req) t_state_r <= T_IDLE;
            default: t_state_r <= T_IDLE;
        endcase
    end
end

// =====================================================================
// ANA DEMO FSM — başlat / Qb besle / durum
// =====================================================================
localparam [2:0] D_IDLE=3'd0, D_START=3'd1, D_WAIT_QA=3'd2, D_QB_X=3'd3,
                 D_QB_Y=3'd4, D_QB_GO=3'd5, D_WAIT_SS=3'd6, D_DONE=3'd7;
reg [2:0] d_state_r;
reg [2:0] qb_cnt_r;
reg       qa_lat_r, ss_lat_r, err_lat_r, busy_r;

always @(posedge clk_100 or negedge rst_n) begin
    if (!rst_n) begin
        d_state_r<=D_IDLE; qb_cnt_r<=3'd0;
        i_start_r<=1'b0; i_qb_start_r<=1'b0;
        i_pkt_in_r<=32'd0; i_pkt_vld_r<=1'b0; i_pkt_sel_r<=2'd0;
        qa_lat_r<=1'b0; ss_lat_r<=1'b0; err_lat_r<=1'b0; busy_r<=1'b0;
    end else begin
        i_start_r<=1'b0; i_qb_start_r<=1'b0; i_pkt_vld_r<=1'b0;
        if (o_qa_done) qa_lat_r<=1'b1;
        if (o_done)    ss_lat_r<=1'b1;
        if (o_err)     err_lat_r<=1'b1;

        case (d_state_r)
            D_IDLE: begin
                busy_r <= 1'b0;
                if (start_pulse) begin
                    qa_lat_r<=1'b0; ss_lat_r<=1'b0; err_lat_r<=1'b0;
                    d_state_r <= D_START;
                end
            end
            D_START: begin
                busy_r    <= 1'b1;
                i_start_r <= 1'b1;
                d_state_r <= D_WAIT_QA;
            end
            D_WAIT_QA: begin
                if (o_err) d_state_r <= D_DONE;
                else if (o_qa_done) begin qb_cnt_r<=3'd0; d_state_r<=D_QB_X; end
            end
            D_QB_X: begin
                i_pkt_vld_r <= 1'b1; i_pkt_sel_r <= QBIX_X;
                i_pkt_in_r  <= GX_MONT[qb_cnt_r*32 +: 32];
                if (qb_cnt_r==3'd7) begin qb_cnt_r<=3'd0; d_state_r<=D_QB_Y; end
                else qb_cnt_r <= qb_cnt_r + 3'd1;
            end
            D_QB_Y: begin
                i_pkt_vld_r <= 1'b1; i_pkt_sel_r <= QBIX_Y;
                i_pkt_in_r  <= GY_MONT[qb_cnt_r*32 +: 32];
                if (qb_cnt_r==3'd7) begin qb_cnt_r<=3'd0; d_state_r<=D_QB_GO; end
                else qb_cnt_r <= qb_cnt_r + 3'd1;
            end
            D_QB_GO: begin
                i_qb_start_r <= 1'b1;
                d_state_r    <= D_WAIT_SS;
            end
            D_WAIT_SS: begin
                if (o_err)  d_state_r <= D_DONE;
                else if (o_done) d_state_r <= D_DONE;
            end
            D_DONE: begin
                busy_r    <= 1'b0;
                d_state_r <= D_IDLE;
            end
            default: d_state_r <= D_IDLE;
        endcase
    end
end

// =====================================================================
// Ortak Sır X düşük baytını yakala (görsel veri)
// =====================================================================
reg [7:0] ssx_byte_r;
reg       ssx_cap_r;
always @(posedge clk_100 or negedge rst_n) begin
    if (!rst_n) begin ssx_byte_r<=8'd0; ssx_cap_r<=1'b0; end
    else begin
        if (start_pulse) ssx_cap_r <= 1'b0;
        // Ortak Sır aşamasının ilk X paketi (word0) → düşük bayt
        if (o_pkt_vld && (o_stage==STAGE_SS) && (o_pkt_sel==2'b00) && !ssx_cap_r) begin
            ssx_byte_r <= o_pkt_out[7:0];
            ssx_cap_r  <= 1'b1;
        end
    end
end

// =====================================================================
// LED çıkışları
// =====================================================================
assign led[0]     = busy_r;
assign led[1]     = qa_lat_r;
assign led[2]     = ss_lat_r;
assign led[3]     = err_lat_r;
assign led[11:4]  = ssx_byte_r;
assign led[14:12] = 3'b000;
assign led[15]    = hb_r[25];

endmodule
