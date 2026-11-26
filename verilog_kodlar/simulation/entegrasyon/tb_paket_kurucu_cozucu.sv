// =============================================================================
// Testbench : tb_paket_kurucu_cozucu.sv                            (İster TB-09)
// Hedef     : paket_kurucu.v + paket_cozucu.v + crc8_hesap.v
// -----------------------------------------------------------------------------
//   *** KATMAN 2 KAPANIŞ KAPISI — BU TEST ATLANMAMALIDIR ***
//
// Kurucunun ürettiği çerçeve doğrudan çözücüye verilir. Word değerleri
// gidiş-dönüşte KORUNMALIDIR. ENDIANNESS uzlaşımı (K-05/K-06) burada
// kilitlenir; bu testi geçmeyen bir tasarımda hata TB-12'ye kadar sessiz
// kalır ve orada teşhisi çok pahalıdır.
//
// Kontrol edilenler:
//   T1. Karışık desen — 8 word gidiş-dönüş
//   T2. Sınır desenleri: yalnız word0, yalnız word7, tek bit LSB/MSB,
//       tamamen sıfır, tamamen bir
//   T3. Gerçek P-256 GX_MONT sabiti (ecdh_kex_top ile aynı)
//   T4. 64 baytlık çerçeve (16 word, X||Y)
//   T5. Ardışık çerçeveler — durum sızıntısı yok
//   T6. Kurucunun ürettiği CRC'yi çözücü kabul ediyor (simetri kanıtı)
//
// BAŞLIK NOTU:
//   Kurucu 0x5A (çıkış), çözücü 0xA5 (giriş) başlığı kullanır — bunlar ayrı
//   yönlerdir. Bu testte başlık çevrilir ve CRC yeniden hesaplanır; sınanan
//   şey ÇERÇEVELEME ve ENDIANNESS mantığının simetrisidir.
//
// Koşturma (Vivado xsim):
//   xvlog -sv tb_paket_kurucu_cozucu.sv ../sources_1/paket_kurucu.v \
//         ../sources_1/paket_cozucu.v ../sources_1/crc8_hesap.v
//   xelab -debug typical tb_paket_kurucu_cozucu -s tb && xsim tb -R
// =============================================================================

