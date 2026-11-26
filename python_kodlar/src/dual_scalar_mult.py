# src/dual_scalar_mult.py
from src.modular_alu import ModularALU
from src.point_arithmetic import PointArithmetic


class DualScalarMultiplier:
    """
    Straus-Shamir (interleaved) ÇİFT skaler çarpım: R = u1*G + u2*Q

    RTL karşılığı: cift_skaler_carpim.v — ECDSA doğrulamada kullanılır.
    Algoritma cift_skaler_carpim.v'nin durum makinesiyle BİREBİR eşleşir:

      1. T = G + Q ön hesabı (her koşumda, u1/u2'den bağımsız olarak yapılır)
      2. (u1, u2) bit çiftlerinin EN YÜKSEK sıfır-olmayan biti bulunur; R
         doğrudan G/Q/T ile ilklenir (sonsuzlukla ilklenmez — Jacobian
         sonsuzluk özel durumundan tamamen kaçınmak için RTL'in bilinçli
         tercihi; bkz. modül yorumları).
      3. Kalan bitler için: R = 2R (HER ZAMAN); bit çifti != (0,0) ise
         R = R + (G|Q|T) — bit çiftine göre seçilir: (1,0)->G (0,1)->Q (1,1)->T

    *** BU MODÜL KASITLI OLARAK SABİT-ZAMANLI DEĞİLDİR *** — tıpkı RTL'de
    olduğu gibi. ECDSA doğrulaması yalnızca AÇIK verilerle çalışır (r,s,e,
    u1,u2,Q); burada işlenen hiçbir şey gizli değildir, bu yüzden değişken
    toplama sayısı (bit desenine bağlı) bir güvenlik açığı DEĞİLDİR. Bu
    fonksiyon GİZLİ bir skalerle asla çağrılmamalıdır (cift_skaler_carpim.v
    başlığındaki uyarıyla birebir aynı).
    """

    @staticmethod
    def multiply(u1, u2, Q_affine, curve):
        """
        u1, u2      : tamsayı skalerler (AÇIK veri — bkz. yukarıdaki uyarı)
        Q_affine    : (Qx, Qy) — karşı tarafın (veya doğrulanan imzanın) açık anahtarı
        Dönüş       : (X, Y, Z) Jacobian, STANDART uzayda (Montgomery'den çıkarılmış)
                      Z == 0 ise sonuç sonsuzluk noktasıdır (u1==u2==0 durumu dahil).
        """
        p = curve.p
        bit_length = curve.bit_length
        R = 1 << bit_length
        r2_mod_p = (R * R) % p

        def to_mont(std):
            return ModularALU.to_montgomery_domain(std, r2_mod_p, p, bit_length)

        # ── Sabitleri Montgomery-Jacobian'a taşı (RTL: ST_SABIT_YAZ) ──────
        Gx_m = to_mont(curve.Gx)
        Gy_m = to_mont(curve.Gy)
        Qx_m = to_mont(Q_affine[0])
        Qy_m = to_mont(Q_affine[1])
        one_m = to_mont(1)   # Z = 1 (mont) — G ve Q affine girer, Z=1

        G = (Gx_m, Gy_m, one_m)
        Q = (Qx_m, Qy_m, one_m)

        # ── Ön hesap: T = G + Q (RTL: ST_ON_T) ────────────────────────────
        T = PointArithmetic.point_add(G, Q, curve)

        # RTL: bit_cifti_w = {u2_bit, u1_bit} (u2 üst bit). Anahtar burada
        # (u1_bit, u2_bit) ikilisidir:
        #   (1,0) -> bit_cifti_w=2'b01 -> G     (0,1) -> 2'b10 -> Q     (1,1) -> 2'b11 -> T
        bit_pairs = {
            (1, 0): G,
            (0, 1): Q,
            (1, 1): T,
        }

        # ── En yüksek sıfır-olmayan bit çiftini bul (RTL: ST_TARA) ───────
        highest = None
        for i in range(bit_length - 1, -1, -1):
            b1 = (u1 >> i) & 1
            b2 = (u2 >> i) & 1
            if b1 or b2:
                highest = i
                break

        if highest is None:
            # u1 == 0 ve u2 == 0 -> sonuç tanımı gereği sonsuzluk (RTL: ST_SONSUZ)
            return (0, 0, 0)

        b1 = (u1 >> highest) & 1
        b2 = (u2 >> highest) & 1
        Racc = bit_pairs[(b1, b2)]              # RTL: ST_ILKLE

        # ── Ana döngü (RTL: ST_DBL / ST_ADD) ──────────────────────────────
        for i in range(highest - 1, -1, -1):
            Racc = PointArithmetic.point_double(Racc, curve)          # R = 2R (HER ZAMAN)
            b1 = (u1 >> i) & 1
            b2 = (u2 >> i) & 1
            if b1 or b2:
                Racc = PointArithmetic.point_add(Racc, bit_pairs[(b1, b2)], curve)

        # ── Montgomery uzayından çıkış ─────────────────────────────────────
        X_m, Y_m, Z_m = Racc
        X_std = ModularALU.from_montgomery_domain(X_m, p, bit_length)
        Y_std = ModularALU.from_montgomery_domain(Y_m, p, bit_length)
        Z_std = ModularALU.from_montgomery_domain(Z_m, p, bit_length)
        return (X_std, Y_std, Z_std)
