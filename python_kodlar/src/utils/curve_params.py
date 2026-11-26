# src/utils/curve_params.py
"""
NIST asal-alan (GF(p)) eğri parametreleri.

Bu dosyada YALNIZCA bu golden modelin desteklediği (ve RTL ile aynı a=-3
Weierstrass formundaki) asal eğriler bulunur — ikili/Koblitz eğriler (K-*,
B-*) burada YOKTUR, çünkü hiçbir modül (point_arithmetic.py, scalar_mult.py,
vb.) onları desteklemez.

Projenin donanım hedefi yalnızca P-256'dır; diğer eğriler (P-192/224/384/521)
golden modelin JENERİK (curve-parametrized) matematiğini NIST/RFC 6979
kaynaklı vektörlerle geniş çeşitlilikte doğrulamak için burada tutulur
(bkz. validate_all_curves.py).

Tüm sabitler, RFC 6979 Ek A.2.3-A.2.7'deki (IETF, bağımsız yayın) açık
anahtar (Ux, Uy) değerleriyle bu modülün kendi skaler çarpımı çapraz
kontrol edilerek doğrulanmıştır.
"""


class NIST_P192:
    """NIST P-192 (secp192r1)"""
    p = 0xfffffffffffffffffffffffffffffffeffffffffffffffff
    a = p - 3
    b = 0x64210519e59c80e70fa7e9ab72243049feb8deecc146b9b1
    Gx = 0x188da80eb03090f67cbf20eb43a18800f4ff0afd82ff1012
    Gy = 0x07192b95ffc8da78631011ed6b24cdd573f977a11e794811
    n = 0xffffffffffffffffffffffff99def836146bc9b1b4d22831
    bit_length = 192


class NIST_P224:
    """NIST P-224 (secp224r1)"""
    p = 0xffffffffffffffffffffffffffffffff000000000000000000000001
    a = p - 3
    b = 0xb4050a850c04b3abf54132565044b0b7d7bfd8ba270b39432355ffb4
    Gx = 0xb70e0cbd6bb4bf7f321390b94a03c1d356c21122343280d6115c1d21
    Gy = 0xbd376388b5f723fb4c22dfe6cd4375a05a07476444d5819985007e34
    n = 0xffffffffffffffffffffffffffff16a2e0b8f03e13dd29455c5c2a3d
    bit_length = 224


class NIST_P384:
    """NIST P-384 (secp384r1)"""
    p = 0xfffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffeffffffff0000000000000000ffffffff
    a = p - 3
    b = 0xb3312fa7e23ee7e4988e056be3f82d19181d9c6efe8141120314088f5013875ac656398d8a2ed19d2a85c8edd3ec2aef
    Gx = 0xaa87ca22be8b05378eb1c71ef320ad746e1d3b628ba79b9859f741e082542a385502f25dbf55296c3a545e3872760ab7
    # [DOĞRULANDI] RFC 6979 Ek A.2.6 referans imzasıyla çapraz kontrol edildi.
    Gy = 0x3617de4a96262c6f5d9e98bf9292dc29f8f41dbd289a147ce9da3113b5f0b8c00a60b1ce1d7e819d7a431d7c90ea0e5f
    n = 0xffffffffffffffffffffffffffffffffffffffffffffffffc7634d81f4372ddf581a0db248b0a77aecec196accc52973
    bit_length = 384


class NIST_P521:
    """NIST P-521 (secp521r1)"""
    p = 0x01ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff
    a = p - 3
    b = 0x0051953eb9618e1c9a1f929a21a0b68540eea2da725b99b315f3b8b489918ef109e156193951ec7e937b1652c0bd3bb1bf073573df883d2c34f1ef451fd46b503f00
    Gx = 0x00c6858e06b70404e9cd9e3ecb662395b4429c648139053fb521f828af606b4d3dbaa14b5e77efe75928fe1dc127a2ffa8de3348b3c1856a429bf97e7e31c2e5bd66
    Gy = 0x011839296a789a3bc0045c8a5fb42c7d1bd998f54449579b446817afbd17273e662c97ee72995ef42640c550b9013fad0761353c7086a272c24088be94769fd16650
    n = 0x01fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffa51868783bf2f966b7fcc0148f709a5d03bb5c9b8899c47aebb6fb71e91386409
    bit_length = 521


class NIST_P256:
    """NIST P-256 (secp256r1) Eğrisi Parametreleri"""

    # Asal Modül (Prime Field)
    p = 0xFFFFFFFF00000001000000000000000000000000FFFFFFFFFFFFFFFFFFFFFFFF

    # Eğri Denklemi Sabitleri: y^2 = x^3 + ax + b
    a = 0xFFFFFFFF00000001000000000000000000000000FFFFFFFFFFFFFFFFFFFFFFFC
    b = 0x5AC635D8AA3A93E7B3EBBD55769886BC651D06B0CC53B0F63BCE3C3E27D2604B

    # Başlangıç Noktası (Generator Point G)
    Gx = 0x6B17D1F2E12C4247F8BCE6E563A440F277037D812DEB33A0F4A13945D898C296
    Gy = 0x4FE342E2FE1A7F9B8EE7EB4A7C0F9E162BCE33576B315ECECBB6406837BF51F5

    # Eğrinin Mertebesi (Order)
    n = 0xFFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551

    # Bit Uzunluğu
    bit_length = 256
