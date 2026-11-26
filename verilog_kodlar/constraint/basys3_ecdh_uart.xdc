## =============================================================================
## Dosya   : basys3_ecdh_uart.xdc
## Proje   : FPGA Tabanli Guvenli Anahtar Yonetimi ve Kripto Hizlandirici (5260007)
## Kart    : Digilent Basys 3      (xc7a35tcpg236-1)
## Top     : ecdh_uart_top
## -----------------------------------------------------------------------------
## *** BU DOSYAYI KULLANMADAN ONCE OKUYUN ***
##
## 1) PROJE PART NUMARASI DEGISTIRILMELIDIR:
##      Settings -> General -> Project device -> xc7a35tcpg236-1
##
## 2) TOP MODUL PARAMETRESI DEGISTIRILMELIDIR:
##      ecdh_uart_top #( .RESET_AKTIF_DUSUK(0) )
##    Basys 3'te ayri bir reset butonu YOKTUR; normal butonlar aktif-YUKSEKTIR.
##    Parametre 1 birakilirsa rst_n surekli '0' kalir ve TASARIM HIC CALISMAZ.
##    Vivado'da tek top modul kullaniliyorsa ecdh_uart_top.v icindeki
##    varsayilani 0 yapin veya bir sarmalayici modul yazin.
##
## 3) BU DOSYA ILE nexys_a7_ecdh_uart.xdc AYNI ANDA ETKIN OLMAMALIDIR.
##    Kullanilmayani: sag tik -> Disable File
##
## 4) PIN NUMARALARI Digilent Basys 3 master XDC'sine gore yazilmistir.
##    Karta yerlestirmeden ONCE resmi master XDC ile KARSILASTIRIN:
##    https://github.com/Digilent/digilent-xdc  (Basys3_Master.xdc)
## =============================================================================

## -----------------------------------------------------------------------------
## 100 MHz kart osilatoru (W5)
##   Nexys A7 ile AYNI frekans -> SAAT_HZ parametresi DEGISMEZ (100_000_000).
## -----------------------------------------------------------------------------
set_property -dict { PACKAGE_PIN W5  IOSTANDARD LVCMOS33 } [get_ports { clk_100 }]
create_clock -period 10.000 -name sys_clk [get_ports { clk_100 }]
set_clock_uncertainty 0.200 [get_clocks sys_clk]

## -----------------------------------------------------------------------------
## Butonlar  *** AKTIF-YUKSEK ***
##   btn_reset : btnU (T18) — basili degilken '0', basiliyken '1'
##   btn_start : btnC (U18)
##
##   Nexys A7'deki btnCpuReset aktif-DUSUK idi. Kutupluk farki RTL tarafinda
##   RESET_AKTIF_DUSUK=0 parametresiyle giderilir (bkz. yukarida madde 2).
## -----------------------------------------------------------------------------
set_property -dict { PACKAGE_PIN T18 IOSTANDARD LVCMOS33 } [get_ports { btn_reset }]
set_property -dict { PACKAGE_PIN U18 IOSTANDARD LVCMOS33 } [get_ports { btn_start }]

set_false_path -from [get_ports { btn_reset }]
set_false_path -from [get_ports { btn_start }]

## -----------------------------------------------------------------------------
## USB-UART KOPRUSU (FT2232HQ — kart uzerinde, ek donanim GEREKMEZ)
##   Basys 3 master XDC'sinde bu pinler RsRx / RsTx olarak adlandirilir.
##
##   RsRx = B18 : koprunun TXD'si -> FPGA'nin RX'i   -> uart_rx_in  (GIRIS)
##   RsTx = A18 : FPGA'nin TX'i   -> koprunun RXD'si -> uart_tx_out (CIKIS)
##
##   DIKKAT: Isimlendirme kart uzerindeki seri portun bakis acisiyladir.
##   "Rx" olan pin FPGA icin GIRIS, "Tx" olan CIKISTIR. Ters baglamak en sik
##   yapilan hatadir; belirtisi hic veri alinamamasi ve RX hattinin surekli
##   '1' kalmasidir.
##
##   Programlama ve seri iletisim AYNI mikro-USB kablosunu kullanir.
## -----------------------------------------------------------------------------
set_property -dict { PACKAGE_PIN B18 IOSTANDARD LVCMOS33 } [get_ports { uart_rx_in  }]
set_property -dict { PACKAGE_PIN A18 IOSTANDARD LVCMOS33 } [get_ports { uart_tx_out }]

