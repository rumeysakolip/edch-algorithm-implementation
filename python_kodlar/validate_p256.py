"""
validate_p256.py — NIST P-256 golden model doğrulama takımı.

Bu betik, RTL (ecdh-key-exchange/gonder/rtl/*.v) ile hizalanmış golden model
(src/) için P-256 ECDH + ECDSA doğrulamasını TEK dosyada toplar:

  1) ECDH açık-anahtar üretimi  — NIST ACVP CAVP KAS-ECC keyGen vektörleri
     (data/ecdsa-keygen/{prompt,expectedResults}.json, P-256 test grubu; 6 vektör).
  2) ECDSA imzalama + doğrulama — RFC 6979 Ek A.2.5 (NIST P-256, SHA-256)
     referans vektörleri (deterministik k, resmi NIST eğri parametreleriyle).
     NOT: NIST'in resmi CAVP ECDSA (186-4) sigGen/sigVer .zip dosyası bu ortamdan
     erişilebilir değildi (csrc.nist.gov ikili indirmeyi desteklemiyor, GitHub
     ayna kaynakları erişilemedi); RFC 6979 vektörleri aynı NIST P-256 eğrisini
     kullanan, IETF tarafından yayımlanmış, bağımsız doğrulanabilir bir
     alternatif referanstır.
  3) Straus-Shamir (dual scalar mult) — bağımsız affine referans uygulamaya
     karşı rastgele çapraz kontrol (yerel, vektörsüz doğrulama).
  4) Sahtecilik (tamper) tespiti — imzalanan mesaj değişince doğrulamanın
     reddetmesi.
  5) RTL'nin varsayılan (LFSR) nonce kaynağıyla uçtan uca işlevsel tur.

Çalıştırma:  python3 validate_p256.py
"""
import os
import sys
import json
import random

CURRENT_DIR = os.path.dirname(os.path.abspath(__file__))
if CURRENT_DIR not in sys.path:
    sys.path.insert(0, CURRENT_DIR)

from src.utils.curve_params import NIST_P256 as C
from src.ecdh_protocol import ECDH_Protocol
from src.ecdsa_protocol import ECDSA_Protocol
from src.point_arithmetic import PointArithmetic
from src.dual_scalar_mult import DualScalarMultiplier
from src.nonce_lfsr import RTL_LFSR_TRNG

PASS = 0
FAIL = 0


def check(name, ok, detail=""):
    global PASS, FAIL
    if ok:
        PASS += 1
        print(f"  [OK]   {name}")
    else:
        FAIL += 1
        print(f"  [FAIL] {name}  {detail}")


# ══════════════════════════════════════════════════════════════════════════
# 1) NIST ACVP CAVP — ECDSA keyGen (P-256) — data/ecdsa-keygen/
# ══════════════════════════════════════════════════════════════════════════
def test_keygen_vectors():
    print("\n=== 1) NIST ACVP KAS/ECDSA keyGen — P-256 (data/ecdsa-keygen/) ===")
    prompt_path = os.path.join(CURRENT_DIR, "data", "ecdsa-keygen", "prompt.json")
    expected_path = os.path.join(CURRENT_DIR, "data", "ecdsa-keygen", "expectedResults.json")
    if not (os.path.exists(prompt_path) and os.path.exists(expected_path)):
        print("  (atlandı: data/ecdsa-keygen/prompt.json veya expectedResults.json bulunamadı)")
        return

    with open(prompt_path, encoding="utf-8") as f:
        prompt_data = json.load(f)
    with open(expected_path, encoding="utf-8") as f:
        expected_data = json.load(f)

    tg_curves = {tg["tgId"]: tg["curve"] for tg in prompt_data.get("testGroups", [])}

    for tg in expected_data.get("testGroups", []):
        if tg_curves.get(tg["tgId"]) != "P-256":
            continue
        for test in tg.get("tests", []):
            d = int(test["d"], 16)
            exp_qx = int(test["qx"], 16)
            exp_qy = int(test["qy"], 16)
            Q_proj = ECDH_Protocol.generate_public_key(d, C)
            qx, qy = PointArithmetic.to_affine(Q_proj, C.p)
            check(f"keyGen tcId={test['tcId']}", (qx, qy) == (exp_qx, exp_qy))


