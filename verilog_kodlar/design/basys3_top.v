// =============================================================================
// Modül   : basys3_top.v            (KART SEVİYESİ SARMALAYICI — Basys 3)
// Proje   : FPGA Tabanlı Güvenli Anahtar Yönetimi ve Kripto Hızlandırıcı
// No      : 5260007 — Sakarya Uygulamalı Bilimler Üniversitesi
// -----------------------------------------------------------------------------
// NEDEN VAR:
//   `ecdh_uart_top` doğrudan sentez top'u yapıldığında place_design şu hatayla
//   duruyordu:
//
//     ERROR: [Place 30-58] IO placement is infeasible.
//     Number of unplaced IO Ports (41) is greater than number of available
//     pins (0).
//
//   Sebep alan ya da zamanlama DEĞİLDİ (o aşamada LUT %68,9'daydı ve
//   opt_design sorunsuz geçmişti). Sebep, ENTEGRASYON DİKİŞİ portlarının
//   (c_ent_sec/c_ent_indis/c_ent_sozcuk + 4 bayrak = 41 sinyal) XDC'de
//   kısıtlanmamış olmasıydı; Vivado bunları varsayılan olarak bank 0'a
//   (LVCMOS18) yerleştirmeye çalışıp 0 uygun pin buluyordu.
//
//   *** BU PORTLAR ZATEN PİNE ÇIKMAMALI ***
//   ecdh_uart_top.v'nin kendi başlığı bunu açıkça söylüyor: dikiş portları
//   ileride eklenecek HKDF / AES-GCM (AEAD) bloğunun ÇİP İÇİNDE bağlanacağı
//   yerdir; kart üzerinde dışarı çıkmazlar. Aynı tuzak bir kez daha
//   yaşanmış: dikiş eskiden HAM 256-bit portlardı (793 pin!) ve place_design
//   yine düşmüştü — o yüzden 32-bit sözcük arayüzüne geçilmişti. Ama
//   ecdh_uart_top gerçek top olduğu sürece 41 pin de fazladır: Basys 3'ün
//   106 pininin %39'unu yakar ve 7-segment göstergeyi feda etmeyi gerektirir.
//
// NE YAPAR:
//   Çekirdeği olduğu gibi örnekler, YALNIZCA kart üzerinde fiziksel karşılığı
//   olan sinyalleri dışa verir. Dikiş çıkışları bilinçli olarak BAĞSIZ
//   bırakılır — ecdh_uart_top.v'nin öngördüğü kullanım budur.
//
// SONUÇ / BEKLENEN DAVRANIŞ:
//   Dikişi süren mantık (serbest sayaçlı sözcük mux'u ve onu besleyen
//   z_duz_r gibi yazmaçlar) hiçbir yere gitmediği için sentez tarafından
//   elenir. Bu KAYIP DEĞİLDİR: o yolun çip üstünde tüketicisi yoktur.
//   Simülasyonda hiçbir şey değişmez — TB-25 (tb_entegrasyon_dikisi.sv)
//   ecdh_uart_top'u DOĞRUDAN örnekler ve dikişi orada sınamaya devam eder,
//   yani İster INT-01 RTL'de ve doğrulamada aynen korunur.
//
//   Simetrik katman yazıldığında: HKDF/AEAD bloğu BU SARMALAYICININ İÇİNE
//   eklenir ve dikiş portlarına bağlanır; ecdh_uart_top'a dokunulmaz.
//
// XDC NOTU:
//   basys3_ecdh_uart.xdc DEĞİŞTİRİLMEDİ ve değiştirilmesine gerek yok —
//   port adları (clk_100, btn_reset, btn_start, uart_rx_in, uart_tx_out,
//   led[15:0]) burada birebir korundu.
//
// VIVADO'DA YAPILACAK TEK ŞEY:
//   Sources penceresinde bu dosyaya sağ tık -> "Set as Top".
//
// Standart : Verilog-2001 — sentezlenebilir
// Tarih    : Temmuz 2026
// =============================================================================

`timescale 1ns / 1ps

module basys3_top (
    input  wire        clk_100,      // W5  — 100 MHz kart osilatörü
    input  wire        btn_reset,    // T18 — btnU (aktif-YÜKSEK)
    input  wire        btn_start,    // U18 — btnC
    input  wire        uart_rx_in,   // B18 — RsRx
    output wire        uart_tx_out,  // A18 — RsTx
    output wire [15:0] led
);

    // RESET_AKTIF_DUSUK = 0 : Basys 3'te ayrı bir reset butonu yoktur,
    //   normal butonlardan biri kullanılır ve bunlar aktif-YÜKSEKTİR.
    //   1 bırakılırsa rst_n sürekli '0' kalır ve tasarım hiç çalışmaz.
    ecdh_uart_top #(
        .SAAT_HZ           (100_000_000),
        .BAUD_HIZI         (115_200),
        .RESET_AKTIF_DUSUK (0)
    ) cekirdek (
        .clk_100     (clk_100),
        .btn_reset   (btn_reset),
        .btn_start   (btn_start),
        .uart_rx_in  (uart_rx_in),
        .uart_tx_out (uart_tx_out),
        .led         (led),

        // ── ENTEGRASYON DİKİŞİ — BİLİNÇLİ OLARAK BAĞSIZ ──────────────────
        //   Kart üzerinde karşılığı yoktur. Simetrik katman (HKDF/AEAD)
        //   yazıldığında buraya bağlanacak; o zamana kadar sentez bu yolu
        //   eler. Bağlamayı unutmak DEĞİL, bilinçli tercihtir.
        .c_ent_sec      (),
        .c_ent_indis    (),
        .c_ent_sozcuk   (),
        .c_z_gecerli    (),
        .c_imza_gecerli (),
        .c_dog_gecerli  (),
        .c_dog_bitti    ()
    );

endmodule
