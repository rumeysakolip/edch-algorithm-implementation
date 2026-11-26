// =============================================================================
// Testbench : tb_komut_yoneticisi.sv                               (Ister TB-11)
// Hedef     : komut_yoneticisi.v (M-09)
// -----------------------------------------------------------------------------
//   *** KATMAN 3 KAPANIS KAPISI ***
//
// komut_yoneticisi, SAHTE (mock) bir ecdh_kex_top ile kosturulur. Gercek
// cekirdek kullanilmaz; amac protokol -> cekirdek denetimi cevriminin
// dogrulugunu izole olarak sinamaktir. Gercek cekirdek TB-12'de baglanir.
//
// Kontrol edilenler:
//   T1. QB_YUKLE (64 bayt) -> ACK, tampon dolduruldu
//   T2. ECDH_BASLAT -> ACK + c_kex_start darbesi
//   T3. TRNG el sikismasi: cekirdege 8 word d verildi
//   T4. Qa hazir olunca Qb OTOMATIK beslendi (16 word, dogru sel) + qb_start
//   T5. QA_OKU -> 64 bayt, cekirdegin urettigi Qa ile birebir
//   T6. SIR_OKU -> 64 bayt, cekirdegin urettigi Ortak Sir ile birebir
//   T7. DURUM_OKU -> uzunluk 0, durum bayti DURUM alaninda
//   T8. Bilinmeyen komut (0x7F) -> 0xE2
//   T9. Yanlis uzunluk (QB_YUKLE, 32 bayt) -> 0xE3
//   T10. *** GUVENLIK *** TEST_MODU kapali iken 0x10 D_YUKLE -> 0xE2 reddi
//   T11. Cekirdek hatasi -> QA_OKU yanitinda 0xE5
//
//   ── NESNE DEPOSU KOMUTLARI (Ister OBJ-01..05) ──────────────────────────
//   Deponun KENDISI TB-15'te dogrulandi. Buradaki hedef DEPOYA GIDEN YOL:
//   komut_yoneticisi'ndeki S_NES_* durumlari, baslik cozme, red mantigi ve
//   TX kaynak secimi.
//   T12. NESNE_YAZ -> ACK
//   T13. NESNE_BILGI -> uzunluk/kilit/gecerli alanlari dogru
//   T14. NESNE_OKU -> yazilan 14 word birebir geri
//   T15. *** GUVENLIK *** gecersiz FileID (7) -> 0xE8, maskelenmiyor
//   T16. Hizasiz ofset (2) -> 0xEB
//   T17. *** GUVENLIK *** okuma sinir asimi (ofs=1008) -> 0xEA
//        Kabul edilseydi KOMSU SLOTUN icerigi disari sizardi.
//   T18. Yazma sinir asimi (ofs=1008, 56 bayt) -> 0xEA, kirpilmiyor
//   T19. *** GUVENLIK *** trust anchor kilidi: yazma reddi (0xE9), icerik
//        korunuyor, kilitli slot HALA okunabilir
//   T20. Slot yalitimi: slot 1 islemleri slot 0'i bozmuyor
//
// NOT: Bu dosya TEST_MODU TANIMSIZ derlenmelidir (uretim yapilandirmasi).
//      TEST_MODU'lu ayri bir kosum icin xelab'a -d TEST_MODU eklenir; o zaman
//      T10 beklentisi degisir (0x10 kabul edilir) ve TB bunu bildirir.
//
// Kosturma (Vivado xsim):
//   xvlog -sv tb_komut_yoneticisi.sv ../sources_1/komut_yoneticisi.v
//   xelab -debug typical tb_komut_yoneticisi -s tb && xsim tb -R
// =============================================================================

