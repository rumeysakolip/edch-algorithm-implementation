#!/usr/bin/env python3
# =============================================================================
# Dosya   : ecdh_uart_host.py                                       (Ister M-12)
# Proje   : FPGA Tabanli Guvenli Anahtar Yonetimi ve Kripto Hizlandirici (5260007)
# -----------------------------------------------------------------------------
# Amac:
#   Karttaki ecdh_uart_top ile seri port uzerinden konusan PC-tarafi istemci.
#   TB-12'nin yaptigi isin AYNISINI gercek donanimda yapar; ayni cerceve
#   formatini, ayni CRC-8'i, ayni little-endian donusumu ve AYNI VEKTOR
#   DOSYASINI kullanir (Ister M-13 — tek dogruluk kaynagi).
#
#   TB-12 gecip bu betik de ayni sonucu verirse, aradaki tek fark silikondur.
#
# -----------------------------------------------------------------------------
# KURULUM:
#   pip install pyserial
#
# KULLANIM:
#   python3 ecdh_uart_host.py --port COM4                 # tam dogrulama akisi
#   python3 ecdh_uart_host.py --port /dev/ttyUSB0         # Linux
#   python3 ecdh_uart_host.py --port COM4 --durum         # sadece durum oku
#   python3 ecdh_uart_host.py --port COM4 --tekrar 100    # 100 kez kosur (KT-01)
#   python3 ecdh_uart_host.py --liste                     # portlari listele
#
# -----------------------------------------------------------------------------
# *** GUVENLIK ***
#   --d-yukle secenegi yalnizca TEST_MODU ile derlenmis bitstream'de calisir.
#   Uretim bitstream'i bu komutu 0xE2 (bilinmeyen komut) ile reddeder; bu
#   BEKLENEN ve ISTENEN davranistir (Ister PROT-06).
#
#   Gizli anahtar d'yi OKUYAN bir komut YOKTUR ve eklenmemelidir.
#
#   Ortak Sir'in seri porttan okunabiliyor olmasi DEMO tercihidir. Gercek
#   dagitimda ortak sir cipten cikmamali, dogrudan simetrik sifreleme motoruna
#   beslenmelidir — aksi halde hattı dinleyen biri ECDH'nin sagladigi gizliligi
#   tamamen ortadan kaldirir.
# =============================================================================

import argparse
import json
import os
import sys
import time

try:
    import serial
    from serial.tools import list_ports
except ImportError:
    print("HATA: pyserial kurulu degil.  ->  pip install pyserial")
    sys.exit(1)


# ── Protokol sabitleri (Ister PROT-01..05) ──────────────────────────────────
BASLIK_GIRIS = 0xA5
BASLIK_CIKIS = 0x5A

KOM_QB_YUKLE    = 0x01
KOM_ECDH_BASLAT = 0x02
KOM_QA_OKU      = 0x03
KOM_SIR_OKU     = 0x04
KOM_DURUM_OKU   = 0x05
KOM_D_YUKLE     = 0x10      # yalnizca TEST_MODU

# ── Nesne deposu komutlari (Ister OBJ-01..04) ──────────────────────────────
KOM_NESNE_YAZ   = 0x06
KOM_NESNE_OKU   = 0x07
KOM_NESNE_BILGI = 0x08
KOM_NESNE_KILIT = 0x09

NESNE_PARCA     = 56        # cerceve basina veri bayti (4 bayt baslik + 56)
NESNE_SLOT_BAYT = 1024      # slot basina azami bayt

# FileID atamalari — drawio Akis 1 ile eslesir
FID_SERTIFIKA = 0           # adim 9  : cihaz sertifikasi
FID_TRUST     = 1           # adim 10 : trust anchor (yazma korumali olmali)

