// =============================================================================
// Modül   : nesne_deposu.v                                         (İster M-16)
// Proje   : FPGA Tabanlı Güvenli Anahtar Yönetimi ve Kripto Hızlandırıcı (5260007)
// -----------------------------------------------------------------------------
// Açıklama:
//   Secure Element'in ikili (binary) nesne deposu. Cihaz sertifikası, trust
//   anchor (kök/ara CA sertifikaları) gibi GİZLİ OLMAYAN ama BÜTÜNLÜĞÜ KRİTİK
//   verileri saklar. drawio Akış 1 adım 9 (WriteBinary → cihaz sertifikası) ve
//   adım 10 (WriteBinary → yazma korumalı trust store) bu modüle karşılık gelir.
//
//   FileID ile adreslenen SLOT_SAY adet sabit boyutlu slot; her slotun kendi
//   uzunluk, yazma-kilidi ve geçerlilik üst verisi vardır.
//
// -----------------------------------------------------------------------------
// NEDEN SLOT BAŞINA SABİT BOYUT (dinamik ayırma değil):
//   Dinamik ayırma (heap) donanımda serbest-liste, birleştirme ve parçalanma
//   yönetimi demektir; hepsi saldırı yüzeyi ve hepsi FSM karmaşıklığı. Sabit
//   slot, adres hesabını tek kaydırmaya indirir (taban = FileID << 8) ve taşma
//   kontrolünü tek karşılaştırmaya. Toplam 4 KB için parçalanmadan kaçınmak
//   uğruna karmaşıklık satın almanın anlamı yok.
//
// -----------------------------------------------------------------------------
// *** GÜVENLİK ***
//   1. YAZMA KİLİDİ TEK YÖNLÜDÜR. c_kilit bir kez kurulunca yalnız donanım
//      reset'i ile temizlenir; hiçbir komut kilidi açamaz. Trust anchor bu
//      yüzden vardır: değiştirilebilir bir trust store, saldırganın kendi
//      CA'sını ekleyip TÜM sertifika doğrulamasını geçersiz kılmasına izin
//      verir. Bu, sertifika doğrulamasının sessizce anlamsızlaşması demektir.
//
//   2. SINIR KONTROLÜ MODÜLÜN İÇİNDEDİR, çağıranın iyi niyetine bırakılmaz.
//      Ofset + uzunluk slot sınırını aşarsa yazma REDDEDİLİR; kırpılarak
//      kabul EDİLMEZ. Kırpma, saldırganın komşu slotun (örn. trust anchor)
//      üzerine yazmasına yol açabilecek klasik bir hatadır.
//
//   3. BU DEPO GİZLİ VERİ İÇİN DEĞİLDİR. Private key buraya konmaz; anahtar
//      malzemesi Faz 4'teki ayrı anahtar deposunda, dışa okuma yolu FİZİKSEL
//      OLARAK BULUNMAYAN bir yapıda tutulacaktır. Buradaki her nesne
//      READ_BINARY ile okunabilir — sertifikalar zaten TLS el sıkışmasında
//      açıkça gönderildiği için bu bir sorun değildir.
//
// -----------------------------------------------------------------------------
// BELLEK DÜZENİ:
//   Toplam SLOT_SAY × SLOT_BAYT = 4 × 1024 = 4096 bayt = 1024 × 32-bit word.
//   Artix-7'de 1 adet RAMB36 veya 2 adet RAMB18'e oturur (mevcut kullanım
//   %6.3 olduğu için bol yer var).
//
//   Word adresi = { FileID[1:0], slot_ici_word[7:0] }   → 10 bit
//   UART yolu zaten 32-bit word taşıdığı için depo da word yönelimlidir;
//   bayt yönelimli olsaydı her erişimde gereksiz paketleme/çözme gerekirdi.
//
// -----------------------------------------------------------------------------
// UZUNLUK ANLAMBİLİMİ (kritik incelik):
//   Nesnenin GERÇEK bayt uzunluğu (örn. 743 baytlık bir DER sertifikası) ile
//   UART çerçevesinin 4'ün katı olma zorunluluğu AYRI şeylerdir. Hat üzerinde
//   son parça 4'e hizalanmak için doldurulur (padding); gerçek uzunluk bu
//   modülde ayrıca tutulur ve READ_BINARY o uzunluğu bildirir.
//
//   Bu ayrım sayesinde UART çerçeve formatına hiç dokunulmadı: paket_cozucu,
//   paket_kurucu, uart_arayuz ve crc8_hesap DEĞİŞMEDİ; TB-06/07/08/09/12
//   geçerliliğini korudu.
//
// Kabul kriteri (TB-15):
//   Yaz/oku turu; sınır aşımı reddi; kilit sonrası yazma reddi; kilidin
//   açılamaması; slot yalıtımı (bir slota yazmak diğerini bozmamalı);
//   geçersiz FileID; uzunluk takibi; reset sonrası temiz durum.
//
// Standart : Verilog-2001 — sentezlenebilir, latch üretmez
// Tarih    : Temmuz 2026
// =============================================================================

