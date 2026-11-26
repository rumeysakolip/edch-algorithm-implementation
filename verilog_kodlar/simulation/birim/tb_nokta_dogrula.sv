// =============================================================================
// Modül   : tb_nokta_dogrula.sv                                       (TB-14)
// Proje   : FPGA Tabanlı Güvenli Anahtar Yönetimi ve Kripto Hızlandırıcı (5260007)
// -----------------------------------------------------------------------------
// AMAÇ:
//   nokta_dogrula.v'nin NIST P-256 tam açık-anahtar doğrulamasını (SP 800-56A
//   Rev.3 §5.6.2.3.3) doğru uyguladığını KAT (Known Answer Test) yöntemiyle
//   kanıtlamak.
//
//   DUT, paylaşılan MALU'nun İSTEMCİSİDİR. Bu TB'de arbiter yoktur; DUT tek
//   sahip olarak gerçek modular_alu örneğine DOĞRUDAN bağlanır. Böylece hem
//   doğrulama mantığı hem de MALU el sıkışması birlikte sınanır — sahte
//   (mock) MALU kullanılsaydı dispatch alt-FSM'i test edilmemiş kalırdı.
//
// -----------------------------------------------------------------------------
// NEDEN GÖMÜLÜ VEKTÖR, NEDEN SV ALTIN-MODELİ DEĞİL:
//   DUT'un çıktısı 256-bit bir değer değil, TEK BİR HÜKÜMDÜR (geçerli/geçersiz).
//   Böyle bir modülde SV içinde Montgomery aritmetiği yeniden yazmak, testi
//   test edilen mantığın aynısına bağımlı kılar — ortak bir hata iki tarafta
//   da aynı yönde kayar ve test sessizce geçer. Bunun yerine vektörler BAĞIMSIZ
//   bir kaynakta (Python, eğri denklemi doğrudan p modunda) üretilip beklenen
//   hüküm sabitlenmiştir.
//
//   Vektör üretimi: host/nokta_vektor_uret.py  (aynı tohum: 5260007)
//   Çapraz kontrol : vx[0] = ecdh_kex_top.v'deki GX_MONT sabitiyle
//                    bit-birebir eşleşir — Montgomery konvansiyonu çapası.
//
// -----------------------------------------------------------------------------
// KAPSANAN SENARYOLAR:
//   POZİTİF  : G, 2G, 3G, 5G, 7G, 13G ve bir negatif nokta (x, −y).
//              Son madde önemlidir: aşırı-reddetme (over-rejection) yapan bir
//              uygulama burada takılır; (x, p−y) eğri üzerinde GEÇERLİ bir
//              noktadır ve kabul edilmelidir.
//   NEGATİF  : rastgele eğri dışı noktalar; doğru x + bozulmuş y; doğru y +
//              bozulmuş x (invalid-curve saldırısının tipik biçimi); koordinat
//              takası; sonsuzluk gösterimi (0,0); aralıkta ama eğri dışı.
//   ARALIK   : x = p, y = p, x = 2^256−1 → GF(p) elemanı değil, reddedilmeli.
//   ARIZA    : mod_p = 0 → bu noktanın suçu DEĞİLDİR; o_gecerli değil o_err
//              kalkmalıdır. Bu ayrımın korunması önemlidir: üst modül geçersiz
//              anahtarı (protokol hatası) ile bozuk donanımı (sistem hatası)
//              farklı ele almalıdır.
//   TEKRAR   : Tüm vektörler ardışık koşar; DUT her turdan sonra temiz IDLE'a
//              dönmezse sonraki vektör hata verir (bayat durum yakalanır).
//
// ÇALIŞTIRMA (Vivado xsim):
//   xvlog -sv tb_nokta_dogrula.sv
//   xvlog nokta_dogrula.v modular_alu_dsp.v
//   xelab -debug typical tb_nokta_dogrula -s sim_nd
//   xsim sim_nd -R
//
// Standart : SystemVerilog-2012
// Tarih    : Temmuz 2026
// =============================================================================

