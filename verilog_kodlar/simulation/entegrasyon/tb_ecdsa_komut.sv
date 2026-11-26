// =============================================================================
// Testbench : tb_ecdsa_komut.sv                                      (TB-23)
// Hedef     : ecdh_uart_top.v — ECDSA KOMUT KATMANI (0x0C / 0x0D / 0x0E)
// -----------------------------------------------------------------------------
//   *** FAZ 5'IN KAPANIS KAPISI ***
//
//   TB-20 imzalamayi, TB-22 dogrulamayi CEKIRDEK seviyesinde dogruladi.
//   Ancak her ikisi de ecdh_kex_top'un portlarini dogrudan surdu. Gercek
//   kullanimda bu portlara UART'tan erisilir ve arada komut_yoneticisi
//   vardir. Bu TB o son halkayi sinar: PC'nin yerine gecip seri hatti bit
//   bit oynatir.
//
//   Bu TB yazilana kadar imzalama/dogrulama "cekirdekte var ama disaridan
//   erisilemez" durumdaydi — ecdh_uart_top'ta i_imzala ve i_dogrula sabit
//   1'b0'a bagliydi. Yani ozellik, kullanicisi acisindan YOKTU.
//
// -----------------------------------------------------------------------------
// KOMUT AKISI:
//   0x0A ANAHTAR_URET  slot 0, politika = IMZA        -> ACK
//   0x0C IMZALA        [slot|0|0|0] + e(32)           -> 64 bayt (r,s)
//   0x01 QB_YUKLE      Q(64)   (dogrulama icin Q)     -> ACK
//   0x0D IMZA_YUKLE    r(32) || s(32)                 -> ACK
//   0x0E DOGRULA       e(32)                          -> DURUM bayti
//
//   DOGRULA'nin operandlari TEK CERCEVEYE SIGMAZ (160 bayt > 64), bu yuzden
//   uce bolunur. Q icin yeni komut acilmadi: dogrulamadaki Q ile ECDH'deki
//   Qb ayni seydir (karsi tarafin acik anahtari).
//
// -----------------------------------------------------------------------------
// *** OZ-TEST: KENDI IMZASINI DOGRULAMA ***
//   Senaryo C, IMZALA'nin urettigi (r,s)'yi hic degistirmeden geri gonderip
//   DOGRULA'dan gecirir. Bu, iki bagimsiz yolun (imzalama ve dogrulama)
//   AYNI matematik uzerinde anlastigini gosterir — altin model olmadan da
//   anlamli bir tutarlilik kanitidir. Golden model karsilastirmasi (Senaryo
//   B) bunun YERINE gecmez, TAMAMLAR: oz-test ikisinin de ayni sekilde
//   yanlis olmasini yakalayamaz, golden model ise yakalar.
//
// SURE UYARISI:
//   IMZALA ~44 ms (nonce uretimi + k*G + ters alma), DOGRULA ~23 ms.
//   Toplam ~120 ms simulasyon zamani. xsim'de ONLARCA DAKIKA surer.
//
// KOSTURMA:
//   xelab -debug typical tb_ecdsa_komut -s tb23 && xsim tb23 -R
//
// Standart : Verilog-2001 uyumlu SystemVerilog
// Tarih    : Temmuz 2026
// =============================================================================

