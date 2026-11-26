import os
import sys
import json

# ==============================================================================
# 1. DİNAMİK YOL VE MODÜL YÖNLENDİRMELERİ (Sadece ECDH Dosyaları İçin)
# ==============================================================================
current_dir = os.path.dirname(os.path.abspath(__file__))

if current_dir not in sys.path:
    sys.path.insert(0, current_dir)

# Betik farklı bir çalışma dizininden çağrılırsa paket importu başarısız
# olabilir; bu durumda düz (paketsiz) importa düşülür.
try:
    from src.ecdh_protocol import ECDH_Protocol
    from src.modular_alu import ModularALU
except ModuleNotFoundError:
    from ecdh_protocol import ECDH_Protocol
    from modular_alu import ModularALU

# ==============================================================================
# 2. NIST STANDART ELİPTİK EĞRİ PARAMETRELERİ
# ==============================================================================
class Curve:
    def __init__(self, name, p, n, Gx, Gy, bit_length):
        self.name = name
        self.p = p
        self.n = n
        self.Gx = Gx
        self.Gy = Gy
        self.bit_length = bit_length

CURVES = {
    "P-192": Curve(
        name="P-192",
        p=0xfffffffffffffffffffffffffffffffeffffffffffffffff,
        n=0xffffffffffffffffffffffff99def836146bc9b1b4d22831,
        Gx=0x188da80eb03090f67cbf20eb43a18800f4ff0afd82ff1012,
        Gy=0x07192b95ffc8da78631011ed6b24cdd573f977a11e794811,
        bit_length=192
    ),
    "P-224": Curve(
        name="P-224",
        p=0xffffffffffffffffffffffffffffffff000000000000000000000001,
        n=0xffffffffffffffffffffffffffff16a2e0b8f03e13dd29455c5c2a3d,
        Gx=0xb70e0cbd6bb4bf7f321390b94a03c1d356c21122343280d6115c1d21,
        Gy=0xbd376388b5f723fb4c22dfe6cd4375a05a07476444d5819985007e34,
        bit_length=224
    ),
    "P-256": Curve(
        name="P-256",
        p=0xffffffff00000001000000000000000000000000ffffffffffffffffffffffff,
        n=0xffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551,
        Gx=0x6b17d1f2e12c4247f8bce6e563a440f277037d812deb33a0f4a13945d898c296,
        Gy=0x4fe342e2fe1a7f9b8ee7eb4a7c0f9e162bce33576b315ececbb6406837bf51f5,
        bit_length=256
    ),
    "P-384": Curve( # Doğru P-384 Asalı
        name="P-384",
        p=0xfffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffeffffffff0000000000000000ffffffff,
        n=0xffffffffffffffffffffffffffffffffffffffffffffffffc7634d81f4372ddf581a0db248b0a77aecec196accc52973,
        Gx=0xaa87ca22be8b05378eb1c71ef320ad746e1d3b628ba79b9859f741e082542a385502f25dbf55296c3a545e3872760ab7,
        # [DÜZELTİLDİ] bkz. test_runner.py'deki aynı düzeltme notu — eski Gy
        # hatalıydı, RFC 6979 Ek A.2.6 referansıyla doğrulanan değerle değiştirildi.
        Gy=0x3617de4a96262c6f5d9e98bf9292dc29f8f41dbd289a147ce9da3113b5f0b8c00a60b1ce1d7e819d7a431d7c90ea0e5f,
        bit_length=384
    ),
    "P-521": Curve(
        name="P-521",
        p=0x01ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff,
        n=0x01fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffa51868783bf2f966b7fcc0148f709a5d03bb5c9b8899c47aebb6fb71e91386409,
        Gx=0x00c6858e06b70404e9cd9e3ecb662395b4429c648139053fb521f828af606b4d3dbaa14b5e77efe75928fe1dc127a2ffa8de3348b3c1856a429bf97e7e31c2e5bd66,
        Gy=0x011839296a789a3bc0045c8a5fb42c7d1bd998f54449579b446817afbd17273e662c97ee72995ef42640c550b9013fad0761353c7086a272c24088be94769fd16650,
        bit_length=521
    )
}

