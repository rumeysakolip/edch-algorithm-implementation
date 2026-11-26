// =============================================================================
// Testbench : tb_ecdh_uart_top.sv                                  (Ister TB-12)
// Hedef     : ecdh_uart_top.v (M-10) — GERCEK ecdh_kex_top ile
// -----------------------------------------------------------------------------
//   *** SISTEM TESTI — KATMAN 4 KAPANIS KAPISI ***
//
// BU TESTBENCH PC'NIN YERINE GECER.
//   uart_rx_in pinini bit bit oynatir (gercek seri kablo gibi), uart_tx_out'u
//   dinleyip bitleri tekrar bayta cevirir. DUT, bitstream'e donusecek modulun
//   TA KENDISIDIR — sahte cekirdek yoktur, gercek ECC matematigi kosar.
//
//   Akis:  d yukle -> Qb yukle -> baslat -> bekle -> Qa oku -> Sir oku
//          -> golden model degerleriyle BIT BIT karsilastir
//
// -----------------------------------------------------------------------------
// *** TEST_MODU ZORUNLUDUR ***
//   d bilinmeden Qa tahmin edilemez. Normalde d'yi on-chip LFSR uretir.
//   Golden model ile karsilastirma yapabilmek icin 0x10 D_YUKLE ile BILINEN
//   bir d yuklenmelidir; bu komut yalnizca TEST_MODU tanimliyken derlenir.
//
//   xelab ... -d TEST_MODU ...     <-- UNUTULURSA T2 basarisiz olur ve TB
//                                      bunu acikca bildirir.
//
// -----------------------------------------------------------------------------
// SURE UYARISI:
//   Tam bir ECDH islemi iki skaler carpim + iki affine donusum icerir.
//   ecdh_kex_top'un watchdog siniri 12.000.000 cevrimdir; gercek sure
//   tipik olarak birkac milyon cevrimdir. xsim'de bu ONLARCA DAKIKA surebilir.
//   Bu NORMALDIR. Ilerlemeyi gormek icin TB duzenli olarak durum basar.
//
//   UART hizlandirilmistir (BAUD_HIZI=6.25 Mbaud -> BOLUCU=1, bit=160 ns);
//   darbogaz UART degil, ECC matematigidir.
//
// -----------------------------------------------------------------------------
// VEKTOR KAYNAGI (Ister M-13):
//   host/vektor_uret.py --tohum 1  ciktisi. Ayni degerler host betigi
//   tarafindan da kullanilir — TEK DOGRULUK KAYNAGI.
//   ../vektorler/ecdh_vektor.vh dosyasi include edilebiliyorsa o kullanilir;
//   edilemiyorsa asagidaki gomulu kopya devreye girer.
//
// Kosturma (Vivado xsim):
//   xvlog -sv -d TEST_MODU tb_ecdh_uart_top.sv ../sources_1/*.v
//   xelab -debug typical -d TEST_MODU tb_ecdh_uart_top -s tb12
//   xsim tb12 -R
// =============================================================================