YANIT_ADI = {
    0x00: "OK",
    0xE1: "CRC hatasi",
    0xE2: "bilinmeyen komut",
    0xE3: "uzunluk hatasi",
    0xE4: "zaman asimi",
    0xE5: "cekirdek hatasi",
    # Ister SEC-03 — giris dogrulama reddi (DONANIM ARIZASI DEGIL)
    0xE6: "GECERSIZ NOKTA (Qb egri uzerinde degil / aralik disi)",
    0xE7: "GECERSIZ SKALER (d, [1,n-1] araligina sokulamadi)",
    # Ister OBJ-05 — nesne deposu reddi
    0xE8: "NESNE: gecersiz FileID",
    0xE9: "NESNE: slot yazma korumali (kilitli)",
    0xEA: "NESNE: ofset+uzunluk slot sinirini asiyor",
    0xEB: "NESNE: ofset 4'un kati degil",
}

# 0xE6/0xE7 protokol reddidir: donanim saglamdir, GONDERILEN VERI hatalidir.
# 0xE5 ise gercek bir donanim arizasidir. Host bu ikisini AYNI sekilde ele
# almamalidir; ilkinde karti sifirlamak yanlis teshise goturur.
PROTOKOL_REDDI = {0xE6, 0xE7}

# Durum bayti bitleri (Ister PROT-04)
DURUM_RDY     = 0x01
DURUM_QA      = 0x02
DURUM_SIR     = 0x04
DURUM_HATA    = 0x08


class ProtokolHatasi(Exception):
    pass


# ── CRC-8 / SMBus (poli 0x07, init 0x00) — RTL ile ayni ─────────────────────
def crc8(veri, baslangic=0x00):
    c = baslangic
    for b in veri:
        c ^= b
        for _ in range(8):
            c = ((c << 1) ^ 0x07) & 0xFF if (c & 0x80) else (c << 1) & 0xFF
    return c


# ── Cerceve olusturma / cozme ───────────────────────────────────────────────
def cerceve_kur(komut, veri=b""):
    """[0xA5][KOMUT][UZUNLUK][VERI][CRC8] — CRC baslik DAHIL."""
    if len(veri) % 4 != 0 or len(veri) > 64:
        raise ValueError("Veri uzunlugu 4'un kati ve <=64 olmali (%d)" % len(veri))
    govde = bytes([BASLIK_GIRIS, komut, len(veri)]) + bytes(veri)
    return govde + bytes([crc8(govde)])


def word_baytlari(deger):
    """256-bit tam sayi -> 32 bayt, LSB-first (Ister K-05/K-06)."""
    return deger.to_bytes(32, "little")


def baytlardan_deger(baytlar):
    return int.from_bytes(bytes(baytlar), "little")


