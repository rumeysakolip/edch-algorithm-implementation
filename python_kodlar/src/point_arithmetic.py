# src/point_arithmetic.py
from src.modular_alu import ModularALU


class PointArithmetic:
    """
    4. Katman: Eliptik Eğri Nokta Aritmetiği — JACOBIAN KOORDİNATLAR.

    Koordinat Sistemi: x = X/Z^2, y = Y/Z^3   (Standart projektif DEĞİL!)

    ÖNEMLİ: Bu modül, RTL'deki point_arithmetic_unit.v (PAU) ile BİREBİR AYNI
    formülleri kullanır (24 adımlık mikrokod tablosundan çıkarılmıştır):
      - DBL: "dbl-2001-b" (a=-3 için Bernstein/Lange Jacobian ikileme formülü)
      - ADD: "add-2007-bl" ailesi (genel Jacobian toplama formülü)

    Girdi/çıktı değerleri MONTGOMERY UZAYINDADIR (ScalarMultiplier/DualScalarMult
    bu katmanı hep mont-domain X,Y,Z ile çağırır) — ModularALU.mod_add/mod_sub
    doğrusal olduğundan Montgomery kodlamasıyla değişmeli (homomorphic) çalışır,
    montgomery_multiply_radix2 ise iki mont-domain girdiyi çarpıp yine mont-domain
    sonuç üretir. Bu yüzden bu katman "Montgomery mi değil mi" bilmeden çalışır.

    *** RTL DAVRANIŞ EŞLEŞTİRMESİ (KASITLI, "hatalı" GÖRÜNSE DE DOĞRU) ***
    ADD içinde H == U2-U1 == 0 olduğunda (yani X koordinatları eşit), RTL
    HER ZAMAN sonucu sonsuzluk noktası olarak ZORLAR ve o_err bayrağını
    yükseltir — S1==S2 olsa bile (yani gerçek bir P1==P2 ikileme durumu olsa
    bile) RTL bunu double'a yönlendirmez. point_arithmetic_unit.v'nin kendi
    yorumu: "ADD'de H == 0 (P = Q) durumunda ... Z = 0 zorlanır." Bu, ladder
    (R0 ile R1 hep P kadar farklı) ve Straus-Shamir (pratikte neredeyse hiç
    çakışmaz) tasarım varsayımları altında güvenlidir. Golden model, RTL'i
    BİT-BİREBİR temsil etmek için bu davranışı KASITLI OLARAK kopyalar;
    "matematiksel olarak daha doğru" bir double-fallback EKLEMEZ.
    """

    # ------------------------------------------------------------------
    # Jacobian -> Affine dönüşüm (affine_donusum.v'nin yazılım karşılığı)
    # ------------------------------------------------------------------
    @staticmethod
    def to_affine(P, p):
        """(X, Y, Z) Jacobian (standart uzayda) -> (x, y) affine.
        x = X * Z^-2 mod p ,  y = Y * Z^-3 mod p
        Z ters alma işlemi RTL'de affine_donusum.v tarafından Fermat
        (a^(p-2) mod p) ile, MALU üzerinden yapılır — burada da aynı
        şekilde ModularALU.montgomery_pow ile modellenir.
        """
        X, Y, Z = P
        if Z == 0:
            return (0, 0)
        bit_len = p.bit_length()
        # Fermat ile ters alma: Z^-1 mod p  (mod_n_ters.v/affine_donusum.v ile aynı yöntem)
        z_inv = ModularALU.montgomery_pow(Z, p - 2, p, bit_len)
        z_inv2 = (z_inv * z_inv) % p
        z_inv3 = (z_inv2 * z_inv) % p
        x_affine = (X * z_inv2) % p
        y_affine = (Y * z_inv3) % p
        return (x_affine, y_affine)

    # ------------------------------------------------------------------
    # DBL — point_arithmetic_unit.v, i_cmd=0 mikrokodu (adım 0..23)
    # ------------------------------------------------------------------
    @staticmethod
    def point_double(P1, curve):
        """P1 + P1 = 2*P1  (Jacobian, a = -3, "dbl-2001-b")"""
        X1, Y1, Z1 = P1
        p = curve.p
        bl = curve.bit_length

        # RTL: ST_CHK_INF artık koşulsuzdur (SPA düzeltmesi) ama SONUÇ
        # seçimi hâlâ Z1=0 için P1'i aynen döndürür (tx_base_w = A_P1X).
        if Z1 == 0:
            return P1

        mm = lambda a, b: ModularALU.montgomery_multiply_radix2(a, b, p, bl)
        add = lambda a, b: ModularALU.mod_add(a, b, p)
        sub = lambda a, b: ModularALU.mod_sub(a, b, p)

        delta = mm(Z1, Z1)                       # adım 0
        gamma = mm(Y1, Y1)                       # adım 1
        beta = mm(X1, gamma)                     # adım 2
        teksi = sub(X1, delta)                   # adım 3   (X1 - delta)
        tarti = add(X1, delta)                   # adım 4   (X1 + delta)
        mara = mm(teksi, tarti)                  # adım 5
        mara2 = add(mara, mara)                  # adım 6
        w = add(mara2, mara)                     # adım 7   (= 3*mara = alpha)
        alphak = mm(w, w)                        # adım 8   (alpha^2)
        beta2 = add(beta, beta)                  # adım 9
        beta4 = add(beta2, beta2)                # adım 10
        beta8 = add(beta4, beta4)                # adım 11
        X3 = sub(alphak, beta8)                  # adım 12
        yztop = add(Y1, Z1)                      # adım 13
        yzkare = mm(yztop, yztop)                # adım 14
        zt1 = sub(yzkare, gamma)                 # adım 15
        Z3 = sub(zt1, delta)                     # adım 16
        y3t1 = sub(beta4, X3)                    # adım 17
        y3t2 = mm(w, y3t1)                       # adım 18
        gammak = mm(gamma, gamma)                # adım 19
        g2 = add(gammak, gammak)                 # adım 20
        g4 = add(g2, g2)                         # adım 21
        g8 = add(g4, g4)                         # adım 22
        Y3 = sub(y3t2, g8)                       # adım 23

        return (X3, Y3, Z3)

    # ------------------------------------------------------------------
    # ADD — point_arithmetic_unit.v, i_cmd=1 mikrokodu (adım 0..23)
    # ------------------------------------------------------------------
    @staticmethod
    def point_add(P1, P2, curve):
        """P1 + P2 = P3 (Jacobian, genel toplama formülü — "add-2007-bl" ailesi)"""
        X1, Y1, Z1 = P1
        X2, Y2, Z2 = P2
        p = curve.p
        bl = curve.bit_length

        # RTL SABİT-ZAMANLI ÇIKIŞ SEÇİMİ (tx_base_w): hesap her koşulda
        # tam çalışır, yalnızca DÖNÜLEN SONUÇ burada (yazılımda anlık) seçilir.
        if Z1 == 0:
            return P2
        if Z2 == 0:
            return P1

        mm = lambda a, b: ModularALU.montgomery_multiply_radix2(a, b, p, bl)
        add = lambda a, b: ModularALU.mod_add(a, b, p)
        sub = lambda a, b: ModularALU.mod_sub(a, b, p)

        z1k = mm(Z1, Z1)                         # adım 0   Z1^2
        z2k = mm(Z2, Z2)                         # adım 1   Z2^2
        z1kup = mm(z1k, Z1)                      # adım 2   Z1^3
        z2kup = mm(z2k, Z2)                      # adım 3   Z2^3
        u1 = mm(X1, z2k)                         # adım 4
        u2 = mm(X2, z1k)                         # adım 5
        s1 = mm(Y1, z2kup)                       # adım 6
        s2 = mm(Y2, z1kup)                       # adım 7
        h = sub(u2, u1)                          # adım 8
        r_ = sub(s2, s1)                         # adım 9
        h2 = mm(h, h)                            # adım 10
        h3 = mm(h2, h)                           # adım 11
        u1h2 = mm(u1, h2)                        # adım 12
        r2 = mm(r_, r_)                          # adım 13
        u1h2x2 = add(u1h2, u1h2)                 # adım 14
        x3t1 = sub(r2, h3)                       # adım 15
        X3 = sub(x3t1, u1h2x2)                   # adım 16
        y3t1a = sub(u1h2, X3)                    # adım 17
        y3t2a = mm(r_, y3t1a)                    # adım 18
        y3t3a = mm(s1, h3)                       # adım 19
        Y3 = sub(y3t2a, y3t3a)                   # adım 20
        zt1a = mm(h, Z1)                         # adım 21
        Z3 = mm(zt1a, Z2)                        # adım 22
        # adım 23: sahte adım (dummy) — sonuç yazılmaz

        # *** RTL'İN KENDİ SINIRLAMASI: H == 0 HER ZAMAN SONSUZLUĞA ZORLANIR ***
        # (bkz. sınıf docstring'i — gerçek bir double durumunu da kapsar)
        if h == 0:
            return (0, 0, 0)

        return (X3, Y3, Z3)
