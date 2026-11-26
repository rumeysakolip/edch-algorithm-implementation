# src/nonce_lfsr.py
"""
komut_yoneticisi.v içindeki "TRNG" bloğunun BİT-BİREBİR yazılım modeli.

*** KRIPTOGRAFIK DEĞİL — RTL'İ TEMSİL ETMEK İÇİNDİR, ÖRNEK ALINMAMALIDIR ***

RTL'in kendi yorumu (komut_yoneticisi.v, satır ~78-82):
    "Dahili LFSR-PRNG KRIPTOGRAFIK DEGILDIR - yalnizca demo icindir.
     Uretimde gercek bir entropi kaynagi (ring-osilator TRNG + saglik testi)
     ile degistirilmelidir. ECDSA'ya gecildiginde nonce icin bu ZORUNLUDUR;
     tekrarlanan nonce ozel anahtari dogrudan ifsa eder."

Bu proje kapsamında golden modelin RTL'i (mevcut haliyle, uyarılan zafiyetle
BİRLİKTE) temsil etmesi istendiği için, ECDSA imzalama nonce'ının (k)
VARSAYILAN kaynağı bu LFSR'dır (bkz. src/ecdsa_protocol.py). Gerçek/güvenli
bir nonce ile test etmek için sign()'a k_nonce parametresi ile dışarıdan
değer verilebilir.

Donanım parametreleri (komut_yoneticisi.v ile birebir):
    LFSR_TOHUM (seed) = 32'hACE1_2345   (parametre; reset değeri)
    LFSR_TAPS         = 32'hA300_0000   (Fibonacci-stili geri besleme)
    sonraki_durum     = (durum >> 1) ^ (durum[0] ? TAPS : 0)

256-bitlik bir değer (d veya k) için 8 ardışık 32-bit LFSR çıktısı istenir
(g_trng_req ile). anahtar_deposu.v / scalar_multiplier.v'nin skaler yükleme
kaydırma kaydedicisiyle AYNI kayıt sırasını izleyerek: İLK gelen 32-bit
sözcük değerin EN AZ ANLAMLI (LSB) sözcüğü, SON gelen sözcük EN ANLAMLI
(MSB) sözcük olur (d_r <= {i_pkt_in, d_r[255:32]} kaydırmalı yükleme deseni).
"""


class RTL_LFSR_TRNG:
    TAPS = 0xA300_0000
    SEED_VARSAYILAN = 0xACE1_2345
    MASK32 = 0xFFFF_FFFF

    def __init__(self, seed=SEED_VARSAYILAN):
        self.durum = seed & self.MASK32

    def reset(self, seed=SEED_VARSAYILAN):
        """g_sifirla_n (reset) darbesiyle eşdeğer: LFSR'ı tohuma geri döndürür."""
        self.durum = seed & self.MASK32

    def sonraki_sozcuk(self):
        """Bir g_trng_req dönemi içindeki tek bir 32-bit çevrimi üretir."""
        cikis = self.durum
        self.durum = (self.durum >> 1) ^ (self.TAPS if (self.durum & 1) else 0)
        return cikis

    def sonraki_256(self):
        """8 ardışık 32-bit sözcük ister (bir g_trng_req/8-çevrim işlemi) ve
        bunları 256-bit bir tamsayıya birleştirir (ilk sözcük = LSB)."""
        deger = 0
        for i in range(8):
            sozcuk = self.sonraki_sozcuk()
            deger |= sozcuk << (32 * i)
        return deger


# Modül seviyesinde TEK bir "donanım" örneği: gerçek RTL'de LFSR reset'ten
# sonra hiç durmadan ilerler (her TRNG isteği bir öncekinin devamıdır). Bu
# örnek, art arda yapılan sign() çağrılarında aynı sürekliliği taklit eder.
varsayilan_lfsr = RTL_LFSR_TRNG()
