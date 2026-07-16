# 🔐 ECDH Algoritması — Python Altın Model & Verilog RTL Donanım Hızlandırıcısı

**NIST P-256 (secp256r1) tabanlı Eliptic Curve Diffie-Hellman (ECDH) anahtar değişim protokolünün, uçtan uca doğrulanmış Python referans modeli ve sentezlenebilir, sabit-zamanlı (constant-time) FPGA/ASIC RTL donanım implementasyonu.**

Bu depo, **Sakarya Uygulamalı Bilimler Üniversitesi** bünyesinde yürütülen **"Gömülü Sistemler ve Otomasyon Cihazları için FPGA Tabanlı Güvenli Anahtar Yönetimi ve Kripto Hızlandırıcı Tasarımı"** (Proje No: **5260007**) kapsamında geliştirilmektedir. Proje, yazılım seviyesinde davranışsal doğruluğu garanti eden bir **Python Golden Model** ile bu modelle çevrim-doğru (cycle-accurate olmasa da bit-doğru) eşleşen bir **Verilog-2001 RTL çekirdeği**ni bir araya getirir; amaç Artix-7 sınıfı orta seviye FPGA'lerde düşük alan kaplayan, yan-kanal saldırılarına (SPA/DPA/SCA) karşı dayanıklı bir donanım hızlandırıcı üretmektir.

> ⚠️ Kodların hazırlanma sürecinde yapay zekâ destekli araçlardan yararlanılmıştır. Tasarım akademik/araştırma amaçlıdır; üretim ortamında kullanılmadan önce bağımsız bir güvenlik denetiminden geçirilmelidir.

---

## 📚 İçindekiler

