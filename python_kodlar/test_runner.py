import os
import sys
import json

# ==============================================================================
# 1. YOL VE MODÜL AYARLAMALARI (DİNAMİK PATH)
# ==============================================================================
current_dir = os.path.dirname(os.path.abspath(__file__))

if current_dir not in sys.path:
    sys.path.insert(0, current_dir)

# src/ ve src2/ artık TEK KAYNAĞA (src/) konsolide edildi — RTL'nin tek
# paylaşılan MALU/PAU mimarisini yansıtmak için ECDH ve ECDSA aynı paketi
# kullanıyor (src2/*.py dosyaları geriye dönük uyumluluk için src/'yi yeniden
# dışa aktaran ince "shim" dosyalarına dönüştürüldü). Eski "sys.modules['src']
# = src2" takası KALDIRILDI: src2 shim'leri artık `from src.X import Y`
# yaptığı için bu takas dairesel içe aktarma (circular import) hatası
# üretiyordu.
try:
    from src.scalar_mult import ScalarMultiplier
    from src.ecdsa_protocol import ECDSA_Protocol
except ModuleNotFoundError:
    from scalar_mult import ScalarMultiplier
    from ecdsa_protocol import ECDSA_Protocol

# ==============================================================================
# 2. NIST STANDART ELİPTİK EĞRİ PARAMETRELERİ
# (Bu değerler JSON'da bulunmadığı için evrensel sabit olarak kalmalıdır)
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
    "P-384": Curve(
        name="P-384",
        p=0xfffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffeffffffff0000000000000000ffffffff,
        n=0xffffffffffffffffffffffffffffffffffffffffffffffffc7634d81f4372ddf581a0db248b0a77aecec196accc52973,
        Gx=0xaa87ca22be8b05378eb1c71ef320ad746e1d3b628ba79b9859f741e082542a385502f25dbf55296c3a545e3872760ab7,
        # [DÜZELTİLDİ] Önceki Gy değeri hatalıydı (yanlış hex sabiti) — RFC 6979
        # Ek A.2.6 (NIST P-384) referans imzasıyla çapraz kontrol edilerek
        # doğru NIST/SECG secp384r1 Gy değeriyle değiştirildi. Eski (hatalı)
        # değer P-384 test gruplarının TAMAMININ başarısız görünmesine yol
        # açıyordu; bu Binary/Koblitz eğriler gibi "desteklenmiyor" değil,
        # gerçek bir veri hatasıydı.
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
# 3. ÇIKTI YARDIMCISI — validate_p256.py ile AYNI [OK]/[FAIL] biçimi
# ==============================================================================
def check(name, ok, detail=""):
    if ok:
        print(f"  [OK]   {name}")
    else:
        print(f"  [FAIL] {name}  {detail}")
    return ok


# ==============================================================================
# 4. DİNAMİK JSON YÜKLEYİCİ VE TEST KOŞUCU
# ==============================================================================
def run_tests():
    # JSON dosyalarını dinamik olarak bul
    possible_paths = [
        (os.path.join(current_dir, "data", "ecdsa-keygen", "prompt.json"), os.path.join(current_dir, "data", "ecdsa-keygen", "expectedResults.json")),
        (os.path.join(current_dir, "prompt.json"), os.path.join(current_dir, "expectedResults.json"))
    ]

    prompt_path, expected_path = None, None
    for p_path, e_path in possible_paths:
        if os.path.exists(p_path) and os.path.exists(e_path):
            prompt_path, expected_path = p_path, e_path
            break

    if not prompt_path:
        print("HATA: prompt.json ve expectedResults.json dosyaları bulunamadı!")
        return

    print("=== ECDSA NIST JSON Test Dosyaları Okunuyor ===")
    with open(prompt_path, "r", encoding="utf-8") as f:
        prompt_data = json.load(f)

    with open(expected_path, "r", encoding="utf-8") as f:
        expected_data = json.load(f)

    # tgId -> Curve Eşlemesi (Hangi testin hangi eğride koşulacağını prompt.json'dan çekiyoruz)
    tg_curves = {}
    for tg in prompt_data.get("testGroups", []):
        tg_curves[tg["tgId"]] = tg["curve"]

    total_tests = 0
    passed_tests = 0
    skipped_tests = 0

    print("\n=== NIST ACVP Matematiksel Doğrulama Testleri Başlıyor ===\n")

    for tg in expected_data.get("testGroups", []):
        tg_id = tg["tgId"]
        curve_name = tg_curves.get(tg_id)

        # Sadece bizim donanımımızın desteklediği Asal (Prime) eğrileri seçiyoruz.
        if curve_name not in CURVES:
            skipped_tests += len(tg.get("tests", []))
            continue

        curve = CURVES[curve_name]
        print(f"[*] Test Grubu ID: {tg_id} | Eğri: {curve_name} test ediliyor...")

        tests = tg.get("tests", [])
        for test in tests:
            tc_id = test["tcId"]

            # JSON'dan d, Qx ve Qy değerlerini dinamik olarak çekiyoruz
            # ve doğrudan Integer (tam sayı) tipine dönüştürüyoruz.
            d_int = int(test["d"], 16)
            expected_qx_int = int(test["qx"], 16)
            expected_qy_int = int(test["qy"], 16)

            base_point = (curve.Gx, curve.Gy)

            # --- DONANIM SİMÜLASYONU ---
            Q_proj = ScalarMultiplier.multiply(d_int, base_point, curve)
            calc_qx_int, calc_qy_int = ECDSA_Protocol._projective_to_affine(Q_proj[0], Q_proj[1], Q_proj[2], curve.p)

            total_tests += 1

            # --- STRİNG DEĞİL, DOĞRUDAN MATEMATİKSEL EŞİTLİK KONTROLÜ ---
            # Böylece baştaki 0'lar eksik olsa bile sayının değeri aynı kalacağından hata vermez.
            ok = (calc_qx_int == expected_qx_int and calc_qy_int == expected_qy_int)

            detail = ""
            if not ok:
                # Eğer gerçekten matematiksel bir hata varsa, doğru byte uzunluğunda
                # (baştaki sıfırları tamamlayarak) yazdırırız ki hatayı nerede yaptığımızı görelim.
                byte_len = (curve.bit_length + 7) // 8
                hex_len = byte_len * 2
                detail = (f"(beklenen Qx={expected_qx_int:0{hex_len}X} "
                          f"hesaplanan Qx={calc_qx_int:0{hex_len}X} | "
                          f"beklenen Qy={expected_qy_int:0{hex_len}X} "
                          f"hesaplanan Qy={calc_qy_int:0{hex_len}X})")

            if check(f"keyGen {curve_name} tcId={tc_id}", ok, detail):
                passed_tests += 1

    print("\n" + "="*45)
    print("               TEST ÖZETİ")
    print("="*45)
    print(f" TOPLAM İşlenen Prime Eğri Testi : {total_tests}")
    print(f" BAŞARILI OLANLAR                : {passed_tests}")
    if total_tests > passed_tests:
        print(f" BAŞARISIZ OLANLAR               : {total_tests - passed_tests}")
    print(f" Uyumsuz Diye Atlanan Test Sayısı: {skipped_tests} (Binary B/K Serisi)")
    print("="*45)

if __name__ == '__main__':
    run_tests()