`timescale 1ns / 1ps

module tb_ecdh_uart_top;

    // ── UART hizlandirma ──────────────────────────────────────────────────
    localparam integer SAAT_HZ      = 100_000_000;
    localparam integer BAUD_HIZI    = 6_250_000;    // -> BOLUCU=1, bit=16 cevrim
    localparam real    SAAT_PERIYOT = 10.0;         // ns
    localparam real    BIT_SURESI   = 160.0;        // ns (16 cevrim)

    // Ortak Sir'in hazir olmasi icin azami bekleme (cevrim)
    localparam integer AZAMI_BEKLEME = 40_000_000;

    integer hata_say = 0;

    task kontrol(input kosul, input [1023:0] ad);
        begin
            if (kosul) $display("  [GECTI] %0s", ad);
            else begin
                $display("  [KALDI] %0s", ad);
                hata_say = hata_say + 1;
            end
        end
    endtask

    // ═════════════════════════════════════════════════════════════════════
    //  GOLDEN MODEL VEKTORU  (host/vektor_uret.py --tohum 1)
    // ═════════════════════════════════════════════════════════════════════
    localparam [255:0] VEK_D_A  =
        256'hc9afa9d845ba75176c3937d91da02c2a1b2c3d4e5f607182a5d90c3f72a5d7f1;
    localparam [255:0] VEK_QB_X =
        256'hb5e77bb791a2cc9b8871808177e017affebf67930386cecbcc687464212a4abf;
    localparam [255:0] VEK_QB_Y =
        256'he4b6e8718e80e9405377d6b26942db7e109f38753ce09f6c16d2ecf9e80ab59a;
    localparam [255:0] VEK_QA_X =
        256'h13faf75c66aa35163a589578fd914659e3156d852815c49aaa72eebe7ba0923f;
    localparam [255:0] VEK_QA_Y =
        256'h43c06da40fe13d3005b9cfc718679bb48872c8ee44f6f56f773ee51e77ad9539;
    localparam [255:0] VEK_S_X  =
        256'h95c047f3b0dc5cba104efb4a3dd529948bba744cd08421ca2c3eed373760f814;
    localparam [255:0] VEK_S_Y  =
        256'h94c2b6bdfa5edc09f172fee5e0a7e5c29008bd32f9c58a29deb0f26e21796f14;

    // ═════════════════════════════════════════════════════════════════════
    //  DUT — bitstream'e donusecek modulun ta kendisi
    // ═════════════════════════════════════════════════════════════════════
    reg         clk_100 = 1'b0;
    reg         btn_reset;
    reg         btn_start;
    reg         uart_rx_in;
    wire        uart_tx_out;
    wire [15:0] led;

    always #(SAAT_PERIYOT/2.0) clk_100 = ~clk_100;

    ecdh_uart_top #(
        .SAAT_HZ(SAAT_HZ), .BAUD_HIZI(BAUD_HIZI)
    ) dut (
        .clk_100(clk_100),
        .btn_reset(btn_reset),
        .btn_start(btn_start),
        .uart_rx_in(uart_rx_in),
        .uart_tx_out(uart_tx_out),
        .led(led)
    );

    // ── Cevrim sayaci (ilerleme raporu icin) ──────────────────────────────
    integer cevrim_say = 0;
    always @(posedge clk_100) cevrim_say <= cevrim_say + 1;

    // ═════════════════════════════════════════════════════════════════════
    //  TESHIS MONITORU  —  ILK cekirdek hatasini YERINDE yakala
    // ---------------------------------------------------------------------
    //  o_err bir DARBEDIR; TB ana akista ona baktiginda coktan gecmis olur.
    //  Ayrica hata kodu tek basina yetmez: hangi durumda oldugumuzu ve
    //  nokta dogrulamanin girdilerini de ayni cevrimde gormek gerekir,
    //  aksi halde "ERR_NOKTA aldik" deyip nedenini tahmin etmeye kaliriz.
    //  Bu blok hatanin OLDUGU cevrimde her seyi dondurup basar.
    // ═════════════════════════════════════════════════════════════════════
    reg        hata_goruldu = 1'b0;
    reg [2:0]  yak_err_kod;
    reg [6:0]  yak_state;
    reg [255:0] yak_qbx, yak_qby;

    always @(posedge clk_100) begin
        // TB'de rst_n YOKTUR — reset pini btn_reset'tir ve rst_n DUT icinde
        // uretilir. Hiyerarsik erisim: dut.rst_n
        if (dut.rst_n && dut.kex_err && !hata_goruldu) begin
            hata_goruldu <= 1'b1;
            yak_err_kod  <= dut.kex_err_kod;
            yak_state    <= dut.kex.state_r;
            yak_qbx      <= dut.kex.qb_x_r;
            yak_qby      <= dut.kex.qb_y_r;
            $display("\n  *** TESHIS: CEKIRDEK HATASI (cevrim %0d) ***", cevrim_say);
            $display("      o_err_kod   = %0d  (1=NOKTA 2=TRNG 3=CEKIRDEK 4=WDOG 5=SLOT 6=IZIN)",
                     dut.kex_err_kod);
            $display("      kex.state_r = %0d", dut.kex.state_r);
            $display("      nv_gecerli  = %b   nv_done = %b   nv_err = %b",
                     dut.kex.nv_gecerli_w, dut.kex.nv_done_w, dut.kex.nv_err_w);
            $display("      slot_hata   = %b   izin_var = %b  ozel_gecerli = %b",
                     dut.kex_slot_hata, dut.kex.kd_izin_var_w, dut.kex.kd_ozel_gecerli_w);
            $display("      qb_x_r      = 0x%064h", dut.kex.qb_x_r);
            $display("      qb_y_r      = 0x%064h", dut.kex.qb_y_r);
            $display("      beklenen X  = 0x%064h", VEK_QB_X);
            $display("      beklenen Y  = 0x%064h", VEK_QB_Y);
            // NOT: nokta_dogrula.v'de x_r/y_r/mod_p_r/yy_r/mres_r gibi 256-bit
            //   ara yazmaçlar bir refaktörle TAMAMEN KALDIRILDI (bkz. dosyanın
            //   kendi başlığı: "256-bit olanların TAMAMI elendi" — 32-bit'lik
            //   ara_mem BRAM scratchpad'ine geçildi). Eski hiyerarşik referanslar
            //   XSim'de "is not declared under prefix" hatasıyla elaborasyonu
            //   TAMAMEN durduruyordu. Güncel, gerçekten var olan iç sinyallere
            //   güncellendi.
            $display("      nokta_dogrula.state_r   = %0d", dut.kex.nv_inst.state_r);
            $display("      nokta_dogrula.modp_nz_r = %b", dut.kex.nv_inst.modp_nz_r);
            $display("      nokta_dogrula.cmp_esit_r  = %b   cmp_kucuk_r = %b",
                     dut.kex.nv_inst.cmp_esit_r, dut.kex.nv_inst.cmp_kucuk_r);
            $display("      nokta_dogrula.o_gecerli_r = %b   o_err_r = %b\n",
                     dut.kex.nv_inst.o_gecerli_r, dut.kex.nv_inst.o_err_r);
        end
    end

    // ═════════════════════════════════════════════════════════════════════
    //  SERI COZUCU — uart_tx_out'u dinleyip bayta cevir
    // ═════════════════════════════════════════════════════════════════════
    reg [7:0] alinan [0:127];
    integer   alinan_say = 0;

    initial begin : seri_dinleyici
        reg [7:0] b;
        integer   k;
        forever begin
            @(negedge uart_tx_out);            // start biti
            #(BIT_SURESI * 1.5);               // veri0'in ortasi
            for (k = 0; k < 8; k = k + 1) begin
                b[k] = uart_tx_out;            // LSB-first
                if (k < 7) #(BIT_SURESI);
            end
            #(BIT_SURESI);                     // stop bitinin ortasi
            if (alinan_say < 128) begin
                alinan[alinan_say] = b;
                alinan_say = alinan_say + 1;
            end
        end
    end

    // ═════════════════════════════════════════════════════════════════════
    //  CRC-8 ve CERCEVE ARAClari
    // ═════════════════════════════════════════════════════════════════════
    function [7:0] crc8_bayt(input [7:0] mevcut, input [7:0] yeni);
        reg [7:0] g;
        integer k;
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
            uart_rx_in = 1'b0;  #(BIT_SURESI);         // start
            for (k = 0; k < 8; k = k + 1) begin
                uart_rx_in = b[k];  #(BIT_SURESI);     // LSB-first
            end
            uart_rx_in = 1'b1;  #(BIT_SURESI);         // stop
            #(BIT_SURESI/2);                           // baytlar arasi bosluk
        end
    endtask

    reg [7:0] crc_r;

    // Komut cercevesi gonder: [A5][KOMUT][UZUNLUK][VERI][CRC]
    task komut_gonder(input [7:0] komut, input [7:0] uzunluk, input [511:0] veri);
        integer k;
        reg [7:0] b;
        begin
            alinan_say = 0;                    // yanit tamponunu temizle
            crc_r = 8'h00;
            b = 8'hA5;    crc_r = crc8_bayt(crc_r, b); seri_bayt(b);
            b = komut;    crc_r = crc8_bayt(crc_r, b); seri_bayt(b);
            b = uzunluk;  crc_r = crc8_bayt(crc_r, b); seri_bayt(b);
            for (k = 0; k < uzunluk; k = k + 1) begin
                b = veri[k*8 +: 8];            // LSB-first (K-06)
                crc_r = crc8_bayt(crc_r, b);
                seri_bayt(b);
            end
            seri_bayt(crc_r);
        end
    endtask

    // Yanit cercevesini bekle ve dogrula; veriyi cikti_veri'ye koy
    reg [511:0] cikti_veri;
    reg [7:0]   cikti_durum;
    reg         yanit_ok;

    task yanit_bekle(input [7:0] bek_uzunluk, input integer azami_bit);
        integer bek, k;
        reg [7:0] crc_bek;
        begin
            yanit_ok   = 1'b1;
            cikti_veri = 512'd0;

            bek = 0;
            while (alinan_say < (bek_uzunluk + 4) && bek < azami_bit) begin
                #(BIT_SURESI);
                bek = bek + 1;
            end

            if (alinan_say != (bek_uzunluk + 4)) begin
                yanit_ok = 1'b0;
                $display("     -> yanit %0d bayt geldi, %0d beklendi",
                         alinan_say, bek_uzunluk + 4);
            end else begin
                if (alinan[0] !== 8'h5A) begin
                    yanit_ok = 1'b0;
                    $display("     -> baslik 0x%02h (0x5A olmali)", alinan[0]);
                end
                cikti_durum = alinan[1];
                if (alinan[2] !== bek_uzunluk) begin
                    yanit_ok = 1'b0;
                    $display("     -> uzunluk %0d (%0d olmali)", alinan[2], bek_uzunluk);
                end
                crc_bek = 8'h00;
                for (k = 0; k < (bek_uzunluk + 3); k = k + 1)
                    crc_bek = crc8_bayt(crc_bek, alinan[k]);
                if (alinan[bek_uzunluk + 3] !== crc_bek) begin
                    yanit_ok = 1'b0;
                    $display("     -> yanit CRC 0x%02h (0x%02h olmali)",
                             alinan[bek_uzunluk+3], crc_bek);
                end
                for (k = 0; k < bek_uzunluk; k = k + 1)
                    cikti_veri[k*8 +: 8] = alinan[3 + k];
            end
        end
    endtask

    // ═════════════════════════════════════════════════════════════════════
    //  ANA TEST
    // ═════════════════════════════════════════════════════════════════════
    reg [511:0] gonder_veri;
    reg [255:0] qa_x_alinan, qa_y_alinan, s_x_alinan, s_y_alinan;
    integer     bekle_cevrim;
    integer     rapor_sayac;

    initial begin
        $display("=========================================================");
        $display(" TB-12 : ecdh_uart_top — SISTEM TESTI (GERCEK CEKIRDEK)");
`ifdef TEST_MODU
        $display("   TEST_MODU: TANIMLI  (0x10 D_YUKLE kullanilabilir)");
