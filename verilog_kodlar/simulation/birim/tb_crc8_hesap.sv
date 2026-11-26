// =============================================================================
// Testbench : tb_crc8_hesap.sv                                     (İster TB-03)
// Hedef     : crc8_hesap.v  (M-03)
// -----------------------------------------------------------------------------
// Kontrol edilenler:
//   T1. Standart kontrol vektörü: "123456789" → 0xF4
//   T2. Tek bayt vektörleri (0x00 → 0x00, 0xFF → 0xF3)
//   T3. Çerçeve başlığı örneği: A5 01 40 → 0x5A
//   T4. Ardışık artan dizi: 0x00..0x0F → 0x41
//   T5. Tekrarlı bayt: 8 x 0xA5 → 0x59
//   T6. g_temizle çerçeveler arasında sızıntı bırakmıyor
//   T7. g_gecerli düşükken CRC değişmiyor (kaçak bayt yok)
//   T8. g_temizle, g_gecerli'den öncelikli
//
// Beklenen değerler Python referans modeliyle üretilmiştir:
//   CRC-8/SMBus - poli 0x07, init 0x00, yansima yok, son XOR yok
//
// Koşturma (Vivado xsim):
//   xvlog -sv tb_crc8_hesap.sv ../sources_1/crc8_hesap.v
//   xelab -debug typical tb_crc8_hesap -s tb && xsim tb -R
// =============================================================================

`timescale 1ns / 1ps

module tb_crc8_hesap;

    localparam real SAAT_PERIYOT = 10.0;

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
    reg        temizle;
    reg  [7:0] veri;
    reg        gecerli;
    wire [7:0] crc;

    always #(SAAT_PERIYOT/2.0) saat = ~saat;

    crc8_hesap #(.POLINOM(8'h07), .BASLANGIC(8'h00)) dut (
        .g_saat(saat), .g_sifirla_n(sifirla_n),
        .g_temizle(temizle), .g_veri(veri), .g_gecerli(gecerli), .c_crc(crc)
    );

    // ── Yardımcı görevler ─────────────────────────────────────────────────
    task crc_temizle;
        begin
            @(negedge saat);
            temizle = 1'b1; gecerli = 1'b0;
            @(negedge saat);
            temizle = 1'b0;
        end
    endtask

    task bayt_besle(input [7:0] b);
        begin
            @(negedge saat);
            veri = b; gecerli = 1'b1;
            @(negedge saat);
            gecerli = 1'b0;
        end
    endtask

    // ── Test verileri ─────────────────────────────────────────────────────
    reg [7:0] dizi_123456789 [0:8];
    reg [7:0] dizi_0_15      [0:15];
    integer i;
    reg [7:0] crc_kayit;

    initial begin
        dizi_123456789[0]=8'h31; dizi_123456789[1]=8'h32; dizi_123456789[2]=8'h33;
        dizi_123456789[3]=8'h34; dizi_123456789[4]=8'h35; dizi_123456789[5]=8'h36;
        dizi_123456789[6]=8'h37; dizi_123456789[7]=8'h38; dizi_123456789[8]=8'h39;
        for (i = 0; i < 16; i = i + 1) dizi_0_15[i] = i[7:0];
    end

    initial begin
        $display("=====================================================");
        $display(" TB-03 : crc8_hesap  (CRC-8/SMBus, poli 0x07)");
        $display("=====================================================");

        temizle = 1'b0; gecerli = 1'b0; veri = 8'h00;
        sifirla_n = 1'b0;
        repeat (5) @(posedge saat);
        @(negedge saat); sifirla_n = 1'b1;
        @(negedge saat);

        kontrol(crc === 8'h00, "T0: Reset sonrasi CRC = BASLANGIC (0x00)");

        // ── T1: standart kontrol vektörü ──────────────────────────────────
        crc_temizle;
        for (i = 0; i < 9; i = i + 1) bayt_besle(dizi_123456789[i]);
        @(negedge saat);
        kontrol(crc === 8'hF4, "T1: \"123456789\" -> 0xF4 (standart kontrol degeri)");
        if (crc !== 8'hF4) $display("     -> okunan 0x%02h", crc);

        // ── T2: tek bayt vektörleri ───────────────────────────────────────
        crc_temizle; bayt_besle(8'h00); @(negedge saat);
        kontrol(crc === 8'h00, "T2a: 0x00 -> 0x00");

        crc_temizle; bayt_besle(8'hFF); @(negedge saat);
        kontrol(crc === 8'hF3, "T2b: 0xFF -> 0xF3");
        if (crc !== 8'hF3) $display("     -> okunan 0x%02h", crc);

        // ── T3: çerçeve başlığı örneği ────────────────────────────────────
        crc_temizle;
        bayt_besle(8'hA5); bayt_besle(8'h01); bayt_besle(8'h40);
        @(negedge saat);
        kontrol(crc === 8'h5A, "T3: A5 01 40 -> 0x5A (QB_YUKLE cerceve basi)");
        if (crc !== 8'h5A) $display("     -> okunan 0x%02h", crc);

        // ── T4: artan dizi ────────────────────────────────────────────────
        crc_temizle;
        for (i = 0; i < 16; i = i + 1) bayt_besle(dizi_0_15[i]);
        @(negedge saat);
        kontrol(crc === 8'h41, "T4: 0x00..0x0F -> 0x41");
        if (crc !== 8'h41) $display("     -> okunan 0x%02h", crc);

        // ── T5: tekrarlı bayt ─────────────────────────────────────────────
        crc_temizle;
        for (i = 0; i < 8; i = i + 1) bayt_besle(8'hA5);
        @(negedge saat);
        kontrol(crc === 8'h59, "T5: 8 x 0xA5 -> 0x59");
        if (crc !== 8'h59) $display("     -> okunan 0x%02h", crc);

        // ── T6: çerçeveler arası sızıntı yok ──────────────────────────────
        //   Onceki cerceve (T5) hemen ardindan temizlenip T1 tekrarlanir.
        //   Ayni sonucu vermeli - aksi halde temizle eksik calisyor demektir.
        crc_temizle;
        for (i = 0; i < 9; i = i + 1) bayt_besle(dizi_123456789[i]);
        @(negedge saat);
        kontrol(crc === 8'hF4, "T6: Ardisik cerceveler arasi sizinti yok");

        // ── T7: gecerli dusukken CRC degismiyor ───────────────────────────
        crc_kayit = crc;
        @(negedge saat); veri = 8'hDE; gecerli = 1'b0;
        repeat (5) @(negedge saat);
        kontrol(crc === crc_kayit, "T7: g_gecerli dusukken CRC sabit kaldi");

        // ── T8: temizle onceligi ──────────────────────────────────────────
        @(negedge saat);
        temizle = 1'b1; veri = 8'hAA; gecerli = 1'b1;   // ikisi ayni anda
        @(negedge saat);
        temizle = 1'b0; gecerli = 1'b0;
        @(negedge saat);
        kontrol(crc === 8'h00, "T8: g_temizle, g_gecerli'den oncelikli");

        // ── Özet ──────────────────────────────────────────────────────────
        $display("-----------------------------------------------------");
        if (hata_say == 0) $display(" TB-03 SONUC: TUM TESTLER GECTI");
        else               $display(" TB-03 SONUC: %0d TEST KALDI", hata_say);
        $display("=====================================================");
        $finish;
    end

    initial begin
        #500_000;
        $display(" TB-03 HATA: zaman asimi");
        $finish;
    end

endmodule
