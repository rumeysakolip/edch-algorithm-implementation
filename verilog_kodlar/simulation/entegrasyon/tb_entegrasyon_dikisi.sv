// =============================================================================
// Testbench : tb_entegrasyon_dikisi.sv                                (TB-25)
// Hedef     : ecdh_uart_top.v — SIMETRIK KATMAN ARAYUZU (İster INT-01)
// -----------------------------------------------------------------------------
// AMAÇ:
//   Arkadaşların HKDF / AES-GCM bloklarını bağlayacağı portların doğru
//   değeri, doğru zamanda ve DOĞRU ALANDA verdiğini kanıtlamak.
//
//   Bu TB kripto matematiğini yeniden sınamaz — o iş TB-12/20/22/23'te
//   yapıldı. Burada sınanan tek şey DİKİŞİN KENDİSİ.
//
// -----------------------------------------------------------------------------
// *** EN KRİTİK TEST: Z'NİN ALANI (A2) ***
//   Ortak sır çekirdek içinde MONTGOMERY alanında hesaplanır ve UART'a
//   (SIR_OKU) öyle basılır. Ancak NIST SP 800-56A Rev.3 §5.7.1.2, KDF'ye
//   verilecek Z'nin ortak noktanın x koordinatının DÜZ tam sayı gösterimi
//   olmasını şart koşar.
//
//   Bu dönüşüm atlanıp Montgomery değeri HKDF'ye verilseydi:
//     - iki taraf da aynı donanımı kullandığı için AYNI değeri üretirdi
//     - anahtarlar tutar, TLS el sıkışması başarılı olurdu
//     - bütün testler geçerdi
//   Hata ancak karşı taraf BAŞKA BİR UYGULAMA olduğunda ortaya çıkardı —
//   yani sahada, birlikte çalışabilirlik testinde. A2 tam olarak bunu
//   yakalamak için vardır ve beklenen değer bağımsız Python hesabından
//   gelir (Montgomery değerinin R^-1 ile çarpımı).
//
// -----------------------------------------------------------------------------
// KAPSANAN SENARYOLAR:
//   A) ECDH sonrası c_z_gecerli yükselir; c_z_duz DÜZ Z ile birebir
//   B) c_z_duz, UART'tan okunan Montgomery değerinden FARKLI olmalı
//      (dönüşümün gerçekten yapıldığının kanıtı — aynı çıkarsa dönüşüm yok)
//   C) Yeni ECDH başlayınca c_z_gecerli DÜŞER (bayat sır sızmaz)
//   D) IMZALA sonrası c_imza_r / c_imza_s doğru, c_imza_gecerli DARBE
//   E) DOGRULA sonrası c_dog_bitti darbesi + c_dog_gecerli hükmü doğru
//   F) Geçersiz imzada c_dog_bitti yine gelir, c_dog_gecerli DÜŞÜK
//
//   C özellikle önemlidir: ECDH yarıda kesilirse (hata, zeroize) eski Z
//   hâlâ geçerli görünseydi, KDF ÖNCEKİ oturumun sırrıyla anahtar türetirdi.
//
// SÜRE UYARISI: ECDH ~43 ms + imza ~44 ms + doğrulama ~23 ms ≈ 110 ms.
//
// KOSTURMA:  xelab -debug typical -d TEST_MODU tb_entegrasyon_dikisi -s tb25
//            xsim tb25 -R
//
// Standart : SystemVerilog-2012
// Tarih    : Temmuz 2026
// =============================================================================

