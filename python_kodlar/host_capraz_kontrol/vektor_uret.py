#!/usr/bin/env python3
# =============================================================================
# Dosya   : vektor_uret.py                                          (İster M-13)
# Proje   : FPGA Tabanlı Güvenli Anahtar Yönetimi ve Kripto Hızlandırıcı (5260007)
# -----------------------------------------------------------------------------
# Amaç:
#   Testbench'ler ve PC-tarafı host betiği için TEK DOĞRULUK KAYNAĞI olan
#   ECDH test vektörlerini üretir. (d, Qb, Qa=d·G, S=d·Qb) dörtlüsünü hem
#   normal hem Montgomery formda yazar.
#
#   TB ve host AYNI dosyayı okur. Ayrı ayrı vektör tanımlanırsa, uyuşmazlık
#   çıktığında hangisinin yanlış olduğu anlaşılamaz.
#
# Montgomery uzlaşımı (mevcut RTL'den doğrulanmıştır):
#   R        = 2^256 mod p
#   X_mont   = X * R mod p
#   ecdh_kex_top içindeki GX_MONT/GY_MONT sabitleri bu kuralla üretilmiştir.
#
# Word/bayt sırası (İster K-05, K-06):
#   word0 = bit[31:0]  → little-endian word sırası
#   word içi ilk bayt = bit[7:0] → LSB-first
#   Python karşılığı: int.to_bytes(32, 'little')
#
# Çıktılar (vektorler/ altına):
#   ecdh_vektor.hex   → TB'ler için $readmemh (satır başına 32-bit word)
#   ecdh_vektor.vh    → TB'ler için localparam tanımları
#   ecdh_vektor.json  → host betiği (ecdh_uart_host.py) için
#
# Kullanım: python3 vektor_uret.py [--tohum 1]
# =============================================================================

import argparse
import json
import os

# ── NIST P-256 parametreleri ────────────────────────────────────────────────
P  = 0xFFFFFFFF00000001000000000000000000000000FFFFFFFFFFFFFFFFFFFFFFFF
A  = 0xFFFFFFFF00000001000000000000000000000000FFFFFFFFFFFFFFFFFFFFFFFC
B  = 0x5AC635D8AA3A93E7B3EBBD55769886BC651D06B0CC53B0F63BCE3C3E27D2604B
GX = 0x6B17D1F2E12C4247F8BCE6E563A440F277037D812DEB33A0F4A13945D898C296
GY = 0x4FE342E2FE1A7F9B8EE7EB4A7C0F9E162BCE33576B315ECECBB6406837BF51F5
N  = 0xFFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551

R_MOD_P = (1 << 256) % P          # Montgomery R
BIT_UZUNLUK = 256
WORD_SAYISI = BIT_UZUNLUK // 32   # 8


# ── Eğri aritmetiği (affine, referans amaçlı — sabit zamanlı DEĞİL) ─────────
# NOT: Bu betik yalnızca beklenen değeri üretmek içindir; donanımdaki sabit
#      zamanlı Montgomery Ladder'ın yerine geçmez.

def nokta_topla(nokta1, nokta2):
    """Affine nokta toplama. Sonsuz nokta None ile temsil edilir."""
    if nokta1 is None:
        return nokta2
    if nokta2 is None:
        return nokta1

    x1, y1 = nokta1
    x2, y2 = nokta2

    if x1 == x2 and (y1 + y2) % P == 0:
        return None  # P + (-P) = sonsuz

    if nokta1 == nokta2:
        egim = (3 * x1 * x1 + A) * pow(2 * y1, P - 2, P) % P
    else:
        egim = (y2 - y1) * pow(x2 - x1, P - 2, P) % P

    x3 = (egim * egim - x1 - x2) % P
    y3 = (egim * (x1 - x3) - y1) % P
    return (x3, y3)


def skaler_carp(katsayi, nokta):
    """Double-and-add. Referans model — yan kanal güvenliği HEDEF DEĞİL."""
    sonuc = None
    toplanan = nokta
    while katsayi:
        if katsayi & 1:
            sonuc = nokta_topla(sonuc, toplanan)
        toplanan = nokta_topla(toplanan, toplanan)
        katsayi >>= 1
    return sonuc


def egri_uzerinde_mi(nokta):
    """y^2 == x^3 + a·x + b (mod p) kontrolü."""
    if nokta is None:
        return True
    x, y = nokta
    return (y * y - (x * x * x + A * x + B)) % P == 0


# ── Montgomery dönüşümü ─────────────────────────────────────────────────────

def mont_ileri(deger):
    """Normal → Montgomery: X·R mod p"""
    return (deger * R_MOD_P) % P


