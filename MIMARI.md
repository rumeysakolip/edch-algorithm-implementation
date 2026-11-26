# ecc — ECDH / ECDSA Modülü

**Proje No:** 5260007 — Sakarya Uygulamalı Bilimler Üniversitesi

**Hazırlayan:** Rümeysa KOLİP

**Hedef eğri:** NIST P-256 (secp256r1, fabrika/varsayılan) — P-192 ve P-224, `parametre_deposu.v` üzerinden çalışma anında (bitstream değişmeden) yüklenebilir (bkz. "Çoklu Eğri Desteği")

**Hedef platform:** Artix-7 (Digilent Basys3, xc7a35tcpg236-1)

## Kapsam

Bu modül, P-256 eğrisi üzerinde çalışan iki asimetrik protokolü tek bir paylaşılan aritmetik çekirdek üzerinde gerçekleştirir:

- **ECDH** — güvenli oturum anahtarı dağıtımı (`d·G`, `d·Qb`)
- **ECDSA** — imzalama ve doğrulama (Secure Boot / kimlik doğrulama / yazılım güncelleme doğrulaması senaryoları için)

Protokoller UART üzerinden 16-bit paketler halinde çalışan özgün bir komut arayüzüyle sürülür (`komut_yoneticisi.v`).

## Mimari Kararlar

### Paylaşılan Aritmetik Çekirdek

Tasarımın merkezinde **tek bir** Montgomery modüler aritmetik birimi (MALU, `modular_alu_dsp.v`) ve **tek bir** nokta aritmetik birimi (PAU, `point_arithmetic_unit.v`) bulunur. Bu ikisi, ECDH skaler çarpımı, ECDSA imzalama/doğrulama, nokta doğrulama ve modüler ters alma arasında **arbitre edilerek paylaşılır** — ayrı bir GF(n) çarpanı YOKTUR; aynı MALU, yüklenen modülüs `p` veya `n` olacak şekilde yeniden kullanılır. Bu, alan (LUT) tasarrufu için bilinçli bir tercihtir ve golden modelin de birebir yansıttığı bir mimari karardır (bkz. `python_kodlar/src/`).

Tüm RTL kaynakları `verilog_kodlar/design/` altında tek dizindedir. İşlevsel gruplar:

| Katman | RTL Modülü | İşlev |
|---|---|---|
| 1 — Modüler aritmetik | `modular_alu_dsp.v` | DSP48E1 tabanlı CIOS Montgomery çarpıcı; GF(p) ve GF(n) için paylaşılır |
| 2 — Nokta aritmetiği | `point_arithmetic_unit.v` | Jacobian koordinatlarda ADD/DBL (24 adımlık mikrokod) |
| 3 — Skaler çarpım | `scalar_multiplier.v` | Sabit-zamanlı Montgomery Ladder + XOR-CSWAP |
| 3 — Çift skaler çarpım | `cift_skaler_carpim.v` | Straus-Shamir interleaved `u1·G + u2·Q` (yalnızca ECDSA doğrulama, AÇIK veri) |
| — | `mod_n_ters.v` | GF(n) modüler ters alma (Fermat, sabit-zamanlı) |
| — | `nokta_dogrula.v` | SP 800-56A §5.6.2.3.3 açık anahtar doğrulama |
| — | `affine_donusum.v` | Jacobian → Affine dönüşüm |
| — | `ecdsa_imza.v` / `ecdsa_dogrula.v` | ECDSA'nın GF(n) aritmetik yarısı (r,s hesabı / doğrulama) |
| — | `ecdh_kex_top.v` | Üst seviye FSM; anahtar üretimi, ECDH/ECDSA orkestrasyon |
| — | `komut_yoneticisi.v` | UART komut FSM'i, paket protokolü, demo TRNG (LFSR) |
| — | `ecdh_uart_top.v` / `basys3_top.v` | UART entegrasyonu ve Basys3 üst düzey sarmalayıcı |
| — | `anahtar_deposu.v` / `nesne_deposu.v` | Anahtar/nesne (sertifika vb.) depoları |
| — | `parametre_deposu.v` | Eğri sabitlerinin (p, n, G, b) tutulduğu register bankası — bkz. "Çoklu Eğri Desteği" |
| — | `paket_kurucu.v` / `paket_cozucu.v`, `uart_*.v`, `senk_fifo.v`, `crc8_hesap.v` | UART/paket alt yapısı |