`timescale 1ns / 1ps

// [ALAN OPT. Temmuz 2026] keep_hierarchy KAPATILDI. Bu attribute yalnizca
// hiyerarsik raporlama granulerligini korur; PAYLASIMI ETKILEMEZ — tek MALU /
// tek PAU paylasimi RTL de YAPISALDIR (tek ornek + mux), sentez var olmayan
// ikinci bir ornek yaratamaz. Kapatmak, modul sinirlari arasinda sabit
// yayilimi ve olu mantik elemesini acar (~%5-15 LUT). Hiyerarsik rapor
// gerekirse satiri gecici olarak geri ac.
// (* keep_hierarchy = "yes" *)
module nesne_deposu #(
    parameter integer SLOT_SAY   = 4,      // nesne slotu adedi
    parameter integer SLOT_BAYT  = 1024,   // slot başına bayt
    parameter integer ID_BIT     = 2,      // $clog2(SLOT_SAY)
    parameter integer SLOT_WORD  = 256,    // SLOT_BAYT/4
    parameter integer WADR_BIT   = 8,      // $clog2(SLOT_WORD)
    parameter integer UZUN_BIT   = 11      // SLOT_BAYT'ı taşımadan tutacak genişlik
)(
    input  wire                 g_saat,
    input  wire                 g_sifirla_n,

    // ── Erişim isteği ────────────────────────────────────────────────────
    input  wire [7:0]           g_id,        // FileID (üst bitler 0 olmalı)
    input  wire [WADR_BIT-1:0]  g_word_adr,  // slot içi word adresi
    input  wire [31:0]          g_yaz_word,
    input  wire                 g_yaz_vld,   // 1 çevrim: bu word'ü yaz
    input  wire                 g_oku_vld,   // 1 çevrim: bu word'ü oku

    // ── Okuma sonucu (1 çevrim gecikmeli, BRAM çıkışı kayıtlı) ───────────
    output wire [31:0]          c_oku_word,
    output wire                 c_oku_hazir,

    // ── Üst veri yazma ───────────────────────────────────────────────────
    input  wire [UZUN_BIT-1:0]  g_uzunluk,      // nesnenin gerçek bayt uzunluğu
    input  wire                 g_uzunluk_vld,  // 1 çevrim: uzunluğu kaydet
    input  wire                 g_kilitle,      // 1 çevrim: slotu kalıcı kilitle

    // ── Üst veri okuma (g_id ile kombinasyonel) ──────────────────────────
    output wire [UZUN_BIT-1:0]  c_uzunluk,
    output wire                 c_kilit,
    output wire                 c_gecerli,

    // ── Hata bayrağı (1 çevrim darbe) ────────────────────────────────────
    output wire                 c_hata,
    output wire [1:0]           c_hata_kod   // 1=gecersiz id, 2=kilitli, 3=sinir
);

// ── Hata kodları ──────────────────────────────────────────────────────────
localparam [1:0] HK_YOK      = 2'd0,
                 HK_GECERSIZ = 2'd1,   // FileID slot aralığı dışında
                 HK_KILITLI  = 2'd2,   // slot yazma korumalı
                 HK_SINIR    = 2'd3;   // uzunluk slot boyutunu aşıyor

// ═════════════════════════════════════════════════════════════════════════
//  BELLEK VE ÜST VERİ
// ═════════════════════════════════════════════════════════════════════════
//   ram_style="block" ile Vivado'nun bunu dağıtık RAM'e (LUTRAM) çevirmesi
//   engellenir. 1024 word dağıtık RAM'e konsaydı binlerce LUT harcanırdı.
(* ram_style = "block" *)
reg [31:0] bellek_r [0:SLOT_SAY*SLOT_WORD-1];

reg [UZUN_BIT-1:0] uzunluk_r [0:SLOT_SAY-1];
reg                kilit_r   [0:SLOT_SAY-1];
reg                gecerli_r [0:SLOT_SAY-1];

reg [31:0] oku_word_r;
reg        oku_hazir_r;
reg        hata_r;
reg [1:0]  hata_kod_r;

assign c_oku_word  = oku_word_r;
assign c_oku_hazir = oku_hazir_r;
assign c_hata      = hata_r;
assign c_hata_kod  = hata_kod_r;

// ── Geçerlilik hatları ────────────────────────────────────────────────────
//   g_id 8 bit gelir ama yalnız alt ID_BIT biti anlamlıdır. Üst bitler sıfır
//   değilse istek REDDEDİLİR — sessizce maskelenmez. Maskeleme, host'un
//   FileID=5 gönderip FileID=1'e yazmasına yol açardı; bu tür sessiz
//   yeniden yönlendirme, yanlış slotun üzerine yazan hataların klasik kaynağıdır.
wire id_gecerli_w = (g_id < SLOT_SAY[7:0]);
wire [ID_BIT-1:0] id_w = g_id[ID_BIT-1:0];

// Slot içi tam word adresi
wire [ID_BIT+WADR_BIT-1:0] tam_adr_w = {id_w, g_word_adr};

// Yazma izni: geçerli ID + kilitli değil
wire yazilabilir_w = id_gecerli_w && !kilit_r[id_w];

// Üst veri okuma — geçersiz ID'de sıfır döner (çöp değil)
assign c_uzunluk = id_gecerli_w ? uzunluk_r[id_w] : {UZUN_BIT{1'b0}};
assign c_kilit   = id_gecerli_w ? kilit_r  [id_w] : 1'b0;
assign c_gecerli = id_gecerli_w ? gecerli_r[id_w] : 1'b0;

// ═════════════════════════════════════════════════════════════════════════
//  BELLEK ERİŞİMİ
// ═════════════════════════════════════════════════════════════════════════
//   Yazma ve okuma ayrı always bloklarında tutulur; Vivado'nun bunu gerçek
//   bir blok RAM'e çıkarabilmesi için erişim deseninin basit kalması gerekir.
always @(posedge g_saat) begin
    if (g_yaz_vld && yazilabilir_w)
        bellek_r[tam_adr_w] <= g_yaz_word;
end

always @(posedge g_saat) begin
    if (g_oku_vld && id_gecerli_w)
        oku_word_r <= bellek_r[tam_adr_w];
end

// ═════════════════════════════════════════════════════════════════════════
//  ÜST VERİ VE HATA MANTIĞI
// ═════════════════════════════════════════════════════════════════════════
integer i;
always @(posedge g_saat or negedge g_sifirla_n) begin
    if (!g_sifirla_n) begin
        for (i = 0; i < SLOT_SAY; i = i + 1) begin
            uzunluk_r[i] <= {UZUN_BIT{1'b0}};
            kilit_r  [i] <= 1'b0;
            gecerli_r[i] <= 1'b0;
        end
        oku_hazir_r <= 1'b0;
        hata_r      <= 1'b0;
        hata_kod_r  <= HK_YOK;
    end else begin
        // Darbe sinyalleri
        oku_hazir_r <= 1'b0;
        hata_r      <= 1'b0;

        // ── Okuma tamamlanma darbesi ─────────────────────────────────────
        if (g_oku_vld && id_gecerli_w)
            oku_hazir_r <= 1'b1;

        // ── Hata üretimi — öncelik sırası önemlidir ──────────────────────
        //   Geçersiz ID önce gelir: kilit/sınır kontrolleri geçersiz bir ID
        //   ile anlamsızdır ve kilit_r[id_w] tanımsız indekse erişirdi.
        if (g_yaz_vld || g_oku_vld || g_uzunluk_vld || g_kilitle) begin
            if (!id_gecerli_w) begin
                hata_r <= 1'b1; hata_kod_r <= HK_GECERSIZ;
            end else if ((g_yaz_vld || g_uzunluk_vld) && kilit_r[id_w]) begin
                // Kilitli slota yazma girişimi — sessizce yutulmaz, raporlanır.
                hata_r <= 1'b1; hata_kod_r <= HK_KILITLI;
            end else if (g_uzunluk_vld && (g_uzunluk > SLOT_BAYT[UZUN_BIT-1:0])) begin
                // Sınır aşımı: KIRPILMAZ, reddedilir.
                hata_r <= 1'b1; hata_kod_r <= HK_SINIR;
            end
        end

        // ── Uzunluk kaydı ────────────────────────────────────────────────
        if (g_uzunluk_vld && id_gecerli_w && !kilit_r[id_w]
                          && (g_uzunluk <= SLOT_BAYT[UZUN_BIT-1:0])) begin
            uzunluk_r[id_w] <= g_uzunluk;
            gecerli_r[id_w] <= (g_uzunluk != {UZUN_BIT{1'b0}});
        end

        // ── Kalıcı kilit ─────────────────────────────────────────────────
        //   TEK YÖNLÜ: kilit_r'yi 0'a çeken BAŞKA HİÇBİR YOL YOKTUR (reset
        //   dışında). Bu satırı "kilit aç" ile eşleştirecek bir komut
        //   eklenirse trust anchor garantisi ortadan kalkar.
        if (g_kilitle && id_gecerli_w)
            kilit_r[id_w] <= 1'b1;
    end
end

endmodule
