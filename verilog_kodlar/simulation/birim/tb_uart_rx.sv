// =============================================================================
// Testbench : tb_uart_rx.sv                                        (İster TB-04)
// Hedef     : uart_rx.v  (M-04) + uart_baud_uretici.v (M-01)
// -----------------------------------------------------------------------------
// Kontrol edilenler:
//   T1. Temel alım - 0x00, 0xFF, 0xA5, 0x5A
//   T2. Ardışık baytlarda kayıp yok (256 baytın tamamı)
//   T3. Baud sapması +%2  → hatasız alım
//   T4. Baud sapması -%2  → hatasız alım
//   T5. Bozuk stop biti   → c_cerceve_hata YÜKSELIR, c_gecerli BASTIRILIR
//   T6. Gürültü darbesi reddi (yarım bitten kısa düşük darbe bayt üretmemeli)
//   T7. Çerçeve hatası sonrası FSM kilitlenmiyor (sonraki bayt alınabiliyor)
//
// NOT: Simülasyon süresi için BAUD_HIZI yükseltilmiştir (BOLUCU=4).
//      Bu, FSM mantığını değiştirmez; yalnızca sim süresini kısaltır.
//
// Koşturma (Vivado xsim):
//   xvlog -sv tb_uart_rx.sv ../sources_1/uart_rx.v ../sources_1/uart_baud_uretici.v
//   xelab -debug typical tb_uart_rx -s tb && xsim tb -R
// =============================================================================

