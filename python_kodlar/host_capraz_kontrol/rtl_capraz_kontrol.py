#!/usr/bin/env python3
# =============================================================================
# Dosya   : rtl_capraz_kontrol.py
# Proje   : FPGA Tabanlı Güvenli Anahtar Yönetimi ve Kripto Hızlandırıcı (5260007)
# -----------------------------------------------------------------------------
# Amaç:
#   Katman 0-1 RTL modüllerinin (M-01..M-05) mantığını ÇEVRİM-DOĞRU olarak
#   Python'da yeniden kurar ve testbench'lerdeki beklenen değerleri doğrular.
#
#   NEDEN: Bu model, Verilog'un yerine geçmez. Amaç, kaydırma yazmacı
#   indisleme, FSM geçiş sırası ve örnekleme noktası gibi SESSİZ mantık
#   hatalarını xsim'e girmeden önce yakalamaktır. RTL ile bu model arasında
#   uyuşmazlık çıkarsa, ikisinden biri yanlıştır — ikisi de incelenmelidir.
#
#   Modeller Verilog kaynaklarının satır sırasını takip eder; RTL değişirse
#   bu dosya da güncellenmelidir.
#
# Kullanım: python3 rtl_capraz_kontrol.py
# =============================================================================

import sys

BASARISIZ = []


def kontrol(kosul, ad, ayrinti=""):
    if kosul:
        print("  [GECTI] %s" % ad)
    else:
        print("  [KALDI] %s %s" % (ad, ayrinti))
        BASARISIZ.append(ad)