class EcdhKart:
    """ecdh_uart_top ile konusan istemci."""

    def __init__(self, port, baud=115200, zaman_asimi=2.0, ayrintili=False):
        self.ayrintili = ayrintili
        self.seri = serial.Serial(port, baud, timeout=zaman_asimi)
        time.sleep(0.1)
        self.seri.reset_input_buffer()
        self.seri.reset_output_buffer()

    def kapat(self):
        self.seri.close()

    # ── Alt seviye ──────────────────────────────────────────────────────
    def _yanit_oku(self, bek_uzunluk):
        """[0x5A][DURUM][UZUNLUK][VERI][CRC] cercevesini okur ve dogrular."""
        toplam = bek_uzunluk + 4
        ham = self.seri.read(toplam)

        if len(ham) != toplam:
            raise ProtokolHatasi(
                "Yanit eksik: %d bayt geldi, %d beklendi. "
                "(Kart programlanmis mi? Baud dogru mu? RX/TX ters mi?)"
                % (len(ham), toplam))

        if ham[0] != BASLIK_CIKIS:
            raise ProtokolHatasi("Baslik 0x%02X (0x5A olmali) — senkron kaybi"
                                 % ham[0])

        durum   = ham[1]
        uzunluk = ham[2]
        veri    = ham[3:3 + bek_uzunluk]
        crc_gel = ham[3 + bek_uzunluk]
        crc_bek = crc8(ham[:3 + bek_uzunluk])

        if crc_gel != crc_bek:
            raise ProtokolHatasi("Yanit CRC hatasi: 0x%02X geldi, 0x%02X beklendi"
                                 % (crc_gel, crc_bek))

        if uzunluk != bek_uzunluk:
            raise ProtokolHatasi("Uzunluk %d, %d beklendi" % (uzunluk, bek_uzunluk))

        return durum, veri

    def _komut(self, komut, veri=b"", bek_uzunluk=0):
        cerceve = cerceve_kur(komut, veri)
        if self.ayrintili:
            print("    -> %s" % cerceve.hex(" "))
        self.seri.reset_input_buffer()
        self.seri.write(cerceve)
        self.seri.flush()
        durum, yanit = self._yanit_oku(bek_uzunluk)
        if self.ayrintili:
            print("    <- durum 0x%02X (%s), %d bayt"
                  % (durum, YANIT_ADI.get(durum, "?"), len(yanit)))
        return durum, yanit

    # ── Komutlar ────────────────────────────────────────────────────────
    def durum_oku(self):
        durum, _ = self._komut(KOM_DURUM_OKU, b"", 0)
        return durum

    def qb_yukle(self, qb_x, qb_y):
        veri = word_baytlari(qb_x) + word_baytlari(qb_y)
        durum, _ = self._komut(KOM_QB_YUKLE, veri, 0)
        if durum != 0x00:
            raise ProtokolHatasi("QB_YUKLE reddedildi: 0x%02X (%s)"
                                 % (durum, YANIT_ADI.get(durum, "?")))

    def d_yukle(self, d):
        """*** YALNIZCA TEST_MODU ile derlenmis bitstream'de calisir. ***"""
        durum, _ = self._komut(KOM_D_YUKLE, word_baytlari(d), 0)
        if durum == 0xE2:
            raise ProtokolHatasi(
                "D_YUKLE reddedildi (0xE2). Bitstream TEST_MODU olmadan "
                "uretilmis. Bu URETIM icin DOGRU davranistir.")
        if durum != 0x00:
            raise ProtokolHatasi("D_YUKLE hatasi: 0x%02X" % durum)

    def ecdh_baslat(self):
        durum, _ = self._komut(KOM_ECDH_BASLAT, b"", 0)
        if durum != 0x00:
            raise ProtokolHatasi("ECDH_BASLAT reddedildi: 0x%02X" % durum)

    def qa_oku(self):
        durum, veri = self._komut(KOM_QA_OKU, b"", 64)
        if durum == 0xE5:
            raise ProtokolHatasi("Cekirdek hatasi (0xE5)")
        return baytlardan_deger(veri[:32]), baytlardan_deger(veri[32:])

    def sir_oku(self):
        durum, veri = self._komut(KOM_SIR_OKU, b"", 64)
        if durum == 0xE5:
            raise ProtokolHatasi("Cekirdek hatasi (0xE5)")
        return baytlardan_deger(veri[:32]), baytlardan_deger(veri[32:])

    # ══════════════════════════════════════════════════════════════════════
    #  NESNE DEPOSU (Ister OBJ-01..04) — sertifika / trust anchor
    # ══════════════════════════════════════════════════════════════════════
    def nesne_parca_yaz(self, file_id, ofset, parca, son=False):
        """Tek cerceve: 4 bayt baslik + 56 bayt veri.

        parca 56 bayttan kisaysa sifirla doldurulur; nesnenin GERCEK uzunlugu
        SON bayragi ile birlikte gonderilen gecerli_bayt sayisindan belirlenir.
        Hattaki 4-hizalama ile nesnenin gercek boyu AYRI seylerdir.
        """
        if not 0 <= len(parca) <= NESNE_PARCA:
            raise ValueError(f"parca 0..{NESNE_PARCA} bayt olmali")
        if ofset % 4:
            raise ValueError("ofset 4'un kati olmali (RTL 0xEB ile reddeder)")

        bayrak = (0x80 if son else 0x00) | len(parca)
        baslik = bytes([file_id & 0xFF, ofset & 0xFF, (ofset >> 8) & 0xFF, bayrak])
        veri = baslik + parca + b"\x00" * (NESNE_PARCA - len(parca))

        durum, _ = self._komut(KOM_NESNE_YAZ, veri, 0)
        if durum != 0x00:
            raise ProtokolHatasi(
                "NESNE_YAZ reddedildi (id=%d ofset=%d): 0x%02X %s"
                % (file_id, ofset, durum, YANIT_ADI.get(durum, "?")))

    def nesne_parca_oku(self, file_id, ofset):
        """Tek cerceve: 56 bayt geri doner."""
        baslik = bytes([file_id & 0xFF, ofset & 0xFF, (ofset >> 8) & 0xFF, 0x00])
        durum, veri = self._komut(KOM_NESNE_OKU, baslik, NESNE_PARCA)
        if durum != 0x00:
            raise ProtokolHatasi(
                "NESNE_OKU reddedildi (id=%d ofset=%d): 0x%02X %s"
                % (file_id, ofset, durum, YANIT_ADI.get(durum, "?")))
        return veri

    def nesne_bilgi(self, file_id):
        """(uzunluk, kilit, gecerli) dondurur."""
        baslik = bytes([file_id & 0xFF, 0, 0, 0])
        durum, veri = self._komut(KOM_NESNE_BILGI, baslik, 4)
        if durum != 0x00:
            raise ProtokolHatasi("NESNE_BILGI reddedildi: 0x%02X %s"
                                 % (durum, YANIT_ADI.get(durum, "?")))
        d = int.from_bytes(veri, "little")
        return (d & 0x7FF), bool(d & (1 << 16)), bool(d & (1 << 17))

    def nesne_kilitle(self, file_id):
        """*** GERI ALINAMAZ ***  Kilidi acan bir komut YOKTUR.

        Trust anchor icin zorunludur: degistirilebilir bir trust store,
        saldirganin kendi CA'sini ekleyip TUM sertifika dogrulamasini
        sessizce anlamsizlastirmasina izin verir.
        """
        baslik = bytes([file_id & 0xFF, 0, 0, 0])
        durum, _ = self._komut(KOM_NESNE_KILIT, baslik, 0)
        if durum != 0x00:
            raise ProtokolHatasi("NESNE_KILIT reddedildi: 0x%02X %s"
                                 % (durum, YANIT_ADI.get(durum, "?")))

    def nesne_yaz(self, file_id, veri, dogrula=True):
        """Nesnenin tamamini parcalar halinde yazar.

        dogrula=True ise yazdiktan sonra GERI OKUYUP karsilastirir. Bu, hem
        hattaki bozulmayi (CRC-8 cerceve basina korur; cok parcali transferde
        tespit edilemeyen hata olasiligi ihmal edilemez) hem de bellege
        gercekten dogru yazildigini kontrol eder.
        """
        if len(veri) > NESNE_SLOT_BAYT:
            raise ValueError(f"nesne {len(veri)} bayt, slot siniri "
                             f"{NESNE_SLOT_BAYT}")
        if not veri:
            raise ValueError("bos nesne yazilamaz")

        parca_say = (len(veri) + NESNE_PARCA - 1) // NESNE_PARCA
        for i in range(parca_say):
            ofs = i * NESNE_PARCA
            self.nesne_parca_yaz(file_id, ofs, veri[ofs:ofs + NESNE_PARCA],
                                 son=(i == parca_say - 1))

        if not dogrula:
            return

        okunan = self.nesne_oku(file_id)
        if okunan != veri:
            # Ilk farkli baytin yerini bildir — hata ayiklamayi cok kolaylastirir
            fark = next((j for j in range(min(len(okunan), len(veri)))
                         if okunan[j] != veri[j]), min(len(okunan), len(veri)))
            raise ProtokolHatasi(
                "NESNE DOGRULAMA BASARISIZ (id=%d): yazilan %d bayt, okunan %d "
                "bayt, ilk fark ofset %d" % (file_id, len(veri), len(okunan), fark))

    def nesne_oku(self, file_id):
        """Nesnenin tamamini okur; gercek uzunluk NESNE_BILGI'den alinir."""
        uzunluk, _, gecerli = self.nesne_bilgi(file_id)
        if not gecerli or uzunluk == 0:
            return b""
        cikti = bytearray(uzunluk)
        ofs = 0
        while ofs < uzunluk:
            # Okuma HER ZAMAN 56 bayt dondurur ve RTL slot sinirini asan
            # okumayi reddeder (komsu slotun icerigi sizmasin diye). Nesnenin
            # kuyrugu slot sonuna dayaniyorsa ORTUSEN bir okuma yapilir:
            # geriye kayilir, fazlasi atilir. Bu, 1024 baytlik (tam slot)
            # nesnenin son baytlarina da erisilmesini saglar.
            oku_ofs = min(ofs, NESNE_SLOT_BAYT - NESNE_PARCA)
            oku_ofs -= oku_ofs % 4                      # 4-hizali kalmali
            blok = self.nesne_parca_oku(file_id, oku_ofs)

            bas = ofs - oku_ofs                          # blok icindeki baslangic
            alinacak = min(NESNE_PARCA - bas, uzunluk - ofs)
            cikti[ofs:ofs + alinacak] = blok[bas:bas + alinacak]
            ofs += alinacak
        return bytes(cikti)

    def bitmesini_bekle(self, azami_sn=5.0, aralik=0.05):
        """Ortak Sir hazir olana kadar durum sorgular."""
        bitis = time.time() + azami_sn
        while time.time() < bitis:
            d = self.durum_oku()
            if d & DURUM_HATA:
                raise ProtokolHatasi("Cekirdek hata bayragi set (durum 0x%02X)" % d)
            if d & DURUM_SIR:
                return d
            time.sleep(aralik)
        raise ProtokolHatasi("Zaman asimi: Ortak Sir %.1f sn icinde hazir olmadi"
                             % azami_sn)


