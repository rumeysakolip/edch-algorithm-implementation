"""
validate_all_curves.py — Golden modelin JENERİK (curve-parametrized) matematiğini
projeyle UYUMLU TÜM NIST asal eğrilerinde (P-192, P-224, P-256, P-384, P-521)
doğrular ve sonunda tek bir özet tablo basar.

NOT: RTL donanım hedefi yalnızca P-256'dır (bkz. validate_p256.py — asıl,
RTL'e en yakın doğrulama takımı). Bu betik, aynı Jacobian nokta aritmetiği /
Montgomery çarpıcı / Straus-Shamir kodunun P-256'ya ÖZGÜ bir tesadüf olmadığını,
genel (a=-3) eğri matematiğini doğru uyguladığını göstermek için "çeşitlilik"
amaçlıdır — RTL'in kendisi yalnızca P-256 çalıştırır.

Kullanılan veri kaynakları (yalnızca projeyle uyumlu asal eğriler; ikili/Koblitz
eğriler tamamen dışlanmıştır):
  - keyGen  : P-192 -> data/kas-ecc-p192/internalProjection.json (NIST ACVP KAS-ECC)
              P-224/256/384/521 -> data/ecdsa-keygen/{prompt,expectedResults}.json (NIST ACVP)
  - sign/verify : data/rfc6979/p_curves_rfc6979.json (RFC 6979 Ek A.2.3-A.2.7'den derlenmiş,
              yalnızca bu 5 eğri) — bkz. o dosyanın "_aciklama" alanı.
  - Straus-Shamir : bağımsız affine referans uygulamaya karşı rastgele çapraz kontrol
              (vektörsüz, jenerik doğrulama — her eğride).
"""
import os
import sys
import json
import random

CURRENT_DIR = os.path.dirname(os.path.abspath(__file__))
if CURRENT_DIR not in sys.path:
    sys.path.insert(0, CURRENT_DIR)

from src.utils.curve_params import NIST_P192, NIST_P224, NIST_P256, NIST_P384, NIST_P521
from src.ecdh_protocol import ECDH_Protocol
from src.ecdsa_protocol import ECDSA_Protocol
from src.point_arithmetic import PointArithmetic
from src.dual_scalar_mult import DualScalarMultiplier

CURVES = {
    "P-192": NIST_P192,
    "P-224": NIST_P224,
    "P-256": NIST_P256,
    "P-384": NIST_P384,
    "P-521": NIST_P521,
}

# Golden modelin saf-Python bit-serial Montgomery çarpıcısı RTL'in çevrim-çevrim
# davranışını taklit ettiği için (bkz. src/modular_alu.py) BİLİNÇLİ OLARAK yavaştır
# — bu, RTL'e sadakat içindir. Yüksek bit uzunluklarında (P-384/P-521) tüm NIST ACVP
# vektör setini + çok sayıda rastgele Straus-Shamir denemesini koşmak dakikalar
# sürebilir. Bu betik hızlı/pratik bir "çeşitlilik" turu olması için eğri başına
# vektör/deneme sayısını sınırlar; RTL'in asıl hedefi olan P-256 için TAM kapsamlı
# doğrulama validate_p256.py'dedir (orada sınırlama YOKTUR).
MAX_KEYGEN_VECTORS = {"P-192": 6, "P-224": 6, "P-256": 6, "P-384": 4, "P-521": 3}
STRAUS_SHAMIR_TRIALS = {"P-192": 2, "P-224": 2, "P-256": 2, "P-384": 2, "P-521": 1}

RESULTS = {name: {"keyGen": None, "imza_dogrula": None, "straus_shamir": None} for name in CURVES}


def check(name, ok, detail=""):
    if ok:
        print(f"  [OK]   {name}")
    else:
        print(f"  [FAIL] {name}  {detail}")
    return ok


