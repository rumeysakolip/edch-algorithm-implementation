// =============================================================================
// Testbench : tb_negatif_akis.sv                                      (TB-27)
// Hedef     : ecdh_uart_top.v — bu oturumda duzeltilen 5 hatanin REGRESYONU
// -----------------------------------------------------------------------------
// AMAC:
//   00_BAGLAM bolum 5'te listelenen 5 duzeltmenin HICBIRINI koruyan test
//   yoktu. Hepsi "mutlu yol" testlerinden geciyordu. Bu TB o bosluğu kapatir;
//   N1..N6 her biri GERCEK bir hatayi (RTL kaynagindan dogrulanmis satir
//   numaralariyla) hedef alir. Bu TB kripto matematigini SINAMAZ (o is
//   TB-12/20/22/23'te yapildi) — yalniz PROTOKOL/FSM davranisini sinar.
//
// -----------------------------------------------------------------------------
// KAPSANAN SENARYOLAR VE HANGI HATAYI YAKALADIKLARI:
//
//   N1 IZIN REDDI (en kritik)
//     komut_yoneticisi.v:477-481 — KOM_ANAHTAR_URET, nesne_rx_r yazma
//     dalinda YOKTU -> slot/politika baytı X okunuyor, ERR_IZIN yerine
//     baska bir hata / sessiz basari cikiyordu. ANAHTAR_URET(pol=IZIN_ECDH
//     yalniz) + IMZALA -> ecdh_kex_top.v:933-935 K_IM_D_OKU'da ERR_IZIN
//     (kod=6) beklenir; UART'ta YAN_IZIN=0xED.
//
//   N2 DURUM BAYTI ESLEMESI
//     komut_yoneticisi.v:416,428 — hata_yanit_w bir cevrim GERIYDI; anlik
//     hatada eski hata_kod_r okunuyordu (orn. IZIN yerine CEKIRDEK 0xE5
//     basiliyordu). N1'in 0xED hukmu bunu zaten kapsar; ayrica bos slotla
//     IMZALA -> YAN_SLOT=0xEC sinanir.
//
//   N3 HAYALET HATA YOK
//     komut_yoneticisi.v:589-607 — hata_r YALNIZCA kex_start_r (ECDH) ile
//     temizleniyordu; ANAHTAR_URET/IMZALA/DOGRULA temizlemiyordu. N1'in
//     hatasindan SONRA basarili bir ANAHTAR_URET+IMZALA'nin YAN_OK (0x00)
//     donmesi gerekir.
//
//   N4 Qa KORUNUMU
//     ecdh_kex_top.v:866 — K_QA_DONE'da kd_acik_yaz_r <= !imza_modu_r
//     duzeltmesi ONCESINDE, nonce'un acik noktasi (k.G) imza anahtarinin
//     slotunu SESSIZCE eziyordu. IMZALA'dan ONCE ve SONRA QA_OKU ayni
//     Qa'yi vermelidir.
//
//   N5 IMZA TAMPONU TEK KAYNAK
//     komut_yoneticisi.v:757-768 — imza_tampon_r iki ayri always blogundan
//     yaziliyordu -> [Synth 8-2913] sentez hatasi. Duzeltmeden sonra TEK
//     yazar var (UART / cekirdek birlesimsel mux). DOGRULA'nin S_DOG_RS
//     durumu (satir 1292-1298) HER ZAMAN imza_tampon_r'den okur; bu test
//     IMZA_YUKLE'nin cekirdegin urettigi degeri EZDIGINI kanitlar.
//
//   N6 UZUNLUK / BILINMEYEN KOMUT
//     komut_yoneticisi.v:881-888 — regresyon guvenligi icin kontrol
//     (bu oturumda degismedi, ama N1-N5 ile ayni cerceve altyapisini
//     kullandigi icin ucretsiz kapsam saglar).
//
// SURE UYARISI: N1(~42ms) + N3(~44ms) + N4(~44ms) + N5(~44ms) + N6(~0)
//   toplam ~175 ms. UZUN SURER — genel zaman asimi buna gore genis tutuldu.
//
// KOSTURMA:  xelab -debug typical tb_negatif_akis -s tb27
//            xsim tb27 -R
//   (TEST_MODU GEREKMEZ — bu TB deterministik d/k vektoru kullanmiyor,
//   yalniz PROTOKOL davranisini sinadigi icin rastgele TRNG anahtarlarla
//   calisir.)
//
// Standart : SystemVerilog-2012
// Tarih    : Temmuz 2026
// =============================================================================

