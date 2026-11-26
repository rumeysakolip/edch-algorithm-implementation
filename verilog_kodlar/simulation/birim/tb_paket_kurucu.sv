// =============================================================================
// Testbench : tb_paket_kurucu.sv                                   (İster TB-07)
// Hedef     : paket_kurucu.v (M-07) + crc8_hesap.v (M-03)
// -----------------------------------------------------------------------------
// Kontrol edilenler:
//   T1. Çerçeve alanları: [0x5A][DURUM][UZUNLUK][VERI][CRC]
//   T2. ENDIANNESS: word'ün en düşük baytı hatta İLK çıkar (K-06)
//   T3. CRC baytı doğru — son veri baytını İÇERİR (D_CRC_BEK kontrolü)
//   T4. c_word_iste el sıkışması
//   T5. Verisiz çerçeve (uzunluk 0) → 4 bayt
//   T6. GERİ BASINÇ altında bayt kaybı yok (kritik)
//   T7. 64 baytlık çerçeve → 68 bayt toplam
//   T8. Uzunluk hatası → çerçeve başlatılmaz
//
// Beklenen değerler host/katman2_capraz_kontrol.py ile üretilmiştir.
//
// Koşturma (Vivado xsim):
//   xvlog -sv tb_paket_kurucu.sv ../sources_1/paket_kurucu.v ../sources_1/crc8_hesap.v
//   xelab -debug typical tb_paket_kurucu -s tb && xsim tb -R
// =============================================================================

