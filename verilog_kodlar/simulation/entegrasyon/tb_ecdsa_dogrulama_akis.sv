// =============================================================================
// Modül   : tb_ecdsa_dogrulama_akis.sv                                 (TB-22)
// Proje   : FPGA Tabanlı Güvenli Anahtar Yönetimi ve Kripto Hızlandırıcı (5260007)
// -----------------------------------------------------------------------------
// AMAÇ:
//   ecdh_kex_top içindeki ECDSA DOĞRULAMA AKIŞINI uçtan uca sınamak.
//
//     i_dogrula → ecdsa_dogrula AŞ.1 (w, u1, u2)
//               → cift_skaler_carpim (R = u1·G + u2·Q)
//               → affine_donusum → Rx Montgomery→düz
//               → ecdsa_dogrula AŞ.2 (v = Rx mod n, v == r ?)
//
// -----------------------------------------------------------------------------
// *** BU YOL BUGÜNE KADAR HİÇ KOŞMADI ***
//   TB-21 yalnızca ecdsa_dogrula modülünün aritmetiğini sınadı. Orkestrasyon,
//   yani owner_csc / owner_dog arbiter yolları ve dört modül arası alan
//   uyumu, ilk kez BURADA çalışır. Bu TB yazılana kadar doğrulama akışı
//   "derlenmiş ama denenmemiş" durumdaydı.
//
//   Bu TB hazırlanırken tasarımda İKİ hata ortaya çıktı ve düzeltildi:
//
//   1) DG_WDOG_MAX 20 bitlik bir taşıyıcıya 4.000.000 yazıyordu; değer
//      sessizce 854.272'ye kırpılıyordu. Çift skaler çarpım tek başına
//      ~1,8 M çevrim sürdüğü için doğrulama HER SEFERİNDE ERR_WDOG ile
//      ölürdü. Vivado bunu yalnızca "literal truncated" UYARISI olarak
//      bildiriyordu.
//
//   2) K_IDLE paket yakalamıyordu. Doğrulama ECDH oturumu açmadığı için
//      K_QB_WAIT'e hiç uğranmaz; dolayısıyla Q, r ve s çekirdeğe ULAŞAMIYORDU.
//      Hesap, reset değerleri (sıfır) ile yapılır, hiçbir hata bayrağı
//      kalkmaz ve imza yalnızca "geçersiz" çıkardı — yani sessiz bir yanlış
//      sonuç. Artık K_IDLE açık operandları (Q, r, s) kabul ediyor.
//
// -----------------------------------------------------------------------------
// VEKTÖR ÜRETİMİ — İKİ AŞAMALI:
//   Vektör önce (d, k) ile imzalanarak üretildi, sonra imzalama yolundan
//   TAMAMEN BAĞIMSIZ bir doğrulayıcıdan geçirildi. Ayrıca bozulmuş r, s ve e
//   ile reddedildiği de Python'da teyit edildi. Tek aşamalı üretim, hem
//   modelin hem vektörün aynı hatayı paylaşmasına izin verirdi.
//
// ALAN NOTU (kritik):
//   Q, cift_skaler_carpim'e MONTGOMERY alanında verilir (GX_MONT ile aynı
//   düzlem). Buna karşılık r, s ve e DÜZ ve mod n'dir. İki alanın aynı
//   testte bulunması bilinçlidir; karıştırılırsa v != r çıkar ve imza
//   sessizce reddedilir.
//
// -----------------------------------------------------------------------------
// KAPSANAN SENARYOLAR:
//   A) GEÇERLİ İMZA      : o_imza_gecerli = 1
//   B) BOZUK s           : reddedilir (aritmetik yol, aralık içi)
//   C) BOZUK e (özet)    : reddedilir — imzalanan mesaj değişmiş
//   D) ARALIK DIŞI s = 0 : o_imza_aralik_hata = 1, hesaba HİÇ girilmez
//   E) ARALIK DIŞI r = n : o_imza_aralik_hata = 1
//   F) ARDIŞIK KOŞUM     : A'dan sonra tekrar A → durum makinesi temiz döner
//
//   D ve E, FIPS 186-4 §6.4.2 adım 1'in donanımda gerçekten uygulandığını
//   gösterir: aralık kontrolü BAŞTA yapılır, ~18 ms'lik çift skaler çarpım
//   hiç başlatılmaz. Bu yalnızca doğruluk değil, hizmet-dışı bırakma (DoS)
//   direnci meselesidir de.
//
// SÜRE UYARISI:
//   Her doğrulama ≈ ters alma (0,12 M) + çift skaler çarpım (~1,8 M)
//   + affine (~0,3 M) ≈ 2,3 M çevrim ≈ 23 ms. Dört tam doğrulama koşar;
//   aralık dışı senaryolar (D, E) neredeyse anında biter. Toplam ~100 ms.
//
// ÇALIŞTIRMA (Vivado xsim):
//   xvlog -sv tb_ecdsa_dogrulama_akis.sv ../sources_1/new/*.v
//   xelab -debug typical tb_ecdsa_dogrulama_akis -s tb22 && xsim tb22 -R
//
// Standart : SystemVerilog-2012
// Tarih    : Temmuz 2026
// =============================================================================

