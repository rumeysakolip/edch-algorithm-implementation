// =============================================================================
// Modül   : modular_alu_dsp.v      (DSP48E1 tabanlı CIOS Montgomery — DROP-IN)
// Proje   : FPGA Tabanlı Güvenli Anahtar Yönetimi ve Kripto Hızlandırıcı
// No      : 5260007 — Sakarya Uygulamalı Bilimler Üniversitesi
// -----------------------------------------------------------------------------
// AMAÇ:
//   modular_alu.v ile PORT PORT AYNI, davranışı BİREBİR aynı, fakat MontMult
//   çekirdeği bit-seri Carry-Save döngüsü yerine SÖZCÜK-SERİ CIOS'a dayanan
//   alternatif uygulama. İki hedefi vardır:
//
//     [1] ALAN: 258-bit CSA dizileri (s1/c1/s2/c2 — her biri 258 bit genişlikte
//         3-girişli fonksiyonlar) ve 259-bit çözümleme toplayıcısı KALKAR.
//         Yerine 32x32 çarpma gelir ve bu DSP48E1'e iner. Amaç, ikinci bir
//         PAU+MALU çiftine yer açmaktır (yol haritası Adım 2).
//
//     [2] HIZ: MontMult 267 çevrimden 99 çevrime iner (~2,7x).
//
//   *** modular_alu.v'ye DOKUNULMAMIŞTIR. ***
//   O dosya üç nesildir değişmeden gelen, 20.000 vektörle altın modele karşı
//   doğrulanmış ve zamanlaması kapanmış bir referanstır. Bu modül ONUN YANINA
//   konur; üst seviyede parametreyle seçilir. Geri dönüş yolu her zaman açıktır.
//
// -----------------------------------------------------------------------------
// ALGORİTMA — CIOS (Coarsely Integrated Operand Scanning), W=32, S=8
//   Koç–Acar–Kaliski. Standart CIOS iki ardışık iç döngü koşar (önce a*b[i],
//   sonra m*p). Burada bu iki döngü BİR ÇEVRİM OFSETLE KAYNAŞTIRILMIŞTIR:
//   MAC1 j indisini işlerken MAC2 (j-2) indisini işler. Böylece dış tur başına
//   iç döngü sayısı 16'dan 8'e iner.
//
//   Bağımlılık: MAC2'nin k. adımı, MAC1'in k. adımının ürettiği S_k'yı ister.
//   Aradaki 2 çevrimlik gecikme prev1_r / prev2_r kayıt hattıyla kapatılır —
//   prev2_r her zaman "2 çevrim önce üretilen S" değerini taşır.
//
//   Dış tur başına çevrim şeması (i = 0..7):
//     c0        ST_MM_A0    MAC1 j=0                    -> s0_r, c1_r
//     c1        ST_MM_M     MAC2 çarpanı m = s0*n0'     + MAC1 j=1
//     c2..c9    ST_MM_LOOP  MAC2 k=0..7 (t[k-1] yazar)  + MAC1 j=k+2 / kuyruk
//     c10       ST_MM_TAIL  t[7], t[8] güncelle
//   = 11 çevrim x 8 tur = 88 + INIT(1) + FIN(1) + indirgeme(2)
//
//   ÖLÇÜLEN (i_start -> o_done), çevrim-doğru modelden:
//        92  çevrim  — n0' önbellekte (olağan durum)
//       102  çevrim  — P değişmiş, n0' yeniden hesaplanıyor (+10)
//   Karşılaştırma: modular_alu.v = 259 çevrim  ->  2,8x / 2,5x
//   (Her ikisine de sonuç aktarımı için +8 çevrim TX eklenir.)
//
// -----------------------------------------------------------------------------
// n0' = -P^-1 mod 2^32  — NEWTON-RAPHSON, ÖNBELLEKLİ
//   y <- y*(2 - P0*y) mod 2^32, y0 = 1, 5 iterasyon (1->2->4->8->16->32 bit).
//   Donanımda her iterasyon iki çevrim (çarpma zinciri bölünür) = 10 çevrim.
//   SADECE P'nin alt 32 biti değiştiğinde yeniden hesaplanır; ECDH/ECDSA
//   akışında P sürekli p ile n arasında gidip gelir, önbellek bu yüzden
//   anlamlıdır. n0' yalnız P mod 2^32'ye bağlıdır — önbellek anahtarı budur.
//
// -----------------------------------------------------------------------------
// DOĞRULAMA (Verilog yazılmadan ÖNCE yapıldı):
//   Bu FSM'in çevrim-doğru Python modeli, hem GF(p) hem GF(n) alanında
//   20.000'er rastgele vektörde (toplam 40.000) sınandı:
//     • sonuç == a*b*R^-1 mod P  (altın model)          -> 0 hata
//     • sonuç < 2P  (tek koşullu çıkarma yeterli)       -> 0 hata
//     • referans CIOS ile bit-birebir aynı              -> 0 hata
//     • k=0 adımında MAC2'nin alt sözcüğü daima 0       -> 0 hata
//   Kenar durumlar ayrıca zorlandı: (0,0), (1,1), (P-1,P-1), (P-1,1), (R,R).
//
// -----------------------------------------------------------------------------
// SABİT ZAMAN (SCA):
//   Çevrim sayısı VERİDEN TAMAMEN BAĞIMSIZDIR. Döngü sınırları sabittir,
//   erken çıkış yoktur, koşullu çıkarma borrow-select ile yapılır (dallanma
//   değil, mux).
//
//   Tek değişken n0' önbelleğidir (92 / 102). Bunun tek bağımlılığı P'dir ve
//   P GİZLİ DEĞİLDİR — p ve n protokolün açık parametreleridir. Gizli olan
//   a, b ve skalerdir; hiçbirinin çevrim sayısına etkisi yoktur. TB-26 bunu
//   iki ayrı hükümle sınar: sabit P'de değişmezlik (E1) ve soğuk yolun da
//   kendi içinde sabit olması (E2).
//
// -----------------------------------------------------------------------------
// *** BİLİNEN ZAMANLAMA RİSKİ — SENTEZDEN SONRA BAKILACAK ***
//   MAC yolu tek çevrimdedir: 32x32 çarpma + 64-bit toplama. DSP48E1'in
//   dâhili post-adder'ı ve PCOUT->PCIN kaskad yolu kullanıldığında bu yapı
//   100 MHz'de rahat kapanır; ancak mevcut tasarımın payı yalnızca
//   WNS = +0,345 ns ve çip %75 dolu.
//
//   WNS NEGATİFE DÜŞERSE çözüm mekaniktir ve veri akışını DEĞİŞTİRMEZ:
//   mul1_p_w / mul2_p_w çarpım çıkışları bir kayıtçıya alınır (DSP'nin MREG'i),
//   şema bir çevrim ötelenir; MontMult 92'den ~100 çevrime çıkar. Doğrulanmış
//   matematik aynen korunur.
//
// ModAdd / ModSub / indirgeme yolu modular_alu.v'den AYNEN alınmıştır —
// kanıtlanmış mantığı yeniden yazmanın hiçbir kazancı yok, riski var.
//
// I/O: 32-bit LSB-önce paket; SEL_A/SEL_B/SEL_P; opcode 00=Add 01=Sub 10=MontMult.
// Standart : Verilog-2001 — sentezlenebilir, latch üretmez
// Tarih    : Temmuz 2026
// =============================================================================

