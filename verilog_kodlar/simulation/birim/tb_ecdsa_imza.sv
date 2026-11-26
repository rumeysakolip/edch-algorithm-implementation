// =============================================================================
// Modül   : tb_ecdsa_imza.sv                                          (TB-18)
// Proje   : FPGA Tabanlı Güvenli Anahtar Yönetimi ve Kripto Hızlandırıcı (5260007)
// -----------------------------------------------------------------------------
// AMAÇ:
//   ecdsa_imza.v'nin s = k^(-1)(e + r·d) mod n hesabını doğru yaptığını
//   kanıtlamak.
//
// -----------------------------------------------------------------------------
// VEKTÖRLERİN ÜRETİMİ — NEDEN GÜVENİLİR:
//   KAT vektörleri Python'da iki AYRI yoldan geçirilerek üretildi:
//     1) RTL'in izleyeceği adım dizisi birebir modellendi (Montgomery alan
//        akışı dahil) ve (r,s) üretildi.
//     2) Üretilen (r,s) çifti, o adım dizisinden TAMAMEN BAĞIMSIZ bir ECDSA
//        doğrulayıcısıyla sınandı:  u1·G + u2·Q'nun x'i r'ye eşit mi?
//   6/6 geçti. Yani vektörler yalnızca "modelin dediği" değil, gerçekten
//   GEÇERLİ ECDSA imzalarıdır.
//
//   Bu iki aşama önemliydi: modelin ilk hâli Montgomery ters alma yerine düz
//   üs alma yapıyordu ve 6/6 BAŞARISIZ oldu. Tek aşamalı bir model bu hatayı
//   yakalayamazdı — RTL de aynı yanlışı yapsaydı test sessizce geçerdi.
//
// -----------------------------------------------------------------------------
// KAPSANAN SENARYOLAR:
//   A) KAT       : 4 vektör, (r,s) bit-birebir.
//   B) SABİT ZAMAN: tüm vektörlerde aynı çevrim sayısı. ECDSA'da süre gizli
//                   veriye (k, d) bağlı olmamalıdır.
//   C) Rx >= n   : indirgeme yolu (tek koşullu çıkarma) sınanır.
//   D) k = 0     : geçersiz nonce reddedilir (o_k_gecersiz).
//   E) ARDIŞIK   : ikinci koşum aynı sonucu verir (bayat durum avı).
//
// SÜRE UYARISI: her imza ~124.000 çevrim (1.24 ms) — ters alma baskın.
//               Toplam ~8 ms.
//
// ÇALIŞTIRMA (Vivado xsim):
//   xvlog -sv tb_ecdsa_imza.sv
//   xvlog ecdsa_imza.v mod_n_ters.v modular_alu_dsp.v
//   xelab -debug typical tb_ecdsa_imza -s sim_imza
//   xsim sim_imza -R
//
// Standart : SystemVerilog-2012
// Tarih    : Temmuz 2026
// =============================================================================

