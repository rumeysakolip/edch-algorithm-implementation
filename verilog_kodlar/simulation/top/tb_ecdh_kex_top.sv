// =============================================================================
// Modül   : tb_ecdh_kex_top.sv
// Proje   : FPGA Tabanlı Güvenli Anahtar Yönetimi ve Kripto Hızlandırıcı
// No      : 5260007 — Sakarya Uygulamalı Bilimler Üniversitesi
// -----------------------------------------------------------------------------
// Açıklama:
//   ecdh_kex_top (uçtan uca ECDH Anahtar Değişim Sistemi) üst-seviye
//   doğrulama testbench'i. Kara-kutu (black-box) yaklaşımıyla sistemin dış
//   arayüzlerini sürer; TRNG IP'si davranışsal bir mock ile taklit edilir.
//
//   TRNG MOCK MEKANİZMASI:
//     o_trng_req yükseldiğinde, ayarlanabilir gecikme (trng_gecikme) sonrası
//     8 × 32-bit paket hâlinde 256-bit değer (trng_deger) sürülür. trng_sifir_ilk
//     bayrağı ile ilk talebe 0 (zayıf anahtar) döndürülüp yeniden-talep koruması
//     test edilebilir.
//
//   TEST SENARYOLARI:
//     A) Tam akış (d=1): Qa = 1·G = G ; Qb = G ; Ortak Sır = 1·G = G
//        Beklenen Affin çıkış = (Gx_mont, Gy_mont) hem Qa hem Ortak Sır için.
//     B) TRNG gecikmesi (uzun latency) → sistem yine tamamlanır.
//     C) Zayıf anahtar koruması: ilk TRNG yanıtı 0 → yeniden talep → tamamlanır.
//     D) Hatalı karşı taraf anahtarı Qb=(0,0) → o_err beklenir.
//
//   NOT: Fonksiyonel doğruluk çapası olarak d=1 seçilmiştir; bu durumda beklenen
//   Affin sonuç, harici altın-vektöre gerek olmadan taban noktası G'ye eşittir.
//   Keyfi d için Kesin Test Vektörleri (KAT), Python altın-modelinden üretilip
//   test_tam_akis görevine parametre olarak eklenebilir.
//
// PAKETİ PROTOKOLÜ: 256-bit = 8 × 32-bit, LSB-önce
// ÇALIŞTIRMA (Vivado): run 900ms  — ECC matematigi yavas, 4 senaryo
//   yaklasik 15 M cevrim (150 ms) surer. "run 5ms" ESKI ve YANLISTI.
// Standart : SystemVerilog-2012
// =============================================================================

