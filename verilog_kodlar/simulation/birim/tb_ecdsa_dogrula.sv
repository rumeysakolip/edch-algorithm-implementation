// =============================================================================
// Modül   : tb_ecdsa_dogrula.sv                                       (TB-21)
// Proje   : FPGA Tabanlı Güvenli Anahtar Yönetimi ve Kripto Hızlandırıcı (5260007)
// -----------------------------------------------------------------------------
// AMAÇ:
//   ecdsa_dogrula.v'nin iki aşamasını da doğrulamak:
//     AŞAMA 1 : (e,r,s) → aralık kontrolü + u1, u2
//     AŞAMA 2 : Rx      → v = Rx mod n → v == r hükmü
//
//   Aradaki çift skaler çarpım (u1·G + u2·Q) ve affin dönüşüm çağıranın
//   işidir; bu TB onları koşturmaz, Rx'i doğrudan verir. Böylece test
//   edilen şey ARİTMETİK ve HÜKÜM mantığı olarak izole kalır.
//   Tam zincir (çift çarpım dahil) ecdh_kex_top entegrasyonunda sınanacak.
//
// -----------------------------------------------------------------------------
// VEKTÖRLER:
//   Python'da geçerli ECDSA imzaları üretildi (r = (k·G).x mod n,
//   s = k^-1(e + r·d)) ve BAĞIMSIZ bir doğrulayıcıdan geçirildi.
//   u1, u2 beklenen değerleri RTL'in izleyeceği Montgomery akışıyla ayrıca
//   hesaplandı; ikisi de tuttu.
//
// KAPSANAN SENARYOLAR:
//   A) u1/u2 üretimi : 3 KAT vektörü, bit-birebir.
//   B) HÜKÜM DOĞRU   : gerçek Rx verilince o_gecerli = 1.
//   C) HÜKÜM YANLIŞ  : bozuk Rx verilince o_gecerli = 0.
//                      Bu, en kritik kontroldür: her zaman "geçerli" diyen
//                      bir doğrulayıcı A ve B'yi geçer ama İŞE YARAMAZ.
//   D) ARALIK        : r=0, s=0, r=n, s=n → o_aralik_hata, hesaba girmeden.
//   E) ARDIŞIK       : aralık reddinden sonra normal doğrulama çalışıyor.
//
// SÜRE: her AŞAMA 1 ≈ 123.500 çevrim (1.24 ms, ters alma baskın).
//       Toplam ~6 ms.
//
// Standart : SystemVerilog-2012
// Tarih    : Temmuz 2026
// =============================================================================