# ==============================================================================
# 3. YARDIMCI FONKSİYON: PROJEKTİF -> AFFINE ÇEVİRİCİ
# (NIST testleri sonucu x,y olarak bekler, donanımınız X,Y,Z üretir)
# ==============================================================================
def projective_to_affine(X, Y, Z, p):
    """
    JACOBIAN -> Affine (x = X/Z^2, y = Y/Z^3).
    [GÜNCELLENDİ] Önceki sürüm standart projektif (x=X/Z, y=Y/Z) varsayıyordu;
    golden model artık RTL'nin point_arithmetic_unit.v'sinin gerçekte
    kullandığı Jacobian koordinatlara hizalandığı için (bkz. src/point_arithmetic.py)
    bu yardımcı fonksiyon da güncellendi. PointArithmetic.to_affine ile aynı mantık.
    """
    if Z == 0:
        return (0, 0)
    z_inv = ModularALU.mod_inv(Z, p)
    z_inv2 = (z_inv * z_inv) % p
    z_inv3 = (z_inv2 * z_inv) % p
    x_affine = (X * z_inv2) % p
    y_affine = (Y * z_inv3) % p
    return (x_affine, y_affine)

# ==============================================================================
# 4. ÇIKTI YARDIMCISI — validate_p256.py / test_runner.py ile AYNI [OK]/[FAIL] biçimi
# ==============================================================================
def check(name, ok, detail=""):
    if ok:
        print(f"  [OK]   {name}")
    else:
        print(f"  [FAIL] {name}  {detail}")
    return ok