# =============================================================================
# M-01 · uart_baud_uretici modeli
# =============================================================================
class BaudUretici:
    def __init__(self, saat_hz=100_000_000, baud=115_200, ornekleme=16):
        self.bolucu = (saat_hz + (ornekleme * baud) // 2) // (ornekleme * baud)
        self.sayac = 0
        self.tik = 0

    def saat_kenari(self):
        """Verilog: sayac_r == SON_DEGER ? (0, tik=1) : (sayac+1, tik=0)"""
        if self.sayac == self.bolucu - 1:
            self.sayac = 0
            self.tik = 1
        else:
            self.sayac += 1
            self.tik = 0


# =============================================================================
# M-03 · crc8_hesap modeli
# =============================================================================
class Crc8:
    def __init__(self, polinom=0x07, baslangic=0x00):
        self.polinom = polinom
        self.baslangic = baslangic
        self.crc = baslangic

    def temizle(self):
        self.crc = self.baslangic

    def bayt(self, b):
        """Verilog bayt_isle() fonksiyonunun birebir karşılığı."""
        gecici = self.crc ^ b
        for _ in range(8):
            # Verilog kademe(): mevcut[7] ? (mevcut<<1)^POLINOM : mevcut<<1
            if gecici & 0x80:
                gecici = ((gecici << 1) ^ self.polinom) & 0xFF
            else:
                gecici = (gecici << 1) & 0xFF
        self.crc = gecici
        return self.crc


# =============================================================================
# M-02 · senk_fifo modeli
# =============================================================================
class SenkFifo:
    def __init__(self, derinlik=8):
        self.derinlik = derinlik
        self.bellek = [0] * derinlik
        self.yaz_ptr = 0
        self.oku_ptr = 0
        self.sayi = 0
        self.oku_veri = 0

    @property
    def bos(self):
        return self.sayi == 0

    @property
    def dolu(self):
        return self.sayi == self.derinlik

    def saat_kenari(self, yaz=0, veri=0, oku=0):
        """Verilog ile aynı: koruma (dolu/boş) içeride uygulanır."""
        yaz_etkin = yaz and not self.dolu
        oku_etkin = oku and not self.bos

        if yaz_etkin:
            self.bellek[self.yaz_ptr] = veri
        if oku_etkin:
            self.oku_veri = self.bellek[self.oku_ptr]

        if yaz_etkin:
            self.yaz_ptr = (self.yaz_ptr + 1) % self.derinlik
        if oku_etkin:
            self.oku_ptr = (self.oku_ptr + 1) % self.derinlik

        if yaz_etkin and not oku_etkin:
            self.sayi += 1
        elif oku_etkin and not yaz_etkin:
            self.sayi -= 1
        # eşzamanlı → değişmez


# =============================================================================
# M-04 · uart_rx modeli
# =============================================================================
D_BEKLE, D_START, D_VERI, D_STOP = 0, 1, 2, 3


class UartRx:
    def __init__(self, ornekleme=16):
        self.ornekleme = ornekleme
        self.yarim_bit = ornekleme // 2 - 1
        self.tam_bit = ornekleme - 1
        self.durum = D_BEKLE
        self.tik_say = 0
        self.bit_say = 0
        self.kaydir = 0
        self.veri = 0
        self.gecerli = 0
        self.hata = 0
        self.senk = 0b11

    def saat_kenari(self, seri, ort_tik):
        # 2-flop senkronizör
        self.senk = ((self.senk << 1) | (seri & 1)) & 0b11
        seri_w = (self.senk >> 1) & 1

        self.gecerli = 0
        self.hata = 0

        if not ort_tik:
            return

        if self.durum == D_BEKLE:
            self.tik_say = 0
            self.bit_say = 0
            if seri_w == 0:
                self.durum = D_START

        elif self.durum == D_START:
            if self.tik_say == self.yarim_bit:
                self.tik_say = 0
                self.durum = D_VERI if seri_w == 0 else D_BEKLE
            else:
                self.tik_say += 1

        elif self.durum == D_VERI:
            if self.tik_say == self.tam_bit:
                self.tik_say = 0
                # Verilog: kaydir_r <= {seri_w, kaydir_r[7:1]}
                self.kaydir = ((seri_w << 7) | (self.kaydir >> 1)) & 0xFF
                if self.bit_say == 7:
                    self.bit_say = 0
                    self.durum = D_STOP
                else:
                    self.bit_say += 1
            else:
                self.tik_say += 1

        elif self.durum == D_STOP:
            if self.tik_say == self.tam_bit:
                self.tik_say = 0
                self.durum = D_BEKLE
                if seri_w == 1:
                    self.veri = self.kaydir
                    self.gecerli = 1
                else:
                    self.hata = 1
            else:
                self.tik_say += 1


# =============================================================================
# M-05 · uart_tx modeli
# =============================================================================
D_BOSTA, T_START, T_VERI, T_STOP = 0, 1, 2, 3


class UartTx:
    def __init__(self, ornekleme=16):
        self.tam_bit = ornekleme - 1
        self.durum = D_BOSTA
        self.tik_say = 0
        self.bit_say = 0
        self.kaydir = 0xFF
        self.seri = 1
        self.mesgul = 0
        self.istek = 0

    def saat_kenari(self, veri, basla, ort_tik):
        if self.durum == D_BOSTA:
            self.seri = 1
            self.tik_say = 0
            self.bit_say = 0
            if basla and not self.istek:
                self.kaydir = veri & 0xFF
                self.istek = 1
                self.mesgul = 1
            if self.istek and ort_tik:
                self.istek = 0
                self.seri = 0            # start biti
                self.durum = T_START

        elif self.durum == T_START:
            if ort_tik:
                if self.tik_say == self.tam_bit:
                    self.tik_say = 0
                    self.seri = self.kaydir & 1        # bit0
                    self.durum = T_VERI
                else:
                    self.tik_say += 1

        elif self.durum == T_VERI:
            if ort_tik:
                if self.tik_say == self.tam_bit:
                    self.tik_say = 0
                    eski = self.kaydir
                    self.kaydir = ((1 << 7) | (eski >> 1)) & 0xFF
                    if self.bit_say == 7:
                        self.bit_say = 0
                        self.seri = 1                  # stop
                        self.durum = T_STOP
                    else:
                        self.bit_say += 1
                        self.seri = (eski >> 1) & 1    # sonraki bit
                else:
                    self.tik_say += 1

        elif self.durum == T_STOP:
            if ort_tik:
                if self.tik_say == self.tam_bit:
                    self.tik_say = 0
                    self.mesgul = 0
                    self.durum = D_BOSTA
                else:
                    self.tik_say += 1


# =============================================================================
# TESTLER
# =============================================================================

def test_baud():
    print("\n--- M-01 uart_baud_uretici ---")
    b = BaudUretici(100_000_000, 115_200, 16)
    kontrol(b.bolucu == 54, "BOLUCU = 54", "(hesaplanan %d)" % b.bolucu)

    gerceklesen = 100_000_000 / (b.bolucu * 16)
    hata = (gerceklesen - 115200) / 115200 * 100
    kontrol(abs(hata) < 2.0,
            "Baud hatasi %%%.3f < %%2 (8N1 butcesi)" % hata)
    print("       gerceklesen baud = %.1f" % gerceklesen)

    # Tik periyodu ölçümü
    tikler = []
    for cevrim in range(54 * 100):
        b.saat_kenari()
        if b.tik:
            tikler.append(cevrim)
    periyotlar = [tikler[i+1] - tikler[i] for i in range(len(tikler) - 1)]
    kontrol(all(p == 54 for p in periyotlar),
            "Tum tik periyotlari tam 54 cevrim")

    # BOLUCU=1 sınır durumu
    b1 = BaudUretici(100_000_000, 6_250_000, 16)
    kontrol(b1.bolucu == 1, "Sinir durum: BOLUCU=1", "(%d)" % b1.bolucu)
    say = sum((b1.saat_kenari() or b1.tik) for _ in range(100))
    kontrol(say == 100, "BOLUCU=1'de her saatte tik", "(%d/100)" % say)


def test_crc():
    print("\n--- M-03 crc8_hesap ---")
    vektorler = [
        (b"123456789", 0xF4, "standart kontrol degeri"),
        (bytes([0x00]), 0x00, "tek 0x00"),
        (bytes([0xFF]), 0xF3, "tek 0xFF"),
        (bytes([0xA5, 0x01, 0x40]), 0x5A, "cerceve basligi"),
        (bytes(range(16)), 0x41, "0x00..0x0F"),
        (bytes([0xA5] * 8), 0x59, "8 x 0xA5"),
    ]
    for veri, beklenen, ad in vektorler:
        c = Crc8()
        c.temizle()
        for b in veri:
            c.bayt(b)
        kontrol(c.crc == beklenen, "CRC %s -> 0x%02X" % (ad, beklenen),
                "(hesaplanan 0x%02X)" % c.crc)

    # Çerçeveler arası sızıntı
    c = Crc8()
    for b in bytes([0xDE, 0xAD]):
        c.bayt(b)
    c.temizle()
    for b in b"123456789":
        c.bayt(b)
    kontrol(c.crc == 0xF4, "Temizle sonrasi sizinti yok")


def test_fifo():
    print("\n--- M-02 senk_fifo ---")
    f = SenkFifo(derinlik=8)
    kontrol(f.bos and not f.dolu and f.sayi == 0, "Reset sonrasi bos")

    # Tam doldur
    for i in range(8):
        f.saat_kenari(yaz=1, veri=0x10 + i)
    kontrol(f.dolu and f.sayi == 8, "Tam doldurma -> dolu", "(sayi=%d)" % f.sayi)

    # Taşma koruması
    f.saat_kenari(yaz=1, veri=0xFF)
    kontrol(f.sayi == 8, "Dolu iken yazma sayaci degistirmedi")

    # Boşalt ve sıra kontrolü
    okunanlar = []
    for _ in range(8):
        f.saat_kenari(oku=1)
        okunanlar.append(f.oku_veri)
    beklenen = list(range(0x10, 0x18))
    kontrol(okunanlar == beklenen, "FIFO sirasi dogru, tasan 0xFF sizmadi",
            "(okunan %s)" % [hex(x) for x in okunanlar])

    # Boşaltma koruması
    f.saat_kenari(oku=1)
    kontrol(f.sayi == 0, "Bos iken okuma sayaci eksiye dusurmedi")

    # Sarma
    hata = False
    for i in range(24):
        f.saat_kenari(yaz=1, veri=(0x40 + i) & 0xFF)
        f.saat_kenari(oku=1)
        if f.oku_veri != ((0x40 + i) & 0xFF):
            hata = True
    kontrol(not hata, "Sarma (wrap-around) dogru")

    # Eşzamanlı oku+yaz
    f.saat_kenari(yaz=1, veri=0x11)
    f.saat_kenari(yaz=1, veri=0x22)
    once = f.sayi
    f.saat_kenari(yaz=1, veri=0x33, oku=1)
    kontrol(f.sayi == once, "Eszamanli oku+yaz sayiyi degistirmedi")
    kontrol(f.oku_veri == 0x11, "Eszamanli islemde dogru veri okundu",
            "(0x%02X)" % f.oku_veri)


def phy_dongusu(baytlar, ornekleme=16, bolucu=4):
    """TX -> hat -> RX zinciri, gerçek çevrim adımlamasıyla (TB-08 modeli)."""
    baud = BaudUretici(100_000_000, 100_000_000 // (bolucu * ornekleme), ornekleme)
    tx = UartTx(ornekleme)
    rx = UartRx(ornekleme)

    alinanlar = []
    hatalar = 0
    kuyruk = list(baytlar)
    bekleyen = None
    basla = 0

    # Bayt basina ~10 bit * bolucu * ornekleme cevrim + pay
    azami = (len(baytlar) + 4) * 12 * bolucu * ornekleme

    for _ in range(azami):
        baud.saat_kenari()
        tik = baud.tik

        # Gönderim sırası: TX boştaysa yeni bayt ver
        if tx.mesgul == 0 and tx.istek == 0 and kuyruk and bekleyen is None:
            bekleyen = kuyruk.pop(0)
            basla = 1
        else:
            basla = 0

        onceki_seri = tx.seri
        tx.saat_kenari(bekleyen if bekleyen is not None else 0, basla, tik)
        if basla:
            bekleyen = None

        # Hat: TX cikisi -> RX girisi (loopback)
        rx.saat_kenari(onceki_seri, tik)

        if rx.gecerli:
            alinanlar.append(rx.veri)
        if rx.hata:
            hatalar += 1

        if not kuyruk and bekleyen is None and len(alinanlar) == len(baytlar):
            break

    return alinanlar, hatalar


def test_phy():
    print("\n--- M-04/M-05 PHY LOOPBACK (TB-08 modeli) ---")

    alinan, hata = phy_dongusu([0xA5])
    kontrol(alinan == [0xA5], "Tek bayt gidis-donus (0xA5)", "(alinan %s)" % alinan)
    kontrol(hata == 0, "Cerceve hatasi yok")

    gonderilen = list(range(256))
    alinan, hata = phy_dongusu(gonderilen)
    kontrol(alinan == gonderilen, "0x00..0xFF tamami kayipsiz",
            "(alinan %d bayt)" % len(alinan))
    kontrol(hata == 0, "256 bayt boyunca cerceve hatasi yok")

    # Kritik desenler: LSB-first hatasi bu baytlarda ortaya cikar
    desenler = [0x01, 0x80, 0x0F, 0xF0, 0xAA, 0x55, 0x7F, 0xFE]
    alinan, hata = phy_dongusu(desenler)
    kontrol(alinan == desenler, "LSB-first kritik desenleri (0x01/0x80/0xAA/0x55)",
            "(alinan %s)" % [hex(x) for x in alinan])


def test_rx_bit_seviyesi():
    """RX'i dogrudan bit uyarimiyla surer — TX'ten bagimsiz kontrol."""
    print("\n--- M-04 uart_rx bagimsiz bit uyarimi ---")
    ornekleme = 16
    bolucu = 4
    tik_basi_cevrim = bolucu

    def bayt_al(bayt, stop_biti=1, sapma=0.0):
        rx = UartRx(ornekleme)
        baud = BaudUretici(100_000_000, 100_000_000 // (bolucu * ornekleme), ornekleme)
        # Bit dizisi: start + 8 veri (LSB-first) + stop
        bitler = [0] + [(bayt >> i) & 1 for i in range(8)] + [stop_biti]
        # Gondericinin bit suresi (cevrim cinsinden), sapmali
        bit_cevrim = tik_basi_cevrim * ornekleme * (100.0 / (100.0 + sapma))

        sonuc = []
        hatalar = 0
        toplam = int(bit_cevrim * (len(bitler) + 3))
        for cevrim in range(toplam):
            indis = int(cevrim / bit_cevrim)
            seri = bitler[indis] if indis < len(bitler) else 1
            baud.saat_kenari()
            rx.saat_kenari(seri, baud.tik)
            if rx.gecerli:
                sonuc.append(rx.veri)
            if rx.hata:
                hatalar += 1
        return sonuc, hatalar

    for b in (0x00, 0xFF, 0xA5, 0x5A, 0x01, 0x80):
        sonuc, hatalar = bayt_al(b)
        kontrol(sonuc == [b], "Bit uyarimi 0x%02X" % b, "(alinan %s)" % sonuc)

    # Bozuk stop biti
    sonuc, hatalar = bayt_al(0x3C, stop_biti=0)
    kontrol(sonuc == [] and hatalar == 1,
            "Bozuk stop -> hata darbesi, bayt BASTIRILDI",
            "(sonuc=%s hata=%d)" % (sonuc, hatalar))

    # Baud sapmasi
    for sapma in (+2.0, -2.0, +3.0, -3.0):
        sonuc, _ = bayt_al(0xA5, sapma=sapma)
        kontrol(sonuc == [0xA5], "Baud sapmasi %+.0f%% -> hatasiz" % sapma,
                "(alinan %s)" % sonuc)


def test_endianness():
    """K-05/K-06 uzlasiminin PHY uzerinden ucdan uca dogrulanmasi."""
    print("\n--- K-05/K-06 ENDIANNESS (kritik) ---")
    deger = 0x11223344556677889900AABBCCDDEEFF_00112233445566778899AABBCCDDEEFF

    baytlar = list(deger.to_bytes(32, 'little'))
    alinan, hata = phy_dongusu(baytlar)
    kontrol(alinan == baytlar, "32 baytlik koordinat PHY'den gecti")

    geri = int.from_bytes(bytes(alinan), 'little')
    kontrol(geri == deger, "Little-endian gidis-donus degeri korudu")

    # Word ayristirma (paket_cozucu'nun yapacagi is)
    wordler = [int.from_bytes(bytes(alinan[i*4:(i+1)*4]), 'little') for i in range(8)]
    kontrol(wordler[0] == (deger & 0xFFFFFFFF),
            "word0 == deger[31:0]  (K-05)",
            "(word0=0x%08X)" % wordler[0])
    kontrol(wordler[7] == ((deger >> 224) & 0xFFFFFFFF),
            "word7 == deger[255:224]",
            "(word7=0x%08X)" % wordler[7])

    # Mevcut RTL sabitiyle capraz kontrol
    P = 0xFFFFFFFF00000001000000000000000000000000FFFFFFFFFFFFFFFFFFFFFFFF
    GX = 0x6B17D1F2E12C4247F8BCE6E563A440F277037D812DEB33A0F4A13945D898C296
    R = (1 << 256) % P
    RTL_GX_MONT = 0x18905f76a53755c679fb732b7762251075ba95fc5fedb60179e730d418a9143c
    kontrol((GX * R) % P == RTL_GX_MONT,
            "Montgomery uzlasimi mevcut ecdh_kex_top sabitleriyle uyumlu")


def main():
    print("=" * 62)
    print(" RTL CAPRAZ KONTROL — Katman 0-1 (M-01..M-05)")
    print(" Python cevrim-dogru model vs. testbench beklenen degerleri")
    print("=" * 62)

    test_baud()
    test_crc()
    test_fifo()
    test_rx_bit_seviyesi()
    test_phy()
    test_endianness()

    print("\n" + "=" * 62)
    if BASARISIZ:
        print(" SONUC: %d KONTROL KALDI" % len(BASARISIZ))
        for ad in BASARISIZ:
            print("   - %s" % ad)
        print("=" * 62)
        sys.exit(1)
    else:
        print(" SONUC: TUM KONTROLLER GECTI")
        print(" NOT: Bu, RTL'in dogrulugunu KANITLAMAZ. Python modeli ile")
        print("      Verilog ayni hatayi paylasabilir. xsim kosumu zorunludur.")
        print("=" * 62)


if __name__ == '__main__':
    main()
