#!/usr/bin/env python3
# =============================================================================
# Dosya   : katman2_capraz_kontrol.py
# Proje   : FPGA Tabanlı Güvenli Anahtar Yönetimi ve Kripto Hızlandırıcı (5260007)
# -----------------------------------------------------------------------------
# Amaç:
#   Katman 2 modüllerinin (M-06 paket_cozucu, M-07 paket_kurucu) mantığını
#   ÇEVRİM-DOĞRU olarak Python'da yeniden kurar ve TB-06/07/09'un beklenen
#   değerlerini üretir.
#
#   EN KRİTİK KONTROL: TB-09 karşılıklı testi — kurucunun ürettiği çerçeve
#   çözücü tarafından hatasız çözülmeli VE word değerleri korunmalı.
#   Endianness hatası burada yakalanmazsa TB-12'ye kadar sessiz kalır.
#
#   Modeller Verilog kaynaklarını satır satır takip eder; RTL değişirse bu
#   dosya da güncellenmelidir.
#
# Kullanım: python3 katman2_capraz_kontrol.py
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
# CRC-8 (M-03 ile aynı)
# =============================================================================
class Crc8:
    def __init__(self, polinom=0x07, baslangic=0x00):
        self.polinom = polinom
        self.baslangic = baslangic
        self.crc = baslangic

    def temizle(self):
        self.crc = self.baslangic

    def bayt(self, b):
        g = self.crc ^ b
        for _ in range(8):
            g = ((g << 1) ^ self.polinom) & 0xFF if (g & 0x80) else (g << 1) & 0xFF
        self.crc = g
        return self.crc


def crc8_dizi(veri, baslangic=0x00):
    c = Crc8(baslangic=baslangic)
    for b in veri:
        c.bayt(b)
    return c.crc


# =============================================================================
# Referans çerçeveleyici (host tarafının yapacağı iş)
# =============================================================================
BASLIK_GIRIS = 0xA5
BASLIK_CIKIS = 0x5A


def cerceve_kur(komut, veri=b"", baslik=BASLIK_GIRIS):
    """[BASLIK][KOMUT][UZUNLUK][VERI][CRC8] — CRC baslik dahil."""
    govde = bytes([baslik, komut, len(veri)]) + bytes(veri)
    return govde + bytes([crc8_dizi(govde)])


def word_listesi(deger, word_sayisi=8):
    """256-bit -> 8 word, little-endian (K-05)."""
    return [(deger >> (32 * i)) & 0xFFFFFFFF for i in range(word_sayisi)]


# =============================================================================
# M-06 · paket_cozucu modeli
# =============================================================================
C_BEKLE, C_KOMUT, C_UZUNLUK, C_VERI, C_CRC, C_TESLIM = range(6)


