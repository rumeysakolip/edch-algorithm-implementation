# src/modular_alu.py

class ModularALU:
    """Donanım seviyesindeki modüler aritmetik birimi (ALU) RTL simülasyonu"""

    @staticmethod
    def mod_add(a, b, p):
        """Kombinasyonel Toplayıcı (Combinational Adder) + Koşullu Çıkarıcı"""
        res = a + b
        if res >= p:
            res -= p
        return res

    @staticmethod
    def mod_sub(a, b, p):
        """Kombinasyonel Çıkarıcı (Combinational Subtractor)"""
        res = a - b
        if res < 0:
            res += p
        return res

    @staticmethod
    def mod_inv(a, p):
        """
        Modüler Ters Alma (Modular Inversion). Z^-1 mod p hesaplar.
        Donanımda (FPGA) bölme işlemi alan israfı olduğu için,
        Projektif formdan Affine (Normal) forma dönüş için en sonda
        sadece 1 kere çalıştırılır. (Genelde yazılıma/Host işlemciye bırakılır).
        """
        # Fermat'ın Küçük Teoremi (Fermat's Little Theorem): a^(p-2) mod p = a^-1 mod p
        # Python'ın yerleşik pow fonksiyonu bu devasa üs alma işlemini milisaniyeler içinde yapar.
        return pow(a, p - 2, p)

    @staticmethod
    def montgomery_multiply_radix2(a, b, p, bit_length=256):
        """
        %100 Bit-True Radix-2 Montgomery Çarpıcı (Hardware RTL Modeli)
        FPGA'deki durum makinesini (State Machine) çevrim çevrim taklit eder.
        Hesaplanan değer: (A * B * R^-1) mod p
        """
        R = 0  # FPGA'deki Accumulator (Biriktirici) Register. Başlangıçta 0'dır.

        # FPGA'de bu, bir sayıcı (counter) ile kontrol edilen 256 state'lik bir makinedir.
        for i in range(bit_length):
            # 1. A'nın i. bitini al (Donanımda bu bir Multiplexer veya Shift Register'dır)
            a_i = (a >> i) & 1

            # 2. LSB (En anlamsız bit) Kontrolü (q_i hesaplaması)
            # Amaç: R + a_i*B toplamının P eklenerek veya eklenmeyerek ÇİFT SAYI yapılmasını sağlamak.
            # Çift sayı olmalı ki bir sonraki adımda 2'ye bölerken (sağa kaydırırken) küsurat kaybolmasın.
            # Donanımda bu basit bir XOR (^) ve AND (&) kapısıdır:
            R_0 = R & 1
            b_0 = b & 1
            q_i = R_0 ^ (a_i & b_0)

            # 3. Toplama Aşaması (Carry-Save Adder ağacı taklidi)
            # Eğer a_i 1 ise B'yi ekle, q_i 1 ise P'yi ekle.
            add_b = b if a_i == 1 else 0
            add_p = p if q_i == 1 else 0

            # Donanımda bu 3 girişli (R, add_b, add_p) bir toplayıcıdır.
            R = R + add_b + add_p

            # 4. Donanımsal Sağa Kaydırma (Division by 2)
            # Yukarıdaki q_i mantığı sayesinde R şu an KESİNLİKLE çift sayıdır.
            # Kaydırma işlemi veri kaybı yaşatmaz.
            R = R >> 1

        # Döngü bitiminde (256. çevrimden sonra) R değeri P'den büyükse son bir çıkarma yapılır.
        if R >= p:
            R = R - p

        return R

    # --- DİKKAT: MONTGOMERY UZAYI DÖNÜŞÜMLERİ ---
    # Montgomery çarpımı normal çarpım sonucunu vermez. Sonucu R^-1 (2^-256) ile çarpılmış halidir.
    # Bu yüzden sayıları donanıma sokmadan önce Montgomery Uzayına (Domain) taşımak gerekir.

    @staticmethod
    def to_montgomery_domain(a, r_squared_mod_p, p, bit_length=256):
        """Sayıyı Montgomery uzayına sokar. FPGA'de giriş verisine uygulanır."""
        # a * (R^2 mod p) işlemi sayıyı (a * R mod p) formuna getirir.
        return ModularALU.montgomery_multiply_radix2(a, r_squared_mod_p, p, bit_length)

    @staticmethod
    def from_montgomery_domain(a_mont, p, bit_length=256):
        """Sayıyı normal uzaya geri döndürür. FPGA'in en son çıkışında uygulanır."""
        # a_mont * 1 işlemi sayıyı tekrar standart forma sokar.
        return ModularALU.montgomery_multiply_radix2(a_mont, 1, p, bit_length)