`timescale 1ns / 1ps

module tb_ecdh_kex_top;

// =====================================================================
// NIST P-256 Sabitleri (Montgomery alanı)
// =====================================================================
localparam [255:0] R_MOD_P =
    256'h00000000fffffffeffffffffffffffffffffffff000000000000000000000001;
localparam [255:0] GX_MONT =
    256'h18905f76a53755c679fb732b7762251075ba95fc5fedb60179e730d418a9143c;
localparam [255:0] GY_MONT =
    256'h8571ff1825885d85d2e88688dd21f3258b4ab8e4ba19e45cddf25357ce95560a;

// d=1 için beklenen Affin sonuç = G
localparam [255:0] BEK_X = GX_MONT;
localparam [255:0] BEK_Y = GY_MONT;

// =====================================================================
// Qb giriş ve çıkış seçicileri
// =====================================================================
localparam [1:0] QBIX_X = 2'b00;
localparam [1:0] QBIX_Y = 2'b01;
localparam [1:0] STAGE_QA = 2'b01;
localparam [1:0] STAGE_SS = 2'b10;

localparam integer CLK_NS   = 10;
// ── ZAMAN AŞIMI SINIRI — ÖLÇÜLMÜŞ DEĞERE GÖRE ────────────────────────────
//   Önceki değer 2_000_000 çevrim (20 ms) idi ve GERÇEK SÜREDEN KISAYDI:
//   TB-12 (tb_ecdh_uart_top) gerçek donanımda Qa'nın TEK BAŞINA 2_137_918
//   çevrim (21.38 ms) sürdüğünü ölçtü. Yani bu testbench mevcut çekirdekle
//   hiçbir zaman geçemezdi; bu yüzden others/ altında, regresyon dışında
//   kalmıştı. Faz 4 değişiklikleriyle ilgisi yoktur.
//
//   Bir aşamanın (Qa veya Ortak Sır) maliyeti:
//     skaler çarpım 256 iterasyon + affine dönüşüm (FLT ile 256 MALU çağrısı)
//     ≈ 2.14 M çevrim. Tam akış = Qa + Ortak Sır ≈ 4.3 M çevrim (43 ms).
//
//   4 M çevrim (40 ms) aşama başına ~%87 pay bırakır — çekirdek biraz
//   yavaşlarsa test yanlış alarm vermez, gerçekten kilitlenirse yakalar.
localparam integer TIMEOUT  = 4_000_000;  // asama basina maks cevrim (40 ms)
// ── GEÇERSİZ NOKTA REDDİ İÇİN ZAMAN AŞIMI ────────────────────────────────
//   Önceki değer 500 çevrimdi ve Faz 1'den SONRA yetersiz kaldı.
//
//   ESKİ DAVRANIŞ: K_QB_VALIDATE yalnızca (x==0 && y==0) bakıyordu. Bu
//   kombinasyonel bir karşılaştırmaydı; ret TEK ÇEVRİMDE geliyordu, 500 bol
//   geliyordu.
//
//   YENİ DAVRANIŞ: nokta_dogrula, noktanın gerçekten eğri üzerinde olup
//   olmadığını sınar — aralık kontrolü + y² = x³ − 3x + b denklemi, yani
//   7 MALU çağrısı ≈ 2300 çevrim. (0,0) da bu denklem tarafından reddedilir
//   (0 != b), ayrı bir özel durum yoktur.
//
//   Yani ret ARTIK YAVAŞ — ve bu bir gerileme değil, doğrulamanın gerçekten
//   yapılıyor olmasının bedelidir. Eski hızlı ret, kontrolün neredeyse hiç
//   yapılmadığının göstergesiydi.
//
//   Yan fayda: ret süresi noktanın NEDEN geçersiz olduğundan bağımsız olarak
//   yaklaşık sabittir; hangi kontrolün takıldığı zamanlamadan sızmaz.
//
//   20_000 çevrim (0.2 ms) ~9x pay bırakır.
localparam integer ERR_TO   = 20_000;

// =====================================================================
// DUT Sinyalleri
// =====================================================================
logic        clk_in, rst_n;
logic        i_start;
logic        o_trng_req;
logic        i_trng_vld;
logic [31:0] i_trng_pkt;
logic [31:0] i_pkt_in;
logic        i_pkt_vld;
logic [2:0]  i_pkt_sel;
logic        i_qb_start;
logic [31:0] o_pkt_out;
logic        o_pkt_vld;
logic [1:0]  o_pkt_sel;
logic        o_pkt_last;
logic [1:0]  o_stage;
logic        o_qa_done;
logic        o_rdy, o_done, o_err;

// =====================================================================
// TRNG Mock Kontrol Değişkenleri
// =====================================================================
logic [255:0] trng_deger;      // Döndürülecek 256-bit değer
int           trng_gecikme;    // Talep sonrası latency (çevrim)
bit           trng_sifir_ilk;  // İlk talebe 0 döndür (zayıf anahtar testi)
int           trng_servis_cnt; // Kaçıncı talep servis edildi

// =====================================================================
// Çıkış Toplayıcı Kayıtçıları
// =====================================================================
logic [255:0] qa_x, qa_y, ss_x, ss_y;
logic [2:0]   cx_qa, cy_qa, cx_ss, cy_ss;
logic         qa_ready, ss_ready;

int toplam_test, basarili_test;

// =====================================================================
// DUT
// =====================================================================
ecdh_kex_top dut (
    .clk_in(clk_in), .rst_n(rst_n),
    .i_start(i_start),
    .o_trng_req(o_trng_req), .i_trng_vld(i_trng_vld), .i_trng_pkt(i_trng_pkt),
    .i_pkt_in(i_pkt_in), .i_pkt_vld(i_pkt_vld), .i_pkt_sel(i_pkt_sel),
    .i_qb_start(i_qb_start),
    .o_pkt_out(o_pkt_out), .o_pkt_vld(o_pkt_vld), .o_pkt_sel(o_pkt_sel),
    .o_pkt_last(o_pkt_last), .o_stage(o_stage), .o_qa_done(o_qa_done),
    // FAZ 4 — slot arayuzu. Bagsiz birakilirsa z -> x yayilir.
        .i_slot(2'd0), .i_politika(8'h01), .i_zeroize(1'b0),
        // Bu TB ECDH yolunu sinar; imzalama girisleri sabit sifir.
        // Bagsiz birakilsa z -> x yayilir ve ECDH yolunu da bozardi.
        .i_dogrula(1'b0), .i_uret(1'b0), .i_imzala(1'b0), .i_hash_pkt(32'd0), .i_hash_vld(1'b0),
        .o_imza_hazir(), .o_imza_sel(), .o_imza_tekrar(),
        .o_imza_gecerli(), .o_imza_aralik_hata(),
        .o_slot_hata(), .o_uret_hata_kod(),
        .o_rdy(o_rdy), .o_done(o_done), .o_err(o_err),
        // ── ÇOKLU EĞRİ DESTEĞİ (İster M-24) — P-256 sabit degerleri ─────
        //   Bu TB komut_yoneticisi/parametre_deposu'nu ATLAYIP ecdh_kex_top'u
        //   DOGRUDAN surdugu icin bu portlar burada P-256 literalleriyle
        //   BESLENMELIDIR; aksi halde bagsiz giris X yayar ve TUM testler
        //   o_err ile basarisiz olur (bu TB'nin daha once yasadigi hata).
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

// =====================================================================
// Saat — 100 MHz
// =====================================================================
initial clk_in = 1'b0;
always #(CLK_NS/2) clk_in = ~clk_in;

// =====================================================================
// TRNG DAVRANIŞSAL MOCK
//   o_trng_req yükseldiğinde gecikme sonrası 8 paket sürer.
// =====================================================================
initial begin
    integer k;
    logic [255:0] gonderilecek;
    i_trng_vld = 1'b0;
    i_trng_pkt = 32'd0;
    forever begin
        @(posedge clk_in);
        if (o_trng_req && rst_n) begin
            // Talep latency'si (TRNG gecikmesi modeli)
            repeat (trng_gecikme) @(posedge clk_in);
            // İlk talepte zayıf anahtar (0) enjeksiyonu opsiyonu
            if (trng_sifir_ilk && trng_servis_cnt == 0)
                gonderilecek = 256'd0;
            else
                gonderilecek = trng_deger;
            trng_servis_cnt = trng_servis_cnt + 1;
            // 8 × 32-bit paket sür
            for (k = 0; k < 8; k = k + 1) begin
                @(posedge clk_in); #1;
                i_trng_pkt = gonderilecek[k*32 +: 32];
                i_trng_vld = 1'b1;
            end
            @(posedge clk_in); #1;
            i_trng_vld = 1'b0;
            // Talep düşene kadar bekle (sonraki talebe hazırlan)
            while (o_trng_req) @(posedge clk_in);
        end
    end
end

// =====================================================================
// ÇIKIŞ TOPLAYICI: Qa ve Ortak Sır koordinatlarını yakala
// =====================================================================
always @(posedge clk_in or negedge rst_n) begin
    if (!rst_n) begin
        qa_x<=256'd0; qa_y<=256'd0; ss_x<=256'd0; ss_y<=256'd0;
        cx_qa<=3'd0; cy_qa<=3'd0; cx_ss<=3'd0; cy_ss<=3'd0;
        qa_ready<=1'b0; ss_ready<=1'b0;
    end else begin
        if (o_pkt_vld) begin
            case ({o_stage, o_pkt_sel})
                {STAGE_QA, 2'b00}: begin qa_x[cx_qa*32 +: 32]<=o_pkt_out; cx_qa<=cx_qa+3'd1; end
                {STAGE_QA, 2'b01}: begin qa_y[cy_qa*32 +: 32]<=o_pkt_out; cy_qa<=cy_qa+3'd1; end
                {STAGE_SS, 2'b00}: begin ss_x[cx_ss*32 +: 32]<=o_pkt_out; cx_ss<=cx_ss+3'd1; end
                {STAGE_SS, 2'b01}: begin ss_y[cy_ss*32 +: 32]<=o_pkt_out; cy_ss<=cy_ss+3'd1; end
                default: ;
            endcase
        end
        if (o_qa_done) qa_ready<=1'b1;
        if (o_done)    ss_ready<=1'b1;
    end
end

// =====================================================================
// GÖREV: DUT sıfırla ve tüm sinyalleri temizle
// =====================================================================
task automatic dut_reset;
    begin
        rst_n = 1'b0;
        i_start=1'b0; i_pkt_in=32'd0; i_pkt_vld=1'b0; i_pkt_sel=2'd0;
        i_qb_start=1'b0;
        trng_deger=256'd1; trng_gecikme=3; trng_sifir_ilk=1'b0; trng_servis_cnt=0;
        repeat(5) @(posedge clk_in);
        rst_n = 1'b1;
        repeat(3) @(posedge clk_in);
    end
endtask

// =====================================================================
// GÖREV: Qb (Affin) gönder — 8 X + 8 Y paketi
// =====================================================================
task automatic gonder_qb(input [255:0] qx, input [255:0] qy);
    integer k;
    begin
        for (k = 0; k < 8; k = k + 1) begin
            @(posedge clk_in); #1;
            i_pkt_in=qx[k*32 +: 32]; i_pkt_vld=1'b1; i_pkt_sel=QBIX_X;
        end
        for (k = 0; k < 8; k = k + 1) begin
            @(posedge clk_in); #1;
            i_pkt_in=qy[k*32 +: 32]; i_pkt_vld=1'b1; i_pkt_sel=QBIX_Y;
        end
        @(posedge clk_in); #1;
        i_pkt_vld=1'b0;
        // Qb yüklendi → Ortak Sır hesabına geç
        @(posedge clk_in); #1;
        i_qb_start=1'b1;
        @(posedge clk_in); #1;
        i_qb_start=1'b0;
    end
endtask

// =====================================================================
// GÖREV: kontrol — 256-bit eşitlik
// =====================================================================
task automatic kontrol(input [255:0] gelen, input [255:0] beklenen, input string ad);
    begin
        toplam_test++;
        if (gelen === beklenen) begin
            basarili_test++;
            $display("  [PASS] %s", ad);
            $display("         0x%064x", gelen);
        end else begin
            $display("  [FAIL] %s", ad);
            $display("         Gelen   : 0x%064x", gelen);
            $display("         Beklenen: 0x%064x", beklenen);
        end
    end
endtask

// =====================================================================
// GÖREV: Tam anahtar değişim akışı testi (d=1 çapası)
// =====================================================================
task automatic test_tam_akis(input string ad);
    int bekle;
    begin
        $display("\n[INFO] %s — oturum baslatiliyor (i_start)...", ad);
        @(posedge clk_in); #1; i_start=1'b1;
        @(posedge clk_in); #1; i_start=1'b0;

        // ── Qa hazır olana kadar bekle ────────────────────────────────
        bekle = 0;
        while (!qa_ready && !o_err && bekle < TIMEOUT) begin @(posedge clk_in); bekle++; end
        if (o_err) begin
            $display("  [FAIL] %s — Qa fazinda beklenmeyen o_err!", ad);
            toplam_test++; return;
        end
        if (bekle >= TIMEOUT) begin
            $display("  [FAIL] %s — Qa zaman asimi!", ad);
            toplam_test++; return;
        end
        $display("[INFO] %s — Qa alindi (%0d cevrim). Dogrulaniyor...", ad, bekle);
        kontrol(qa_x, BEK_X, {ad, " Qa.X"});
        kontrol(qa_y, BEK_Y, {ad, " Qa.Y"});

        // ── Karşı taraf açık anahtarı Qb = G gönder ───────────────────
        $display("[INFO] %s — Qb = G gonderiliyor...", ad);
        gonder_qb(GX_MONT, GY_MONT);

        // ── Ortak Sır hazır olana kadar bekle ─────────────────────────
        bekle = 0;
        while (!ss_ready && !o_err && bekle < TIMEOUT) begin @(posedge clk_in); bekle++; end
        if (o_err) begin
            $display("  [FAIL] %s — Ortak Sir fazinda beklenmeyen o_err!", ad);
            toplam_test++; return;
        end
        if (bekle >= TIMEOUT) begin
            $display("  [FAIL] %s — Ortak Sir zaman asimi!", ad);
            toplam_test++; return;
        end
        $display("[INFO] %s — Ortak Sir alindi (%0d cevrim). Dogrulaniyor...", ad, bekle);
        // Qb=G ve d=1 → S = 1·G = G
        kontrol(ss_x, BEK_X, {ad, " OrtakSir.X"});
        kontrol(ss_y, BEK_Y, {ad, " OrtakSir.Y"});
    end
endtask

// =====================================================================
// GÖREV: Hatalı Qb testi (o_err beklenir)
// =====================================================================
task automatic test_hatali_qb(input string ad);
    int bekle;
    begin
        $display("\n[INFO] %s — Qa alinip hatali Qb=(0,0) gonderilecek...", ad);
        @(posedge clk_in); #1; i_start=1'b1;
        @(posedge clk_in); #1; i_start=1'b0;
        bekle = 0;
        while (!qa_ready && !o_err && bekle < TIMEOUT) begin @(posedge clk_in); bekle++; end
        if (!qa_ready) begin
            $display("  [FAIL] %s — Qa alinamadi!", ad); toplam_test++; return;
        end
        // Qb = (0,0) — geçersiz
        gonder_qb(256'd0, 256'd0);
        bekle = 0;
        while (!o_err && bekle < ERR_TO) begin @(posedge clk_in); bekle++; end
        toplam_test++;
        if (bekle < ERR_TO) begin
            basarili_test++;
            $display("  [PASS] %s — o_err=1 alindi (%0d cevrim)", ad, bekle);
        end else begin
            $display("  [FAIL] %s — o_err beklendi ama gelmedi!", ad);
        end
    end
endtask

// =====================================================================
// Ana Test Akışı
// =====================================================================
initial begin
    toplam_test = 0; basarili_test = 0;

    $display("\n============================================================");
    $display("  ecdh_kex_top UST-SEVIYE TESTBENCH (TRNG mock)");
    $display("============================================================");

    // ── TEST A: Normal akış, d=1, kısa TRNG gecikmesi ─────────────────
    dut_reset();
    trng_deger=256'd1; trng_gecikme=3; trng_sifir_ilk=1'b0;
    test_tam_akis("A: Normal akis (d=1)");

    // ── TEST B: Uzun TRNG gecikmesi ───────────────────────────────────
    dut_reset();
    trng_deger=256'd1; trng_gecikme=40; trng_sifir_ilk=1'b0;
    test_tam_akis("B: TRNG uzun gecikme (d=1)");

    // ── TEST C: Zayıf anahtar (ilk TRNG=0) → yeniden talep koruması ────
    dut_reset();
    trng_deger=256'd1; trng_gecikme=3; trng_sifir_ilk=1'b1;
    test_tam_akis("C: Zayif anahtar yeniden-talep (0 -> 1)");

    // ── TEST D: Hatalı Qb=(0,0) → o_err ───────────────────────────────
    dut_reset();
    trng_deger=256'd1; trng_gecikme=3; trng_sifir_ilk=1'b0;
    test_hatali_qb("D: Hatali Qb=(0,0)");

    // ── Özet ──────────────────────────────────────────────────────────
    $display("\n============================================================");
    $display("  GENEL SONUC: %0d / %0d test basarili", basarili_test, toplam_test);
    if (basarili_test == toplam_test)
        $display("  >>> TUM TESTLER GECTI <<<  [PASS]");
    else
        $display("  !!! %0d TEST HATALI !!!    [FAIL]", toplam_test - basarili_test);
    $display("============================================================\n");
    $finish;
end

// =====================================================================
// Mutlak Zaman Aşımı
// =====================================================================
initial begin
    // 4 senaryo x (Qa + Ortak Sir) ~= 15 M cevrim. TIMEOUT*20 = 80 M cevrim
    // (800 ms) bol pay birakir. Onceki carpan 4 idi ve TEK bir senaryoyu bile
    // tamamlayamadan devreye giriyordu.
    repeat(TIMEOUT * 20) @(posedge clk_in);
    $fatal(1, "[HATA] Mutlak simulasyon zaman asimi — ecdh_kex_top yanit vermiyor!");
end

initial begin
    $dumpfile("tb_ecdh_kex_top.vcd");
    $dumpvars(0, tb_ecdh_kex_top);
end

endmodule