`timescale 1ns / 1ps

// =============================================================================
//  SAHTE ecdh_kex_top
//  Gercek cekirdegin port arayuzunu ve el sikisma sirasini taklit eder;
//  matematik yapmaz, sabit degerler uretir.
// =============================================================================
module sahte_kex_top (
    input  wire        clk_in,
    input  wire        rst_n,
    input  wire        i_start,
    output reg         o_trng_req,
    input  wire        i_trng_vld,
    input  wire [31:0] i_trng_pkt,
    input  wire [31:0] i_pkt_in,
    input  wire        i_pkt_vld,
    input  wire [1:0]  i_pkt_sel,
    input  wire        i_qb_start,
    output reg  [31:0] o_pkt_out,
    output reg         o_pkt_vld,
    output reg  [1:0]  o_pkt_sel,
    output reg         o_pkt_last,
    output reg  [1:0]  o_stage,
    output reg         o_qa_done,
    output reg         o_rdy,
    output reg         o_done,
    output reg         o_err,
    // ── Gozlem portlari (yalniz TB icin) ──────────────────────────────────
    output reg  [255:0] gz_d,      // 8 x 32 bit (duz vektor)
    output reg  [511:0] gz_qb,     // 16 x 32 bit (duz vektor)
    output reg  [4:0]  gz_d_say,
    output reg  [4:0]  gz_qb_say,
    output reg         gz_qb_start_gor,
    input  wire        gz_hata_uret
);

localparam [1:0] STAGE_QA = 2'b01, STAGE_SS = 2'b10;

// Sahte sonuclar — TB bunlarla karsilastirir
function [31:0] qa_word(input [3:0] i);
    qa_word = 32'hA0000000 | {28'd0, i};
endfunction
function [31:0] ss_word(input [3:0] i);
    ss_word = 32'h55000000 | {28'd0, i};
endfunction

localparam [3:0] M_BOSTA=0, M_TRNG=1, M_QA_X=2, M_QA_Y=3, M_QA_BITTI=4,
                 M_QB_BEK=5, M_SS_X=6, M_SS_Y=7, M_BITTI=8, M_HATA=9;

reg [3:0] m_durum;
reg [3:0] m_sayac;

always @(posedge clk_in or negedge rst_n) begin
    if (!rst_n) begin
        m_durum <= M_BOSTA; m_sayac <= 4'd0;
        o_trng_req <= 1'b0; o_pkt_vld <= 1'b0; o_pkt_out <= 32'd0;
        o_pkt_sel <= 2'd0; o_pkt_last <= 1'b0; o_stage <= 2'b00;
        o_qa_done <= 1'b0; o_rdy <= 1'b1; o_done <= 1'b0; o_err <= 1'b0;
        gz_d_say <= 5'd0; gz_qb_say <= 5'd0; gz_qb_start_gor <= 1'b0;
    end else begin
        o_pkt_vld <= 1'b0; o_qa_done <= 1'b0; o_done <= 1'b0;
        o_pkt_last <= 1'b0; o_err <= 1'b0;

        // Qb paketlerini her zaman yakala
        if (i_pkt_vld && gz_qb_say < 5'd16) begin
            gz_qb[gz_qb_say*32 +: 32] <= i_pkt_in;
            gz_qb_say <= gz_qb_say + 5'd1;
        end
        if (i_qb_start) gz_qb_start_gor <= 1'b1;

        // TRNG word'lerini yakala
        if (i_trng_vld && gz_d_say < 5'd8) begin
            gz_d[gz_d_say*32 +: 32] <= i_trng_pkt;
            gz_d_say <= gz_d_say + 5'd1;
        end

        case (m_durum)
            M_BOSTA: begin
                o_rdy <= 1'b1;
                if (i_start) begin
                    gz_d_say <= 5'd0; gz_qb_say <= 5'd0;
                    gz_qb_start_gor <= 1'b0;
                    o_rdy <= 1'b0;
                    o_trng_req <= 1'b1;
                    m_durum <= M_TRNG;
                end
            end

            M_TRNG: if (gz_d_say == 5'd8) begin
                o_trng_req <= 1'b0;
                if (gz_hata_uret) begin
                    m_durum <= M_HATA;
                end else begin
                    m_sayac <= 4'd0;
                    o_stage <= STAGE_QA;
                    m_durum <= M_QA_X;
                end
            end

            M_QA_X: begin
                o_pkt_vld <= 1'b1; o_pkt_sel <= 2'b00;
                o_pkt_out <= qa_word(m_sayac);
                if (m_sayac == 4'd7) begin m_sayac <= 4'd0; m_durum <= M_QA_Y; end
                else m_sayac <= m_sayac + 4'd1;
            end

            M_QA_Y: begin
                o_pkt_vld <= 1'b1; o_pkt_sel <= 2'b01;
                o_pkt_out <= qa_word(m_sayac + 4'd8);
                if (m_sayac == 4'd7) begin m_sayac <= 4'd0; m_durum <= M_QA_BITTI; end
                else m_sayac <= m_sayac + 4'd1;
            end

            M_QA_BITTI: begin
                o_qa_done <= 1'b1;
                m_durum   <= M_QB_BEK;
            end

            M_QB_BEK: if (gz_qb_start_gor) begin
                m_sayac <= 4'd0;
                o_stage <= STAGE_SS;
                m_durum <= M_SS_X;
            end

            M_SS_X: begin
                o_pkt_vld <= 1'b1; o_pkt_sel <= 2'b00;
                o_pkt_out <= ss_word(m_sayac);
                if (m_sayac == 4'd7) begin m_sayac <= 4'd0; m_durum <= M_SS_Y; end
                else m_sayac <= m_sayac + 4'd1;
            end

            M_SS_Y: begin
                o_pkt_vld <= 1'b1; o_pkt_sel <= 2'b01;
                o_pkt_out <= ss_word(m_sayac + 4'd8);
                if (m_sayac == 4'd7) begin m_sayac <= 4'd0; m_durum <= M_BITTI; end
                else m_sayac <= m_sayac + 4'd1;
            end

            M_BITTI: begin
                o_done  <= 1'b1;
                o_rdy   <= 1'b1;
                m_durum <= M_BOSTA;
            end

            M_HATA: begin
                o_err   <= 1'b1;
                o_rdy   <= 1'b1;
                m_durum <= M_BOSTA;
            end

            default: m_durum <= M_BOSTA;
        endcase
    end
end

endmodule


// =============================================================================
//  TB-11
// =============================================================================
module tb_komut_yoneticisi;

    localparam real SAAT_PERIYOT = 10.0;

    integer hata_say  = 0;
    // Gecen dogrulama sayaci. TB-14 ve TB-15 bunu basiyordu, TB-11 basmiyordu;
    // bu tutarsizlik "kac test var" sorusunun tahminle cevaplanmasina yol acti.
    // DIKKAT: burada sayilan sey NUMARALI TEST (T1..T20) degil, tek tek
    // DOGRULAMADIR. Bir test birden cok dogrulama icerebilir (T4'te dort,
    // T19'da bes gibi), bu yuzden iki sayi birbirini tutmaz — ikisi de basilir.
    integer gecen_say = 0;

    // Durum bayti bekleyen testler icin: kalirsa GERCEK degeri de basar.
    // Boylece "eski RTL mi kosuyor, yoksa gercek bir hata mi var" sorusu
    // logdan dogrudan cevaplanir. Ornegin nesne komutlarindan 0xE2 donuyorsa
    // S_BOSTA dagitimi eski surumdedir (komut default dalina dusuyor);
    // 0xE3 donuyorsa uzunluk tablosu, baska bir kod donuyorsa gercek mantik
    // hatasi vardir.
    task kontrol_durum(input [7:0] beklenen, input [1023:0] ad);
        begin
            if (yanit_say == 1 && yanit_durum_r === beklenen) begin
                $display("  [GECTI] %0s", ad);
                gecen_say = gecen_say + 1;
            end else begin
                $display("  [KALDI] %0s", ad);
                $display("          -> beklenen durum 0x%02X | GELEN 0x%02X | yanit_say=%0d",
                         beklenen, yanit_durum_r, yanit_say);
                if (yanit_say == 0) begin
                    $display("          -> HIC YANIT URETILMEDI: FSM ilerlemiyor");
                    // DUT'un ic durumunu bas — asili kalinan YERI gosterir.
                    // 8=S_NES_YAZ'da sonsuz dongu, 1=S_VERI_BEK'te word
                    // bekliyor, 7=S_NES_ISLE'de takili demektir.
                    $display("          -> durum_r=%0d  aktif_komut=0x%02X  son_indis=%0d  nesne_sayac=%0d",
                             dut.durum_r, dut.aktif_komut_r, dut.son_indis_w, dut.nesne_sayac_r);
                    $display("          -> nesne_rx_r[0]=%08h  nb_son=%b nb_gecerli=%0d nb_id=%0d nb_ofset=%0d",
                             dut.nesne_rx_r[0], dut.nb_son_w, dut.nb_gecerli_w,
                             dut.nb_id_w, dut.nb_ofset_w);
                    $display("          -> nb_yaz_word=%0d  hiza_ok=%b yaz_sinir_ok=%b oku_sinir_ok=%b",
                             dut.nb_yaz_word_w, dut.nb_hiza_ok_w,
                             dut.nb_yaz_sinir_ok_w, dut.nb_oku_sinir_ok_w);
                end
                else if (yanit_durum_r === 8'hE2)
                    $display("          -> 0xE2 = komut S_BOSTA dagitiminda 'default' dalina dustu");
                else if (yanit_durum_r === 8'hE3)
                    $display("          -> 0xE3 = beklenen_uzunluk_w tablosu uyusmuyor");
                hata_say = hata_say + 1;
            end
        end
    endtask

    task kontrol(input kosul, input [1023:0] ad);
        begin
            if (kosul) begin
                $display("  [GECTI] %0s", ad);
                gecen_say = gecen_say + 1;
            end else begin
                $display("  [KALDI] %0s", ad);
                hata_say = hata_say + 1;
            end
        end
    endtask

    reg saat = 1'b0;
    reg sifirla_n;
    always #(SAAT_PERIYOT/2.0) saat = ~saat;

    // ── komut_yoneticisi baglantilari ─────────────────────────────────────
    reg  [7:0]  komut, uzunluk;
    reg         komut_gecerli;
    reg  [31:0] rx_word;
    reg         rx_word_gecerli;
    reg  [3:0]  rx_indis;
    wire        c_rx_word_hazir;

    wire        c_yanit_basla;
    wire [7:0]  c_yanit_durum, c_yanit_uzunluk;
    wire [31:0] c_tx_word;
    wire        c_tx_word_gecerli;
    reg         tx_word_iste;

    wire        c_kex_start, c_kex_qb_start;
    wire [31:0] c_kex_pkt;
    wire        c_kex_pkt_vld;
    wire [1:0]  c_kex_pkt_sel;
    wire [31:0] c_trng_pkt;
    wire        c_trng_vld;
    wire [7:0]  c_durum;

    // ── sahte cekirdek baglantilari ───────────────────────────────────────
    wire [31:0] k_pkt_out;
    wire        k_pkt_vld;
    wire [1:0]  k_sel, k_stage;
    wire        k_pkt_last, k_qa_done, k_rdy, k_done, k_err, k_trng_req;
    wire [255:0] gz_d;
    wire [511:0] gz_qb;
    wire [4:0]  gz_d_say, gz_qb_say;
    wire        gz_qb_start;
    reg         hata_uret;

    // Hata nedeni (Ister SEC-03). TB tarafindan surulur; sahte cekirdegin
    // uretmesi gerekmez. BAGSIZ BIRAKILMAMALIDIR: bagsiz bir giris portu
    // simulasyonda z'ye duser, hata_kod_r z olur ve yanit durum bayti x
    // cikar — TB sessizce ve yaniltici bicimde kalir.
    //   0 = genel/bilinmeyen -> 0xE5 (eski davranis)
    //   1 = gecersiz nokta   -> 0xE6
    //   2 = gecersiz skaler  -> 0xE7
    reg  [2:0]  k_err_kod;
    initial     k_err_kod = 3'd0;

    // FAZ 4 — slot geri bildirimi. Sahte cekirdek uretmez; TB surer.
    // BAGSIZ BIRAKILMAMALIDIR: bagsiz giris z'ye duser ve hata_yanit_w
    // uzerinden yanit durum bayti x cikar.
    reg         k_slot_hata;
    reg  [1:0]  k_uret_hata_kod;
    initial   begin k_slot_hata = 1'b0; k_uret_hata_kod = 2'd0; end

    komut_yoneticisi dut (
        .g_saat(saat), .g_sifirla_n(sifirla_n),
        .g_komut(komut), .g_uzunluk(uzunluk), .g_komut_gecerli(komut_gecerli),
        // MEVCUT KUSUR (bu fazda bulundu, benim degisikligimle ilgisi yok):
        // g_manuel_basla bagsizdi -> simulasyonda z. z bir 'if' kosulunda x
        // uretir; kart butonu bu TB'de test edilmedigi icin sabit 0 baglandi.
        .g_manuel_basla(1'b0),
        .g_rx_word(rx_word), .g_rx_word_gecerli(rx_word_gecerli),
        .g_rx_indis(rx_indis), .c_rx_word_hazir(c_rx_word_hazir),
        .c_yanit_basla(c_yanit_basla), .c_yanit_durum(c_yanit_durum),
        .c_yanit_uzunluk(c_yanit_uzunluk),
        .c_tx_word(c_tx_word), .c_tx_word_gecerli(c_tx_word_gecerli),
        .g_tx_word_iste(tx_word_iste),
        .c_kex_start(c_kex_start), .c_kex_qb_start(c_kex_qb_start),
        .c_kex_pkt(c_kex_pkt), .c_kex_pkt_vld(c_kex_pkt_vld),
        .c_kex_pkt_sel(c_kex_pkt_sel),
        .g_kex_pkt_out(k_pkt_out), .g_kex_pkt_vld(k_pkt_vld),
        .g_kex_sel(k_sel), .g_kex_stage(k_stage),
        .g_kex_qa_done(k_qa_done), .g_kex_rdy(k_rdy),
        .g_kex_done(k_done), .g_kex_err(k_err), .g_kex_err_kod(k_err_kod),
        .g_kex_slot_hata(k_slot_hata), .g_kex_uret_hata_kod(k_uret_hata_kod),
        .c_kex_slot(), .c_kex_politika(), .c_kex_zeroize(),
        .g_trng_req(k_trng_req), .c_trng_pkt(c_trng_pkt), .c_trng_vld(c_trng_vld),
        .c_durum(c_durum)
    );

    sahte_kex_top cekirdek (
        .clk_in(saat), .rst_n(sifirla_n),
        .i_start(c_kex_start),
        .o_trng_req(k_trng_req), .i_trng_vld(c_trng_vld), .i_trng_pkt(c_trng_pkt),
        .i_pkt_in(c_kex_pkt), .i_pkt_vld(c_kex_pkt_vld), .i_pkt_sel(c_kex_pkt_sel),
        .i_qb_start(c_kex_qb_start),
        .o_pkt_out(k_pkt_out), .o_pkt_vld(k_pkt_vld), .o_pkt_sel(k_sel),
        .o_pkt_last(k_pkt_last), .o_stage(k_stage), .o_qa_done(k_qa_done),
        .o_rdy(k_rdy), .o_done(k_done), .o_err(k_err),
        .gz_d(gz_d), .gz_qb(gz_qb), .gz_d_say(gz_d_say), .gz_qb_say(gz_qb_say),
        .gz_qb_start_gor(gz_qb_start), .gz_hata_uret(hata_uret)
    );

    // ── Yanit yakalayici ──────────────────────────────────────────────────
    reg [7:0] yanit_durum_r, yanit_uzunluk_r;
    integer   yanit_say = 0;

    always @(posedge saat) begin
        if (c_yanit_basla) begin
            yanit_durum_r   <= c_yanit_durum;
            yanit_uzunluk_r <= c_yanit_uzunluk;
            yanit_say       <= yanit_say + 1;
        end
    end

    // Nesne testlerinde (T12..T20) coklu word karsilastirmasi icin bayrak
    reg        nesne_ok;

    // ── TX word toplayici (paket_kurucu taklidi) ──────────────────────────
    //   16 girisli: en buyuk yanit QA_OKU/SIR_OKU (16 word). Nesne okuma
    //   14 word oldugu icin bu tampon yeterlidir.
    reg [31:0] tx_toplanan [0:15];
    integer    tx_say = 0;

    always @(posedge saat) begin
        if (c_tx_word_gecerli && tx_say < 16) begin
            tx_toplanan[tx_say] <= c_tx_word;
            tx_say <= tx_say + 1;
        end
    end

    // paket_kurucu gibi word iste darbeleri uret
    task word_cek(input integer adet);
        integer k, j;
        begin
            for (k = 0; k < adet; k = k + 1) begin
                @(negedge saat);
                tx_word_iste = 1'b1;
                @(negedge saat);
                tx_word_iste = 1'b0;
                for (j = 0; j < 4; j = j + 1) @(negedge saat);
            end
        end
    endtask

    // ── Komut gonderme (paket_cozucu taklidi) ─────────────────────────────
    task komut_ver(input [7:0] k, input [7:0] uz);
        begin
            @(negedge saat);
            komut = k; uzunluk = uz; komut_gecerli = 1'b1;
            @(negedge saat);
            komut_gecerli = 1'b0;
            @(negedge saat);
        end
    endtask

    task word_ver(input [3:0] indis, input [31:0] w);
        begin
            @(negedge saat);
            rx_indis = indis; rx_word = w; rx_word_gecerli = 1'b1;
            @(negedge saat);
            rx_word_gecerli = 1'b0;
            @(negedge saat);
        end
    endtask

    // ── Test verileri ─────────────────────────────────────────────────────
    function [31:0] qb_test_word(input [3:0] i);
        qb_test_word = 32'hB0000000 | {28'd0, i};
    endfunction
    function [31:0] qa_bek(input [3:0] i);
        qa_bek = 32'hA0000000 | {28'd0, i};
    endfunction
    function [31:0] ss_bek(input [3:0] i);
        ss_bek = 32'h55000000 | {28'd0, i};
    endfunction

    integer i, bek;
    reg     uyum_hata;

    initial begin
        $display("=====================================================");
        $display(" TB-11 : komut_yoneticisi + sahte kex_top");
        $display("         *** KATMAN 3 KAPANIS KAPISI ***");
`ifdef TEST_MODU
        $display("   YAPILANDIRMA: TEST_MODU TANIMLI (0x10 kabul edilir)");
