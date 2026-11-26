// =============================================================================
// Testbench : tb_modular_alu_dsp.sv                                   (TB-26)
// Hedef     : modular_alu_dsp.v  —  DSP48E1 tabanlı CIOS MontMult
// -----------------------------------------------------------------------------
// AMAÇ:
//   Yeni MALU'nun mevcut (kanıtlanmış) MALU ile BİREBİR AYNI davrandığını
//   göstermek ve kazandığı çevrimi ölçmek.
//
// YÖNTEM — DİFERANSİYEL TEST:
//   İki modül YAN YANA örneklenir ve AYNI uyaranla sürülür. Beklenen değer
//   dışarıdan hesaplanmaz; REFERANS DOĞRUDAN modular_alu.v'nin kendisidir.
//   Bu, "altın modeli TB'ye yeniden yazarken hata yapma" riskini tamamen
//   ortadan kaldırır — mevcut modül zaten 20.000 vektörle Python altın
//   modeline karşı doğrulanmış durumda.
//
//   Diferansiyel testin tek zayıf noktası, İKİ modülün AYNI şekilde yanlış
//   olması ihtimalidir. İkisi tamamen farklı algoritmalar (bit-seri Carry-Save
//   ve sözcük-seri CIOS) olduğu için bu pratikte imkânsızdır; yine de bağımsız
//   bir çapa olsun diye Python'dan üretilmiş KAT vektörleri ayrıca sınanır.
//
// KAPSAM:
//   A) KAT — Python altın modelinden üretilmiş bilinen cevaplar (p ve n alanı)
//   B) Kenar durumlar — (0,0) (1,1) (P-1,P-1) (P-1,1) (R,R)
//   C) Rastgele diferansiyel — her alanda N_RASTGELE tur, MontMult/Add/Sub
//   D) Çevrim ölçümü — i_start'tan o_done'a; hızlanma oranı
//   E) Sabit zaman — MontMult çevrim sayısı TÜM vektörlerde aynı olmalı
//
// KOSTURMA:  xelab -debug typical tb_modular_alu_dsp -s tb26
//            xsim tb26 -R
//
// Standart : SystemVerilog-2012
// Tarih    : Temmuz 2026
// =============================================================================