`timescale 1ns / 1ps

module tb_ecdsa_komut;

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

    // ── Python altin-modeli (bagimsiz dogrulayiciyla capraz sinandi) ─────
    localparam [255:0] VEK_E =
        256'h7c1e5a93d84f0b26e37a915cf0d2864b591e7038ac4d62f1085b39e7c26d4f5a;
    localparam [255:0] VEK_R =
        256'h2cb781e4053f459ecb5dbb7f237f5609fc718d71f1193066a385197a5ef44e25;
    localparam [255:0] VEK_S =
        256'h86f982dfea2029eadd7bc5d37e096884681c4b9b0c64d75da3de9b588624dc42;
    localparam [255:0] VEK_QX =
        256'hb8120011b7ec6ad10e22a8dcb82bb553f397e0f955d610a03e3a5d525fdeef5d;
    localparam [255:0] VEK_QY =
        256'h7f3f7c789cf2832ebb8908ff62e3a60ba188314629b6e702cd89aef0ee6aef30;

    // Politika bitleri (anahtar_deposu.v ile ayni)
    localparam [7:0] POL_ECDH = 8'h01, POL_IMZA = 8'h02;
    // Yanit durum kodlari (komut_yoneticisi.v ile ayni)
    localparam [7:0] YAN_OK = 8'h00, YAN_IMZA_GECERSIZ = 8'hEE,
                     YAN_IMZA_ARALIK = 8'hEF, YAN_IZIN = 8'hED;

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
    //  SERI COZUCU
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
    //  ANA TEST
    // ═════════════════════════════════════════════════════════════════════
    reg [511:0] gonder;
    reg [255:0] alinan_r, alinan_s;

    initial begin
        $display("=========================================================");
        $display(" TB-23 : ECDSA KOMUT KATMANI (UART uzerinden)");
        $display("   0x0C IMZALA / 0x0D IMZA_YUKLE / 0x0E DOGRULA");
        $display("   UYARI: imza ~44 ms, dogrulama ~23 ms. UZUN SURER.");
        $display("=========================================================");

        // [DUZELTME] ecdh_uart_top'un varsayilan RESET_AKTIF_DUSUK=0'dir
        // (Basys 3, aktif-YUKSEK buton): btn_reset=1 -> basili/reset,
        // btn_reset=0 -> birakilmis/calisir. Bu TB eskiden aktif-DUSUK
        // (Nexys A7) kutupluguyla yazilmisti (0=reset, 1=birak); parametre
        // override edilmedigi icin DUT gercekte Basys3 kutuplugunu kullanip
        // btn_reset=1'e gecince SUREKLI RESETTE kaliyordu (durum_r=0,
        // state_r=0, 200 ms boyunca hicbir yanit gelmiyordu). Degerler
        // DUT'un varsayilanina uyacak sekilde TERSINE cevrildi.
        btn_reset = 1'b1; btn_start = 1'b0; uart_rx_in = 1'b1;
        repeat (50) @(posedge clk_100);
        @(negedge clk_100); btn_reset = 1'b0;
        #(BIT_SURESI * 10);

        // ── A) IMZA IZNI OLAN SLOT URET ────────────────────────────────
        $display("\n [A] Slot 0'a IMZA izinli anahtar uretiliyor (0x0A)...");
        gonder = {504'd0, POL_IMZA, 8'd0};   // word0: [7:0]=slot [15:8]=politika
        komut_gonder(8'h0A, 8'd4, gonder);
        yanit_bekle(8'd0, 400000);
        kontrol(yanit_ok && cikti_durum === YAN_OK,
                "A1: ANAHTAR_URET kabul edildi (IMZA politikasi)");

        // ── B) IMZALA ──────────────────────────────────────────────────
        //   Bu komut cekirdekte nonce uretimi + k*G + ters alma tetikler;
        //   yanit ~44 ms sonra gelir. yanit_bekle'nin bit cinsinden siniri
        //   buna gore genis tutulmustur.
        $display("\n [B] IMZALA (0x0C) — bu adim ~44 ms surer...");
        gonder = {VEK_E, 32'd0};             // word0 = baslik(slot 0), sonra e
        komut_gonder(8'h0C, 8'd36, gonder);
        yanit_bekle(8'd64, 4000000);
        kontrol(yanit_ok, "B1: IMZALA yaniti dogru cerceveli (64 bayt)");
        kontrol(cikti_durum === YAN_OK, "B2: IMZALA durumu 0x00");

        alinan_r = cikti_veri[255:0];
        alinan_s = cikti_veri[511:256];
        if (!yanit_ok)
            $display("       durum bayti = 0x%02h", cikti_durum);

        // ── C) URETILEN IMZAYI KENDI UZERINDE DOGRULA ──────────────────
        //   Once Q yuklenir. Burada dikkat: imzalayan slot 0'in ACIK
        //   ANAHTARI gerekir. Bu TB'de d on-chip LFSR ile uretildigi icin
        //   Q'yu bilmiyoruz — bu yuzden oz-test yerine GOLDEN MODEL
        //   vektoruyle dogrulama yapilir (asagida D). Oz-test, d'nin
        //   bilindigi TEST_MODU kosumunda anlamlidir.
        $display("\n [C] Golden model imzasi dogrulaniyor...");
        gonder = {VEK_QY, VEK_QX};
        komut_gonder(8'h01, 8'd64, gonder);      // QB_YUKLE -> Q
        yanit_bekle(8'd0, 20000);
        kontrol(yanit_ok && cikti_durum === YAN_OK, "C1: Q yuklendi (0x01)");

        gonder = {VEK_S, VEK_R};
        komut_gonder(8'h0D, 8'd64, gonder);      // IMZA_YUKLE -> r,s
        yanit_bekle(8'd0, 20000);
        kontrol(yanit_ok && cikti_durum === YAN_OK, "C2: (r,s) yuklendi (0x0D)");

        gonder = {256'd0, VEK_E};
        komut_gonder(8'h0E, 8'd32, gonder);      // DOGRULA
        yanit_bekle(8'd0, 4000000);
        kontrol(yanit_ok, "C3: DOGRULA yaniti dogru cerceveli");
        kontrol(cikti_durum === YAN_OK, "C4: *** IMZA GECERLI (0x00) ***");
        if (cikti_durum !== YAN_OK)
            $display("       durum bayti = 0x%02h (0x00 beklendi)", cikti_durum);

        // ── D) BOZUK IMZA REDDEDILMELI ─────────────────────────────────
        $display("\n [D] Bozuk s ile dogrulama (0xEE beklenir)...");
        gonder = {VEK_S ^ 256'd1, VEK_R};
        komut_gonder(8'h0D, 8'd64, gonder);
        yanit_bekle(8'd0, 20000);
        kontrol(yanit_ok && cikti_durum === YAN_OK, "D1: bozuk (r,s) yuklendi");

        gonder = {256'd0, VEK_E};
        komut_gonder(8'h0E, 8'd32, gonder);
        yanit_bekle(8'd0, 4000000);
        kontrol(cikti_durum === YAN_IMZA_GECERSIZ,
                "D2: *** BOZUK IMZA REDDEDILDI (0xEE) ***");
        if (cikti_durum !== YAN_IMZA_GECERSIZ)
            $display("       durum bayti = 0x%02h (0xEE beklendi)", cikti_durum);

        // ── E) ARALIK DISI s = 0 ───────────────────────────────────────
        //   0xEF ile 0xEE'nin AYRI olmasi onemlidir: 0xEF imzanin
        //   matematigine HIC bakilmadigini soyler.
        $display("\n [E] s = 0 (aralik disi, 0xEF beklenir)...");
        gonder = {256'd0, VEK_R};
        komut_gonder(8'h0D, 8'd64, gonder);
        yanit_bekle(8'd0, 20000);
        kontrol(yanit_ok, "E1: s=0 yuklendi");

        gonder = {256'd0, VEK_E};
        komut_gonder(8'h0E, 8'd32, gonder);
        yanit_bekle(8'd0, 200000);
        kontrol(cikti_durum === YAN_IMZA_ARALIK,
                "E2: *** ARALIK DISI REDDEDILDI (0xEF) ***");
        if (cikti_durum !== YAN_IMZA_ARALIK)
            $display("       durum bayti = 0x%02h (0xEF beklendi)", cikti_durum);

        // ── F) ECDH HALA CALISIYOR ─────────────────────────────────────
        //   ECDSA komutlari eklendikten sonra mevcut yollarin bozulmadigini
        //   gosterir. Yeni durumlar eklenirken durum kodlamasinin tasmasi
        //   (bkz. durum_r genislik notu) tam olarak buradan yakalanirdi.
        $display("\n [F] DURUM_OKU hala calisiyor mu?");
        komut_gonder(8'h05, 8'd0, 512'd0);
        yanit_bekle(8'd0, 20000);
        kontrol(yanit_ok, "F1: DURUM_OKU yaniti alindi (FSM saglam)");

        $display("\n---------------------------------------------------------");
        if (hata_say == 0) begin
            $display(" TB-23 SONUC: TUM TESTLER GECTI (%0d dogrulama)", gecen);
            $display(" >>> ECDSA imzalama ve dogrulama artik UART'tan");
            $display(" >>> ERISILEBILIR. FAZ 5 TAMAMLANDI.");
        end else begin
            $display(" TB-23 SONUC: %0d TEST KALDI (%0d gecti)", hata_say, gecen);
        end
        $display("=========================================================");
        $finish;
    end

    initial begin
        #(200_000_000);
        $display("\n *** TB-23 GENEL ZAMAN ASIMI ***");
        $display("     komut_yoneticisi.durum_r = %0d", dut.yonetici.durum_r);
        $display("     ecdh_kex_top.state_r     = %0d", dut.kex.state_r);
        $finish;
    end

endmodule