def mont_geri(deger):
    """Montgomery → Normal: X·R^-1 mod p"""
    return (deger * pow(R_MOD_P, P - 2, P)) % P


# ── Word/bayt ayrıştırma (İster K-05, K-06) ─────────────────────────────────

def word_listesi(deger):
    """256-bit tam sayı → 8 adet 32-bit word, little-endian (word0 = [31:0])."""
    return [(deger >> (32 * i)) & 0xFFFFFFFF for i in range(WORD_SAYISI)]


def bayt_dizisi(deger):
    """256-bit tam sayı → 32 bayt, LSB-first. Hat üzerinde gönderilen sıra."""
    return deger.to_bytes(32, 'little')


# ── Vektör üretimi ──────────────────────────────────────────────────────────

def vektor_uret(tohum=1):
    """
    Deterministik test vektörü üretir.

    tohum: küçük bir tam sayı. Aynı tohum her zaman aynı vektörü verir —
           TB ve host'un aynı değerleri görmesi buna bağlıdır.
    """
    # Özel anahtarlar: deterministik ama yapısız olsun diye SHA benzeri
    # bir karıştırma yerine basit modüler türetme kullanıyoruz.
    # Kriptografik değildir; SADECE test amaçlıdır.
    d_a = (0xC9AF_A9D8_45BA_7517_6C39_37D9_1DA0_2C2A_1B2C_3D4E_5F60_7182_93A4_B5C6_D7E8_F901
           + tohum * 0x1234_5678_9ABC_DEF0) % N
    d_b = (0x7A1F_B3C5_D7E9_0B2D_4F61_8395_A7B9_CBDD_EF01_1325_3749_5B6D_7F91_A3B5_C7D9_EBFD
           + tohum * 0x0FED_CBA9_8765_4321) % N

    if d_a == 0 or d_b == 0:
        raise ValueError("Özel anahtar sıfır olamaz")

    G = (GX, GY)

    # Qa = d_a · G   (FPGA'nın ürettiği açık anahtar)
    qa = skaler_carp(d_a, G)
    # Qb = d_b · G   (karşı tarafın açık anahtarı — UART'tan yüklenecek)
    qb = skaler_carp(d_b, G)
    # S = d_a · Qb   (FPGA'nın hesaplayacağı ortak sır)
    s_fpga = skaler_carp(d_a, qb)
    # Çapraz kontrol: d_b · Qa aynı sonucu vermeli
    s_karsi = skaler_carp(d_b, qa)

    # ── Doğrulamalar ────────────────────────────────────────────────────
    assert egri_uzerinde_mi(qa), "Qa eğri üzerinde değil"
    assert egri_uzerinde_mi(qb), "Qb eğri üzerinde değil"
    assert egri_uzerinde_mi(s_fpga), "S eğri üzerinde değil"
    assert s_fpga == s_karsi, "ECDH simetri kontrolü BAŞARISIZ (d_a·Qb != d_b·Qa)"
    assert skaler_carp(N, G) is None, "n·G sonsuz nokta olmalı"
    assert mont_geri(mont_ileri(GX)) == GX, "Montgomery gidiş-dönüş hatalı"

    return {
        'tohum': tohum,
        'd_a': d_a, 'd_b': d_b,
        'qa': qa, 'qb': qb, 's': s_fpga,
    }


# ── Dosya yazıcıları ────────────────────────────────────────────────────────

def hex_yaz(yol, vek):
    """$readmemh için: satır başına bir 32-bit word, little-endian sırada."""
    alanlar = [
        ('D_A',   vek['d_a']),          # skaler — Montgomery DEĞİL (n modülünde)
        ('QB_X',  mont_ileri(vek['qb'][0])),
        ('QB_Y',  mont_ileri(vek['qb'][1])),
        ('QA_X',  mont_ileri(vek['qa'][0])),
        ('QA_Y',  mont_ileri(vek['qa'][1])),
        ('S_X',   mont_ileri(vek['s'][0])),
        ('S_Y',   mont_ileri(vek['s'][1])),
    ]
    with open(yol, 'w') as f:
        f.write("// ecdh_vektor.hex — vektor_uret.py tarafindan uretildi\n")
        f.write("// Sira: D_A, QB_X, QB_Y, QA_X, QA_Y, S_X, S_Y\n")
        f.write("// Her alan 8 word, little-endian (word0 = bit[31:0])\n")
        f.write("// Koordinatlar MONTGOMERY formda; D_A skalerdir (donusum yok)\n")
        for ad, deger in alanlar:
            f.write("// --- %s ---\n" % ad)
            for word in word_listesi(deger):
                f.write("%08x\n" % word)
    return alanlar