class PaketCozucu:
    def __init__(self, azami_veri=64, zaman_asimi=5_000_000):
        self.azami_veri = azami_veri
        self.zaman_asimi = zaman_asimi
        self.durum = C_BEKLE
        self.tampon = [0] * azami_veri
        self.veri_say = 0
        self.komut = 0
        self.uzunluk = 0
        self.word_indis = 0
        self.word_adet = 0
        self.word_indis_cik = 0
        self.word = 0
        self.word_gecerli = 0
        self.komut_gecerli = 0
        self.crc_hata = 0
        self.uzunluk_hata = 0
        self.zaman_asimi_bayrak = 0
        self.za_sayac = 0
        self.crc = Crc8()
        # crc besleme boru hatti (Verilog'da crc_besle_r 1 cevrim gecikmeli)
        self._crc_bekleyen = None

    def saat_kenari(self, bayt=0, bayt_gecerli=0, word_hazir=1):
        # Onceki cevrimde kuyruga alinan bayt simdi CRC'ye islenir
        if self._crc_bekleyen is not None:
            if self._crc_bekleyen == "temizle":
                self.crc.temizle()
            else:
                self.crc.bayt(self._crc_bekleyen)
            self._crc_bekleyen = None

        self.word_gecerli = 0
        self.komut_gecerli = 0
        self.crc_hata = 0
        self.uzunluk_hata = 0
        self.zaman_asimi_bayrak = 0

        # Zaman asimi
        if self.durum in (C_BEKLE, C_TESLIM):
            self.za_sayac = 0
        elif bayt_gecerli:
            self.za_sayac = 0
        elif self.za_sayac == self.zaman_asimi:
            self.za_sayac = 0
            self.zaman_asimi_bayrak = 1
            self.durum = C_BEKLE
        else:
            self.za_sayac += 1

        if self.durum == C_BEKLE:
            self.veri_say = 0
            self.word_indis = 0
            if bayt_gecerli and bayt == BASLIK_GIRIS:
                self._crc_bekleyen = bayt        # baslik CRC'ye DAHIL
                self.durum = C_KOMUT
            else:
                self._crc_bekleyen = "temizle"   # bostayken sifirda tut

        elif self.durum == C_KOMUT:
            if bayt_gecerli:
                self.komut = bayt
                self._crc_bekleyen = bayt
                self.durum = C_UZUNLUK

        elif self.durum == C_UZUNLUK:
            if bayt_gecerli:
                self._crc_bekleyen = bayt
                if bayt > self.azami_veri or (bayt & 3) != 0:
                    self.uzunluk_hata = 1
                    self.durum = C_BEKLE
                else:
                    self.uzunluk = bayt
                    self.word_adet = bayt >> 2
                    self.durum = C_CRC if bayt == 0 else C_VERI

        elif self.durum == C_VERI:
            if bayt_gecerli:
                self.tampon[self.veri_say] = bayt
                self._crc_bekleyen = bayt
                if self.veri_say == self.uzunluk - 1:
                    self.durum = C_CRC
                else:
                    self.veri_say += 1

        elif self.durum == C_CRC:
            if bayt_gecerli:
                if bayt == self.crc.crc:
                    self.komut_gecerli = 1
                    self.word_indis = 0
                    self.durum = C_BEKLE if self.word_adet == 0 else C_TESLIM
                else:
                    self.crc_hata = 1
                    self.durum = C_BEKLE   # WORD CIKISI YOK

        elif self.durum == C_TESLIM:
            if word_hazir:
                t = self.word_indis * 4
                # ENDIANNESS (K-06): ilk bayt = en dusuk bayt
                self.word = (self.tampon[t] |
                             (self.tampon[t + 1] << 8) |
                             (self.tampon[t + 2] << 16) |
                             (self.tampon[t + 3] << 24))
                self.word_gecerli = 1
                self.word_indis_cik = self.word_indis
                if self.word_indis + 1 == self.word_adet:
                    self.word_indis = 0
                    self.durum = C_BEKLE
                else:
                    self.word_indis += 1


# =============================================================================
# M-07 · paket_kurucu modeli
# =============================================================================
K_BOSTA, K_BASLIK, K_DURUM, K_UZUNLUK, K_WORD, K_VERI, K_CRC_BEK, K_CRC = range(8)


