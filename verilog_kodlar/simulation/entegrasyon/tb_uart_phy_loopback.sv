// =============================================================================
// Testbench : tb_uart_phy_loopback.sv                              (İster TB-08)
// Hedef     : uart_tx.v + uart_rx.v + uart_baud_uretici.v  (M-01, M-04, M-05)
// -----------------------------------------------------------------------------
// Bu ilk ENTEGRASYON testidir. Verici çıkışı doğrudan alıcı girişine bağlanır
// (c_seri -> g_seri). Katman 1'in kapanış kapısıdır.
//
// Kontrol edilenler:
//   T1. Tek bayt gidiş-dönüş
//   T2. 256 baytın tamamı (0x00..0xFF) kayıpsız
//   T3. Sırt sırta gönderim - TX boşalır boşalmaz yeni bayt
//   T4. Sözde-rastgele 512 bayt akışı
//   T5. Alım sırasında hiç çerçeve hatası oluşmadı
//   T6. Gönderilen ve alınan bayt SAYILARI eşit (kayıp/tekrar yok)
//
// NOT: TX ve RX AYNI baud üreticisini paylaşır (tasarım kararı). Bu, gerçek
//      dünyadaki iki bağımsız osilatör durumunu modellemez; baud toleransı
//      TB-04'te ayrıca sınanmıştır.
//
// Koşturma (Vivado xsim):
//   xvlog -sv tb_uart_phy_loopback.sv ../sources_1/uart_tx.v \
//         ../sources_1/uart_rx.v ../sources_1/uart_baud_uretici.v
//   xelab -debug typical tb_uart_phy_loopback -s tb && xsim tb -R
// =============================================================================