`timescale 1ns / 1ps

module tb_ecdsa_dogrula;

localparam int CLK_NS = 10;
localparam int ZA = 400_000;

localparam [255:0] N_ORDER =
    256'hffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551;

localparam [2:0] DIX_MODN=3'd0, DIX_E=3'd1, DIX_R=3'd2, DIX_S=3'd3, DIX_RX=3'd4;

logic clk_in = 1'b0, rst_n = 1'b0;
always #(CLK_NS/2) clk_in = ~clk_in;

logic [31:0] d_pkt_in; logic d_pkt_vld; logic [2:0] d_pkt_sel;
logic        d_start, d_hukum;
wire  [31:0] d_pkt_out; wire d_pkt_vld_o, d_pkt_sel_o, d_pkt_last;
wire         d_rdy, d_done, d_err, d_gecerli, d_aralik;

wire [31:0] to_dat; wire to_vld, to_st; wire [1:0] to_sel;
wire [31:0] mnt_out; wire mnt_vld, mnt_last, mnt_rdy, mnt_done, mnt_err;
wire [31:0] mnt_mo_dat; wire mnt_mo_vld, mnt_mo_st; wire [1:0] mnt_mo_sel, mnt_mo_opc;
wire [31:0] mo_dat; wire mo_vld, mo_st; wire [1:0] mo_sel, mo_opc;
wire [31:0] mi_out; wire mi_vld, mi_last, mi_rdy, mi_done, mi_err;

// Ters alma calisirken MALU onundur — ust seviyedeki arbitrasyonun aynisi.
wire ters_aktif = !mnt_rdy;

ecdsa_dogrula dut (
    .clk_in(clk_in), .rst_n(rst_n),
    .i_pkt_in(d_pkt_in), .i_pkt_vld(d_pkt_vld), .i_pkt_sel(d_pkt_sel),
    .i_start(d_start), .i_hukum(d_hukum),
    .o_pkt_out(d_pkt_out), .o_pkt_vld(d_pkt_vld_o), .o_pkt_sel(d_pkt_sel_o),
    .o_pkt_last(d_pkt_last),
    .o_rdy(d_rdy), .o_done(d_done), .o_err(d_err),
    .o_gecerli(d_gecerli), .o_aralik_hata(d_aralik),
    .to_pkt_dat(to_dat), .to_pkt_vld(to_vld), .to_pkt_sel(to_sel), .to_st(to_st),
    .ti_pkt_out(mnt_out), .ti_pkt_vld(mnt_vld),
    .ti_rdy(mnt_rdy), .ti_done(mnt_done), .ti_err(mnt_err),
    .mo_pkt_dat(mo_dat), .mo_pkt_vld(mo_vld), .mo_pkt_sel(mo_sel),
    .mo_opc(mo_opc), .mo_st(mo_st),
    .mi_pkt_out(mi_out), .mi_pkt_vld(mi_vld), .mi_pkt_last(mi_last),
    .mi_rdy(mi_rdy), .mi_done(mi_done), .mi_err(mi_err),
    .g_r2n(256'h66e12d94f3d956202845b2392b6bec594699799c49bd6fa683244c95be79eea2)
);

mod_n_ters mnt_ortak (
    .clk_in(clk_in), .rst_n(rst_n),
    .i_pkt_in(to_dat), .i_pkt_vld(to_vld), .i_pkt_sel(to_sel), .i_start(to_st),
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

// ── KAT vektorleri ──────────────────────────────────────────────────────
localparam int VEK = 3;
logic [255:0] v_e[0:2], v_r[0:2], v_s[0:2], v_u1[0:2], v_u2[0:2];
initial begin
  v_e [0]=256'h4944c75f9135157d7634e944ea5fe98d86aaa1054f93b039d453d4ab22306ec7;
  v_r [0]=256'h038306b5ecce18cd4ebfe79053c5fd6d1ba59ee5866491294e8ae1e782dc90b9;
  v_s [0]=256'h2009a3bba0b27427170abc2a0cf4ee5ae30775a392c6d0516e84884019ebe97f;
  v_u1[0]=256'hdec145c5ffd35a6a36f6ad0d45ad3e8b020501553719966bd6961ce0ef375e88;
  v_u2[0]=256'hdd94dbd8762502965c18e78e91ee8db0e0b3f800d98e76b1bee83a8e34e0f087;

  v_e [1]=256'hb80222519cbaee54195732d63ea8ddc917b243dedf21eb7a274163e8db15d9ef;
  v_r [1]=256'h0e0c1338d97c9155c8665e054bfff7c5dcb7fa124ccf9365786682addcbdd909;
  v_s [1]=256'h3ed825684aec3dc01a21046182a3c957ce8aff0d8d93658bbada0f91bcd23030;
  v_u1[1]=256'h51441b675e95b24ad4cd24ef36666f71408ca5b48ce6c4f733044922a5154a3f;
  v_u2[1]=256'hc8a0acfbf83d798184190b925cc3b5ee0d29222b9824570e5153ff69aebd5022;

  v_e [2]=256'h4f3703b84a98fba5fdcda7354742ced449d1c82925967a66d0d5db05110990fc;
  v_r [2]=256'h0a4b855bc58ce1dfa8421805c7630973c6675187b6502985298e695b52b3825d;
  v_s [2]=256'he83ca4fdbb92370e0285e990d409da2d07641d640c8da0b0d3e854ad9f92ee7a;
  v_u1[2]=256'h13d023871ef89306a4f0a5f67f3990676938bdf8ce31c719ea4a5320a90026fd;
  v_u2[2]=256'h17710a9e6d6e156d843cc0582eadde523851557720427d9a6913a1ae4f19d22f;
end

int gecen = 0, kalan = 0;
task automatic kontrol(input string a, input logic k);
    if (k) begin $display("   gecti   %s", a); gecen++; end
    else   begin $display("   KALDI   %s   <<<", a); kalan++; end
endtask

task automatic paket_yaz(input logic [2:0] sel, input logic [255:0] v);
    for (int i = 0; i < 8; i++) begin
        @(negedge clk_in); d_pkt_in = v[i*32 +: 32]; d_pkt_sel = sel; d_pkt_vld = 1'b1;
    end
    @(negedge clk_in); d_pkt_vld = 1'b0;
endtask

// ASAMA 1
task automatic faz1(input logic [255:0] e, r, s,
                    output logic [255:0] u1, u2,
                    output logic ariza, aralik, output int cev);
    int c, i1, i2;
    paket_yaz(DIX_MODN, N_ORDER);
    paket_yaz(DIX_E, e); paket_yaz(DIX_R, r); paket_yaz(DIX_S, s);
    @(negedge clk_in); d_start = 1'b1;
    @(negedge clk_in); d_start = 1'b0;
    c=0; i1=0; i2=0; u1=0; u2=0; ariza=0; aralik=0;
    forever begin
        @(posedge clk_in); c++;
        if (d_pkt_vld_o) begin
            if (!d_pkt_sel_o) begin u1[i1*32 +: 32]=d_pkt_out; i1++; end
            else              begin u2[i2*32 +: 32]=d_pkt_out; i2++; end
        end
        if (d_err)  begin ariza=1'b1; break; end
        if (d_done) begin aralik=d_aralik; break; end
        if (c>=ZA) begin $display("     !! ZAMAN ASIMI"); ariza=1'bx; break; end
    end
    cev=c; repeat (4) @(posedge clk_in);
endtask

// ASAMA 2
task automatic faz2(input logic [255:0] rx, output logic gecerli, output logic ariza);
    int c;
    paket_yaz(DIX_RX, rx);
    @(negedge clk_in); d_hukum = 1'b1;
    @(negedge clk_in); d_hukum = 1'b0;
    c=0; gecerli=0; ariza=0;
    forever begin
        @(posedge clk_in); c++;
        if (d_err)  begin ariza=1'b1; break; end
        if (d_done) begin gecerli=d_gecerli; break; end
        if (c>=ZA) begin $display("     !! ZAMAN ASIMI (faz2)"); ariza=1'bx; break; end
    end
    repeat (4) @(posedge clk_in);
endtask

logic [255:0] u1, u2;
logic ariza, aralik, gecerli;
int cev, cmin, cmax;

initial begin
    d_pkt_in=0; d_pkt_vld=0; d_pkt_sel=0; d_start=0; d_hukum=0;
    cmin=1_000_000; cmax=0;

    $display("");
    $display("==================================================================");
    $display(" TB-21  ecdsa_dogrula.v  —  w=s^-1, u1, u2, v==r hukmu");
    $display(" UYARI: her asama-1 ~1.24 ms (ters alma), toplam ~6 ms");
    $display("==================================================================");

    repeat (5) @(posedge clk_in); rst_n = 1'b1; repeat (5) @(posedge clk_in);

    $display("\n SENARYO A — u1 / u2 uretimi (KAT)");
    for (int v = 0; v < VEK; v++) begin
        faz1(v_e[v], v_r[v], v_s[v], u1, u2, ariza, aralik, cev);
        if (cev<cmin) cmin=cev;
        if (cev>cmax) cmax=cev;
        if (ariza!==1'b0 || aralik) begin
            $display("   KALDI   vektor #%0d ariza=%b aralik=%b   <<<", v+1, ariza, aralik);
            kalan++;
        end else begin
            if (u1 !== v_u1[v]) $display("           u1 beklenen 0x%064x\n           u1 cikan    0x%064x", v_u1[v], u1);
            kontrol($sformatf("vektor #%0d u1 dogru (%0d cevrim)", v+1, cev), u1 === v_u1[v]);
            if (u2 !== v_u2[v]) $display("           u2 beklenen 0x%064x\n           u2 cikan    0x%064x", v_u2[v], u2);
            kontrol($sformatf("vektor #%0d u2 dogru", v+1), u2 === v_u2[v]);
        end
    end

    // ── B/C) Hukum: dogru ve YANLIS Rx ───────────────────────────────────
    //   C senaryosu kritiktir: her zaman "gecerli" diyen bir dogrulayici
    //   A ve B'yi gecer ama tamamen ise yaramaz olur.
    $display("\n SENARYO B/C — hukum (dogru ve bozuk Rx)");
    faz1(v_e[0], v_r[0], v_s[0], u1, u2, ariza, aralik, cev);
    faz2(v_r[0], gecerli, ariza);          // Rx = r  ->  v == r
    kontrol("dogru Rx -> o_gecerli = 1", !ariza && gecerli === 1'b1);
    faz2(v_r[0] ^ 256'd1, gecerli, ariza); // tek bit bozuk
    kontrol("*** bozuk Rx -> o_gecerli = 0 ***", !ariza && gecerli === 1'b0);
    faz2(v_r[1], gecerli, ariza);          // baska imzanin r'si
    kontrol("baska imzanin Rx'i -> o_gecerli = 0", !ariza && gecerli === 1'b0);

    // ── D) Aralik kontrolu ───────────────────────────────────────────────
    $display("\n SENARYO D — r/s aralik disi (FIPS 186-4 6.4.2 adim 1)");
    faz1(v_e[0], 256'd0, v_s[0], u1, u2, ariza, aralik, cev);
    kontrol("r = 0   -> aralik hatasi", aralik === 1'b1);
    faz1(v_e[0], v_r[0], 256'd0, u1, u2, ariza, aralik, cev);
    kontrol("s = 0   -> aralik hatasi", aralik === 1'b1);
    faz1(v_e[0], N_ORDER, v_s[0], u1, u2, ariza, aralik, cev);
    kontrol("r = n   -> aralik hatasi", aralik === 1'b1);
    faz1(v_e[0], v_r[0], N_ORDER, u1, u2, ariza, aralik, cev);
    kontrol("s = n   -> aralik hatasi", aralik === 1'b1);

    // ── E) Ardisik kosum ─────────────────────────────────────────────────
    $display("\n SENARYO E — aralik reddinden sonra normal dogrulama");
    faz1(v_e[2], v_r[2], v_s[2], u1, u2, ariza, aralik, cev);
    kontrol("normal dogrulama yeniden calisiyor",
            !ariza && !aralik && u1 === v_u1[2] && u2 === v_u2[2]);

    $display("\n   asama-1 cevrim: en kisa %0d, en uzun %0d", cmin, cmax);

    $display("");
    $display("==================================================================");
    $display(" OZET:  %0d gecti / %0d kaldi   (toplam %0d dogrulama)",
             gecen, kalan, gecen + kalan);
    if (kalan == 0) $display(" SONUC: *** TB-21 BASARILI ***");
    else            $display(" SONUC: *** TB-21 BASARISIZ — %0d kaldi ***", kalan);
    $display("==================================================================");
    $display("");
    $finish;
end

initial begin
    #(CLK_NS * ZA * 40);
    $display(" !! TB-21 GENEL ZAMAN ASIMI");
    $finish;
end

endmodule