# ==============================================================================
# 5. DİNAMİK JSON YÜKLEYİCİ VE TEST KOŞUCU (SADECE ECDH)
# ==============================================================================
def run_ecdh_tests():
    # ACVP NIST testlerinde ECDH (KAS-ECC) için anahtarlar genelde internalProjection.json
    # veya expectedResults.json içinde bulunur. Hangisi varsa dinamik okur.
    search_folders = [os.path.join("data", "kas-ecc-p192"), "."]
    target_path = None

    for folder in search_folders:
        path1 = os.path.join(current_dir, folder, "internalProjection.json")
        path2 = os.path.join(current_dir, folder, "expectedResults.json")
        if os.path.exists(path1):
            target_path = path1
            break
        elif os.path.exists(path2):
            target_path = path2
            break

    if not target_path:
        print("HATA: ECDH test verilerini içeren JSON dosyası (internalProjection/expectedResults) bulunamadı!")
        return

    print(f"=== ECDH NIST JSON Test Dosyası Okunuyor: {os.path.basename(target_path)} ===")
    with open(target_path, "r", encoding="utf-8") as f:
        data = json.load(f)

    # Prompt'tan (eğer varsa) eğri bilgisini çek (TestGroups eşleştirmesi)
    curve_mapping = {}
    for folder in search_folders:
        prompt_path = os.path.join(current_dir, folder, "prompt.json")
        if os.path.exists(prompt_path):
            with open(prompt_path, "r", encoding="utf-8") as pf:
                p_data = json.load(pf)
                for ptg in p_data.get("testGroups", []):
                    curve_mapping[ptg["tgId"]] = ptg.get("curve")
            break

    total_tests = 0
    passed_tests = 0
    skipped_tests = 0

    print("\n=== NIST ACVP KAS-ECC (ECDH) Matematiksel Doğrulama Testleri Başlıyor ===\n")

    for tg in data.get("testGroups", []):
        tg_id = tg.get("tgId")

        # Eğri adını öncelikle grubun kendisinden, yoksa prompt dosyasındaki haritadan al
        curve_name = tg.get("curve") or curve_mapping.get(tg_id)

        # Sadece desteklediğimiz Prime (P) serisi eğrileri test et
        if curve_name not in CURVES:
            skipped_tests += len(tg.get("tests", []))
            continue

        curve = CURVES[curve_name]
        print(f"[*] Test Grubu ID: {tg_id} | Eğri: {curve_name} test ediliyor...")

        tests = tg.get("tests", [])
        for test in tests:
            tc_id = test.get("tcId")

            # JSON dosyasında eksik/farklı adlandırılmış veri varsa atla (örn ECDH olmayan AFT grubuysa)
            if "privateIut" not in test or "publicServerX" not in test or "z" not in test:
                continue

            # Verileri JSON'dan çek ve DOĞRUDAN INT'E ÇEVİR (Sıfır kaybı hatasını önler)
            d_iut = int(test["privateIut"], 16)               # Bizim private key'imiz (d)
            server_qx = int(test["publicServerX"], 16)        # Karşı tarafın Public Key X'i
            server_qy = int(test["publicServerY"], 16)        # Karşı tarafın Public Key Y'si

            expected_iut_qx = int(test["publicIutX"], 16)     # Bizim Public Key'imizin X'i (beklenen)
            expected_iut_qy = int(test["publicIutY"], 16)     # Bizim Public Key'imizin Y'si (beklenen)
            expected_z = int(test["z"], 16)                   # Ortak Sırrın (Shared Secret) X koordinatı (beklenen)

            total_tests += 1

            # ------------------------------------------------------------------
            # 1. Kendi Açık Anahtarımızı (Public Key) Hesaplayalım
            # ------------------------------------------------------------------
            Q_proj = ECDH_Protocol.generate_public_key(d_iut, curve)
            calc_iut_qx, calc_iut_qy = projective_to_affine(*Q_proj, curve.p)

            pub_ok = (calc_iut_qx == expected_iut_qx) and (calc_iut_qy == expected_iut_qy)

            # ------------------------------------------------------------------
            # 2. Ortak Sırrı (Shared Secret - Z) Hesaplayalım
            # ------------------------------------------------------------------
            peer_public_key = (server_qx, server_qy)
            Z_proj = ECDH_Protocol.compute_shared_secret(d_iut, peer_public_key, curve)
            calc_z, _ = projective_to_affine(*Z_proj, curve.p)

            secret_ok = (calc_z == expected_z)

            # ------------------------------------------------------------------
            # Eşitlik Kontrolü ve Çıktı — validate_p256.py / test_runner.py ile AYNI biçim
            # ------------------------------------------------------------------
            ok = pub_ok and secret_ok
            detail = ""
            if not ok:
                byte_len = (curve.bit_length + 7) // 8
                hex_len = byte_len * 2
                parts = []
                if not pub_ok:
                    parts.append(f"Q: beklenen Qx={expected_iut_qx:0{hex_len}X} "
                                  f"hesaplanan Qx={calc_iut_qx:0{hex_len}X}")
                if not secret_ok:
                    parts.append(f"z: beklenen={expected_z:0{hex_len}X} "
                                  f"hesaplanan={calc_z:0{hex_len}X}")
                detail = "(" + " | ".join(parts) + ")"

            if check(f"ECDH {curve_name} tcId={tc_id} (Q + paylaşılan sır)", ok, detail):
                passed_tests += 1

    print("\n" + "="*50)
    print("               ECDH TEST ÖZETİ")
    print("="*50)
    print(f" TOPLAM İşlenen KAS-ECC Testi      : {total_tests}")
    print(f" BAŞARILI OLANLAR                  : {passed_tests}")
    if total_tests > passed_tests:
        print(f" BAŞARISIZ OLANLAR                 : {total_tests - passed_tests}")
    print(f" Uyumsuz Eğri Nedeniyle Atlananlar : {skipped_tests} (Binary/Koblitz vb.)")
    print("="*50)

if __name__ == '__main__':
    run_ecdh_tests()
