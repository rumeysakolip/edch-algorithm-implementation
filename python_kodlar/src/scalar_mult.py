# src/scalar_mult.py
from src.modular_alu import ModularALU
from src.point_arithmetic import PointArithmetic

class ScalarMultiplier:
    """
    3. Katman: Skaler Çarpım (Montgomery Ladder)
    Donanımın SPA/DPA saldırılarına karşı korumalı ana motoru.
    """

    @staticmethod
    def multiply(d, base_point, curve):
        p = curve.p
        bit_length = curve.bit_length # DİNAMİK: P-192 ise 192, P-256 ise 256 olur

        # FPGA'de donanıma gömülü olan (Hardcoded) R^2 mod P sabiti hesaplaması
        R = 1 << bit_length
        R2_mod_p = (R * R) % p

        # 1. ADIM: MONTGOMERY UZAYINA GİRİŞ (DOMAIN CONVERSION)
        Px_std, Py_std = base_point
        Px_mont = ModularALU.to_montgomery_domain(Px_std, R2_mod_p, p, bit_length)
        Py_mont = ModularALU.to_montgomery_domain(Py_std, R2_mod_p, p, bit_length)

        Z1_std = 1
        Z1_mont = ModularALU.to_montgomery_domain(Z1_std, R2_mod_p, p, bit_length)

        R0 = (0, 0, 0) # Sonsuzluk noktası
        R1 = (Px_mont, Py_mont, Z1_mont)

        # 2. ADIM: CONSTANT-TIME MONTGOMERY LADDER
        for i in range(bit_length - 1, -1, -1):
            d_i = (d >> i) & 1

            if d_i == 0:
                R1 = PointArithmetic.point_add(R0, R1, curve)
                R0 = PointArithmetic.point_double(R0, curve)
            else:
                R0 = PointArithmetic.point_add(R0, R1, curve)
                R1 = PointArithmetic.point_double(R1, curve)

        # 3. ADIM: MONTGOMERY UZAYINDAN ÇIKIŞ (NORMALİZASYON)
        X_mont, Y_mont, Z_mont = R0

        X_std = ModularALU.from_montgomery_domain(X_mont, p, bit_length)
        Y_std = ModularALU.from_montgomery_domain(Y_mont, p, bit_length)
        Z_std = ModularALU.from_montgomery_domain(Z_mont, p, bit_length)

        return (X_std, Y_std, Z_std)