`else
        $display("   *** UYARI: TEST_MODU TANIMSIZ ***");
        $display("   d yuklenemez -> golden model karsilastirmasi YAPILAMAZ.");
        $display("   xelab'a -d TEST_MODU ekleyip tekrar kosturun.");
`endif
        $display("   UART: %0d baud (bit = %0.0f ns)", BAUD_HIZI, BIT_SURESI);
        $display("   UYARI: ECC matematigi yavas — onlarca dakika surebilir.");
        $display("=========================================================");

        // [DUZELTME] ecdh_uart_top varsayilani RESET_AKTIF_DUSUK=0 (Basys 3,
        // aktif-YUKSEK): btn_reset=1 -> reset, btn_reset=0 -> calisir. Eski
        // aktif-DUSUK (Nexys A7) kutupluguyle yazilmis surum DUT'u surekli
        // resette birakiyordu (bkz. tb_ecdsa_komut.sv duzeltmesi).
        btn_reset  = 1'b1;         // aktif-YUKSEK: reset uygulaniyor
        btn_start  = 1'b0;
        uart_rx_in = 1'b1;         // bosta '1'
        repeat (50) @(posedge clk_100);
        @(negedge clk_100); btn_reset = 1'b0;
        #(BIT_SURESI * 10);

        // ── T1: DURUM_OKU — hat calisiyor mu ──────────────────────────────
        $display("\n [1/6] Baglanti kontrolu (DURUM_OKU)...");
        komut_gonder(8'h05, 8'd0, 512'd0);
        yanit_bekle(8'd0, 2000);
        kontrol(yanit_ok, "T1: DURUM_OKU yaniti alindi (hat calisiyor)");
        $display("       durum bayti = 0x%02h", cikti_durum);

`ifdef TEST_MODU
        // ── T2: d yukle (golden model ile karsilastirma icin SART) ────────
        $display("\n [2/6] Bilinen d yukleniyor (0x10 D_YUKLE)...");
        gonder_veri = {256'd0, VEK_D_A};
        komut_gonder(8'h10, 8'd32, gonder_veri);
        yanit_bekle(8'd0, 2000);
        kontrol(yanit_ok && cikti_durum === 8'h00,
                "T2: D_YUKLE kabul edildi (ACK 0x00)");
`else
        $display("\n [2/6] ATLANDI — TEST_MODU tanimsiz.");
        kontrol(1'b0, "T2: TEST_MODU tanimsiz — d yuklenemedi");
`endif

        // ── T3: Qb yukle ──────────────────────────────────────────────────
        $display("\n [3/6] Qb yukleniyor (0x01 QB_YUKLE, 64 bayt)...");
        gonder_veri = {VEK_QB_Y, VEK_QB_X};
        komut_gonder(8'h01, 8'd64, gonder_veri);
        yanit_bekle(8'd0, 4000);
        kontrol(yanit_ok && cikti_durum === 8'h00,
                "T3: QB_YUKLE kabul edildi (ACK 0x00)");

        // ── T4: ECDH baslat ve bitmesini bekle ────────────────────────────
        $display("\n [4/6] ECDH baslatiliyor (0x02)...");
        komut_gonder(8'h02, 8'd0, 512'd0);
        yanit_bekle(8'd0, 2000);
        kontrol(yanit_ok && cikti_durum === 8'h00, "T4a: ECDH_BASLAT ACK");

        $display("       Hesaplama suruyor — bu uzun surer, sabirli olun.");
        bekle_cevrim = 0;
        rapor_sayac  = 0;
        // led[2] = Ortak Sir hazir ; led[3] = cekirdek hatasi
        while (led[2] !== 1'b1 && led[3] !== 1'b1 && bekle_cevrim < AZAMI_BEKLEME) begin
            @(posedge clk_100);
            bekle_cevrim = bekle_cevrim + 1;
            rapor_sayac  = rapor_sayac + 1;
            if (rapor_sayac == 1_000_000) begin
                rapor_sayac = 0;
                $display("       ... %0d M cevrim gecti (busy=%b qa=%b sir=%b hata=%b)",
                         bekle_cevrim/1000000, led[0], led[1], led[2], led[3]);
            end
        end

        kontrol(led[3] !== 1'b1, "T4b: Cekirdek hatasi olusmadi");
        if (hata_goruldu)
            $display("       (ilk hata: kod=%0d, durum=%0d — ayrinti yukarida)",
                     yak_err_kod, yak_state);
        kontrol(led[1] === 1'b1, "T4c: Qa hesaplandi (led[1])");
        kontrol(led[2] === 1'b1, "T4d: Ortak Sir hesaplandi (led[2])");
        $display("       Toplam hesaplama suresi: %0d cevrim (%0.2f ms @100MHz)",
                 bekle_cevrim, bekle_cevrim / 100000.0);

        // ── T5: Qa oku ve golden model ile karsilastir ────────────────────
        $display("\n [5/6] Qa okunuyor (0x03 QA_OKU)...");
        komut_gonder(8'h03, 8'd0, 512'd0);
        yanit_bekle(8'd64, 20000);
        kontrol(yanit_ok, "T5a: QA_OKU yaniti dogru cerceveli");
        kontrol(cikti_durum === 8'h00, "T5b: QA_OKU durum 0x00 (hata yok)");

        qa_x_alinan = cikti_veri[255:0];
        qa_y_alinan = cikti_veri[511:256];

        kontrol(qa_x_alinan === VEK_QA_X, "T5c: *** Qa.X golden model ile AYNI ***");
        if (qa_x_alinan !== VEK_QA_X) begin
            $display("       beklenen 0x%064h", VEK_QA_X);
            $display("       alinan   0x%064h", qa_x_alinan);
        end
        kontrol(qa_y_alinan === VEK_QA_Y, "T5d: *** Qa.Y golden model ile AYNI ***");
        if (qa_y_alinan !== VEK_QA_Y) begin
            $display("       beklenen 0x%064h", VEK_QA_Y);
            $display("       alinan   0x%064h", qa_y_alinan);
        end

        // ── T6: Ortak Sir oku ve karsilastir ──────────────────────────────
        $display("\n [6/6] Ortak Sir okunuyor (0x04 SIR_OKU)...");
        komut_gonder(8'h04, 8'd0, 512'd0);
        yanit_bekle(8'd64, 20000);
        kontrol(yanit_ok, "T6a: SIR_OKU yaniti dogru cerceveli");

        s_x_alinan = cikti_veri[255:0];
        s_y_alinan = cikti_veri[511:256];

        kontrol(s_x_alinan === VEK_S_X, "T6b: *** Ortak Sir.X golden model ile AYNI ***");
        if (s_x_alinan !== VEK_S_X) begin
            $display("       beklenen 0x%064h", VEK_S_X);
            $display("       alinan   0x%064h", s_x_alinan);
        end
        kontrol(s_y_alinan === VEK_S_Y, "T6c: *** Ortak Sir.Y golden model ile AYNI ***");
        if (s_y_alinan !== VEK_S_Y) begin
            $display("       beklenen 0x%064h", VEK_S_Y);
            $display("       alinan   0x%064h", s_y_alinan);
        end

        // ── Ozet ──────────────────────────────────────────────────────────
        $display("\n---------------------------------------------------------");
        if (hata_say == 0) begin
            $display(" TB-12 SONUC: TUM TESTLER GECTI");
            $display(" >>> UART zinciri gercek ECDH cekirdegiyle uctan uca");
            $display(" >>> calisiyor ve golden model ile BIT BIT ortusuyor.");
            $display(" >>> Karta yerlestirmeye hazir.");
        end else begin
            $display(" TB-12 SONUC: %0d TEST KALDI", hata_say);
        end
        $display("=========================================================");
        $finish;
    end

    // Kilitlenme korumasi — AZAMI_BEKLEME'nin uzerinde genis pay
    initial begin
        #(AZAMI_BEKLEME * SAAT_PERIYOT * 2);
        $display(" TB-12 HATA: genel zaman asimi (simulasyon takildi)");
        $display("   led = %b", led);
        $finish;
    end

endmodule