class PaketKurucu:
    def __init__(self, azami_veri=64, istek_yenile=256):
        self.azami_veri = azami_veri
        self.istek_yenile = istek_yenile
        self.yenile_sayac = 0
        self.durum = K_BOSTA
        self.durum_alan = 0
        self.uzunluk = 0
        self.word_adet = 0
        self.word_say = 0
        self.word_tut = 0
        self.bayt_say = 0
        self.bayt = 0
        self.bayt_gecerli = 0
        self.word_iste = 0
        self.uzunluk_hata = 0
        self.crc_bayt_cik = 0
        self.crc = Crc8()
        self._crc_bekleyen = None

    @property
    def bayt_cikis_gecerli(self):
        return self.bayt_gecerli or self.crc_bayt_cik

    def saat_kenari(self, basla=0, durum_alan=0, uzunluk=0,
                    word=0, word_gecerli=0, bayt_hazir=1):
        # CRC boru hatti: onceki cevrimde basilan bayt simdi islenir
        if self._crc_bekleyen is not None:
            if self._crc_bekleyen == "temizle":
                self.crc.temizle()
            else:
                self.crc.bayt(self._crc_bekleyen)
            self._crc_bekleyen = None

        # bayt_gecerli_r yuksekse crc birimi o bayti alir (bir sonraki kenarda)
        if self.bayt_gecerli:
            self._crc_bekleyen = self.bayt

        onceki_durum = self.durum
        self.bayt_gecerli = 0
        self.word_iste = 0
        self.uzunluk_hata = 0

        # crc_bayt_cik_r: D_CRC + bayt_hazir -> bir sonraki cevrimde yuksek
        yeni_crc_cik = 1 if (onceki_durum == K_CRC and bayt_hazir) else 0

        if self.durum == K_BOSTA:
            self.bayt_say = 0
            self.word_say = 0
            if basla:
                if uzunluk > self.azami_veri or (uzunluk & 3) != 0:
                    self.uzunluk_hata = 1
                else:
                    self.durum_alan = durum_alan
                    self.uzunluk = uzunluk
                    self.word_adet = uzunluk >> 2
                    self._crc_bekleyen = "temizle"
                    self.durum = K_BASLIK

        elif self.durum == K_BASLIK:
            if bayt_hazir:
                self.bayt = BASLIK_CIKIS
                self.bayt_gecerli = 1
                self.durum = K_DURUM

        elif self.durum == K_DURUM:
            if bayt_hazir:
                self.bayt = self.durum_alan
                self.bayt_gecerli = 1
                self.durum = K_UZUNLUK

        elif self.durum == K_UZUNLUK:
            if bayt_hazir:
                self.bayt = self.uzunluk
                self.bayt_gecerli = 1
                if self.word_adet == 0:
                    self.durum = K_CRC_BEK
                else:
                    self.durum = K_WORD
                    self.word_iste = 1        # ILK istek DARBESI
                    self.yenile_sayac = 0

        elif self.durum == K_WORD:
            # Istek darbesi bu duruma GIRERKEN uretildi; burada tekrarlanmaz.
            if word_gecerli:
                self.word_tut = word
                self.bayt_say = 0
                self.yenile_sayac = 0
                self.durum = K_VERI
            elif self.yenile_sayac == self.istek_yenile:
                self.word_iste = 1            # kilitlenme sigortasi
                self.yenile_sayac = 0
            else:
                self.yenile_sayac += 1

        elif self.durum == K_VERI:
            if bayt_hazir:
                # ENDIANNESS (K-06): en dusuk bayt ILK cikar
                self.bayt = (self.word_tut >> (8 * self.bayt_say)) & 0xFF
                self.bayt_gecerli = 1
                if self.bayt_say == 3:
                    self.bayt_say = 0
                    if self.word_say + 1 == self.word_adet:
                        self.durum = K_CRC_BEK
                    else:
                        self.word_say += 1
                        self.durum = K_WORD
                        self.word_iste = 1    # SONRAKI istek DARBESI
                        self.yenile_sayac = 0
                else:
                    self.bayt_say += 1

        elif self.durum == K_CRC_BEK:
            self.durum = K_CRC

        elif self.durum == K_CRC:
            if bayt_hazir:
                self.bayt = self.crc.crc
                self.durum = K_BOSTA

        self.crc_bayt_cik = yeni_crc_cik


# =============================================================================
# TESTLER
# =============================================================================

def cozucuye_besle(coz, baytlar, bayt_araligi=3, word_hazir=1):
    """Baytlari cozucuye UART benzeri araliklarla besler, cikan word'leri toplar."""
    wordler = []
    komutlar = []
    hatalar = {"crc": 0, "uzunluk": 0, "zaman_asimi": 0}

    def cevrim(b=0, gecerli=0):
        coz.saat_kenari(b, gecerli, word_hazir)
        if coz.word_gecerli:
            wordler.append((coz.word_indis_cik, coz.word))
        if coz.komut_gecerli:
            komutlar.append((coz.komut, coz.uzunluk))
        if coz.crc_hata:
            hatalar["crc"] += 1
        if coz.uzunluk_hata:
            hatalar["uzunluk"] += 1
        if coz.zaman_asimi_bayrak:
            hatalar["zaman_asimi"] += 1

    for b in baytlar:
        cevrim(b, 1)
        for _ in range(bayt_araligi):
            cevrim()
    # Teslim asamasinin bitmesi icin ek cevrimler
    for _ in range(200):
        cevrim()
    return wordler, komutlar, hatalar