`timescale 1ns / 1ps

module tb_uart_phy_loopback;

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

    // ── Ortak saat / reset ────────────────────────────────────────────────
    reg saat = 1'b0;
    reg sifirla_n;
    always #(SAAT_PERIYOT/2.0) saat = ~saat;

    wire ort_tik;
    uart_baud_uretici #(
        .SAAT_HZ(SAAT_HZ), .BAUD_HIZI(BAUD_HIZI), .ORNEKLEME(ORNEKLEME)
    ) baud_inst (
        .g_saat(saat), .g_sifirla_n(sifirla_n), .c_ort_tik(ort_tik)
    );

    // ── TX ────────────────────────────────────────────────────────────────
    reg  [7:0] tx_veri;
    reg        tx_basla;
    wire       hat_w;          // LOOPBACK HATTI
    wire       tx_mesgul;

    uart_tx #(.ORNEKLEME(ORNEKLEME)) tx_inst (
        .g_saat(saat), .g_sifirla_n(sifirla_n),
        .g_veri(tx_veri), .g_basla(tx_basla), .g_ort_tik(ort_tik),
        .c_seri(hat_w), .c_mesgul(tx_mesgul)
    );

    // ── RX ────────────────────────────────────────────────────────────────
    wire [7:0] rx_veri;
    wire       rx_gecerli;
    wire       rx_cerceve_hata;

    uart_rx #(.ORNEKLEME(ORNEKLEME)) rx_inst (
        .g_saat(saat), .g_sifirla_n(sifirla_n),
        .g_seri(hat_w), .g_ort_tik(ort_tik),      // <<< LOOPBACK
        .c_veri(rx_veri), .c_gecerli(rx_gecerli), .c_cerceve_hata(rx_cerceve_hata)
    );

    // ── İzleyiciler ───────────────────────────────────────────────────────
    reg [7:0] alinan_kuyruk [0:1023];
    integer   alinan_yaz = 0;
    integer   alinan_oku = 0;
    integer   cerceve_hata_say = 0;
    integer   gonderilen_say = 0;

    always @(posedge saat) begin
        if (rx_gecerli) begin
            alinan_kuyruk[alinan_yaz] <= rx_veri;
            alinan_yaz <= alinan_yaz + 1;
        end
        if (rx_cerceve_hata) cerceve_hata_say <= cerceve_hata_say + 1;
    end

    // ── Gönderim görevi (meşgul beklemeli) ────────────────────────────────
    task gonder(input [7:0] b);
        begin
            wait (tx_mesgul === 1'b0);
            @(negedge saat);
            tx_veri = b; tx_basla = 1'b1;
            @(negedge saat);
            tx_basla = 1'b0;
            gonderilen_say = gonderilen_say + 1;
        end
    endtask

    // ── Ana test ──────────────────────────────────────────────────────────
    integer i;
    reg     dizi_hata;
    reg [7:0] beklenen;
    reg [15:0] lfsr;

    initial begin
        $display("=====================================================");
        $display(" TB-08 : UART PHY LOOPBACK  (Katman 1 kapanis kapisi)");
        $display("   BOLUCU=%0d, bit suresi=%0.0f ns", BOLUCU, BIT_SURESI);
        $display("=====================================================");

        tx_veri = 8'h00; tx_basla = 1'b0;
        sifirla_n = 1'b0;
        repeat (20) @(posedge saat);
        @(negedge saat); sifirla_n = 1'b1;
        #(BIT_SURESI * 2);

        // ── T1: tek bayt ──────────────────────────────────────────────────
        gonder(8'hA5);
        wait (alinan_yaz == 1);
        #(BIT_SURESI);
        kontrol(alinan_kuyruk[0] === 8'hA5, "T1: Tek bayt gidis-donus (0xA5)");

        // ── T2: 0x00..0xFF tamami ─────────────────────────────────────────
        alinan_yaz = 0; alinan_oku = 0; gonderilen_say = 0;
        for (i = 0; i < 256; i = i + 1) gonder(i[7:0]);
        wait (alinan_yaz == 256);
        #(BIT_SURESI * 2);

        dizi_hata = 1'b0;
        for (i = 0; i < 256; i = i + 1) begin
            if (alinan_kuyruk[i] !== i[7:0]) begin
                dizi_hata = 1'b1;
                if (i < 8) $display("     -> indis %0d: beklenen 0x%02h, alinan 0x%02h",
                                    i, i[7:0], alinan_kuyruk[i]);
            end
        end
        kontrol(!dizi_hata, "T2: 0x00..0xFF tamami kayipsiz gidis-donus");

        // ── T3/T6: sirt sirta gonderim, sayi esitligi ─────────────────────
        kontrol(gonderilen_say == 256 && alinan_yaz == 256,
                "T3/T6: Gonderilen ve alinan bayt sayilari esit (256)");

        // ── T4: sozde-rastgele akis ───────────────────────────────────────
        alinan_yaz = 0; gonderilen_say = 0;
        lfsr = 16'hACE1;
        dizi_hata = 1'b0;

        for (i = 0; i < 512; i = i + 1) begin
            gonder(lfsr[7:0]);
            lfsr = {lfsr[14:0], lfsr[15]^lfsr[13]^lfsr[12]^lfsr[10]};
        end
        wait (alinan_yaz == 512);
        #(BIT_SURESI * 2);

        lfsr = 16'hACE1;
        for (i = 0; i < 512; i = i + 1) begin
            beklenen = lfsr[7:0];
            if (alinan_kuyruk[i] !== beklenen) begin
                dizi_hata = 1'b1;
                if (i < 8) $display("     -> indis %0d: beklenen 0x%02h, alinan 0x%02h",
                                    i, beklenen, alinan_kuyruk[i]);
            end
            lfsr = {lfsr[14:0], lfsr[15]^lfsr[13]^lfsr[12]^lfsr[10]};
        end
        kontrol(!dizi_hata, "T4: 512 baytlik sozde-rastgele akis kayipsiz");

        // ── T5: cerceve hatasi olmamali ───────────────────────────────────
        kontrol(cerceve_hata_say == 0,
                "T5: Tum test boyunca cerceve hatasi olusmadi");

        // ── Özet ──────────────────────────────────────────────────────────
        $display("-----------------------------------------------------");
        $display(" Toplam gonderilen : %0d bayt", 256 + 512 + 1);
        $display(" Cerceve hatasi    : %0d", cerceve_hata_say);
        if (hata_say == 0) begin
            $display(" TB-08 SONUC: TUM TESTLER GECTI");
            $display(" >>> KATMAN 1 KAPANDI - Katman 2'ye gecilebilir.");
        end else begin
            $display(" TB-08 SONUC: %0d TEST KALDI", hata_say);
            $display(" >>> Katman 2'ye GECMEYIN.");
        end
        $display("=====================================================");
        $finish;
    end

    initial begin
        #200_000_000;
        $display(" TB-08 HATA: zaman asimi");
        $finish;
    end

endmodule
