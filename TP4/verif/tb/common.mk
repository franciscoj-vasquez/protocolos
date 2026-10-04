# Common cocotb + Verilator rules for the TP4 testbenches.
# Include it at the END of each testbench Makefile (after DUT, sources, PARAM_*).
#
#   make                      run every test of the testbench (waves on: dump.fst)
#   make WAVES=0              faster, no waveform
#   make COCOTB_TEST_FILTER=test_name     run a subset (regex)
#   make COCOTB_RANDOM_SEED=1234          reproduce a run (seed is printed at start)
#   make waves                open dump.fst in GTKWave

TOPLEVEL_LANG ?= verilog
SIM   ?= verilator
WAVES ?= 1

COCOTB_HDL_TIMEUNIT      = 1ns
COCOTB_HDL_TIMEPRECISION = 1ps

ifneq ($(SIM),verilator)
  $(error These testbenches target Verilator (taxi uses SystemVerilog that Icarus does not support))
endif

# Expand taxi .f file lists (same helpers as the upstream taxi Makefiles)
process_f_file = $(call process_f_files,$(addprefix $(dir $1),$(shell cat $1)))
process_f_files = $(foreach f,$1,$(if $(filter %.f,$f),$(call process_f_file,$f),$f))
uniq_base = $(if $1,$(call uniq_base,$(foreach f,$1,$(if $(filter-out $(notdir $(lastword $1)),$(notdir $f)),$f,))) $(lastword $1))
VERILOG_SOURCES := $(call uniq_base,$(call process_f_files,$(VERILOG_SOURCES)))

# VIP package and the testbench directory on the Python path
export PYTHONPATH := $(VERIF_DIR):$(CURDIR)$(if $(PYTHONPATH),:$(PYTHONPATH))

# DUT parameters (PARAM_<name> -> -G<name>=<value>); also visible to Python
COMPILE_ARGS += $(foreach v,$(filter PARAM_%,$(.VARIABLES)),-G$(subst PARAM_,,$(v))=$($(v)))
# keep lint warnings visible but do not stop the build on the third-party RTL
COMPILE_ARGS += -Wno-fatal

ifeq ($(WAVES),1)
  COMPILE_ARGS += --trace-fst
  VERILATOR_TRACE = 1
endif

# cocotb only rebuilds the model when a source file changes: keep a stamp of the
# compile arguments so that a new parameter value or WAVES setting also rebuilds.
SIM_BUILD ?= sim_build
_ARGS_FILE := $(SIM_BUILD)/compile_args.txt
_ARGS_NOW  := $(strip $(COMPILE_ARGS) $(VERILOG_SOURCES))
_ARGS_OLD  := $(if $(wildcard $(_ARGS_FILE)),$(strip $(file <$(_ARGS_FILE))))
ifneq ($(_ARGS_NOW),$(_ARGS_OLD))
  $(shell mkdir -p $(SIM_BUILD))
  $(file >$(_ARGS_FILE),$(_ARGS_NOW))
endif
CUSTOM_COMPILE_DEPS += $(abspath $(_ARGS_FILE))

include $(shell cocotb-config --makefiles)/Makefile.sim

.PHONY: waves
waves:
	gtkwave dump.fst $(wildcard *.gtkw) &

clean::
	@rm -rf dump.fst dump.vcd reports __pycache__