def test_cozucu():
    print("\n--- M-06 paket_cozucu (TB-06) ---")

    deger = 0x0123456789ABCDEF_FEDCBA9876543210_1122334455667788_99AABBCCDDEEFF00
    veri = deger.to_bytes(32, 'little')
    cerceve = cerceve_kur(0x10, veri)          # D_YUKLE, 32 bayt

    coz = PaketCozucu()
    wordler, komutlar, hatalar = cozucuye_besle(coz, cerceve)

    kontrol(komutlar == [(0x10, 32)], "Gecerli cerceve -> komut 0x10, uzunluk 32",
            "(alinan %s)" % komutlar)
    kontrol(len(wordler) == 8, "8 word uretildi", "(uretilen %d)" % len(wordler))
    kontrol([w[0] for w in wordler] == list(range(8)),
            "Word indisleri 0..7 sirali")

    beklenen_wordler = word_listesi(deger)
    kontrol([w[1] for w in wordler] == beklenen_wordler,
            "ENDIANNESS: word degerleri dogru (K-05/K-06)",
            "\n       beklenen %s\n       alinan   %s" %
            ([hex(x) for x in beklenen_wordler], [hex(w[1]) for w in wordler]))
    kontrol(wordler[0][1] == (deger & 0xFFFFFFFF),
            "word0 == deger[31:0]", "(0x%08X)" % wordler[0][1])
    kontrol(hatalar == {"crc": 0, "uzunluk": 0, "zaman_asimi": 0},
            "Temiz cercevede hata bayragi yok", "(%s)" % hatalar)

    # ── CRC hatasi: tek bit bozulmasi ─────────────────────────────────────
    bozuk = bytearray(cerceve)
    bozuk[10] ^= 0x01                          # veri icinde tek bit
    coz = PaketCozucu()
    wordler, komutlar, hatalar = cozucuye_besle(coz, bozuk)
    kontrol(hatalar["crc"] == 1, "Tek bit bozulmasi -> CRC hatasi", "(%s)" % hatalar)
    kontrol(len(wordler) == 0,
            "CRC hatasinda WORD CIKISI BASTIRILDI (kritik)",
            "(uretilen %d word)" % len(wordler))
    kontrol(len(komutlar) == 0, "CRC hatasinda komut darbesi yok")

    # ── CRC baytinin kendisi bozuk ────────────────────────────────────────
    bozuk = bytearray(cerceve)
    bozuk[-1] ^= 0xFF
    coz = PaketCozucu()
    wordler, komutlar, hatalar = cozucuye_besle(coz, bozuk)
    kontrol(hatalar["crc"] == 1 and len(wordler) == 0,
            "Bozuk CRC bayti -> cerceve reddedildi")

    # ── Uzunluk hatasi ────────────────────────────────────────────────────
    for kotu_uz, ad in [(65, "65 > AZAMI_VERI"), (33, "33, 4'un kati degil")]:
        coz = PaketCozucu()
        govde = bytes([BASLIK_GIRIS, 0x01, kotu_uz])
        _, _, hatalar = cozucuye_besle(coz, govde + bytes([crc8_dizi(govde)]))
        kontrol(hatalar["uzunluk"] == 1, "Uzunluk hatasi: %s" % ad, "(%s)" % hatalar)

    # ── Verisiz komut (uzunluk 0) ─────────────────────────────────────────
    coz = PaketCozucu()
    wordler, komutlar, hatalar = cozucuye_besle(coz, cerceve_kur(0x02))
    kontrol(komutlar == [(0x02, 0)] and len(wordler) == 0,
            "Verisiz komut (ECDH_BASLAT) -> komut var, word yok",
            "(komut %s, word %d)" % (komutlar, len(wordler)))

    # ── Govdede 0xA5 resenkronize ETMEMELI ────────────────────────────────
    veri_a5 = bytes([0xA5] * 32)
    coz = PaketCozucu()
    wordler, komutlar, hatalar = cozucuye_besle(coz, cerceve_kur(0x10, veri_a5))
    kontrol(komutlar == [(0x10, 32)] and len(wordler) == 8,
            "Govdede 0xA5 resenkronizasyona sebep olmadi",
            "(komut %s, word %d)" % (komutlar, len(wordler)))
    kontrol(all(w[1] == 0xA5A5A5A5 for w in wordler),
            "0xA5 dolu govde dogru cozuldu")

    # ── Yarim cerceve + zaman asimi ───────────────────────────────────────
    # zaman_asimi, cozucuye_besle'nin 200 cevrimlik kuyruk beklemesinden KUCUK
    # olmali; aksi halde darbe hic gozlenmez (ilk surumde 500 yazilmisti).
    coz = PaketCozucu(zaman_asimi=50)
    wordler, komutlar, hatalar = cozucuye_besle(coz, cerceve[:6], bayt_araligi=3)
    kontrol(hatalar["zaman_asimi"] >= 1,
            "Yarim cerceve -> zaman asimi darbesi", "(%s)" % hatalar)
    kontrol(coz.durum == C_BEKLE, "Zaman asimi sonrasi BEKLE'ye donuldu")

    # Zaman asimi sonrasi normal cerceve hala alinabiliyor mu?
    wordler, komutlar, hatalar = cozucuye_besle(coz, cerceve)
    kontrol(komutlar == [(0x10, 32)] and len(wordler) == 8,
            "Zaman asimi sonrasi FSM toparlandi (kilitlenme yok)")

    # ── Cerceve oncesi cop baytlar ────────────────────────────────────────
    coz = PaketCozucu()
    cop = bytes([0x00, 0xFF, 0x12, 0x34]) + cerceve
    wordler, komutlar, _ = cozucuye_besle(coz, cop)
    kontrol(komutlar == [(0x10, 32)] and len(wordler) == 8,
            "Cerceve oncesi cop baytlar sessizce atildi")

    # ── 64 baytlik tam cerceve (QB_YUKLE) ─────────────────────────────────
    deger2 = 0xAABBCCDDEEFF0011_2233445566778899_0123456789ABCDEF_0F1E2D3C4B5A6978
    veri64 = deger.to_bytes(32, 'little') + deger2.to_bytes(32, 'little')
    coz = PaketCozucu()
    wordler, komutlar, _ = cozucuye_besle(coz, cerceve_kur(0x01, veri64))
    kontrol(komutlar == [(0x01, 64)] and len(wordler) == 16,
            "64 baytlik QB_YUKLE -> 16 word",
            "(komut %s, word %d)" % (komutlar, len(wordler)))
    bek = word_listesi(deger) + word_listesi(deger2)
    kontrol([w[1] for w in wordler] == bek,
            "16 word degerleri dogru (X||Y sirasi korundu)")


