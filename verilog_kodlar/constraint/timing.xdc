## =============================================================================
## Dosya   : timing.xdc
## Proje   : FPGA Tabanlı Güvenli Anahtar Yönetimi ve Kripto Hızlandırıcı (5260007)
## Hedef   : xc7a50tcpg236-1 (Artix-7)
## Amaç    : Saat kısıtı + temel I/O gecikmeleri + kart-genel ayarlar.
##           Bu kısıt dosyası, güç (power) ve sıcaklık (junction temp) tahmininin
##           gerçekçi olması için ZORUNLU olan saat frekansını tanımlar.
## -----------------------------------------------------------------------------
## Uyum    : Top modül ecdh_controller VEYA ecdh_kex_top olabilir; port isimleri
##           all_inputs/all_outputs ile filtrelendiği için her ikisinde de çalışır.
## Not     : Fiziksel pin atamaları (PACKAGE_PIN) karta özgüdür; bu dosyada yer
##           almaz. Gerçek bir karta yerleştirme yaparken en alttaki şablonu
##           doldurun. Yalnızca sentez + zamanlama/güç analizi için pin ataması
##           şart değildir (Vivado I/O'ları otomatik yerleştirir).
## =============================================================================

## -----------------------------------------------------------------------------
## 1) SİSTEM SAATİ - 100 MHz (10.000 ns periyot)
##    Tasarım 100 MHz için ölçeklendi. Bu satır olmadan WNS/TNS "NA" görünür ve
##    güç tahmini varsayılan/kötümser aktiviteyle şişer (yüksek sıcaklık nedeni).
## -----------------------------------------------------------------------------
create_clock -period 10.000 -name clk_in [get_ports clk_in]

## Saat belirsizliği (jitter + kötümser pay) - opsiyonel, gerçekçi kapanış için
set_clock_uncertainty 0.200 [get_clocks clk_in]

## -----------------------------------------------------------------------------
## 2) ASENKRON RESET - zamanlama yoluna dahil edilmez
##    rst_n aktif-düşük asenkron reset; saat yoluyla analiz edilmez.
## -----------------------------------------------------------------------------
set_false_path -from [get_ports rst_n]

## -----------------------------------------------------------------------------
## 3) GİRİŞ / ÇIKIŞ GECİKMELERİ
##    Kart-dışı arayüz zamanlaması için kötümser değerler. clk_in ve rst_n
##    veri yolu değildir; giriş gecikmesinden hariç tutulur.
##    (Bu değerler kart timing'i için placeholder'dır; güç/sıcaklık tahminini
##     etkilemez - asıl etken yukarıdaki create_clock'tur.)
## -----------------------------------------------------------------------------
set veri_girisleri [filter [all_inputs] {NAME != clk_in && NAME != rst_n}]
set_input_delay  -clock clk_in 2.000 $veri_girisleri
set_output_delay -clock clk_in 2.000 [all_outputs]

## -----------------------------------------------------------------------------
## 4) KART-GENEL YAPILANDIRMA (sık görülen kritik uyarıları giderir)
##    Bank 0 için CFGBVS / CONFIG_VOLTAGE tanımlanmazsa Vivado DRC kritik uyarı
##    verir. 7-serisi için tipik değerler:
## -----------------------------------------------------------------------------
set_property CFGBVS VCCO         [current_design]
set_property CONFIG_VOLTAGE 3.3  [current_design]

## =============================================================================
## 5) FİZİKSEL PİN ATAMA ŞABLONU (karta özgü - gerçek karta yerleştirmede doldurun)
##    Örnek biçim (kendi kartınızın pinlerine göre değiştirin):
##
##    set_property -dict {PACKAGE_PIN <PIN> IOSTANDARD LVCMOS33} [get_ports clk_in]
##    set_property -dict {PACKAGE_PIN <PIN> IOSTANDARD LVCMOS33} [get_ports rst_n]
##    ... (diğer portlar)
##
##    NOT: xc7a50t-cpg236 yalnızca 106 kullanıcı I/O sunar. ecdh_controller
##    (~78 port) bu pakete sığar; ancak uçtan uca ecdh_kex_top 115 port
##    içerdiğinden cpg236'ya SIĞMAZ - onun için xq7a100t-cs324 (≥210 I/O)
##    gereklidir.
## =============================================================================