// =============================================================================
// Testbench : tb_cok_egri_entegrasyon.sv                              (TB-25)
// Hedef     : ecdh_uart_top.v — ÇOKLU EĞRİ DESTEĞİ, UÇTAN UCA (İster M-24)
// -----------------------------------------------------------------------------
//   *** ÜST SEVİYE ENTEGRASYON KAPISI — parametre_deposu.v'nin gerçek UART
//       protokolü üzerinden (bit-bit RS-232 çerçeveleme dahil) doğru
//       çalıştığını kanıtlar. ***
//
//   Önceki testler (TB-24 = parametre_deposu birim testi, TB-16 SENARYO I =
//   anahtar_deposu maskeleme birim testi) bu modülleri KENDİ arayüzlerinden
//   İZOLE test etti. Bu TB o katmanları ATLAMAZ: gerçek UART bit akışıyla
//   EGRI_* komutlarını gönderir, gerçek bir P-192 anahtar değişimi
//   tetikler ve sonucu BAĞIMSIZ (Python, saf double-and-add) hesaplanmış
//   bir referans değerle karşılaştırır.
//
// -----------------------------------------------------------------------------
// KOMUT AKIŞI:
//   SENARYO A — P-256 REGRESYONU (curve yüklemeden önce, fabrika varsayılanı)
//     0x10 D_YUKLE (yalnız TEST_MODU) + 0x02 ECDH_BASLAT + 0x03 QA_OKU
//     -> bağımsız hesaplanmış d·G ile karşılaştırılır.
//   SENARYO B — P-192 EĞRİ YÜKLEME
//     0x11 EGRI_ALAN_YUKLE x8 (P, R_MOD_P, GX_MONT, GY_MONT, B_MONT,
//          N_ORDER, MONT_BIR_N, R2N) + 0x12 EGRI_UZUNLUK_YUKLE(192,192)
//          + 0x13 EGRI_UYGULA
//   SENARYO C — P-192 İLE GERÇEK ECDH
//     Aynı D_YUKLE/ECDH_BASLAT/QA_OKU akışı, P-192 için bağımsız hesaplanmış
//     d·G ile karşılaştırılır. *** Bu, sadece sabitlerin doğru yüklendiğini
//     değil, MALU/PAU/scalar_multiplier/affine_donusum zincirinin YENİ
//     eğriyle uçtan uca doğru çalıştığını kanıtlayan asıl testtir. ***
//   SENARYO D — VARSAYILANA DÖNÜŞ
//     0x14 EGRI_VARSAYILAN, ardından SENARYO A'nın AYNISI tekrar çalıştırılır
//     — eğri değiştirmenin GERİ ALINABİLİR olduğunu ve P-256'nın bozulmadığını
//     kanıtlar.
//   SENARYO E — PROTOKOL SAĞLAMLIĞI
//     Yanlış uzunlukta EGRI_ALAN_YUKLE (0x11) -> 0xE3 (YAN_UZUNLUK) reddi.
//
// -----------------------------------------------------------------------------
// *** ÖNEMLİ — DETERMİNİSTİK DOĞRULAMA İÇİN TEST_MODU GEREKİR ***
//   D_YUKLE (0x10) yalnızca `TEST_MODU tanımlıyken derlenir/kabul edilir
//   (bkz. komut_yoneticisi.v güvenlik notu — özel anahtarı okutan komut
//   YOKTUR, yalnız TEST modunda yazılabilir). Bu TB, TEST_MODU TANIMSIZ
//   iken de çalışır ama o durumda d on-chip TRNG'den geldiğinden Qa'yı
//   BİLİNEN bir referansla birebir KARŞILAŞTIRAMAZ — yalnızca "ECDH hatasız
//   tamamlandı mı" gibi zayıf bir kontrol yapar. TAM doğrulama için:
//     xelab -d TEST_MODU -debug typical tb_cok_egri_entegrasyon -s tb25
//     xsim tb25 -R
//
// SÜRE UYARISI: ~birkaç yüz bin ns simülasyon zamanı; xsim'de birkaç dakika.
//
// Standart : Verilog-2001 uyumlu SystemVerilog
// Tarih    : Temmuz 2026
// =============================================================================