# ══════════════════════════════════════════════════════════════════════════
# 1) keyGen — NIST ACVP vektörleri
# ══════════════════════════════════════════════════════════════════════════
def test_keygen():
    print("\n=== 1) keyGen (NIST ACVP) — tüm desteklenen eğriler ===")

    # --- P-192: data/kas-ecc-p192/internalProjection.json ---
    path = os.path.join(CURRENT_DIR, "data", "kas-ecc-p192", "internalProjection.json")
    curve_name = "P-192"
    curve_ok = True
    n_tests = 0
    if os.path.exists(path):
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
        limit = MAX_KEYGEN_VECTORS[curve_name]
        for tg in data.get("testGroups", []):
            if tg.get("curve") != curve_name or n_tests >= limit:
                continue
            for test in tg.get("tests", []):
                if n_tests >= limit:
                    break
                if "privateIut" not in test:
                    continue
                d = int(test["privateIut"], 16)
                exp_qx = int(test["publicIutX"], 16)
                exp_qy = int(test["publicIutY"], 16)
                Q_proj = ECDH_Protocol.generate_public_key(d, CURVES[curve_name])
                qx, qy = PointArithmetic.to_affine(Q_proj, CURVES[curve_name].p)
                ok = (qx, qy) == (exp_qx, exp_qy)
                curve_ok &= ok
                n_tests += 1
    check(f"{curve_name} keyGen ({n_tests}/{MAX_KEYGEN_VECTORS[curve_name]} örnek vektör, NIST ACVP data/kas-ecc-p192)", curve_ok and n_tests > 0)
    RESULTS[curve_name]["keyGen"] = curve_ok and n_tests > 0

    # --- P-224 / P-256 / P-384 / P-521: data/ecdsa-keygen/{prompt,expectedResults}.json ---
    prompt_path = os.path.join(CURRENT_DIR, "data", "ecdsa-keygen", "prompt.json")
    expected_path = os.path.join(CURRENT_DIR, "data", "ecdsa-keygen", "expectedResults.json")
    if os.path.exists(prompt_path) and os.path.exists(expected_path):
        with open(prompt_path, encoding="utf-8") as f:
            prompt_data = json.load(f)
        with open(expected_path, encoding="utf-8") as f:
            expected_data = json.load(f)
        tg_curves = {tg["tgId"]: tg["curve"] for tg in prompt_data.get("testGroups", [])}

        for curve_name in ("P-224", "P-256", "P-384", "P-521"):
            curve_ok = True
            n_tests = 0
            limit = MAX_KEYGEN_VECTORS[curve_name]
            for tg in expected_data.get("testGroups", []):
                if tg_curves.get(tg["tgId"]) != curve_name or n_tests >= limit:
                    continue
                for test in tg.get("tests", []):
                    if n_tests >= limit:
                        break
                    d = int(test["d"], 16)
                    exp_qx = int(test["qx"], 16)
                    exp_qy = int(test["qy"], 16)
                    Q_proj = ECDH_Protocol.generate_public_key(d, CURVES[curve_name])
                    qx, qy = PointArithmetic.to_affine(Q_proj, CURVES[curve_name].p)
                    ok = (qx, qy) == (exp_qx, exp_qy)
                    curve_ok &= ok
                    n_tests += 1
            check(f"{curve_name} keyGen ({n_tests}/{limit} örnek vektör, NIST ACVP data/ecdsa-keygen)", curve_ok and n_tests > 0)
            RESULTS[curve_name]["keyGen"] = curve_ok and n_tests > 0


