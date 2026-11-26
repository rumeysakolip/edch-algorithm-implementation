// =============================================================================
// Modül   : mod_n_ters.v                                           (İster M-18)
// Proje   : FPGA Tabanlı Güvenli Anahtar Yönetimi ve Kripto Hızlandırıcı (5260007)
// -----------------------------------------------------------------------------
// Açıklama:
//   GF(n) skaler alanında modüler ters alma:  c = a^(-1) mod n
//   Fermat'ın Küçük Teoremi ile:  a^(-1) = a^(n-2) mod n   (n asal)
//
//   ECDSA'nın İKİ yerinde de zorunludur ve Faz 5'in temel taşıdır:
//     İmzalama  : s = k^(-1) · (h + r·d) mod n     → k^(-1) gerekir
//     Doğrulama : w = s^(-1) mod n                 → s^(-1) gerekir
//
//   Bu yüzden imza ve doğrulama modüllerinden ÖNCE, ayrı ve bağımsız
//   doğrulanabilir bir birim olarak yazılmıştır.
//
// -----------------------------------------------------------------------------
// *** KRİTİK BULGU: modular_alu ZATEN GENELDİR ***
//   modular_alu'nun modülü sabit değildir; SEL_P ile dışarıdan yüklenir ve
//   tüm indirgeme mantığı mod_p_r üzerinden çalışır. Yani AYNI ÇARPAN hem
//   GF(p) hem GF(n) için kullanılabilir — tek şart modülün TEK olmasıdır
//   (n tektir) ve üst bitinin set olmasıdır (n ≈ 2^256, set).
//
//   Sonuç: GF(n) için AYRI BİR ÇARPAN YAZILMADI. ECDSA'nın alan maliyeti
//   bu sayede beklenenden çok düşük kalıyor; MALU dördüncü bir istemci
//   kazanıyor, o kadar.
//
//   Doğrulama: n ve p için Montgomery aritmetiği Python'da bit-birebir
//   karşılaştırıldı; aynı algoritma her iki modülde de doğru sonuç veriyor.
//
// -----------------------------------------------------------------------------
// NEDEN FERMAT, NEDEN GENİŞLETİLMİŞ ÖKLİD DEĞİL:
//   Genişletilmiş Öklid (binary xGCD) ~3-4 kat daha hızlıdır. Ancak
//   ÇALIŞMA SÜRESİ GİRDİYE BAĞLIDIR: iterasyon sayısı a'nın bit desenine
//   göre değişir. ECDSA imzalamada ters alınan değer k^(-1)'dir ve k GİZLİ
//   NONCE'dur — süresi k'ya bağlı bir işlem, k hakkında zamanlama kanalı
//   açar. Nonce'un tek bir bitinin sızması bile kafes (lattice) saldırısıyla
//   özel anahtarın toparlanmasına yeter.
//
//   Fermat üsteli SABİTTİR (n-2) ve her zaman 256 kare + sabit sayıda çarpma
//   yapar; süre girdiden BAĞIMSIZDIR. Yavaşlık bilinçli ödenen bedeldir.
//
//   NOT: Kare-al-ve-çarp'ta çarpma yalnız üs biti 1 iken yapılır — ama üs
//   SABİT olduğu için bu desen de sabittir ve sır sızdırmaz. Sızdıran şey
//   üssün gizli olmasıdır; burada üs n-2, herkesçe bilinen bir sabittir.
//
// -----------------------------------------------------------------------------
// MONTGOMERY ALANI:
//   Giriş ve çıkış Montgomery-n alanındadır (ã = a·R mod n, R = 2^256).
//   Akümülatör Montgomery 1 ile başlatılır:
//     MONT_BIR = R mod n = 0x00000000ffffffff...039cdaaf
//   MontMult alanı koruduğu için üs alma döngüsü olduğu gibi çalışır.
//
// MALİYET:
//   256 kare + (n-2'nin set bit sayısı) çarpma ≈ 384 MALU çağrısı
//   ≈ 384 × ~324 çevrim ≈ 124.000 çevrim ≈ 1.24 ms @100 MHz.
//   ECDSA imzalamada bir kez çalışır; skaler çarpımın 21 ms'i yanında %6.
//
// Kabul kriteri (TB-17):
//   KAT vektörleri (a=1,2,3,küçük,büyük,rastgele) için a·a^(-1) ≡ 1 (mod n);
//   ardışık koşumda temiz IDLE'a dönüş; MALU arızasının yayılması.
//
// Standart : Verilog-2001 — sentezlenebilir, latch üretmez
// Tarih    : Temmuz 2026
// =============================================================================

