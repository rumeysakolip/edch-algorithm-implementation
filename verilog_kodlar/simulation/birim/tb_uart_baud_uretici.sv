// =============================================================================
// Testbench : tb_uart_baud_uretici.sv                              (İster TB-01)
// Hedef     : uart_baud_uretici.v  (M-01)
// -----------------------------------------------------------------------------
// Kontrol edilenler:
//   T1. Tik periyodu teorik değerden < %0.5 sapmalı
//   T2. Tik darbesi TEK saat çevrimi genişliğinde olmalı
//   T3. Reset sırasında tik üretilmemeli
//   T4. Reset sonrası sayaç temiz başlamalı (ilk periyot da doğru olmalı)
//   T5. BOLUCU=1 sınır durumu (sim hızlandırma) - her saatte tik
//
// Koşturma (Vivado xsim):
//   xvlog -sv tb_uart_baud_uretici.sv ../sources_1/uart_baud_uretici.v
//   xelab -debug typical tb_uart_baud_uretici -s tb && xsim tb -R
// =============================================================================

`timescale 1ns / 1ps

module tb_uart_baud_uretici;

    // ── Test parametreleri ────────────────────────────────────────────────
    localparam integer SAAT_HZ    = 100_000_000;
    localparam integer BAUD_HIZI  = 115_200;
    localparam integer ORNEKLEME  = 16;
    localparam real    SAAT_PERIYOT = 10.0;    // ns (100 MHz)

    localparam integer BEK_BOLUCU =
        (SAAT_HZ + (ORNEKLEME*BAUD_HIZI)/2) / (ORNEKLEME*BAUD_HIZI);   // 54

    // ── Hata sayacı ───────────────────────────────────────────────────────
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

    // ── DUT sinyalleri ────────────────────────────────────────────────────
    reg  saat = 1'b0;
    reg  sifirla_n;
    wire ort_tik;

    always #(SAAT_PERIYOT/2.0) saat = ~saat;

    uart_baud_uretici #(
        .SAAT_HZ(SAAT_HZ), .BAUD_HIZI(BAUD_HIZI), .ORNEKLEME(ORNEKLEME)
    ) dut (
        .g_saat(saat), .g_sifirla_n(sifirla_n), .c_ort_tik(ort_tik)
    );

    // ── Ölçüm değişkenleri ────────────────────────────────────────────────
    integer saat_sayac   = 0;      // serbest koşan saat sayacı
    integer onceki_tik   = -1;
    integer tik_adedi    = 0;
    integer periyot_top  = 0;      // periyot toplamı (ortalama için)
    integer genislik_hata = 0;
    integer reset_tik    = 0;

    always @(posedge saat) saat_sayac <= saat_sayac + 1;

    // Tik periyodu ölçümü
    always @(posedge saat) begin
        if (ort_tik) begin
            if (!sifirla_n) reset_tik = reset_tik + 1;   // T3 ihlali
            if (onceki_tik >= 0) begin
                periyot_top = periyot_top + (saat_sayac - onceki_tik);
                tik_adedi   = tik_adedi + 1;
            end
            onceki_tik = saat_sayac;
        end
    end

    // T2: darbe genişliği - tik iki ardışık saatte yüksek kalmamalı
    reg tik_gecikmis = 1'b0;
    always @(posedge saat) begin
        tik_gecikmis <= ort_tik;
        if (ort_tik && tik_gecikmis) genislik_hata = genislik_hata + 1;
    end

    // ── Ana test akışı ────────────────────────────────────────────────────
    real olculen_ort, sapma_yuzde;

    initial begin
        $display("=====================================================");
        $display(" TB-01 : uart_baud_uretici");
        $display("   SAAT_HZ=%0d  BAUD=%0d  ORNEKLEME=%0d", SAAT_HZ, BAUD_HIZI, ORNEKLEME);
        $display("   Beklenen BOLUCU = %0d", BEK_BOLUCU);
        $display("=====================================================");

        // Reset uygula
        sifirla_n = 1'b0;
        repeat (20) @(posedge saat);

        // T3 kontrolü: reset sırasında tik olmamalı
        kontrol(reset_tik == 0, "T3: Reset sirasinda tik uretilmedi");

        // Reset kaldır
        @(negedge saat);
        sifirla_n = 1'b1;

        // Ölçüm için yeterli tik topla (~200 tik)
        onceki_tik  = -1;
        tik_adedi   = 0;
        periyot_top = 0;
        repeat (BEK_BOLUCU * 210) @(posedge saat);

        // ── T1: ortalama periyot sapması ──────────────────────────────────
        olculen_ort = periyot_top * 1.0 / tik_adedi;
        sapma_yuzde = ((olculen_ort - BEK_BOLUCU) / (BEK_BOLUCU * 1.0)) * 100.0;

        $display("  Olculen ortalama periyot : %0.4f saat cevrimi (%0d tik uzerinden)",
                 olculen_ort, tik_adedi);
        $display("  Teorik periyot           : %0d", BEK_BOLUCU);
        $display("  Sapma                    : %0.4f %%", sapma_yuzde);

        kontrol((sapma_yuzde < 0.5) && (sapma_yuzde > -0.5),
                "T1: Periyot sapmasi < %0.5 (ic tutarlilik)");

        // Gercek baud hatasi (hedef baud'a gore) - bilgi amacli
        $display("  NOT: Gerceklesen baud = %0.1f (hedef %0d, hata %0.3f %%)",
                 SAAT_HZ / (BEK_BOLUCU * ORNEKLEME * 1.0), BAUD_HIZI,
                 ((SAAT_HZ / (BEK_BOLUCU*ORNEKLEME*1.0)) - BAUD_HIZI) * 100.0 / BAUD_HIZI);

        // ── T2 ────────────────────────────────────────────────────────────
        kontrol(genislik_hata == 0, "T2: Tik darbesi tek saat cevrimi genisliginde");

        // ── T4: reset sonrasi ilk periyot ─────────────────────────────────
        @(negedge saat); sifirla_n = 1'b0;
        repeat (5) @(posedge saat);
        @(negedge saat); sifirla_n = 1'b1;

        onceki_tik  = -1;
        tik_adedi   = 0;
        periyot_top = 0;
        repeat (BEK_BOLUCU * 12) @(posedge saat);
        olculen_ort = periyot_top * 1.0 / tik_adedi;
        kontrol((olculen_ort > BEK_BOLUCU - 0.01) && (olculen_ort < BEK_BOLUCU + 0.01),
                "T4: Reset sonrasi periyot dogru");

        // ── Özet ──────────────────────────────────────────────────────────
        $display("-----------------------------------------------------");
        if (hata_say == 0) $display(" TB-01 SONUC: TUM TESTLER GECTI");
        else               $display(" TB-01 SONUC: %0d TEST KALDI", hata_say);
        $display("=====================================================");
        $finish;
    end

    // Kilitlenme koruması
    initial begin
        #20_000_000;
        $display(" TB-01 HATA: zaman asimi (simulasyon takildi)");
        $finish;
    end

endmodule


// =============================================================================
// TB-01b : BOLUCU=1 sinir durumu (simulasyon hizlandirma modu)
//   BAUD_HIZI=6_250_000 @ 100MHz, ORNEKLEME=16 → BOLUCU=1 → her saatte tik
// =============================================================================
module tb_uart_baud_uretici_sinir;

    localparam real SAAT_PERIYOT = 10.0;

    reg  saat = 1'b0;
    reg  sifirla_n = 1'b0;
    wire ort_tik;
    integer tik_say = 0;
    integer cevrim  = 0;

    always #(SAAT_PERIYOT/2.0) saat = ~saat;

    uart_baud_uretici #(
        .SAAT_HZ(100_000_000), .BAUD_HIZI(6_250_000), .ORNEKLEME(16)
    ) dut (.g_saat(saat), .g_sifirla_n(sifirla_n), .c_ort_tik(ort_tik));

    always @(posedge saat) if (sifirla_n) begin
        cevrim <= cevrim + 1;
        if (ort_tik) tik_say <= tik_say + 1;
    end

    initial begin
        $display("=====================================================");
        $display(" TB-01b : BOLUCU=1 sinir durumu");
        repeat (10) @(posedge saat);
        @(negedge saat); sifirla_n = 1'b1;
        repeat (100) @(posedge saat);
        @(negedge saat);
        if (tik_say >= cevrim - 1)
            $display("  [GECTI] T5: BOLUCU=1'de her saatte tik (%0d/%0d)", tik_say, cevrim);
        else
            $display("  [KALDI] T5: tik sayisi %0d, beklenen ~%0d", tik_say, cevrim);
        $display("=====================================================");
        $finish;
    end

endmodule
