"""
VIP (verification IP) for the TP4 10GBASE-R PCS/XGMII testbenches.

Pure-Python modules (no simulator needed, unit-tested in vip/tests):
  xgmii   XGMII characters/words, frame -> word stream builder, MAC-level parser
  baser   independent IEEE 802.3 Clause 49 reference model (64B/66B, scrambler,
          TX/RX state diagrams, block lock)
  prbs    PRBS generator / self-synchronizing checker
  scoreboard, coverage

cocotb modules (need a running simulation):
  agents  XGMII driver (Agent 1), XGMII monitor (Agent 2), PCS driver/monitor,
          PCS channel (loopback / full duplex), status monitor
  tb_utils
"""