def kurucuyu_kostur(kur, durum_alan, wordler, bayt_hazir_deseni=None):
    """
    Kurucuyu surer ve uretilen bayt akisini dondurur.

    BESLEYICI DAVRANISI — kasitli olarak "korumasiz":
      Verilog testbench'indeki besleyici gibi, c_word_iste'yi gordugu HER
      cevrimde siradaki word'u gonderir. Kendi icinde "zaten yanit verdim"
      korumasi YOKTUR.
      Ilk surumde bu model korumali yazilmisti ve bu yuzden istek sinyalinin
      seviye tutmasindan kaynaklanan word kaybini KACIRDI (TB-07'de cikti).
      Model, RTL'in el sikismasini oldugu gibi zorlamalidir.
    """
    uzunluk = len(wordler) * 4
    baytlar = []
    kuyruk = list(wordler)
    verilecek = None
    basla = 1
    cevrim = 0
    azami = 5000

    while cevrim < azami:
        hazir = 1
        if bayt_hazir_deseni is not None:
            hazir = bayt_hazir_deseni(cevrim)

        # Onceki cevrimde kuyruga alinan word bu cevrimde sunulur
        w = 0
        w_gec = 0
        if verilecek is not None:
            w, w_gec = verilecek, 1
            verilecek = None
        # Istek gorulduyse siradaki word'u kuyruga al (KORUMA YOK — bkz. yukarI)
        if kur.word_iste and kuyruk:
            verilecek = kuyruk.pop(0)

        kur.saat_kenari(basla=basla, durum_alan=durum_alan, uzunluk=uzunluk,
                        word=w, word_gecerli=w_gec, bayt_hazir=hazir)
        basla = 0

        if kur.bayt_cikis_gecerli:
            baytlar.append(kur.bayt)

        cevrim += 1
        if cevrim > 5 and kur.durum == K_BOSTA and not kur.crc_bayt_cik and baytlar:
            break

    return bytes(baytlar)


