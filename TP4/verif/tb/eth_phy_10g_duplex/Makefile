# Integration testbench: two taxi_eth_phy_10g back to back (full duplex)

include ../paths.mk

DUT                 = taxi_eth_phy_10g
COCOTB_TOPLEVEL     = tb_eth_phy_10g_duplex
COCOTB_TEST_MODULES = test_eth_phy_10g_duplex
VERILOG_SOURCES    += $(CURDIR)/tb_eth_phy_10g_duplex.sv
VERILOG_SOURCES    += $(TAXI_RTL)/$(DUT).f

export PARAM_DATA_W      := 64
export PARAM_CTRL_W      := 8
export PARAM_HDR_W       := 2
COUNT_125US ?= 195
export PARAM_COUNT_125US := $(COUNT_125US)

include ../common.mk