# ══════════════════════════════════════════════════════════════════════════
# 2) ECDSA imzala + doğrula — RFC 6979 (derlenmiş data/p_curves_rfc6979.json)
# ══════════════════════════════════════════════════════════════════════════
def test_sign_verify():
    print("\n=== 2) ECDSA imzala + doğrula (RFC 6979, derlenmiş veri seti) ===")
    path = os.path.join(CURRENT_DIR, "data", "rfc6979", "p_curves_rfc6979.json")
    if not os.path.exists(path):
        print("  (atlandı: data/p_curves_rfc6979.json bulunamadı)")
        return
    with open(path, encoding="utf-8") as f:
        dataset = json.load(f)

    for curve_name, curve in CURVES.items():
        entry = dataset["curves"].get(curve_name, {}).get("ecdsa_sign_verify")
        if not entry:
            check(f"{curve_name} imza/doğrula (veri yok)", False, "(veri seti eksik)")
            RESULTS[curve_name]["imza_dogrula"] = False
            continue

        d = int(entry["d"], 16)
        exp_Ux, exp_Uy = int(entry["Ux"], 16), int(entry["Uy"], 16)
        Q_proj = ECDH_Protocol.generate_public_key(d, curve)
        qx, qy = PointArithmetic.to_affine(Q_proj, curve.p)
        pub_ok = (qx, qy) == (exp_Ux, exp_Uy)
        check(f"{curve_name} açık anahtar (RFC 6979)", pub_ok)

        cases = entry.get("cases", [])
        curve_ok = pub_ok
        if cases:
            for case in cases:
                k = int(case["k"], 16)
                exp_r, exp_s = int(case["r"], 16), int(case["s"], 16)
                msg = case["message"].encode()
                res = ECDSA_Protocol.sign(d, msg, curve, k_nonce=k)
                r, s = res["r_s_tuple"]
                sign_ok = (r, s) == (exp_r, exp_s)
                verify_ok = ECDSA_Protocol.verify((qx, qy), msg, r, s, curve)
                ok = sign_ok and verify_ok
                curve_ok &= ok
                check(f"{curve_name} sign+verify (RFC 6979, msg={case['message']!r})", ok,
                      "" if ok else f"(sign_ok={sign_ok} verify_ok={verify_ok})")
        else:
            # RFC vektörü eksik (bkz. veri setinin kendi notu) — yerel, çapraz
            # kontrollü bir imzala/doğrula turu ile en azından işlevsel doğrulama yapılır.
            k_local = (d * 7 + 12345) % (curve.n - 1) + 1
            res = ECDSA_Protocol.sign(d, b"validate_all_curves-local-check", curve, k_nonce=k_local)
            r, s = res["r_s_tuple"]
            ok = ECDSA_Protocol.verify((qx, qy), b"validate_all_curves-local-check", r, s, curve)
            curve_ok &= ok
            check(f"{curve_name} sign+verify (YEREL çapraz kontrol — RFC vektörü eksik)", ok)

        RESULTS[curve_name]["imza_dogrula"] = curve_ok


# ══════════════════════════════════════════════════════════════════════════
# 3) Straus-Shamir (dual scalar mult) çapraz kontrolü — her eğride
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


def test_straus_shamir():
    print("\n=== 3) Straus-Shamir çapraz kontrolü (eğri başına örnek deneme) ===")
    random.seed(20260729)
    for curve_name, curve in CURVES.items():
        n_trials = STRAUS_SHAMIR_TRIALS[curve_name]
        padd, pmul = _ref_affine_ops(curve.p, curve.a)
        all_ok = True
        for _ in range(n_trials):
            u1 = random.randrange(1, curve.n)
            u2 = random.randrange(1, curve.n)
            qd = random.randrange(1, curve.n)
            Qpub = pmul(qd, (curve.Gx, curve.Gy))
            ref = padd(pmul(u1, (curve.Gx, curve.Gy)), pmul(u2, Qpub))
            got_proj = DualScalarMultiplier.multiply(u1, u2, Qpub, curve)
            got = PointArithmetic.to_affine(got_proj, curve.p)
            if got != ref:
                all_ok = False
                break
        check(f"{curve_name} Straus-Shamir == bağımsız referans ({n_trials} deneme)", all_ok)
        RESULTS[curve_name]["straus_shamir"] = all_ok


# ══════════════════════════════════════════════════════════════════════════
# 4) ÖZET TABLO
# ══════════════════════════════════════════════════════════════════════════
def print_summary_table():
    print("\n" + "=" * 68)
    print("                         ÖZET TABLO")
    print("=" * 68)

    def sym(v):
        if v is None:
            return "  -  "
        return " OK  " if v else "FAIL "

    header = f"{'Eğri':<8} | {'keyGen':^7} | {'İmza/Doğrula':^14} | {'Straus-Shamir':^14} | {'Genel':^6}"
    print(header)
    print("-" * len(header))

    all_pass = True
    for name in CURVES:
        r = RESULTS[name]
        genel = all(v for v in r.values() if v is not None) and all(v is not None for v in r.values())
        all_pass &= genel
        print(f"{name:<8} | {sym(r['keyGen']):^7} | {sym(r['imza_dogrula']):^14} | "
              f"{sym(r['straus_shamir']):^14} | {'BAŞARILI' if genel else 'BAŞARISIZ':^6}")

    print("=" * 68)
    if all_pass:
        print(" SONUÇ: Tüm desteklenen NIST asal eğrilerde (P-192/224/256/384/521)")
        print("        golden model matematiği başarıyla doğrulandı.")
    else:
        print(" SONUÇ: En az bir eğride başarısız test var — yukarıdaki [FAIL]")
        print("        satırlarına bakın.")
    print("=" * 68)
    return all_pass


if __name__ == "__main__":
    test_keygen()
    test_sign_verify()
    test_straus_shamir()
    ok = print_summary_table()
    sys.exit(0 if ok else 1)
