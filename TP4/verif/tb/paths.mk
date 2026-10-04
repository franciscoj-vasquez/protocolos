# Paths shared by the TP4 testbenches (this file lives in TP4/verif/tb/).
# Override the DUT location with: make TAXI_DIR=/path/to/taxi

TB_COMMON_DIR := $(patsubst %/,%,$(dir $(abspath $(lastword $(MAKEFILE_LIST)))))
VERIF_DIR     := $(abspath $(TB_COMMON_DIR)/..)
TP4_DIR       := $(abspath $(VERIF_DIR)/..)
TAXI_DIR      ?= $(TP4_DIR)/repo_taxi/taxi
TAXI_RTL      := $(TAXI_DIR)/src/eth/rtl

ifeq ($(wildcard $(TAXI_RTL)/taxi_eth_phy_10g.sv),)
  $(error taxi RTL not found in $(TAXI_RTL). Run TP4/scripts/get_taxi.sh or set TAXI_DIR)
endif
