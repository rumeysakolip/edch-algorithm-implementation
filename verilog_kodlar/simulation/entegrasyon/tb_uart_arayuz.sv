// =============================================================================
// Testbench : tb_uart_arayuz.sv                                    (Ister TB-10)
// Hedef     : uart_arayuz.v (M-08) + M-01..M-07
// -----------------------------------------------------------------------------
// Uctan uca ENTEGRASYON testi. Seri pinden cerceve girer, seri pinden cerceve
// cikar. Aradaki tum zincir (uart_rx -> fifo -> cozucu -> ... -> kurucu ->
// fifo -> uart_tx) gercek modullerle kosar.
//
// Kontrol edilenler:
//   T1. Seri girisden gelen 32 baytlik cerceve dogru cozuldu
//   T2. ECHO: alinan word'ler geri gonderilip seri cikista dogrulandi
//   T3. 64 baytlik cerceve (68 bayt cikis — TX FIFO tikanma senaryosu)
//   T4. Verisiz komut cercevesi
//   T5. Bozuk CRC -> c_hata[1] darbesi, word cikisi yok
//   T6. Ardisik cerceveler — durum sizintisi yok
//
// NOT: BOLUCU=4 ile sim hizlandirilmistir (bit suresi 640 ns).
//
// Kosturma (Vivado xsim):
//   xvlog -sv tb_uart_arayuz.sv ../sources_1/uart_arayuz.v ../sources_1/uart_rx.v \
//         ../sources_1/uart_tx.v ../sources_1/uart_baud_uretici.v \
//         ../sources_1/senk_fifo.v ../sources_1/paket_cozucu.v \
//         ../sources_1/paket_kurucu.v ../sources_1/crc8_hesap.v
//   xelab -debug typical tb_uart_arayuz -s tb && xsim tb -R
// =============================================================================