`else
        $display("   YAPILANDIRMA: TEST_MODU TANIMSIZ (uretim — 0x10 reddedilir)");
`endif
        $display("=====================================================");

        komut = 8'd0; uzunluk = 8'd0; komut_gecerli = 1'b0;
        rx_word = 32'd0; rx_word_gecerli = 1'b0; rx_indis = 4'd0;
        tx_word_iste = 1'b0; hata_uret = 1'b0;
        sifirla_n = 1'b0;
        repeat (10) @(posedge saat);
        @(negedge saat); sifirla_n = 1'b1;
        repeat (5) @(negedge saat);

        // ── T1: QB_YUKLE ──────────────────────────────────────────────────
        yanit_say = 0;
        komut_ver(8'h01, 8'd64);
        for (i = 0; i < 16; i = i + 1) word_ver(i[3:0], qb_test_word(i[3:0]));
        repeat (10) @(negedge saat);
        kontrol(yanit_say == 1 && yanit_durum_r === 8'h00 && yanit_uzunluk_r === 8'd0,
                "T1: QB_YUKLE -> ACK (durum 0x00, uzunluk 0)");

        // ── T2: ECDH_BASLAT ───────────────────────────────────────────────
        yanit_say = 0;
        komut_ver(8'h02, 8'd0);
        repeat (10) @(negedge saat);
        kontrol(yanit_say == 1 && yanit_durum_r === 8'h00,
                "T2: ECDH_BASLAT -> ACK ve c_kex_start verildi");

        // ── T3: TRNG el sikismasi ─────────────────────────────────────────
        bek = 0;
        while (gz_d_say != 5'd8 && bek < 500) begin @(negedge saat); bek = bek + 1; end
        kontrol(gz_d_say == 5'd8, "T3: Cekirdege 8 word d verildi (TRNG)");

        // ── T4: Qa hazir -> Qb OTOMATIK beslendi ──────────────────────────
        bek = 0;
        while (!gz_qb_start && bek < 2000) begin @(negedge saat); bek = bek + 1; end
        kontrol(gz_qb_start, "T4a: i_qb_start darbesi uretildi");
        kontrol(gz_qb_say == 5'd16, "T4b: Cekirdege 16 Qb word'u beslendi");

        uyum_hata = 1'b0;
        for (i = 0; i < 16; i = i + 1)
            if (gz_qb[i*32 +: 32] !== qb_test_word(i[3:0])) begin
                uyum_hata = 1'b1;
                if (i < 4) $display("     -> qb[%0d]: 0x%08h (0x%08h olmali)",
                                    i, gz_qb[i*32 +: 32], qb_test_word(i[3:0]));
            end
        kontrol(!uyum_hata, "T4c: Qb tamponu dogru sirada aktarildi");

        // Ortak Sir hesabinin bitmesini bekle
        bek = 0;
        while (c_durum[2] !== 1'b1 && bek < 2000) begin @(negedge saat); bek = bek + 1; end
        kontrol(c_durum[2] === 1'b1, "T4d: Ortak Sir hazir bayragi yukseldi");

        // ── T5: QA_OKU ────────────────────────────────────────────────────
        yanit_say = 0; tx_say = 0;
        komut_ver(8'h03, 8'd0);
        repeat (5) @(negedge saat);
        kontrol(yanit_durum_r === 8'h00 && yanit_uzunluk_r === 8'd64,
                "T5a: QA_OKU -> durum 0x00, uzunluk 64");
        word_cek(16);
        repeat (5) @(negedge saat);
        kontrol(tx_say == 16, "T5b: 16 word cekildi");
        uyum_hata = 1'b0;
        for (i = 0; i < 16; i = i + 1)
            if (tx_toplanan[i] !== qa_bek(i[3:0])) begin
                uyum_hata = 1'b1;
                if (i < 4) $display("     -> qa[%0d]: 0x%08h (0x%08h olmali)",
                                    i, tx_toplanan[i], qa_bek(i[3:0]));
            end
        kontrol(!uyum_hata, "T5c: Qa degerleri cekirdek ciktisiyla birebir");

        // ── T6: SIR_OKU ───────────────────────────────────────────────────
        yanit_say = 0; tx_say = 0;
        komut_ver(8'h04, 8'd0);
        repeat (5) @(negedge saat);
        kontrol(yanit_durum_r === 8'h00 && yanit_uzunluk_r === 8'd64,
                "T6a: SIR_OKU -> durum 0x00, uzunluk 64");
        word_cek(16);
        repeat (5) @(negedge saat);
        uyum_hata = 1'b0;
        for (i = 0; i < 16; i = i + 1)
            if (tx_toplanan[i] !== ss_bek(i[3:0])) begin
                uyum_hata = 1'b1;
                if (i < 4) $display("     -> ss[%0d]: 0x%08h (0x%08h olmali)",
                                    i, tx_toplanan[i], ss_bek(i[3:0]));
            end
        kontrol(!uyum_hata, "T6b: Ortak Sir degerleri birebir");

        // ── T7: DURUM_OKU ─────────────────────────────────────────────────
        yanit_say = 0;
        komut_ver(8'h05, 8'd0);
        repeat (5) @(negedge saat);
        kontrol(yanit_say == 1 && yanit_uzunluk_r === 8'd0,
                "T7a: DURUM_OKU -> uzunluk 0 (durum DURUM alaninda)");
        kontrol(yanit_durum_r[1] === 1'b1 && yanit_durum_r[2] === 1'b1,
                "T7b: Durum baytinda qa_hazir ve sir_hazir bitleri set");

        // ── T8: bilinmeyen komut ──────────────────────────────────────────
        yanit_say = 0;
        komut_ver(8'h7F, 8'd0);
        repeat (5) @(negedge saat);
        kontrol(yanit_say == 1 && yanit_durum_r === 8'hE2,
                "T8: Bilinmeyen komut 0x7F -> 0xE2");

        // ── T9: yanlis uzunluk ────────────────────────────────────────────
        yanit_say = 0;
        komut_ver(8'h01, 8'd32);       // QB_YUKLE 64 bekler
        repeat (5) @(negedge saat);
        kontrol(yanit_say == 1 && yanit_durum_r === 8'hE3,
                "T9: QB_YUKLE yanlis uzunluk (32) -> 0xE3");

        // ── T10: GUVENLIK — D_YUKLE ───────────────────────────────────────
        //   TB KUSURU (Faz 3 regresyonunda bulundu):
        //   Onceki surum yalnizca komut darbesi gonderiyor, 8 veri word'unu
        //   GONDERMIYORDU. TEST_MODU tanimsizken 0x10 bilinmeyen komut sayilip
        //   aninda 0xE2 dondugu icin bu eksiklik gorunmuyordu. TEST_MODU
        //   TANIMLI iken ise komut GECERLI oldugundan FSM S_VERI_BEK'te 8 word
        //   bekler; gelmeyince yanit uretilmez ve T10 kalir. Dahasi FSM orada
        //   asili kaldigi icin T11 hic calisamaz — T11a/T11b de artci olarak
        //   kalirdi. Uc basarisizligin tek kok nedeni buydu.
        //
        //   D_YUKLE 32 bayt = 8 word bekler (bkz. beklenen_uzunluk_w tablosu),
        //   bu yuzden T1'deki QB_YUKLE deseninin aynisi uygulanir.
        yanit_say = 0;
        komut_ver(8'h10, 8'd32);
`ifdef TEST_MODU
        // Komut kabul edildi -> veri word'leri BEKLENIYOR, gonderilmeli.
        for (i = 0; i < 8; i = i + 1) word_ver(i[3:0], 32'hD0D0_0000 + i);
        repeat (10) @(negedge saat);
        kontrol(yanit_say == 1 && yanit_durum_r !== 8'hE2,
                "T10: TEST_MODU tanimli -> 0x10 D_YUKLE KABUL edildi");
`else
        // Komut REDDEDILIR -> veri asamasina hic girilmez, word gonderilmez.
        repeat (5) @(negedge saat);
        kontrol(yanit_say == 1 && yanit_durum_r === 8'hE2,
                "T10: *** GUVENLIK *** TEST_MODU yok -> 0x10 REDDEDILDI (0xE2)");
`endif

        // ── T11: cekirdek hatasi ──────────────────────────────────────────
        hata_uret = 1'b1;
        yanit_say = 0;
        komut_ver(8'h02, 8'd0);        // yeni islem baslat -> hata uretecek
        bek = 0;
        while (c_durum[3] !== 1'b1 && bek < 2000) begin @(negedge saat); bek = bek + 1; end
        kontrol(c_durum[3] === 1'b1, "T11a: Cekirdek hatasi durum bitine yansidi");

        yanit_say = 0;
        komut_ver(8'h03, 8'd0);
        repeat (5) @(negedge saat);
        kontrol(yanit_durum_r === 8'hE5,
                "T11b: Hata sonrasi QA_OKU -> 0xE5 (cekirdek hatasi)");

        // *** ZORUNLU: yaniti BOSALT ***
        //   QA_OKU 64 baytlik (16 word) yanit uretir. S_YANIT_BEK, yanitin
        //   tamamen cekilmesini bekler:
        //       tx_cekilen_r == yanit_uzunluk_r[6:2]   // 64/4 = 16
        //   Word'ler cekilmezse FSM S_YANIT_BEK'te KILITLI kalir, S_BOSTA'ya
        //   donmez ve sonraki HICBIR komutu isleyemez.
        //
        //   T11b eskiden son testti; kilitlenme gorunmuyordu. Arkasina T12+
        //   eklenince tum nesne testleri artci olarak kaldi (durum_r=3,
        //   aktif_komut=0x03 teshisi tam olarak bunu gosterdi).
        //   T5 ve T6 bu bosaltmayi zaten yapiyor; T11b'de eksikti.
        word_cek(16);
        repeat (5) @(negedge saat);
        kontrol(dut.durum_r === 4'd0,
                "T11c: yanit bosaltildi, FSM S_BOSTA'ya dondu");

        hata_uret = 1'b0;

        // ═════════════════════════════════════════════════════════════════
        //  T12..T20 — NESNE DEPOSU KOMUTLARI (İster OBJ-01..05)
        // ═════════════════════════════════════════════════════════════════
        //   nesne_deposu'nun KENDISI TB-15'te dogrulandi. Buradaki hedef
        //   FARKLI: komut_yoneticisi icindeki S_NES_* durumlari, baslik
        //   cozme, sinir/kilit/hiza reddi ve TX kaynak secimi. Yani depo
        //   degil, DEPOYA GIDEN YOL test ediliyor.
        hata_uret = 1'b0;
        repeat (5) @(negedge saat);

        // ── T12: NESNE_YAZ -> ACK ─────────────────────────────────────────
        //   Baslik: FileID=0 (sertifika), ofset=0, SON=1, gecerli=56
        //   word0 = {bayrak, ofset_hi, ofset_lo, id} (LSB-once paketleme)
        yanit_say = 0;
        komut_ver(8'h06, 8'd60);
        word_ver(4'd0, {8'hB8, 8'h00, 8'h00, 8'h00});   // SON|56, ofs=0, id=0
        for (i = 1; i < 15; i = i + 1)
            word_ver(i[3:0], 32'hA5A5_0000 + i);
        repeat (25) @(negedge saat);
        kontrol_durum(8'h00, "T12: NESNE_YAZ -> ACK (durum 0x00)");

        // ── T13: NESNE_BILGI -> uzunluk 56, gecerli, kilit yok ────────────
        yanit_say = 0; tx_say = 0;
        komut_ver(8'h08, 8'd4);
        word_ver(4'd0, {8'h00, 8'h00, 8'h00, 8'h00});   // id=0
        repeat (10) @(negedge saat);
        word_cek(1);
        repeat (5) @(negedge saat);
        kontrol_durum(8'h00, "T13a: NESNE_BILGI -> durum 0x00");
        kontrol(yanit_uzunluk_r === 8'd4, "T13a2: NESNE_BILGI -> uzunluk 4");
        kontrol(tx_toplanan[0][10:0] === 11'd56,
                "T13b: kaydedilen uzunluk 56 (SON bayragindan)");
        kontrol(tx_toplanan[0][16] === 1'b0 && tx_toplanan[0][17] === 1'b1,
                "T13c: kilit=0, gecerli=1");

        // ── T14: NESNE_OKU -> yazilan veri birebir geri ───────────────────
        yanit_say = 0; tx_say = 0;
        komut_ver(8'h07, 8'd4);
        word_ver(4'd0, {8'h00, 8'h00, 8'h00, 8'h00});   // id=0, ofs=0
        // On-getirme 14 word x ~3 cevrim surer; erken word_cek bos okur.
        repeat (60) @(negedge saat);
        word_cek(14);
        repeat (5) @(negedge saat);
        kontrol_durum(8'h00, "T14a: NESNE_OKU -> durum 0x00");
        kontrol(yanit_uzunluk_r === 8'd56, "T14a2: NESNE_OKU -> uzunluk 56");
        kontrol(tx_say == 14, "T14b: 14 word cekildi");
        nesne_ok = 1'b1;
        for (i = 0; i < 14; i = i + 1)
            if (tx_toplanan[i] !== (32'hA5A5_0000 + i + 1)) nesne_ok = 1'b0;
        kontrol(nesne_ok, "T14c: okunan 14 word yazilanla BIREBIR");

        // ── T15: gecersiz FileID -> 0xE8 ──────────────────────────────────
        //   Maskelenseydi 7 & 2'b11 = 3 olur, slot 3'e yazardi.
        yanit_say = 0;
        komut_ver(8'h07, 8'd4);
        word_ver(4'd0, {8'h00, 8'h00, 8'h00, 8'h07});   // id=7 (slot disi)
        repeat (15) @(negedge saat);
        kontrol_durum(8'hE8, "T15: gecersiz FileID -> 0xE8 (maskelenmedi)");

        // ── T16: hizasiz ofset -> 0xEB ────────────────────────────────────
        yanit_say = 0;
        komut_ver(8'h07, 8'd4);
        word_ver(4'd0, {8'h00, 8'h00, 8'h02, 8'h00});   // ofs=2, 4'un kati degil
        repeat (15) @(negedge saat);
        kontrol_durum(8'hEB, "T16: hizasiz ofset (2) -> 0xEB");

        // ── T17: okuma sinir asimi -> 0xEA ────────────────────────────────
        //   ofs=1008 icin 1008+56 = 1064 > 1024. Kabul edilseydi KOMSU SLOTUN
        //   icerigi disari sizardi — yalitim ihlali.
        yanit_say = 0;
        komut_ver(8'h07, 8'd4);
        word_ver(4'd0, {8'h00, 8'h03, 8'hF0, 8'h00});   // ofs=0x03F0=1008
        repeat (15) @(negedge saat);
        kontrol_durum(8'hEA, "T17: okuma sinir asimi (ofs=1008) -> 0xEA");

        // ── T18: yazma sinir asimi -> 0xEA ────────────────────────────────
        //   ofs=1008, SON=0 -> 14 word (56 bayt) yazilir, 1064 > 1024.
        yanit_say = 0;
        komut_ver(8'h06, 8'd60);
        word_ver(4'd0, {8'h38, 8'h03, 8'hF0, 8'h00});   // SON=0|56, ofs=1008
        for (i = 1; i < 15; i = i + 1) word_ver(i[3:0], 32'hDEAD_0000 + i);
        repeat (25) @(negedge saat);
        kontrol_durum(8'hEA, "T18: yazma sinir asimi (ofs=1008, 56 bayt) -> 0xEA");

        // ── T19: TRUST ANCHOR KILIDI ──────────────────────────────────────
        //   slot 1'e yaz, kilitle, sonra yazmayi dene.
        yanit_say = 0;
        komut_ver(8'h06, 8'd60);
        word_ver(4'd0, {8'hB8, 8'h00, 8'h00, 8'h01});   // SON|56, ofs=0, id=1
        for (i = 1; i < 15; i = i + 1) word_ver(i[3:0], 32'h7711_0000 + i);
        repeat (25) @(negedge saat);
        kontrol_durum(8'h00, "T19a: trust slotuna (id=1) yazma OK");

        yanit_say = 0;
        komut_ver(8'h09, 8'd4);
        word_ver(4'd0, {8'h00, 8'h00, 8'h00, 8'h01});   // id=1 kilitle
        repeat (15) @(negedge saat);
        kontrol_durum(8'h00, "T19b: NESNE_KILIT -> ACK");

        yanit_say = 0;
        komut_ver(8'h06, 8'd60);
        word_ver(4'd0, {8'hB8, 8'h00, 8'h00, 8'h01});   // ayni slota tekrar yaz
        for (i = 1; i < 15; i = i + 1) word_ver(i[3:0], 32'hBAAD_0000 + i);
        repeat (25) @(negedge saat);
        kontrol_durum(8'hE9, "T19c: *** kilitli slota yazma REDDEDILDI (0xE9) ***");

        // Kilitli slot HALA OKUNABILIR olmali (sertifika gizli degil,
        // yalnizca DEGISTIRILEMEZ olmali) ve icerigi DEGISMEMIS olmali.
        yanit_say = 0; tx_say = 0;
        komut_ver(8'h07, 8'd4);
        word_ver(4'd0, {8'h00, 8'h00, 8'h00, 8'h01});
        repeat (60) @(negedge saat);
        word_cek(14);
        repeat (5) @(negedge saat);
        kontrol(yanit_durum_r === 8'h00, "T19d: kilitli slot HALA OKUNABILIR");
        nesne_ok = 1'b1;
        for (i = 0; i < 14; i = i + 1)
            if (tx_toplanan[i] !== (32'h7711_0000 + i + 1)) nesne_ok = 1'b0;
        kontrol(nesne_ok, "T19e: kilitli slot icerigi DEGISMEDI (BAAD yazilmadi)");

        // ── T20: SLOT YALITIMI ────────────────────────────────────────────
        //   Trust slotuna yapilan islemler sertifika slotunu bozmamali.
        yanit_say = 0; tx_say = 0;
        komut_ver(8'h07, 8'd4);
        word_ver(4'd0, {8'h00, 8'h00, 8'h00, 8'h00});   // id=0
        repeat (60) @(negedge saat);
        word_cek(14);
        repeat (5) @(negedge saat);
        nesne_ok = 1'b1;
        for (i = 0; i < 14; i = i + 1)
            if (tx_toplanan[i] !== (32'hA5A5_0000 + i + 1)) nesne_ok = 1'b0;
        kontrol(nesne_ok, "T20: slot 0 icerigi slot 1 islemlerinden ETKILENMEDI");

        // ── Ozet ──────────────────────────────────────────────────────────
        $display("-----------------------------------------------------");
        $display(" OZET: %0d gecti / %0d kaldi   (toplam %0d dogrulama)",
                 gecen_say, hata_say, gecen_say + hata_say);
        $display(" NOT: numarali test T1..T20; bir test birden cok dogrulama");
        $display("      icerebilir, bu yuzden iki sayi birbirini tutmaz.");
        if (hata_say == 0) begin
            $display(" TB-11 SONUC: TUM DOGRULAMALAR GECTI");
            $display(" >>> KATMAN 3 KAPANDI — Katman 4'e gecilebilir.");
        end else begin
            $display(" TB-11 SONUC: %0d DOGRULAMA KALDI", hata_say);
            $display(" >>> Katman 4'e GECMEYIN.");
        end
        $display("=====================================================");
        $finish;
    end

    initial begin
        #20_000_000;
        $display(" TB-11 HATA: zaman asimi (simulasyon takildi)");
        $finish;
    end

endmodule
