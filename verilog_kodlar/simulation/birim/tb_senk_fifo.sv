// =============================================================================
// Testbench : tb_senk_fifo.sv                                      (İster TB-02)
// Hedef     : senk_fifo.v  (M-02)
// -----------------------------------------------------------------------------
// Kontrol edilenler:
//   T1. Reset sonrası boş, sayi=0
//   T2. Tek yazma/okuma - veri bütünlüğü
//   T3. Tam doldurma → c_dolu, sayi=DERINLIK
//   T4. TAŞMA KORUMASI: dolu iken yazma mevcut veriyi BOZMAZ
//   T5. Tam boşaltma - FIFO sırası (ilk giren ilk çıkar)
//   T6. BOŞALTMA KORUMASI: boş iken okuma sayacı eksiye düşürmez
//   T7. Sarma (wrap-around) - DERINLIK'in 3 katı veri geçir
//   T8. Eşzamanlı oku+yaz - sayi sabit kalmalı
//
// Koşturma (Vivado xsim):
//   xvlog -sv tb_senk_fifo.sv ../sources_1/senk_fifo.v
//   xelab -debug typical tb_senk_fifo -s tb && xsim tb -R
// =============================================================================

`timescale 1ns / 1ps

module tb_senk_fifo;

    localparam integer GENISLIK = 8;
    localparam integer DERINLIK = 8;      // küçük derinlik → sarma hızlı test edilir
    localparam real    SAAT_PERIYOT = 10.0;

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
    reg                     saat = 1'b0;
    reg                     sifirla_n;
    reg                     yaz;
    reg  [GENISLIK-1:0]     veri_gir;
    reg                     oku;
    wire [GENISLIK-1:0]     veri_cik;
    wire                    bos, dolu;
    wire [$clog2(DERINLIK):0] sayi;

    always #(SAAT_PERIYOT/2.0) saat = ~saat;

    senk_fifo #(.GENISLIK(GENISLIK), .DERINLIK(DERINLIK)) dut (
        .g_saat(saat), .g_sifirla_n(sifirla_n),
        .g_yaz(yaz), .g_veri(veri_gir),
        .g_oku(oku), .c_veri(veri_cik),
        .c_bos(bos), .c_dolu(dolu), .c_sayi(sayi)
    );

    // ── Yardımcı görevler ─────────────────────────────────────────────────
    task fifo_yaz(input [GENISLIK-1:0] d);
        begin
            @(negedge saat);
            yaz = 1'b1; veri_gir = d;
            @(negedge saat);
            yaz = 1'b0;
        end
    endtask

    task fifo_oku(output [GENISLIK-1:0] d);
        begin
            @(negedge saat);
            oku = 1'b1;
            @(negedge saat);
            oku = 1'b0;
            @(negedge saat);      // senkron okuma: c_veri 1 saat sonra geçerli
            d = veri_cik;
        end
    endtask

    // ── Ana test ──────────────────────────────────────────────────────────
    integer i;
    reg [GENISLIK-1:0] okunan;
    reg [GENISLIK-1:0] beklenen;
    reg                sira_hata;
    reg [$clog2(DERINLIK):0] sayi_once;

    initial begin
        $display("=====================================================");
        $display(" TB-02 : senk_fifo  (GENISLIK=%0d DERINLIK=%0d)", GENISLIK, DERINLIK);
        $display("=====================================================");

        yaz = 1'b0; oku = 1'b0; veri_gir = {GENISLIK{1'b0}};
        sifirla_n = 1'b0;
        repeat (5) @(posedge saat);
        @(negedge saat); sifirla_n = 1'b1;
        @(negedge saat);

        // ── T1 ────────────────────────────────────────────────────────────
        kontrol(bos === 1'b1 && dolu === 1'b0 && sayi === 0,
                "T1: Reset sonrasi bos, sayi=0");

        // ── T2 ────────────────────────────────────────────────────────────
        fifo_yaz(8'hA5);
        kontrol(bos === 1'b0 && sayi === 1, "T2a: Yazma sonrasi sayi=1, bos degil");
        fifo_oku(okunan);
        kontrol(okunan === 8'hA5, "T2b: Okunan veri yazilanla ayni (0xA5)");
        kontrol(bos === 1'b1 && sayi === 0, "T2c: Okuma sonrasi tekrar bos");

        // ── T3 ────────────────────────────────────────────────────────────
        for (i = 0; i < DERINLIK; i = i + 1)
            fifo_yaz(i[GENISLIK-1:0] + 8'h10);
        kontrol(dolu === 1'b1 && sayi === DERINLIK && bos === 1'b0,
                "T3: Tam doldurma -> dolu=1, sayi=DERINLIK");

        // ── T4: TAŞMA KORUMASI ────────────────────────────────────────────
        sayi_once = sayi;
        fifo_yaz(8'hFF);          // dolu iken yazma denemesi
        kontrol(sayi === sayi_once && dolu === 1'b1,
                "T4a: Dolu iken yazma sayaci degistirmedi");

        // ── T5: sıra kontrolü (ilk giren ilk çıkar) ───────────────────────
        sira_hata = 1'b0;
        for (i = 0; i < DERINLIK; i = i + 1) begin
            beklenen = i[GENISLIK-1:0] + 8'h10;
            fifo_oku(okunan);
            if (okunan !== beklenen) begin
                sira_hata = 1'b1;
                $display("     -> indis %0d: beklenen 0x%02h, okunan 0x%02h",
                         i, beklenen, okunan);
            end
        end
        kontrol(!sira_hata, "T4b/T5: FIFO sirasi dogru, tasan veri iceri sizmadi");
        kontrol(bos === 1'b1 && sayi === 0, "T5b: Bosaltma sonrasi bos");

        // ── T6: BOŞALTMA KORUMASI ─────────────────────────────────────────
        fifo_oku(okunan);         // boş iken okuma denemesi
        kontrol(sayi === 0 && bos === 1'b1,
                "T6: Bos iken okuma sayaci eksiye dusurmedi");

        // ── T7: sarma (wrap-around) ───────────────────────────────────────
        sira_hata = 1'b0;
        for (i = 0; i < DERINLIK*3; i = i + 1) begin
            fifo_yaz(i[GENISLIK-1:0] + 8'h40);
            fifo_oku(okunan);
            if (okunan !== (i[GENISLIK-1:0] + 8'h40)) begin
                sira_hata = 1'b1;
                $display("     -> sarma indis %0d: beklenen 0x%02h, okunan 0x%02h",
                         i, i[GENISLIK-1:0] + 8'h40, okunan);
            end
        end
        kontrol(!sira_hata, "T7: Sarma (wrap-around) dogru calisiyor");

        // ── T8: eşzamanlı oku + yaz ───────────────────────────────────────
        fifo_yaz(8'h11);
        fifo_yaz(8'h22);
        sayi_once = sayi;         // 2 olmali
        @(negedge saat);
        yaz = 1'b1; veri_gir = 8'h33; oku = 1'b1;   // ayni cevrimde
        @(negedge saat);
        yaz = 1'b0; oku = 1'b0;
        @(negedge saat);
        kontrol(sayi === sayi_once,
                "T8a: Eszamanli oku+yaz sayiyi degistirmedi");
        kontrol(veri_cik === 8'h11, "T8b: Eszamanli islemde dogru veri okundu");

        fifo_oku(okunan);
        kontrol(okunan === 8'h22, "T8c: Sonraki veri 0x22");
        fifo_oku(okunan);
        kontrol(okunan === 8'h33, "T8d: Eszamanli yazilan 0x33 kayitli");

        // ── Özet ──────────────────────────────────────────────────────────
        $display("-----------------------------------------------------");
        if (hata_say == 0) $display(" TB-02 SONUC: TUM TESTLER GECTI");
        else               $display(" TB-02 SONUC: %0d TEST KALDI", hata_say);
        $display("=====================================================");
        $finish;
    end

    initial begin
        #500_000;
        $display(" TB-02 HATA: zaman asimi");
        $finish;
    end

endmodule
