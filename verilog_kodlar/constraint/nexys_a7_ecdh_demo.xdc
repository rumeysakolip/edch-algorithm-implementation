## =============================================================================
## Dosya   : nexys_a7_ecdh_demo.xdc
## Proje   : FPGA Tabanlı Güvenli Anahtar Yönetimi ve Kripto Hızlandırıcı (5260007)
## Kart    : Digilent Nexys A7-100T  (xc7a100tcsg324-1)
## Top     : ecdh_demo_top
## Amaç    : Bit-stream için fiziksel pin atamaları + saat kısıtı.
## -----------------------------------------------------------------------------
## ÖNEMLİ: Pin numaraları Nexys A7-100T master XDC'sine göredir. Farklı bir kart
## kullanıyorsanız, PACKAGE_PIN değerlerini kendi kartınızın resmi master XDC'si
## ile MUTLAKA karşılaştırıp değiştirin.
## Bu dosya, önceki timing.xdc'nin yerini alır (top artık ecdh_demo_top).
## =============================================================================

## -----------------------------------------------------------------------------
## 100 MHz kart osilatörü (pin E3) + saat kısıtı (10 ns)
## -----------------------------------------------------------------------------
set_property -dict { PACKAGE_PIN E3  IOSTANDARD LVCMOS33 } [get_ports { clk_100 }]
create_clock -period 10.000 -name sys_clk [get_ports { clk_100 }]
set_clock_uncertainty 0.200 [get_clocks sys_clk]

## -----------------------------------------------------------------------------
## Butonlar
##   btn_reset : btnCpuReset (kırmızı reset butonu, C12, aktif-DÜŞÜK)
##   btn_start : btnC (orta buton, N17)
## -----------------------------------------------------------------------------
set_property -dict { PACKAGE_PIN C12 IOSTANDARD LVCMOS33 } [get_ports { btn_reset }]
set_property -dict { PACKAGE_PIN N17 IOSTANDARD LVCMOS33 } [get_ports { btn_start }]

## Butonlar asenkron; iç senkronizasyon var (giriş zamanlaması analiz dışı)
set_false_path -from [get_ports { btn_reset }]
set_false_path -from [get_ports { btn_start }]

## -----------------------------------------------------------------------------
## 16 LED (LD0..LD15)
## -----------------------------------------------------------------------------
set_property -dict { PACKAGE_PIN H17 IOSTANDARD LVCMOS33 } [get_ports { led[0]  }]
set_property -dict { PACKAGE_PIN K15 IOSTANDARD LVCMOS33 } [get_ports { led[1]  }]
set_property -dict { PACKAGE_PIN J13 IOSTANDARD LVCMOS33 } [get_ports { led[2]  }]
set_property -dict { PACKAGE_PIN N14 IOSTANDARD LVCMOS33 } [get_ports { led[3]  }]
set_property -dict { PACKAGE_PIN R18 IOSTANDARD LVCMOS33 } [get_ports { led[4]  }]
set_property -dict { PACKAGE_PIN V17 IOSTANDARD LVCMOS33 } [get_ports { led[5]  }]
set_property -dict { PACKAGE_PIN U17 IOSTANDARD LVCMOS33 } [get_ports { led[6]  }]
set_property -dict { PACKAGE_PIN U16 IOSTANDARD LVCMOS33 } [get_ports { led[7]  }]
set_property -dict { PACKAGE_PIN V16 IOSTANDARD LVCMOS33 } [get_ports { led[8]  }]
set_property -dict { PACKAGE_PIN T15 IOSTANDARD LVCMOS33 } [get_ports { led[9]  }]
set_property -dict { PACKAGE_PIN U14 IOSTANDARD LVCMOS33 } [get_ports { led[10] }]
set_property -dict { PACKAGE_PIN T16 IOSTANDARD LVCMOS33 } [get_ports { led[11] }]
set_property -dict { PACKAGE_PIN V15 IOSTANDARD LVCMOS33 } [get_ports { led[12] }]
set_property -dict { PACKAGE_PIN V14 IOSTANDARD LVCMOS33 } [get_ports { led[13] }]
set_property -dict { PACKAGE_PIN V12 IOSTANDARD LVCMOS33 } [get_ports { led[14] }]
set_property -dict { PACKAGE_PIN V11 IOSTANDARD LVCMOS33 } [get_ports { led[15] }]

## -----------------------------------------------------------------------------
## Kart-genel yapılandırma (bit-stream için gerekli)
## -----------------------------------------------------------------------------
set_property CFGBVS VCCO         [current_design]
set_property CONFIG_VOLTAGE 3.3  [current_design]
