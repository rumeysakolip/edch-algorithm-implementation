# ecc — Kullanım Talimatları

## 1. Golden Model (Python)

Gereksinim: Python 3.8+ (harici bağımlılık yoktur, yalnızca standart kütüphane).

Tüm komutlar `python_kodlar/` dizininden çalıştırılır:

```bash
cd python_kodlar
```

### Hızlı doğrulama (P-256 — RTL'in gerçek hedefi)

```bash
python validate_p256.py
```

NIST ACVP keyGen vektörleri, RFC 6979 imzala/doğrula vektörleri, Straus-Shamir çapraz kontrolü, sahtecilik tespiti ve RTL'in varsayılan (LFSR) nonce kaynağıyla uçtan uca turu çalıştırır. ~birkaç saniye sürer.

### Geniş çeşitlilik doğrulaması (tüm desteklenen NIST asal eğrileri)

```bash
python validate_all_curves.py
```

P-192/224/256/384/521'in her birinde keyGen + imzala/doğrula + Straus-Shamir'i çalıştırıp sonunda özet tablo basar. Saf-Python Montgomery çarpıcısı RTL'in çevrim-çevrim davranışını taklit ettiği için (kasıtlı olarak) yavaştır — **~1 dakika** sürebilir, donmuş sanmayın.

### Eski/bireysel test koşucuları

```bash
python test_runner.py     # ECDSA keyGen — P-224/256/384/521 (NIST ACVP data/ecdsa-keygen/)
python nist_wrapper.py    # ECDH (KAS-ECC) — P-192 (NIST ACVP data/kas-ecc-p192/)
```

Her üç betik de aynı `[OK]`/`[FAIL]` çıktı biçimini kullanır.

### Golden model API'sini kendi betiğinizde kullanmak

```python
from src.utils.curve_params import NIST_P256
from src.ecdh_protocol import ECDH_Protocol
from src.ecdsa_protocol import ECDSA_Protocol
from src.point_arithmetic import PointArithmetic

Q_proj = ECDH_Protocol.generate_public_key(d, NIST_P256)
Qx, Qy = PointArithmetic.to_affine(Q_proj, NIST_P256.p)

# RFC 6979 / bilinen bir k ile imzala (test/cross-check için):
res = ECDSA_Protocol.sign(d, b"mesaj", NIST_P256, k_nonce=k)

# RTL'in varsayılan (kriptografik OLMAYAN) LFSR nonce kaynağıyla imzala:
res = ECDSA_Protocol.sign(d, b"mesaj", NIST_P256)

ok = ECDSA_Protocol.verify((Qx, Qy), b"mesaj", *res["r_s_tuple"], NIST_P256)
```

## 1a. Çalışma Anında Eğri Değiştirme (P-192 / P-224) — `parametre_deposu.v`

RTL'in `komut_yoneticisi.v` katmanı 4 yeni UART komutu sunar (bkz. `MIMARI.md` → "Çoklu Eğri Desteği"). Host bir eğri tablosunu yüklemek için sırasıyla:

1. `KOM_EGRI_ALAN_YUKLE` (0x11) — her biri 36 bayt (4 bayt başlık `[3:0]=alan_id` + 32 bayt değer, 8×32-bit sözcük, LSB sözcük önce) olmak üzere **8 kez** gönderilir — alan_id 0..7:
   `0=P, 1=R_MOD_P, 2=GX_MONT, 3=GY_MONT, 4=B_MONT, 5=N_ORDER, 6=MONT_BIR_N, 7=R2N`.
   Bu 8 sabit `MIMARI.md` → "Çoklu Eğri Desteği" bölümündeki P-192/P-224 tablolarından alınabilir; `R = 2^256` kullanılarak hesaplanmıştır.
2. `KOM_EGRI_UZUNLUK_YUKLE` (0x12) — 4 bayt: `{p_bit_uzunluk[19:10], n_bit_uzunluk[9:0]}` (P-192 için ikisi de 192, P-224 için ikisi de 224).
3. `KOM_EGRI_UYGULA` (0x13) — 0 bayt, ACK döner. Bu komuttan SONRA başlatılan işlemler yeni eğriyi kullanır.
4. Geri dönmek için `KOM_EGRI_VARSAYILAN` (0x14) — 0 bayt, P-256 fabrika ayarına döner.