`timescale 1ns / 1ps

// [ALAN OPT. Temmuz 2026] keep_hierarchy KAPATILDI. Bu attribute yalnizca
// hiyerarsik raporlama granulerligini korur; PAYLASIMI ETKILEMEZ — tek MALU /
// tek PAU paylasimi RTL de YAPISALDIR (tek ornek + mux), sentez var olmayan
// ikinci bir ornek yaratamaz. Kapatmak, modul sinirlari arasinda sabit
// yayilimi ve olu mantik elemesini acar (~%5-15 LUT). Hiyerarsik rapor
// gerekirse satiri gecici olarak geri ac.
// (* keep_hierarchy = "yes" *)
module mod_n_ters (
    input  wire         clk_in,
    input  wire         rst_n,

    // ── Paket girişi (32-bit, LSB-önce) ──────────────────────────────────
    input  wire [31:0]  i_pkt_in,
    input  wire         i_pkt_vld,
    input  wire [1:0]   i_pkt_sel,     // 0 = mod_n, 1 = a (ters alinacak)
    input  wire         i_start,

    // ── Sonuç ────────────────────────────────────────────────────────────
    output wire [31:0]  o_pkt_out,
    output wire         o_pkt_vld,
    output wire         o_pkt_last,
    output wire         o_rdy,
    output wire         o_done,
    output wire         o_err,

    // ── Paylaşılan MALU dış arayüzü (master) ─────────────────────────────
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
    //   n dışarıdan gelir (g_n_order); N_MINUS_2 buradan türetilir (ayrı
    //   sabit taşınmaz — n/n-2 tutarsızlığı riskini önler). MONT_BIR
    //   (=R mod n) ayrıca yüklenir (n'ye göre hesaplanması pahalı olurdu).
    //   Reset/varsayılan P-256'dır, davranış değişmez.
    input  wire [255:0] g_n_order,
    input  wire [255:0] g_mont_bir_n
);

wire [255:0] N_MINUS_2 = g_n_order - 256'd2;
wire [255:0] MONT_BIR  = g_mont_bir_n;
// Eski P-256 sabitleri (belge amaçlı):
//   N_MINUS_2 = 256'hffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc63254f
//   MONT_BIR  = 256'h00000000ffffffff00000000000000004319055258e8617b0c46353d039cdaaf

// ── Giriş seçicileri ──────────────────────────────────────────────────────
localparam [1:0] TIX_MODN = 2'd0,
                 TIX_A    = 2'd1;

// ── MALU arayüz sabitleri (modular_alu.v ile birebir) ────────────────────
localparam [1:0] MSEL_A = 2'b00, MSEL_B = 2'b01, MSEL_P = 2'b10;
localparam [1:0] MMUL   = 2'b10;


// =============================================================================
// TEMMUZ 2026 — 32-BİT SÖZCÜK-ADRESLİ BRAM DÖNÜŞÜMÜ (Nihai Mimari, Adım 5)
//
//   Bu modül 963 LUT / 1659 FF tutuyordu; kaynak 6 adet 256-bit yazmaç
//   (mod_n_r, a_r, acc_r, ma_r, mb_r, mres_r = 1536 bit) ve onları 32-bit
//   sözcüklere bölen 7 part-select mux'uydu. Her part-select 32 bitlik bir
//   8:1 mux'tur ve ~150 LUT'a mal olur.
//
//   Değerler artık 8 ardışık 32-bit sözcük olarak tek bir Block RAM'de durur:
//   adres = {slot[1:0], sozcuk[2:0]}. Okuma mux'u ve yazma çözücüsü tamamen
//   kayboldu; ma_r/mb_r/mres_r ara tamponları da gereksizleşti (operandlar
//   BRAM'den doğrudan akıtılır, sonuç geldiği gibi BRAM'e yazılır).
//
//   *** BRAM 1 ÇEVRİM GECİKMELİDİR: okuma adresi FETCH *VE* KULLANIM
//   durumunun İKİSİNDE de tutulmalıdır *** — yalnızca fetch çevriminde
//   verilip sonra varsayılana dönerse mem_rd_r sessizce bozulur (TB-19'da
//   yakalanan hata buydu).
//
//   SABİT ZAMANLILIK KORUNDU: üs (n-2) sabittir, dallanma deseni veriden
//   bağımsızdır; BRAM adresleri yalnızca sayaçlara bağlıdır.
// =============================================================================

// ── Durum kodlaması ───────────────────────────────────────────────────────
localparam [4:0]
    ST_IDLE     = 5'd0,
    ST_SENDP_RD = 5'd1,  // MALU'ya modülü (n) bir kez yükle: oku
    ST_SENDP_TX = 5'd2,  //                                   gönder
    ST_INIT     = 5'd3,  // akümülatör = Montgomery 1 (8 sözcük yazılır)
    ST_KARE     = 5'd4,  // acc = acc²
    ST_KARE_D   = 5'd5,  // üs bitine bak
    ST_CARP     = 5'd6,  // acc = acc · a
    ST_CARP_D   = 5'd7,
    ST_SONRAKI  = 5'd8,  // üs indisini azalt
    ST_TX_RD    = 5'd9,
    ST_TX       = 5'd10,
    ST_DONE     = 5'd11,
    // MALU dispatch alt-FSM'i (operandlar BRAM'den)
    ST_MA_ARD   = 5'd12,
    ST_MA_ATX   = 5'd13,
    ST_MA_BRD   = 5'd14,
    ST_MA_BTX   = 5'd15,
    ST_MA_GO    = 5'd16,
    ST_MA_WT    = 5'd17,
    ST_MA_RX    = 5'd18,
    ST_MA_WR    = 5'd19;

reg [4:0] state_r;

// modular_alu'nun kendi watchdog'u 300 çevrimdir; 4000 bol emniyet payıdır.
localparam [11:0] MA_WDOG_MAX = 12'd4000;

// ── BRAM slot adresleri (her slot 8 x 32-bit sözcük) ─────────────────────
localparam [1:0] A_N=2'd0, A_A=2'd1, A_ACC=2'd2;

// ── 32-bit geniş Block RAM scratchpad ────────────────────────────────────
(* ram_style = "block" *) reg [31:0] ara_mem [0:31];
reg [31:0] mem_rd_r;
reg [4:0]  mem_ra_c;
reg        mem_we_c;
reg [4:0]  mem_wa_c;
reg [31:0] mem_wd_c;
always @(posedge clk_in) begin
    if (mem_we_c) ara_mem[mem_wa_c] <= mem_wd_c;
    mem_rd_r <= ara_mem[mem_ra_c];
end

// ── Veri kayıtçıları — 256-bit olanların TAMAMI elendi ───────────────────
reg [8:0]   us_idx_r;    // 255 → 0
reg [1:0]   opid_a_r, opid_b_r, opid_res_r;
reg [4:0]   mret_r;
reg [2:0]   mcnt_r;
reg [11:0]  ma_wdog_r;
reg [2:0]   pkt_rx_cnt_r, pkt_tx_cnt_r;

// ── Çıkış saklayıcıları ───────────────────────────────────────────────────
reg [31:0] o_pkt_out_r;
reg        o_pkt_vld_r, o_pkt_last_r, o_rdy_r, o_done_r, o_err_r;
reg [31:0] malu_pkt_dat_r;
reg        malu_pkt_vld_r;
reg [1:0]  malu_pkt_sel_r;
reg        malu_st_r;

assign o_pkt_out  = o_pkt_out_r;
assign o_pkt_vld  = o_pkt_vld_r;
assign o_pkt_last = o_pkt_last_r;
assign o_rdy      = o_rdy_r;
assign o_done     = o_done_r;
assign o_err      = o_err_r;
assign mo_pkt_dat = malu_pkt_dat_r;
assign mo_pkt_vld = malu_pkt_vld_r;
assign mo_pkt_sel = malu_pkt_sel_r;
assign mo_opc     = MMUL;          // bu modül YALNIZCA MontMult kullanır
assign mo_st      = malu_st_r;

// Üssün o anki biti
wire us_biti_w = N_MINUS_2[us_idx_r[7:0]];

// ── BRAM OKUMA ADRESİ (KOMBİNASYONEL) ────────────────────────────────────
//   Adres hem FETCH hem KULLANIM durumunda tutulur (yukarıdaki nota bak).
always @* begin
    case (state_r)
        ST_SENDP_RD, ST_SENDP_TX: mem_ra_c = {A_N, mcnt_r};
        ST_MA_ARD,   ST_MA_ATX:   mem_ra_c = {opid_a_r, mcnt_r};
        ST_MA_BRD,   ST_MA_BTX:   mem_ra_c = {opid_b_r, mcnt_r};
        ST_TX_RD,    ST_TX:       mem_ra_c = {A_ACC, pkt_tx_cnt_r};
        default:                  mem_ra_c = 5'd0;
    endcase
end

// ── BRAM YAZMA DENETİMİ (KOMBİNASYONEL) ──────────────────────────────────
always @* begin
    mem_we_c = 1'b0; mem_wa_c = 5'd0; mem_wd_c = 32'd0;
    if (state_r == ST_IDLE) begin
        // Giriş paketi doğrudan sözcük olarak yazılır
        if (i_pkt_vld && (i_pkt_sel <= TIX_A)) begin
            mem_we_c = 1'b1;
            mem_wa_c = {(i_pkt_sel == TIX_MODN) ? A_N : A_A, pkt_rx_cnt_r};
            mem_wd_c = i_pkt_in;
        end
    end else if (state_r == ST_INIT) begin
        // ACC = Montgomery "1"  (sabit kaynak -> ucuz)
        mem_we_c = 1'b1;
        mem_wa_c = {A_ACC, mcnt_r};
        mem_wd_c = MONT_BIR[mcnt_r*32 +: 32];
    end else if ((state_r == ST_MA_WT) || (state_r == ST_MA_RX)) begin
        // MALU sonucu geldiği gibi hedef slota yazılır (mres_r yok)
        if (mi_pkt_vld) begin
            mem_we_c = 1'b1;
            mem_wa_c = {opid_res_r, mcnt_r};
            mem_wd_c = mi_pkt_out;
        end
    end
end

// =========================================================================
//  ANA DURUM MAKİNESİ
// =========================================================================
always @(posedge clk_in or negedge rst_n) begin
    if (!rst_n) begin
        state_r        <= ST_IDLE;
        us_idx_r       <= 9'd255;
        opid_a_r       <= A_ACC;
        opid_b_r       <= A_ACC;
        opid_res_r     <= A_ACC;
        mret_r         <= 5'd0;
        mcnt_r         <= 3'd0;
        ma_wdog_r      <= 12'd0;
        pkt_rx_cnt_r   <= 3'd0;
        pkt_tx_cnt_r   <= 3'd0;
        o_pkt_out_r    <= 32'd0;
        o_pkt_vld_r    <= 1'b0;
        o_pkt_last_r   <= 1'b0;
        o_rdy_r        <= 1'b0;
        o_done_r       <= 1'b0;
        o_err_r        <= 1'b0;
        malu_pkt_dat_r <= 32'd0;
        malu_pkt_vld_r <= 1'b0;
        malu_pkt_sel_r <= 2'd0;
        malu_st_r      <= 1'b0;
    end else begin
        o_pkt_vld_r    <= 1'b0;
        o_pkt_last_r   <= 1'b0;
        o_done_r       <= 1'b0;
        o_err_r        <= 1'b0;
        malu_st_r      <= 1'b0;
        malu_pkt_vld_r <= 1'b0;

        if (mi_err) begin
            o_err_r <= 1'b1; o_rdy_r <= 1'b1; state_r <= ST_IDLE;
        end else begin
        case (state_r)

        ST_IDLE: begin
            o_rdy_r <= 1'b1;
            if (i_pkt_vld) begin
                // Veri BRAM'e yazma bloğunda gidiyor; burada yalnızca sayaç
                pkt_rx_cnt_r <= pkt_rx_cnt_r + 3'd1;
            end
            if (i_start) begin
                o_rdy_r      <= 1'b0;
                pkt_rx_cnt_r <= 3'd0;
                mcnt_r       <= 3'd0;
                state_r      <= ST_SENDP_RD;
            end
        end

        // MALU'ya modül olarak n yüklenir — p DEĞİL. Bu modülün tamamı
        // GF(n) içinde çalışır.  (n artık BRAM'den okunuyor)
        ST_SENDP_RD: state_r <= ST_SENDP_TX;
        ST_SENDP_TX: begin
            malu_pkt_vld_r <= 1'b1;
            malu_pkt_dat_r <= mem_rd_r;
            malu_pkt_sel_r <= MSEL_P;
            if (mcnt_r == 3'd7) begin mcnt_r <= 3'd0; state_r <= ST_INIT; end
            else begin mcnt_r <= mcnt_r + 3'd1; state_r <= ST_SENDP_RD; end
        end

        // ACC = Montgomery "1" — 8 sözcük BRAM'e yazılır (yazma bloğunda)
        ST_INIT: begin
            if (mcnt_r == 3'd7) begin
                mcnt_r <= 3'd0; us_idx_r <= 9'd255; state_r <= ST_KARE;
            end else mcnt_r <= mcnt_r + 3'd1;
        end

        // ── Kare-al-ve-çarp: acc = acc² ───────────────────────────────────
        ST_KARE: begin
            opid_a_r <= A_ACC; opid_b_r <= A_ACC; opid_res_r <= A_ACC;
            mret_r <= ST_KARE_D; mcnt_r <= 3'd0; state_r <= ST_MA_ARD;
        end

        ST_KARE_D: begin
            // Kare sonucu zaten A_ACC'ye yazıldı (ara tampon yok).
            // Üs biti 1 ise çarp; 0 ise doğrudan sonraki bite geç.
            // Üs SABİT (n-2) olduğu için bu dallanma deseni de sabittir
            // ve gizli veri hakkında bilgi sızdırmaz.
            if (us_biti_w) state_r <= ST_CARP;
            else           state_r <= ST_SONRAKI;
        end

        // ── acc = acc · a ─────────────────────────────────────────────────
        ST_CARP: begin
            opid_a_r <= A_ACC; opid_b_r <= A_A; opid_res_r <= A_ACC;
            mret_r <= ST_CARP_D; mcnt_r <= 3'd0; state_r <= ST_MA_ARD;
        end

        ST_CARP_D: begin
            state_r <= ST_SONRAKI;
        end

        ST_SONRAKI: begin
            if (us_idx_r == 9'd0) begin
                pkt_tx_cnt_r <= 3'd0;
                state_r      <= ST_TX_RD;
            end else begin
                us_idx_r <= us_idx_r - 9'd1;
                state_r  <= ST_KARE;
            end
        end

        // Çıkış: acc BRAM'den sözcük sözcük akıtılır (RD/TX almaşık)
        ST_TX_RD: state_r <= ST_TX;
        ST_TX: begin
            o_pkt_vld_r  <= 1'b1;
            o_pkt_out_r  <= mem_rd_r;
            o_pkt_last_r <= (pkt_tx_cnt_r == 3'd7);
            if (pkt_tx_cnt_r == 3'd7) state_r <= ST_DONE;
            else begin
                pkt_tx_cnt_r <= pkt_tx_cnt_r + 3'd1;
                state_r <= ST_TX_RD;
            end
        end

        ST_DONE: begin
            o_done_r <= 1'b1;
            o_rdy_r  <= 1'b1;
            state_r  <= ST_IDLE;
        end

        // ── MALU DISPATCH ALT-FSM'İ (operandlar BRAM'den akıtılır) ────────
        //   ma_r / mb_r / mres_r ara yazmaçları TAMAMEN KALDIRILDI.
        ST_MA_ARD: state_r <= ST_MA_ATX;
        ST_MA_ATX: begin
            malu_pkt_vld_r <= 1'b1;
            malu_pkt_dat_r <= mem_rd_r;
            malu_pkt_sel_r <= MSEL_A;
            if (mcnt_r == 3'd7) begin mcnt_r <= 3'd0; state_r <= ST_MA_BRD; end
            else begin mcnt_r <= mcnt_r + 3'd1; state_r <= ST_MA_ARD; end
        end

        ST_MA_BRD: state_r <= ST_MA_BTX;
        ST_MA_BTX: begin
            malu_pkt_vld_r <= 1'b1;
            malu_pkt_dat_r <= mem_rd_r;
            malu_pkt_sel_r <= MSEL_B;
            if (mcnt_r == 3'd7) begin mcnt_r <= 3'd0; state_r <= ST_MA_GO; end
            else begin mcnt_r <= mcnt_r + 3'd1; state_r <= ST_MA_BRD; end
        end

        ST_MA_GO: begin
            malu_st_r <= 1'b1;
            ma_wdog_r <= 12'd0;
            mcnt_r    <= 3'd0;
            state_r   <= ST_MA_WT;
        end

        ST_MA_WT: begin
            // İlk sözcük yazma bloğunda BRAM'e gitti (mcnt_r = 0)
            if (ma_wdog_r >= MA_WDOG_MAX) begin
                o_err_r <= 1'b1; o_rdy_r <= 1'b1; state_r <= ST_IDLE;
            end else if (mi_pkt_vld) begin
                mcnt_r  <= 3'd1;
                state_r <= ST_MA_RX;
            end else begin
                ma_wdog_r <= ma_wdog_r + 12'd1;
            end
        end

        ST_MA_RX: begin
            if (mi_pkt_vld) begin
                if (mcnt_r == 3'd7) begin mcnt_r <= 3'd0; state_r <= ST_MA_WR; end
                else                      mcnt_r <= mcnt_r + 3'd1;
            end
        end

        // Son yazmanın BRAM'e oturması için 1 çevrimlik tampon
        ST_MA_WR: state_r <= mret_r;

        default: state_r <= ST_IDLE;

        endcase
        end
    end
end

endmodule
