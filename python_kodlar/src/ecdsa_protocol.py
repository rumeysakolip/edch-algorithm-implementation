# src/ecdsa_protocol.py
"""
ECDSA İmza ve Doğrulama Protokol Katmanı — RTL (ecdsa_imza.v / ecdsa_dogrula.v /
cift_skaler_carpim.v / komut_yoneticisi.v) ile hizalı, TEK KAYNAK sürüm.

Bu dosya eskiden src2/ecdsa_protocol.py idi ve kendi bağımsız (src2/scalar_alu.py
üzerinden "textbook" GF(n) aritmetiği kullanan, iki-ayrı-skaler-çarpım ile
doğrulama yapan) bir yol izliyordu. RTL'in tek paylaşılan MALU/PAU mimarisini
yansıtmak için ECDH ile AYNI src/ paketine taşındı:
  - Nokta aritmetiği: src.point_arithmetic (Jacobian, PAU ile birebir)
  - Skaler çarpım (k*G): src.scalar_mult (Montgomery Ladder, RTL ile birebir)
  - Çift skaler çarpım (u1*G+u2*Q): src.dual_scalar_mult (Straus-Shamir, RTL ile birebir)
  - GF(n) aritmetiği: src.scalar_field (Montgomery-n, RTL ile birebir; ARTIK
    düz Python (a*b)%n DEĞİL)
  - Nonce: src.nonce_lfsr (RTL'nin GERÇEK, kriptografik OLMAYAN LFSR'ı — bkz.
    aşağıdaki "NONCE KAYNAĞI" notu)
"""
import hashlib

from src.scalar_mult import ScalarMultiplier
from src.point_arithmetic import PointArithmetic
from src.dual_scalar_mult import DualScalarMultiplier
from src.scalar_field import ScalarFieldALU
from src.hash_manager import HashManager
from src.nonce_lfsr import RTL_LFSR_TRNG, varsayilan_lfsr


class ECDSA_Protocol:
    """ECDSA İmza ve Doğrulama Protokol Katmanı."""

    # ------------------------------------------------------------------
    # Jacobian -> Affine (PointArithmetic.to_affine'e delege)
    # ------------------------------------------------------------------
    @staticmethod
    def _projective_to_affine(X, Y, Z, p):
        return PointArithmetic.to_affine((X, Y, Z), p)

    @staticmethod
    def _encode_der(r, s):
        """(r, s) tamsayılarını ASN.1 DER formatında hex string'e çevirir."""
        def to_bytes(val):
            hex_str = hex(val)[2:]
            if len(hex_str) % 2 != 0:
                hex_str = '0' + hex_str
            val_bytes = bytes.fromhex(hex_str)
            if val_bytes[0] >= 0x80:
                val_bytes = b'\x00' + val_bytes
            return val_bytes

        r_bytes = to_bytes(r)
        s_bytes = to_bytes(s)
        r_enc = b'\x02' + bytes([len(r_bytes)]) + r_bytes
        s_enc = b'\x02' + bytes([len(s_bytes)]) + s_bytes
        sequence = r_enc + s_enc
        der_bytes = b'\x30' + bytes([len(sequence)]) + sequence
        return der_bytes.hex()

    # ------------------------------------------------------------------
    # NONCE KAYNAĞI
    #   RTL'in şu anki (komut_yoneticisi.v) GERÇEK, kriptografik OLMAYAN
    #   nonce kaynağı varsayılan olarak kullanılır — bu, golden modelin
    #   RTL'i (uyarılan zafiyetiyle birlikte) temsil etmesi kararının bir
    #   sonucudur. k_nonce parametresiyle dışarıdan (örn. RFC 6979 test
    #   vektörleri veya gelecekteki gerçek TRNG modeli) değer enjekte
    #   edilebilir; bu durumda LFSR hiç kullanılmaz.
    # ------------------------------------------------------------------
    @staticmethod
    def sign(private_key_d, message_bytes, curve, k_nonce=None, lfsr=None):
        """
        ECDSA İmza Oluşturma.
          k_nonce verilirse (örn. NIST/RFC 6979 test vektörü, ya da gerçek bir
            TRNG modeli) DOĞRUDAN o kullanılır — LFSR'a hiç dokunulmaz.
          verilmezse RTL'in mevcut varsayılan nonce kaynağı olan LFSR'dan
            (src.nonce_lfsr.RTL_LFSR_TRNG) 256 bit çekilir.
        """
        n = curve.n
        p = curve.p
        bl = curve.bit_length
        kaynak = lfsr if lfsr is not None else varsayilan_lfsr

        e = HashManager.hash_to_int(message_bytes, n)

        r, s = 0, 0
        k = None
        while s == 0:
            while r == 0:
                if k_nonce is not None:
                    k = k_nonce
                else:
                    # RTL: 1 <= k < n olana kadar LFSR'dan yeniden çek
                    # (ecdsa_imza.v yalnızca aralığı denetler; burada denetimi
                    # geçene kadar donanımın TRNG isteğini tekrarladığı varsayılır).
                    k = kaynak.sonraki_256()
                    while not (1 <= k < n):
                        k = kaynak.sonraki_256()

                base_point = (curve.Gx, curve.Gy)
                R_proj = ScalarMultiplier.multiply(k, base_point, curve)
                Rx, Ry = PointArithmetic.to_affine(R_proj, p)
                r = Rx % n

                if k_nonce is not None and r == 0:
                    # Dışarıdan sabit k verildiyse ve r=0 çıkıyorsa bu test
                    # vektörünün kullanılamayacağı anlamına gelir — sonsuz
                    # döngüye girmemek için açıkça hata ver.
                    raise ValueError("Verilen k_nonce ile r=0 elde edildi; bu k test için kullanılamaz.")

            k_inv = ScalarFieldALU.mod_inv(k, n, bl)
            r_d = ScalarFieldALU.mod_mul(r, private_key_d, n, bl)
            e_plus_rd = ScalarFieldALU.mod_add(e, r_d, n)
            s = ScalarFieldALU.mod_mul(k_inv, e_plus_rd, n, bl)

            if k_nonce is not None and s == 0:
                raise ValueError("Verilen k_nonce ile s=0 elde edildi; bu k test için kullanılamaz.")

        der_format = ECDSA_Protocol._encode_der(r, s)
        return {"r_s_tuple": (r, s), "der_hex": der_format, "k_used": k}

    @staticmethod
    def verify(public_key_Q_affine, message_bytes, r, s, curve):
        """ECDSA İmza Doğrulama — cift_skaler_carpim.v (Straus-Shamir) ile hizalı."""
        n = curve.n
        p = curve.p
        bl = curve.bit_length

        if not (1 <= r < n) or not (1 <= s < n):
            return False

        e = HashManager.hash_to_int(message_bytes, n)

        w = ScalarFieldALU.mod_inv(s, n, bl)
        u1 = ScalarFieldALU.mod_mul(e, w, n, bl)
        u2 = ScalarFieldALU.mod_mul(r, w, n, bl)

        R_prime_proj = DualScalarMultiplier.multiply(u1, u2, public_key_Q_affine, curve)

        if R_prime_proj[2] == 0:
            # o_sonsuz — RTL burada da geçersiz imza olarak raporlar.
            return False

        Rx, Ry = PointArithmetic.to_affine(R_prime_proj, p)
        return (Rx % n) == r