### Koordinat Sistemi ve Montgomery Uzayı

Nokta aritmetiği **Jacobian koordinatlarda** (x = X/Z², y = Y/Z³) yürütülür; standart projektif DEĞİLDİR. Tüm GF(p) aritmetiği Montgomery uzayında yapılır (bölme donanımda alan israfı olduğu için elenmiştir). Golden model bu iki noktayı da birebir taklit eder (`python_kodlar/src/point_arithmetic.py`, `python_kodlar/src/modular_alu.py`).

### Sabit Zamanlılık (SPA/SCA Koruması)

- `scalar_multiplier.v`: Montgomery Ladder + XOR-CSWAP — çevrim sayısı ve BRAM adres dizisi gizli bitten tamamen bağımsızdır.
- `point_arithmetic_unit.v`: 24 adımlık nokta toplama/ikiye katlama hesabı koşulsuz çalışır; sonsuz-nokta gibi özel durumlar yalnızca çıkış seçiminde (kombinasyonel mux) ele alınır, hesabın kendisi hiçbir girdiye göre dallanmaz.
- `mod_n_ters.v`: Binary Extended Euclid yerine bilinçli olarak Fermat (sabit üs, n-2) kullanır — Euclid'in iterasyon sayısı operanda bağlı olurdu.
- `cift_skaler_carpim.v` **KASITLI OLARAK sabit-zamanlı DEĞİLDİR** — yalnızca AÇIK verilerle (r, s, e, u1, u2, Q) çalıştığından toplama sayısının bit desenine bağlı olması bir zafiyet oluşturmaz. Bu modül asla gizli bir skalerle çağrılmamalıdır.

### Güvenlik Sertleştirmeleri