**Önemli protokol kuralı:** `EGRI_UYGULA` gönderilmeden yeni bir ECDH/ECDSA işlemi (`ECDH_BASLAT`, `ANAHTAR_URET`, `IMZALA`, `DOGRULA`) başlatılmamalıdır — donanım bunu ŞU AN engellemiyor (bkz. MIMARI.md'deki bilinen sınırlama), yükleme yarım kalmışken işlem başlatmak eski/karışık sabitlerle çalışmaya yol açar.

**P-384/P-521 desteklenmez** — bu komutlarla yüklenemezler, veri yolu genişliği yetersizdir.

## 2. RTL Simülasyonu (Vivado / XSim)

1. Vivado'da yeni bir proje açın (veya mevcut `.xpr`'ı kullanın), `verilog_kodlar/design/` altındaki tüm `.v` dosyalarını `sources_1` altına ekleyin (top modül: `basys3_top` veya `ecdh_uart_top`), çalıştırmak istediğiniz testbench'i `verilog_kodlar/simulation/` altından `sim_1` altına ekleyin.
2. `verilog_kodlar/simulation/` katmanlı bir test piramidi olarak üç alt dizinde organize edilmiştir — her katman, bir alttakinin YAKALAYAMADIĞI bir hata sınıfını hedefler (alan/endianness uyuşmazlığı, arbiter/orkestrasyon hataları, protokol katmanları arası sızıntı vb.); bu yüzden katmanlar arasında görünen kapsam örtüşmesi kasıtlıdır, gereksiz tekrar değildir:
   - `verilog_kodlar/simulation/birim/` — tek veya iki modülü doğrudan süren birim testleri: `modular_alu_dsp`, `point_arithmetic_unit`, `mod_n_ters`, `nokta_dogrula`, `affine_donusum`, `cift_skaler_carpim`, `ecdsa_imza`, `ecdsa_dogrula`, `anahtar_deposu` (P-192 reddetme-örneklemesi maskelemesi dahil), `nesne_deposu`, `parametre_deposu`, `crc8_hesap`, `senk_fifo`, `uart_baud_uretici`, `uart_rx`, `uart_tx`, `paket_kurucu`, `paket_cozucu`.
   - `verilog_kodlar/simulation/entegrasyon/` — birden fazla modülü veya bir protokol katmanının tamamını birlikte süren testler: `uart_phy_loopback` (tx+rx), `uart_arayuz` (tüm UART zinciri), `paket_kurucu_cozucu` (kurucu↔çözücü gidiş-dönüş — endianness'ın kilitlendiği kritik test), `komut_yoneticisi` (sahte çekirdekle protokol FSM'i), `ecdsa_akis`/`ecdsa_dogrulama_akis` (ECDSA imzalama/doğrulama orkestrasyonu, `ecdh_kex_top` doğrudan), `ecdsa_komut` (aynı akışlar gerçek UART üzerinden), `entegrasyon_dikisi` (simetrik katman arayüzü — Z'nin düz/Montgomery alanı).
   - `verilog_kodlar/simulation/top/` — tam sistem / üst modül testleri: `ecdh_kex_top` (çekirdek FSM, doğrudan), `ecdh_uart_top` (tam sistem, UART üzerinden — `-d TEST_MODU` gerektirir), `cok_egri_entegrasyon` (P-256↔P-192 çalışma anında eğri değiştirme, gerçek UART akışı, `-d TEST_MODU` gerektirir), `negatif_akis` (izin reddi, hayalet hata, Qa korunumu gibi negatif/güvenlik senaryolarının regresyonu).
3. Simülasyonu (`Run Simulation` → `Run Behavioral Simulation`) çalıştırın; testbench'ler kendi içinde `$display`/assertion ile PASS/FAIL raporlar.
4. Testbench çıktısı, ilgili golden model hesabıyla (yukarıdaki Python API) karşılaştırılarak doğrulanmalıdır — bkz. `MIMARI.md` "Golden Model" bölümü.

## 3. Fiziksel Donanımda Test — `python_kodlar/host_capraz_kontrol/`

Bu dizin, kartla gerçek UART üzerinden konuşan ve donanım çıktısını bağımsız bir Python modeliyle karşılaştıran araçları içerir. `python_kodlar/src/`'den BAĞIMSIZ çalışırlar (kendi iç UART/CRC/protokol modellerini kullanırlar).

Ön koşul: kart, `verilog_kodlar/constraint/basys3_ecdh_uart.xdc` + `basys3_top.v` ile sentezlenip programlanmış olmalı ve PC'ye USB/UART üzerinden bağlı olmalıdır.

### 3.1 Kartla uçtan uca test — `ecdh_uart_host.py`

Kart ile gerçek UART üzerinden konuşan tek betik budur; aşağıdaki 3.2'deki diğer araçlar donanım gerektirmeyen saf Python simülasyonlarıdır.

Kurulum:

```bash
pip install pyserial
```

Kullanım:

```bash
python3 ecdh_uart_host.py --liste                    # bağlı seri portları listele
python3 ecdh_uart_host.py --port COM4                 # Windows — tam doğrulama akışı
python3 ecdh_uart_host.py --port /dev/ttyUSB0          # Linux
python3 ecdh_uart_host.py --port COM4 --durum           # yalnızca durum baytını oku
python3 ecdh_uart_host.py --port COM4 --tekrar 100       # akışı 100 kez tekrarla (kararlılık testi)
python3 ecdh_uart_host.py --port COM4 --vektor dosya.json # varsayılan yerine başka bir vektör dosyasıyla çalıştır
```

| Bayrak | Açıklama |
|---|---|
| `--port` | Seri port adı (`COM4`, `/dev/ttyUSB0`). `--liste` dışında zorunludur. |
| `--baud` | Baud hızı, varsayılan `115200` — kartın `uart_baud_uretici.v` parametresiyle eşleşmelidir. |
| `--liste` | Bağlı seri portları listeler ve çıkar. |
| `--durum` | Tam akış yerine yalnızca cihazın durum baytını okur. |
| `--test-modu` | Bitstream `TEST_MODU` ile derlenmişse test-modu komutlarını (örn. bilinen `d` yükleme) kullanır — aşağıdaki uyarıya bakın. |
| `--tekrar N` | Aynı akışı N kez tekrarlar. |
| `--vektor DOSYA` | Varsayılan `ecdh_vektor.json` yerine başka bir vektör dosyası kullanır (bkz. §3.2 `vektor_uret.py`). |
| `-v`, `--ayrintili` | Ayrıntılı (verbose) çıktı. |

⚠️ `--test-modu`, yalnızca `TEST_MODU` tanımıyla derlenmiş bir bitstream'de çalışır. Üretim bitstream'i (TEST_MODU'suz) bu komutları `0xE2` (bilinmeyen komut) ile reddeder — bu beklenen ve istenen davranıştır; gizli anahtarı dışarı okuyan hiçbir komut yoktur.

### 3.2 Donanımsız katman doğrulaması ve vektör üretimi

Aşağıdakiler kart/UART gerektirmez, doğrudan çalıştırılır:

```bash
python3 rtl_capraz_kontrol.py       # UART PHY/CRC/FIFO katmanının çevrim-doğru Python modeli
python3 katman2_capraz_kontrol.py   # paket_kurucu/paket_cozucu katmanının çevrim-doğru Python modeli
python3 vektor_uret.py --tohum 1    # TB'ler ve ecdh_uart_host.py için ortak ECDH vektörünü (ecdh_vektor.json/.hex/.vh) üretir
python3 nokta_vektor_uret.py        # tb_nokta_dogrula.sv için nokta doğrulama vektörlerini üretir
```

`vektor_uret.py` ve `nokta_vektor_uret.py` sabit bir tohum kullanır; her çalıştırmada aynı vektörleri üretirler, böylece TB ve host betiği her zaman aynı dosyayı okur.

## 4. Bilinen Kısıtlar

- ECDSA imzalama nonce kaynağı (LFSR) **kriptografik değildir** — bkz. `MIMARI.md`. Üretim kullanımından önce değiştirilmelidir.