`timescale 1ns / 1ps

module tb_ecdsa_imza;

localparam real SAAT_PERIYOT = 10.0;
localparam int  VEK_ZAMAN_ASIMI = 500_000;

localparam logic [255:0] N_ORDER =
    256'hffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551;

localparam logic [2:0] EIX_MODN=3'd0, EIX_E=3'd1, EIX_RX=3'd2,
                       EIX_D=3'd3,    EIX_K=3'd4;

logic clk_in = 1'b0, rst_n = 1'b0;
always #(SAAT_PERIYOT/2.0) clk_in = ~clk_in;

// ── DUT ↔ MALU ────────────────────────────────────────────────────────────
logic [31:0] d_pkt_in;  logic d_pkt_vld;  logic [2:0] d_pkt_sel;  logic d_start;
wire  [31:0] d_pkt_out; wire  d_pkt_vld_o, d_pkt_sel_o, d_pkt_last;
wire         d_rdy, d_done, d_err, d_r0, d_s0, d_kgec;
wire [31:0] mo_dat; wire mo_vld; wire [1:0] mo_sel, mo_opc; wire mo_st;
wire [31:0] mi_out; wire mi_vld, mi_last, mi_rdy, mi_done, mi_err;

// FAZ 5 refactor: mod_n_ters artik ecdsa_imza'nin ICINDE DEGIL.
// Gercek sistemde ecdh_kex_top'ta TEK ornek olarak durur; TB de ayni
// yapiyi kurar. MALU ikisi arasinda arbitre edilir — tipki ust seviyede
// oldugu gibi, boylece TB gercek baglama duzenini sinar.
wire [31:0] imz_to_dat; wire imz_to_vld, imz_to_st; wire [1:0] imz_to_sel;
wire [31:0] mnt_out;    wire mnt_vld, mnt_last, mnt_rdy, mnt_done, mnt_err;
wire [31:0] mnt_mo_dat; wire mnt_mo_vld, mnt_mo_st; wire [1:0] mnt_mo_sel, mnt_mo_opc;

// Ters alma calisirken MALU onundur. ecdsa_imza ters sonucunu beklerken
// MALU'ya dokunmaz, dolayisiyla cakisma yok.
wire ters_aktif = !mnt_rdy;

ecdsa_imza dut (
    .clk_in(clk_in), .rst_n(rst_n),
    .i_pkt_in(d_pkt_in), .i_pkt_vld(d_pkt_vld), .i_pkt_sel(d_pkt_sel),
    .i_start(d_start),
    .o_pkt_out(d_pkt_out), .o_pkt_vld(d_pkt_vld_o), .o_pkt_sel(d_pkt_sel_o),
    .o_pkt_last(d_pkt_last), .o_rdy(d_rdy), .o_done(d_done), .o_err(d_err),
    .o_r_sifir(d_r0), .o_s_sifir(d_s0), .o_k_gecersiz(d_kgec),
    .to_pkt_dat(imz_to_dat), .to_pkt_vld(imz_to_vld),
    .to_pkt_sel(imz_to_sel), .to_st(imz_to_st),
    .ti_pkt_out(mnt_out), .ti_pkt_vld(mnt_vld),
    .ti_rdy(mnt_rdy), .ti_done(mnt_done), .ti_err(mnt_err),
    .mo_pkt_dat(mo_dat), .mo_pkt_vld(mo_vld), .mo_pkt_sel(mo_sel),
    .mo_opc(mo_opc), .mo_st(mo_st),
    .mi_pkt_out(mi_out), .mi_pkt_vld(mi_vld), .mi_pkt_last(mi_last),
    .mi_rdy(mi_rdy), .mi_done(mi_done), .mi_err(mi_err),
    .g_n_order(256'hffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551),
    .g_r2n(256'h66e12d94f3d956202845b2392b6bec594699799c49bd6fa683244c95be79eea2)
);

mod_n_ters mnt_ortak (
    .clk_in(clk_in), .rst_n(rst_n),
    .i_pkt_in(imz_to_dat), .i_pkt_vld(imz_to_vld),
    .i_pkt_sel(imz_to_sel), .i_start(imz_to_st),
    .o_pkt_out(mnt_out), .o_pkt_vld(mnt_vld), .o_pkt_last(mnt_last),
    .o_rdy(mnt_rdy), .o_done(mnt_done), .o_err(mnt_err),
    .mo_pkt_dat(mnt_mo_dat), .mo_pkt_vld(mnt_mo_vld), .mo_pkt_sel(mnt_mo_sel),
    .mo_opc(mnt_mo_opc), .mo_st(mnt_mo_st),
    .mi_pkt_out(mi_out), .mi_pkt_vld(mi_vld), .mi_pkt_last(mi_last),
    .mi_rdy(mi_rdy), .mi_done(mi_done), .mi_err(mi_err),
    .g_n_order(256'hffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551),
    .g_mont_bir_n(256'h00000000ffffffff00000000000000004319055258e8617b0c46353d039cdaaf)
);

// [ADIM-1] modular_alu -> modular_alu_dsp (port-port ayni, drop-in).
modular_alu_dsp malu (
    .clk_in(clk_in), .rst_n(rst_n),
    .i_pkt_in (ters_aktif ? mnt_mo_dat : mo_dat),
    .i_pkt_vld(ters_aktif ? mnt_mo_vld : mo_vld),
    .i_pkt_sel(ters_aktif ? mnt_mo_sel : mo_sel),
    .i_opcode (ters_aktif ? mnt_mo_opc : mo_opc),
    .i_start  (ters_aktif ? mnt_mo_st  : mo_st),
    .o_pkt_out(mi_out), .o_pkt_vld(mi_vld), .o_pkt_last(mi_last),
    .o_rdy(mi_rdy), .o_done(mi_done), .o_err(mi_err)
);

// ── KAT vektorleri (Python: RTL dizisi + BAGIMSIZ ECDSA dogrulamasi) ─────
localparam int VEK_SAY = 4;
logic [255:0] v_e[0:3], v_d[0:3], v_k[0:3], v_r[0:3], v_s[0:3];

initial begin
  v_e[0]=256'h4944c75f9135157d7634e944ea5fe98d86aaa1054f93b039d453d4ab22306ec7;
  v_d[0]=256'hf0f9b94dd1756914a5acbc6a8721dca6956e35d98e68c30d09579d641f27bfe1;
  v_k[0]=256'h20ea7706a70fc4ea335fafdb7541a879d37d0f48f962fe0663a1235261991715;
  v_r[0]=256'h038306b5ecce18cd4ebfe79053c5fd6d1ba59ee5866491294e8ae1e782dc90b9;
  v_s[0]=256'h2009a3bba0b27427170abc2a0cf4ee5ae30775a392c6d0516e84884019ebe97f;

  v_e[1]=256'hb80222519cbaee54195732d63ea8ddc917b243dedf21eb7a274163e8db15d9ef;
  v_d[1]=256'h783457eb7b52f41dbd7b159d8675a612a48ec36f1b274fa46af8debb7b347a51;
  v_k[1]=256'h22f95d3a809bcfc48d85e4e48a3e777b0de21cefef836fd810722a1e98f806bf;
  v_r[1]=256'h0e0c1338d97c9155c8665e054bfff7c5dcb7fa124ccf9365786682addcbdd909;
  v_s[1]=256'h3ed825684aec3dc01a21046182a3c957ce8aff0d8d93658bbada0f91bcd23030;

  v_e[2]=256'h4f3703b84a98fba5fdcda7354742ced449d1c82925967a66d0d5db05110990fc;
  v_d[2]=256'haf1f5025b4fe6a781186b44cb0a38f9fbed339fba7d24e1d5df13761c4c02b36;
  v_k[2]=256'h1969b5a54cc3b94ef8cbf519835f450b73a0c2e50c84ed034a012a673f33bf8d;
  v_r[2]=256'h0a4b855bc58ce1dfa8421805c7630973c6675187b6502985298e695b52b3825d;
  v_s[2]=256'he83ca4fdbb92370e0285e990d409da2d07641d640c8da0b0d3e854ad9f92ee7a;

  v_e[3]=256'h6b74cf7555a36ada40bdc7df6e596258beac710bd980e849f0f036573dd4c2ea;
  v_d[3]=256'h0e78a282d4e69db6f1eb4f755fcebfcafb4829e8ae408fe02475c2e783adc560;
  v_k[3]=256'hfd93c9b7d6f7724524788c0699ba78bc0c9a66970bfc849e4ec92fa13b2851e5;
  v_r[3]=256'h364ca615312ad39525460ed0321f20b4f897debf70ba85b408ed3e15f9b31221;
  v_s[3]=256'h8f0a35528e63f898396d5d49c3735a7c2a51947fb6db84b0f59a2471411825ef;
end

int gecen_r = 0, kalan_r = 0;
task automatic kontrol(input string a, input logic k);
    if (k) begin $display("   gecti   %s", a); gecen_r++; end
    else   begin $display("   KALDI   %s   <<<", a); kalan_r++; end
endtask

task automatic paket_yaz(input logic [2:0] sel, input logic [255:0] v);
    for (int i = 0; i < 8; i++) begin
        @(negedge clk_in);
        d_pkt_in = v[i*32 +: 32]; d_pkt_sel = sel; d_pkt_vld = 1'b1;
    end
    @(negedge clk_in); d_pkt_vld = 1'b0;
endtask

// Rx olarak r verilir (Rx < n oldugu vektorlerde indirgeme kimlik islemidir);
// C senaryosunda Rx = r + n verilerek indirgeme yolu ayrica sinanir.
task automatic imzala(input  logic [255:0] e, rx, d, k,
                      output logic [255:0] r_o, s_o,
                      output logic         ariza, r0, s0, kg,
                      output int           cevrim);
    int sayac, ri, si;
    paket_yaz(EIX_MODN, N_ORDER);
    paket_yaz(EIX_E,    e);
    paket_yaz(EIX_RX,   rx);
    paket_yaz(EIX_D,    d);
    paket_yaz(EIX_K,    k);
    @(negedge clk_in); d_start = 1'b1;
    @(negedge clk_in); d_start = 1'b0;

    sayac=0; ri=0; si=0; r_o=0; s_o=0; ariza=0; r0=0; s0=0; kg=0;
    forever begin
        @(posedge clk_in);
        sayac++;
        if (d_pkt_vld_o) begin
            if (!d_pkt_sel_o) begin r_o[ri*32 +: 32] = d_pkt_out; ri++; end
            else              begin s_o[si*32 +: 32] = d_pkt_out; si++; end
        end
        if (d_err) begin ariza = 1'b1; break; end
        if (d_done) begin r0 = d_r0; s0 = d_s0; kg = d_kgec; break; end
        if (sayac >= VEK_ZAMAN_ASIMI) begin
            $display("     !! ZAMAN ASIMI (%0d cevrim)", sayac);
            ariza = 1'bx; break;
        end
    end
    cevrim = sayac;
    repeat (4) @(posedge clk_in);
endtask

logic [255:0] r_o, s_o;
logic ariza, r0, s0, kg;
int   cevrim, cmin, cmax;

initial begin
    d_pkt_in=0; d_pkt_vld=0; d_pkt_sel=0; d_start=0;
    cmin = 1_000_000; cmax = 0;

    $display("");
    $display("==================================================================");
    $display(" TB-18  ecdsa_imza.v  —  s = k^-1 (e + r*d) mod n");
    $display(" Vektorler: RTL dizisi + BAGIMSIZ ECDSA dogrulayicisi (6/6)");
    $display(" UYARI: her imza ~1.24 ms (ters alma baskin), toplam ~8 ms");
    $display("==================================================================");

    repeat (5) @(posedge clk_in);
    rst_n = 1'b1;
    repeat (5) @(posedge clk_in);

    // [ADIM-1] ISINMA KOSUMU — modular_alu_dsp'nin n0' onbellegi resetten
    // sonra SOGUKTUR; onbellek bos oldugunda ilk MontMult, Newton-Raphson'u
    // calistirmak icin +10 cevrim harcar (bkz. modular_alu_dsp.v basligi).
    // Bu maliyet SADECE P'nin ilk kez yuklenmesine baglidir, k/d/e gibi
    // gizli verilerden TAMAMEN BAGIMSIZDIR — ama SENARYO A'daki ilk olculen
    // vektore "sanki veriye bagliymis gibi" bir fark bindirir. Onbellegi
    // burada bir kerelik, atilan bir imzayla isitiyoruz ki SENARYO B gercek
    // karsilastirmayi ayni (sicak) onbellek kosuluyla yapsin.
    imzala(v_e[0], v_r[0], v_d[0], v_k[0], r_o, s_o, ariza, r0, s0, kg, cevrim);

    $display("\n SENARYO A — KAT dogrulamasi");
    for (int v = 0; v < VEK_SAY; v++) begin
        imzala(v_e[v], v_r[v], v_d[v], v_k[v], r_o, s_o, ariza, r0, s0, kg, cevrim);
        if (cevrim < cmin) cmin = cevrim;
        if (cevrim > cmax) cmax = cevrim;
        if (ariza !== 1'b0 || r0 || s0 || kg) begin
            $display("   KALDI   vektor #%0d — ariza=%b r0=%b s0=%b kg=%b   <<<",
                     v+1, ariza, r0, s0, kg);
            kalan_r++;
        end else begin
            kontrol($sformatf("vektor #%0d  r dogru", v+1), r_o === v_r[v]);
            if (s_o !== v_s[v]) begin
                $display("           s beklenen 0x%064x", v_s[v]);
                $display("           s cikan    0x%064x", s_o);
            end
            kontrol($sformatf("vektor #%0d  s dogru  (%0d cevrim)", v+1, cevrim),
                    s_o === v_s[v]);
        end
    end

    $display("\n SENARYO B — sabit zamanlilik");
    $display("   en kisa = %0d | en uzun = %0d | yayilim = %0d",
             cmin, cmax, cmax - cmin);
    // Isinma kosumu sayesinde n0' onbellegi butun SENARYO A boyunca
    // sicak kalir (P her zaman n); yayilim artik yalnizca k/d/e'ye
    // duyarli olsaydi ortaya cikardi.
    kontrol("*** sure gizli veriden (k,d) BAGIMSIZ ***", (cmax - cmin) == 0);

    $display("\n SENARYO C — Rx >= n indirgemesi (tek kosullu cikarma)");
    // *** TB KUSURU (ilk kosumda bulundu) ***
    //   Once "Rx = v_r[0] + N_ORDER" yaziliyordu. Bu YANLISTI: v_r[0]
    //   (2^256 - n)'den BUYUK oldugu icin toplam 256 biti TASIRIYOR ve
    //   DUT'a sarmalanmis, alakasiz bir deger gidiyordu. RTL dogru
    //   davraniyordu; test verisi gecersizdi.
    //
    //   Rx >= n olabilmesi icin Rx in [n, 2^256) olmali, yani
    //   r = Rx - n < 2^256 - n  →  r en fazla ~224 bit.
    //   Gercek hayatta bu ~2^-32 olasilikli bir durumdur (Rx neredeyse
    //   her zaman n'den kucuktur) ama kod yolu yine de dogru olmalidir.
    //
    //   Asagidaki vektor Python'da uretildi: Rx = n + r_kucuk, tasma yok.
    imzala(256'h4944c75f9135157d7634e944ea5fe98d86aaa1054f93b039d453d4ab22306ec7,
           256'hffffffff123456799abcdef01234567857a3d99db94bf4fd8e76a9b30e977bc9, // Rx = n + r
           256'hf0f9b94dd1756914a5acbc6a8721dca6956e35d98e68c30d09579d641f27bfe1,
           256'h20ea7706a70fc4ea335fafdb7541a879d37d0f48f962fe0663a1235261991715,
           r_o, s_o, ariza, r0, s0, kg, cevrim);
    kontrol("Rx >= n -> r = Rx-n dogru indirgendi", !ariza &&
        r_o === 256'h00000000123456789abcdef0123456789abcdef0123456789abcdef012345678);
    kontrol("Rx >= n -> s dogru hesaplandi", !ariza &&
        s_o === 256'h2a04e64d9d36070b05a5e3f3b354ea372327e5a2a23def5028c440dd727f897d);

    $display("\n SENARYO D — gecersiz nonce");
    imzala(v_e[0], v_r[0], v_d[0], 256'd0, r_o, s_o, ariza, r0, s0, kg, cevrim);
    kontrol("k = 0 -> o_k_gecersiz kalkti", kg === 1'b1);
    imzala(v_e[0], v_r[0], v_d[0], N_ORDER, r_o, s_o, ariza, r0, s0, kg, cevrim);
    kontrol("k = n -> o_k_gecersiz kalkti", kg === 1'b1);

    $display("\n SENARYO E — ardisik kosum (bayat durum avi)");
    imzala(v_e[1], v_r[1], v_d[1], v_k[1], r_o, s_o, ariza, r0, s0, kg, cevrim);
    kontrol("gecersiz nonce sonrasi normal imza calisiyor",
            !ariza && !kg && r_o === v_r[1] && s_o === v_s[1]);

    $display("");
    $display("==================================================================");
    $display(" OZET:  %0d gecti / %0d kaldi   (toplam %0d dogrulama)",
             gecen_r, kalan_r, gecen_r + kalan_r);
    if (kalan_r == 0) $display(" SONUC: *** TB-18 BASARILI ***");
    else              $display(" SONUC: *** TB-18 BASARISIZ — %0d kaldi ***", kalan_r);
    $display("==================================================================");
    $display("");
    $finish;
end

initial begin
    #(SAAT_PERIYOT * VEK_ZAMAN_ASIMI * 14);
    $display(" !! TB-18 GENEL ZAMAN ASIMI");
    $finish;
end

endmodule