`timescale 1ns / 1ps

module tb_modular_alu_dsp;

    localparam int N_RASTGELE = 300;   // alan başına rastgele tur

    localparam [255:0] P_ASAL =
        256'hffffffff00000001000000000000000000000000ffffffffffffffffffffffff;
    localparam [255:0] N_MERTEBE =
        256'hffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551;

    reg clk = 1'b0;  always #5 clk = ~clk;      // 100 MHz
    reg rst_n;

    reg [31:0] pkt_r;
    reg        pkt_vld_r;
    reg [1:0]  pkt_sel_r, opcode_r;
    reg        start_r;

    wire [31:0] ref_pkt_w,  dsp_pkt_w;
    wire        ref_vld_w,  dsp_vld_w;
    wire        ref_last_w, dsp_last_w;
    wire        ref_rdy_w,  dsp_rdy_w;
    wire        ref_done_w, dsp_done_w;
    wire        ref_err_w,  dsp_err_w;

    modular_alu ref_dut (
        .clk_in(clk), .rst_n(rst_n),
        .i_pkt_in(pkt_r), .i_pkt_vld(pkt_vld_r), .i_pkt_sel(pkt_sel_r),
        .i_opcode(opcode_r), .i_start(start_r),
        .o_pkt_out(ref_pkt_w), .o_pkt_vld(ref_vld_w), .o_pkt_last(ref_last_w),
        .o_rdy(ref_rdy_w), .o_done(ref_done_w), .o_err(ref_err_w)
    );

    modular_alu_dsp dsp_dut (
        .clk_in(clk), .rst_n(rst_n),
        .i_pkt_in(pkt_r), .i_pkt_vld(pkt_vld_r), .i_pkt_sel(pkt_sel_r),
        .i_opcode(opcode_r), .i_start(start_r),
        .o_pkt_out(dsp_pkt_w), .o_pkt_vld(dsp_vld_w), .o_pkt_last(dsp_last_w),
        .o_rdy(dsp_rdy_w), .o_done(dsp_done_w), .o_err(dsp_err_w)
    );

    // ── Sonuç toplayıcılar ──────────────────────────────────────────────
    //   Her iki modül de sonucu 8 paket hâlinde LSB-önce basar. Gecikmeleri
    //   FARKLI olduğu için ayrı ayrı toplanır; ana akış ikisini de bekler.
    reg [255:0] ref_son_r, dsp_son_r;
    reg [2:0]   ref_ix_r,  dsp_ix_r;
    reg         ref_bitti_r, dsp_bitti_r;

    always @(posedge clk) begin
        if (!rst_n) begin ref_ix_r<=3'd0; ref_bitti_r<=1'b0; end
        else begin
            if (start_r) begin ref_ix_r<=3'd0; ref_bitti_r<=1'b0; end
            if (ref_vld_w) begin
                ref_son_r[ref_ix_r*32 +: 32] <= ref_pkt_w;
                ref_ix_r <= ref_ix_r + 3'd1;
                if (ref_last_w) ref_bitti_r <= 1'b1;
            end
        end
    end

    always @(posedge clk) begin
        if (!rst_n) begin dsp_ix_r<=3'd0; dsp_bitti_r<=1'b0; end
        else begin
            if (start_r) begin dsp_ix_r<=3'd0; dsp_bitti_r<=1'b0; end
            if (dsp_vld_w) begin
                dsp_son_r[dsp_ix_r*32 +: 32] <= dsp_pkt_w;
                dsp_ix_r <= dsp_ix_r + 3'd1;
                if (dsp_last_w) dsp_bitti_r <= 1'b1;
            end
        end
    end

    // ── Çevrim ölçümü: i_start → o_done ─────────────────────────────────
    //   *** SAYACA YALNIZCA BU BLOK YAZAR ***
    //   İlk yazımda sayaçlar görevden blocking (=), buradan non-blocking (<=)
    //   sürülüyordu. Bu, AYNI kayıtçının iki ayrı süreçten sürülmesidir ve
    //   TB-25'te bizi bir kez yakalayan yarışın ta kendisidir: görevin
    //   sıfırlaması çekirdeğin saymasını ezebilir, ölçüm sessizce bozulur.
    //   Sıfırlama da start_r ile BU BLOĞUN İÇİNDE yapılır.
    integer ref_cev_r = 0, dsp_cev_r = 0, ref_olc_r = 0, dsp_olc_r = 0;
    always @(posedge clk) begin
        if (start_r) begin
            ref_olc_r<=1; dsp_olc_r<=1; ref_cev_r<=0; dsp_cev_r<=0;
        end else begin
            if (ref_olc_r) begin
                ref_cev_r <= ref_cev_r + 1;
                if (ref_done_w) ref_olc_r <= 0;
            end
            if (dsp_olc_r) begin
                dsp_cev_r <= dsp_cev_r + 1;
                if (dsp_done_w) dsp_olc_r <= 0;
            end
        end
    end

    // ═════════════════════════════════════════════════════════════════════
    integer hata_say = 0, gecen = 0;
    integer mm_cev_ref = -1, mm_cev_dsp = -1, sabit_ihlal = 0;
    integer cev_soguk = -1, soguk_ihlal = 0;

    task kontrol(input kosul, input [1023:0] ad);
        begin
            if (kosul) gecen = gecen + 1;
            else begin $display("  [KALDI] %0s", ad); hata_say = hata_say + 1; end
        end
    endtask

    task operand_yukle(input [1:0] sel, input [255:0] deger);
        integer w;
        begin
            for (w = 0; w < 8; w = w + 1) begin
                @(negedge clk);
                pkt_r     = deger[w*32 +: 32];
                pkt_sel_r = sel;
                pkt_vld_r = 1'b1;
            end
            @(negedge clk); pkt_vld_r = 1'b0;
        end
    endtask

    // Tek bir işlemi iki modülde birden koştur, sonuçları topla
    task kostur(input [255:0] p, input [255:0] a, input [255:0] b,
                input [1:0] opc);
        integer bek;
        begin
            operand_yukle(2'b10, p);
            operand_yukle(2'b00, a);
            operand_yukle(2'b01, b);
            // Sayac sifirlamasi start_r ile olcum blogunda yapilir — buradan
            // yazmak coklu surucu olurdu (yukaridaki nota bak).
            @(negedge clk); opcode_r = opc; start_r = 1'b1;
            @(negedge clk); start_r = 1'b0;
            bek = 0;
            while ((!ref_bitti_r || !dsp_bitti_r) && bek < 3000) begin
                @(posedge clk); bek = bek + 1;
            end
            if (bek >= 3000) begin
                $display("  [KALDI] ZAMAN ASIMI (ref_bitti=%b dsp_bitti=%b)",
                         ref_bitti_r, dsp_bitti_r);
                hata_say = hata_say + 1;
            end
            @(negedge clk);
        end
    endtask

    // Diferansiyel karşılaştırma + isteğe bağlı KAT
    task karsilastir(input [255:0] bek, input kat_var, input [1023:0] ad);
        begin
            if (ref_son_r !== dsp_son_r) begin
                $display("  [KALDI] %0s  -- DSP != REF", ad);
                $display("        ref 0x%064h", ref_son_r);
                $display("        dsp 0x%064h", dsp_son_r);
                hata_say = hata_say + 1;
            end else if (kat_var && (dsp_son_r !== bek)) begin
                $display("  [KALDI] %0s  -- KAT uyusmadi", ad);
                $display("        beklenen 0x%064h", bek);
                $display("        alinan   0x%064h", dsp_son_r);
                hata_say = hata_say + 1;
            end else gecen = gecen + 1;
        end
    endtask

    // ── SABİT ZAMAN HÜKMÜ — DOĞRU İFADESİ ───────────────────────────────
    //   İddia "çevrim sayısı HER ZAMAN aynıdır" DEĞİLDİR; doğru iddia şudur:
    //   *** SABİT BİR MODÜL İÇİN çevrim sayısı VERİDEN bağımsızdır. ***
    //
    //   Fark n0' önbelleğinden gelir: P'nin alt sözcüğü değişince Newton-
    //   Raphson yeniden koşar ve işlem 10 çevrim uzar (92 -> 102). Bu bir
    //   sızıntı DEĞİLDİR, çünkü tek bağımlılık P'dir ve P gizli değildir —
    //   p ile n zaten protokolün açık parametreleridir. Gizli olan a, b ve
    //   skalerdir; onların çevrim sayısına hiçbir etkisi yoktur.
    //
    //   Bu ayrımı yapmayan bir kontrol, alan değiştiğinde YANLIŞ ALARM verir.
    //   Bu yüzden referans her alan değişiminde yenilenir.
    task sabit_zaman_kontrol;
        begin
            if (mm_cev_dsp < 0) begin
                mm_cev_ref = ref_cev_r; mm_cev_dsp = dsp_cev_r;
            end else if (dsp_cev_r !== mm_cev_dsp) begin
                sabit_ihlal = sabit_ihlal + 1;
                $display("  [SABIT-ZAMAN IHLALI] beklenen %0d, olculen %0d",
                         mm_cev_dsp, dsp_cev_r);
            end
        end
    endtask

    task sabit_yenile;   // alan degisiminde referansi yeniden kur
        begin mm_cev_dsp = -1; end
    endtask

    // ── KAT sarmalayıcı ─────────────────────────────────────────────────
    //   *** BURADA SABIT-ZAMAN KONTROLU YAPILMAZ ***
    //   KAT listesi p ve n alanlari arasinda gidip geliyor; ilk cagri SOGUK
    //   (n0' hesaplanir, 103), sonrakiler SICAK (93). Iki yolu ayirmadan
    //   olcmek YANLIS ALARM uretir — ilk kosuda tam bunu yasadik: 9 adet
    //   "IHLAL" satiri, hicbiri gercek degildi. Kontrolun kendisi degil,
    //   nereye konuldugu yanlisti.
    //   Sabit zaman hukmu C (sicak, sabit P) ve D (soguk) bolumlerinde,
    //   iki yol AYRI AYRI olculerek verilir.
    task KAT(input [255:0] p, input [255:0] a, input [255:0] b,
             input [255:0] r_mm, input [255:0] r_add, input [255:0] r_sub);
        begin
            kostur(p, a, b, 2'b10); karsilastir(r_mm,  1'b1, "KAT MontMult");
            kostur(p, a, b, 2'b00); karsilastir(r_add, 1'b1, "KAT ModAdd");
            kostur(p, a, b, 2'b01); karsilastir(r_sub, 1'b1, "KAT ModSub");
        end
    endtask

    integer tur;
    reg [255:0] ra, rb, aktif_p;
    integer alan;

    initial begin
        $display("=========================================================");
        $display(" TB-26 : modular_alu_dsp  (DSP48E1 / CIOS Montgomery)");
        $display("   Referans = modular_alu.v  (diferansiyel test)");
        $display("=========================================================");

        rst_n=1'b0; pkt_r=32'd0; pkt_vld_r=1'b0; pkt_sel_r=2'b00;
        opcode_r=2'b00; start_r=1'b0;
        repeat (10) @(posedge clk);
        @(negedge clk); rst_n=1'b1;
        repeat (5) @(posedge clk);

        // ── A + B) KAT ve kenar durumlar ────────────────────────────────
        $display("\n [A/B] KAT + kenar durumlar (Python altin modelinden)...");

        // ---- GF(p) : NIST P-256 asali ----
        KAT(P_ASAL,
            256'h0000000000000000000000000000000000000000000000000000000000000000,
            256'h0000000000000000000000000000000000000000000000000000000000000000,
            256'h0000000000000000000000000000000000000000000000000000000000000000,
            256'h0000000000000000000000000000000000000000000000000000000000000000,
            256'h0000000000000000000000000000000000000000000000000000000000000000);

        KAT(P_ASAL,
            256'h0000000000000000000000000000000000000000000000000000000000000001,
            256'h0000000000000000000000000000000000000000000000000000000000000001,
            256'hfffffffe00000003fffffffd0000000200000001fffffffe0000000300000000,
            256'h0000000000000000000000000000000000000000000000000000000000000002,
            256'h0000000000000000000000000000000000000000000000000000000000000000);

        KAT(P_ASAL,
            256'hffffffff00000001000000000000000000000000fffffffffffffffffffffffe,
            256'hffffffff00000001000000000000000000000000fffffffffffffffffffffffe,
            256'hfffffffe00000003fffffffd0000000200000001fffffffe0000000300000000,
            256'hffffffff00000001000000000000000000000000fffffffffffffffffffffffd,
            256'h0000000000000000000000000000000000000000000000000000000000000000);

        KAT(P_ASAL,
            256'hffffffff00000001000000000000000000000000fffffffffffffffffffffffe,
            256'h0000000000000000000000000000000000000000000000000000000000000001,
            256'h00000000fffffffd00000002fffffffdffffffff00000001fffffffcffffffff,
            256'h0000000000000000000000000000000000000000000000000000000000000000,
            256'hffffffff00000001000000000000000000000000fffffffffffffffffffffffd);

        // R mod p ile kendisi: MontMult(R,R) = R  (Montgomery birim testi)
        KAT(P_ASAL,
            256'h00000000fffffffeffffffffffffffffffffffff000000000000000000000001,
            256'h00000000fffffffeffffffffffffffffffffffff000000000000000000000001,
            256'h00000000fffffffeffffffffffffffffffffffff000000000000000000000001,
            256'h00000001fffffffdfffffffffffffffffffffffe000000000000000000000002,
            256'h0000000000000000000000000000000000000000000000000000000000000000);

        KAT(P_ASAL,
            256'h23b8c1e9392456de3eb13b9046685257bdd640fb06671ad11c80317fa3b1799d,
            256'h972a846916419f828b9d2434e465e150bd9c66b3ad3c2d6d1a3d1fa7bc8960a9,
            256'hc072c27541914018394d7a9ccf9c134920b13576a7193e254a608f68e6e4b2d8,
            256'hbae346524f65f660ca4e5fc52ace33a87b72a7aeb3a3483e36bd5127603ada46,
            256'h8c8e3d7f22e2b75cb314175b620271070039da48592aed64024311d7e72818f3);

        KAT(P_ASAL,
            256'hc241330b01a9e71fde8a774bcf36d58b4737819096da1dac72ff5d2a386ecbe0,
            256'h371ecd7b27cd813047229389571aa8766c307511b2b9437a28df6ec4ce4a2bbd,
            256'h143cacec036dc1bbc69e82ecd2987ea1ace13819b42dac3f164b819351500d58,
            256'hf96000862977685025ad0ad526517e01b367f6a2499361269bdecbef06b8f79d,
            256'h8b22658fd9dc65ef9767e3c2781c2d14db070c7ee420da324a1fee656a24a023);

        // ---- GF(n) : P-256 mertebesi (n0' = 0xee00bc4f, onbellek degisir) ----
        KAT(N_MERTEBE,
            256'h0000000000000000000000000000000000000000000000000000000000000001,
            256'h0000000000000000000000000000000000000000000000000000000000000001,
            256'h60d066334905c1e907f8b6041e607725badef3e243566fafce1bc8f79c197c79,
            256'h0000000000000000000000000000000000000000000000000000000000000002,
            256'h0000000000000000000000000000000000000000000000000000000000000000);

        KAT(N_MERTEBE,
            256'hffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632550,
            256'hffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632550,
            256'h60d066334905c1e907f8b6041e607725badef3e243566fafce1bc8f79c197c79,
            256'hffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc63254f,
            256'h0000000000000000000000000000000000000000000000000000000000000000);

        KAT(N_MERTEBE,
            256'h5be6128e18c267976142ea7d17be31111a2a73ed562b0f79c37459eef50bea63,
            256'h759cde66bacfb3d00b1f9163ce9ff57f43b7a3a69a8dca03580d7b71d8f56413,
            256'h6f1ff6e1ce7198e0a820abf48ea1a73066904f29b1e246b473e00499bf06d732,
            256'hd182f0f4d3921b676c627be0e65e26905de21793f0b8d97d1b81d560ce014e76,
            256'he64934265df2b3c856235919491e3b919359caf462b4e3fb5f20a9401879aba1);

        KAT(N_MERTEBE,
            256'hfc377a4c4a15544dc5e7ce8a3a578a8ea9488d990bbb259911ce5dd2b45ed1f0,
            256'h7412b29347294739614ff3d719db3ad0ddd1dfb23b982ef8daf61a26146d3f31,
            256'hed49b7ee613fe1b6807052c734d0a5f3f280cf1985cf0e01d426a70502f8e7a1,
            256'h704a2ce0913e9b862737c2615432c55fca33729da03bb60cf90aad35cc68ebd0,
            256'h8824c7b902ec0d146497dab3207c4fbdcb76ade6d022f6a036d843ac9ff192bf);

        $display("       KAT bitti: %0d dogrulama, %0d hata", gecen, hata_say);

        // ── C) Rastgele diferansiyel ────────────────────────────────────
        //   Alan DEGISTIREREK kosuluyor: n0' onbelleginin gecersizlestirme
        //   mantigi ancak P degisince sinanir. Sabit P ile kosmak, onbellegi
        //   hic yanlislamayacagi icin o hatayi GORMEZDI.
        $display("\n [C] Rastgele diferansiyel: alan basina %0d tur...", N_RASTGELE);
        for (alan = 0; alan < 2; alan = alan + 1) begin
            aktif_p = (alan == 0) ? P_ASAL : N_MERTEBE;
            // n0' onbellegini bu alan icin isit, sonra sabit-zaman
            // referansini yenile: 92/102 farki alarm uretmesin.
            kostur(aktif_p, 256'd1, 256'd1, 2'b10);
            karsilastir(256'd0, 1'b0, "isitma MontMult");
            sabit_yenile();
            for (tur = 0; tur < N_RASTGELE; tur = tur + 1) begin
                ra = {$urandom, $urandom, $urandom, $urandom,
                      $urandom, $urandom, $urandom, $urandom};
                rb = {$urandom, $urandom, $urandom, $urandom,
                      $urandom, $urandom, $urandom, $urandom};
                if (ra >= aktif_p) ra = ra - aktif_p;
                if (rb >= aktif_p) rb = rb - aktif_p;

                kostur(aktif_p, ra, rb, 2'b10);
                karsilastir(256'd0, 1'b0, "rastgele MontMult");
                sabit_zaman_kontrol();

                kostur(aktif_p, ra, rb, 2'b00);
                karsilastir(256'd0, 1'b0, "rastgele ModAdd");

                kostur(aktif_p, ra, rb, 2'b01);
                karsilastir(256'd0, 1'b0, "rastgele ModSub");
            end
            $display("       alan %0d bitti (P = 0x%08h...)", alan, aktif_p[255:224]);
        end

        // ── D) Alan degisimi ARDI ARDINA: onbellek yanlislama stresi ────
        $display("\n [D] Alan degisimi stresi (p <-> n, ardisik)...");
        for (tur = 0; tur < 20; tur = tur + 1) begin
            aktif_p = (tur % 2 == 0) ? P_ASAL : N_MERTEBE;
            ra = {$urandom, $urandom, $urandom, $urandom,
                  $urandom, $urandom, $urandom, $urandom};
            rb = {$urandom, $urandom, $urandom, $urandom,
                  $urandom, $urandom, $urandom, $urandom};
            if (ra >= aktif_p) ra = ra - aktif_p;
            if (rb >= aktif_p) rb = rb - aktif_p;
            kostur(aktif_p, ra, rb, 2'b10);
            karsilastir(256'd0, 1'b0, "alan degisimi MontMult");
            // Her turda onbellek gecersiz (P degisiyor) -> hepsi SOGUK yol.
            // Burada da deger SABIT olmali; degilse n0' yolu veriye bagli
            // davraniyor demektir ve bu gercek bir sizinti olurdu.
            if (cev_soguk < 0) cev_soguk = dsp_cev_r;
            else if (dsp_cev_r !== cev_soguk) begin
                soguk_ihlal = soguk_ihlal + 1;
                $display("  [SOGUK YOL DEGISKEN] beklenen %0d, olculen %0d",
                         cev_soguk, dsp_cev_r);
            end
        end

        // ── E) Sabit zaman hükmü ────────────────────────────────────────
        kontrol(sabit_ihlal == 0,
                "E1: *** sabit P'de MontMult cevrimi VERIDEN BAGIMSIZ ***");
        kontrol(soguk_ihlal == 0,
                "E2: *** n0' yeniden hesabi da SABIT cevrim (P'ye bagli, veriye degil) ***");

        // ── Özet ────────────────────────────────────────────────────────
        $display("\n---------------------------------------------------------");
        $display(" CEVRIM (i_start -> o_done):");
        $display("   modular_alu     (CSA, bit-seri) : %0d cevrim", mm_cev_ref);
        $display("   modular_alu_dsp (CIOS, DSP)     : %0d cevrim  [n0' onbellekte]",
                 mm_cev_dsp);
        $display("   modular_alu_dsp (P degistiginde) : %0d cevrim  [n0' yeniden]",
                 cev_soguk);
        if (mm_cev_dsp > 0)
            $display("   HIZLANMA                        : %0d.%02dx",
                     mm_cev_ref / mm_cev_dsp,
                     ((mm_cev_ref * 100) / mm_cev_dsp) % 100);
        $display("---------------------------------------------------------");
        if (hata_say == 0)
            $display(" TB-26 SONUC: TUM TESTLER GECTI (%0d dogrulama)", gecen);
        else
            $display(" TB-26 SONUC: %0d TEST KALDI (%0d gecti)", hata_say, gecen);
        $display("=========================================================");
        $finish;
    end

    initial begin
        #(200_000_000);
        $display("\n *** TB-26 GENEL ZAMAN ASIMI ***");
        $display("     ref.state_r = %0d  dsp.state_r = %0d",
                 ref_dut.state_r, dsp_dut.state_r);
        $finish;
    end

endmodule
