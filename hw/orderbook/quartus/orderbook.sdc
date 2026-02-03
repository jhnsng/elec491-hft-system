#**************************************************************
# Create primary FPGA clock
#**************************************************************
# 50 MHz external oscillator
create_clock -name CLOCK_50 -period 20.000 [get_ports CLOCK_50]

#**************************************************************
# Create generated clocks
#**************************************************************
# PLL generates 145 MHz clock from CLOCK_50
# Let Platform Designer / PLL IP define internal clocks automatically
derive_pll_clocks

#**************************************************************
# Clock uncertainty
#**************************************************************
derive_clock_uncertainty

#**************************************************************
# Input / Output delays
#**************************************************************
# No external synchronous I/O used in this module
# All inputs/outputs are internal FPGA signals
# → No input/output delay constraints required

#**************************************************************
# End of file
#**************************************************************
