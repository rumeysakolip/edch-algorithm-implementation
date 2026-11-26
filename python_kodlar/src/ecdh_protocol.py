# src/ecdh_protocol.py
from src.scalar_mult import ScalarMultiplier

class ECDH_Protocol:
    """
    ECDH (Elliptic Curve Diffie-Hellman) Protokol Katmanı.
    Bu katman matematiksel hesap yapmaz, işlemleri ScalarMultiplier'a devreder.
    """

    @staticmethod
    def generate_public_key(private_key_d, curve):
        """
        Kendi özel anahtarımız (d) ile eğrinin Base Point'ini (G) çarpar.
        Sonuç: Kendi Açık Anahtarımız (Q = d * G)
        """
        base_point = (curve.Gx, curve.Gy)

        # 3. Katmana skaler çarpım emri gönder
        public_key_projective = ScalarMultiplier.multiply(private_key_d, base_point, curve)
        return public_key_projective

    @staticmethod
    def compute_shared_secret(private_key_d, peer_public_key_Q, curve):
        """
        Kendi özel anahtarımız (d) ile KARŞI TARAFIN açık anahtarını (Q_peer) çarpar.
        Sonuç: Ortak Sır (Shared Secret: Z = d * Q_peer)
        """
        # Karşı tarafın anahtarı (X, Y) affine formatında gelir, formata uygun z=1 ekleyebiliriz
        # Skaler çarpım çağrısı:
        shared_secret_projective = ScalarMultiplier.multiply(private_key_d, peer_public_key_Q, curve)

        return shared_secret_projective
