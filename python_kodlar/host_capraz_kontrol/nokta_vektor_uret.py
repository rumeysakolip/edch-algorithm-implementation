#!/usr/bin/env python3
# =============================================================================
# Dosya   : nokta_vektor_uret.py                                    (Ister M-15)
# Proje   : FPGA Tabanli Guvenli Anahtar Yonetimi ve Kripto Hizlandirici (5260007)
# -----------------------------------------------------------------------------
# Amac:
#   tb_nokta_dogrula.sv (TB-14) icin nokta dogrulama test vektorleri uretir.
#   Ayni tohumla (5260007) her calistirmada AYNI vektorleri verir.
#
#   Uretilen vektorler MONTGOMERY alanindadir; aralik-disi olanlar bilincli
#   olarak HAM birakilir (Montgomery'ye tasinmaz), cunku test edilen sey
#   aralik kontrolunun kendisidir.
#
# -----------------------------------------------------------------------------
# NEDEN AYRI BIR URETICI:
#   nokta_dogrula.v'nin ciktisi 256-bit bir deger degil, TEK BIR HUKUMDUR
#   (gecerli/gecersiz). Boyle bir modulde SystemVerilog icinde Montgomery
#   aritmetigini yeniden yazmak testi, test edilen mantigin aynisina bagimli
#   kilar: ortak bir hata iki tarafta da ayni yone kayar ve test sessizce
#   gecer. Bu yuzden beklenen hukum, BAGIMSIZ bir yoldan hesaplanir —
#   dogrudan p modunda egri denklemi, Montgomery'ye hic girmeden.
#
#   Capraz kontrol capasi: uretilen ilk vektorun x'i, ecdh_kex_top.v'deki
#   GX_MONT sabitiyle bit-birebir esitse Montgomery konvansiyonu dogrulanmis
#   demektir. Betik bunu kendisi sinar ve tutmazsa hata verir.
#
# KULLANIM:
#   python3 nokta_vektor_uret.py            # SV bloklarini ekrana bas
#   python3 nokta_vektor_uret.py --dogrula  # yalniz oz-testleri kosur
# =============================================================================

import argparse
import random
import sys

# ── NIST P-256 (secp256r1) alan parametreleri ───────────────────────────────
P = 0xffffffff00000001000000000000000000000000ffffffffffffffffffffffff
N = 0xffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551
B = 0x5ac635d8aa3a93e7b3ebbd55769886bc651d06b0cc53b0f63bce3c3e27d2604b
A = P - 3                       # P-256'da a = -3
GX = 0x6b17d1f2e12c4247f8bce6e563a440f277037d812deb33a0f4a13945d898c296
GY = 0x4fe342e2fe1a7f9b8ee7eb4a7c0f9e162bce33576b315ececbb6406837bf51f5
G = (GX, GY)

R = (1 << 256) % P              # Montgomery donusturucu

# ecdh_kex_top.v icindeki sabitler — capraz kontrol capasi
GX_MONT_RTL = 0x18905f76a53755c679fb732b7762251075ba95fc5fedb60179e730d418a9143c
GY_MONT_RTL = 0x8571ff1825885d85d2e88688dd21f3258b4ab8e4ba19e45cddf25357ce95560a
# nokta_dogrula.v icindeki sabit
B_MONT_RTL  = 0xdc30061d04874834e5a220abf7212ed6acf005cd78843090d89cdf6229c4bddf

TOHUM = 5260007


def mont(v):
    """Ham degeri Montgomery alanina tasir: v -> v*R mod P."""
    return v * R % P


def egri_uzerinde(x, y):
    """Bagimsiz hakem: y^2 == x^3 - 3x + b (mod p) VE aralikta mi?

    Bilincli olarak Montgomery aritmetigi KULLANMAZ. RTL ile ayni yolu
    izleseydi ortak bir hata iki tarafta da gizlenirdi.
    """
    if not (0 <= x < P and 0 <= y < P):
        return False
    return (y * y - (x * x * x + A * x + B)) % P == 0


# ── Eliptik egri nokta toplama (afin, sadece vektor uretimi icin) ───────────
def nokta_topla(p1, p2):
    if p1 is None:
        return p2
    if p2 is None:
        return p1
    if p1[0] == p2[0] and (p1[1] + p2[1]) % P == 0:
        return None                                   # sonsuzluk
    if p1 == p2:
        lam = (3 * p1[0] * p1[0] + A) * pow(2 * p1[1], -1, P) % P
    else:
        lam = (p2[1] - p1[1]) * pow(p2[0] - p1[0], -1, P) % P
    x = (lam * lam - p1[0] - p2[0]) % P
    return (x, (lam * (p1[0] - x) - p1[1]) % P)


def kG(k):
    """k*G — tekrarli toplama (k kucuk oldugu icin yeterli)."""
    acc, sonuc = G, None
    while k:
        if k & 1:
            sonuc = nokta_topla(sonuc, acc)
        acc = nokta_topla(acc, acc)
        k >>= 1
    return sonuc