set_false_path -from [get_ports { uart_rx_in  }]
set_false_path -to   [get_ports { uart_tx_out }]

## -----------------------------------------------------------------------------
## 16 LED (LD0..LD15) — Basys 3'te tam 16 adet var, LED haritasi DEGISMEZ
## -----------------------------------------------------------------------------
set_property -dict { PACKAGE_PIN U16 IOSTANDARD LVCMOS33 } [get_ports { led[0]  }]
set_property -dict { PACKAGE_PIN E19 IOSTANDARD LVCMOS33 } [get_ports { led[1]  }]
set_property -dict { PACKAGE_PIN U19 IOSTANDARD LVCMOS33 } [get_ports { led[2]  }]
set_property -dict { PACKAGE_PIN V19 IOSTANDARD LVCMOS33 } [get_ports { led[3]  }]
set_property -dict { PACKAGE_PIN W18 IOSTANDARD LVCMOS33 } [get_ports { led[4]  }]
set_property -dict { PACKAGE_PIN U15 IOSTANDARD LVCMOS33 } [get_ports { led[5]  }]
set_property -dict { PACKAGE_PIN U14 IOSTANDARD LVCMOS33 } [get_ports { led[6]  }]
set_property -dict { PACKAGE_PIN V14 IOSTANDARD LVCMOS33 } [get_ports { led[7]  }]
set_property -dict { PACKAGE_PIN V13 IOSTANDARD LVCMOS33 } [get_ports { led[8]  }]
set_property -dict { PACKAGE_PIN V3  IOSTANDARD LVCMOS33 } [get_ports { led[9]  }]
set_property -dict { PACKAGE_PIN W3  IOSTANDARD LVCMOS33 } [get_ports { led[10] }]
set_property -dict { PACKAGE_PIN U3  IOSTANDARD LVCMOS33 } [get_ports { led[11] }]
set_property -dict { PACKAGE_PIN P3  IOSTANDARD LVCMOS33 } [get_ports { led[12] }]
set_property -dict { PACKAGE_PIN N3  IOSTANDARD LVCMOS33 } [get_ports { led[13] }]
set_property -dict { PACKAGE_PIN P1  IOSTANDARD LVCMOS33 } [get_ports { led[14] }]
set_property -dict { PACKAGE_PIN L1  IOSTANDARD LVCMOS33 } [get_ports { led[15] }]

## -----------------------------------------------------------------------------
## Kart-genel yapilandirma
## -----------------------------------------------------------------------------
set_property CFGBVS VCCO         [current_design]
set_property CONFIG_VOLTAGE 3.3  [current_design]

## =============================================================================
## BASYS 3 KONTROL LISTESI
##   [ ] Project device = xc7a35tcpg236-1
##   [ ] RESET_AKTIF_DUSUK = 0
##   [ ] nexys_a7_ecdh_uart.xdc DEVRE DISI
##   [ ] Bu dosya etkin ve target constraint
##   [ ] Top modul = ecdh_uart_top
##   [ ] TEST_MODU sentezde TANIMSIZ
##   [ ] Sentez sonrasi: LUT doluluk ~%58 bekleniyor (20.800'un 12.149'u)
##   [ ] WNS > 0
##
## BEKLENEN FARKLAR (Nexys A7-100T'ye gore)
##   - LUT dolulugu %19 -> ~%58  (35T, 100T'nin ucte biri kadar LUT'a sahip)
##   - Zamanlama payi daralabilir; WNS pozitif kalmali ama +0.278 ns'den
##     dusuk cikmasi normaldir. Negatif cikarsa Implementation Strategy'yi
##     "Performance_ExplorePostRoutePhysOpt" yapmayi deneyin.
##   - Guc tuketimi duser (daha kucuk cip)
## =============================================================================