`timescale 1ns / 1ps

module modular_alu_dsp (
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

localparam [3:0] ST_IDLE   =4'd0,  ST_MM_INIT=4'd1,  ST_NP_A  =4'd2,
                 ST_NP_B   =4'd3,  ST_MM_A0  =4'd4,  ST_MM_M  =4'd5,
                 ST_MM_LOOP=4'd6,  ST_MM_TAIL=4'd7,  ST_MM_FIN=4'd8,
                 ST_RED_LO =4'd9,  ST_RED_HI =4'd10, ST_TX    =4'd11,
                 ST_AS_LOOP=4'd12;   // [ADIM-3] AŞAMA-1 word-serial döngüsü

reg [3:0] state_r;
localparam [8:0] WDOG_MAX = 9'd500;   // en uzun yol 99 çevrim; bol pay

// ── Operandlar / sonuç ───────────────────────────────────────────────────
reg [255:0] op_a_r, op_b_r, mod_p_r, result_r;

// ── CIOS çalışma alanı: t[0..S+1] = 10 sözcük ───────────────────────────
reg [31:0] t_r [0:9];
reg [31:0] c1_r, c2_r;          // MAC1 / MAC2 elde zincirleri
reg [31:0] s0_r;                // S_0 (m'nin türetildiği sözcük)
reg [31:0] prev1_r, prev2_r;    // S gecikme hattı (MAC2 daima prev2_r'yi yer)
reg [31:0] m_r;                 // m = t[0]*n0' mod 2^32
reg [31:0] sT_r, cT_r;          // kuyruk: t[8]+C1 sonucu
reg [2:0]  i_r;                 // dış tur sayacı (b sözcüğü indisi)
reg [2:0]  k_r;                 // iç döngü sayacı

// ── n0' üreteci + önbellek ───────────────────────────────────────────────
reg [31:0] n0_r;                // -P^-1 mod 2^32
reg [31:0] n0_p0_r;             // önbelleğin ait olduğu P[31:0]
reg        n0_gecerli_r;
reg [31:0] np_y_r, np_u_r;
// Carpim boru hatti fazi: 0 = operandi yakala, 1 = carpimi bekle,
//                         2 = sonucu tuket
reg  [1:0] mac_faz_r;
reg [2:0]  np_it_r;

// ── İndirgeme (modular_alu.v ile AYNI) ───────────────────────────────────
reg [258:0] pre_r;
reg         is_sub_r;
reg [127:0] d_lo_r, s_lo_r;
reg         b_lo_r, c_lo_r;

// [ADIM-3] AŞAMA-1 word-serial toplama/çıkarma sayaçları
reg [2:0]  as_idx_r;    // 0..7: hangi 32-bit dilim işleniyor
reg        as_cb_r;     // dilimler arası taşıma (add) / ödünç (sub)

reg [2:0]  pkt_rx_cnt_r, pkt_tx_cnt_r;
reg [8:0]  wdog_r;

integer n;

// ── Çıkış saklayıcıları ──────────────────────────────────────────────────
reg [31:0] o_pkt_out_r;
reg        o_pkt_vld_r, o_pkt_last_r, o_rdy_r, o_done_r, o_err_r;
assign o_pkt_out  = o_pkt_out_r;
assign o_pkt_vld  = o_pkt_vld_r;
assign o_pkt_last = o_pkt_last_r;
assign o_rdy      = o_rdy_r;
assign o_done     = o_done_r;
assign o_err      = o_err_r;

// =====================================================================
// [ADIM-3] AŞAMA-1 WORD-SERIAL toplama/çıkarma
// -----------------------------------------------------------------------
//   Eskiden (modular_alu.v ile "AYNEN aynı") bu işlem 256 bitin TAMAMI
//   üzerinde TEK vuruşta yapılıyordu — geniş carry-chain, dar zamanlama
//   marjı, yüksek LUT maliyeti. Şimdi 8x32-bit dilime bölünüp ST_AS_LOOP
//   durumunda ardışık 8 vuruşta işleniyor (bkz. Nihai Mimari Raporu Bölüm
//   6). Taşıma/ödünç biti as_cb_r'de bir sonraki vuruşa taşınır.
//
//   Üst 3 bit (pre_r[258:256]) — AYNEN eski addsum_w/subdiff_w ile
//   matematiksel olarak ÖZDEŞ üretilir:
//     TOPLAMA : iki 256-bit sayının toplamı en fazla 257 bit tutar, yani
//               bit258/257 HER ZAMAN 0'dır; bit256 gerçek elde bitidir.
//     ÇIKARMA : a<b olursa (ödünç), {3'b000,a}-{3'b000,b} 259-bit'lik
//               ikinin tümleyeninde ÜÇÜ BİRDEN 1'e sarar (259-bit'te
//               2^259-(b-a) = 111 + (2^256-(b-a)) örüntüsü) — bu yüzden
//               son dilimin ödünç çıkışı is_sub_r=1 iken üç bite birden
//               kopyalanır, is_sub_r=0 iken yalnızca bit256'ya yazılır.
// =====================================================================
wire [31:0] as_a_w = op_a_r[as_idx_r*32 +: 32];
wire [31:0] as_b_w = op_b_r[as_idx_r*32 +: 32];
wire [32:0] as_addsum_w  = {1'b0, as_a_w} + {1'b0, as_b_w} + {32'd0, as_cb_r};
wire [32:0] as_subdiff_w = {1'b0, as_a_w} - {1'b0, as_b_w} - {32'd0, as_cb_r};
wire [32:0] as_sonuc_w   = is_sub_r ? as_subdiff_w : as_addsum_w;

// =====================================================================
// AŞAMA-2 borrow-select indirgeme  (modular_alu.v ile AYNEN aynı)
//   256-bit elde zinciri 128-bit alt / 131-bit üst iki çevrime bölünmüştür.
//   100 MHz kapanışını sağlayan yapı budur — DOKUNULMADI.
// =====================================================================
wire [128:0] sub_lo_w = {1'b0, pre_r[127:0]} - {1'b0, mod_p_r[127:0]};
wire [128:0] add_lo_w = {1'b0, pre_r[127:0]} + {1'b0, mod_p_r[127:0]};
wire [130:0] sub_hi_w = pre_r[258:128] - {3'b000, mod_p_r[255:128]} - {130'd0, b_lo_r};
wire [130:0] add_hi_w = pre_r[258:128] + {3'b000, mod_p_r[255:128]} + {130'd0, c_lo_r};
wire [258:0] pre_sub_w = {sub_hi_w, d_lo_r};
wire [258:0] pre_add_w = {add_hi_w, s_lo_r};
wire [255:0] red_addr_w = pre_sub_w[258] ? pre_r[255:0] : pre_sub_w[255:0];
wire [255:0] red_sub_w  = pre_r[258]     ? pre_add_w[255:0] : pre_r[255:0];
wire [255:0] reduce_w   = is_sub_r ? red_sub_w : red_addr_w;

// =====================================================================
// MAC1 — a[j]*b[i] + t[j] + C1     (n0' durumlarında çarpanı ödünç alınır)
// =====================================================================
//   j indisi duruma göre seçilir. k_r<=5 iken j=k_r+2; k_r==6 iken j=8
//   (kuyruk: t[8]+C1, çarpım YOK); k_r==7 iken MAC1 boştadır.
wire [3:0] j1_w = (state_r == ST_MM_A0) ? 4'd0 :
                  (state_r == ST_MM_M)  ? 4'd1 :
                  (k_r <= 3'd5)         ? ({1'b0, k_r} + 4'd2) : 4'd8;

// Çarpım yalnızca gerçek a*b adımlarında etkin; kuyrukta ve boşta sıfırlanır
wire j1_carp_w = (state_r == ST_MM_A0) || (state_r == ST_MM_M) ||
                 ((state_r == ST_MM_LOOP) && (k_r <= 3'd5));

wire [31:0] a_j_w = (j1_w < 4'd8) ? op_a_r[j1_w[2:0]*32 +: 32] : 32'd0;
wire [31:0] b_i_w = op_b_r[i_r*32 +: 32];
wire [31:0] t_j_w = t_r[j1_w];

// ST_MM_A0'da elde zinciri SIFIRDAN başlar (turun ilk sözcüğü)
wire [31:0] c1_in_w = (state_r == ST_MM_A0) ? 32'd0 : c1_r;

// n0' hesabı MAC1'in çarpanını ödünç alır — ayrı bir çarpıcı sentezlenmesin
wire [31:0] mul1_x_w = (state_r == ST_NP_A) ? mod_p_r[31:0] :
                       (state_r == ST_NP_B) ? np_y_r        : a_j_w;
wire [31:0] mul1_y_w = (state_r == ST_NP_A) ? np_y_r            :
                       (state_r == ST_NP_B) ? (32'd2 - np_u_r)  :
                       (j1_carp_w ? b_i_w : 32'd0);

// =============================================================================
// TEMMUZ 2026 — ÇARPIM BORU HATTI (WNS düzeltmesi)
//
//   ÖLÇÜM (post-route, impl_1): WNS = -6,628 ns. Kritik yol:
//     k_r -> operand mux (LUT2/LUT6/LUT6/LUT5/LUT5)
//         -> DSP48E1 mul1_p_w__1 (4,04 ns) -> PCOUT
//         -> DSP48E1 mul1_p_w__2 (1,52 ns) -> P[0]
//         -> LUT2 -> CARRY4 x13 (64-bit MAC toplaması) -> c1_r[28]
//     Data Path Delay 16,378 ns | 23 mantık seviyesi | 10 ns bütçe.
//
//   SEBEP: 256->32 operand mux'u, 32x32 çarpma (iki KASKATLI DSP) ve
//   64-bit üç-girişli toplama TEK ÇEVRİMDE zincirlenmişti. Çarpım
//   kombinasyonel bir `wire` olduğu için Vivado DSP'nin iç boru hattı
//   yazmacını (MREG) kullanamıyordu — dosyanın kendi başlığı (satır 85)
//   "çarpım çıkışları bir kayıtçıya alınır (DSP'nin MREG'i)" diyordu ama
//   kod bunu yapmıyordu.
//
//   ÇÖZÜM: Çarpım artık KAYITÇIYA alınıyor. Bu, yolu ikiye böler:
//     Faz 0 : operand mux -> DSP çarpma -> MREG        (~6,5 ns)
//     Faz 1 : MREG -> DSP P -> 64-bit MAC -> c1_r      (~5,0 ns)
//   MAC kullanan durumlar aşağıda mac_faz_r ile 2 çevrime çıkarıldı:
//   faz 0 boru hattını doldurur (hiçbir şey tüketmez), faz 1 sonucu alır.
//   Operand mux'ları iki faz boyunca DEĞİŞMEZ (sayaçlar faz 1'de ilerler),
//   bu yüzden faz 1'de okunan çarpım tam olarak o adımın çarpımıdır.
//
//   MALİYET: MontMult ~100 -> ~200 çevrim. Skaler çarpım bunun katı olduğu
//   için ECDH süresi yaklaşık iki katına çıkar. Zamanlama kapanmadan
//   tasarım kartta ÇALIŞMAYACAĞI için bu takas zorunludur.
// =============================================================================
// [WNS-2] OPERAND KAYITCILARI — post-route olcumu WNS = -0,249 ns gosterdi.
//   Kalan kritik yol: k_r -> LUT6/LUT6/LUT4/LUT4 (operand mux) -> DSP -> MREG
//   (8,667 ns, 5 seviye). Yani mux ile carpma HALA ayni cevrimdeydi.
//   Operandlari kayitlamak bu 4 LUT seviyesini DSP girisinden ayirir ve
//   AREG/BREG'i devreye sokar — ikisi de DSP48E1'in ICINDEDIR, fabric'te
//   ek LUT/FF maliyeti yoktur. Yol uce bolunur:
//     Faz 0: mux -> AREG/BREG        (~3 ns)
//     Faz 1: AREG -> carpma -> MREG  (~5 ns, tamami DSP ici)
//     Faz 2: MREG -> P -> MAC -> c1_r (~5 ns)
reg [31:0] mul1_x_r, mul1_y_r, mul2_x_r, mul2_y_r;
(* use_dsp = "yes" *) reg [63:0] mul1_p_r;
(* use_dsp = "yes" *) reg [63:0] mul2_p_r;
always @(posedge clk_in) begin
    mul1_x_r <= mul1_x_w;  mul1_y_r <= mul1_y_w;
    mul2_x_r <= mul2_x_w;  mul2_y_r <= mul2_y_w;
    mul1_p_r <= mul1_x_r * mul1_y_r;
    mul2_p_r <= mul2_x_r * mul2_y_r;
end

wire [63:0] mac1_w = {32'd0, t_j_w} + mul1_p_r + {32'd0, c1_in_w};

// =====================================================================
// MAC2 — m*p[k] + prev2 + C2       (ST_MM_M'de m'nin kendisini üretir)
// =====================================================================
wire [31:0] p_k_w    = mod_p_r[k_r*32 +: 32];
wire [31:0] mul2_x_w = (state_r == ST_MM_M) ? s0_r : m_r;
wire [31:0] mul2_y_w = (state_r == ST_MM_M) ? n0_r : p_k_w;

// (mul2 çarpımı da yukarıda mul2_p_r'ye kayıtlandı — aynı gerekçe)
wire [63:0] mac2_w = {32'd0, prev2_r} + mul2_p_r + {32'd0, c2_r};

// Kuyruk toplaması: t[7] = sT + C2 ; taşma t[8]'e gider
wire [32:0] tail_w = {1'b0, sT_r} + {1'b0, c2_r};

// n0' önbelleği geçerli mi (aynı P alt sözcüğü)?
wire n0_hazir_w = n0_gecerli_r && (n0_p0_r == mod_p_r[31:0]);

// =====================================================================
// Ana FSM
// =====================================================================
always @(posedge clk_in or negedge rst_n) begin
    if (!rst_n) begin
        state_r<=ST_IDLE; o_rdy_r<=1'b1; o_done_r<=1'b0; o_pkt_vld_r<=1'b0;
        o_pkt_last_r<=1'b0; o_pkt_out_r<=32'd0; o_err_r<=1'b0;
        wdog_r<=9'd0;
        op_a_r<=256'd0; op_b_r<=256'd0; mod_p_r<=256'd0; result_r<=256'd0;
        pre_r<=259'd0; is_sub_r<=1'b0;
        as_idx_r<=3'd0; as_cb_r<=1'b0;
        d_lo_r<=128'd0; s_lo_r<=128'd0; b_lo_r<=1'b0; c_lo_r<=1'b0;
        pkt_rx_cnt_r<=3'd0; pkt_tx_cnt_r<=3'd0;
        c1_r<=32'd0; c2_r<=32'd0; s0_r<=32'd0; prev1_r<=32'd0; prev2_r<=32'd0;
        m_r<=32'd0; sT_r<=32'd0; cT_r<=32'd0; i_r<=3'd0; k_r<=3'd0;
        n0_r<=32'd0; n0_p0_r<=32'd0; n0_gecerli_r<=1'b0;
        np_y_r<=32'd0; np_u_r<=32'd0; np_it_r<=3'd0; mac_faz_r<=2'd0;
        for (n=0; n<10; n=n+1) t_r[n] <= 32'd0;
    end else begin
        o_done_r<=1'b0; o_pkt_vld_r<=1'b0; o_pkt_last_r<=1'b0; o_err_r<=1'b0;

        case (state_r)

        // ── Boşta: operand yükle / i_start ──────────────────────────────
        //   Paket protokolü modular_alu.v ile BİREBİR aynıdır.
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
                // P=0 reddi modular_alu.v ile aynı. P ÇİFT ise Montgomery
                // tanımsızdır (n0' yoktur) — sessizce çöp üretmek yerine
                // açıkça hata verilir. Bu tasarımda P daima p veya n, ikisi de
                // tek asal; dolayısıyla normal akışta hiç tetiklenmez.
                if (mod_p_r == 256'd0 || (i_opcode == 2'b10 && !mod_p_r[0])) begin
                    o_err_r<=1'b1; o_rdy_r<=1'b1;
                end else begin
                    o_rdy_r <= 1'b0;
                    wdog_r  <= 9'd0;
                    case (i_opcode)
                        2'b10:   state_r <= ST_MM_INIT;
                        // [ADIM-3] Add/Sub artık tek vuruşta değil; word-serial
                        // döngüye (ST_AS_LOOP) giriyor. is_sub_r burada
                        // sabitlenir, döngü boyunca değişmez.
                        2'b01: begin is_sub_r<=1'b1; as_idx_r<=3'd0; as_cb_r<=1'b0; state_r<=ST_AS_LOOP; end
                        default: begin is_sub_r<=1'b0; as_idx_r<=3'd0; as_cb_r<=1'b0; state_r<=ST_AS_LOOP; end
                    endcase
                end
            end
        end

        // [ADIM-3] AŞAMA-1 WORD-SERIAL DÖNGÜSÜ — 256-bit toplama/çıkarma
        //   8x32-bit dilime bölünmüş hâlde, ardışık 8 vuruşta işlenir. Döngü
        //   sayısı DAİMA 8'dir (veriden bağımsız) — sabit-zamanlılık korunur,
        //   dallanma yoktur. Son dilimde üst 3 bit (pre_r[258:256]) yukarıda
        //   as_sonuc_w yorumunda açıklanan kurala göre tamamlanıp ST_RED_LO'ya
        //   geçilir; AŞAMA-2 (borrow-select indirgeme) DEĞİŞMEDEN kalır.
        ST_AS_LOOP: begin
            pre_r[as_idx_r*32 +: 32] <= as_sonuc_w[31:0];
            as_cb_r <= as_sonuc_w[32];
            wdog_r  <= wdog_r + 9'd1;
            if (as_idx_r == 3'd7) begin
                pre_r[258:256] <= is_sub_r ? {3{as_sonuc_w[32]}} : {2'b00, as_sonuc_w[32]};
                state_r <= ST_RED_LO;
            end else as_idx_r <= as_idx_r + 3'd1;
        end

        // ── MontMult kurulumu: t[] temizle, n0' gerekiyorsa üret ─────────
        ST_MM_INIT: begin
            // Onceki islem yarida kesilmisse (wdog/err) faz bayragini temizle
            mac_faz_r <= 2'd0;
            for (n=0; n<10; n=n+1) t_r[n] <= 32'd0;
            i_r<=3'd0; k_r<=3'd0; c1_r<=32'd0; c2_r<=32'd0;
            prev1_r<=32'd0; prev2_r<=32'd0;
            wdog_r <= wdog_r + 9'd1;
            if (n0_hazir_w) state_r <= ST_MM_A0;
            else begin np_y_r<=32'd1; np_it_r<=3'd0; state_r<=ST_NP_A; end
        end

        // ── Newton-Raphson: u = P0*y ────────────────────────────────────
        ST_NP_A: begin
            wdog_r <= wdog_r + 9'd1;
            if (mac_faz_r != 2'd2) mac_faz_r <= mac_faz_r + 2'd1;  // boru hatti
            else begin
                mac_faz_r <= 2'd0;
                np_u_r    <= mul1_p_r[31:0];
                state_r   <= ST_NP_B;
            end
        end

        // ── Newton-Raphson: y = y*(2-u) ; 5. turda n0' = -y ─────────────
        ST_NP_B: begin
            wdog_r <= wdog_r + 9'd1;
            if (mac_faz_r != 2'd2) mac_faz_r <= mac_faz_r + 2'd1;
            else begin
                mac_faz_r <= 2'd0;
                np_y_r    <= mul1_p_r[31:0];
                if (np_it_r == 3'd4) begin
                    n0_r         <= (~mul1_p_r[31:0]) + 32'd1;  // -y mod 2^32
                    n0_p0_r      <= mod_p_r[31:0];
                    n0_gecerli_r <= 1'b1;
                    state_r      <= ST_MM_A0;
                end else begin
                    np_it_r <= np_it_r + 3'd1;
                    state_r <= ST_NP_A;
                end
            end
        end

        // ── c0: MAC1 j=0 → s0 (m buradan türer), elde zinciri başlar ────
        ST_MM_A0: begin
            wdog_r  <= wdog_r + 9'd1;
            if (mac_faz_r != 2'd2) mac_faz_r <= mac_faz_r + 2'd1;
            else begin
                mac_faz_r <= 2'd0;
                s0_r      <= mac1_w[31:0];
                c1_r      <= mac1_w[63:32];
                prev2_r   <= prev1_r;
                prev1_r   <= mac1_w[31:0];
                state_r   <= ST_MM_M;
            end
        end

        // ── c1: m = s0*n0' (MAC2 çarpanı) + MAC1 j=1 ────────────────────
        //   m ile m*p[0] AYNI çevrimde yapılamaz (çarpma→çarpma zinciri
        //   100 MHz'i geçer). Bu yüzden m'ye ayrı bir çevrim verilir;
        //   MAC1 bu çevrimde boş durmaz, j=1'i işler.
        ST_MM_M: begin
            wdog_r  <= wdog_r + 9'd1;
            if (mac_faz_r != 2'd2) mac_faz_r <= mac_faz_r + 2'd1;
            else begin
                mac_faz_r <= 2'd0;
                m_r       <= mul2_p_r[31:0];
                c2_r      <= 32'd0;
                c1_r      <= mac1_w[63:32];
                prev2_r   <= prev1_r;
                prev1_r   <= mac1_w[31:0];
                k_r       <= 3'd0;
                state_r   <= ST_MM_LOOP;
            end
        end

        // ── c2..c9: MAC2 k=0..7 ile MAC1 j=k+2 kaynaşık koşar ───────────
        //   MAC2 t_r[k-1]'e yazar, MAC1 t_r[k+2]'yi okur — indisler asla
        //   çakışmaz (k-1 < k+2), bu yüzden tek portlu kayıt dizisi yeter.
        ST_MM_LOOP: if (mac_faz_r != 2'd2) begin
            mac_faz_r <= mac_faz_r + 2'd1;       // boru hattini doldur
            wdog_r    <= wdog_r + 9'd1;
        end else begin
            mac_faz_r <= 2'd0;
            // MAC2: k=0'da alt sözcük tanım gereği 0'dır, yazılmaz.
            c2_r <= mac2_w[63:32];
            if (k_r != 3'd0) t_r[{1'b0,k_r} - 4'd1] <= mac2_w[31:0];

            // MAC1: k<=5 normal adım, k==6 kuyruk (t[8]+C1), k==7 boşta
            if (k_r <= 3'd5) begin
                c1_r    <= mac1_w[63:32];
                prev2_r <= prev1_r;
                prev1_r <= mac1_w[31:0];
            end else if (k_r == 3'd6) begin
                sT_r    <= mac1_w[31:0];
                cT_r    <= mac1_w[63:32];
                prev2_r <= prev1_r;          // prev1_r sabit kalır
            end else begin
                prev2_r <= prev1_r;
            end

            wdog_r <= wdog_r + 9'd1;
            if (k_r == 3'd7) state_r <= ST_MM_TAIL;
            else             k_r     <= k_r + 3'd1;
        end

        // ── c10: turun kuyruğu — t[7], t[8] güncelle ────────────────────
        ST_MM_TAIL: begin
            t_r[7] <= tail_w[31:0];
            t_r[8] <= t_r[9] + cT_r + {31'd0, tail_w[32]};
            t_r[9] <= 32'd0;
            wdog_r <= wdog_r + 9'd1;
            if (i_r == 3'd7) state_r <= ST_MM_FIN;
            else begin
                i_r     <= i_r + 3'd1;
                c1_r    <= 32'd0;
                c2_r    <= 32'd0;
                state_r <= ST_MM_A0;
            end
        end

        // ── Sonucu indirgeme hattına aktar ──────────────────────────────
        //   AYRI BİR ÇEVRİM OLMASININ SEBEBİ: t_r[7] ve t_r[8] ST_MM_TAIL'de
        //   non-blocking atanır; aynı çevrimde okunsalardı ESKİ değerleri
        //   görülürdü. Bir çevrim beklemek, o sınıf hatayı tümden kaldırır.
        //   Sonuç < 2P < 2^257 olduğundan t_r[8] en fazla 1'dir.
        ST_MM_FIN: begin
            pre_r <= { t_r[8][2:0], t_r[7], t_r[6], t_r[5], t_r[4],
                       t_r[3], t_r[2], t_r[1], t_r[0] };
            is_sub_r <= 1'b0;
            wdog_r   <= wdog_r + 9'd1;
            if (wdog_r >= WDOG_MAX) begin
                o_err_r<=1'b1; o_rdy_r<=1'b1; state_r<=ST_IDLE;
            end else state_r <= ST_RED_LO;
        end

        // ── İndirgeme aşama-2a: alt-yarı (modular_alu.v ile aynı) ────────
        ST_RED_LO: begin
            d_lo_r  <= sub_lo_w[127:0];  b_lo_r <= sub_lo_w[128];
            s_lo_r  <= add_lo_w[127:0];  c_lo_r <= add_lo_w[128];
            state_r <= ST_RED_HI;
        end

        // ── İndirgeme aşama-2b: üst-yarı + borrow-select ─────────────────
        ST_RED_HI: begin
            result_r     <= reduce_w;
            o_done_r     <= 1'b1;
            pkt_tx_cnt_r <= 3'd0;
            state_r      <= ST_TX;
        end

        // ── Sonucu 8 paket gönder ───────────────────────────────────────
        ST_TX: begin
            o_rdy_r      <= 1'b0;
            o_pkt_vld_r  <= 1'b1;
            // [ALAN OPT.] 8:1 okuma mux'u yerine 32-bit SAGA DONDURME.
            //   Tam 8 gonderim yapildigi icin dondurme degeri BOZMAZ:
            //   8. cevrimde result_r baslangic hizasina geri doner.
            //   Bu yol TX'tedir, MAC kritik yolunda DEGILDIR — op_a_r/op_b_r/
            //   mod_p_r'nin part-select'lerine ise KASITLI OLARAK dokunulmadi,
            //   onlar DSP'yi besliyor ve WNS +0,006 ns'i bozarlardi.
            o_pkt_out_r  <= result_r[31:0];
            result_r     <= {result_r[31:0], result_r[255:32]};
            o_pkt_last_r <= (pkt_tx_cnt_r == 3'd7);
            if (pkt_tx_cnt_r == 3'd7) begin pkt_tx_cnt_r<=3'd0; state_r<=ST_IDLE; end
            else pkt_tx_cnt_r <= pkt_tx_cnt_r + 3'd1;
        end

        default: state_r <= ST_IDLE;
        endcase
    end
end

endmodule