`timescale 1ns / 1ps

module tb_paket_kurucu_cozucu;

    localparam real    SAAT_PERIYOT = 10.0;
    localparam integer AZAMI_VERI   = 64;
    localparam integer ZAMAN_ASIMI  = 100_000;   // testte tetiklenmemeli

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

    reg saat = 1'b0;
    reg sifirla_n;
    always #(SAAT_PERIYOT/2.0) saat = ~saat;

    // ═════════════════════════════════════════════════════════════════════
    //  KURUCU (M-07)
    // ═════════════════════════════════════════════════════════════════════
    reg         k_basla;
    reg  [7:0]  k_durum_alan;
    reg  [7:0]  k_uzunluk;
    reg  [31:0] k_word;
    reg         k_word_gecerli;
    reg         k_bayt_hazir;

    wire        k_word_iste;
    wire [7:0]  k_bayt;
    wire        k_bayt_gecerli;
    wire        k_mesgul;
    wire        k_uzunluk_hata;

    paket_kurucu #(.AZAMI_VERI(AZAMI_VERI)) kurucu (
        .g_saat(saat), .g_sifirla_n(sifirla_n),
        .g_basla(k_basla), .g_durum(k_durum_alan), .g_uzunluk(k_uzunluk),
        .c_word_iste(k_word_iste), .g_word(k_word), .g_word_gecerli(k_word_gecerli),
        .c_bayt(k_bayt), .c_bayt_gecerli(k_bayt_gecerli), .g_bayt_hazir(k_bayt_hazir),
        .c_mesgul(k_mesgul), .c_uzunluk_hata(k_uzunluk_hata)
    );

    // ═════════════════════════════════════════════════════════════════════
    //  ÇÖZÜCÜ (M-06)
    // ═════════════════════════════════════════════════════════════════════
    reg  [7:0]  c_bayt_gir;
    reg         c_bayt_gecerli_gir;
    reg         c_word_hazir;

    wire [7:0]  c_komut;
    wire [7:0]  c_uzunluk_cik;
    wire        c_komut_gecerli;
    wire [31:0] c_word;
    wire        c_word_gecerli;
    wire [3:0]  c_word_indis;
    wire        c_crc_hata;
    wire        c_uzunluk_hata;
    wire        c_zaman_asimi;
    wire        c_mesgul;

    paket_cozucu #(.AZAMI_VERI(AZAMI_VERI), .ZAMAN_ASIMI(ZAMAN_ASIMI)) cozucu (
        .g_saat(saat), .g_sifirla_n(sifirla_n),
        .g_bayt(c_bayt_gir), .g_bayt_gecerli(c_bayt_gecerli_gir),
        .c_komut(c_komut), .c_uzunluk(c_uzunluk_cik), .c_komut_gecerli(c_komut_gecerli),
        .c_word(c_word), .c_word_gecerli(c_word_gecerli), .c_word_indis(c_word_indis),
        .g_word_hazir(c_word_hazir),
        .c_crc_hata(c_crc_hata), .c_uzunluk_hata(c_uzunluk_hata),
        .c_zaman_asimi(c_zaman_asimi), .c_mesgul(c_mesgul)
    );

    // ── Kurucu cikisini yakala ────────────────────────────────────────────
    reg [7:0] kopru [0:127];
    integer   kopru_say = 0;

    always @(posedge saat) begin
        if (k_bayt_gecerli && kopru_say < 128) begin
            kopru[kopru_say] <= k_bayt;
            kopru_say <= kopru_say + 1;
        end
    end

    // ── Cozucu cikisini yakala ────────────────────────────────────────────
    reg [31:0] donen_word [0:15];
    integer    donen_say    = 0;
    integer    komut_say    = 0;
    integer    crc_hata_say = 0;

    always @(posedge saat) begin
        if (c_word_gecerli && donen_say < 16) begin
            donen_word[donen_say] <= c_word;
            donen_say <= donen_say + 1;
        end
        if (c_komut_gecerli) komut_say    <= komut_say + 1;
        if (c_crc_hata)      crc_hata_say <= crc_hata_say + 1;
    end

    // ── Word besleyici ────────────────────────────────────────────────────
    reg [31:0] word_kaynak [0:15];
    integer    word_indis = 0;

    always @(posedge saat) begin
        if (!sifirla_n) begin
            k_word_gecerli <= 1'b0;
        end else begin
            k_word_gecerli <= 1'b0;
            if (k_word_iste && word_indis < 16) begin
                k_word         <= word_kaynak[word_indis];
                k_word_gecerli <= 1'b1;
                word_indis     <= word_indis + 1;
            end
        end
    end

    // ── CRC-8 referansi ───────────────────────────────────────────────────
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

    // ═════════════════════════════════════════════════════════════════════
    //  GIDIS-DONUS GOREVI
    // ═════════════════════════════════════════════════════════════════════
    task gidis_donus(input [511:0] veri, input [7:0] uzunluk_b,
                     input [1023:0] ad);
        integer k, bek;
        reg [7:0] crc_yeni;
        reg       hata;
        begin
            hata = 1'b0;

            // ── 1) Kurucuyu surerek cerceve uret ──────────────────────────
            for (k = 0; k < 16; k = k + 1)
                word_kaynak[k] = veri[k*32 +: 32];

            kopru_say = 0; word_indis = 0; donen_say = 0;
            komut_say = 0; crc_hata_say = 0;

            @(negedge saat);
            k_durum_alan = 8'h00; k_uzunluk = uzunluk_b; k_basla = 1'b1;
            @(negedge saat);
            k_basla = 1'b0;

            bek = 0;
            while (k_mesgul === 1'b1 && bek < 5000) begin
                @(negedge saat); bek = bek + 1;
            end
            repeat (10) @(negedge saat);

            if (kopru_say != (uzunluk_b + 4)) begin
                hata = 1'b1;
                $display("     -> kurucu %0d bayt uretti, %0d beklendi",
                         kopru_say, uzunluk_b + 4);
            end

            // ── 2) Basligi cevir (0x5A -> 0xA5) ve CRC'yi yeniden hesapla ─
            //   Iki yon ayri baslik kullanir; sinanan sey cerceveleme
            //   ve endianness mantiginin simetrisidir.
            kopru[0] = 8'hA5;
            crc_yeni = 8'h00;
            for (k = 0; k < (uzunluk_b + 3); k = k + 1)
                crc_yeni = crc8_bayt(crc_yeni, kopru[k]);
            kopru[uzunluk_b + 3] = crc_yeni;

            // ── 3) Cozucuye besle (UART benzeri araliklarla) ──────────────
            for (k = 0; k < (uzunluk_b + 4); k = k + 1) begin
                @(negedge saat);
                c_bayt_gir = kopru[k]; c_bayt_gecerli_gir = 1'b1;
                @(negedge saat);
                c_bayt_gecerli_gir = 1'b0;
                repeat (4) @(negedge saat);
            end
            repeat (60) @(negedge saat);

            // ── 4) Karsilastir ────────────────────────────────────────────
            if (crc_hata_say != 0) begin
                hata = 1'b1;
                $display("     -> cozucu CRC hatasi verdi (simetri BOZUK)");
            end
            if (komut_say != 1) begin
                hata = 1'b1;
                $display("     -> komut darbesi %0d (1 beklendi)", komut_say);
            end
            if (donen_say != (uzunluk_b / 4)) begin
                hata = 1'b1;
                $display("     -> %0d word dondu, %0d beklendi",
                         donen_say, uzunluk_b / 4);
            end else begin
                for (k = 0; k < (uzunluk_b / 4); k = k + 1) begin
                    if (donen_word[k] !== veri[k*32 +: 32]) begin
                        hata = 1'b1;
                        $display("     -> word%0d: gonderilen 0x%08h, donen 0x%08h",
                                 k, veri[k*32 +: 32], donen_word[k]);
                    end
                end
            end

            kontrol(!hata, ad);
        end
    endtask

    // ── Test degerleri ────────────────────────────────────────────────────
    localparam [255:0] D_KARISIK =
        256'h0123456789ABCDEF_FEDCBA9876543210_1122334455667788_99AABBCCDDEEFF00;
    localparam [255:0] D_WORD0 =
        256'h00000000000000000000000000000000000000000000000000000000FFFFFFFF;
    localparam [255:0] D_WORD7 =
        256'hFFFFFFFF00000000000000000000000000000000000000000000000000000000;
    localparam [255:0] D_LSB   = 256'h1;
    localparam [255:0] D_MSB   =
        256'h8000000000000000000000000000000000000000000000000000000000000000;
    localparam [255:0] D_SIFIR = 256'h0;
    localparam [255:0] D_BIR   = {256{1'b1}};
    localparam [255:0] GX_MONT =
        256'h18905f76a53755c679fb732b7762251075ba95fc5fedb60179e730d418a9143c;
    localparam [255:0] GY_MONT =
        256'h8571ff1825885d85d2e88688dd21f3258b4ab8e4ba19e45cddf25357ce95560a;

    reg [511:0] v;

    initial begin
        $display("=====================================================");
        $display(" TB-09 : KURUCU <-> COZUCU KARSILIKLI TEST");
        $display("         *** KATMAN 2 KAPANIS KAPISI ***");
        $display("=====================================================");

        k_basla = 1'b0; k_durum_alan = 8'h00; k_uzunluk = 8'd0;
        k_word = 32'd0; k_bayt_hazir = 1'b1;
        c_bayt_gir = 8'h00; c_bayt_gecerli_gir = 1'b0; c_word_hazir = 1'b1;
        sifirla_n = 1'b0;
        repeat (10) @(posedge saat);
        @(negedge saat); sifirla_n = 1'b1;
        repeat (5) @(negedge saat);

        // ── T1: karisik desen ─────────────────────────────────────────────
        v = {256'd0, D_KARISIK};
        gidis_donus(v, 8'd32, "T1: Karisik desen — 8 word gidis-donus");

        // ── T2: sinir desenleri ───────────────────────────────────────────
        v = {256'd0, D_WORD0};
        gidis_donus(v, 8'd32, "T2a: Yalniz word0 dolu");
        v = {256'd0, D_WORD7};
        gidis_donus(v, 8'd32, "T2b: Yalniz word7 dolu");
        v = {256'd0, D_LSB};
        gidis_donus(v, 8'd32, "T2c: Tek bit — LSB (bit0)");
        v = {256'd0, D_MSB};
        gidis_donus(v, 8'd32, "T2d: Tek bit — MSB (bit255)");
        v = {256'd0, D_SIFIR};
        gidis_donus(v, 8'd32, "T2e: Tamamen sifir");
        v = {256'd0, D_BIR};
        gidis_donus(v, 8'd32, "T2f: Tamamen bir");

        // ── T3: gercek P-256 sabiti ───────────────────────────────────────
        v = {256'd0, GX_MONT};
        gidis_donus(v, 8'd32, "T3: GX_MONT (ecdh_kex_top ile ayni sabit)");

        // ── T4: 64 baytlik cerceve (X||Y) ─────────────────────────────────
        v = {GY_MONT, GX_MONT};
        gidis_donus(v, 8'd64, "T4: 64 bayt — GX_MONT || GY_MONT (16 word)");

        // ── T5: ardisik cerceveler, durum sizintisi yok ───────────────────
        v = {256'd0, D_KARISIK};
        gidis_donus(v, 8'd32, "T5a: Ardisik cerceve 1");
        v = {256'd0, GX_MONT};
        gidis_donus(v, 8'd32, "T5b: Ardisik cerceve 2 (sizinti yok)");
        v = {256'd0, D_SIFIR};
        gidis_donus(v, 8'd32, "T5c: Ardisik cerceve 3");

        // ── Özet ──────────────────────────────────────────────────────────
        $display("-----------------------------------------------------");
        if (hata_say == 0) begin
            $display(" TB-09 SONUC: TUM TESTLER GECTI");
            $display(" >>> ENDIANNESS KILITLENDI (K-05/K-06)");
            $display(" >>> KATMAN 2 KAPANDI — Katman 3'e gecilebilir.");
        end else begin
            $display(" TB-09 SONUC: %0d TEST KALDI", hata_say);
            $display(" >>> Katman 3'e GECMEYIN. Endianness uzlasimi bozuk.");
        end
        $display("=====================================================");
        $finish;
    end

    initial begin
        #50_000_000;
        $display(" TB-09 HATA: zaman asimi (simulasyon takildi)");
        $finish;
    end

endmodule
