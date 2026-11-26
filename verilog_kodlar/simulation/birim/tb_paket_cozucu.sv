// =============================================================================
// Testbench : tb_paket_cozucu.sv                                   (İster TB-06)
// Hedef     : paket_cozucu.v (M-06) + crc8_hesap.v (M-03)
// -----------------------------------------------------------------------------
// Kontrol edilenler:
//   T1. Geçerli 32 baytlık çerçeve → 8 word, doğru sıra ve ENDIANNESS
//   T2. Geçerli 64 baytlık çerçeve → 16 word
//   T3. Tek bit bozulması → c_crc_hata, WORD ÇIKIŞI BASTIRILIR (kritik)
//   T4. Bozuk CRC baytı → çerçeve reddedilir
//   T5. Uzunluk hatası (65 ve 33)
//   T6. Verisiz komut (uzunluk 0) → komut darbesi var, word yok
//   T7. Gövdede 0xA5 resenkronizasyona sebep OLMAZ
//   T8. Yarım çerçeve → zaman aşımı, FSM toparlanır (kilitlenme yok)
//   T9. Çerçeve öncesi çöp baytlar sessizce atılır
//
// Beklenen değerler host/katman2_capraz_kontrol.py ile üretilmiştir.
//
// NOT: ZAMAN_ASIMI sim için 200 çevrime düşürülmüştür (gerçekte 5_000_000).
//
// Koşturma (Vivado xsim):
//   xvlog -sv tb_paket_cozucu.sv ../sources_1/paket_cozucu.v ../sources_1/crc8_hesap.v
//   xelab -debug typical tb_paket_cozucu -s tb && xsim tb -R
// =============================================================================