`timescale 1ns / 1ps

module tb_ecdsa_dogrulama_akis;

localparam int CLK_NS  = 10;
localparam int TIMEOUT = 40_000_000;    // ~400 ms, olculen ~10 M'e bol pay

// ── Python altin-modeli (bagimsiz dogrulayiciyla capraz sinandi) ─────────
localparam [255:0] VEK_E =
    256'h7c1e5a93d84f0b26e37a915cf0d2864b591e7038ac4d62f1085b39e7c26d4f5a;
localparam [255:0] VEK_R =
    256'h2cb781e4053f459ecb5dbb7f237f5609fc718d71f1193066a385197a5ef44e25;
localparam [255:0] VEK_S =
    256'h86f982dfea2029eadd7bc5d37e096884681c4b9b0c64d75da3de9b588624dc42;
// Q = d*G, MONTGOMERY alaninda (cift_skaler_carpim boyle bekler)
localparam [255:0] VEK_QX =
    256'hb8120011b7ec6ad10e22a8dcb82bb553f397e0f955d610a03e3a5d525fdeef5d;
localparam [255:0] VEK_QY =
    256'h7f3f7c789cf2832ebb8908ff62e3a60ba188314629b6e702cd89aef0ee6aef30;
// P-256 grup mertebesi n — aralik disi testi icin
localparam [255:0] N_ORDER =
    256'hffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551;

logic clk_in = 1'b0, rst_n = 1'b0;
always #(CLK_NS/2) clk_in = ~clk_in;

// ── DUT sinyalleri ──────────────────────────────────────────────────────
logic        i_start, i_qb_start, i_imzala, i_zeroize, i_uret, i_dogrula;
logic [31:0] i_pkt_in, i_trng_pkt, i_hash_pkt;
logic        i_pkt_vld, i_trng_vld, i_hash_vld;
logic [2:0]  i_pkt_sel;
logic [1:0]  i_slot;
logic [7:0]  i_politika;
wire  [31:0] o_pkt_out;
wire         o_pkt_vld, o_pkt_last, o_qa_done, o_rdy, o_done, o_err;
wire  [1:0]  o_pkt_sel, o_stage, o_uret_hata_kod;
wire  [2:0]  o_err_kod;
wire         o_trng_req, o_slot_hata, o_imza_hazir, o_imza_sel, o_imza_tekrar;
wire         o_imza_gecerli, o_imza_aralik_hata;

ecdh_kex_top dut (
    .clk_in(clk_in), .rst_n(rst_n),
    .i_start(i_start), .i_uret(i_uret), .i_dogrula(i_dogrula),
    .o_trng_req(o_trng_req), .i_trng_vld(i_trng_vld), .i_trng_pkt(i_trng_pkt),
    .i_pkt_in(i_pkt_in), .i_pkt_vld(i_pkt_vld), .i_pkt_sel(i_pkt_sel),
    .i_qb_start(i_qb_start),
    .o_pkt_out(o_pkt_out), .o_pkt_vld(o_pkt_vld), .o_pkt_sel(o_pkt_sel),
    .o_pkt_last(o_pkt_last), .o_stage(o_stage), .o_qa_done(o_qa_done),
    .o_rdy(o_rdy), .o_done(o_done), .o_err(o_err), .o_err_kod(o_err_kod),
    .i_slot(i_slot), .i_politika(i_politika), .i_zeroize(i_zeroize),
    .o_slot_hata(o_slot_hata), .o_uret_hata_kod(o_uret_hata_kod),
    .i_imzala(i_imzala), .i_hash_pkt(i_hash_pkt), .i_hash_vld(i_hash_vld),
    .o_imza_hazir(o_imza_hazir), .o_imza_sel(o_imza_sel),
    .o_imza_tekrar(o_imza_tekrar),
    .o_imza_gecerli(o_imza_gecerli), .o_imza_aralik_hata(o_imza_aralik_hata),
    // ── ÇOKLU EĞRİ DESTEĞİ (İster M-24) — P-256 sabit degerleri ──────────
    //   Bu TB ecdh_kex_top'u DOGRUDAN surdugu icin bu portlar P-256
    //   literalleriyle beslenmelidir; aksi halde bagsiz giris X yayar.
    .i_egri_p(256'hffffffff00000001000000000000000000000000ffffffffffffffffffffffff),
    .i_egri_r_mod_p(256'h00000000fffffffeffffffffffffffffffffffff000000000000000000000001),
    .i_egri_gx_mont(256'h18905f76a53755c679fb732b7762251075ba95fc5fedb60179e730d418a9143c),
    .i_egri_gy_mont(256'h8571ff1825885d85d2e88688dd21f3258b4ab8e4ba19e45cddf25357ce95560a),
    .i_egri_b_mont(256'hdc30061d04874834e5a220abf7212ed6acf005cd78843090d89cdf6229c4bddf),
    .i_egri_n_order(256'hffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551),
    .i_egri_mont_bir_n(256'h00000000ffffffff00000000000000004319055258e8617b0c46353d039cdaaf),
    .i_egri_r2n(256'h66e12d94f3d956202845b2392b6bec594699799c49bd6fa683244c95be79eea2),
    .i_egri_n_bit_uzunluk(10'd256)
);

// TRNG bu akista hic istenmez: dogrulama YALNIZCA acik verilerle calisir,
// anahtar uretilmez. i_trng_* sabit sifir kalir.

int gecen = 0, kalan = 0;
task automatic kontrol(input string ad, input logic k);
    if (k) begin $display("   [GECTI] %s", ad); gecen++; end
    else   begin $display("   [KALDI] %s   <<<", ad); kalan++; end
endtask

// ── 8 word'luk operand yukleme ──────────────────────────────────────────
task automatic operand_yaz(input logic [2:0] sel, input logic [255:0] v);
    for (int i = 0; i < 8; i++) begin
        @(negedge clk_in);
        i_pkt_in = v[i*32 +: 32]; i_pkt_sel = sel; i_pkt_vld = 1'b1;
    end
    @(negedge clk_in); i_pkt_vld = 1'b0;
endtask

task automatic hash_yaz(input logic [255:0] e);
    for (int i = 0; i < 8; i++) begin
        @(negedge clk_in); i_hash_pkt = e[i*32 +: 32]; i_hash_vld = 1'b1;
    end
    @(negedge clk_in); i_hash_vld = 1'b0;
endtask

// o_err / o_done DARBEDIR — bekleme sirasinda ayni cevrimde yakalanmali.
task automatic dogrulama_kos(input logic [255:0] e,
                             input logic [255:0] r,
                             input logic [255:0] s,
                             output logic gecerli,
                             output logic aralik,
                             output logic ariza,
                             output int    cevrim);
    int c;
    // Operandlar BOSTA yuklenir (K_IDLE artik kabul ediyor)
    operand_yaz(3'd0, VEK_QX);
    operand_yaz(3'd1, VEK_QY);
    operand_yaz(3'd2, r);
    operand_yaz(3'd3, s);
    hash_yaz(e);

    @(negedge clk_in); i_dogrula = 1'b1;
    @(negedge clk_in); i_dogrula = 1'b0;

    c = 0; ariza = 1'b0; gecerli = 1'b0; aralik = 1'b0;
    forever begin
        @(posedge clk_in); c++;
        if (o_err) begin
            ariza   = 1'b1;
            gecerli = o_imza_gecerli;
            aralik  = o_imza_aralik_hata;
            break;
        end
        if (o_done) begin
            gecerli = o_imza_gecerli;
            aralik  = o_imza_aralik_hata;
            break;
        end
        if (c > TIMEOUT) begin ariza = 1'b1; break; end
    end
    cevrim = c;
    // Cekirdegin bosta durumuna tam donmesini bekle
    repeat (20) @(posedge clk_in);
endtask

logic gec, ara, ariz;
int   cev;

initial begin
    $display("=========================================================");
    $display(" TB-22 : ECDSA DOGRULAMA AKISI — UCTAN UCA");
    $display("   i_dogrula -> u1,u2 -> u1G+u2Q -> affine -> v == r ?");
    $display("   UYARI: her dogrulama ~23 ms; toplam ~100 ms surer.");
    $display("=========================================================");

    i_start=0; i_qb_start=0; i_imzala=0; i_zeroize=0; i_uret=0; i_dogrula=0;
    i_pkt_in=0; i_pkt_vld=0; i_pkt_sel=0;
    i_trng_pkt=0; i_trng_vld=0; i_hash_pkt=0; i_hash_vld=0;
    i_slot=2'd0; i_politika=8'h01;

    repeat (20) @(posedge clk_in);
    @(negedge clk_in); rst_n = 1'b1;
    repeat (20) @(posedge clk_in);

    // ── A) GECERLI IMZA ────────────────────────────────────────────────
    $display("\n [A] Gecerli imza dogrulaniyor...");
    dogrulama_kos(VEK_E, VEK_R, VEK_S, gec, ara, ariz, cev);
    kontrol("A1: donanim arizasi yok (o_err dusuk)", !ariz);
    kontrol("A2: aralik hatasi yok", !ara);
    kontrol("A3: *** IMZA GECERLI ***", gec === 1'b1);
    $display("        sure: %0d cevrim (%0.2f ms @100MHz)", cev, cev/100000.0);

    // ── B) BOZUK s ─────────────────────────────────────────────────────
    $display("\n [B] Bozuk s ile dogrulama (reddedilmeli)...");
    dogrulama_kos(VEK_E, VEK_R, VEK_S ^ 256'd1, gec, ara, ariz, cev);
    kontrol("B1: donanim arizasi yok", !ariz);
    kontrol("B2: *** BOZUK IMZA REDDEDILDI ***", gec === 1'b0);

    // ── C) BOZUK e (mesaj degismis) ────────────────────────────────────
    $display("\n [C] Bozuk ozet e ile dogrulama (reddedilmeli)...");
    dogrulama_kos(VEK_E ^ 256'd1, VEK_R, VEK_S, gec, ara, ariz, cev);
    kontrol("C1: donanim arizasi yok", !ariz);
    kontrol("C2: *** DEGISMIS MESAJ REDDEDILDI ***", gec === 1'b0);

    // ── D) ARALIK DISI s = 0 ───────────────────────────────────────────
    //   FIPS 186-4 §6.4.2 adim 1. Hesaba HIC girilmemeli: s=0 ters alma
    //   adimini tanimsiz birakir. Sure kisa olmali — bu, kontrolun gercekten
    //   BASTA yapildiginin kaniti.
    $display("\n [D] s = 0 (aralik disi) ...");
    dogrulama_kos(VEK_E, VEK_R, 256'd0, gec, ara, ariz, cev);
    kontrol("D1: aralik hatasi bildirildi", ara === 1'b1);
    kontrol("D2: imza gecersiz", gec === 1'b0);
    kontrol("D3: cift skaler carpim HIC baslamadi (< 5000 cevrim)", cev < 5000);
    $display("        sure: %0d cevrim", cev);

    // ── E) ARALIK DISI r = n ───────────────────────────────────────────
    $display("\n [E] r = n (aralik disi) ...");
    dogrulama_kos(VEK_E, N_ORDER, VEK_S, gec, ara, ariz, cev);
    kontrol("E1: aralik hatasi bildirildi", ara === 1'b1);
    kontrol("E2: imza gecersiz", gec === 1'b0);
    $display("        sure: %0d cevrim", cev);

    // ── F) ARDISIK KOSUM — durum makinesi temiz dondu mu? ──────────────
    //   Reddedilen imzalardan sonra gecerli bir imza HALA kabul edilmeli.
    //   Bu, o_imza_gecerli / dog_modu_r gibi bayraklarin dogru
    //   temizlendigini gosterir; tek basina A yeterli degildir.
    $display("\n [F] Redlerden sonra gecerli imza tekrar dogrulaniyor...");
    dogrulama_kos(VEK_E, VEK_R, VEK_S, gec, ara, ariz, cev);
    kontrol("F1: donanim arizasi yok", !ariz);
    kontrol("F2: *** ARDISIK KOSUM TEMIZ — IMZA GECERLI ***", gec === 1'b1);

    // ── Ozet ───────────────────────────────────────────────────────────
    $display("\n---------------------------------------------------------");
    $display(" TB-22 SONUC: %0d gecti, %0d kaldi", gecen, kalan);
    if (kalan == 0) begin
        $display(" >>> ECDSA dogrulama yolu uctan uca calisiyor.");
        $display(" >>> Gecerli imza kabul, bozuk imza ve aralik disi");
        $display(" >>> deger reddediliyor. owner_csc / owner_dog");
        $display(" >>> arbiter yollari ILK KEZ dogrulandi.");
    end
    $display("=========================================================");
    $finish;
end

// Kilitlenme korumasi
initial begin
    #(TIMEOUT * CLK_NS);
    $display("\n *** TB-22 GENEL ZAMAN ASIMI — akis kilitlendi ***");
    $display("     dut.state_r = %0d", dut.state_r);
    $finish;
end

endmodule
