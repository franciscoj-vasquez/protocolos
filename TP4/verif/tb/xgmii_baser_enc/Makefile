# Unit testbench: taxi_xgmii_baser_enc (XGMII -> 64B/66B encoder)

include ../paths.mk

DUT                 = taxi_xgmii_baser_enc
COCOTB_TOPLEVEL     = $(DUT)
COCOTB_TEST_MODULES = test_xgmii_baser_enc
VERILOG_SOURCES    += $(TAXI_RTL)/$(DUT).sv

export PARAM_DATA_W    := 64
export PARAM_CTRL_W    := 8
export PARAM_HDR_W     := 2
export PARAM_GBX_IF_EN := 0
export PARAM_GBX_CNT   := 1

include ../common.mk
