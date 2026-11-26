// =============================================================================
// Modül   : parametre_deposu.v                                      (İster M-24)
// Proje   : FPGA Tabanlı Güvenli Anahtar Yönetimi ve Kripto Hızlandırıcı (5260007)
// -----------------------------------------------------------------------------
// Açıklama:
//   RTL, doğuşundan beri YALNIZCA P-256 (secp256r1) için hazırlanmıştı: eğriye
//   özgü ~10 sabit (p, R mod p, G'nin Montgomery temsili, eğri sabiti b, n,
//   n'nin türevleri) 7 ayrı dosyaya `localparam` olarak elle gömülüydü. Bu,
//   sentezden SONRA değiştirilemeyen (derleme-zamanı) bir tasarımdı — başka
//   bir eğriye geçmek yeniden sentez + yeniden bitstream gerektiriyordu.
//
//   Bu modül, o sabitleri TEK bir merkezi register bankasında toplar ve
//   UART üzerinden (komut_yoneticisi.v'nin yeni EGRI_* komutları ile)
//   ÇALIŞMA ANINDA (reset sonrası, bitstream değişmeden) yeniden
//   yüklenebilir hale getirir.
//
//   GERİYE DÖNÜK UYUMLULUK BİLİNÇLİ TASARIM KARARIDIR:
//     Reset değerleri BİREBİR eski P-256 sabitleridir. Host hiçbir EGRI_*
//     komutu göndermezse davranış eskisiyle TAMAMEN AYNIDIR — mevcut
//     testbench'lerin ve host betiklerinin hiçbiri bozulmaz.
//
//   DESTEKLENEN EĞRİLER (bu depo ile, veri yolu genişliği DEĞİŞMEDEN):
//     P-256 (varsayılan), P-192, P-224 — p ve n bit uzunluğu 256'ya sığan
//     asal NIST eğrileri. P-384/P-521 KAPSAM DIŞIDIR: onlar için veri yolu
//     genişliğinin (BRAM sözcük sayısı, kaydırma yazmaçları, paket
//     protokolü) BÜYÜTÜLMESİ gerekir — bu modül o genişlemeyi sağlamaz.
//
//   NEDEN N_MINUS_2 / FERMAT_US BURADA SAKLANMAZ:
//     n-2 ve p-2, ilgili modüllerde (mod_n_ters.v / affine_donusum.v)
//     kendi n / p girişlerinden ANLIK olarak çıkarılır. Bunları AYRICA
//     burada saklamak, host'un tutarsız bir (n, n-2) veya (p, p-2) çifti
//     yüklemesi riskini yaratırdı — tek doğruluk kaynağı ilkesi korunur.
//
//   ALAN KİMLİKLERİ (g_alan_id, KOM_EGRI_ALAN_YUKLE ile birlikte kullanılır):
//     0 = P            (modülüs p)
//     1 = R_MOD_P      (= 2^256 mod p; GZ_MONT ve affine_donusum'un
//                         MONT_BIR'i ile AYNI değer, tek kopya paylaşılır)
//     2 = GX_MONT      (taban nokta G.x, Montgomery)
//     3 = GY_MONT      (taban nokta G.y, Montgomery)
//     4 = B_MONT       (eğri sabiti b, Montgomery)
//     5 = N_ORDER      (eğri mertebesi n)
//     6 = MONT_BIR_N   (= 2^256 mod n)
//     7 = R2N          (= (2^256)^2 mod n)
//
//   GÜVENLİK NOTU: Bu depodaki TÜM değerler AÇIK (public) eğri
//   parametreleridir — gizli anahtar/nonce bu modülden HİÇ geçmez.
//   Dolayısıyla UART'ın "güvenilir olmama" ilkesi (bkz. komut_yoneticisi.v
//   başlığı) burada gizlilik açısından risk oluşturmaz; yine de host YANLIŞ
//   bir eğri tablosu yükleyebilir (bütünlük riski) — bu yüzden c_gecerli
//   bayrağı ve KOM_EGRI_VARSAYILAN (güvenli P-256 dönüşü) sağlanmıştır.
//
//   BİLİNEN SINIRLAMA (dürüstçe belgelenir):
//     c_gecerli, bir alan yazıldığında 0'a düşer ve yalnızca host açıkça
//     KOM_EGRI_UYGULA gönderdiğinde 1'e döner — ama ecdh_kex_top.v BU
//     BAYRAĞI henüz kendi FSM giriş koşullarına BAĞLAMAZ (bu, 1600+ satırlık
//     dosyada çok sayıda durum girişinin değiştirilmesini gerektirirdi).
//     Yani host, ara durumda (yükleme bitmeden) bir ECDH/ECDSA işlemi
//     başlatırsa donanım YİNE DE ESKİ/KARIŞIK sabitlerle çalışır — bu bir
//     hata değil, host'un EGRI_UYGULA'yı göndermeden yeni işlem
//     başlatmaması gereken bir protokol kuralıdır. c_gecerli yalnızca
//     TEŞHİS/DURUM amaçlı dışa açılmıştır.
//
// Standart : Verilog-2001 — sentezlenebilir, latch üretmez
// Tarih    : Temmuz 2026
// =============================================================================