# ══════════════════════════════════════════════════════════════════════════
# 2) RFC 6979 Ek A.2.5 — P-256, SHA-256, deterministik k
# ══════════════════════════════════════════════════════════════════════════
RFC6979_P256 = {
    "d": 0xC9AFA9D845BA75166B5C215767B1D6934E50C3DB36E89B127B8A622B120F6721,
    "Ux": 0x60FED4BA255A9D31C961EB74C6356D68C049B8923B61FA6CE669622E60F29FB6,
    "Uy": 0x7903FE1008B8BC99A41AE9E95628BC64F2F1B20C2D7E9F5177A3C294D4462299,
    "cases": [
        # (mesaj, k, r, s)  — yalnızca SHA-256 satırları (HashManager SHA-256 kullanır)
        (b"sample",
         0xA6E3C57DD01ABE90086538398355DD4C3B17AA873382B0F24D6129493D8AAD60,
         0xEFD48B2AACB6A8FD1140DD9CD45E81D69D2C877B56AAF991C34D0EA84EAF3716,
         0xF7CB1C942D657C41D436C7A1B6E29F65F3E900DBB9AFF4064DC4AB2F843ACDA8),
        (b"test",
         0xD16B6AE827F17175E040871A1C7EC3500192C4C92677336EC2537ACAEE0008E0,
         0xF1ABB023518351CD71D881567B1EA663ED3EFCF6C5132B354F28D3B0B7D38367,
         0x019F4113742A2B14BD25926B49C649155F267E60D3814B4C0CC84250E46F0083),
    ],
}


def test_rfc6979_vectors():
    print("\n=== 2) RFC 6979 Ek A.2.5 — P-256 / SHA-256 (deterministik k) ===")
    d = RFC6979_P256["d"]
    Q_proj = ECDH_Protocol.generate_public_key(d, C)
    qx, qy = PointArithmetic.to_affine(Q_proj, C.p)
    check("açık anahtar (Ux,Uy)", (qx, qy) == (RFC6979_P256["Ux"], RFC6979_P256["Uy"]))

    for msg, k, exp_r, exp_s in RFC6979_P256["cases"]:
        res = ECDSA_Protocol.sign(d, msg, C, k_nonce=k)
        r, s = res["r_s_tuple"]
        check(f"sign r,s  (msg={msg!r})", (r, s) == (exp_r, exp_s))
        ok = ECDSA_Protocol.verify((qx, qy), msg, r, s, C)
        check(f"verify (Straus-Shamir)  (msg={msg!r})", ok is True)


# ══════════════════════════════════════════════════════════════════════════
# 3) Straus-Shamir çapraz kontrol (bağımsız affine referansa karşı)
# ══════════════════════════════════════════════════════════════════════════
def _ref_affine_ops(p, a):
    def inv(x):
        return pow(x, p - 2, p)

    def padd(P, Q):
        if P is None:
            return Q
        if Q is None:
            return P
        x1, y1 = P
        x2, y2 = Q
        if x1 == x2:
            if (y1 + y2) % p == 0:
                return None
            return pdbl(P)
        l = ((y2 - y1) * inv(x2 - x1)) % p
        x3 = (l * l - x1 - x2) % p
        y3 = (l * (x1 - x3) - y1) % p
        return (x3, y3)

    def pdbl(P):
        if P is None:
            return None
        x1, y1 = P
        l = ((3 * x1 * x1 + a) * inv(2 * y1)) % p
        x3 = (l * l - 2 * x1) % p
        y3 = (l * (x1 - x3) - y1) % p
        return (x3, y3)

    def pmul(d, P):
        R = None
        Q = P
        while d:
            if d & 1:
                R = padd(R, Q)
            Q = pdbl(Q)
            d >>= 1
        return R

    return padd, pmul