`timescale 1ns / 1ps

module tb_negatif_akis;

    localparam integer SAAT_HZ   = 100_000_000;
    localparam integer BAUD_HIZI = 6_250_000;      // TB-25 ile ayni: sim hizi
    localparam real    SAAT_PERIYOT = 10.0;
    localparam real    BIT_SURESI   = 160.0;

    integer hata_say = 0, gecen = 0;

    task kontrol(input kosul, input [1023:0] ad);
        begin
            if (kosul) begin $display("  [GECTI] %0s", ad); gecen = gecen + 1; end
            else begin $display("  [KALDI] %0s", ad); hata_say = hata_say + 1; end
        end
    endtask

    // ── ECDSA imzalama icin sabit ozet (e) — matematiksel gecerlilik bu
    //    TB'nin konusu degil, yalniz sabit bir 256 bitlik deger gerekir ──
    localparam [255:0] VEK_E =
        256'h7c1e5a93d84f0b26e37a915cf0d2864b591e7038ac4d62f1085b39e7c26d4f5a;

    reg         clk_100 = 1'b0;
    reg         btn_reset, btn_start, uart_rx_in;
    wire        uart_tx_out;
    wire [15:0] led;

    // 26 Temmuz 2026: c_imza_r/c_imza_s artik HAM 256-bit port degil (bkz.
    // tb_entegrasyon_dikisi.sv / ecdh_uart_top.v gerekcesi — 793 IOB sorunu).
    // Bu TB'de deger okunmuyordu (yalnizca c_imza_gecerli darbesi sayiliyor),
    // yine de arayuzu tam baglamak icin sozcuk portlarini birlestiriyoruz.
    wire [1:0]   c_ent_sec;
    wire [2:0]   c_ent_indis;
    wire [31:0]  c_ent_sozcuk;
    wire [255:0] c_imza_r, c_imza_s;
    wire         c_imza_gecerli;
    wire         c_dog_gecerli, c_dog_bitti;

    always #(SAAT_PERIYOT/2.0) clk_100 = ~clk_100;

    ecdh_uart_top #(.SAAT_HZ(SAAT_HZ), .BAUD_HIZI(BAUD_HIZI)) dut (
        .clk_100(clk_100), .btn_reset(btn_reset), .btn_start(btn_start),
        .uart_rx_in(uart_rx_in), .uart_tx_out(uart_tx_out), .led(led),
        .c_ent_sec(c_ent_sec), .c_ent_indis(c_ent_indis),
        .c_ent_sozcuk(c_ent_sozcuk),
        .c_imza_gecerli(c_imza_gecerli),
        .c_dog_gecerli(c_dog_gecerli), .c_dog_bitti(c_dog_bitti)
    );

    reg [255:0] c_imza_r_yaz, c_imza_s_yaz;
    assign c_imza_r = c_imza_r_yaz;
    assign c_imza_s = c_imza_s_yaz;
    always @(posedge clk_100) begin
        case (c_ent_sec)
            2'd1: c_imza_r_yaz[c_ent_indis*32 +: 32] <= c_ent_sozcuk;
            2'd2: c_imza_s_yaz[c_ent_indis*32 +: 32] <= c_ent_sozcuk;
            default: ;
        endcase
    end

    // ── Darbe sayaci — c_imza_gecerli BIR CEVRIMLIKTIR. TB-25'te ogrenilen
    //    kural: BAYRAK DEGIL SAYAC, ve TB bu kayitciya ASLA yazmaz (yaris
    //    onlenir; bkz. tb_entegrasyon_dikisi.sv basligi). ──────────────────
    integer imza_darbe_say = 0;
    always @(posedge clk_100) begin
        if (c_imza_gecerli) imza_darbe_say <= imza_darbe_say + 1;
    end

    // ═════════════════════════════════════════════════════════════════════
    //  ARIZA MONITORU — hangi err_kod, hangi durumda geldi (teshis)
    // ═════════════════════════════════════════════════════════════════════
    reg [2:0] son_err_kod_r;
    always @(posedge clk_100) begin
        if (dut.rst_n && dut.kex_err) begin
            son_err_kod_r <= dut.kex_err_kod;
        end
    end

    // ═════════════════════════════════════════════════════════════════════
    //  UART ARACLARI — tb_entegrasyon_dikisi.sv (TB-25) ile AYNEN
    // ═════════════════════════════════════════════════════════════════════
    reg [7:0] alinan [0:127];
    integer   alinan_say = 0;

    initial begin : seri_dinleyici
        reg [7:0] b; integer k;
        forever begin
            @(negedge uart_tx_out); #(BIT_SURESI * 1.5);
            for (k = 0; k < 8; k = k + 1) begin
                b[k] = uart_tx_out; if (k < 7) #(BIT_SURESI);
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
            for (k = 0; k < 8; k = k + 1) begin uart_rx_in = b[k]; #(BIT_SURESI); end
            uart_rx_in = 1'b1; #(BIT_SURESI); #(BIT_SURESI/2);
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

    reg [511:0] cikti_veri; reg [7:0] cikti_durum; reg yanit_ok;
    task yanit_bekle(input [7:0] bek_uzunluk, input integer azami_bit);
        integer bek, k; reg [7:0] crc_bek;
        begin
            yanit_ok = 1'b1; cikti_veri = 512'd0; cikti_durum = 8'hFF; bek = 0;
            while (alinan_say < (bek_uzunluk + 4) && bek < azami_bit) begin
                #(BIT_SURESI); bek = bek + 1;
            end
            if (alinan_say != (bek_uzunluk + 4)) begin
                yanit_ok = 1'b0;
                // Sessiz bekleme yok (TB-25'ten ogrenilen kural) — kisa
                // yanit genellikle 4 baytlik bir HATA cercevesidir, durum
                // baytini burada goruruz.
                $display("     -> YANIT UYUSMAZLIGI: %0d bayt geldi, %0d beklendi",
                         alinan_say, bek_uzunluk + 4);
                if (alinan_say >= 2)
                    $display("        durum bayti = 0x%02h  (0xED=IZIN 0xEC=SLOT 0xE5=CEKIRDEK 0xE2=BILINMEYEN 0xE3=UZUNLUK 0xEE=IMZA_GECERSIZ 0xEF=IMZA_ARALIK)",
                             alinan[1]);
                if (alinan_say >= 3)
                    $display("        uzunluk alani = %0d", alinan[2]);
            end
            else begin
                if (alinan[0] !== 8'h5A) yanit_ok = 1'b0;
                cikti_durum = alinan[1];
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
    integer     onceki_imza;
    reg [511:0] qa1, qa2;

    initial begin
        $display("=========================================================");
        $display(" TB-27 : NEGATIF AKIS (bu oturumda duzeltilen 5 hatanin");
        $display("         regresyonu — N1..N6)");
        $display("   UYARI: toplam ~175 ms. UZUN SURER.");
        $display("=========================================================");

        // [DUZELTME] ecdh_uart_top varsayilani RESET_AKTIF_DUSUK=0 (Basys 3,
        // aktif-YUKSEK): btn_reset=1 -> reset, btn_reset=0 -> calisir. Eski
        // aktif-DUSUK (Nexys A7) kutupluguyle yazilmis surum DUT'u surekli
        // resette birakiyordu (bkz. tb_ecdsa_komut.sv duzeltmesi).
        btn_reset = 1'b1; btn_start = 1'b0; uart_rx_in = 1'b1;
        repeat (50) @(posedge clk_100);
        @(negedge clk_100); btn_reset = 1'b0;
        #(BIT_SURESI * 10);

        // ── N1: IZIN REDDI ───────────────────────────────────────────────
        //   ANAHTAR_URET(slot=0, politika=0x01=yalniz IZIN_ECDH) -> ~21 ms
        //   IMZALA(slot=0, e) -> nonce k.G hesaplanir (~21 ms), SONRA
        //   K_IM_D_OKU izin kontrolunde REDDEDILIR (kd_izin_var_w=0).
        //   Toplam ~42 ms bosa harcanir ve durum 0xED donmelidir.
        $display("\n [N1] IZIN REDDI: ANAHTAR_URET(pol=ECDH) + IMZALA...");
        gonder = {504'd0, 8'h01, 8'd0};        // slot 0, politika = 0x01
        komut_gonder(8'h0A, 8'd4, gonder);
        yanit_bekle(8'd0, 400000);
        kontrol(yanit_ok && cikti_durum === 8'h00, "N1a: ANAHTAR_URET ACK'i 0x00");

        onceki_imza = imza_darbe_say;
        gonder = {VEK_E, 32'd0};
        komut_gonder(8'h0C, 8'd36, gonder);
        yanit_bekle(8'd0, 1100000);

        kontrol(yanit_ok, "N1b: yanit cercevesi CRC/uzunluk tutarli");
        kontrol(cikti_durum === 8'hED,
                "N1c: *** durum = 0xED (IZIN) — 0xE5 (CEKIRDEK) DEGIL ***");
        if (cikti_durum !== 8'hED)
            $display("        alinan durum = 0x%02h", cikti_durum);
        kontrol(dut.kex.o_err_kod_r === 3'd6,
                "N1d: kex.o_err_kod_r = 6 (ERR_IZIN)");
        kontrol(imza_darbe_say === onceki_imza,
                "N1e: c_imza_gecerli darbesi GELMEDI (cekirdek imza uretmedi)");

        // ── N2: DURUM BAYTI ESLEMESI (ikinci vaka — bos slot) ────────────
        //   N1'in 0xED hukmu birinci vakayi zaten kapsar. Burada bos bir
        //   slotla (hic uretilmemis slot 1) IMZALA denenir -> YAN_SLOT.
        $display("\n [N2] DURUM BAYTI: bos slotla IMZALA -> 0xEC bekleniyor...");
        gonder = {504'd0, 8'h01, 8'd1};        // NOT: baslik[1:0]=slot -> 1
        komut_gonder(8'h0C, 8'd36, gonder);
        yanit_bekle(8'd0, 1100000);
        kontrol(yanit_ok, "N2a: yanit cercevesi tutarli");
        kontrol(cikti_durum === 8'hEC || cikti_durum === 8'hED,
                "N2b: durum = 0xEC (SLOT) veya 0xED (IZIN) — 0xE5 DEGIL");
        if (cikti_durum === 8'hE5)
            $display("        *** hata_yanit_w bir cevrim geride kalmis olabilir (fix #2 geri alinmis) ***");

        // ── N3: HAYALET HATA YOK ──────────────────────────────────────────
        //   N1'in hatasindan SONRA slot 0'i DOGRU politikayla (IZIN_IMZA)
        //   yeniden uretip imzalarsak, bu sefer 0x00 donmelidir. hata_r
        //   yalniz kex_start_r (ECDH) ile degil, kex_uret_r/kex_imzala_r
        //   ile de temizlenmelidir (fix #3).
        $display("\n [N3] HAYALET HATA: ayni slotu dogru politikayla yeniden uret...");
        gonder = {504'd0, 8'h02, 8'd0};        // slot 0, politika = 0x02 (IMZA)
        komut_gonder(8'h0A, 8'd4, gonder);
        yanit_bekle(8'd0, 400000);
        kontrol(yanit_ok && cikti_durum === 8'h00, "N3a: ANAHTAR_URET ACK'i 0x00");

        onceki_imza = imza_darbe_say;
        gonder = {VEK_E, 32'd0};
        komut_gonder(8'h0C, 8'd36, gonder);
        yanit_bekle(8'd64, 1100000);

        kontrol(yanit_ok, "N3b: yanit cercevesi tutarli");
        kontrol(cikti_durum === 8'h00,
                "N3c: *** ikinci IMZALA 0x00 donuyor (hayalet hata YOK) ***");
        if (cikti_durum !== 8'h00)
            $display("        alinan durum = 0x%02h (0xED/0xE5 ise hata_r temizlenmiyor)", cikti_durum);
        kontrol(imza_darbe_say > onceki_imza, "N3d: c_imza_gecerli darbesi geldi");
        kontrol((^cikti_veri[511:0] !== 1'bx) && (cikti_veri[511:0] !== 512'd0),
                "N3e: donen imza TANIMLI ve sifir disi (X===X tuzagina karsi)");

        // ── N4: Qa KORUNUMU ───────────────────────────────────────────────
        //   IMZALA'dan ONCE ve SONRA QA_OKU ayni Qa'yi vermelidir. N3'te
        //   zaten bir IMZALA yapildi; simdi Qa1'i okuyup ikinci bir IMZALA
        //   sonrasi Qa2 ile karsilastiriyoruz.
        $display("\n [N4] Qa KORUNUMU: IMZALA once/sonra Qa karsilastirmasi...");
        komut_gonder(8'h03, 8'd0, 512'd0);     // QA_OKU
        yanit_bekle(8'd64, 20000);
        kontrol(yanit_ok && cikti_durum === 8'h00, "N4a: QA_OKU (once) 0x00");
        qa1 = cikti_veri;
        kontrol(qa1 !== 512'd0, "N4b: Qa1 sifir DEGIL (bir onceki uretimden gelen gercek nokta)");

        gonder = {VEK_E, 32'd0};
        komut_gonder(8'h0C, 8'd36, gonder);
        yanit_bekle(8'd64, 1100000);
        kontrol(yanit_ok && cikti_durum === 8'h00, "N4c: ikinci IMZALA da basarili");

        komut_gonder(8'h03, 8'd0, 512'd0);     // QA_OKU
        yanit_bekle(8'd64, 20000);
        kontrol(yanit_ok && cikti_durum === 8'h00, "N4d: QA_OKU (sonra) 0x00");
        qa2 = cikti_veri;

        kontrol(qa1 === qa2,
                "N4e: *** Qa1 === Qa2 (nonce'un acik noktasi imza slotunu EZMEDI) ***");
        if (qa1 !== qa2) begin
            $display("        Qa1 = 0x%0128h", qa1);
            $display("        Qa2 = 0x%0128h", qa2);
        end

        // ── N5: IMZA TAMPONU TEK KAYNAK ──────────────────────────────────
        //   N4'te taze bir (r,s) uretildi (imza_tampon_r'de duruyor).
        //   IMZA_YUKLE ile ARALIK-DISI bir (r'=0, s'=1) yuklersek, DOGRULA
        //   S_DOG_RS'de HANGI kaynagi okudugunu ELE VERIR:
        //     - imza_tampon_r TEK yazardan besleniyorsa (duzeltilmis hal)
        //       DOGRULA r=0 gorur -> ARALIK DISI -> 0xEF
        //     - iki kaynaktan biri sessizce kazanirsa (cift-yazar / eski
        //       hal) r != 0 olan GERCEK imza kullanilir -> 0xEF GELMEZ
        $display("\n [N5] IMZA TAMPONU: IMZA_YUKLE(r=0,s=1) sonrasi DOGRULA...");
        gonder = 512'd0; gonder[255:0] = 256'd0; gonder[511:256] = 256'd1;
        komut_gonder(8'h0D, 8'd64, gonder);    // IMZA_YUKLE: r=0, s=1
        yanit_bekle(8'd0, 20000);
        kontrol(yanit_ok && cikti_durum === 8'h00, "N5a: IMZA_YUKLE ACK 0x00");

        gonder = {256'd0, VEK_E};
        komut_gonder(8'h0E, 8'd32, gonder);    // DOGRULA(e)
        yanit_bekle(8'd0, 4000000);

        kontrol(yanit_ok, "N5b: yanit cercevesi tutarli");
        kontrol(cikti_durum === 8'hEF,
                "N5c: *** durum = 0xEF (IMZA ARALIK) — IMZA_YUKLE degeri KULLANILDI ***");
        if (cikti_durum !== 8'hEF)
            $display("        alinan durum = 0x%02h (0xEF DEGILSE cekirdegin urettigi (r,s) hala kullaniliyor -> imza_tampon_r cift yazardan besleniyor olabilir)", cikti_durum);

        // ── N6: UZUNLUK / BILINMEYEN KOMUT ───────────────────────────────
        $display("\n [N6] UZUNLUK / BILINMEYEN KOMUT...");
        gonder = 512'd0;
        komut_gonder(8'h0C, 8'd32, gonder);    // IMZALA ama uzunluk=32 (36 olmali)
        yanit_bekle(8'd0, 20000);
        kontrol(yanit_ok && cikti_durum === 8'hE3, "N6a: yanlis uzunluk -> 0xE3 (UZUNLUK)");

        komut_gonder(8'h7F, 8'd0, 512'd0);     // bilinmeyen komut
        yanit_bekle(8'd0, 20000);
        kontrol(yanit_ok && cikti_durum === 8'hE2, "N6b: bilinmeyen komut -> 0xE2 (BILINMEYEN)");

        // ── Ozet ────────────────────────────────────────────────────────
        $display("\n---------------------------------------------------------");
        if (hata_say == 0) begin
            $display(" TB-27 SONUC: TUM TESTLER GECTI (%0d dogrulama)", gecen);
            $display(" >>> 5 hatanin hicbiri geri gelmemis.");
        end else begin
            $display(" TB-27 SONUC: %0d TEST KALDI (%0d gecti)", hata_say, gecen);
        end
        $display("=========================================================");
        $finish;
    end

    initial begin
        #(1_500_000_000);
        $display("\n *** TB-27 GENEL ZAMAN ASIMI ***");
        $display("     kex.state_r = %0d", dut.kex.state_r);
        $display("     yonetici.durum_r = %0d", dut.yonetici.durum_r);
        $display("     son gorulen err_kod = %0d", son_err_kod_r);
        $finish;
    end

endmodule
