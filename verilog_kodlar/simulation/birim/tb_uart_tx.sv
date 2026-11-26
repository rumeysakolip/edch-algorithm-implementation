// =============================================================================
// Testbench : tb_uart_tx.sv                                        (İster TB-05)
// Hedef     : uart_tx.v  (M-05) + uart_baud_uretici.v (M-01)
// -----------------------------------------------------------------------------
// Kontrol edilenler:
//   T1. Boşta hat seviyesi '1' (reset dahil)
//   T2. Çerçeve yapısı: start='0', 8 veri LSB-first, stop='1'
//   T3. Bit süreleri nominal değerden < %1 sapmalı
//   T4. c_mesgul gönderim boyunca yüksek, bitince düşük
//   T5. MEŞGUL KİLİDİ: c_mesgul yüksekken gelen g_basla veriyi BOZMAZ
//   T6. Ardışık baytlar - 64 bayt kayıpsız
//   T7. Reset sırasında hat '1' kalıyor (break üretilmiyor)
//
// Koşturma (Vivado xsim):
//   xvlog -sv tb_uart_tx.sv ../sources_1/uart_tx.v ../sources_1/uart_baud_uretici.v
//   xelab -debug typical tb_uart_tx -s tb && xsim tb -R
// =============================================================================

`timescale 1ns / 1ps

module tb_uart_tx;

    localparam integer SAAT_HZ    = 100_000_000;
    localparam integer ORNEKLEME  = 16;
    localparam integer BOLUCU     = 4;
    localparam integer BAUD_HIZI  = SAAT_HZ/(BOLUCU*ORNEKLEME);
    localparam real    SAAT_PERIYOT = 10.0;
    localparam real    BIT_SURESI   = BOLUCU * ORNEKLEME * SAAT_PERIYOT;  // 640 ns

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
    reg        saat = 1'b0;
    reg        sifirla_n;
    reg  [7:0] tx_veri;
    reg        tx_basla;
    wire       ort_tik;
    wire       seri;
    wire       mesgul;

    always #(SAAT_PERIYOT/2.0) saat = ~saat;

    uart_baud_uretici #(
        .SAAT_HZ(SAAT_HZ), .BAUD_HIZI(BAUD_HIZI), .ORNEKLEME(ORNEKLEME)
    ) baud_inst (
        .g_saat(saat), .g_sifirla_n(sifirla_n), .c_ort_tik(ort_tik)
    );

    uart_tx #(.ORNEKLEME(ORNEKLEME)) dut (
        .g_saat(saat), .g_sifirla_n(sifirla_n),
        .g_veri(tx_veri), .g_basla(tx_basla), .g_ort_tik(ort_tik),
        .c_seri(seri), .c_mesgul(mesgul)
    );

    // ── Gönderim tetikleyici ──────────────────────────────────────────────
    task gonder(input [7:0] b);
        begin
            @(negedge saat);
            tx_veri = b; tx_basla = 1'b1;
            @(negedge saat);
            tx_basla = 1'b0;
        end
    endtask

    // ── Bağımsız çözücü: hattı örnekleyip baytı geri kurar ────────────────
    //   uart_rx'ten BAGIMSIZ olmasi kasitlidir; iki modulun ayni hatayi
    //   paylasmasi ihtimalini ortadan kaldirir.
    // ÖLÇÜM MESAFESİ - DİKKAT:
    //   t_start = start bitinin DUSEN KENARI (cerceve baslangici, t=0)
    //   t_stop  = stop bitinin ORTASI
    //   Cerceve: start [0..1], veri0 [1..2] ... veri7 [8..9], stop [9..10]
    //   Stop bitinin ortasi = 9.5 bit suresi.  Bolen 9.0 DEGIL, 9.5'tir.
    //   (Ilk surumde 9.0 yazilmisti; %5.56 sahte sapma uretiyordu.)
    localparam real OLCUM_BIT_SAYISI = 9.5;

    task hat_coz(output [7:0] cozulen, output cerceve_ok, output real olculen_bit);
        real t_start, t_stop;
        integer i;
        begin
            cerceve_ok = 1'b1;
            @(negedge seri);              // start bitinin dusen kenari  (t = 0)
            t_start = $realtime;
            #(BIT_SURESI * 1.5);          // veri0'in ortasi              (t = 1.5)
            for (i = 0; i < 8; i = i + 1) begin
                cozulen[i] = seri;        // LSB-first
                if (i < 7) #(BIT_SURESI);
            end                           // veri7'nin ortasi             (t = 8.5)
            #(BIT_SURESI);                // stop bitinin ortasi          (t = 9.5)
            if (seri !== 1'b1) cerceve_ok = 1'b0;
            t_stop = $realtime;
            olculen_bit = (t_stop - t_start) / OLCUM_BIT_SAYISI;
        end
    endtask

    // ── Ana test ──────────────────────────────────────────────────────────
    reg [7:0] cozulen;
    reg       cerceve_ok;
    real      olculen_bit, sapma;
    integer   i;
    reg       dizi_hata;
    reg       reset_hat_hata;

    // T1/T7: reset sirasinda hat izleme
    initial begin
        reset_hat_hata = 1'b0;
        forever begin
            @(posedge saat);
            if (!sifirla_n && seri !== 1'b1) reset_hat_hata = 1'b1;
        end
    end

    initial begin
        $display("=====================================================");
        $display(" TB-05 : uart_tx  (BOLUCU=%0d, bit suresi=%0.0f ns)", BOLUCU, BIT_SURESI);
        $display("=====================================================");

        tx_veri = 8'h00; tx_basla = 1'b0;
        sifirla_n = 1'b0;
        repeat (20) @(posedge saat);

        kontrol(reset_hat_hata == 1'b0 && seri === 1'b1,
                "T1/T7: Reset sirasinda hat '1' (break uretilmiyor)");

        @(negedge saat); sifirla_n = 1'b1;
        repeat (10) @(posedge saat);
        kontrol(seri === 1'b1 && mesgul === 1'b0, "T1b: Bosta hat '1', mesgul dusuk");

        // ── T2 + T3: cerceve yapisi ve bit suresi ─────────────────────────
        fork
            gonder(8'hA5);
            hat_coz(cozulen, cerceve_ok, olculen_bit);
        join
        kontrol(cozulen === 8'hA5, "T2a: 0xA5 dogru cozuldu (LSB-first)");
        if (cozulen !== 8'hA5) $display("     -> cozulen 0x%02h", cozulen);
        kontrol(cerceve_ok, "T2b: Stop biti '1'");

        sapma = ((olculen_bit - BIT_SURESI) / BIT_SURESI) * 100.0;
        $display("  Olculen bit suresi: %0.2f ns (nominal %0.0f ns, sapma %0.3f %%)",
                 olculen_bit, BIT_SURESI, sapma);
        kontrol(sapma < 1.0 && sapma > -1.0, "T3: Bit suresi sapmasi < %1");

        #(BIT_SURESI * 2);

        // ── T4: mesgul davranisi ──────────────────────────────────────────
        @(negedge saat);
        tx_veri = 8'h3C; tx_basla = 1'b1;
        @(negedge saat);
        tx_basla = 1'b0;
        @(negedge saat);
        kontrol(mesgul === 1'b1, "T4a: Gonderim baslayinca c_mesgul yukseldi");
        #(BIT_SURESI * 11);
        kontrol(mesgul === 1'b0, "T4b: Gonderim bitince c_mesgul dustu");

        // ── T5: MESGUL KILIDI ─────────────────────────────────────────────
        //   0x11 gonderilirken 0xEE ile ikinci bir g_basla verilir.
        //   Hatta 0x11 GORULMELI, 0xEE ile bozulmamali.
        fork
            begin
                gonder(8'h11);
                #(BIT_SURESI * 2);
                gonder(8'hEE);        // mesgulken -> yok sayilmali
            end
            hat_coz(cozulen, cerceve_ok, olculen_bit);
        join
        kontrol(cozulen === 8'h11,
                "T5: Mesgulken gelen g_basla gonderilen baytI BOZMADI");
        if (cozulen !== 8'h11) $display("     -> cozulen 0x%02h (0xEE sizmis olabilir)", cozulen);

        // hattin bosalmasini bekle
        wait (mesgul === 1'b0);
        #(BIT_SURESI * 3);

        // ── T6: ardisik 64 bayt ───────────────────────────────────────────
        dizi_hata = 1'b0;
        for (i = 0; i < 64; i = i + 1) begin
            fork
                begin
                    wait (mesgul === 1'b0);
                    gonder(i[7:0] ^ 8'h5A);
                end
                hat_coz(cozulen, cerceve_ok, olculen_bit);
            join
            if (cozulen !== (i[7:0] ^ 8'h5A) || !cerceve_ok) begin
                dizi_hata = 1'b1;
                $display("     -> bayt %0d: beklenen 0x%02h, cozulen 0x%02h",
                         i, i[7:0] ^ 8'h5A, cozulen);
            end
            wait (mesgul === 1'b0);
            #(BIT_SURESI/2);
        end
        kontrol(!dizi_hata, "T6: 64 ardisik bayt kayipsiz gonderildi");

        // ── Özet ──────────────────────────────────────────────────────────
        $display("-----------------------------------------------------");
        if (hata_say == 0) $display(" TB-05 SONUC: TUM TESTLER GECTI");
        else               $display(" TB-05 SONUC: %0d TEST KALDI", hata_say);
        $display("=====================================================");
        $finish;
    end

    initial begin
        #50_000_000;
        $display(" TB-05 HATA: zaman asimi");
        $finish;
    end

endmodule
