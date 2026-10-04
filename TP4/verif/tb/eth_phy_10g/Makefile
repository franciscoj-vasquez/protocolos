# Top-level testbench: taxi_eth_phy_10g (10GBASE-R PCS with XGMII and SERDES ports)

include ../paths.mk

DUT                 = taxi_eth_phy_10g
COCOTB_TOPLEVEL     = $(DUT)
COCOTB_TEST_MODULES = test_eth_phy_10g
VERILOG_SOURCES    += $(TAXI_RTL)/$(DUT).f

# Configuration under test (RTL defaults except where noted)
export PARAM_DATA_W              := 64
export PARAM_CTRL_W              := 8
export PARAM_HDR_W               := 2
export PARAM_TX_GBX_IF_EN        := 0
export PARAM_RX_GBX_IF_EN        := 0
export PARAM_BIT_REVERSE         := "1'b0"
export PARAM_SCRAMBLER_DISABLE   := "1'b0"
# PRBS31 test-pattern logic present (cfg_*_prbs31_enable = 0 unless a test sets it)
export PARAM_PRBS31_EN           := "1'b1"
export PARAM_TX_SERDES_PIPELINE  ?= 0
export PARAM_RX_SERDES_PIPELINE  ?= 0
export PARAM_BITSLIP_HIGH_CYCLES := 1
export PARAM_BITSLIP_LOW_CYCLES  := 7
# 125 us timer scaled 1:100 for simulation speed (real value: 125000/6.4 = 19531.25)
COUNT_125US ?= 195
export PARAM_COUNT_125US         := $(COUNT_125US)

include ../common.mk