`timescale 1ns / 1ps

module tb_paket_kurucu;

    localparam real    SAAT_PERIYOT = 10.0;
    localparam integer AZAMI_VERI   = 64;

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

    // ── DUT ───────────────────────────────────────────────────────────────
    reg         saat = 1'b0;
    reg         sifirla_n;
    reg         basla;
    reg  [7:0]  durum_alan;
    reg  [7:0]  uzunluk;
    reg  [31:0] word_veri;
    reg         word_gecerli;
    reg         bayt_hazir;

    wire        c_word_iste;
    wire [7:0]  c_bayt;
    wire        c_bayt_gecerli;
    wire        c_mesgul;
    wire        c_uzunluk_hata;

    always #(SAAT_PERIYOT/2.0) saat = ~saat;

    paket_kurucu #(.AZAMI_VERI(AZAMI_VERI)) dut (
        .g_saat(saat), .g_sifirla_n(sifirla_n),
        .g_basla(basla), .g_durum(durum_alan), .g_uzunluk(uzunluk),
        .c_word_iste(c_word_iste), .g_word(word_veri), .g_word_gecerli(word_gecerli),
        .c_bayt(c_bayt), .c_bayt_gecerli(c_bayt_gecerli), .g_bayt_hazir(bayt_hazir),
        .c_mesgul(c_mesgul), .c_uzunluk_hata(c_uzunluk_hata)
    );

    // ── Cikan baytlari yakala ─────────────────────────────────────────────
    reg [7:0] cikan [0:127];
    integer   cikan_say = 0;
    integer   uz_hata_say = 0;

    always @(posedge saat) begin
        if (c_bayt_gecerli && cikan_say < 128) begin
            cikan[cikan_say] <= c_bayt;
            cikan_say <= cikan_say + 1;
        end
        if (c_uzunluk_hata) uz_hata_say <= uz_hata_say + 1;
    end

    // ── Word besleyici: c_word_iste geldiginde siradaki word'u ver ────────
    reg [31:0] word_kaynak [0:15];
    integer    word_indis = 0;
    reg        besleyici_aktif = 1'b0;

    always @(posedge saat) begin
        if (!sifirla_n) begin
            word_gecerli <= 1'b0;
        end else begin
            word_gecerli <= 1'b0;
            if (besleyici_aktif && c_word_iste && word_indis < 16) begin
                word_veri    <= word_kaynak[word_indis];
                word_gecerli <= 1'b1;
                word_indis   <= word_indis + 1;
            end
        end
    end

    // ── CRC-8 referansi (TB tarafi) ───────────────────────────────────────
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

    // ── Cerceve baslatma ──────────────────────────────────────────────────
    task cerceve_basla(input [7:0] d, input [7:0] uz);
        begin
            @(negedge saat);
            durum_alan = d; uzunluk = uz; basla = 1'b1;
            @(negedge saat);
            basla = 1'b0;
        end
    endtask

    task bitmeyi_bekle;
        integer bek;
        begin
            bek = 0;
            while (c_mesgul === 1'b1 && bek < 5000) begin
                @(negedge saat);
                bek = bek + 1;
            end
            repeat (10) @(negedge saat);
        end
    endtask

    // ── Test verileri ─────────────────────────────────────────────────────
    localparam [255:0] VERI_A =
        256'h0123456789ABCDEF_FEDCBA9876543210_1122334455667788_99AABBCCDDEEFF00;
    localparam [255:0] VERI_B =
        256'hAABBCCDDEEFF0011_2233445566778899_0123456789ABCDEF_0F1E2D3C4B5A6978;

    integer i;
    reg     uyum_hata;
    reg [7:0] crc_bek;
    reg [7:0] cikan_kopya [0:127];
    integer   cikan_say_kopya;

    // Beklenen cerceveyi dogrula
    task cerceve_dogrula(input [7:0] d, input [7:0] uz, input [511:0] veri,
                         input [1023:0] ad);
        integer k;
        reg hata;
        begin
            hata = 1'b0;
            crc_bek = 8'h00;

            if (cikan_say != (uz + 4)) begin
                hata = 1'b1;
                $display("     -> bayt sayisi: beklenen %0d, alinan %0d", uz+4, cikan_say);
            end else begin
                if (cikan[0] !== 8'h5A) begin
                    hata = 1'b1; $display("     -> baslik: 0x%02h (0x5A olmali)", cikan[0]);
                end
                if (cikan[1] !== d) begin
                    hata = 1'b1; $display("     -> durum: 0x%02h (0x%02h olmali)", cikan[1], d);
                end
                if (cikan[2] !== uz) begin
                    hata = 1'b1; $display("     -> uzunluk: %0d (%0d olmali)", cikan[2], uz);
                end
                crc_bek = crc8_bayt(crc_bek, cikan[0]);
                crc_bek = crc8_bayt(crc_bek, cikan[1]);
                crc_bek = crc8_bayt(crc_bek, cikan[2]);
                for (k = 0; k < uz; k = k + 1) begin
                    // ENDIANNESS (K-06): en dusuk bayt ilk
                    if (cikan[3+k] !== veri[k*8 +: 8]) begin
                        hata = 1'b1;
                        if (k < 6) $display("     -> veri[%0d]: 0x%02h (0x%02h olmali)",
                                            k, cikan[3+k], veri[k*8 +: 8]);
                    end
                    crc_bek = crc8_bayt(crc_bek, cikan[3+k]);
                end
                if (cikan[3+uz] !== crc_bek) begin
                    hata = 1'b1;
                    $display("     -> CRC: 0x%02h (0x%02h olmali)", cikan[3+uz], crc_bek);
                end
            end
            kontrol(!hata, ad);
        end
    endtask

    reg [511:0] veri_gecici;

    initial begin
        $display("=====================================================");
        $display(" TB-07 : paket_kurucu");
        $display("=====================================================");

        basla = 1'b0; durum_alan = 8'h00; uzunluk = 8'd0;
        word_veri = 32'd0; bayt_hazir = 1'b1;
        sifirla_n = 1'b0;
        repeat (10) @(posedge saat);
        @(negedge saat); sifirla_n = 1'b1;
        repeat (5) @(negedge saat);

        for (i = 0; i < 8; i = i + 1)  word_kaynak[i]   = VERI_A[i*32 +: 32];
        for (i = 0; i < 8; i = i + 1)  word_kaynak[i+8] = VERI_B[i*32 +: 32];

        // ── T1/T2/T3/T4: 32 baytlik cerceve ───────────────────────────────
        cikan_say = 0; word_indis = 0; besleyici_aktif = 1'b1;
        cerceve_basla(8'h00, 8'd32);
        bitmeyi_bekle;

        veri_gecici = {256'd0, VERI_A};
        cerceve_dogrula(8'h00, 8'd32, veri_gecici,
                        "T1/T2/T3: 32 baytlik cerceve alanlari, endianness ve CRC dogru");
        kontrol(cikan_say == 36, "T1b: Toplam 36 bayt");
        kontrol(word_indis == 8, "T4: c_word_iste el sikismasi 8 word cekti");

        // ── T5: verisiz cerceve ───────────────────────────────────────────
        cikan_say = 0; word_indis = 0;
        cerceve_basla(8'hE1, 8'd0);
        bitmeyi_bekle;
        cerceve_dogrula(8'hE1, 8'd0, 512'd0, "T5a: Verisiz cerceve (hata yaniti) dogru");
        kontrol(cikan_say == 4, "T5b: Verisiz cerceve 4 bayt");
        kontrol(word_indis == 0, "T5c: Verisiz cercevede word istenmedi");

        // ── T7: 64 baytlik cerceve ────────────────────────────────────────
        cikan_say = 0; word_indis = 0;
        cerceve_basla(8'h00, 8'd64);
        bitmeyi_bekle;
        veri_gecici = {VERI_B, VERI_A};
        cerceve_dogrula(8'h00, 8'd64, veri_gecici, "T7a: 64 baytlik cerceve dogru");
        kontrol(cikan_say == 68,
                "T7b: Toplam 68 bayt (>64 -> TX FIFO derinligi 128 olmali)");

        // ── T6: GERI BASINC altinda ───────────────────────────────────────
        //   bayt_hazir her 3 cevrimde bir dusuk (FIFO dolu benzetimi)
        cikan_say = 0; word_indis = 0;
        fork
            begin
                cerceve_basla(8'h00, 8'd32);
                bitmeyi_bekle;
            end
            begin : geri_basinc
                integer c;
                for (c = 0; c < 4000; c = c + 1) begin
                    @(negedge saat);
                    bayt_hazir = (c % 3 == 0) ? 1'b0 : 1'b1;
                end
            end
        join_any
        disable geri_basinc;
        @(negedge saat); bayt_hazir = 1'b1;
        repeat (20) @(negedge saat);

        veri_gecici = {256'd0, VERI_A};
        cerceve_dogrula(8'h00, 8'd32, veri_gecici,
                        "T6: GERI BASINC altinda bayt kaybi YOK (KRITIK)");

        // ── T8: uzunluk hatasi ────────────────────────────────────────────
        cikan_say = 0; uz_hata_say = 0;
        cerceve_basla(8'h00, 8'd65);          // > AZAMI_VERI
        repeat (30) @(negedge saat);
        kontrol(uz_hata_say == 1 && cikan_say == 0,
                "T8a: Uzunluk 65 -> hata, cerceve baslatilmadi");

        cikan_say = 0; uz_hata_say = 0;
        cerceve_basla(8'h00, 8'd33);          // 4'un kati degil
        repeat (30) @(negedge saat);
        kontrol(uz_hata_say == 1 && cikan_say == 0,
                "T8b: Uzunluk 33 -> hata, cerceve baslatilmadi");

        // Hata sonrasi normal cerceve
        cikan_say = 0; word_indis = 0;
        cerceve_basla(8'h00, 8'd32);
        bitmeyi_bekle;
        cerceve_dogrula(8'h00, 8'd32, veri_gecici,
                        "T8c: Uzunluk hatasi sonrasi FSM toparlandi");

        // ── Özet ──────────────────────────────────────────────────────────
        $display("-----------------------------------------------------");
        if (hata_say == 0) $display(" TB-07 SONUC: TUM TESTLER GECTI");
        else               $display(" TB-07 SONUC: %0d TEST KALDI", hata_say);
        $display("=====================================================");
        $finish;
    end

    initial begin
        #20_000_000;
        $display(" TB-07 HATA: zaman asimi (simulasyon takildi)");
        $finish;
    end

endmodule