`ecdh_kex_top.v` içinde: [SEC-01] karşı tarafın açık anahtarının (Qb) tam eğri doğrulaması, [SEC-02] `d ∈ [1, n-1]` aralık kontrolü + rejection-sampling (SP 800-56A §5.6.1.2 modulo bias'ını önler), [SEC-03] protokol reddi ile donanım hatasını ayıran ayrı hata kodu portu.

### ⚠️ Bilinen Sınırlama — Nonce (k) Kaynağı

`komut_yoneticisi.v` içindeki mevcut TRNG, sabit tohumlu (`LFSR_TOHUM = 32'hACE1_2345`) 32-bit bir LFSR'dır ve RTL yorumlarında **açıkça "KRIPTOGRAFIK DEGIL, yalnızca demo içindir"** diye işaretlenmiştir. Bu, ECDSA imzalama nonce'ı (k) için üretimde **KABUL EDİLEMEZ** — tekrarlanan/tahmin edilebilir k, özel anahtarı doğrudan ifşa eder. Üretime geçişte gerçek bir entropi kaynağı (ring-osilatör TRNG + sağlık testi) veya RFC 6979 deterministik nonce türetimi **ZORUNLUDUR**. Golden model bu durumu gizlemek yerine RTL'i sadakatle temsil etmek için AYNI (zayıf) LFSR'ı varsayılan nonce kaynağı olarak modeller (`python_kodlar/src/nonce_lfsr.py`) — bkz. `KULLANIM.md`.

### Çoklu Eğri Desteği — `parametre_deposu.v`

Eğriye özgü sabitler (p, n, G, b ve bunların Montgomery-uzay karşılıkları) sentez-zamanı `localparam` olarak değil, `parametre_deposu.v` içindeki tek bir merkezi register bankasında tutulur. Bu sabitler UART üzerinden **çalışma anında, bitstream değişmeden** yeniden yüklenebilir.

**Desteklenen eğriler:** P-256 (varsayılan/fabrika ayarı), P-192, P-224 — p ve n bit-uzunluğu 256-bit veri yoluna sığan asal NIST eğrileri. P-384/P-521 kapsam dışıdır — 256 bitten uzun oldukları için veri yolu genişliğinin (BRAM sözcük sayısı, kaydırma yazmaçları, paket protokolü) büyütülmesini gerektirirler.

Reset değerleri P-256 sabitleridir; host hiçbir `EGRI_*` komutu göndermezse davranış her zaman P-256 üzerindendir.

**Mimari:**

| Dosya | Rol |
|---|---|
| `parametre_deposu.v` | p, R_MOD_P (=GZ_MONT=MONT_BIR_p), GX_MONT, GY_MONT, B_MONT, N_ORDER, MONT_BIR_n, R2N ve p/n bit-uzunluklarını tutan register bankası. `N_MINUS_2`=n-2 ve `FERMAT_US`=p-2 burada SAKLANMAZ — tüketen modülde n/p'den anlık türetilir (tutarsız çift yükleme riskini önler). |
| `komut_yoneticisi.v` | parametre_deposu burada örneklenir (nesne_deposu ile aynı sahiplik mantığı). Eğri yükleme/uygulama için 4 UART komutu sunar: `KOM_EGRI_ALAN_YUKLE` (0x11), `KOM_EGRI_UZUNLUK_YUKLE` (0x12), `KOM_EGRI_UYGULA` (0x13), `KOM_EGRI_VARSAYILAN` (0x14) — bkz. `KULLANIM.md`. |
| `ecdh_kex_top.v` | `P256/R_MOD_P/GX_MONT/GY_MONT/GZ_MONT/N_ORDER` isimli `wire`'lar, komut_yoneticisi'nden gelen girişlere bağlıdır. |
| `cift_skaler_carpim.v`, `nokta_dogrula.v`, `affine_donusum.v`, `mod_n_ters.v`, `anahtar_deposu.v`, `ecdsa_imza.v`, `ecdsa_dogrula.v` | Eğri sabitlerini kendi lokal `localparam`'ları yerine `g_*` giriş portlarından alır (ecdh_kex_top.v üzerinden beslenir). |

**Reddetme-örnekleme maskelemesi (P-192/P-224 için kritik):** `anahtar_deposu.v`'deki `U_CMP` durumu, ham TRNG adayını (`aday_r`) `g_n_bit_uzunluk` girişine göre MASKELER (`aday_maskeli_w = aday_r & bit_maske_w`) — üst bitler eğrinin gerçek n bit-uzunluğunun ötesindeyse sıfırlanır. Bu maskeleme olmadan, P-192 (n=192 bit) için 256-bit bir adayın n'den küçük çıkma olasılığı ~2⁻⁶⁴ olur ve sabit `DENEME_MAX=8` yeniden deneme neredeyse her zaman `UH_SKALER` hatasına düşer; maskeleme ile kabul olasılığı P-256'daki gibi ~2⁻³² civarındadır.

MALU'nun kendi Montgomery sabiti (`n0' = -p⁻¹ mod 2^32`, `modular_alu_dsp.v`) çalışma anında Newton-Raphson ile üretilir ve zaten eğriden bağımsızdır.

**Bilinen sınırlama:** `parametre_deposu.v`'nin `c_gecerli` bayrağı, bir alan yüklendiğinde 0'a düşer ve yalnızca `EGRI_UYGULA` gönderildiğinde 1'e döner — ama `ecdh_kex_top.v` bu bayrağı kendi FSM giriş koşullarına bağlamaz. Yani host, `EGRI_UYGULA` göndermeden yeni bir ECDH/ECDSA işlemi başlatırsa donanım mevcut (eski/karışık) sabitlerle çalışır; bu protokol kuralının host tarafında uygulanması gerekir (bkz. `KULLANIM.md` → "Çalışma Anında Eğri Değiştirme").

#### P-192 / P-224 için RTL Sabitleri (`EGRI_ALAN_YUKLE` ile yüklenecek 8 değer)

Aşağıdaki değerler, RTL'in P-256 için hazırladığı ~10 `localparam [255:0]` sabitinin P-192 ve P-224 karşılıkları olarak hesaplanmış ve Python'da bağımsız doğrulanmıştır (`GX_MONT`, `R⁻¹ mod p` ile geri çözülüp `Gx`'e eşit olduğu teyit edilerek). `R = 2^256` (MALU'nun sabit Montgomery yarıçapı, curve'den bağımsız).

**P-192:**

| Sabit | Değer (256-bit hex) |
|---|---|
| P (p) | `0000000000000000fffffffffffffffffffffffffffffffeffffffffffffffff` |
| R_MOD_P / GZ_MONT | `0000000000000000000000000000000100000000000000010000000000000000` |
| GX_MONT | `00000000000000008a4bd3f776d12909a2d97c062701b9ff954cc8f9f3d218f7` |
| GY_MONT | `0000000000000000de22b5248966f05ee53be0ba892fcad66a293d836aeda84d` |
| B_MONT | `00000000000000007281cdb219076ae2d6a2d2cbfea3ebc973c8eec557c0b131` |
| FERMAT_US (p-2) | `0000000000000000fffffffffffffffffffffffffffffffefffffffffffffffd` |
| N_ORDER (n) | `0000000000000000ffffffffffffffffffffffff99def836146bc9b1b4d22831` |
| N_MINUS_2 (n-2) | `0000000000000000ffffffffffffffffffffffff99def836146bc9b1b4d2282f` |
| MONT_BIR (R mod n) | `000000000000000000000000662107c9eb94364e4b2dd7cf0000000000000000` |
| R2N (R² mod n) | `0000000000000000126792c4cef5d8c5d69c6961caaf687f01d1770a83134c27` |

**P-224:**

| Sabit | Değer (256-bit hex) |
|---|---|
| P (p) | `00000000ffffffffffffffffffffffffffffffff000000000000000000000001` |
| R_MOD_P / GZ_MONT | `00000000000000000000000000000000ffffffffffffffffffffffff00000000` |
| GX_MONT | `00000000a21b5e606dd3af9bf96bec05852597366018bfaabc9052266d0a4aea` |
| GY_MONT | `00000000614786f1aea9c5ae03dfe878f8cd672b05335a6b2edca1e5eff3ede8` |
| B_MONT | `000000007fc02f933dceba98c8528151107ac2f3ccf01310e768cdf663c059cd` |
| FERMAT_US (p-2) | `00000000fffffffffffffffffffffffffffffffeffffffffffffffffffffffff` |
| N_ORDER (n) | `00000000ffffffffffffffffffffffffffff16a2e0b8f03e13dd29455c5c2a3d` |
| N_MINUS_2 (n-2) | `00000000ffffffffffffffffffffffffffff16a2e0b8f03e13dd29455c5c2a3b` |
| MONT_BIR (R mod n) | `0000000000000000000000000000e95d1f470fc1ec22d6baa3a3d5c300000000` |
| R2N (R² mod n) | `00000000b1e979616ad15f7cd9714856abc8ff5931d63f4b29947a695f517d15` |

**Not:** Bu tablo yalnızca aritmetik sabitleri kapsar. `anahtar_deposu.v`'nin reddetme-örnekleme genişliği (`DENEME_MAX`) ve TRNG'nin ham çekim genişliği bu sabitlerden bağımsız, yukarıdaki "Reddetme-örnekleme maskelemesi" paragrafında ele alınmıştır.

## Golden Model

`python_kodlar/src/` RTL ile hizalı **tek kaynak**tır (ECDH ve ECDSA aynı Jacobian nokta aritmetiği, aynı Montgomery MALU, aynı Straus-Shamir modülünü paylaşır — RTL'in paylaşılan MALU/PAU mimarisini birebir yansıtır).

Ayrıntılı doğrulama sonuçları ve test komutları için `KULLANIM.md`'ye bakın.