# ── Vektor dosyasi ──────────────────────────────────────────────────────────
def vektor_yukle(yol=None):
    if yol is None:
        yol = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                           "..", "vektorler", "ecdh_vektor.json")
    yol = os.path.normpath(yol)
    if not os.path.exists(yol):
        print("HATA: vektor dosyasi yok: %s" % yol)
        print("      Once uretin:  python3 vektor_uret.py")
        sys.exit(1)
    with open(yol) as f:
        v = json.load(f)
    return {k: (int(x, 16) if isinstance(x, str) and x.startswith("0x") else x)
            for k, x in v.items()}


# ── Akislar ─────────────────────────────────────────────────────────────────
def durum_yazdir(d):
    print("  Durum bayti: 0x%02X" % d)
    print("    rdy=%d  qa_hazir=%d  sir_hazir=%d  hata=%d  asama=%d"
          % (bool(d & DURUM_RDY), bool(d & DURUM_QA), bool(d & DURUM_SIR),
             bool(d & DURUM_HATA), (d >> 4) & 3))


def tam_akis(kart, vek, test_modu, ayrintili):
    """d yukle -> Qb yukle -> baslat -> bekle -> oku -> dogrula."""
    if test_modu:
        print("  [1/5] Bilinen d yukleniyor (TEST_MODU)...")
        kart.d_yukle(vek["d_a"])
    else:
        print("  [1/5] d yukleme ATLANDI (uretim bitstream'i).")
        print("        Qa/Sir on-chip PRNG'ye bagli — golden model")
        print("        karsilastirmasi YAPILAMAZ, sadece tutarlilik kontrolu.")

    print("  [2/5] Qb yukleniyor (64 bayt)...")
    kart.qb_yukle(vek["qb_x_mont"], vek["qb_y_mont"])

    print("  [3/5] ECDH baslatiliyor...")
    t0 = time.time()
    kart.ecdh_baslat()

    print("  [4/5] Sonuc bekleniyor...")
    kart.bitmesini_bekle(azami_sn=5.0)
    sure = time.time() - t0
    print("        Tamamlandi (%.3f sn)" % sure)

    print("  [5/5] Sonuclar okunuyor...")
    qa_x, qa_y = kart.qa_oku()
    s_x,  s_y  = kart.sir_oku()

    print("\n  Qa.X = 0x%064x" % qa_x)
    print("  S.X  = 0x%064x" % s_x)

    if not test_modu:
        print("\n  NOT: TEST_MODU yok — degerler PRNG'ye bagli, karsilastirma yok.")
        return True

    print()
    tamam = True
    for ad, alinan, beklenen in [
        ("Qa.X", qa_x, vek["qa_x_mont"]),
        ("Qa.Y", qa_y, vek["qa_y_mont"]),
        ("S.X",  s_x,  vek["s_x_mont"]),
        ("S.Y",  s_y,  vek["s_y_mont"]),
    ]:
        if alinan == beklenen:
            print("  [GECTI] %-5s golden model ile AYNI" % ad)
        else:
            tamam = False
            print("  [KALDI] %-5s UYUSMUYOR" % ad)
            print("          beklenen 0x%064x" % beklenen)
            print("          alinan   0x%064x" % alinan)

    return tamam


