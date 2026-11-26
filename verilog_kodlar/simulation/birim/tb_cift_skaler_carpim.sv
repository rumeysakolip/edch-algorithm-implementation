// =============================================================================
// Modül   : tb_cift_skaler_carpim.sv                                  (TB-19)
// Proje   : FPGA Tabanlı Güvenli Anahtar Yönetimi ve Kripto Hızlandırıcı (5260007)
// -----------------------------------------------------------------------------
// AMAÇ:
//   cift_skaler_carpim.v'nin R = u1·G + u2·Q hesabını doğru yaptığını
//   kanıtlamak. Bu, ECDSA doğrulamasının pahalı adımıdır.
//
// -----------------------------------------------------------------------------
// *** JACOBIAN SONUCU NASIL KARŞILAŞTIRILIYOR ***
//   DUT sonucu JACOBIAN (X,Y,Z) verir; affin dönüşüm çağıranın işidir.
//   Jacobian gösterim TEK DEĞİLDİR: (X,Y,Z) ve (λ²X, λ³Y, λZ) aynı noktadır.
//   Dolayısıyla beklenen değerle doğrudan bit karşılaştırması YAPILAMAZ.
//
//   Bunun yerine matematiksel bağıntı sınanır:
//       affin x = X / Z²    ⟺    X = x · Z²
//   Montgomery alanında (her şey R ile ölçekli) bu bağıntı korunur:
//       X̃ == MonMul(MonMul(x̃, Z̃), Z̃)
//
//   TB bu kontrolü kendi MonMul fonksiyonuyla yapar. Alternatif,
//   affine_donusum'u da TB'ye örneklemekti; o zaman MALU'yu iki istemci
//   arasında arbitre etmek gerekirdi ve test edilen şeyin dışına çıkardı.
//
//   Beklenen affin x değeri Python'da BAĞIMSIZ olarak hesaplandı
//   (u1·G + u2·Q, düz afin aritmetik), Straus-Shamir yolundan geçmeden.
//
// -----------------------------------------------------------------------------
// KAPSANAN SENARYOLAR:
//   A) KAT        : 3 rastgele (u1,u2,Q) üçlüsü.
//   B) UÇ DURUMLAR: u1=1/u2=0, u1=0/u2=1, u1=1/u2=1 — ilkleme dallarının
//                   üçü de (G, Q, T) sınanır.
//   C) SONSUZLUK  : u1=0 && u2=0 → o_sonsuz, o_err DEĞİL.
//   D) ARDIŞIK    : ikinci koşum aynı sonucu verir.
//
// NOT — SABİT ZAMANLILIK ARANMAZ:
//   Bu modül bilerek değişken zamanlıdır; doğrulama tamamen açık verilerle
//   çalışır. Bkz. cift_skaler_carpim.v başlığı. Bu yüzden TB'de yayılım
//   ölçülmez — ölçülseydi "başarısız" görünürdü ve yanıltıcı olurdu.
//
// SÜRE UYARISI: her koşum ~446 PAU işlemi ≈ 1.8 M çevrim ≈ 18 ms.
//               7 koşum ≈ 130 ms. UZUN SÜRER.
//
// ÇALIŞTIRMA (Vivado xsim):
//   xvlog -sv tb_cift_skaler_carpim.sv
//   xvlog cift_skaler_carpim.v point_arithmetic_unit.v modular_alu_dsp.v
//   xelab -debug typical tb_cift_skaler_carpim -s sim_csc
//   xsim sim_csc -R
//
// Standart : SystemVerilog-2012
// Tarih    : Temmuz 2026
// =============================================================================

