# 156.25 MHz: the 64-bit datapath clock of a 10 Gb/s Ethernet MAC (64 bits x 156.25 MHz = 10 Gb/s).
create_clock -period 6.400 -name clk [get_ports clk]