`timescale 1ns / 1ps

module tb_cok_egri_entegrasyon;

    localparam integer SAAT_HZ      = 100_000_000;
    localparam integer BAUD_HIZI    = 6_250_000;
    localparam real    SAAT_PERIYOT = 10.0;
    localparam real    BIT_SURESI   = 160.0;

    integer hata_say = 0;
    integer gecen    = 0;

    task kontrol(input kosul, input [1023:0] ad);
        begin
            if (kosul) begin $display("  [GECTI] %0s", ad); gecen = gecen + 1; end
            else begin $display("  [KALDI] %0s", ad); hata_say = hata_say + 1; end
        end
    endtask

    // ── Yanit durum kodlari (komut_yoneticisi.v ile ayni) ────────────────
    localparam [7:0] YAN_OK = 8'h00, YAN_UZUNLUK = 8'hE3;

    // ── Alan kimlikleri (parametre_deposu.v ile BİREBİR ayni) ────────────
    localparam [3:0] ALN_P=4'd0, ALN_R_MOD_P=4'd1, ALN_GX_MONT=4'd2,
                     ALN_GY_MONT=4'd3, ALN_B_MONT=4'd4, ALN_N_ORDER=4'd5,
                     ALN_MONT_BIR_N=4'd6, ALN_R2N=4'd7;

    // ── P-256 (fabrika varsayilani) — Python double-and-add ile bagimsiz
    //    hesaplanmis d, Qx, Qy (bkz. TB baslik notu) ───────────────────────
    localparam [255:0] P256_D  =
        256'h00000000123456789abcdef0112233445566778899aabbccddeeff0011223344;
    localparam [255:0] P256_QX =
        256'h38610cbe5fca97daa945cf2738d14dc8c979daa895cd8e1e4c9adb2389941b69;
    localparam [255:0] P256_QY =
        256'hac3e6cb0b23684b8f033093f7f575a9a1ded4144f4e422fde1e4e3c15fee4a3f;

    // ── P-192 (secp192r1) sabitleri — R=2^256, Python'da hesaplanip
    //    GX_MONT icin R^-1 mod p ile geri cozulerek Gx'e esitligi
    //    dogrulanmisti (bkz. data/DATA.md) ──────────────────────────────────
    localparam [255:0] P192_P          = 256'h0000000000000000fffffffffffffffffffffffffffffffeffffffffffffffff;
    localparam [255:0] P192_R_MOD_P    = 256'h0000000000000000000000000000000100000000000000010000000000000000;
    localparam [255:0] P192_GX_MONT    = 256'h00000000000000008a4bd3f776d12909a2d97c062701b9ff954cc8f9f3d218f7;
    localparam [255:0] P192_GY_MONT    = 256'h0000000000000000de22b5248966f05ee53be0ba892fcad66a293d836aeda84d;
    localparam [255:0] P192_B_MONT     = 256'h00000000000000007281cdb219076ae2d6a2d2cbfea3ebc973c8eec557c0b131;
    localparam [255:0] P192_N_ORDER    = 256'h0000000000000000ffffffffffffffffffffffff99def836146bc9b1b4d22831;
    localparam [255:0] P192_MONT_BIR_N = 256'h000000000000000000000000662107c9eb94364e4b2dd7cf0000000000000000;
    localparam [255:0] P192_R2N        = 256'h0000000000000000126792c4cef5d8c5d69c6961caaf687f01d1770a83134c27;
    localparam [9:0]   P192_BIT        = 10'd192;

    // ── P-192'de, YUKARIDAKI ayni d ile bagimsiz hesaplanmis d.G ─────────
    //   (d mod n_192 alinarak elde edildi — bkz. TB baslik notundaki Python
    //   betigi; d, P-192 icin de 256-bit alanda ust bitleri sifir olarak
    //   tasinir — mimarinin "256-bit yapisal genislik, curve-native deger
    //   ust bitlerde sifirla dolgulanir" kuralina uygun.)
    localparam [255:0] P192_D  =
        256'h00000000000000009abcdef0112233445ca9ab4959587d839ed73f71192ae64c;
    localparam [255:0] P192_QX =
        256'h000000000000000072c3d28a0efdb0dba29b9d8565a155a1ee7756ec1b9d4c35;
    localparam [255:0] P192_QY =
        256'h00000000000000001a78f9499f8271491c88db046019750c25ee3d4846e58180;

    reg         clk_100 = 1'b0;
    reg         btn_reset, btn_start, uart_rx_in;
    wire        uart_tx_out;
    wire [15:0] led;

    always #(SAAT_PERIYOT/2.0) clk_100 = ~clk_100;

    ecdh_uart_top #(.SAAT_HZ(SAAT_HZ), .BAUD_HIZI(BAUD_HIZI)) dut (
        .clk_100(clk_100), .btn_reset(btn_reset), .btn_start(btn_start),
        .uart_rx_in(uart_rx_in), .uart_tx_out(uart_tx_out), .led(led)
    );

    // ═════════════════════════════════════════════════════════════════════
    //  SERI COZUCU / KURUCU (tb_ecdsa_komut.sv ile BIREBIR ayni harness)
    // ═════════════════════════════════════════════════════════════════════
    reg [7:0] alinan [0:127];
    integer   alinan_say = 0;

    initial begin : seri_dinleyici
        reg [7:0] b; integer k;
        forever begin
            @(negedge uart_tx_out);
            #(BIT_SURESI * 1.5);
            for (k = 0; k < 8; k = k + 1) begin
                b[k] = uart_tx_out;
                if (k < 7) #(BIT_SURESI);
            end
            #(BIT_SURESI);
            if (alinan_say < 128) begin
                alinan[alinan_say] = b; alinan_say = alinan_say + 1;
            end
        end
    end

    function [7:0] crc8_bayt(input [7:0] mevcut, input [7:0] yeni);
        reg [7:0] g; integer k;
        begin
            g = mevcut ^ yeni;
            for (k = 0; k < 8; k = k + 1)
                g = g[7] ? ((g << 1) ^ 8'h07) : (g << 1);
            crc8_bayt = g;
        end
    endfunction

    task seri_bayt(input [7:0] b);
        integer k;
        begin
            uart_rx_in = 1'b0; #(BIT_SURESI);
            for (k = 0; k < 8; k = k + 1) begin
                uart_rx_in = b[k]; #(BIT_SURESI);
            end
            uart_rx_in = 1'b1; #(BIT_SURESI);
            #(BIT_SURESI/2);
        end
    endtask

    reg [7:0] crc_r;

    task komut_gonder(input [7:0] komut, input [7:0] uzunluk, input [511:0] veri);
        integer k; reg [7:0] b;
        begin
            alinan_say = 0; crc_r = 8'h00;
            b = 8'hA5;   crc_r = crc8_bayt(crc_r, b); seri_bayt(b);
            b = komut;   crc_r = crc8_bayt(crc_r, b); seri_bayt(b);
            b = uzunluk; crc_r = crc8_bayt(crc_r, b); seri_bayt(b);
            for (k = 0; k < uzunluk; k = k + 1) begin
                b = veri[k*8 +: 8]; crc_r = crc8_bayt(crc_r, b); seri_bayt(b);
            end
            seri_bayt(crc_r);
        end
    endtask

    reg [511:0] cikti_veri;
    reg [7:0]   cikti_durum;
    reg         yanit_ok;

    task yanit_bekle(input [7:0] bek_uzunluk, input integer azami_bit);
        integer bek, k; reg [7:0] crc_bek;
        begin
            yanit_ok = 1'b1; cikti_veri = 512'd0; cikti_durum = 8'hFF;
            bek = 0;
            while (alinan_say < (bek_uzunluk + 4) && bek < azami_bit) begin
                #(BIT_SURESI); bek = bek + 1;
            end
            if (alinan_say != (bek_uzunluk + 4)) begin
                yanit_ok = 1'b0;
                $display("     -> yanit %0d bayt geldi, %0d beklendi",
                         alinan_say, bek_uzunluk + 4);
            end else begin
                if (alinan[0] !== 8'h5A) yanit_ok = 1'b0;
                cikti_durum = alinan[1];
                if (alinan[2] !== bek_uzunluk) yanit_ok = 1'b0;
                crc_bek = 8'h00;
                for (k = 0; k < (bek_uzunluk + 3); k = k + 1)
                    crc_bek = crc8_bayt(crc_bek, alinan[k]);
                if (alinan[bek_uzunluk + 3] !== crc_bek) yanit_ok = 1'b0;
                for (k = 0; k < bek_uzunluk; k = k + 1)
                    cikti_veri[k*8 +: 8] = alinan[3 + k];
            end
        end
    endtask

    // ═════════════════════════════════════════════════════════════════════
    //  ÇOKLU EĞRİ YARDIMCI GÖREVLERİ (bu TB'ye özgü)
    // ═════════════════════════════════════════════════════════════════════
    reg [511:0] gonder;

    // EGRI_ALAN_YUKLE (0x11): 36 bayt = baslik(4,[3:0]=alan_id) + deger(32,
    // LSB sozcuk once). deger 256 bit oldugundan {deger, baslik} tam olarak
    // dogru sozcuk sirasini verir (bkz. komut_yoneticisi.v yorum notu).
    task alan_yukle(input [3:0] alan_id, input [255:0] deger);
        begin
            gonder = {224'd0, deger, 28'd0, alan_id};
            komut_gonder(8'h11, 8'd36, gonder);
            yanit_bekle(8'd0, 20000);
            kontrol(yanit_ok && cikti_durum === YAN_OK,
                    "EGRI_ALAN_YUKLE ACK alindi");
        end
    endtask

    task uzunluk_yukle(input [9:0] p_bit, input [9:0] n_bit);
        reg [31:0] uzun_word;
        begin
            uzun_word = {12'd0, p_bit, n_bit};
            gonder = {480'd0, uzun_word};
            komut_gonder(8'h12, 8'd4, gonder);
            yanit_bekle(8'd0, 20000);
            kontrol(yanit_ok && cikti_durum === YAN_OK,
                    "EGRI_UZUNLUK_YUKLE ACK alindi");
        end
    endtask

    task egri_uygula();
        begin
            komut_gonder(8'h13, 8'd0, 512'd0);
            yanit_bekle(8'd0, 20000);
            kontrol(yanit_ok && cikti_durum === YAN_OK, "EGRI_UYGULA ACK alindi");
        end
    endtask

    task egri_varsayilan();
        begin
            komut_gonder(8'h14, 8'd0, 512'd0);
            yanit_bekle(8'd0, 20000);
            kontrol(yanit_ok && cikti_durum === YAN_OK, "EGRI_VARSAYILAN ACK alindi");
        end
    endtask

    // ── d.G uctan uca uret + oku, bagimsiz referansla karsilastir ────────
    //   TEST_MODU TANIMLIYSA: D_YUKLE ile bilinen d yuklenir, tam
    //   deterministik karsilastirma yapilir. DEGILSE: d on-chip TRNG'den
    //   gelir; yalnizca "hatasiz tamamlandi mi" kontrol edilir (zayif).
    task ecdh_uret_ve_dogrula(input [255:0] d_bilinen, input [255:0] beklenen_qx,
                              input [255:0] beklenen_qy, input [1023:0] etiket);
        begin
`ifdef TEST_MODU
            gonder = {256'd0, d_bilinen};
            komut_gonder(8'h10, 8'd32, gonder);
            yanit_bekle(8'd0, 20000);
            kontrol(yanit_ok && cikti_durum === YAN_OK,
                    {etiket, ": D_YUKLE ACK alindi"});
`endif
            komut_gonder(8'h02, 8'd0, 512'd0);
            yanit_bekle(8'd0, 20000);
            kontrol(yanit_ok && cikti_durum === YAN_OK,
                    {etiket, ": ECDH_BASLAT ACK alindi"});

            // Qa hazir olana kadar GERCEK bayragi bekle (sabit cevrim sayisi
            // TAHMINI DEGIL — TB-16 SENARYO I'de bulunan zamanlama
            // kirilganligina karsi bilincli tercih, bkz. o TB'nin notu).
            wait (dut.yonetici.qa_gecerli_r == 1'b1);
            repeat (5) @(posedge clk_100);

            komut_gonder(8'h03, 8'd0, 512'd0);
            yanit_bekle(8'd64, 200000);
            kontrol(yanit_ok && cikti_durum === YAN_OK,
                    {etiket, ": QA_OKU yaniti dogru cerceveli"});

`ifdef TEST_MODU
            kontrol(cikti_veri[255:0] === beklenen_qx,
                    {etiket, ": Qx bagimsiz referansla ESLESTI"});
            kontrol(cikti_veri[511:256] === beklenen_qy,
                    {etiket, ": Qy bagimsiz referansla ESLESTI"});
            if (cikti_veri[255:0] !== beklenen_qx)
                $display("     Qx bulundu = %h  beklenen = %h",
                         cikti_veri[255:0], beklenen_qx);
            if (cikti_veri[511:256] !== beklenen_qy)
                $display("     Qy bulundu = %h  beklenen = %h",
                         cikti_veri[511:256], beklenen_qy);
`else
            $display("     [NOT] TEST_MODU tanimsiz: d bilinmiyor, Qx/Qy");
            $display("           bagimsiz referansla KARSILASTIRILAMADI.");
            $display("           Tam dogrulama icin: xelab -d TEST_MODU ...");
`endif
        end
    endtask

    // ═════════════════════════════════════════════════════════════════════
    //  ANA TEST
    // ═════════════════════════════════════════════════════════════════════
    initial begin
        $display("=========================================================");
        $display(" TB-25 : COKLU EGRI ENTEGRASYONU (UART uzerinden ucdan uca)");
        $display("   0x11 EGRI_ALAN_YUKLE / 0x12 EGRI_UZUNLUK_YUKLE /");
        $display("   0x13 EGRI_UYGULA / 0x14 EGRI_VARSAYILAN");
`ifdef TEST_MODU
        $display("   YAPILANDIRMA: TEST_MODU TANIMLI (tam deterministik dogrulama)");
`else
        $display("   YAPILANDIRMA: TEST_MODU TANIMSIZ (zayif dogrulama — bkz. baslik)");
`endif
        $display("=========================================================");

        btn_reset = 1'b1; btn_start = 1'b0; uart_rx_in = 1'b1;
        repeat (50) @(posedge clk_100);
        @(negedge clk_100); btn_reset = 1'b0;
        #(BIT_SURESI * 10);

        // ── SENARYO A — P-256 regresyonu (curve yuklemeden ONCE) ─────────
        $display("\n [A] P-256 (fabrika varsayilani) ile ECDH");
        ecdh_uret_ve_dogrula(P256_D, P256_QX, P256_QY, "A");

        // ── SENARYO B — P-192 egri yukleme ────────────────────────────────
        $display("\n [B] P-192 egri parametreleri yukleniyor (0x11 x8 + 0x12 + 0x13)");
        alan_yukle(ALN_P,          P192_P);
        alan_yukle(ALN_R_MOD_P,    P192_R_MOD_P);
        alan_yukle(ALN_GX_MONT,    P192_GX_MONT);
        alan_yukle(ALN_GY_MONT,    P192_GY_MONT);
        alan_yukle(ALN_B_MONT,     P192_B_MONT);
        alan_yukle(ALN_N_ORDER,    P192_N_ORDER);
        alan_yukle(ALN_MONT_BIR_N, P192_MONT_BIR_N);
        alan_yukle(ALN_R2N,        P192_R2N);
        uzunluk_yukle(P192_BIT, P192_BIT);
        egri_uygula();

        // ── SENARYO C — P-192 ile GERCEK ECDH (asil kanit) ────────────────
        $display("\n [C] P-192 ile ECDH — uctan uca dogru mu?");
        ecdh_uret_ve_dogrula(P192_D, P192_QX, P192_QY, "C");

        // ── SENARYO D — varsayilana donus + P-256 regresyonu TEKRAR ───────
        $display("\n [D] EGRI_VARSAYILAN sonrasi P-256 hala dogru mu?");
        egri_varsayilan();
        ecdh_uret_ve_dogrula(P256_D, P256_QX, P256_QY, "D");

        // ── SENARYO E — protokol saglamligi: yanlis uzunluk reddi ─────────
        $display("\n [E] Yanlis uzunlukta EGRI_ALAN_YUKLE reddediliyor mu?");
        gonder = {224'd0, P192_P, 28'd0, ALN_P};
        komut_gonder(8'h11, 8'd4, gonder);   // 36 yerine 4 bayt -> hata
        yanit_bekle(8'd0, 20000);
        kontrol(yanit_ok && cikti_durum === YAN_UZUNLUK,
                "E: yanlis uzunluk -> 0xE3 (YAN_UZUNLUK) reddi");

        $display("\n---------------------------------------------------------");
        if (hata_say == 0) begin
            $display(" TB-25 SONUC: TUM TESTLER GECTI (%0d dogrulama)", gecen);
            $display(" >>> Coklu egri destegi (parametre_deposu + EGRI_*");
            $display(" >>> komutlari) UART uzerinden UCTAN UCA dogrulandi.");
        end else begin
            $display(" TB-25 SONUC: %0d TEST KALDI (%0d gecti)", hata_say, gecen);
        end
        $display("=========================================================");
        $finish;
    end

    initial begin
        #(400_000_000);
        $display("\n *** TB-25 GENEL ZAMAN ASIMI ***");
        $display("     komut_yoneticisi.durum_r = %0d", dut.yonetici.durum_r);
        $display("     ecdh_kex_top.state_r     = %0d", dut.kex.state_r);
        $finish;
    end

endmodule