def test_dual_scalar_cross_check(n_trials=25):
    print(f"\n=== 3) Straus-Shamir çapraz kontrol ({n_trials} rastgele deneme) ===")
    padd, pmul = _ref_affine_ops(C.p, -3 % C.p)
    random.seed(20260729)
    all_ok = True
    for _ in range(n_trials):
        u1 = random.randrange(1, C.n)
        u2 = random.randrange(1, C.n)
        qd = random.randrange(1, C.n)
        Qpub = pmul(qd, (C.Gx, C.Gy))
        ref = padd(pmul(u1, (C.Gx, C.Gy)), pmul(u2, Qpub))
        got_proj = DualScalarMultiplier.multiply(u1, u2, Qpub, C)
        got = PointArithmetic.to_affine(got_proj, C.p)
        if got != ref:
            all_ok = False
            break
    check("Straus-Shamir == bağımsız referans (tüm denemeler)", all_ok)


# ══════════════════════════════════════════════════════════════════════════
# 4) Sahtecilik (tamper) tespiti
# ══════════════════════════════════════════════════════════════════════════
def test_tamper_detection():
    print("\n=== 4) Sahtecilik tespiti ===")
    d = RFC6979_P256["d"]
    qx, qy = RFC6979_P256["Ux"], RFC6979_P256["Uy"]
    k, exp_r, exp_s = RFC6979_P256["cases"][0][1:]
    res = ECDSA_Protocol.sign(d, b"sample", C, k_nonce=k)
    r, s = res["r_s_tuple"]
    ok_orig = ECDSA_Protocol.verify((qx, qy), b"sample", r, s, C)
    ok_tampered = ECDSA_Protocol.verify((qx, qy), b"SAMPLE-DEGISTI", r, s, C)
    check("orijinal mesaj doğrulanır", ok_orig is True)
    check("değiştirilmiş mesaj REDDEDİLİR", ok_tampered is False)


# ══════════════════════════════════════════════════════════════════════════
# 5) RTL'nin varsayılan LFSR nonce kaynağıyla uçtan uca işlevsel tur
# ══════════════════════════════════════════════════════════════════════════
def test_lfsr_default_roundtrip():
    print("\n=== 5) Varsayılan (RTL-LFSR) nonce kaynağıyla uçtan uca tur ===")
    d = 0x1A2B3C4D5E6F7089ABCDEF0123456789ABCDEF0123456789ABCDEF012345678
    Q_proj = ECDH_Protocol.generate_public_key(d, C)
    qx, qy = PointArithmetic.to_affine(Q_proj, C.p)
    lfsr = RTL_LFSR_TRNG()  # komut_yoneticisi.v varsayılan tohumuyla
    res = ECDSA_Protocol.sign(d, b"lfsr-roundtrip-test", C, lfsr=lfsr)
    r, s = res["r_s_tuple"]
    ok = ECDSA_Protocol.verify((qx, qy), b"lfsr-roundtrip-test", r, s, C)
    check("LFSR nonce ile imzala -> doğrula", ok is True)
    check("k_used aralık içinde (1 <= k < n)", 1 <= res["k_used"] < C.n)


if __name__ == "__main__":
    test_keygen_vectors()
    test_rfc6979_vectors()
    test_dual_scalar_cross_check()
    test_tamper_detection()
    test_lfsr_default_roundtrip()

    print("\n" + "=" * 50)
    print(f"  TOPLAM: {PASS + FAIL}   BAŞARILI: {PASS}   BAŞARISIZ: {FAIL}")
    print("=" * 50)
    sys.exit(1 if FAIL else 0)
