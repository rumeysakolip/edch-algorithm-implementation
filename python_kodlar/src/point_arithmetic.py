# src/point_arithmetic.py
from src.modular_alu import ModularALU

class PointArithmetic:
    """
    4. Katman: Eliptik Eğri Nokta Aritmetiği (Standart Projektif Koordinatlar)
    Koordinat Sistemi: x = X/Z, y = Y/Z
    """

    @staticmethod
    def point_double(P1, curve):
        """P1 + P1 = 2*P1 (Standart Projektif Koordinatlar, a=-3)"""
        X1, Y1, Z1 = P1
        p = curve.p
        bit_len = curve.bit_length

        if Z1 == 0:
            return P1

        # NIST Eğrilerinde 'a' sabiti her zaman -3'tür.
        # Matematiksel Formül: w = 3 * X1^2 + a * Z1^2 = 3 * (X1^2 - Z1^2) = 3 * (X1 - Z1) * (X1 + Z1)
        X_minus_Z = ModularALU.mod_sub(X1, Z1, p)
        X_plus_Z = ModularALU.mod_add(X1, Z1, p)
        w_part = ModularALU.montgomery_multiply_radix2(X_minus_Z, X_plus_Z, p, bit_len)
        w = ModularALU.mod_add(w_part, w_part, p)
        w = ModularALU.mod_add(w, w_part, p) # w = 3 * w_part

        # s = Y1 * Z1
        s = ModularALU.montgomery_multiply_radix2(Y1, Z1, p, bit_len)

        # B = X1 * Y1 * s
        Y1_s = ModularALU.montgomery_multiply_radix2(Y1, s, p, bit_len)
        B = ModularALU.montgomery_multiply_radix2(X1, Y1_s, p, bit_len)

        # h = w^2 - 8B
        w_squared = ModularALU.montgomery_multiply_radix2(w, w, p, bit_len)
        two_B = ModularALU.mod_add(B, B, p)
        four_B = ModularALU.mod_add(two_B, two_B, p)
        eight_B = ModularALU.mod_add(four_B, four_B, p)
        h = ModularALU.mod_sub(w_squared, eight_B, p)

        # X3 = 2 * h * s
        h_s = ModularALU.montgomery_multiply_radix2(h, s, p, bit_len)
        X3 = ModularALU.mod_add(h_s, h_s, p)

        # Y3 = w * (4B - h) - 8 * Y1^2 * s^2
        four_B_minus_h = ModularALU.mod_sub(four_B, h, p)
        part1 = ModularALU.montgomery_multiply_radix2(w, four_B_minus_h, p, bit_len)

        Y1_sq = ModularALU.montgomery_multiply_radix2(Y1, Y1, p, bit_len)
        s_sq = ModularALU.montgomery_multiply_radix2(s, s, p, bit_len)
        Y1_sq_s_sq = ModularALU.montgomery_multiply_radix2(Y1_sq, s_sq, p, bit_len)

        eight_Y1_sq_s_sq = ModularALU.mod_add(Y1_sq_s_sq, Y1_sq_s_sq, p)
        eight_Y1_sq_s_sq = ModularALU.mod_add(eight_Y1_sq_s_sq, eight_Y1_sq_s_sq, p)
        eight_Y1_sq_s_sq = ModularALU.mod_add(eight_Y1_sq_s_sq, eight_Y1_sq_s_sq, p)

        Y3 = ModularALU.mod_sub(part1, eight_Y1_sq_s_sq, p)

        # Z3 = 8 * s^3
        s_cubed = ModularALU.montgomery_multiply_radix2(s_sq, s, p, bit_len)
        Z3 = ModularALU.mod_add(s_cubed, s_cubed, p)
        Z3 = ModularALU.mod_add(Z3, Z3, p)
        Z3 = ModularALU.mod_add(Z3, Z3, p)

        return (X3, Y3, Z3)

    @staticmethod
    def point_add(P1, P2, curve):
        """P1 + P2 = P3 (Standart Projektif Koordinatlar)"""
        X1, Y1, Z1 = P1
        X2, Y2, Z2 = P2
        p = curve.p
        bit_len = curve.bit_length

        if Z1 == 0:
            return P2
        if Z2 == 0:
            return P1

        U1 = ModularALU.montgomery_multiply_radix2(Y2, Z1, p, bit_len)
        U2 = ModularALU.montgomery_multiply_radix2(Y1, Z2, p, bit_len)

        V1 = ModularALU.montgomery_multiply_radix2(X2, Z1, p, bit_len)
        V2 = ModularALU.montgomery_multiply_radix2(X1, Z2, p, bit_len)

        u = ModularALU.mod_sub(U1, U2, p)
        v = ModularALU.mod_sub(V1, V2, p)

        if v == 0:
            if u == 0:
                return PointArithmetic.point_double(P1, curve)
            else:
                return (0, 0, 0)

        w = ModularALU.montgomery_multiply_radix2(Z1, Z2, p, bit_len)
        v_squared = ModularALU.montgomery_multiply_radix2(v, v, p, bit_len)
        v_cubed = ModularALU.montgomery_multiply_radix2(v_squared, v, p, bit_len)
        v_squared_V2 = ModularALU.montgomery_multiply_radix2(v_squared, V2, p, bit_len)
        u_squared = ModularALU.montgomery_multiply_radix2(u, u, p, bit_len)
        u_squared_w = ModularALU.montgomery_multiply_radix2(u_squared, w, p, bit_len)

        two_v_squared_V2 = ModularALU.mod_add(v_squared_V2, v_squared_V2, p)
        A = ModularALU.mod_sub(u_squared_w, v_cubed, p)
        A = ModularALU.mod_sub(A, two_v_squared_V2, p)

        X3 = ModularALU.montgomery_multiply_radix2(v, A, p, bit_len)

        v_squared_V2_minus_A = ModularALU.mod_sub(v_squared_V2, A, p)

        part1 = ModularALU.montgomery_multiply_radix2(u, v_squared_V2_minus_A, p, bit_len)
        part2 = ModularALU.montgomery_multiply_radix2(v_cubed, U2, p, bit_len)

        Y3 = ModularALU.mod_sub(part1, part2, p)
        Z3 = ModularALU.montgomery_multiply_radix2(v_cubed, w, p, bit_len)

        return (X3, Y3, Z3)