`timescale 1ns / 1ps

module parametre_deposu (
    input  wire         g_saat,
    input  wire         g_sifirla_n,

    // ── Alan yükleme (256-bit değerler, 8x32-bit sözcük halinde) ─────────
    input  wire [3:0]   g_alan_id,      // 0..7, yukarıdaki tabloya bakın
    input  wire [2:0]   g_alan_indis,   // sözcük indisi: 0=bit[31:0] .. 7=bit[255:224]
    input  wire [31:0]  g_alan_word,
    input  wire         g_alan_yaz,     // 1 çevrimlik darbe

    // ── Bit-uzunluğu yükleme: {p_bit[19:10], n_bit[9:0]} tek sözcükte ─────
    input  wire [31:0]  g_uzunluk_word,
    input  wire         g_uzunluk_yaz,  // 1 çevrimlik darbe

    // ── Denetim ────────────────────────────────────────────────────────────
    input  wire         g_uygula,        // yükleme tamamlandı, geçerli say
    input  wire         g_varsayilana_don, // P-256 fabrika ayarına dön

    output wire         c_gecerli,       // yalnızca teşhis/durum amaçlı

    // ── Eğri sabitleri çıkışı ──────────────────────────────────────────────
    output wire [255:0] c_p,
    output wire [255:0] c_r_mod_p,       // = GZ_MONT = affine MONT_BIR
    output wire [255:0] c_gx_mont,
    output wire [255:0] c_gy_mont,
    output wire [255:0] c_b_mont,
    output wire [255:0] c_n_order,
    output wire [255:0] c_mont_bir_n,
    output wire [255:0] c_r2n,
    output wire [9:0]   c_p_bit_uzunluk,
    output wire [9:0]   c_n_bit_uzunluk
);

// ── P-256 FABRİKA VARSAYILANLARI (eski hardcoded sabitlerle BİREBİR aynı) ──
localparam [255:0] VARSAYILAN_P          = 256'hffffffff00000001000000000000000000000000ffffffffffffffffffffffff;
localparam [255:0] VARSAYILAN_R_MOD_P    = 256'h00000000fffffffeffffffffffffffffffffffff000000000000000000000001;
localparam [255:0] VARSAYILAN_GX_MONT    = 256'h18905f76a53755c679fb732b7762251075ba95fc5fedb60179e730d418a9143c;
localparam [255:0] VARSAYILAN_GY_MONT    = 256'h8571ff1825885d85d2e88688dd21f3258b4ab8e4ba19e45cddf25357ce95560a;
localparam [255:0] VARSAYILAN_B_MONT     = 256'hdc30061d04874834e5a220abf7212ed6acf005cd78843090d89cdf6229c4bddf;
localparam [255:0] VARSAYILAN_N_ORDER    = 256'hffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551;
localparam [255:0] VARSAYILAN_MONT_BIR_N = 256'h00000000ffffffff00000000000000004319055258e8617b0c46353d039cdaaf;
localparam [255:0] VARSAYILAN_R2N        = 256'h66e12d94f3d956202845b2392b6bec594699799c49bd6fa683244c95be79eea2;
localparam [9:0]   VARSAYILAN_P_BIT      = 10'd256;
localparam [9:0]   VARSAYILAN_N_BIT      = 10'd256;

// ── Alan kimlikleri ─────────────────────────────────────────────────────
localparam [3:0] ALN_P        = 4'd0,
                 ALN_R_MOD_P  = 4'd1,
                 ALN_GX_MONT  = 4'd2,
                 ALN_GY_MONT  = 4'd3,
                 ALN_B_MONT   = 4'd4,
                 ALN_N_ORDER  = 4'd5,
                 ALN_MONT_BIR_N = 4'd6,
                 ALN_R2N      = 4'd7;

reg [255:0] p_r, r_mod_p_r, gx_mont_r, gy_mont_r, b_mont_r, n_order_r, mont_bir_n_r, r2n_r;
reg [9:0]   p_bit_r, n_bit_r;
reg         gecerli_r;

assign c_p              = p_r;
assign c_r_mod_p         = r_mod_p_r;
assign c_gx_mont         = gx_mont_r;
assign c_gy_mont         = gy_mont_r;
assign c_b_mont          = b_mont_r;
assign c_n_order         = n_order_r;
assign c_mont_bir_n      = mont_bir_n_r;
assign c_r2n             = r2n_r;
assign c_p_bit_uzunluk   = p_bit_r;
assign c_n_bit_uzunluk   = n_bit_r;
assign c_gecerli         = gecerli_r;

always @(posedge g_saat or negedge g_sifirla_n) begin
    if (!g_sifirla_n) begin
        p_r          <= VARSAYILAN_P;
        r_mod_p_r    <= VARSAYILAN_R_MOD_P;
        gx_mont_r    <= VARSAYILAN_GX_MONT;
        gy_mont_r    <= VARSAYILAN_GY_MONT;
        b_mont_r     <= VARSAYILAN_B_MONT;
        n_order_r    <= VARSAYILAN_N_ORDER;
        mont_bir_n_r <= VARSAYILAN_MONT_BIR_N;
        r2n_r        <= VARSAYILAN_R2N;
        p_bit_r      <= VARSAYILAN_P_BIT;
        n_bit_r      <= VARSAYILAN_N_BIT;
        gecerli_r    <= 1'b1;   // reset sonrası P-256 zaten tutarlı/geçerli
    end else begin
        if (g_varsayilana_don) begin
            p_r          <= VARSAYILAN_P;
            r_mod_p_r    <= VARSAYILAN_R_MOD_P;
            gx_mont_r    <= VARSAYILAN_GX_MONT;
            gy_mont_r    <= VARSAYILAN_GY_MONT;
            b_mont_r     <= VARSAYILAN_B_MONT;
            n_order_r    <= VARSAYILAN_N_ORDER;
            mont_bir_n_r <= VARSAYILAN_MONT_BIR_N;
            r2n_r        <= VARSAYILAN_R2N;
            p_bit_r      <= VARSAYILAN_P_BIT;
            n_bit_r      <= VARSAYILAN_N_BIT;
            gecerli_r    <= 1'b1;
        end else begin
            if (g_alan_yaz) begin
                gecerli_r <= 1'b0;   // yükleme sürüyor — UYGULA'ya kadar "tam" sayılmaz
                case (g_alan_id)
                    ALN_P:          p_r         [g_alan_indis*32 +: 32] <= g_alan_word;
                    ALN_R_MOD_P:    r_mod_p_r   [g_alan_indis*32 +: 32] <= g_alan_word;
                    ALN_GX_MONT:    gx_mont_r   [g_alan_indis*32 +: 32] <= g_alan_word;
                    ALN_GY_MONT:    gy_mont_r   [g_alan_indis*32 +: 32] <= g_alan_word;
                    ALN_B_MONT:     b_mont_r    [g_alan_indis*32 +: 32] <= g_alan_word;
                    ALN_N_ORDER:    n_order_r   [g_alan_indis*32 +: 32] <= g_alan_word;
                    ALN_MONT_BIR_N: mont_bir_n_r[g_alan_indis*32 +: 32] <= g_alan_word;
                    ALN_R2N:        r2n_r       [g_alan_indis*32 +: 32] <= g_alan_word;
                    default: ; // bilinmeyen alan_id sessizce yok sayılır (host sorumluluğu)
                endcase
            end

            if (g_uzunluk_yaz) begin
                gecerli_r <= 1'b0;
                n_bit_r <= g_uzunluk_word[9:0];
                p_bit_r <= g_uzunluk_word[19:10];
            end

            if (g_uygula) begin
                gecerli_r <= 1'b1;
            end
        end
    end
end

endmodule