def vh_yaz(yol, alanlar, vek):
    """TB'lerin `include edebilecegi localparam tanimlari."""
    with open(yol, 'w') as f:
        f.write("// =========================================================\n")
        f.write("// ecdh_vektor.vh — vektor_uret.py tarafindan uretildi\n")
        f.write("// ELLE DUZENLEMEYIN. Yeniden uretmek icin:\n")
        f.write("//   python3 host/vektor_uret.py --tohum %d\n" % vek['tohum'])
        f.write("// =========================================================\n\n")
        for ad, deger in alanlar:
            f.write("localparam [255:0] VEK_%-6s = 256'h%064x;\n" % (ad, deger))
        f.write("\n// Normal (Montgomery olmayan) formda — insan okunurlugu icin\n")
        f.write("// QA_X_NORM = 256'h%064x\n" % vek['qa'][0])
        f.write("// S_X_NORM  = 256'h%064x\n" % vek['s'][0])


def json_yaz(yol, vek):
    """host betigi (ecdh_uart_host.py) icin."""
    icerik = {
        'tohum': vek['tohum'],
        'aciklama': 'ECDH test vektoru — TB ve host icin ortak kaynak',
        'montgomery_R': hex(R_MOD_P),
        'word_sirasi': 'little-endian (word0 = bit[31:0])',
        'bayt_sirasi': 'LSB-first',
        'd_a': hex(vek['d_a']),
        'qb_x_mont': hex(mont_ileri(vek['qb'][0])),
        'qb_y_mont': hex(mont_ileri(vek['qb'][1])),
        'qa_x_mont': hex(mont_ileri(vek['qa'][0])),
        'qa_y_mont': hex(mont_ileri(vek['qa'][1])),
        's_x_mont':  hex(mont_ileri(vek['s'][0])),
        's_y_mont':  hex(mont_ileri(vek['s'][1])),
        'qa_x_norm': hex(vek['qa'][0]),
        'qa_y_norm': hex(vek['qa'][1]),
        's_x_norm':  hex(vek['s'][0]),
        's_y_norm':  hex(vek['s'][1]),
        # Hat uzerinde gonderilecek ham bayt dizileri (hex string)
        'qb_yukle_veri': (bayt_dizisi(mont_ileri(vek['qb'][0])) +
                          bayt_dizisi(mont_ileri(vek['qb'][1]))).hex(),
        'd_yukle_veri':  bayt_dizisi(vek['d_a']).hex(),
    }
    with open(yol, 'w') as f:
        json.dump(icerik, f, indent=2)


# ── Ana akış ────────────────────────────────────────────────────────────────

def main():
    ayristirici = argparse.ArgumentParser(
        description="ECDH UART test vektoru ureticisi (Ister M-13)")
    ayristirici.add_argument('--tohum', type=int, default=1,
                             help="Deterministik vektor tohumu (varsayilan: 1)")
    ayristirici.add_argument('--cikti', default=None,
                             help="Cikti dizini (varsayilan: ../vektorler)")
    arg = ayristirici.parse_args()

    if arg.cikti:
        cikti_dizin = arg.cikti
    else:
        cikti_dizin = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                   '..', 'vektorler')
    cikti_dizin = os.path.normpath(cikti_dizin)
    os.makedirs(cikti_dizin, exist_ok=True)

    print("ECDH test vektoru uretiliyor (tohum=%d)..." % arg.tohum)
    vek = vektor_uret(arg.tohum)
    print("  [OK] Egri uzerinde olma kontrolu")
    print("  [OK] ECDH simetri kontrolu (d_a.Qb == d_b.Qa)")
    print("  [OK] n.G == sonsuz nokta")
    print("  [OK] Montgomery gidis-donus")

    yol_hex  = os.path.join(cikti_dizin, 'ecdh_vektor.hex')
    yol_vh   = os.path.join(cikti_dizin, 'ecdh_vektor.vh')
    yol_json = os.path.join(cikti_dizin, 'ecdh_vektor.json')

    alanlar = hex_yaz(yol_hex, vek)
    vh_yaz(yol_vh, alanlar, vek)
    json_yaz(yol_json, vek)

    print("\nYazilan dosyalar:")
    for y in (yol_hex, yol_vh, yol_json):
        print("  %s" % y)

    print("\nOzet:")
    print("  d_a  = 0x%064x" % vek['d_a'])
    print("  Qa.x = 0x%064x  (normal)" % vek['qa'][0])
    print("  S.x  = 0x%064x  (normal)" % vek['s'][0])
    print("  S.x  = 0x%064x  (Montgomery)" % mont_ileri(vek['s'][0]))
    print("\n  Hat uzerindeki ilk 8 bayt (QB_YUKLE verisi):")
    print("  %s" % bayt_dizisi(mont_ileri(vek['qb'][0]))[:8].hex(' '))


if __name__ == '__main__':
    main()