`timescale 1ns / 1ps

module tb_uart_arayuz;

    localparam integer SAAT_HZ    = 100_000_000;
    localparam integer ORNEKLEME  = 16;
    localparam integer BOLUCU     = 4;
    localparam integer BAUD_HIZI  = SAAT_HZ/(BOLUCU*ORNEKLEME);
    localparam real    SAAT_PERIYOT = 10.0;
    localparam real    BIT_SURESI   = BOLUCU * ORNEKLEME * SAAT_PERIYOT;

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
    reg         seri_rx;
    wire        seri_tx;

    wire [7:0]  c_komut, c_uzunluk;
    wire        c_komut_gecerli;
    wire [31:0] c_rx_word;
    wire        c_rx_word_gecerli;
    wire [3:0]  c_rx_indis;

    reg         yanit_basla;
    reg  [7:0]  yanit_durum, yanit_uzunluk;
    reg  [31:0] tx_word;
    reg         tx_word_gecerli;
    wire        c_tx_word_iste;
    wire        c_mesgul;
    wire [3:0]  c_hata;

    always #(SAAT_PERIYOT/2.0) saat = ~saat;

    uart_arayuz #(
        .SAAT_HZ(SAAT_HZ), .BAUD_HIZI(BAUD_HIZI), .ORNEKLEME(ORNEKLEME),
        .AZAMI_VERI(64), .ZAMAN_ASIMI(1_000_000),
        .RX_DERINLIK(16), .TX_DERINLIK(128)
    ) dut (
        .g_saat(saat), .g_sifirla_n(sifirla_n),
        .g_seri_rx(seri_rx), .c_seri_tx(seri_tx),
        .c_komut(c_komut), .c_uzunluk(c_uzunluk), .c_komut_gecerli(c_komut_gecerli),
        .c_rx_word(c_rx_word), .c_rx_word_gecerli(c_rx_word_gecerli),
        .c_rx_indis(c_rx_indis), .g_rx_word_hazir(1'b1),
        .g_yanit_basla(yanit_basla), .g_yanit_durum(yanit_durum),
        .g_yanit_uzunluk(yanit_uzunluk),
        .g_tx_word(tx_word), .g_tx_word_gecerli(tx_word_gecerli),
        .c_tx_word_iste(c_tx_word_iste),
        .c_mesgul(c_mesgul), .c_hata(c_hata)
    );

    // ── Alinan word'leri yakala ───────────────────────────────────────────
    reg [31:0] alinan_word [0:15];
    integer    alinan_say  = 0;
    integer    komut_say   = 0;
    integer    crc_hata_say = 0;
    reg [7:0]  son_komut, son_uzunluk;

    always @(posedge saat) begin
        if (c_rx_word_gecerli && alinan_say < 16) begin
            alinan_word[alinan_say] <= c_rx_word;
            alinan_say <= alinan_say + 1;
        end
        if (c_komut_gecerli) begin
            son_komut   <= c_komut;
            son_uzunluk <= c_uzunluk;
            komut_say   <= komut_say + 1;
        end
        if (c_hata[1]) crc_hata_say <= crc_hata_say + 1;
    end

    // ── TX word besleyici (echo icin) ─────────────────────────────────────
    reg [31:0] tx_kaynak [0:15];
    integer    tx_indis = 0;

    always @(posedge saat) begin
        if (!sifirla_n) begin
            tx_word_gecerli <= 1'b0;
        end else begin
            tx_word_gecerli <= 1'b0;
            if (c_tx_word_iste && tx_indis < 16) begin
                tx_word         <= tx_kaynak[tx_indis];
                tx_word_gecerli <= 1'b1;
                tx_indis        <= tx_indis + 1;
            end
        end
    end

    // ── Seri cikisi coz ───────────────────────────────────────────────────
    reg [7:0] cikan [0:127];
    integer   cikan_say = 0;

    initial begin : tx_cozucu
        reg [7:0] b;
        integer   k;
        forever begin
            @(negedge seri_tx);           // start biti
            #(BIT_SURESI * 1.5);
            for (k = 0; k < 8; k = k + 1) begin
                b[k] = seri_tx;
                if (k < 7) #(BIT_SURESI);
            end
            #(BIT_SURESI);                // stop bitinin ortasi
            if (cikan_say < 128) begin
                cikan[cikan_say] = b;
                cikan_say = cikan_say + 1;
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

    // ── Seri bayt gonderimi ───────────────────────────────────────────────
    task seri_bayt(input [7:0] b);
        integer k;
        begin
            seri_rx = 1'b0;  #(BIT_SURESI);
            for (k = 0; k < 8; k = k + 1) begin
                seri_rx = b[k];  #(BIT_SURESI);
            end
            seri_rx = 1'b1;  #(BIT_SURESI);
        end
    endtask

    reg [7:0] crc_ref_r;

    task seri_cerceve(input [7:0] komut, input [7:0] uzunluk,
                      input [511:0] veri, input crc_boz);
        integer k;
        reg [7:0] b;
        begin
            crc_ref_r = 8'h00;
            b = 8'hA5; crc_ref_r = crc8_bayt(crc_ref_r, b); seri_bayt(b);
            b = komut; crc_ref_r = crc8_bayt(crc_ref_r, b); seri_bayt(b);
            b = uzunluk; crc_ref_r = crc8_bayt(crc_ref_r, b); seri_bayt(b);
            for (k = 0; k < uzunluk; k = k + 1) begin
                b = veri[k*8 +: 8];
                crc_ref_r = crc8_bayt(crc_ref_r, b);
                seri_bayt(b);
            end
            seri_bayt(crc_boz ? (crc_ref_r ^ 8'hFF) : crc_ref_r);
            #(BIT_SURESI * 3);
        end
    endtask

    // ── Test verileri ─────────────────────────────────────────────────────
    localparam [255:0] VERI_A =
        256'h0123456789ABCDEF_FEDCBA9876543210_1122334455667788_99AABBCCDDEEFF00;
    localparam [255:0] GX_MONT =
        256'h18905f76a53755c679fb732b7762251075ba95fc5fedb60179e730d418a9143c;
    localparam [255:0] GY_MONT =
        256'h8571ff1825885d85d2e88688dd21f3258b4ab8e4ba19e45cddf25357ce95560a;

    integer i;
    reg     uyum_hata;
    reg [7:0] crc_bek;
    reg [511:0] v;

    task sayaclari_sifirla;
        begin
            alinan_say = 0; komut_say = 0; crc_hata_say = 0;
            cikan_say = 0; tx_indis = 0;
        end
    endtask

    // Cikan yanit cercevesini dogrula
    task yaniti_dogrula(input [7:0] d, input [7:0] uz, input [511:0] veri,
                        input [1023:0] ad);
        integer k;
        reg hata;
        begin
            hata = 1'b0;
            crc_bek = 8'h00;
            if (cikan_say != (uz + 4)) begin
                hata = 1'b1;
                $display("     -> yanit %0d bayt, %0d beklendi", cikan_say, uz+4);
            end else begin
                if (cikan[0] !== 8'h5A) hata = 1'b1;
                if (cikan[1] !== d)     hata = 1'b1;
                if (cikan[2] !== uz)    hata = 1'b1;
                for (k = 0; k < 3; k = k + 1) crc_bek = crc8_bayt(crc_bek, cikan[k]);
                for (k = 0; k < uz; k = k + 1) begin
                    if (cikan[3+k] !== veri[k*8 +: 8]) begin
                        hata = 1'b1;
                        if (k < 6) $display("     -> yanit veri[%0d]: 0x%02h (0x%02h olmali)",
                                            k, cikan[3+k], veri[k*8 +: 8]);
                    end
                    crc_bek = crc8_bayt(crc_bek, cikan[3+k]);
                end
                if (cikan[3+uz] !== crc_bek) begin
                    hata = 1'b1;
                    $display("     -> yanit CRC: 0x%02h (0x%02h olmali)", cikan[3+uz], crc_bek);
                end
            end
            kontrol(!hata, ad);
        end
    endtask

    initial begin
        $display("=====================================================");
        $display(" TB-10 : uart_arayuz  (UCTAN UCA ENTEGRASYON)");
        $display("   BOLUCU=%0d, bit suresi=%0.0f ns", BOLUCU, BIT_SURESI);
        $display("=====================================================");

        seri_rx = 1'b1;
        yanit_basla = 1'b0; yanit_durum = 8'h00; yanit_uzunluk = 8'd0;
        tx_word = 32'd0;
        sifirla_n = 1'b0;
        repeat (20) @(posedge saat);
        @(negedge saat); sifirla_n = 1'b1;
        #(BIT_SURESI * 3);

        // ── T1: seri giristen 32 baytlik cerceve ──────────────────────────
        sayaclari_sifirla;
        v = {256'd0, VERI_A};
        seri_cerceve(8'h10, 8'd32, v, 1'b0);
        #(BIT_SURESI * 5);

        kontrol(komut_say == 1 && son_komut === 8'h10 && son_uzunluk === 8'd32,
                "T1a: Seri cerceve cozuldu (komut 0x10, uzunluk 32)");
        kontrol(alinan_say == 8, "T1b: 8 word alindi");
        uyum_hata = 1'b0;
        for (i = 0; i < 8; i = i + 1)
            if (alinan_word[i] !== VERI_A[i*32 +: 32]) uyum_hata = 1'b1;
        kontrol(!uyum_hata, "T1c: Word degerleri ve endianness dogru");

        // ── T2: ECHO — ayni word'leri geri gonder ─────────────────────────
        cikan_say = 0; tx_indis = 0;
        for (i = 0; i < 8; i = i + 1) tx_kaynak[i] = alinan_word[i];

        @(negedge saat);
        yanit_durum = 8'h00; yanit_uzunluk = 8'd32; yanit_basla = 1'b1;
        @(negedge saat);
        yanit_basla = 1'b0;

        // 36 bayt gonderilene kadar bekle
        wait (cikan_say == 36);
        #(BIT_SURESI * 2);
        yaniti_dogrula(8'h00, 8'd32, v, "T2: ECHO — 32 bayt geri dondu ve dogru");

        // ── T3: 64 baytlik cerceve (68 bayt yanit) ────────────────────────
        sayaclari_sifirla;
        v = {GY_MONT, GX_MONT};
        seri_cerceve(8'h01, 8'd64, v, 1'b0);
        #(BIT_SURESI * 5);
        kontrol(komut_say == 1 && alinan_say == 16,
                "T3a: 64 baytlik cerceve -> 16 word");
        uyum_hata = 1'b0;
        for (i = 0; i < 8; i = i + 1) begin
            if (alinan_word[i]   !== GX_MONT[i*32 +: 32]) uyum_hata = 1'b1;
            if (alinan_word[i+8] !== GY_MONT[i*32 +: 32]) uyum_hata = 1'b1;
        end
        kontrol(!uyum_hata, "T3b: GX_MONT || GY_MONT sirasi korundu");

        cikan_say = 0; tx_indis = 0;
        for (i = 0; i < 16; i = i + 1) tx_kaynak[i] = alinan_word[i];
        @(negedge saat);
        yanit_durum = 8'h00; yanit_uzunluk = 8'd64; yanit_basla = 1'b1;
        @(negedge saat);
        yanit_basla = 1'b0;
        wait (cikan_say == 68);
        #(BIT_SURESI * 2);
        yaniti_dogrula(8'h00, 8'd64, v,
                       "T3c: 68 baytlik yanit kayipsiz (TX FIFO tikanmadi)");

        // ── T4: verisiz komut ─────────────────────────────────────────────
        sayaclari_sifirla;
        seri_cerceve(8'h02, 8'd0, 512'd0, 1'b0);
        #(BIT_SURESI * 5);
        kontrol(komut_say == 1 && son_komut === 8'h02 && alinan_say == 0,
                "T4a: Verisiz komut -> komut var, word yok");

        cikan_say = 0;
        @(negedge saat);
        yanit_durum = 8'hE1; yanit_uzunluk = 8'd0; yanit_basla = 1'b1;
        @(negedge saat);
        yanit_basla = 1'b0;
        wait (cikan_say == 4);
        #(BIT_SURESI * 2);
        yaniti_dogrula(8'hE1, 8'd0, 512'd0, "T4b: Verisiz yanit (hata kodu) dogru");

        // ── T5: bozuk CRC ─────────────────────────────────────────────────
        sayaclari_sifirla;
        v = {256'd0, VERI_A};
        seri_cerceve(8'h10, 8'd32, v, 1'b1);
        #(BIT_SURESI * 5);
        kontrol(crc_hata_say == 1, "T5a: Bozuk CRC -> c_hata[1] darbesi");
        kontrol(alinan_say == 0 && komut_say == 0,
                "T5b: Bozuk cercevede word/komut cikisi YOK");

        // ── T6: ardisik cerceveler ────────────────────────────────────────
        sayaclari_sifirla;
        v = {256'd0, GX_MONT};
        seri_cerceve(8'h01, 8'd32, v, 1'b0);
        #(BIT_SURESI * 3);
        seri_cerceve(8'h01, 8'd32, v, 1'b0);
        #(BIT_SURESI * 5);
        kontrol(komut_say == 2 && alinan_say == 16,
                "T6a: Iki ardisik cerceve -> 2 komut, 16 word");
        uyum_hata = 1'b0;
        for (i = 0; i < 8; i = i + 1) begin
            if (alinan_word[i]   !== GX_MONT[i*32 +: 32]) uyum_hata = 1'b1;
            if (alinan_word[i+8] !== GX_MONT[i*32 +: 32]) uyum_hata = 1'b1;
        end
        kontrol(!uyum_hata, "T6b: Ardisik cercevelerde durum sizintisi yok");

        // ── Ozet ──────────────────────────────────────────────────────────
        $display("-----------------------------------------------------");
        if (hata_say == 0) $display(" TB-10 SONUC: TUM TESTLER GECTI");
        else               $display(" TB-10 SONUC: %0d TEST KALDI", hata_say);
        $display("=====================================================");
        $finish;
    end

    initial begin
        #200_000_000;
        $display(" TB-10 HATA: zaman asimi (simulasyon takildi)");
        $finish;
    end

endmodule