1. [Öne Çıkan Özellikler](#-öne-çıkan-özellikler)
2. [Dizin Yapısı](#-dizin-yapısı-project-architecture)
3. [Matematiksel ve Kriptografik Altyapı](#-matematiksel-ve-kriptografik-altyapı)
4. [Python Golden Model](#-python-golden-model)
5. [Verilog RTL Donanım Tasarımı](#-verilog-rtl-donanım-tasarımı)
6. [Kurulum ve Çalıştırma (Quick Start)](#-kurulum-ve-çalıştırma-quick-start)
7. [Bilinen Sınırlamalar](#-bilinen-sınırlamalar--yol-haritası)
8. [Katkıda Bulunma](#-katkıda-bulunma)
9. [Lisans](#-lisans)

---

## ✨ Öne Çıkan Özellikler

| Kategori | Özellik | Açıklama |
|---|---|---|
| 🐍 **Yazılım (Golden Model)** | Katmanlı mimari | `ModularALU → PointArithmetic → ScalarMultiplier → ECDH_Protocol` şeklinde donanım hiyerarşisini birebir yansıtan 4 katmanlı Python tasarımı |
| 🐍 **Yazılım** | Bit-doğru Montgomery çarpımı | `montgomery_multiply_radix2`, FPGA'deki 256 çevrimlik durum makinesini yazılımda **çevrim çevrim** simüle eder |
| 🐍 **Yazılım** | NIST ACVP test altyapısı | `KAS-ECC / CDH-Component` formatında JSON test vektörleriyle (`prompt.json`, `expectedResults.json`) doğrulama |
| 🔧 **Donanım (RTL)** | Modüler ALU (`modular_alu.v`) | Carry-Save Montgomery çarpıcı + iki-aşamalı borrow-select indirgeme; kritik yolu ~yarıya indiren pipeline mimarisi |
| 🔧 **Donanım** | Nokta Aritmetik Birimi (`point_arithmetic_unit.v`) | Jacobian projektif koordinatlarda DBL/ADD; 40+ ara değişken için **Block RAM scratchpad** (FF/LUT tasarrufu) |
| 🔧 **Donanım** | Sabit-Zamanlı Skaler Çarpım | **Montgomery Ladder** + XOR tabanlı koşulsuz **CSWAP** → SPA/DPA yan-kanal saldırılarına karşı mimari koruma |
| 🔧 **Donanım** | Paylaşılan MALU Mimarisi | `ecdh_kex_top`, skaler çarpım ve affine dönüşüm ardışık çalıştığından **tek MALU örneğini** arbitre ederek alan tasarrufu sağlar |
| 🔧 **Donanım** | Affine Dönüşüm (`affine_donusum.v`) | Fermat'ın Küçük Teoremi (`Z^(p-2) mod p`) ile bölmesiz modüler ters alma |
| 🎛️ **Arayüz** | 16-bit/32-bit paket tabanlı I/O | Fiziksel pin sınırlarını aşmak için parçalı (LSB-önce) 256-bit veri aktarım protokolü |
| 🃏 **Doğrulama** | Öz-kontrollü SystemVerilog Testbench'leri | Her modül için bağımsız SV altın-referans modeliyle bit-birebir karşılaştırma (`tb_*.sv`) |
| 🖥️ **Demo** | Nexys A7-100T board demosu | `ecdh_demo_top.v` — buton/LED arayüzü ile canlı donanım üzerinde uçtan uca ECDH gösterimi |
| 🛡️ **Güvenlik** | Watchdog / hata koruması | Her FSM'de sonsuz döngü koruması (`WDOG_MAX`) ve girdi doğrulama (`mod_p == 0`, `Z == 0`, zayıf anahtar vb.) |

---

## 🗂 Dizin Yapısı (Project Architecture)

```text
edch-algorithm-implementation/
│
├── LICENSE                              # MIT + NIST katkı bildirimi
├── README.md                            # Bu belge
│
├── python_kodlar/                       # 🐍 Katman 1-4: Python Golden Model
│   ├── test_runner.py                   # NIST ACVP JSON test koşucusu (bkz. Bilinen Sınırlamalar)
│   ├── data/                            # NIST CAVP/ACVP KAS-ECC test vektörleri
│   │   ├── prompt.json                  #   Girdi test grupları (curve, publicServerX/Y)
│   │   ├── expectedResults.json         #   Beklenen çıktılar (publicIutX/Y, ortak sır z)
│   │   ├── internalProjection.json      #   İç doğrulama izdüşümü (server + iut anahtar çiftleri)
│   │   ├── registration.json            #   Desteklenen fonksiyon/eğri kaydı (dpGen, keyPairGen, ...)
│   │   └── validation.json              #   Referans sonuç doğrulama kayıtları
│   └── src/
│       ├── __init__.py
│       ├── modular_alu.py               # Katman 1: GF(p) ModAdd/ModSub/ModInv + Radix-2 Montgomery Çarpım
│       ├── point_arithmetic.py          # Katman 2: Standart Projektif Koordinatlarda point_add / point_double
│       ├── scalar_mult.py               # Katman 3: Sabit-zamanlı Montgomery Ladder skaler çarpım
│       ├── ecdh_protocol.py             # Katman 4: ECDH protokol arayüzü (generate_public_key / compute_shared_secret)
│       └── utils/
│           └── curve_params.py          # NIST P-256 (secp256r1) eğri sabitleri (p, a, b, Gx, Gy, n)
│
└── verilog_kodlar/                      # 🔧 Sentezlenebilir RTL + Doğrulama Ortamı
    ├── design/                          # RTL Tasarım Dosyaları (Verilog-2001)
    │   ├── modular_alu.v                #   GF(p) ALU: Carry-Save MontMult + pipeline'lı borrow-select indirgeme
    │   ├── point_arithmetic_unit.v      #   Jacobian DBL/ADD birimi (PAU) — BRAM scratchpad tabanlı
    │   ├── scalar_multiplier.v          #   Montgomery Ladder + XOR-CSWAP (SM) — PAU'yu örnekler
    │   ├── affine_donusum.v             #   Jacobian → Affine dönüşüm (Fermat tersleme)
    │   ├── ecdh_kex_top.v               #   Uçtan uca ECDH Anahtar Değişim (KEX) üst denetleyicisi
    │   └── ecdh_demo_top.v              #   Nexys A7-100T board demo sarmalayıcısı (buton/LED + mock TRNG)
    │
    ├── constraint/                      # Xilinx Vivado Kısıt Dosyaları (.xdc)
    │   ├── timing.xdc                   #   Genel saat/zamanlama kısıtı (xc7a50t, ecdh_kex_top hedefi)
    │   └── nexys_a7_ecdh_demo.xdc       #   Nexys A7-100T'ye özgü pin ataması (buton, LED, 100 MHz saat)
    │
    └── simulation/                      # SystemVerilog Öz-Kontrollü Testbench'ler
        ├── tb_modular_alu_csa.sv        #   MALU (Carry-Save) birim testi — rastgele + bilinen vektörler
        ├── tb_modular_alu_dsp.sv        #   DSP48E1 tabanlı alternatif MALU çekirdeği için birim testi
        ├── tb_point_arithmetic_unit.sv  #   PAU birim testi — DBL/ADD, sonsuzluk noktası uç durumları
        ├── tb_affine_donusum.sv         #   Affine dönüşüm birim testi — FLT tersleme doğrulaması
        └── tb_ecdh_kex_top.sv           #   Uçtan uca sistem testi — TRNG mock + tam KEX akışı
```

### Modül Hiyerarşisi (Örnekleme Ağacı)

`ecdh_kex_top`, tasarımın en üst denetleyicisidir ve alt modülleri **tek paylaşılan `modular_alu` örneği** etrafında bir sahiplik arbiteri (`owner_aff`) ile koordine eder:

```text
ecdh_kex_top                    (üst FSM: TRNG → Qa=d·G → Qb al → S=d·Qb)
│
├── modular_alu   [shared_malu] (TEK örnek — SM ve affine_donusum tarafından zaman-paylaşımlı kullanılır)
│
├── scalar_multiplier   [sm_inst]
│   └── point_arithmetic_unit   [pau_inst]
│         └── (mo_*/mi_* master arayüzü ile shared_malu'ya bağlanır — iç örnek YOK)
│
└── affine_donusum      [aff_inst]
      └── (mo_*/mi_* master arayüzü ile shared_malu'ya bağlanır — iç örnek YOK)
```

`ecdh_demo_top`, bu çekirdeği fiziksel Nexys A7-100T kart kaynaklarına (buton, LED, 100 MHz osilatör) bağlayan ve bit-stream'in üretildiği en dış sarmalayıcıdır; içinde demo amaçlı kriptografik olmayan bir LFSR tabanlı sözde-TRNG barındırır.

---

## 🧮 Matematiksel ve Kriptografik Altyapı

Tasarım, NIST P-256 (secp256r1) eğrisi üzerinde çalışır ve aşağıdaki dört matematiksel katmanı hem yazılımda hem donanımda birebir örtüştürür:

**1. GF(p) Asal Alan Aritmetiği — Montgomery Çarpım Matematiği**
Donanımda doğrudan bölme (`mod`) işlemi aşırı alan/yönlendirme karmaşıklığına yol açtığından, çarpımlar **Radix-2 Montgomery Çarpım Algoritması** ile gerçekleştirilir:

```
MM(A, B) = A · B · R⁻¹ mod p         (R = 2²⁵⁶)
```

Sayılar işleme sokulmadan önce `to_montgomery_domain` ile Montgomery uzayına taşınır (`a · R² mod p`), işlem sonunda `from_montgomery_domain` ile normal forma geri döndürülür. RTL tarafında bu, `modular_alu.v` içinde **Carry-Save Adder (CSA)** tabanlı 256 çevrimlik bir döngü olarak; toplama/çıkarma indirgemesi ise elde/borrow zincirini kısaltmak için **iki-aşamalı borrow-select** pipeline olarak uygulanır.

**2. Nokta Toplama / Katlama (Point Addition / Doubling)**
Eğri noktaları **Standart Projektif (Jacobian) Koordinatlarda** `(X, Y, Z)`, `x = X/Z, y = Y/Z` ilişkisiyle temsil edilir; bu sayede her ara adımda pahalı modüler ters alma yerine yalnızca çarpma/toplama kullanılır. `a = −3` özel eğri sabitinden yararlanan optimize edilmiş formüller (`w = 3(X₁−Z₁)(X₁+Z₁)` vb.) hem `point_arithmetic.py` hem `point_arithmetic_unit.v`'de birebir uygulanır.

**3. Skaler Çarpım — Sabit Zamanlı Montgomery Ladder**
`d · P` hesaplaması, zamanlama ve güç analizi tabanlı yan-kanal saldırılarına (**SPA/SCA**) karşı korunmak amacıyla **Montgomery Ladder** algoritmasıyla, skalerin her bitinde **aynı sayıda** nokta toplama + katlama işlemi yaparak gerçekleştirilir. RTL tarafında `scalar_multiplier.v`, merdiven noktaları R0/R1 arasındaki koşullu takasları **XOR tabanlı koşulsuz CSWAP** ile yapar — böylece dallanma (branch) tabanlı sızıntı riski ortadan kalkar.

**4. Affine Dönüşüm — Fermat'ın Küçük Teoremi**
Skaler çarpım sonunda elde edilen projektif nokta, dış dünyaya sunulmadan önce Affine forma çevrilir. Modüler ters alma, donanımda bölücü devre yerine `Z⁻¹ mod p = Z^(p−2) mod p` eşitliğiyle (**Fermat'ın Küçük Teoremi**), 256 adımlık kare-al/çarp (square-and-multiply) döngüsüyle hesaplanır — bu işlem yalnızca protokol başına bir kez (skaler çarpım sonunda) çalıştırılır.

> **Not:** Proje talimatlarında öngörülen çift-PAU'lu paralel Skaler Çarpım (SM) mimarisi ve ECDSA (imza) çekirdekleri bu depodaki mevcut RTL setinde henüz yer almamaktadır — bkz. [Bilinen Sınırlamalar](#-bilinen-sınırlamalar--yol-haritası).

---

## 🐍 Python Golden Model

`python_kodlar/src/` altındaki katmanlı yapı, RTL tasarımının **referans davranış modelini** oluşturur; her Verilog modülünün çıktısı, geliştirme sürecinde bu Python fonksiyonlarının çıktılarıyla bit-bit karşılaştırılarak doğrulanır.

| Dosya | Sorumluluk | Donanımdaki Karşılığı |
|---|---|---|
| `utils/curve_params.py` | `NIST_P256` sınıfı: `p`, `a`, `b`, `Gx`, `Gy`, `n`, `bit_length` sabitleri | `ecdh_kex_top.v` içindeki `P256`, `GX_MONT`, `GY_MONT` `localparam`'ları |
| `modular_alu.py` | `mod_add`, `mod_sub`, `mod_inv` (Fermat), `montgomery_multiply_radix2` (256 çevrim taklidi), `to/from_montgomery_domain` | `modular_alu.v` |
| `point_arithmetic.py` | `point_double`, `point_add` — Jacobian koordinatlarda `a=-3` optimizasyonu | `point_arithmetic_unit.v` |
| `scalar_mult.py` | `ScalarMultiplier.multiply` — sabit-zamanlı Montgomery Ladder (256 iterasyon, MSB→LSB) | `scalar_multiplier.v` |
| `ecdh_protocol.py` | `generate_public_key` (`Q = d·G`), `compute_shared_secret` (`Z = d·Q_peer`) | `ecdh_kex_top.v` (üst seviye KEX akışı) |

### Veri Seti (`python_kodlar/data/`)

JSON dosyaları **NIST ACVP `KAS-ECC` / `CDH-Component`** formatındadır ve CAVP/ACVP eliptik eğri anahtar anlaşması test paketinden alınmıştır:

- `registration.json` — desteklenen fonksiyonlar (`dpGen`, `dpVal`, `keyPairGen`, `fullVal`, `partialVal`, `keyRegen`) ve eğriler (`P-192`, `K-163`, `B-163`).
- `prompt.json` — her test grubu için kullanılan eğri ve karşı taraf açık anahtarı (`publicServerX/Y`).
- `expectedResults.json` — beklenen açık anahtar (`publicIutX/Y`) ve ortak sır (`z`).
- `internalProjection.json` / `validation.json` — iç referans sunucu/IUT anahtar çiftleri ve geçmiş doğrulama sonuçları.

### `test_runner.py` ile Testlerin Koşturulması

`test_runner.py`, `prompt.json` ve `expectedResults.json` dosyalarını dinamik olarak okur, her test grubunun eğrisini (`tgId → curve` eşlemesi) belirler ve **yalnızca asal (prime) alan eğrilerini** (P-224/256/384/521) `ScalarMultiplier.multiply` ile yeniden hesaplayarak beklenen `(Qx, Qy)` değerleriyle **matematiksel tam sayı eşitliği** üzerinden karşılaştırır. İkili (binary) eğriler (`K-*`, `B-*`) desteklenmediğinden atlanır ve özet raporda ayrı sayılır.

```bash
cd python_kodlar
python3 test_runner.py
```

Beklenen çıktı formatı:

```text
=== ECDSA NIST JSON Test Dosyaları Okunuyor ===
[*] Test Grubu ID: 1 | Eğri: P-256 test ediliyor...
=============================================
               TEST ÖZETİ
=============================================
 İşlenen Toplam Prime Eğri Testi : N
 BAŞARILI OLANLAR                : N
 Uyumsuz Diye Atlanan Test Sayısı: M (Binary B/K Serisi)
=============================================
```

> 🔎 Bu betiğin **mevcut haliyle** repodaki modüllerle çalışması için birkaç uyarlama gerekir — ayrıntılar için bkz. [Bilinen Sınırlamalar](#-bilinen-sınırlamalar--yol-haritası).

---

## 🔧 Verilog RTL Donanım Tasarımı

Tüm RTL, **Verilog-2001** standardında, sentezlenebilir (inferred latch üretmeyen), 32-bit LSB-önce paket tabanlı bir I/O protokolüyle tasarlanmıştır. Modüller `SEL_A/SEL_B/SEL_P` gibi seçici sinyallerle çok-parçalı (256-bit → 8×32-bit) veri alışverişi yapar.

### `modular_alu.v` — Modüler Aritmetik Birimi (MALU)

GF(p) üzerinde `ModAdd` / `ModSub` / `MontMult` işlemlerini yürüten temel hesaplama çekirdeği.

- **Carry-Save Montgomery çarpıcı:** Akümülatör redundant `acc_s`/`acc_c` çiftinde tutulur; her iterasyon iki adet 3:2 CSA ile yürütülür → gecikme genişlikten bağımsız (~2-3 LUT derinliği), tam elde-yayma yalnızca döngü sonunda **bir kez** yapılır.
- **Pipeline + borrow-select indirgeme:** 256-bit geniş toplama/çıkarma yolu, `ST_RED_LO` (alt 128-bit) ve `ST_RED_HI` (üst 131-bit) olmak üzere iki ardışık çevrime bölünerek kritik yol ~yarıya indirilir.
- **FSM Durumları:** `ST_IDLE → ST_CALC (256 çevrim) → ST_RED_LO → ST_RED_HI → ST_TX (8 paket)`.
- **Watchdog koruması:** `WDOG_MAX = 300` çevrim aşılırsa `o_err` tetiklenir.

### `point_arithmetic_unit.v` — Nokta Aritmetik Birimi (PAU)

Jacobian projektif koordinatlarda **Nokta Katlama (DBL, 24 adım)** ve **Nokta Toplama (ADD, 24 adım)** işlemlerini, paylaşılan MALU'ya adım adım operand göndererek gerçekleştirir.

- **BRAM Scratchpad:** ~40 adet 256-bit ara değişken (`delta`, `gamma`, `beta`, `U1`, `U2`, `S1`, `S2`, `H`, `R`, ...) dağıtık kayıtçılar yerine tek bir `ara_mem[0:63]` Block RAM'inde tutulur → hem FF hem de dev MUX ağacı (LUT) tasarrufu.
- **Sonsuzluk noktası koruması:** `ST_CHK_INF` durumu, `P1.Z == 0` veya `P2.Z == 0` uç durumlarını doğrudan çıktıya yönlendirir (kısayol).
- **SCA "dummy" adımı:** ADD işleminin 24. adımı (`step_r == 23`), sabit adım sayısını korumak için kasıtlı bir `dummy` işlemdir — zamanlama tabanlı sızıntıyı önler.

### `scalar_multiplier.v` — Skaler Çarpım (SM)

256-bit sabit-zamanlı skaler çarpımı (`d·G` / `d·Q`) yürüten motor.

- **Montgomery Ladder:** Skalerin her bitinde (`d_shift_r[255]`, MSB-önce), R0/R1 çiftleri üzerinde **bir ADD + bir DBL** çalıştırılır — bit değerinden bağımsız sabit işlem sayısı.
- **XOR-CSWAP:** Koşullu takas, `{256{cswap_bit_w}} & (r0 ^ r1)` maskesiyle **dallanmasız** (branchless) gerçekleştirilir; `ST_PRE_CSWAP` (döngü başı) ve `ST_POST_CSWAP` (döngü sonu) olmak üzere iki noktada uygulanır.
- **Mimari not:** R0/R1 merdiven kayıtçıları, tek çevrimde 6 okuma + 6 yazma gerektiren paralel CSWAP erişimi nedeniyle bilinçli olarak flip-flop olarak bırakılmıştır (2-portlu BRAM bu erişim desenini karşılayamaz); BRAM kazancı bunun yerine `point_arithmetic_unit`'in seri erişimli büyük ara değişken bankasında elde edilmiştir.
- Kendi içinde bir `point_arithmetic_unit` (`pau_inst`) örnekler; MALU'ya `mo_*/mi_* master arayüzü` üzerinden (iç örnekleme olmadan) erişir.

### `affine_donusum.v` — Jacobian → Affine Dönüşüm

Skaler çarpım çıktısını `(X, Y, Z)` Jacobian/Montgomery formundan `(x, y)` Affine forma çevirir.

- **Fermat tabanlı ters alma:** `Z⁻¹ mod p = Z^(p−2) mod p`, 256 adımlık kare-al/gerekirse-çarp (`ST_EXP_SQ` / `ST_EXP_MUL`) döngüsüyle hesaplanır (`FERMAT_US = p − 2` sabiti).
- **Paylaşılan MALU:** Bu modül de kendi içinde MALU örneklemez; `ecdh_kex_top` seviyesinde skaler çarpım ile **ardışık (sequential)** çalıştığından tek MALU'yu zaman paylaşımlı kullanır.
- **16 slotluk BRAM scratchpad** (`ara_mem[0:15]`) ile ara değerler (`XJ`, `YJ`, `ZJ`, `ACC`, `ZINV2`, `ZINV3`, `XA`, `YA`) saklanır.

### `ecdh_kex_top.v` — Uçtan Uca ECDH KEX Üst Denetleyicisi

Tüm alt modülleri koordine eden en üst kriptografik çekirdek. Akış:

```
1. i_start → TRNG'den özel anahtar d talep edilir (o_trng_req)
2. Qa = d·G hesaplanır (scalar_multiplier) → Affine'e çevrilir (affine_donusum) → dışarı gönderilir (o_qa_done)
3. Karşı tarafın açık anahtarı Qb, i_pkt_in üzerinden alınır (i_qb_start)
4. Ortak Sır S = d·Qb hesaplanır → Affine'e çevrilir → dışarı gönderilir (o_done)
```

- **Paylaşılan MALU + sahiplik arbiteri:** `owner_aff = (state_r >= K_AF_DMODP)` sinyali, tek `shared_malu` örneğinin girişlerini SM veya `affine_donusum`'a yönlendirir — bu sayede iki ayrı MALU yerine (DSP/LUT tasarrufu sağlayan) tek örnek kullanılır.
- **Zayıf anahtar koruması:** TRNG'den `d == 0` dönerse `RETRY_MAX = 8` denemeye kadar yeniden talep edilir.
- **Hedef cihaz notu:** 115 üst-seviye port ile `xq7a100t-cs324` (≥210 kullanıcı I/O) paketine sığar.

### `ecdh_demo_top.v` — Nexys A7-100T Board Demo Sarmalayıcısı

`ecdh_kex_top` çekirdeğini fiziksel kart kaynaklarına bağlayan, bit-stream'in üretildiği üst modül.

- Buton (`btn_start`) ile debounce'lı başlatma, dahili **32-bit Galois LFSR** ile **yalnızca demo amaçlı** (kriptografik olmayan) sözde-rastgele `d` üretimi.
- Karşı taraf açık anahtarı olarak gömülü sabit `Qb = G` beslenir; LED'ler `busy` / `Qa hazır` / `Ortak Sır hazır` / `hata` durumlarını ve ortak sırrın alt baytını görselleştirir.

### FPGA Kısıtlamaları (`.xdc`)

| Dosya | Hedef Cihaz | Kapsam |
|---|---|---|
| `timing.xdc` | `xc7a50tcpg236-1` (Artix-7) | Genel saat (100 MHz / 10 ns), `set_clock_uncertainty`, `set_false_path` (reset), I/O gecikmeleri, `CFGBVS`/`CONFIG_VOLTAGE` — top modül `ecdh_kex_top` sentez/zamanlama analizi için |
| `nexys_a7_ecdh_demo.xdc` | `xc7a100tcsg324-1` (Nexys A7-100T) | `ecdh_demo_top` için tam pin ataması: 100 MHz osilatör (E3), `btnCpuReset`/`btnC`, 16×LED, kart-genel yapılandırma |

### Simülasyon Ortamı (SystemVerilog Testbench'ler)

Her testbench **öz-kontrollüdür (self-checking)**: harici vektör dosyasına ihtiyaç duymadan, SystemVerilog'un yerel 256/512-bit tam sayı aritmetiğiyle kurulmuş bağımsız bir altın-referans modeli (`modmul`/`modpow`) üretir ve DUT çıktısıyla otomatik karşılaştırır.

| Testbench | DUT | Test Senaryoları |
|---|---|---|
| `tb_modular_alu_csa.sv` | `modular_alu.v` | Bilinen + **rastgele** vektörlerle MontMult; ModAdd/ModSub; `mod_p == 0` hata yolu |
| `tb_modular_alu_dsp.sv` | *(DSP48E1 tabanlı alternatif MALU çekirdeği — bu depoda henüz `design/` altında yok)* | CIOS Montgomery, DSP entegrasyon öncesi imza doğrulama kapısı |
| `tb_point_arithmetic_unit.sv` | `point_arithmetic_unit.v` | `DBL(∞)`, `ADD(∞,G)→G`, `ADD(G,∞)→G`, `DBL(G)→2G`, `ADD(G,2G)→3G` |
| `tb_affine_donusum.sv` | `affine_donusum.v` | Özdeşlik (`Z=Montgomery(1)`), rastgele-Z tersleme (×2), `Z=0` ve `mod_p=0` hata yolları |
| `tb_ecdh_kex_top.sv` | `ecdh_kex_top.v` | Tam KEX akışı (`d=1`), gecikmeli TRNG mock, zayıf-anahtar yeniden-talep, geçersiz `Qb=(0,0)` hata yolu |

> `tb_modular_alu_dsp.sv`, `modular_alu_dsp` adlı DSP48E1 tabanlı bir çekirdeği hedefler; bu modül şu an `verilog_kodlar/design/` altında **bulunmamaktadır** (bkz. Bilinen Sınırlamalar). Diğer tüm testbench'ler mevcut `design/` dosyalarıyla doğrudan çalışacak şekilde hazırlanmıştır.

---

## 🚀 Kurulum ve Çalıştırma (Quick Start)

### Gereksinimler

- **Python** ≥ 3.8 (harici bağımlılık yok — yalnızca standart kütüphane)
- **Xilinx Vivado** (Design Suite ya da ML Edition) — RTL sentezi ve simülasyonu için (Artix-7 desteği ile)

### 1) Python Golden Model Simülasyonunu Çalıştırma

```bash
git clone <bu-repo-url>
cd edch-algorithm-implementation/python_kodlar

# Katmanları doğrudan Python içinden kullanmak için hızlı bir örnek:
python3 - <<'PY'
from src.utils.curve_params import NIST_P256
from src.ecdh_protocol import ECDH_Protocol
from src.modular_alu import ModularALU

curve = NIST_P256()

# Taraf A anahtar çifti
d_a = 0x1234...   # 256-bit özel anahtar (örnek)
Q_a_proj = ECDH_Protocol.generate_public_key(d_a, curve)

# Projektiften Affine'e (Fermat tersleme ile) dönüş
X, Y, Z = Q_a_proj
Z_inv = ModularALU.mod_inv(Z, curve.p)
Qx = (X * Z_inv) % curve.p
Qy = (Y * Z_inv) % curve.p
print(hex(Qx), hex(Qy))
PY
```

Hazır NIST test vektörleriyle toplu doğrulama için:

```bash
python3 test_runner.py
```

### 2) Vivado Projesi Kurulumu, Sentez ve Simülasyon

1. **Yeni proje oluşturun:** Vivado → *Create Project* → *RTL Project* (kaynak dosyaları henüz eklemeden ilerleyin).
2. **Tasarım dosyalarını ekleyin** (`Add Sources → Add or Create Design Sources`):
   ```
   verilog_kodlar/design/modular_alu.v
   verilog_kodlar/design/point_arithmetic_unit.v
   verilog_kodlar/design/scalar_multiplier.v
   verilog_kodlar/design/affine_donusum.v
   verilog_kodlar/design/ecdh_kex_top.v
   verilog_kodlar/design/ecdh_demo_top.v      # yalnızca board bit-stream hedefleniyorsa
   ```
3. **Simülasyon kaynaklarını ekleyin** (`Add Sources → Add or Create Simulation Sources`):
   ```
   verilog_kodlar/simulation/tb_modular_alu_csa.sv
   verilog_kodlar/simulation/tb_point_arithmetic_unit.sv
   verilog_kodlar/simulation/tb_affine_donusum.sv
   verilog_kodlar/simulation/tb_ecdh_kex_top.sv
   ```
4. **Kısıt dosyasını ekleyin** (`Add Sources → Add or Create Constraints`):
   - Yalnızca sentez/zamanlama analizi için → `verilog_kodlar/constraint/timing.xdc`
   - Nexys A7-100T board bit-stream'i için → `verilog_kodlar/constraint/nexys_a7_ecdh_demo.xdc`
5. **Hedef cihazı seçin:**
   - `ecdh_kex_top` (çekirdek, port sayısı nedeniyle) → `xq7a100t-cs324` (≥210 I/O)
   - `ecdh_demo_top` (board demo) → `xc7a100tcsg324-1` (Nexys A7-100T)
6. **Simülasyonu koşturun:** İlgili testbench'i *Top Module* olarak ayarlayıp *Run Simulation → Run Behavioral Simulation* seçin; simülasyon konsoluna her testbench başlığında belirtilen süreyi girin (örn. `tb_ecdh_kex_top.sv` için `run 5ms`, `tb_modular_alu_csa.sv` için `run 300us`).
7. **Sentez ve Implementasyon:** *Run Synthesis → Run Implementation → Generate Bitstream* (yalnızca `ecdh_demo_top` + `nexys_a7_ecdh_demo.xdc` kombinasyonu fiziksel bir Nexys A7-100T'ye programlanabilir bit-stream üretir).

Komut satırından (Tcl) hızlı simülasyon örneği:

```tcl
create_project ecdh_proj ./vivado_proj -part xc7a100tcsg324-1
add_files -norecurse {verilog_kodlar/design/modular_alu.v \
                       verilog_kodlar/design/point_arithmetic_unit.v \
                       verilog_kodlar/design/scalar_multiplier.v \
                       verilog_kodlar/design/affine_donusum.v \
                       verilog_kodlar/design/ecdh_kex_top.v}
add_files -fileset sim_1 -norecurse verilog_kodlar/simulation/tb_ecdh_kex_top.sv
set_property top tb_ecdh_kex_top [get_filesets sim_1]
launch_simulation
run 5ms
```

---

## ⚠️ Bilinen Sınırlamalar & Yol Haritası

Bu README, depodaki kaynak kodun **birebir statik analizine** dayanılarak hazırlanmıştır. Şeffaflık amacıyla, mevcut kod tabanında tespit edilen tutarsızlıklar ve eksik parçalar aşağıda listelenmiştir:

- **`test_runner.py` mevcut `src/` yapısıyla doğrudan çalışmıyor:** Betik, `from src2.scalar_mult import ScalarMultiplier` ve `from ecdsa_protocol import ECDSA_Protocol` gibi bu depoda bulunmayan (`src2` paketi, `ecdsa_protocol.py`) modülleri içe aktarmaya çalışıyor; ayrıca `data/` klasöründeki JSON vektörleri `P-192 / K-163 / B-163` eğrilerini hedefliyorken (`registration.json`), Python golden model ve RTL yalnızca **P-256**'yı destekliyor. Betiği bu depoyla uyumlu hale getirmek için: (a) içe aktarmaları `src.scalar_mult` / `src.ecdh_protocol` olarak güncellemek, (b) `ECDSA_Protocol._projective_to_affine` çağrısını `ModularALU.mod_inv` tabanlı bir Affine dönüşüm yardımcısıyla değiştirmek, (c) P-256 test vektörleri içeren bir NIST ACVP `KAS-ECC` paketi ile `data/` klasörünü değiştirmek/genişletmek gerekir.
- **`tb_modular_alu_dsp.sv`, karşılık gelen `modular_alu_dsp.v` tasarım dosyasını referans alıyor** ancak bu dosya `verilog_kodlar/design/` altında bulunmuyor; mevcut `modular_alu.v` Carry-Save mimarisini kullanıyor (DSP48E1 tabanlı CIOS çekirdeği henüz eklenmemiş).
- **Çift-PAU'lu paralel Skaler Çarpım mimarisi** (proje şartnamesinde belirtilen) henüz uygulanmamıştır; mevcut `scalar_multiplier.v` **tek PAU** ile seri ADD→DBL sırasıyla çalışır.
- **ECDSA çekirdekleri** (imza oluşturma/doğrulama, Straus-Shamir interleaving, nonce güvenliği) bu depoda henüz yer almıyor — yalnızca ECDH akışı mevcut.
- **`ecdh_demo_top.v` içindeki LFSR tabanlı TRNG yalnızca demo amaçlıdır**, kriptografik olarak güvenli değildir; üretim tasarımında gerçek bir entropi kaynağıyla (donanımsal TRNG IP) değiştirilmelidir.

---

## 🤝 Katkıda Bulunma

Katkılarınızı memnuniyetle karşılıyoruz. Lütfen aşağıdaki adımları izleyin:

1. Bu depoyu fork'layın ve özellik/düzeltme için yeni bir dal (`git checkout -b ozellik/harika-fikir`) oluşturun.
2. Verilog kodları için depoda tanımlı **isimlendirme kurallarına** uyun: girişler `g_`/`gir_`, çıkışlar `c_`/`cik_`, yazmaçlar `_r`/`_yaz`, bağlantı hatları `_w`/`_hat`, parametreler `BÜYÜK_HARF`.
3. Her yeni/değiştirilen modül için ilgili `tb_*.sv` testbench'ini güncelleyin ve Python golden model çıktısıyla bit-doğru eşleşmeyi doğrulayın.
4. Değişikliklerinizi net commit mesajlarıyla kaydedip bir Pull Request açın; PR açıklamasında hangi modülün etkilendiğini ve nasıl doğrulandığını belirtin.

---

## 📄 Lisans

Bu proje **MIT Lisansı** ile lisanslanmıştır — ayrıntılar için [LICENSE](LICENSE) dosyasına bakın. Ayrıca NIST tarafından geliştirilen materyaller (eğri parametreleri, test vektörleri) için NIST'in kendi kullanım şartları geçerlidir; bu şartların tam metni `LICENSE` dosyasında yer almaktadır.

---

<p align="center">
  <sub>Sakarya Uygulamalı Bilimler Üniversitesi — Proje No: 5260007<br/>
  Gömülü Sistemler ve Otomasyon Cihazları için FPGA Tabanlı Güvenli Anahtar Yönetimi ve Kripto Hızlandırıcı Tasarımı</sub>
</p>