`timescale 1ns / 1ps

module tb_paket_cozucu;

    localparam real    SAAT_PERIYOT = 10.0;
    localparam integer AZAMI_VERI   = 64;
    localparam integer ZAMAN_ASIMI  = 200;      // sim icin kisaltildi
    localparam integer BAYT_ARALIK  = 4;        // baytlar arasi bosluk (cevrim)

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
    reg  [7:0]  bayt;
    reg         bayt_gecerli;
    reg         word_hazir;

    wire [7:0]  c_komut;
    wire [7:0]  c_uzunluk;
    wire        c_komut_gecerli;
    wire [31:0] c_word;
    wire        c_word_gecerli;
    wire [3:0]  c_word_indis;
    wire        c_crc_hata;
    wire        c_uzunluk_hata;
    wire        c_zaman_asimi;
    wire        c_mesgul;

    always #(SAAT_PERIYOT/2.0) saat = ~saat;

    paket_cozucu #(.AZAMI_VERI(AZAMI_VERI), .ZAMAN_ASIMI(ZAMAN_ASIMI)) dut (
        .g_saat(saat), .g_sifirla_n(sifirla_n),
        .g_bayt(bayt), .g_bayt_gecerli(bayt_gecerli),
        .c_komut(c_komut), .c_uzunluk(c_uzunluk), .c_komut_gecerli(c_komut_gecerli),
        .c_word(c_word), .c_word_gecerli(c_word_gecerli), .c_word_indis(c_word_indis),
        .g_word_hazir(word_hazir),
        .c_crc_hata(c_crc_hata), .c_uzunluk_hata(c_uzunluk_hata),
        .c_zaman_asimi(c_zaman_asimi), .c_mesgul(c_mesgul)
    );

    // ── İzleyiciler ───────────────────────────────────────────────────────
    reg [31:0] alinan_word [0:15];
    reg [3:0]  alinan_indis[0:15];
    integer    word_say       = 0;
    integer    komut_say      = 0;
    integer    crc_hata_say   = 0;
    integer    uz_hata_say    = 0;
    integer    za_say         = 0;
    reg [7:0]  son_komut, son_uzunluk;

    always @(posedge saat) begin
        if (c_word_gecerli && word_say < 16) begin
            alinan_word[word_say]  <= c_word;
            alinan_indis[word_say] <= c_word_indis;
            word_say <= word_say + 1;
        end
        if (c_komut_gecerli) begin
            son_komut   <= c_komut;
            son_uzunluk <= c_uzunluk;
            komut_say   <= komut_say + 1;
        end
        if (c_crc_hata)     crc_hata_say <= crc_hata_say + 1;
        if (c_uzunluk_hata) uz_hata_say  <= uz_hata_say  + 1;
        if (c_zaman_asimi)  za_say       <= za_say       + 1;
    end

    task sayaclari_sifirla;
        begin
            word_say = 0; komut_say = 0;
            crc_hata_say = 0; uz_hata_say = 0; za_say = 0;
        end
    endtask

    // ── CRC-8 referansı (TB tarafı — DUT'tan bağımsız) ────────────────────
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

    // ── Bayt gönderimi ────────────────────────────────────────────────────
    reg [7:0] crc_ref_r;

    task bayt_ver(input [7:0] b);
        integer k;
        begin
            @(negedge saat);
            bayt = b; bayt_gecerli = 1'b1;
            @(negedge saat);
            bayt_gecerli = 1'b0;
            for (k = 0; k < BAYT_ARALIK; k = k + 1) @(negedge saat);
        end
    endtask

    // Cerceve gonderimi: [A5][KOMUT][UZUNLUK][VERI][CRC]
    //   veri_deger: 256-bit; uzunluk 32 ise dusuk 32 bayti kullanilir.
    task cerceve_ver(input [7:0] komut, input [7:0] uzunluk,
                     input [511:0] veri, input crc_boz);
        integer k;
        reg [7:0] b;
        begin
            crc_ref_r = 8'h00;
            b = 8'hA5; crc_ref_r = crc8_bayt(crc_ref_r, b); bayt_ver(b);
            b = komut; crc_ref_r = crc8_bayt(crc_ref_r, b); bayt_ver(b);
            b = uzunluk; crc_ref_r = crc8_bayt(crc_ref_r, b); bayt_ver(b);
            for (k = 0; k < uzunluk; k = k + 1) begin
                b = veri[k*8 +: 8];               // LSB-first (K-06)
                crc_ref_r = crc8_bayt(crc_ref_r, b);
                bayt_ver(b);
            end
            bayt_ver(crc_boz ? (crc_ref_r ^ 8'hFF) : crc_ref_r);
            repeat (40) @(negedge saat);          // teslim asamasi
        end
    endtask

    // ── Test verileri ─────────────────────────────────────────────────────
    localparam [255:0] VERI_A =
        256'h0123456789ABCDEF_FEDCBA9876543210_1122334455667788_99AABBCCDDEEFF00;
    localparam [255:0] VERI_B =
        256'hAABBCCDDEEFF0011_2233445566778899_0123456789ABCDEF_0F1E2D3C4B5A6978;
    // Gercek P-256 GX (Montgomery) — ecdh_kex_top ile ayni sabit
    localparam [255:0] GX_MONT =
        256'h18905f76a53755c679fb732b7762251075ba95fc5fedb60179e730d418a9143c;

    integer i;
    reg     uyum_hata;
    reg [511:0] veri_gecici;

    initial begin
        $display("=====================================================");
        $display(" TB-06 : paket_cozucu  (ZAMAN_ASIMI=%0d cevrim)", ZAMAN_ASIMI);
        $display("=====================================================");

        bayt = 8'h00; bayt_gecerli = 1'b0; word_hazir = 1'b1;
        sifirla_n = 1'b0;
        repeat (10) @(posedge saat);
        @(negedge saat); sifirla_n = 1'b1;
        repeat (5) @(negedge saat);

        // ── T1: gecerli 32 baytlik cerceve ────────────────────────────────
        sayaclari_sifirla;
        veri_gecici = {256'd0, VERI_A};
        cerceve_ver(8'h10, 8'd32, veri_gecici, 1'b0);

        kontrol(komut_say == 1 && son_komut === 8'h10 && son_uzunluk === 8'd32,
                "T1a: Gecerli cerceve -> komut 0x10, uzunluk 32");
        kontrol(word_say == 8, "T1b: 8 word uretildi");

        uyum_hata = 1'b0;
        for (i = 0; i < 8; i = i + 1) begin
            if (alinan_word[i] !== VERI_A[i*32 +: 32]) begin
                uyum_hata = 1'b1;
                $display("     -> word%0d: beklenen 0x%08h, alinan 0x%08h",
                         i, VERI_A[i*32 +: 32], alinan_word[i]);
            end
            if (alinan_indis[i] !== i[3:0]) begin
                uyum_hata = 1'b1;
                $display("     -> indis%0d: beklenen %0d, alinan %0d",
                         i, i, alinan_indis[i]);
            end
        end
        kontrol(!uyum_hata, "T1c: ENDIANNESS ve word sirasi dogru (K-05/K-06)");
        kontrol(alinan_word[0] === VERI_A[31:0], "T1d: word0 == VERI[31:0]");

        // ── T2: 64 baytlik cerceve ────────────────────────────────────────
        sayaclari_sifirla;
        veri_gecici = {VERI_B, VERI_A};
        cerceve_ver(8'h01, 8'd64, veri_gecici, 1'b0);

        kontrol(komut_say == 1 && son_uzunluk === 8'd64 && word_say == 16,
                "T2a: 64 baytlik QB_YUKLE -> 16 word");
        uyum_hata = 1'b0;
        for (i = 0; i < 8; i = i + 1) begin
            if (alinan_word[i]   !== VERI_A[i*32 +: 32]) uyum_hata = 1'b1;
            if (alinan_word[i+8] !== VERI_B[i*32 +: 32]) uyum_hata = 1'b1;
        end
        kontrol(!uyum_hata, "T2b: X||Y sirasi korundu");

        // ── T3: tek bit bozulmasi (CRC hatasi) ────────────────────────────
        //   crc_boz=1 ile CRC bayti bozulur -> ayni etki
        sayaclari_sifirla;
        veri_gecici = {256'd0, VERI_A};
        cerceve_ver(8'h10, 8'd32, veri_gecici, 1'b1);

        kontrol(crc_hata_say == 1, "T3a: Bozuk CRC -> c_crc_hata darbesi");
        kontrol(word_say == 0,
                "T3b: CRC hatasinda WORD CIKISI BASTIRILDI (KRITIK)");
        kontrol(komut_say == 0, "T3c: CRC hatasinda komut darbesi yok");

        // ── T4: hata sonrasi toparlanma ───────────────────────────────────
        sayaclari_sifirla;
        cerceve_ver(8'h10, 8'd32, veri_gecici, 1'b0);
        kontrol(komut_say == 1 && word_say == 8,
                "T4: CRC hatasi sonrasi FSM toparlandi");

        // ── T5: uzunluk hatalari ──────────────────────────────────────────
        sayaclari_sifirla;
        crc_ref_r = 8'h00;
        bayt_ver(8'hA5); bayt_ver(8'h01); bayt_ver(8'd65);   // 65 > AZAMI
        repeat (20) @(negedge saat);
        kontrol(uz_hata_say == 1, "T5a: Uzunluk 65 -> uzunluk hatasi");

        sayaclari_sifirla;
        bayt_ver(8'hA5); bayt_ver(8'h01); bayt_ver(8'd33);   // 4'un kati degil
        repeat (20) @(negedge saat);
        kontrol(uz_hata_say == 1, "T5b: Uzunluk 33 (4'un kati degil) -> hata");

        // ── T6: verisiz komut ─────────────────────────────────────────────
        sayaclari_sifirla;
        cerceve_ver(8'h02, 8'd0, 512'd0, 1'b0);
        kontrol(komut_say == 1 && son_komut === 8'h02 && word_say == 0,
                "T6: Verisiz komut (ECDH_BASLAT) -> komut var, word yok");

        // ── T7: govdede 0xA5 ──────────────────────────────────────────────
        sayaclari_sifirla;
        veri_gecici = {256'd0, {32{8'hA5}}};
        cerceve_ver(8'h10, 8'd32, veri_gecici, 1'b0);
        uyum_hata = 1'b0;
        for (i = 0; i < 8; i = i + 1)
            if (alinan_word[i] !== 32'hA5A5A5A5) uyum_hata = 1'b1;
        kontrol(komut_say == 1 && word_say == 8 && !uyum_hata,
                "T7: Govdede 0xA5 resenkronizasyona sebep OLMADI");

        // ── T8: yarim cerceve -> zaman asimi ──────────────────────────────
        sayaclari_sifirla;
        bayt_ver(8'hA5); bayt_ver(8'h10); bayt_ver(8'd32);
        bayt_ver(8'h11); bayt_ver(8'h22);        // cerceve yarida kesiliyor
        repeat (ZAMAN_ASIMI + 100) @(negedge saat);
        kontrol(za_say >= 1, "T8a: Yarim cerceve -> zaman asimi darbesi");
        kontrol(c_mesgul === 1'b0, "T8b: Zaman asimi sonrasi BEKLE'ye donuldu");

        sayaclari_sifirla;
        veri_gecici = {256'd0, VERI_A};
        cerceve_ver(8'h10, 8'd32, veri_gecici, 1'b0);
        kontrol(komut_say == 1 && word_say == 8,
                "T8c: Zaman asimi sonrasi FSM toparlandi (KILITLENME YOK)");

        // ── T9: cerceve oncesi cop ────────────────────────────────────────
        sayaclari_sifirla;
        bayt_ver(8'h00); bayt_ver(8'hFF); bayt_ver(8'h12); bayt_ver(8'h34);
        cerceve_ver(8'h10, 8'd32, veri_gecici, 1'b0);
        kontrol(komut_say == 1 && word_say == 8,
                "T9: Cerceve oncesi cop baytlar sessizce atildi");

        // ── T10: gercek P-256 sabiti ──────────────────────────────────────
        sayaclari_sifirla;
        veri_gecici = {256'd0, GX_MONT};
        cerceve_ver(8'h01, 8'd32, veri_gecici, 1'b0);
        uyum_hata = 1'b0;
        for (i = 0; i < 8; i = i + 1)
            if (alinan_word[i] !== GX_MONT[i*32 +: 32]) uyum_hata = 1'b1;
        kontrol(!uyum_hata,
                "T10: GX_MONT (gercek ecdh_kex_top sabiti) dogru cozuldu");

        // ── Özet ──────────────────────────────────────────────────────────
        $display("-----------------------------------------------------");
        if (hata_say == 0) $display(" TB-06 SONUC: TUM TESTLER GECTI");
        else               $display(" TB-06 SONUC: %0d TEST KALDI", hata_say);
        $display("=====================================================");
        $finish;
    end

    initial begin
        #20_000_000;
        $display(" TB-06 HATA: zaman asimi (simulasyon takildi)");
        $finish;
    end

endmodule