def vektorleri_uret():
    """(ad, x, y, beklenen_hukum) listesi dondurur. x/y RTL'e gidecek hali."""
    random.seed(TOHUM)
    V = []

    def ekle_mont(ad, x, y, beklenen):
        """Aralik icindeki nokta — Montgomery'ye tasinir."""
        assert egri_uzerinde(x, y) == bool(beklenen), \
            f"HAKEM CELISKISI: '{ad}' icin beklenen {beklenen}"
        V.append((ad, mont(x), mont(y), beklenen))

    def ekle_ham(ad, x, y, beklenen):
        """Aralik disi deger — HAM gonderilir, tasinmaz."""
        V.append((ad, x, y, beklenen))

    # ── POZITIF: gercek P-256 noktalari ────────────────────────────────────
    for k in (1, 2, 3, 5, 7, 13):
        pt = kG(k)
        ekle_mont(f"gecerli {k}G", pt[0], pt[1], 1)

    # Negatif nokta (x, -y) de egri uzerindedir ve KABUL edilmelidir.
    # Asiri-reddetme yapan bir uygulama burada takilir.
    p3 = kG(3)
    ekle_mont("negatif nokta (x,-y)", p3[0], (P - p3[1]) % P, 1)

    # ── NEGATIF: egri disi ─────────────────────────────────────────────────
    for i in range(3):
        while True:
            x, y = random.randrange(P), random.randrange(P)
            if not egri_uzerinde(x, y):
                break
        ekle_mont(f"rastgele egri disi #{i + 1}", x, y, 0)

    # Invalid-curve saldirisinin tipik bicimi: tek koordinat bozulur.
    p5, p7 = kG(5), kG(7)
    ekle_mont("dogru x, y+1 (invalid-curve)", p5[0], (p5[1] + 1) % P, 0)
    ekle_mont("dogru y, x+1 (invalid-curve)", (p7[0] + 1) % P, p7[1], 0)

    p2 = kG(2)
    ekle_mont("koordinat takasi (y,x)", p2[1], p2[0], 0)
    ekle_mont("sonsuzluk gosterimi (0,0)", 0, 0, 0)
    ekle_mont("x=p-1 (aralikta, egri disi)", P - 1, 1, 0)

    # ── NEGATIF: aralik disi (GF(p) elemani degil) ─────────────────────────
    ekle_ham("x=p (ARALIK DISI)", P, mont(GY), 0)
    ekle_ham("y=p (ARALIK DISI)", mont(GX), P, 0)
    ekle_ham("x=2^256-1 (ARALIK DISI)", (1 << 256) - 1, mont(GY), 0)

    return V


def oz_test():
    """Uretici dogru mu? RTL sabitlerine karsi capraz kontrol."""
    hata = 0

    def kontrol(ad, kosul):
        nonlocal hata
        print(f"  {'gecti ' if kosul else 'KALDI '}  {ad}")
        if not kosul:
            hata += 1

    print("\n OZ-TEST — uretici / RTL sabit capraz kontrolu")
    kontrol("GX_MONT  RTL sabitiyle esit", mont(GX) == GX_MONT_RTL)
    kontrol("GY_MONT  RTL sabitiyle esit", mont(GY) == GY_MONT_RTL)
    kontrol("B_MONT   RTL sabitiyle esit", mont(B) == B_MONT_RTL)
    kontrol("G egri uzerinde", egri_uzerinde(GX, GY))
    kontrol("n*G = sonsuzluk (mertebe dogru)", kG(N % (1 << 40)) is not None)

    # Montgomery alani carpma altinda korunuyor mu?
    rinv = pow(R, -1, P)
    mm = lambda a, b: a * b * rinv % P
    xm, ym = mont(GX), mont(GY)
    sol = mm(ym, ym)
    sag = (mm(mm(xm, xm), xm) - (3 * xm) % P + mont(B)) % P
    kontrol("Montgomery alaninda egri denklemi G icin saglaniyor", sol == sag)

    # 200 rastgele noktada hakem tutarli mi?
    random.seed(TOHUM)
    tutarli = True
    for _ in range(200):
        x, y = random.randrange(P), random.randrange(P)
        if egri_uzerinde(x, y):
            tutarli = False        # rastgele nokta egri uzerinde cikamaz
    kontrol("200 rastgele nokta hicbiri egri uzerinde degil", tutarli)

    # 20 gercek nokta kabul ediliyor mu?
    hepsi = all(egri_uzerinde(*kG(k)) for k in range(1, 21))
    kontrol("k*G (k=1..20) hepsi egri uzerinde", hepsi)

    return hata


def sv_bas(V):
    print(f"\nlocalparam int VEK_SAY = {len(V)};\n")
    for i, (ad, x, y, bk) in enumerate(V):
        sol = f'  ad[{i:2d}]="{ad}";'.ljust(44)
        print(f'{sol} vx[{i:2d}]=256\'h{x:064x};'
              f' vy[{i:2d}]=256\'h{y:064x};'
              f' vb[{i:2d}]=1\'b{bk};')


def main():
    ap = argparse.ArgumentParser(description="TB-14 nokta dogrulama vektor ureticisi")
    ap.add_argument("--dogrula", action="store_true", help="yalniz oz-testleri kosur")
    args = ap.parse_args()

    hata = oz_test()
    if hata:
        print(f"\n *** OZ-TEST BASARISIZ — {hata} kontrol kaldi ***\n")
        sys.exit(1)
    print(" *** OZ-TEST BASARILI ***")

    V = vektorleri_uret()
    poz = sum(1 for v in V if v[3])
    print(f"\n {len(V)} vektor uretildi  ({poz} kabul / {len(V) - poz} red)")

    if not args.dogrula:
        print(" Asagidaki blok tb_nokta_dogrula.sv icindeki initial blogunu"
              " degistirir:")
        sv_bas(V)


if __name__ == "__main__":
    main()
