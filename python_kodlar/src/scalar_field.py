# src/scalar_field.py
from src.modular_alu import ModularALU


class ScalarFieldALU:
    """
    ECDSA imza/doğrulama aritmetiği için GF(n) (skaler alan) katmanı.

    *** ÖNEMLİ — RTL EŞLEŞTİRMESİ ***
    RTL'de GF(n) için AYRI bir çarpan YOKTUR (mod_n_ters.v ve ecdsa_imza.v
    yorumları bunu açıkça belirtir): aynı paylaşılan Montgomery MALU'su,
    modülüsü 'p' yerine 'n' olarak yüklenerek yeniden kullanılır. Bu sınıf
    da aynısını yapar — src.modular_alu.ModularALU'nun Montgomery çarpıcısını
    ve montgomery_pow'unu 'n' modülüsüyle çağırır. ÖNCEKİ sürüm (src2/scalar_alu.py,
    artık kaldırıldı) burada düz Python (a*b)%n / pow(a,n-2,n) kullanıyordu —
    bu, matematiksel olarak doğru ama RTL'in aritmetik YOLUNU hiç temsil
    etmiyordu. Bu sınıf golden modeli RTL ile hizalamak için eklendi.
    """

    @staticmethod
    def mod_add(a, b, n):
        """Kombinasyonel toplayıcı + koşullu çıkarma (n modülünde) — MALU ile aynı devre."""
        return ModularALU.mod_add(a, b, n)

    @staticmethod
    def mod_sub(a, b, n):
        """Kombinasyonel çıkarıcı (n modülünde) — MALU ile aynı devre."""
        return ModularALU.mod_sub(a, b, n)

    @staticmethod
    def mod_mul(a, b, n, bit_length=256):
        """
        a*b mod n — PAYLAŞILAN Montgomery çarpıcı üzerinden (modülüs = n).
        ecdsa_imza.v'nin "2 dönüşüm" optimizasyonuyla aynı yöntem
        (bkz. ModularALU.mod_mul docstring'i).
        """
        return ModularALU.mod_mul(a, b, n, bit_length)

    @staticmethod
    def mod_inv(a, n, bit_length=256):
        """
        a^-1 mod n — mod_n_ters.v ile AYNI yöntem: Fermat (a^(n-2) mod n),
        sabit-yapılı (256 kare + koşullu çarpma) Montgomery üs alma.
        Hem k^-1 (imzalama, GİZLİ) hem s^-1 (doğrulama, AÇIK) için kullanılır
        — RTL'de de aynı mod_n_ters.v örneği ikisi için paylaşılır.
        """
        return ModularALU.montgomery_pow(a, n - 2, n, bit_length)
