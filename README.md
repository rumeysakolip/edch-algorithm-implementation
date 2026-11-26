# edch-algorithm-implementation

FPGA üzerinde çalışmak üzere tasarlanmış **ECDH** (anahtar değişimi) ve **ECDSA** (imzalama / doğrulama) çekirdeği: Python golden model, sentezlenebilir Verilog RTL, testbench'ler ve Digilent **Basys 3** için UART arayüzlü üst modül.

> Depo adı ilk aşamadaki yalnızca-ECDH çalışmadan kalmıştır. Güncel sürüm hem ECDH hem ECDSA içerir ve P-256'nın yanında daha küçük NIST eğrilerini (P-192, P-224) çalışma anında destekler.

**Proje No:** 5260007 — Sakarya Uygulamalı Bilimler Üniversitesi
**Hazırlayan:** Rümeysa Kolip

## Özellikler

- **ECDH** ve **ECDSA** (imzala / doğrula) tek bir paylaşılan aritmetik çekirdek üzerinde: Montgomery modüler çarpıcı (DSP48E1) ve Jacobian koordinatlı nokta aritmetik birimi.
- **Çoklu eğri:** P-256 (varsayılan), P-192 ve P-224. Eğri sabitleri UART komutlarıyla çalışma anında yüklenir, yeniden sentez gerekmez. P-384 ve P-521, 256 bitten uzun oldukları için kapsam dışıdır.
- **Sabit zamanlı** skaler çarpım (Montgomery Ladder), açık anahtar doğrulama (SP 800-56A), `d ∈ [1, n-1]` kontrolü.
- **UART arayüzü:** paketli, CRC-8 korumalı komut protokolü (115200 baud).
- **Golden model:** RTL ile aynı mimariyi izleyen Python modeli; NIST ACVP ve RFC 6979 vektörleriyle doğrulanır.
- **Testbench piramidi:** birim, entegrasyon ve üst modül testleri (SystemVerilog).

## Dizin yapısı

```text
edch-algorithm-implementation/
├── README.md
├── MIMARI.md                 mimari kararlar, çoklu eğri sabitleri, bilinen sınırlamalar
├── KULLANIM.md               golden model, simülasyon, kart testi talimatları
├── LICENSE
├── python_kodlar/            golden model ve host araçları
│   ├── src/                  ECDH, ECDSA, nokta aritmetiği, Montgomery ALU
│   ├── data/                 NIST ACVP ve RFC 6979 test vektörleri
│   ├── vektorler/            TB ve host betiği için ortak ECDH vektörü
│   ├── host_capraz_kontrol/  karta UART ile bağlanan ve çapraz kontrol araçları
│   ├── validate_p256.py      P-256 hızlı doğrulama
│   ├── validate_all_curves.py
│   ├── test_runner.py
│   └── nist_wrapper.py
└── verilog_kodlar/
    ├── design/               sentezlenebilir RTL (üst modül: basys3_top.v)
    ├── simulation/           testbench'ler (birim/, entegrasyon/, top/)
    └── constraint/           Basys 3 kısıt dosyası (basys3_ecdh_uart.xdc)
```

## Hızlı başlangıç

Golden model (yalnızca Python 3.8+ standart kütüphanesi gerekir):

```bash
cd python_kodlar
python validate_p256.py
python validate_all_curves.py
```

`validate_all_curves.py`, kasıtlı olarak çevrim-doğru ve yavaş bir model kullandığı için yaklaşık 1 dakika sürebilir.

RTL simülasyonu için Vivado'da `verilog_kodlar/design/` altındaki tüm `.v` dosyalarını ve seçtiğiniz testbench'i projeye ekleyin. Ayrıntılar [KULLANIM.md](KULLANIM.md) içindedir.

## Basys 3

| | |
|---|---|
| Kart / çip | Digilent Basys 3, Artix-7 XC7A35T (`xc7a35tcpg236-1`) |
| Üst modül | `basys3_top` (içinde `ecdh_uart_top`) |
| Kısıt dosyası | `verilog_kodlar/constraint/basys3_ecdh_uart.xdc` |
| Saat | 100 MHz |
| UART | kart üzerindeki USB-UART köprüsü, 115200 baud |
| Reset | `btnU`, aktif-yüksek (`RESET_AKTIF_DUSUK = 0`) |
| Başlat | `btnC` |
| Hayatta olma göstergesi | `LED15` |

Kartla konuşmak için:

```bash
pip install pyserial
cd python_kodlar/host_capraz_kontrol
python ecdh_uart_host.py --liste
python ecdh_uart_host.py --port COM4
```

## Durum

| Konu | Durum |
|---|---|
| Python golden model, P-256 doğrulaması (`validate_p256.py`) | Geçiyor (16/16) |
| RTL testbench'leri | Depoda mevcut; sonuçlar bu belgede ayrıca listelenmemiştir |
| Basys 3 üzerinde donanım doğrulaması | Devam ediyor |

## Bilinen sınırlamalar

- **ECDSA nonce kaynağı kriptografik değildir.** `komut_yoneticisi.v` içindeki sabit tohumlu 32 bit LFSR yalnızca demo içindir. Gerçek kullanımda ring-osilatör tabanlı TRNG veya RFC 6979 deterministik nonce gerekir. Ayrıntı: [MIMARI.md](MIMARI.md).
- `EGRI_UYGULA` gönderilmeden yeni bir işlem başlatılırsa donanım eski veya karışık eğri sabitleriyle çalışır; bu kural host tarafında uygulanmalıdır.

## Dokümanlar

- [MIMARI.md](MIMARI.md) — mimari, güvenlik kararları, çoklu eğri
- [KULLANIM.md](KULLANIM.md) — çalıştırma, simülasyon, donanım testi

## Lisans

MIT lisansı altındadır. Doğrulama vektörleri NIST'ten alındığı için lisans dosyasının sonundaki NIST bildirimi de geçerlidir. Ayrıntı için [LICENSE](LICENSE) dosyasına bakın.

Kodların hazırlanmasında yapay zekâ kullanılmıştır.