def test_kurucu():
    print("\n--- M-07 paket_kurucu (TB-07) ---")

    deger = 0x0123456789ABCDEF_FEDCBA9876543210_1122334455667788_99AABBCCDDEEFF00
    wordler = word_listesi(deger)

    kur = PaketKurucu()
    cikti = kurucuyu_kostur(kur, 0x00, wordler)

    beklenen = cerceve_kur(0x00, deger.to_bytes(32, 'little'), baslik=BASLIK_CIKIS)
    kontrol(cikti == beklenen, "Uretilen cerceve referansla ayni",
            "\n       beklenen %s\n       uretilen %s" % (beklenen.hex(), cikti.hex()))

    kontrol(cikti[0] == BASLIK_CIKIS, "Baslik bayti 0x5A", "(0x%02X)" % cikti[0])
    kontrol(cikti[2] == 32, "Uzunluk alani 32", "(%d)" % cikti[2])
    kontrol(len(cikti) == 36, "Toplam cerceve 36 bayt", "(%d)" % len(cikti))
    kontrol(cikti[-1] == crc8_dizi(cikti[:-1]),
            "CRC bayti dogru (son veri bayti DAHIL — D_CRC_BEK calisiyor)",
            "(uretilen 0x%02X, beklenen 0x%02X)" % (cikti[-1], crc8_dizi(cikti[:-1])))

    # ── Verisiz cerceve ───────────────────────────────────────────────────
    kur = PaketKurucu()
    cikti = kurucuyu_kostur(kur, 0xE1, [])
    kontrol(cikti == cerceve_kur(0xE1, b"", baslik=BASLIK_CIKIS),
            "Verisiz cerceve (hata yaniti) dogru", "(uretilen %s)" % cikti.hex())
    kontrol(len(cikti) == 4, "Verisiz cerceve 4 bayt", "(%d)" % len(cikti))

    # ── Geri basinc altinda ───────────────────────────────────────────────
    #   bayt_hazir her 3 cevrimde bir dusuk -> FIFO dolu benzetimi
    kur = PaketKurucu()
    cikti_gb = kurucuyu_kostur(kur, 0x00, wordler,
                               bayt_hazir_deseni=lambda c: 0 if (c % 3 == 0) else 1)
    kontrol(cikti_gb == beklenen,
            "Geri basinc altinda bayt kaybi YOK (kritik)",
            "\n       beklenen %s\n       uretilen %s" % (beklenen.hex(), cikti_gb.hex()))

    # ── 64 baytlik cerceve ────────────────────────────────────────────────
    deger2 = 0xAABBCCDDEEFF0011_2233445566778899_0123456789ABCDEF_0F1E2D3C4B5A6978
    w16 = word_listesi(deger) + word_listesi(deger2)
    kur = PaketKurucu()
    cikti = kurucuyu_kostur(kur, 0x00, w16)
    bek64 = cerceve_kur(0x00, deger.to_bytes(32, 'little') + deger2.to_bytes(32, 'little'),
                        baslik=BASLIK_CIKIS)
    kontrol(cikti == bek64, "64 baytlik cerceve dogru", "(%d bayt)" % len(cikti))
    kontrol(len(cikti) == 68, "Toplam 68 bayt (>64 — FIFO derinligi 128 olmali)",
            "(%d)" % len(cikti))