`timescale 1ns / 1ps

module tb_entegrasyon_dikisi;

    localparam integer SAAT_HZ   = 100_000_000;
    localparam integer BAUD_HIZI = 6_250_000;
    localparam real    SAAT_PERIYOT = 10.0;
    localparam real    BIT_SURESI   = 160.0;

    integer hata_say = 0, gecen = 0;

    task kontrol(input kosul, input [1023:0] ad);
        begin
            if (kosul) begin $display("  [GECTI] %0s", ad); gecen = gecen + 1; end
            else begin $display("  [KALDI] %0s", ad); hata_say = hata_say + 1; end
        end
    endtask

    // ── TB-12 ile AYNI vektor (tek dogruluk kaynagi) ────────────────────
    localparam [255:0] VEK_D_A  =
        256'hc9afa9d845ba75176c3937d91da02c2a1b2c3d4e5f607182a5d90c3f72a5d7f1;
    localparam [255:0] VEK_QB_X =
        256'hb5e77bb791a2cc9b8871808177e017affebf67930386cecbcc687464212a4abf;
    localparam [255:0] VEK_QB_Y =
        256'he4b6e8718e80e9405377d6b26942db7e109f38753ce09f6c16d2ecf9e80ab59a;
    // Ortak sirrin MONTGOMERY hali (UART'tan boyle okunur)
    localparam [255:0] VEK_S_X_MONT =
        256'h95c047f3b0dc5cba104efb4a3dd529948bba744cd08421ca2c3eed373760f814;
    // *** KDF'ye gidecek DUZ Z  =  VEK_S_X_MONT * R^-1 mod p ***
    localparam [255:0] VEK_Z_DUZ =
        256'hf4b253e1b6a66d4d2a2cafc83499bae639da72aa6c2f2017ca2ef8fcbc7949bb;

    // ── ECDSA vektoru (TB-22/23 ile ayni) ───────────────────────────────
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

    reg         clk_100 = 1'b0;
    reg         btn_reset, btn_start, uart_rx_in;
    wire        uart_tx_out;
    wire [15:0] led;

    // ── DIKIS PORTLARI — test konusu ────────────────────────────────────
    //   26 Temmuz 2026: c_z_duz/c_imza_r/c_imza_s artik top-level'da HAM
    //   256-bit port degil (793 IOB'a yol aciyordu, hicbir FPGA paketi
    //   karsilayamaz — bkz. ecdh_uart_top.v'deki gerekce). Bunun yerine
    //   32-bit sozcuk arayuzunu (c_ent_sec/indis/sozcuk) DUT'tan okuyup
    //   asagida AYNI ESKI 256-bit isimlerle (tb_z_duz vb.) yeniden
    //   birlestiriyoruz — testin geri kalani DEGISMEDEN calisir.
    wire [1:0]   c_ent_sec;
    wire [2:0]   c_ent_indis;
    wire [31:0]  c_ent_sozcuk;
    wire         c_z_gecerli;
    wire         c_imza_gecerli;
    wire         c_dog_gecerli, c_dog_bitti;

    always #(SAAT_PERIYOT/2.0) clk_100 = ~clk_100;

    ecdh_uart_top #(.SAAT_HZ(SAAT_HZ), .BAUD_HIZI(BAUD_HIZI)) dut (
        .clk_100(clk_100), .btn_reset(btn_reset), .btn_start(btn_start),
        .uart_rx_in(uart_rx_in), .uart_tx_out(uart_tx_out), .led(led),
        .c_ent_sec(c_ent_sec), .c_ent_indis(c_ent_indis),
        .c_ent_sozcuk(c_ent_sozcuk), .c_z_gecerli(c_z_gecerli),
        .c_imza_gecerli(c_imza_gecerli),
        .c_dog_gecerli(c_dog_gecerli), .c_dog_bitti(c_dog_bitti)
    );

    // ── 32-bit sozcuk arayuzunu 256-bit'e geri birlestir (TB tarafi) ─────
    //   c_ent_* serbest sayacla surekli dolasir (0-7 z_duz, 8-15 imza_r,
    //   16-23 imza_s); her cevrim ilgili 32-bit dilimi kilitleriz. En kotu
    //   durumda 24 cevrim (240 ns @ 100 MHz) icinde tamamen guncellenir —
    //   testteki bekleme donguleri (20_000_000 cevrim) yaninda ihmal
    //   edilebilir. Eski test kodunun degismeden calismasi icin isimler
    //   c_z_duz / c_imza_r / c_imza_s olarak KORUNDU (artik reg, wire degil).
    reg [255:0] c_z_duz, c_imza_r, c_imza_s;
    always @(posedge clk_100) begin
        case (c_ent_sec)
            2'd0: c_z_duz [c_ent_indis*32 +: 32] <= c_ent_sozcuk;
            2'd1: c_imza_r[c_ent_indis*32 +: 32] <= c_ent_sozcuk;
            2'd2: c_imza_s[c_ent_indis*32 +: 32] <= c_ent_sozcuk;
            default: ; // 3 hic uretilmez (sayac 0..23 sinirli)
        endcase
    end

    // ── Darbe yakalayicilar ─────────────────────────────────────────────
    //   c_imza_gecerli ve c_dog_bitti BIR CEVRIMLIKTIR. Ana akis onlara
    //   baktiginda coktan gecmis olur; bu bloklar darbe anindaki degerleri
    //   kilitler. Tuketici taraf da AYNI SEYI yapmak zorundadir — bu, TB'nin
    //   ayni zamanda kullanim ornegi olmasini saglar.
    //   *** BAYRAK DEGIL SAYAC ***
    //   Ilk surumde bu bloklar bir bayrak (imza_darbe_r) kaldiriyor, ana akis
    //   da her senaryodan once onu 0'a cekiyordu. Bu, AYNI KAYITCIYI iki ayri
    //   surecten surmek demektir: always blogu non-blocking (<=), initial
    //   blogu blocking (=). Klasik bir YARIS; TB'nin sifirlamasi cekirdegin
    //   darbesini eziyor ve darbe hic gelmemis gibi gorunuyordu.
    //
    //   Belirti ogreticiydi: D1 (darbe geldi mi) KALDI ama D2/D3 (yakalanan
    //   r ve s dogru mu) GECTI. Yakalama YALNIZCA darbe aninda yapildigi icin
    //   D2/D3'un gecmesi darbenin GELDIGININ kanitiydi — yani hata RTL'de
    //   degil, olcum duzenegindeydi.
    //
    //   Cozum: sayac yalnizca ARTAR, TB hicbir zaman yazmaz. Ana akis islem
    //   oncesi degeri kopyalar ve sonrasinda artmis mi diye bakar.
    // [DUZELTME] c_imza_r/c_imza_s, DUT'un serbest sayacli 32-bit sozcuk
    // mux'iyla (ent_sayac_r, 0..23 dolasir) YAVAS YAVAS guncellenir — RTL'de
    // imza_s_r'nin SON word'u yazildigi ANDA (kex_pkt_out) c_imza_gecerli de
    // AYNI cevrimde yukselir, ama mux'in butun 24 sozcugu tazelemesi (en kotu
    // durumda) 24 cevrim daha surer. Darbe aninda c_imza_r/c_imza_s'i
    // DOGRUDAN yakalamak, mux'in henuz tazelemedigi (bayat/eski) sozcukleri
    // yakalayabilir — TIPKI dosyanin basinda anlatilan "BAYRAK DEGIL SAYAC"
    // yarisinin bir baskasi, bu kez mux seviyesinde. Cozum ayni desen:
    // darbeyi bir SAYACLA takip edip mux'a tam bir tur (24 cevrim) tanimak.
    integer     imza_darbe_say = 0;
    reg [255:0] yak_imza_r, yak_imza_s;
    reg         imza_mux_bekliyor_r = 1'b0;
    reg [5:0]   imza_mux_gecikme_r  = 6'd0;
    localparam [5:0] MUX_TUR = 6'd24;   // ent_sayac_r 0..23 -> tam tazeleme
    always @(posedge clk_100) begin
        if (c_imza_gecerli) begin
            imza_mux_bekliyor_r <= 1'b1;
            imza_mux_gecikme_r  <= 6'd0;
        end else if (imza_mux_bekliyor_r) begin
            if (imza_mux_gecikme_r == MUX_TUR - 6'd1) begin
                imza_mux_bekliyor_r <= 1'b0;
                imza_darbe_say      <= imza_darbe_say + 1;
                yak_imza_r          <= c_imza_r;
                yak_imza_s          <= c_imza_s;
            end else imza_mux_gecikme_r <= imza_mux_gecikme_r + 6'd1;
        end
    end

    integer dog_darbe_say = 0;
    reg     yak_dog_gecerli_r;
    always @(posedge clk_100) begin
        if (c_dog_bitti) begin
            dog_darbe_say     <= dog_darbe_say + 1;
            yak_dog_gecerli_r <= c_dog_gecerli;
        end
    end

    // ═════════════════════════════════════════════════════════════════════
    //  TESHIS IZI — imza paket olaylari
    // ---------------------------------------------------------------------
    //  D1 (darbe geldi mi) KALIYOR ama D2/D3 (yakalanan r,s dogru mu)
    //  GECIYOR. Yakalama darbe ile AYNI always blogunda oldugu icin bu ikisi
    //  ayrilamaz; yani varsayimlarimdan biri yanlis. Tahmin etmek yerine
    //  cekirdegin bastigi 16 paketi tek tek yazdiriyoruz: kac tanesi r, kac
    //  tanesi s, ve son s paketinde indis gercekten 7 mi.
    //
    //  Darbe kosulu:  kex_imza_sel && (imza_idx_w == 3'd7)
    //  Bu iz, kosulun neden saglanmadigini dogrudan gosterir.
    // ═════════════════════════════════════════════════════════════════════
    // ═════════════════════════════════════════════════════════════════════
    //  ARIZA MONITORU — hangi ALT MODUL, hangi DURUMDA hata verdi
    // ---------------------------------------------------------------------
    //  UART yalnizca 0xE5 "cekirdek arizasi" diyor; bu, ERR_CEKIRD kodunun
    //  karsiligidir ve ecdh_kex_top'taki TEK BIR toplu kontrolden gelir:
    //     sm_err | aff_err | nv_err | imz_err | dog_err | csc_err
    //  Hangisinin tetikledigini disaridan ayirt etmek IMKANSIZ. Bu monitor
    //  hatanin oldugu CEVRIMDE altilisini ayri ayri ve durum numarasiyla
    //  birlikte donduruyor.
    // ═════════════════════════════════════════════════════════════════════
    reg ariza_goruldu = 1'b0;
    always @(posedge clk_100) begin
        if (dut.rst_n && dut.kex_err && !ariza_goruldu) begin
            ariza_goruldu <= 1'b1;
            $display("\n  *** ARIZA MONITORU (t=%0t) ***", $time);
            $display("      err_kod = %0d  (1=NOKTA 2=TRNG 3=CEKIRDEK 4=WDOG 5=SLOT 6=IZIN)",
                     dut.kex_err_kod);
            $display("      kex.state_r = %0d", dut.kex.state_r);
            $display("      sm_err=%b aff_err=%b nv_err=%b imz_err=%b dog_err=%b csc_err=%b",
                     dut.kex.sm_err_w,  dut.kex.aff_err_w, dut.kex.nv_err_w,
                     dut.kex.imz_err_w, dut.kex.dog_err_w, dut.kex.csc_err_w);
            $display("      sahiplik: aff=%b nv=%b mnt=%b imz=%b dog=%b csc=%b kex=%b pau=%b",
                     dut.kex.owner_aff, dut.kex.owner_nv,  dut.kex.owner_mnt,
                     dut.kex.owner_imz, dut.kex.owner_dog, dut.kex.owner_csc,
                     dut.kex.owner_kex, dut.kex.owner_pau);
            $display("      mnt_rdy=%b mal_err=%b pau_err=%b\n",
                     dut.kex.mnt_rdy_w, dut.kex.mal_err_w, dut.kex.pau_err_w);
        end
    end

    integer olay_say = 0, r_olay = 0, s_olay = 0;
    always @(posedge clk_100) begin
        if (dut.kex_imza_hazir && dut.kex_pkt_vld) begin
            olay_say <= olay_say + 1;
            if (!dut.kex_imza_sel) r_olay <= r_olay + 1;
            else                   s_olay <= s_olay + 1;
            $display("  [IZ] olay=%0d sel=%b idx=%0d cnt=%0d gec=%b darbe=%b",
                     olay_say, dut.kex_imza_sel, dut.imza_idx_w,
                     dut.imza_cnt_r, dut.imza_sel_gec_r, c_imza_gecerli);
        end
    end

    // ═════════════════════════════════════════════════════════════════════
    //  UART ARACLARI  (TB-12 ile ayni)
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
                // *** SESSIZ BEKLEME YOK ***
                //   Onceki surumde bu dal hicbir sey yazdirmiyordu; yanit
                //   beklenenden KISA geldiginde TB, gelmeyecek baytlari
                //   bekleyip genel zaman asimina kadar suruyor ve elimizde
                //   hicbir bilgi kalmiyordu. Kisa yanit genellikle bir HATA
                //   yanitidir (4 bayt) — durum bayti nedeni soyler.
                $display("     -> YANIT UYUSMAZLIGI: %0d bayt geldi, %0d beklendi",
                         alinan_say, bek_uzunluk + 4);
                if (alinan_say >= 2)
                    $display("        durum bayti = 0x%02h  (0xED=IZIN 0xEC=SLOT 0xE5=CEKIRDEK 0xE2=BILINMEYEN 0xE3=UZUNLUK)",
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
    integer     bekle;
    integer     onceki_imza, onceki_dog;

    initial begin
        $display("=========================================================");
        $display(" TB-25 : ENTEGRASYON DIKISI (simetrik katman arayuzu)");
        $display("   c_z_duz / c_imza_* / c_dog_*");
        $display("   UYARI: toplam ~110 ms. UZUN SURER.");
        $display("=========================================================");

        // [DUZELTME] ecdh_uart_top varsayilani RESET_AKTIF_DUSUK=0 (Basys 3,
        // aktif-YUKSEK): btn_reset=1 -> reset, btn_reset=0 -> calisir. Eski
        // aktif-DUSUK (Nexys A7) kutupluguyle yazilmis surum DUT'u surekli
        // resette birakiyordu (bkz. tb_ecdsa_komut.sv duzeltmesi).
        btn_reset = 1'b1; btn_start = 1'b0; uart_rx_in = 1'b1;
        repeat (50) @(posedge clk_100);
        @(negedge clk_100); btn_reset = 1'b0;
        #(BIT_SURESI * 10);

        kontrol(c_z_gecerli === 1'b0, "A0: reset sonrasi c_z_gecerli dusuk");

`ifdef TEST_MODU
        gonder = {256'd0, VEK_D_A};
        komut_gonder(8'h10, 8'd32, gonder);
        yanit_bekle(8'd0, 2000);
`else
        $display("\n *** TEST_MODU TANIMSIZ — Z karsilastirmasi YAPILAMAZ ***");
        $display("     xelab'a -d TEST_MODU ekleyin.");
        kontrol(1'b0, "A0b: TEST_MODU gerekli");
`endif

        // ── A) ECDH -> Z ────────────────────────────────────────────────
        $display("\n [A] ECDH kosuyor, Z bekleniyor (~43 ms)...");
        gonder = {VEK_QB_Y, VEK_QB_X};
        komut_gonder(8'h01, 8'd64, gonder);
        yanit_bekle(8'd0, 4000);
        komut_gonder(8'h02, 8'd0, 512'd0);
        yanit_bekle(8'd0, 2000);

        bekle = 0;
        while (!c_z_gecerli && led[3] !== 1'b1 && bekle < 20_000_000) begin
            @(posedge clk_100); bekle = bekle + 1;
        end

        // [DUZELTME] c_z_gecerli yukseldigi ANDA c_z_duz'un TAMAMI mux'ta
        // TAZE degildir — z_duz_r degisir degismez gecerli bayragi ayni
        // cevrimde yukselir, ama 32-bit sozcuk mux'i (ent_sayac_r 0..23) yeni
        // degeri butun 8 diliminde yansitmak icin en kotu durumda 24 cevrim
        // daha ister. Ayni sinif hata (bkz. yukarida imza_mux_gecikme_r):
        // "gecerli/darbe = veri hazir" varsayimi mux'i saymiyor.
        repeat (24) @(posedge clk_100);

        kontrol(c_z_gecerli === 1'b1, "A1: c_z_gecerli yukseldi");
        kontrol(c_z_duz === VEK_Z_DUZ, "A2: *** Z DUZ ALANDA VE DOGRU ***");
        if (c_z_duz !== VEK_Z_DUZ) begin
            $display("       beklenen 0x%064h", VEK_Z_DUZ);
            $display("       alinan   0x%064h", c_z_duz);
        end
        $display("       sure: %0d cevrim", bekle);

        // ── B) Z, Montgomery degerinden FARKLI olmali ───────────────────
        //   Ayni cikarsa donusum HIC YAPILMAMIS demektir. Bu kontrol
        //   olmadan, K_SS_ZP durumu bos birakilsa bile A2 gecebilirdi
        //   (yanlislikla dogru sabit yazilmis olsaydi).
        kontrol(c_z_duz !== VEK_S_X_MONT,
                "B1: *** Z, Montgomery degerinden farkli (donusum yapildi) ***");

        // UART hala Montgomery basiyor mu? (demo yolu degismemeli)
        komut_gonder(8'h04, 8'd0, 512'd0);
        yanit_bekle(8'd64, 20000);
        kontrol(yanit_ok && cikti_veri[255:0] === VEK_S_X_MONT,
                "B2: SIR_OKU hala Montgomery basiyor (demo yolu bozulmadi)");

        // ── C) Yeni ECDH -> c_z_gecerli DUSMELI ─────────────────────────
        //   Bayat sir sizmasi: ECDH yarida kesilirse eski Z gecerli
        //   gorunseydi, KDF ONCEKI oturumun sirriyla anahtar turetirdi.
        $display("\n [C] Yeni ECDH baslatiliyor, c_z_gecerli dusmeli...");
        komut_gonder(8'h02, 8'd0, 512'd0);
        yanit_bekle(8'd0, 2000);
        repeat (200) @(posedge clk_100);
        kontrol(c_z_gecerli === 1'b0,
                "C1: *** yeni oturumda c_z_gecerli dustu (bayat sir yok) ***");

        // Bu ECDH'nin bitmesini bekle ki sonraki komutlar islenebilsin
        bekle = 0;
        while (!c_z_gecerli && led[3] !== 1'b1 && bekle < 20_000_000) begin
            @(posedge clk_100); bekle = bekle + 1;
        end
        // [DUZELTME] A2 ile ayni gerekce — mux'a tam tur tanı.
        repeat (24) @(posedge clk_100);
        kontrol(c_z_gecerli === 1'b1, "C2: ikinci ECDH de tamamlandi");
        kontrol(c_z_duz === VEK_Z_DUZ, "C3: ikinci Z de dogru (tekrarlanabilir)");

        // ── D) IMZALA -> c_imza_* ───────────────────────────────────────
        $display("\n [D] IMZALA (~44 ms), imza dikisi bekleniyor...");
        gonder = {504'd0, 8'h02, 8'd0};       // slot 0, politika = IMZA
        komut_gonder(8'h0A, 8'd4, gonder);
        yanit_bekle(8'd0, 400000);

        // ANAHTAR_URET ACK'i HEMEN doner; uretim ~21 ms daha surer.
        // RTL artik S_IMZ_HAZ ile bunu kendisi bekliyor, ama TB'nin de
        // beklemesi olculen imza suresini temizler.
        bekle = 0;
        while (led[0] === 1'b1 && bekle < 5_000_000) begin
            @(posedge clk_100); bekle = bekle + 1;
        end
        $display("       anahtar uretimi bitti (%0d cevrim), imzalaniyor...", bekle);

        onceki_imza = imza_darbe_say;
        gonder = {VEK_E, 32'd0};
        komut_gonder(8'h0C, 8'd36, gonder);
        yanit_bekle(8'd64, 1100000);   // ~176 ms, olculen ~65 ms'e bol pay

        kontrol(imza_darbe_say > onceki_imza, "D1: c_imza_gecerli darbesi geldi");
        $display("       [TESHIS] toplam paket olayi=%0d  (r=%0d, s=%0d)",
                 olay_say, r_olay, s_olay);
        $display("       [TESHIS] darbe sayaci: once=%0d simdi=%0d",
                 onceki_imza, imza_darbe_say);
        $display("       [TESHIS] imza_cnt_r=%0d imza_sel_gec_r=%b",
                 dut.imza_cnt_r, dut.imza_sel_gec_r);
        // *** X === X TUZAGI ***
        //   Onceki surumde D2/D3 sadece "===" ile karsilastiriyordu. Cekirdek
        //   imzayi hic uretmediginde yak_imza_r atanmamis (X) kaliyor,
        //   imza_tampon_r de bos oldugu icin UART'a 64 bayt X basiliyor ve
        //   cikti_veri de X oluyordu. Verilog'da X === X DOGRUDUR — yani iki
        //   bilinmeyen birbirine esit sayilip test SAHTE GECIYORDU.
        //
        //   Bunu D1 yakaladi ama D2/D3 onu ortmeye calisti. Ders: bir "esit
        //   mi" kontrolu, degerlerin TANIMLI oldugunu ayrica sinamiyorsa
        //   hicbir sey kanitlamaz.
        // NOT: "X degil" tek basina zayif bir kontroldur — yanit hic gelmezse
        // cikti_veri SIFIRDIR ve bu kontrol GECER. Sifir da gecerli bir imza
        // degildir, o yuzden ayrica sifir olmadigi da sininiyor.
        kontrol((^cikti_veri[511:0] !== 1'bx) && (cikti_veri[511:0] !== 512'd0),
                "D2a: UART'tan gelen imza TANIMLI ve sifir disi");
        kontrol((^yak_imza_r !== 1'bx) && (^yak_imza_s !== 1'bx),
                "D2b: dikisten gelen imza TANIMLI (X degil)");
        kontrol(yak_imza_r === cikti_veri[255:0],
                "D2: dikisteki r, UART'tan okunan r ile AYNI");
        kontrol(yak_imza_s === cikti_veri[511:256],
                "D3: dikisteki s, UART'tan okunan s ile AYNI");
        if (yak_imza_r !== cikti_veri[255:0]) begin
            $display("       dikis r 0x%064h", yak_imza_r);
            $display("       uart  r 0x%064h", cikti_veri[255:0]);
        end

        // ── E) DOGRULA (gecerli imza) -> c_dog_* ────────────────────────
        $display("\n [E] DOGRULA — gecerli imza (~23 ms)...");
        gonder = {VEK_QY, VEK_QX};
        komut_gonder(8'h01, 8'd64, gonder);
        yanit_bekle(8'd0, 20000);
        gonder = {VEK_S, VEK_R};
        komut_gonder(8'h0D, 8'd64, gonder);
        yanit_bekle(8'd0, 20000);

        onceki_dog = dog_darbe_say;
        gonder = {256'd0, VEK_E};
        komut_gonder(8'h0E, 8'd32, gonder);
        yanit_bekle(8'd0, 4000000);

        kontrol(dog_darbe_say > onceki_dog, "E1: c_dog_bitti darbesi geldi");
        kontrol(yak_dog_gecerli_r === 1'b1,
                "E2: *** c_dog_gecerli = 1 (imza gecerli) ***");
        kontrol(cikti_durum === 8'h00, "E3: UART hukmu de 0x00 (tutarli)");

        // ── F) DOGRULA (bozuk imza) ─────────────────────────────────────
        //   Darbe YINE gelmeli — "hukum verildi" ile "hukum olumlu" ayri
        //   seylerdir. Tuketici taraf bitti darbesini beklemeli, sonra
        //   gecerli bitine bakmalidir.
        $display("\n [F] DOGRULA — bozuk s (~23 ms)...");
        gonder = {VEK_S ^ 256'd1, VEK_R};
        komut_gonder(8'h0D, 8'd64, gonder);
        yanit_bekle(8'd0, 20000);

        // yak_dog_gecerli_r'ye TB YAZMAZ (yaris olurdu). Onceki senaryoda
        // 1 kalmis durumda; bu senaryoda 0'a DUSMESI gerekiyor — yani
        // "tersine kurma" hilesine zaten gerek yok, testi guclendiriyor.
        onceki_dog = dog_darbe_say;
        gonder = {256'd0, VEK_E};
        komut_gonder(8'h0E, 8'd32, gonder);
        yanit_bekle(8'd0, 4000000);

        kontrol(dog_darbe_say > onceki_dog, "F1: bozuk imzada da c_dog_bitti geldi");
        kontrol(yak_dog_gecerli_r === 1'b0,
                "F2: *** c_dog_gecerli = 0 (imza reddedildi) ***");
        kontrol(cikti_durum === 8'hEE, "F3: UART hukmu 0xEE (tutarli)");

        // ── Ozet ────────────────────────────────────────────────────────
        $display("\n---------------------------------------------------------");
        if (hata_say == 0) begin
            $display(" TB-25 SONUC: TUM TESTLER GECTI (%0d dogrulama)", gecen);
            $display(" >>> Dikis hazir. Arkadaslar HKDF'yi c_z_duz'e,");
            $display(" >>> AEAD'i turetilen anahtarlara baglayabilir.");
            $display(" >>> Z, SP 800-56A'ya uygun DUZ alanda veriliyor.");
        end else begin
            $display(" TB-25 SONUC: %0d TEST KALDI (%0d gecti)", hata_say, gecen);
        end
        $display("=========================================================");
        $finish;
    end

    initial begin
        #(800_000_000);
        $display("\n *** TB-25 GENEL ZAMAN ASIMI ***");
        $display("     kex.state_r = %0d", dut.kex.state_r);
        $display("     yonetici.durum_r = %0d", dut.yonetici.durum_r);
        $finish;
    end

endmodule