def main():
    ap = argparse.ArgumentParser(
        description="ecdh_uart_top seri port istemcisi (Ister M-12)")
    ap.add_argument("--port", help="Seri port (COM4, /dev/ttyUSB0)")
    ap.add_argument("--baud", type=int, default=115200)
    ap.add_argument("--liste", action="store_true", help="Portlari listele")
    ap.add_argument("--durum", action="store_true", help="Sadece durum oku")
    ap.add_argument("--test-modu", action="store_true",
                    help="Bitstream TEST_MODU ile derlendi (d yuklenebilir)")
    ap.add_argument("--tekrar", type=int, default=1,
                    help="Akisi N kez kosur (KT-01 kararlilik testi)")
    ap.add_argument("--vektor", default=None, help="ecdh_vektor.json yolu")
    ap.add_argument("-v", "--ayrintili", action="store_true",
                    help="Ham cerceveleri goster")
    arg = ap.parse_args()

    if arg.liste:
        print("Bulunan seri portlar:")
        for p in list_ports.comports():
            print("  %-12s  %s" % (p.device, p.description))
        return

    if not arg.port:
        ap.error("--port gerekli (portlari gormek icin --liste)")

    vek = vektor_yukle(arg.vektor)

    print("=" * 60)
    print(" ECDH UART HOST — %s @ %d baud" % (arg.port, arg.baud))
    print(" Bitstream modu: %s" % ("TEST_MODU" if arg.test_modu else "URETIM"))
    print("=" * 60)

    try:
        kart = EcdhKart(arg.port, arg.baud, ayrintili=arg.ayrintili)
    except serial.SerialException as e:
        print("HATA: port acilamadi: %s" % e)
        sys.exit(1)

    try:
        if arg.durum:
            durum_yazdir(kart.durum_oku())
            return

        basarili = 0
        for k in range(arg.tekrar):
            if arg.tekrar > 1:
                print("\n--- Kosum %d/%d ---" % (k + 1, arg.tekrar))
            try:
                if tam_akis(kart, vek, arg.test_modu, arg.ayrintili):
                    basarili += 1
            except ProtokolHatasi as e:
                print("  HATA: %s" % e)

        print("\n" + "=" * 60)
        if arg.tekrar > 1:
            print(" SONUC: %d/%d kosum basarili" % (basarili, arg.tekrar))
        elif basarili == 1:
            print(" SONUC: BASARILI")
        else:
            print(" SONUC: BASARISIZ")
        print("=" * 60)
        sys.exit(0 if basarili == arg.tekrar else 1)

    except ProtokolHatasi as e:
        print("\nPROTOKOL HATASI: %s" % e)
        sys.exit(1)
    except KeyboardInterrupt:
        print("\nKullanici tarafindan durduruldu.")
    finally:
        kart.kapat()


if __name__ == "__main__":
    main()
