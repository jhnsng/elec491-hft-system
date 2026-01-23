#**************************************************************
# Create primary FPGA clock
#**************************************************************
# 50 MHz external oscillator
create_clock -name CLOCK_50 -period 20.000 [get_ports CLOCK_50]

#**************************************************************
# Create generated clocks
#**************************************************************
# Let Platform Designer / PLL IP define internal clocks
derive_pll_clocks

#**************************************************************
# Clock uncertainty
#**************************************************************
derive_clock_uncertainty

#**************************************************************
# False paths
#**************************************************************
# HPS DDR and peripheral timing is internally constrained
# Do not attempt to time these at the FPGA fabric boundary
set_false_path -from [get_ports HPS_DDR3_*]
set_false_path -to   [get_ports HPS_DDR3_*]

set_false_path -from [get_ports HPS_ENET_*]
set_false_path -to   [get_ports HPS_ENET_*]

set_false_path -from [get_ports HPS_USB_*]
set_false_path -to   [get_ports HPS_USB_*]

set_false_path -from [get_ports HPS_SD_*]
set_false_path -to   [get_ports HPS_SD_*]

set_false_path -from [get_ports HPS_SPI*]
set_false_path -to   [get_ports HPS_SPI*]

set_false_path -from [get_ports HPS_UART_*]
set_false_path -to   [get_ports HPS_UART_*]

set_false_path -from [get_ports HPS_I2C*]
set_false_path -to   [get_ports HPS_I2C*]

set_false_path -from [get_ports HPS_GPIO*]
set_false_path -to   [get_ports HPS_GPIO*]

#**************************************************************
# Input / Output delays
#**************************************************************
# No external synchronous FPGA I/O used in this test
# (LEDR are asynchronous indicators only)
# → No input/output delay constraints required

#**************************************************************
# End of file
#**************************************************************
