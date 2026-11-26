# src/hash_manager.py
import hashlib


class HashManager:
    """Mesaj özetleme ve tamsayıya dönüştürme donanımının simülasyonu.

    Not: RTL, hash'i host tarafında hazırlanmış bir alan (i_hash_pkt) olarak
    alır; bu sınıf yalnızca host-tarafı SHA-256 + NIST kırpma kuralını
    modeller (curve/RTL bağımsızdır, bu yüzden src/src2 arasında farklılaşmaz).
    """

    @staticmethod
    def hash_to_int(message_bytes, curve_n):
        """
        Mesajı SHA-256 ile özetler ve eğri sırasına (n) göre tamsayıya çevirir.
        P-256 ve SHA-256'nın ikisi de 256 bit olduğu için kırpma (truncation) genelde gerekmez
        ancak NIST standartlarına tam uyum için bit uzunluğu kontrolü eklenmiştir.
        """
        h_bytes = hashlib.sha256(message_bytes).digest()
        h_int = int.from_bytes(h_bytes, byteorder='big')

        n_bit_len = curve_n.bit_length()
        h_bit_len = len(h_bytes) * 8

        if h_bit_len > n_bit_len:
            h_int >>= (h_bit_len - n_bit_len)

        return h_int