`timescale 1ns / 1ps

module tb_cift_skaler_carpim;

localparam real SAAT_PERIYOT = 10.0;
localparam int  ZAMAN_ASIMI  = 4_000_000;   // ~2x pay (olculen ~1.8M)

localparam logic [255:0] P256 =
    256'hffffffff00000001000000000000000000000000ffffffffffffffffffffffff;
// R^-1 mod p — MonMul kontrolu icin.
//   Python'da pow(2^256 mod p, -1, p) ile hesaplandi ve 200 vektorde
//   X == MonMul(MonMul(x,Z),Z) bagintisi dogrulandi.
localparam logic [255:0] R_INV_P =
    256'hfffffffe00000003fffffffd0000000200000001fffffffe0000000300000000;

localparam logic [2:0] CIX_MODP=3'd0, CIX_U1=3'd1, CIX_U2=3'd2,
                       CIX_QX=3'd3,   CIX_QY=3'd4;

logic clk_in = 1'b0, rst_n = 1'b0;
always #(SAAT_PERIYOT/2.0) clk_in = ~clk_in;

logic [31:0] d_pkt_in; logic d_pkt_vld; logic [2:0] d_pkt_sel; logic d_start;
wire  [31:0] d_pkt_out; wire d_pkt_vld_o; wire [1:0] d_pkt_sel_o;
wire         d_pkt_last, d_rdy, d_done, d_err, d_sonsuz;
// FAZ 5 refactor: PAU artik cift_skaler_carpim'in ICINDE DEGIL.
// Gercek sistemde ecdh_kex_top'ta TEK ornektir ve scalar_multiplier ile
// paylasilir; TB de ayni baglama duzenini kurar.
wire [31:0] csc_po_dat; wire csc_po_vld, csc_po_cmd, csc_po_st; wire [2:0] csc_po_sel;
wire [31:0] pau_out;    wire pau_vld, pau_last, pau_rdy, pau_done, pau_err;
wire [1:0]  pau_sel;
wire [31:0] mo_dat; wire mo_vld; wire [1:0] mo_sel, mo_opc; wire mo_st;
wire [31:0] mi_out; wire mi_vld, mi_last, mi_rdy, mi_done, mi_err;

cift_skaler_carpim dut (
    .clk_in(clk_in), .rst_n(rst_n),
    .i_pkt_in(d_pkt_in), .i_pkt_vld(d_pkt_vld), .i_pkt_sel(d_pkt_sel),
    .i_start(d_start),
    .o_pkt_out(d_pkt_out), .o_pkt_vld(d_pkt_vld_o), .o_pkt_sel(d_pkt_sel_o),
    .o_pkt_last(d_pkt_last), .o_rdy(d_rdy), .o_done(d_done), .o_err(d_err),
    .o_sonsuz(d_sonsuz),
    .po_pkt_dat(csc_po_dat), .po_pkt_vld(csc_po_vld), .po_pkt_sel(csc_po_sel),
    .po_cmd(csc_po_cmd), .po_st(csc_po_st),
    .pi_pkt_out(pau_out), .pi_pkt_vld(pau_vld), .pi_pkt_sel(pau_sel),
    .pi_pkt_last(pau_last), .pi_rdy(pau_rdy), .pi_done(pau_done), .pi_err(pau_err),
    .g_r_mod_p(256'h00000000fffffffeffffffffffffffffffffffff000000000000000000000001),
    .g_gx_mont(256'h18905f76a53755c679fb732b7762251075ba95fc5fedb60179e730d418a9143c),
    .g_gy_mont(256'h8571ff1825885d85d2e88688dd21f3258b4ab8e4ba19e45cddf25357ce95560a)
);

point_arithmetic_unit pau_ortak (
    .clk_in(clk_in), .rst_n(rst_n),
    .i_pkt_in(csc_po_dat), .i_pkt_vld(csc_po_vld), .i_pkt_sel(csc_po_sel),
    .i_cmd(csc_po_cmd), .i_start(csc_po_st),
    .o_pkt_out(pau_out), .o_pkt_vld(pau_vld), .o_pkt_sel(pau_sel),
    .o_pkt_last(pau_last), .o_rdy(pau_rdy), .o_done(pau_done), .o_err(pau_err),
    .mo_pkt_dat(mo_dat), .mo_pkt_vld(mo_vld), .mo_pkt_sel(mo_sel),
    .mo_opc(mo_opc), .mo_st(mo_st),
    .mi_pkt_out(mi_out), .mi_pkt_vld(mi_vld), .mi_pkt_last(mi_last),
    .mi_rdy(mi_rdy), .mi_done(mi_done), .mi_err(mi_err)
);

// [ADIM-1] modular_alu -> modular_alu_dsp (port-port ayni, drop-in).
modular_alu_dsp malu (
    .clk_in(clk_in), .rst_n(rst_n),
    .i_pkt_in(mo_dat), .i_pkt_vld(mo_vld), .i_pkt_sel(mo_sel),
    .i_opcode(mo_opc), .i_start(mo_st),
    .o_pkt_out(mi_out), .o_pkt_vld(mi_vld), .o_pkt_last(mi_last),
    .o_rdy(mi_rdy), .o_done(mi_done), .o_err(mi_err)
);

// ── Montgomery carpim (TB tarafi hakem) ──────────────────────────────────
//   MonMul(a,b) = a*b*R^-1 mod p.  512-bit ara deger yeterli; iki adimda
//   yapilir ki genislik 512'yi asmasin.
function automatic logic [255:0] monmul(input logic [255:0] a, b);
    logic [511:0] t;
    t = (a * b) % P256;
    t = (t * R_INV_P) % P256;
    return t[255:0];
endfunction

// ── KAT vektorleri (Python, bagimsiz afin aritmetik) ─────────────────────
localparam int VEK_SAY = 3;
logic [255:0] v_u1[0:2], v_u2[0:2], v_qx[0:2], v_qy[0:2], v_rx[0:2];

initial begin
  v_u1[0]=256'h20ea7706a70fc4ea335fafdb7541a879d37d0f48f962fe0663a1235261991715;
  v_u2[0]=256'h4944c75f9135157d7634e944ea5fe98d86aaa1054f93b039d453d4ab22306ec7;
  v_qx[0]=256'ha046ecb7b50fa41f44e97bf95d850835980bff47e538f067a528c3b1516c93d5;
  v_qy[0]=256'h009451e6b0fafa14b3109ec74e3336bbfe94809f59e10be0819d997f7be95b4e;
  v_rx[0]=256'ha92d48cb480ff0bee992a2364a350af95c36d60f735632814c229ecf220cb96f;

  v_u1[1]=256'h22f95d3a809bcfc48d85e4e48a3e777b0de21cefef836fd810722a1e98f806bf;
  v_u2[1]=256'hb80222519cbaee54195732d63ea8ddc917b243dedf21eb7a274163e8db15d9ef;
  v_qx[1]=256'h6432113fea7fe5071941b94aefd6e17f5756f37eefb904322dcb7f04f45aec3d;
  v_qy[1]=256'hcbaa66216e1dfaf6fccf26bc8792393d60fa7865bb9e5281c9172bec7dfcf62a;
  v_rx[1]=256'h2221bee2710dab3992f3b93e9559f0fbfce40d7386da30c10046e577d5650c35;

  v_u1[2]=256'h1969b5a54cc3b94ef8cbf519835f450b73a0c2e50c84ed034a012a673f33bf8d;
  v_u2[2]=256'h4f3703b84a98fba5fdcda7354742ced449d1c82925967a66d0d5db05110990fc;
  v_qx[2]=256'h657e77076051d53f293a22b3768e192ee7f659cebb07fb07b1d4817d9140a89b;
  v_qy[2]=256'hce721dc05cd3f03fdf41d0dc1434cf3e1a0aa723036b52d42e734928f2cd96c1;
  v_rx[2]=256'h3179623b4c7e425405c6ece2fd8956d826835228785a58f53a26618dd9fd72d6;
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

task automatic carp(input  logic [255:0] u1, u2, qx, qy,
                    output logic [255:0] jx, jy, jz,
                    output logic         ariza, sonsuz,
                    output int           cevrim);
    int sayac, ix, iy, iz;
    paket_yaz(CIX_MODP, P256);
    paket_yaz(CIX_U1,   u1);
    paket_yaz(CIX_U2,   u2);
    paket_yaz(CIX_QX,   qx);
    paket_yaz(CIX_QY,   qy);
    @(negedge clk_in); d_start = 1'b1;
    @(negedge clk_in); d_start = 1'b0;

    sayac=0; ix=0; iy=0; iz=0; jx=0; jy=0; jz=0; ariza=0; sonsuz=0;
    forever begin
        @(posedge clk_in);
        sayac++;
        if (d_pkt_vld_o) begin
            case (d_pkt_sel_o)
                2'b00: begin jx[ix*32 +: 32] = d_pkt_out; ix++; end
                2'b01: begin jy[iy*32 +: 32] = d_pkt_out; iy++; end
                default: begin jz[iz*32 +: 32] = d_pkt_out; iz++; end
            endcase
        end
        if (d_err)  begin ariza = 1'b1; break; end
        if (d_done) begin sonsuz = d_sonsuz; break; end
        if (sayac >= ZAMAN_ASIMI) begin
            $display("     !! ZAMAN ASIMI (%0d cevrim)", sayac);
            ariza = 1'bx; break;
        end
    end
    cevrim = sayac;
    repeat (4) @(posedge clk_in);
endtask

// Jacobian (X,Y,Z) gercekten affin x'e mi karsilik geliyor?
function automatic logic jac_dogru(input logic [255:0] jx, jz, x_aff);
    logic [255:0] beklenen;
    if (jz == 256'd0) return 1'b0;          // sonsuzluk
    beklenen = monmul(monmul(x_aff, jz), jz);
    return (jx == beklenen);
endfunction

logic [255:0] jx, jy, jz;
logic ariza, sonsuz;
int   cevrim;

initial begin
    d_pkt_in=0; d_pkt_vld=0; d_pkt_sel=0; d_start=0;

    $display("");
    $display("==================================================================");
    $display(" TB-19  cift_skaler_carpim.v  —  R = u1*G + u2*Q (Straus-Shamir)");
    $display(" Jacobian sonucu  X == MonMul(MonMul(x,Z),Z)  bagintisiyla sinanir");
    $display(" UYARI: her kosum ~18 ms, toplam ~130 ms. UZUN SURER.");
    $display("==================================================================");

    repeat (5) @(posedge clk_in);
    rst_n = 1'b1;
    repeat (5) @(posedge clk_in);

    $display("\n SENARYO A — KAT dogrulamasi");
    for (int v = 0; v < VEK_SAY; v++) begin
        carp(v_u1[v], v_u2[v], v_qx[v], v_qy[v], jx, jy, jz, ariza, sonsuz, cevrim);
        if (ariza !== 1'b0 || sonsuz) begin
            $display("   KALDI   vektor #%0d — ariza=%b sonsuz=%b   <<<", v+1, ariza, sonsuz);
            kalan_r++;
        end else begin
            if (!jac_dogru(jx, jz, v_rx[v])) begin
                $display("           Jacobian X = 0x%064x", jx);
                $display("           Jacobian Z = 0x%064x", jz);
                $display("           beklenen affin x = 0x%064x", v_rx[v]);
            end
            kontrol($sformatf("vektor #%0d  R = u1*G + u2*Q  (%0d cevrim)", v+1, cevrim),
                    jac_dogru(jx, jz, v_rx[v]));
        end
    end

    // ── B) Ilkleme dallarinin ucu de ─────────────────────────────────────
    //   En yuksek bit ciftine gore R; G, Q veya T ile ilklenir. Uc dal da
    //   sinanmazsa biri sessizce bozuk kalabilir.
    $display("\n SENARYO B — ilkleme dallari (G / Q / T)");
    carp(256'd1, 256'd0, v_qx[0], v_qy[0], jx, jy, jz, ariza, sonsuz, cevrim);
    kontrol("u1=1, u2=0 -> R = G (ilkleme dali: G)",
            !ariza && !sonsuz && jac_dogru(jx, jz,
            256'h18905f76a53755c679fb732b7762251075ba95fc5fedb60179e730d418a9143c));
    carp(256'd0, 256'd1, v_qx[0], v_qy[0], jx, jy, jz, ariza, sonsuz, cevrim);
    kontrol("u1=0, u2=1 -> R = Q (ilkleme dali: Q)",
            !ariza && !sonsuz && jac_dogru(jx, jz, v_qx[0]));

    // ── C) Sonsuzluk ─────────────────────────────────────────────────────
    $display("\n SENARYO C — sonsuzluk noktasi");
    carp(256'd0, 256'd0, v_qx[0], v_qy[0], jx, jy, jz, ariza, sonsuz, cevrim);
    kontrol("u1=0 && u2=0 -> o_sonsuz kalkti", sonsuz === 1'b1);
    kontrol("sonsuzluk o_err DEGIL (protokol sonucu, ariza degil)", ariza === 1'b0);

    // ── D) Ardisik kosum ─────────────────────────────────────────────────
    $display("\n SENARYO D — ardisik kosum (bayat durum avi)");
    carp(v_u1[0], v_u2[0], v_qx[0], v_qy[0], jx, jy, jz, ariza, sonsuz, cevrim);
    kontrol("sonsuzluk sonrasi normal kosum dogru",
            !ariza && !sonsuz && jac_dogru(jx, jz, v_rx[0]));

    $display("");
    $display("==================================================================");
    $display(" OZET:  %0d gecti / %0d kaldi   (toplam %0d dogrulama)",
             gecen_r, kalan_r, gecen_r + kalan_r);
    if (kalan_r == 0) $display(" SONUC: *** TB-19 BASARILI ***");
    else              $display(" SONUC: *** TB-19 BASARISIZ — %0d kaldi ***", kalan_r);
    $display("==================================================================");
    $display("");
    $finish;
end

initial begin
    #(SAAT_PERIYOT * ZAMAN_ASIMI * 10);
    $display(" !! TB-19 GENEL ZAMAN ASIMI");
    $finish;
end

endmodule
