# TP4 regression: VIP self-tests + every testbench, then a summary table.
#
#   make                 selftest + all testbenches (WAVES=0 for speed)
#   make selftest        only the simulator-free VIP tests (pytest)
#   make tb_eth_phy_10g  one testbench (waves on)
#   make summary         table of the last results (reports/summary.md)
#   make clean

TBS := xgmii_baser_enc xgmii_baser_dec eth_phy_10g eth_phy_10g_duplex
WAVES ?= 0

.PHONY: all selftest summary clean $(addprefix tb_,$(TBS))

all: selftest
	@for tb in $(TBS); do \
		echo "=== $$tb"; \
		$(MAKE) -C tb/$$tb WAVES=$(WAVES) || true; \
	done
	@$(MAKE) --no-print-directory summary

selftest:
	python3 -m pytest -q selftest

$(addprefix tb_,$(TBS)): tb_%:
	$(MAKE) -C tb/$* WAVES=$(or $(WAVES_TB),1)

summary:
	@python3 tools/summarize_results.py $(addprefix tb/,$(TBS))

clean:
	@for tb in $(TBS); do $(MAKE) -C tb/$$tb clean; done
	@rm -rf reports .pytest_cache selftest/__pycache__ vip/__pycache__