`timescale 1ns / 1ps

module tb_nokta_dogrula;

// ── Saat / reset ──────────────────────────────────────────────────────────
localparam real SAAT_PERIYOT = 10.0;      // 100 MHz
localparam int  ZAMAN_ASIMI  = 200_000;   // çevrim / vektör (bol paylı)

// Hükmü yazdırılabilir metne çevirir.
//   NOT: dogrudan (kosul ? "KABUL" : "RED") YAZILMAMALIDIR. SystemVerilog'da
//   string literalleri ternary icinde ortak genislige hizalanir ve kisa olan
//   SOLDAN null bayt ile doldurulur; %s bunu bozuk karakter olarak basar.
//   Fonksiyon donusu 'string' tipinde oldugu icin bu sorun olusmaz.
function automatic string hkm(input logic k);
    return k ? "KABUL" : "RED";
endfunction

logic clk_in = 1'b0;
logic rst_n  = 1'b0;
always #(SAAT_PERIYOT/2.0) clk_in = ~clk_in;

// ── DUT ↔ MALU bağlantı hatları ───────────────────────────────────────────
logic [31:0] dut_pkt_in;
logic        dut_pkt_vld;
logic [2:0]  dut_pkt_sel;
logic        dut_start;
logic        dut_gecerli, dut_rdy, dut_done, dut_err;

logic [31:0] mo_dat;  logic mo_vld;  logic [1:0] mo_sel, mo_opc;  logic mo_st;
logic [31:0] mi_out;  logic mi_vld, mi_last, mi_rdy, mi_done, mi_err;

// ── Giriş seçicileri (nokta_dogrula.v ile aynı) ───────────────────────────
localparam logic [2:0] NIX_MODP = 3'd0, NIX_X = 3'd1, NIX_Y = 3'd2;

localparam logic [255:0] P256 =
    256'hffffffff00000001000000000000000000000000ffffffffffffffffffffffff;

// ═════════════════════════════════════════════════════════════════════════
//  DUT + gerçek MALU (doğrudan bağlı — bu TB'de tek sahip DUT'tur)
// ═════════════════════════════════════════════════════════════════════════
nokta_dogrula dut (
    .clk_in(clk_in), .rst_n(rst_n),
    .i_pkt_in(dut_pkt_in), .i_pkt_vld(dut_pkt_vld), .i_pkt_sel(dut_pkt_sel),
    .i_start(dut_start),
    .o_gecerli(dut_gecerli), .o_rdy(dut_rdy), .o_done(dut_done), .o_err(dut_err),
    .mo_pkt_dat(mo_dat), .mo_pkt_vld(mo_vld), .mo_pkt_sel(mo_sel),
    .mo_opc(mo_opc), .mo_st(mo_st),
    .mi_pkt_out(mi_out), .mi_pkt_vld(mi_vld), .mi_pkt_last(mi_last),
    .mi_rdy(mi_rdy), .mi_done(mi_done), .mi_err(mi_err),
    .g_b_mont(256'hdc30061d04874834e5a220abf7212ed6acf005cd78843090d89cdf6229c4bddf)
);

// [ADIM-1] modular_alu -> modular_alu_dsp (port-port ayni, drop-in).
modular_alu_dsp malu (
    .clk_in(clk_in), .rst_n(rst_n),
    .i_pkt_in(mo_dat), .i_pkt_vld(mo_vld), .i_pkt_sel(mo_sel),
    .i_opcode(mo_opc), .i_start(mo_st),
    .o_pkt_out(mi_out), .o_pkt_vld(mi_vld), .o_pkt_last(mi_last),
    .o_rdy(mi_rdy), .o_done(mi_done), .o_err(mi_err)
);

// ═════════════════════════════════════════════════════════════════════════
//  TEST VEKTÖRLERİ  (host/nokta_vektor_uret.py çıktısı — tohum 5260007)
//  x ve y MONTGOMERY alanındadır; aralık-dışı vektörler bilinçli olarak ham
//  gönderilir (Montgomery'ye taşınmaz), çünkü test edilen şey aralık kontrolüdür.
// ═════════════════════════════════════════════════════════════════════════
localparam int VEK_SAY = 18;

string          ad [0:VEK_SAY-1];
logic [255:0]   vx [0:VEK_SAY-1];
logic [255:0]   vy [0:VEK_SAY-1];
logic           vb [0:VEK_SAY-1];   // beklenen: 1 = kabul

initial begin
  ad[ 0]="gecerli 1G";                  vx[ 0]=256'h18905f76a53755c679fb732b7762251075ba95fc5fedb60179e730d418a9143c; vy[ 0]=256'h8571ff1825885d85d2e88688dd21f3258b4ab8e4ba19e45cddf25357ce95560a; vb[ 0]=1'b1;
  ad[ 1]="gecerli 2G";                  vx[ 1]=256'hf6bb32e43dcf3a3b732205038d1490d9aa6ae3c1a433827d850046d410ddd64d; vy[ 1]=256'h78c577510a5b8a3b19a8fb0e92042dbe152cd7cbeb236ff82f3648d361bee1a5; vb[ 1]=1'b1;
  ad[ 2]="gecerli 3G";                  vx[ 2]=256'h26936a3fb6ff747e66ad77dd87cbbc98b027f84a087d81fbffac3f904eebc127; vy[ 2]=256'hd5f06a29e587cc07788208311a2ee98e583e47ad0861fe1ab04c5c1fc983a7eb; vb[ 2]=1'b1;
  ad[ 3]="gecerli 5G";                  vx[ 3]=256'hc9079605890523c8941cb5aad076c20c90ec649a94b9537dbe1b8aaec45c61f5; vy[ 3]=256'h73a076bb2dd1e9163540a9877e7a1f6873c568efe5eb882beb309b4ae7ba4f10; vb[ 3]=1'b1;
  ad[ 4]="gecerli 7G";                  vx[ 4]=256'h13ba5119c3123e03f43eaab50c23bb082bd20213d23c00f70746354ea0173b4f; vy[ 4]=256'heaedd9156e240867ef933bdc77c941956742f2f25da67bdd2847d0303f5b9d4d; vb[ 4]=1'b1;
  ad[ 5]="gecerli 13G";                 vx[ 5]=256'h738477ac5395b759bcbcd43f559e98110e356769856fd30dccc425634b2ed709; vy[ 5]=256'hfbc08769c9e7b7977cd06422bd1f5bc168748390742ed2e335752b90c00ee17f; vb[ 5]=1'b1;
  ad[ 6]="negatif nokta (x,-y)";        vx[ 6]=256'h26936a3fb6ff747e66ad77dd87cbbc98b027f84a087d81fbffac3f904eebc127; vy[ 6]=256'h2a0f95d51a7833f9877df7cee5d11671a7c1b853f79e01e54fb3a3e0367c5814; vb[ 6]=1'b1;
  ad[ 7]="rastgele egri disi #1";       vx[ 7]=256'ha16f59d5d3810cfebb670b6593523ac4c553cad5bbbb1a18a882a4fd94cd2547; vy[ 7]=256'h4ed71683a529b24108e953429b4e543bdeb86df3d1862182ec688d12a20c0dde; vb[ 7]=1'b0;
  ad[ 8]="rastgele egri disi #2";       vx[ 8]=256'hc72ba0d3c5d9750b81da73a52e77363d1880f399858f8b1ce8d8d5357e0fba1c; vy[ 8]=256'he02ab35039af48c22a1a584e7d143d1db52237a90eb3b16c4ea826a6825ae5cf; vb[ 8]=1'b0;
  ad[ 9]="rastgele egri disi #3";       vx[ 9]=256'hecba3545abe1ddcb41d739c4b02eee8cf1637fa3cc4a7ae4449c10980327e7c8; vy[ 9]=256'hb44800ed5d35049e2d52354d4657c02f0bb415fb88bfebdc59a62e1df5e9fb06; vb[ 9]=1'b0;
  ad[10]="dogru x, y+1 (invalid-curve)";vx[10]=256'hc9079605890523c8941cb5aad076c20c90ec649a94b9537dbe1b8aaec45c61f5; vy[10]=256'h73a076bc2dd1e9153540a9877e7a1f6873c568eee5eb882beb309b4ae7ba4f11; vb[10]=1'b0;
  ad[11]="dogru y, x+1 (invalid-curve)";vx[11]=256'h13ba511ac3123e02f43eaab50c23bb082bd20212d23c00f70746354ea0173b50; vy[11]=256'heaedd9156e240867ef933bdc77c941956742f2f25da67bdd2847d0303f5b9d4d; vb[11]=1'b0;
  ad[12]="koordinat takasi (y,x)";      vx[12]=256'h78c577510a5b8a3b19a8fb0e92042dbe152cd7cbeb236ff82f3648d361bee1a5; vy[12]=256'hf6bb32e43dcf3a3b732205038d1490d9aa6ae3c1a433827d850046d410ddd64d; vb[12]=1'b0;
  ad[13]="sonsuzluk gosterimi (0,0)";   vx[13]=256'h0;                                                                 vy[13]=256'h0;                                                                 vb[13]=1'b0;
  ad[14]="x=p-1 (aralikta, egri disi)"; vx[14]=256'hfffffffe00000002000000000000000000000001fffffffffffffffffffffffe; vy[14]=256'h00000000fffffffeffffffffffffffffffffffff000000000000000000000001; vb[14]=1'b0;
  ad[15]="x=p (ARALIK DISI)";           vx[15]=256'hffffffff00000001000000000000000000000000ffffffffffffffffffffffff; vy[15]=256'h8571ff1825885d85d2e88688dd21f3258b4ab8e4ba19e45cddf25357ce95560a; vb[15]=1'b0;
  ad[16]="y=p (ARALIK DISI)";           vx[16]=256'h18905f76a53755c679fb732b7762251075ba95fc5fedb60179e730d418a9143c; vy[16]=256'hffffffff00000001000000000000000000000000ffffffffffffffffffffffff; vb[16]=1'b0;
  ad[17]="x=2^256-1 (ARALIK DISI)";     vx[17]={256{1'b1}};                                                            vy[17]=256'h8571ff1825885d85d2e88688dd21f3258b4ab8e4ba19e45cddf25357ce95560a; vb[17]=1'b0;
end

// ═════════════════════════════════════════════════════════════════════════
//  SÜRÜCÜ GÖREVLERİ
// ═════════════════════════════════════════════════════════════════════════
int gecen_r, kalan_r;

// 256-bit değeri 8 × 32-bit paket hâlinde LSB-önce yükler.
task automatic paket_yaz(input logic [2:0] sel, input logic [255:0] deger);
    for (int i = 0; i < 8; i++) begin
        @(negedge clk_in);
        dut_pkt_in  = deger[i*32 +: 32];
        dut_pkt_sel = sel;
        dut_pkt_vld = 1'b1;
    end
    @(negedge clk_in);
    dut_pkt_vld = 1'b0;
endtask

// Bir noktayı koşturur; hüküm ve arıza bayrağını döndürür.
task automatic nokta_kos(input  logic [255:0] modp,
                        input  logic [255:0] px,
                        input  logic [255:0] py,
                        output logic         gecerli,
                        output logic         ariza,
                        output int           cevrim);
    int sayac;
    paket_yaz(NIX_MODP, modp);
    paket_yaz(NIX_X,    px);
    paket_yaz(NIX_Y,    py);

    @(negedge clk_in);  dut_start = 1'b1;
    @(negedge clk_in);  dut_start = 1'b0;

    sayac   = 0;
    gecerli = 1'b0;
    ariza   = 1'b0;
    forever begin
        @(posedge clk_in);
        sayac++;
        if (dut_err)  begin ariza = 1'b1; break; end
        if (dut_done) begin gecerli = dut_gecerli; break; end
        if (sayac >= ZAMAN_ASIMI) begin
            $display("  !! ZAMAN ASIMI: %0d cevrimde ne o_done ne o_err geldi", sayac);
            ariza = 1'bx;
            break;
        end
    end
    cevrim = sayac;
    // DUT'un IDLE'a dönüp hazır olduğunu teyit et (bayat durum avı)
    repeat (4) @(posedge clk_in);
    if (dut_rdy !== 1'b1)
        $display("  !! UYARI: kosum sonrasi o_rdy yukselmedi — DUT temiz IDLE'a donmedi");
endtask

// ═════════════════════════════════════════════════════════════════════════
//  ANA AKIŞ
// ═════════════════════════════════════════════════════════════════════════
logic gecerli_w, ariza_w;
int   cevrim_w, cevrim_min, cevrim_max;

initial begin
    dut_pkt_in  = 32'd0;
    dut_pkt_vld = 1'b0;
    dut_pkt_sel = 3'd0;
    dut_start   = 1'b0;
    gecen_r     = 0;
    kalan_r     = 0;
    cevrim_min  = 1_000_000;
    cevrim_max  = 0;

    $display("");
    $display("==================================================================");
    $display(" TB-14  nokta_dogrula.v  —  NIST P-256 tam acik-anahtar dogrulama");
    $display(" SP 800-56A Rev.3 §5.6.2.3.3   |   %0d vektor", VEK_SAY);
    $display("==================================================================");

    repeat (5) @(posedge clk_in);
    rst_n = 1'b1;
    repeat (5) @(posedge clk_in);

    // ── SENARYO A: vektör kümesi ─────────────────────────────────────────
    $display("");
    $display(" SENARYO A — hukum dogrulugu");
    $display(" %-4s %-30s %-8s %-8s %-9s %s", "no", "vektor", "beklenen", "cikan", "cevrim", "sonuc");
    $display(" ----------------------------------------------------------------------------");

    for (int v = 0; v < VEK_SAY; v++) begin
        nokta_kos(P256, vx[v], vy[v], gecerli_w, ariza_w, cevrim_w);

        if (cevrim_w < cevrim_min) cevrim_min = cevrim_w;
        if (cevrim_w > cevrim_max) cevrim_max = cevrim_w;

        if (ariza_w !== 1'b0) begin
            $display(" %-4d %-30s %-8s %-8s %-9d %s", v, ad[v],
                     hkm(vb[v]), "ARIZA", cevrim_w, "<<< KALDI");
            kalan_r++;
        end else if (gecerli_w === vb[v]) begin
            $display(" %-4d %-30s %-8s %-8s %-9d %s", v, ad[v],
                     hkm(vb[v]), hkm(gecerli_w), cevrim_w, "gecti");
            gecen_r++;
        end else begin
            $display(" %-4d %-30s %-8s %-8s %-9d %s", v, ad[v],
                     hkm(vb[v]), hkm(gecerli_w), cevrim_w, "<<< KALDI");
            kalan_r++;
        end
    end

    // ── SENARYO B: arıza ayrımı (mod_p = 0) ──────────────────────────────
    $display("");
    $display(" SENARYO B — ariza / gecersizlik ayrimi");
    nokta_kos(256'd0, vx[0], vy[0], gecerli_w, ariza_w, cevrim_w);
    if (ariza_w === 1'b1 && gecerli_w === 1'b0) begin
        $display("   mod_p=0 -> o_err yukseldi, o_gecerli dusuk kaldi          gecti");
        gecen_r++;
    end else begin
        $display("   mod_p=0 -> BEKLENEN o_err=1/o_gecerli=0, CIKAN err=%b gec=%b  <<< KALDI",
                 ariza_w, gecerli_w);
        kalan_r++;
    end

    // Arızadan sonra modül hâlâ çalışıyor mu?
    nokta_kos(P256, vx[0], vy[0], gecerli_w, ariza_w, cevrim_w);
    if (ariza_w === 1'b0 && gecerli_w === 1'b1) begin
        $display("   ariza sonrasi kurtarma: gecerli nokta yine KABUL edildi    gecti");
        gecen_r++;
    end else begin
        $display("   ariza sonrasi kurtarma BASARISIZ (err=%b gec=%b)           <<< KALDI",
                 ariza_w, gecerli_w);
        kalan_r++;
    end

    // ── SENARYO C: sabit zamanlılık gözlemi ──────────────────────────────
    //   Eğri kontrolü yan-kanal açısından kritik DEĞİLDİR (Qb zaten açıktır,
    //   gizli veri işlenmez). Yine de aralık kontrolünün erken çıkışı ile tam
    //   eğri kontrolü arasındaki çevrim farkı raporlanır: bu fark saldırgana
    //   yalnız "noktam aralık dışıydı" bilgisini verir, sır sızdırmaz.
    $display("");
    $display(" SENARYO C — cevrim dagilimi");
    $display("   en kisa = %0d cevrim  (aralik kontrolunde erken cikis)", cevrim_min);
    $display("   en uzun = %0d cevrim  (~%0.1f us @100 MHz, tam egri kontrolu)",
             cevrim_max, cevrim_max / 100.0);
    $display("   NOT: gizli veri islenmedigi icin bu fark yan-kanal riski degildir.");

    // ── ÖZET ─────────────────────────────────────────────────────────────
    $display("");
    $display("==================================================================");
    $display(" OZET:  %0d gecti / %0d kaldi   (toplam %0d kontrol)",
             gecen_r, kalan_r, gecen_r + kalan_r);
    if (kalan_r == 0)
        $display(" SONUC: *** TB-14 BASARILI ***");
    else
        $display(" SONUC: *** TB-14 BASARISIZ — %0d kontrol kaldi ***", kalan_r);
    $display("==================================================================");
    $display("");
    $finish;
end

// Genel emniyet kilidi: TB'nin kendisi asılırsa simülasyonu bitir.
initial begin
    #(SAAT_PERIYOT * ZAMAN_ASIMI * (VEK_SAY + 8));
    $display(" !! TB GENEL ZAMAN ASIMI — simulasyon zorla sonlandirildi");
    $finish;
end

endmodule