`timescale 1ns / 1ps

module tb_uart_rx;

    localparam integer SAAT_HZ    = 100_000_000;
    localparam integer ORNEKLEME  = 16;
    localparam integer BOLUCU     = 4;                          // sim hizlandirma
    localparam integer BAUD_HIZI  = SAAT_HZ/(BOLUCU*ORNEKLEME); // 1_562_500
    localparam real    SAAT_PERIYOT = 10.0;                     // ns

    // Nominal bit süresi (ns): BOLUCU * ORNEKLEME * saat periyodu
    localparam real BIT_SURESI = BOLUCU * ORNEKLEME * SAAT_PERIYOT;   // 640 ns

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
    reg        seri = 1'b1;          // bosta '1'
    wire       ort_tik;
    wire [7:0] rx_veri;
    wire       rx_gecerli;
    wire       rx_cerceve_hata;

    always #(SAAT_PERIYOT/2.0) saat = ~saat;

    uart_baud_uretici #(
        .SAAT_HZ(SAAT_HZ), .BAUD_HIZI(BAUD_HIZI), .ORNEKLEME(ORNEKLEME)
    ) baud_inst (
        .g_saat(saat), .g_sifirla_n(sifirla_n), .c_ort_tik(ort_tik)
    );

    uart_rx #(.ORNEKLEME(ORNEKLEME)) dut (
        .g_saat(saat), .g_sifirla_n(sifirla_n),
        .g_seri(seri), .g_ort_tik(ort_tik),
        .c_veri(rx_veri), .c_gecerli(rx_gecerli), .c_cerceve_hata(rx_cerceve_hata)
    );

    // ── Alınan baytları yakala ────────────────────────────────────────────
    reg [7:0] son_veri;
    integer   alinan_say = 0;
    integer   hata_darbe_say = 0;

    always @(posedge saat) begin
        if (rx_gecerli) begin
            son_veri   <= rx_veri;
            alinan_say <= alinan_say + 1;
        end
        if (rx_cerceve_hata) hata_darbe_say <= hata_darbe_say + 1;
    end

    // ── Uyarım görevleri (bit seviyesi) ───────────────────────────────────
    //   yuzde_sapma: gonderici baud hatasi simulasyonu (+2 => %2 hizli)
    task bayt_gonder(input [7:0] b, input real yuzde_sapma);
        real bit_ns;
        integer i;
        begin
            bit_ns = BIT_SURESI * (100.0 / (100.0 + yuzde_sapma));
            seri = 1'b0;  #(bit_ns);                 // start
            for (i = 0; i < 8; i = i + 1) begin
                seri = b[i];  #(bit_ns);             // LSB-first
            end
            seri = 1'b1;  #(bit_ns);                 // stop
        end
    endtask

    task bayt_gonder_bozuk_stop(input [7:0] b);
        integer i;
        begin
            seri = 1'b0;  #(BIT_SURESI);
            for (i = 0; i < 8; i = i + 1) begin
                seri = b[i];  #(BIT_SURESI);
            end
            seri = 1'b0;  #(BIT_SURESI);             // HATALI stop ('0')
            seri = 1'b1;  #(BIT_SURESI);             // hatti toparla
        end
    endtask

    // ── Ana test ──────────────────────────────────────────────────────────
    integer i;
    integer sayac_once;
    reg     dizi_hata;

    initial begin
        $display("=====================================================");
        $display(" TB-04 : uart_rx  (BOLUCU=%0d, bit suresi=%0.0f ns)", BOLUCU, BIT_SURESI);
        $display("=====================================================");

        sifirla_n = 1'b0;
        repeat (10) @(posedge saat);
        @(negedge saat); sifirla_n = 1'b1;
        #(BIT_SURESI * 2);

        // ── T1: temel alim ────────────────────────────────────────────────
        bayt_gonder(8'hA5, 0.0);  #(BIT_SURESI);
        kontrol(son_veri === 8'hA5 && alinan_say == 1, "T1a: 0xA5 alindi");
        if (son_veri !== 8'hA5) $display("     -> okunan 0x%02h", son_veri);

        bayt_gonder(8'h5A, 0.0);  #(BIT_SURESI);
        kontrol(son_veri === 8'h5A, "T1b: 0x5A alindi");

        bayt_gonder(8'h00, 0.0);  #(BIT_SURESI);
        kontrol(son_veri === 8'h00, "T1c: 0x00 alindi (tum bitler sifir)");

        bayt_gonder(8'hFF, 0.0);  #(BIT_SURESI);
        kontrol(son_veri === 8'hFF, "T1d: 0xFF alindi (tum bitler bir)");

        kontrol(hata_darbe_say == 0, "T1e: Temiz alimda cerceve hatasi yok");

        // ── T2: 256 baytin tamami, kayipsiz ───────────────────────────────
        alinan_say = 0;
        dizi_hata  = 1'b0;
        for (i = 0; i < 256; i = i + 1) begin
            bayt_gonder(i[7:0], 0.0);
            #(BIT_SURESI/4);
            if (son_veri !== i[7:0]) begin
                dizi_hata = 1'b1;
                $display("     -> bayt %0d: beklenen 0x%02h, alinan 0x%02h",
                         i, i[7:0], son_veri);
            end
        end
        kontrol(!dizi_hata && alinan_say == 256,
                "T2: 256 ardisik bayt kayipsiz alindi");

        // ── T3: +%2 baud sapmasi ──────────────────────────────────────────
        alinan_say = 0; dizi_hata = 1'b0;
        for (i = 0; i < 32; i = i + 1) begin
            bayt_gonder(i[7:0] ^ 8'h5A, +2.0);
            #(BIT_SURESI/2);
            if (son_veri !== (i[7:0] ^ 8'h5A)) dizi_hata = 1'b1;
        end
        kontrol(!dizi_hata && alinan_say == 32, "T3: +%2 baud sapmasinda hatasiz");

        // ── T4: -%2 baud sapmasi ──────────────────────────────────────────
        alinan_say = 0; dizi_hata = 1'b0;
        for (i = 0; i < 32; i = i + 1) begin
            bayt_gonder(i[7:0] ^ 8'hA5, -2.0);
            #(BIT_SURESI/2);
            if (son_veri !== (i[7:0] ^ 8'hA5)) dizi_hata = 1'b1;
        end
        kontrol(!dizi_hata && alinan_say == 32, "T4: -%2 baud sapmasinda hatasiz");

        // ── T5: bozuk stop biti ───────────────────────────────────────────
        alinan_say     = 0;
        hata_darbe_say = 0;
        bayt_gonder_bozuk_stop(8'h3C);
        #(BIT_SURESI);
        kontrol(hata_darbe_say == 1, "T5a: Bozuk stop -> c_cerceve_hata yukseldi");
        kontrol(alinan_say == 0,     "T5b: Bozuk bayt YUKARI KATMANA VERILMEDI");

        // ── T7: hata sonrasi kilitlenme yok ───────────────────────────────
        alinan_say = 0;
        bayt_gonder(8'h7E, 0.0);
        #(BIT_SURESI);
        kontrol(alinan_say == 1 && son_veri === 8'h7E,
                "T7: Cerceve hatasi sonrasi FSM toparlandi");

        // ── T6: gurultu darbesi reddi ─────────────────────────────────────
        //   Yarim bitten kisa bir dusuk darbe start olarak kabul edilmemeli.
        alinan_say     = 0;
        hata_darbe_say = 0;
        seri = 1'b0;  #(BIT_SURESI/8);      // yarim bitin dortte biri
        seri = 1'b1;  #(BIT_SURESI * 3);
        kontrol(alinan_say == 0 && hata_darbe_say == 0,
                "T6: Kisa gurultu darbesi sahte bayt uretmedi");

        // Gurultu sonrasi normal alim hala calisiyor mu?
        bayt_gonder(8'hC3, 0.0);
        #(BIT_SURESI);
        kontrol(alinan_say == 1 && son_veri === 8'hC3,
                "T6b: Gurultu sonrasi normal alim devam ediyor");

        // ── Özet ──────────────────────────────────────────────────────────
        $display("-----------------------------------------------------");
        if (hata_say == 0) $display(" TB-04 SONUC: TUM TESTLER GECTI");
        else               $display(" TB-04 SONUC: %0d TEST KALDI", hata_say);
        $display("=====================================================");
        $finish;
    end

    initial begin
        #50_000_000;
        $display(" TB-04 HATA: zaman asimi");
        $finish;
    end

endmodule