def test_karsilikli():
    """TB-09 — KRITIK KAPI. Kurucu -> Cozucu, word degerleri korunmali."""
    print("\n--- TB-09 KARSILIKLI TEST (KRITIK KAPI) ---")

    test_degerleri = [
        (0x0123456789ABCDEF_FEDCBA9876543210_1122334455667788_99AABBCCDDEEFF00,
         "karisik desen"),
        (0x00000000000000000000000000000000000000000000000000000000FFFFFFFF,
         "sadece word0 dolu"),
        (0xFFFFFFFF00000000000000000000000000000000000000000000000000000000,
         "sadece word7 dolu"),
        (0x00000000000000000000000000000000000000000000000000000000_00000001,
         "tek bit — LSB"),
        ((1 << 255),
         "tek bit — MSB"),
        (0, "tamamen sifir"),
        ((1 << 256) - 1, "tamamen bir"),
    ]

    for deger, ad in test_degerleri:
        wordler = word_listesi(deger)

        kur = PaketKurucu()
        cerceve = kurucuyu_kostur(kur, 0x00, wordler)

        # Kurucu 0x5A baslik uretir; cozucu 0xA5 bekler -> baslik cevrilir.
        # (Gercek sistemde iki yon ayri hatlardir; burada mantik sinaniyor.)
        cerceve_giris = bytes([BASLIK_GIRIS]) + cerceve[1:-1]
        cerceve_giris += bytes([crc8_dizi(cerceve_giris)])

        coz = PaketCozucu()
        cikan, komutlar, hatalar = cozucuye_besle(coz, cerceve_giris)

        gidis_donus = [w[1] for w in cikan]
        kontrol(gidis_donus == wordler,
                "Gidis-donus: %s" % ad,
                "\n       gonderilen %s\n       alinan     %s" %
                ([hex(x) for x in wordler], [hex(x) for x in gidis_donus]))

        if gidis_donus == wordler:
            geri = sum(w << (32 * i) for i, w in enumerate(gidis_donus))
            if geri != deger:
                kontrol(False, "  -> 256-bit deger korunmadi: %s" % ad)

    # ── Gercek ECDH vektoruyle ────────────────────────────────────────────
    P = 0xFFFFFFFF00000001000000000000000000000000FFFFFFFFFFFFFFFFFFFFFFFF
    GX = 0x6B17D1F2E12C4247F8BCE6E563A440F277037D812DEB33A0F4A13945D898C296
    R = (1 << 256) % P
    gx_mont = (GX * R) % P
    RTL_GX_MONT = 0x18905f76a53755c679fb732b7762251075ba95fc5fedb60179e730d418a9143c

    kontrol(gx_mont == RTL_GX_MONT,
            "Montgomery sabiti ecdh_kex_top ile uyumlu")

    wordler = word_listesi(gx_mont)
    kur = PaketKurucu()
    cerceve = kurucuyu_kostur(kur, 0x00, wordler)
    cerceve_giris = bytes([BASLIK_GIRIS]) + cerceve[1:-1]
    cerceve_giris += bytes([crc8_dizi(cerceve_giris)])
    coz = PaketCozucu()
    cikan, _, _ = cozucuye_besle(coz, cerceve_giris)

    kontrol([w[1] for w in cikan] == wordler,
            "GX_MONT (gercek P-256 sabiti) gidis-donus korundu")
    kontrol(cikan[0][1] == (gx_mont & 0xFFFFFFFF),
            "GX_MONT word0 == bit[31:0]", "(0x%08X)" % cikan[0][1])

    # ── ecdh_demo_top'un yaptigi isle karsilastirma ───────────────────────
    #   Verilog: GX_MONT[qb_cnt_r*32 +: 32], qb_cnt_r = 0..7
    #   Bu, word_listesi() ile AYNI olmali. Endianness zincirinin son halkasi.
    demo_top_wordleri = [(gx_mont >> (32 * i)) & 0xFFFFFFFF for i in range(8)]
    kontrol([w[1] for w in cikan] == demo_top_wordleri,
            "UART word sirasi, ecdh_demo_top'un besleme sirasiyla AYNI (kritik)")


def main():
    print("=" * 64)
    print(" KATMAN 2 CAPRAZ KONTROL — M-06 paket_cozucu / M-07 paket_kurucu")
    print(" Python cevrim-dogru model vs. testbench beklenen degerleri")
    print("=" * 64)

    test_cozucu()
    test_kurucu()
    test_karsilikli()

    print("\n" + "=" * 64)
    if BASARISIZ:
        print(" SONUC: %d KONTROL KALDI" % len(BASARISIZ))
        for ad in BASARISIZ:
            print("   - %s" % ad)
        print("=" * 64)
        sys.exit(1)
    else:
        print(" SONUC: TUM KONTROLLER GECTI")
        print(" NOT: Python modeli ile Verilog ayni hatayi paylasabilir.")
        print("      TB-06/07/09'un xsim'de kosturulmasi ZORUNLUDUR.")
        print("=" * 64)


if __name__ == '__main__':
    main()
