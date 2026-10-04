"""
Integration tests: two taxi_eth_phy_10g back to back (full duplex).

  Agent 1A -> PHY A TX -> channel A->B -> PHY B RX -> Agent 2B
  Agent 2A <- PHY A RX <- channel B->A <- PHY B TX <- Agent 1B

Plan IDs: FD-01..FD-03 (docs/plan_de_verificacion.md).
"""

import cocotb
from cocotb.triggers import ClockCycles, RisingEdge

from vip import sequences
from vip.agents import Channel, StatusMonitor, XgmiiDriver, XgmiiMonitor, now_ps
from vip.prbs import PrbsChecker
from vip.scoreboard import compare_frames, compare_streams
from vip.tb_utils import PERIOD_NS, PERIOD_PS, make_rng, pulse_reset, setup_log, start_clock
from vip.xgmii import IDLE_WORD, fmt_word


class DuplexTB:
    def __init__(self, dut, tag, period_b_ns=PERIOD_NS):
        self.dut = dut
        self.log = setup_log()
        self.rng = make_rng(tag)
        start_clock(dut.clk_a, PERIOD_NS)
        start_clock(dut.clk_b, period_b_ns)
        dut.rst.value = 1
        # A transmits on clk_a; B receives on clk_a (and vice versa)
        self.drv_a = XgmiiDriver(dut.a_xgmii_txd, dut.a_xgmii_txc, dut.clk_a, seed=0x1111,
                                 rng=self.rng, start_lane="random", name="agent1_A")
        self.drv_b = XgmiiDriver(dut.b_xgmii_txd, dut.b_xgmii_txc, dut.clk_b, seed=0x2222,
                                 rng=self.rng, start_lane="random", name="agent1_B")
        self.mon_a = XgmiiMonitor(dut.a_xgmii_rxd, dut.a_xgmii_rxc, dut.clk_b,
                                  valid=dut.a_xgmii_rx_valid, name="agent2_A")
        self.mon_b = XgmiiMonitor(dut.b_xgmii_rxd, dut.b_xgmii_rxc, dut.clk_a,
                                  valid=dut.b_xgmii_rx_valid, name="agent2_B")
        self.ch_ab = Channel(dut.a_serdes_tx_data, dut.a_serdes_tx_hdr, dut.clk_a,
                             dut.b_serdes_rx_data, dut.b_serdes_rx_hdr,
                             rx_slip=dut.b_serdes_rx_bitslip, name="channel_AB")
        self.ch_ba = Channel(dut.b_serdes_tx_data, dut.b_serdes_tx_hdr, dut.clk_b,
                             dut.a_serdes_rx_data, dut.a_serdes_rx_hdr,
                             rx_slip=dut.a_serdes_rx_bitslip, name="channel_BA")
        self.st_a = StatusMonitor(dut.clk_b, lock=dut.a_rx_block_lock, hi_ber=dut.a_rx_high_ber)
        self.st_b = StatusMonitor(dut.clk_a, lock=dut.b_rx_block_lock, hi_ber=dut.b_rx_high_ber)

    async def reset(self):
        await pulse_reset(self.dut.clk_a, [self.dut.rst], cycles=16)

    async def wait_both_locked(self, timeout=20000):
        for _ in range(timeout):
            await RisingEdge(self.dut.clk_a)
            if int(self.dut.a_rx_block_lock.value) and int(self.dut.b_rx_block_lock.value):
                return now_ps()
        raise AssertionError("both receivers did not lock")

    def check_direction(self, name, drv, mon, t_from):
        frames = [f for f in mon.frames if f.t_start >= t_from]
        fr = compare_frames(name, drv.sent_frames[self._sent_from[name]:], frames, log=self.log)
        e2e = compare_streams(name + "_e2e", drv.words, mon.words, lambda w: w != IDLE_WORD,
                              PERIOD_PS, fmt=fmt_word, log=self.log, start_after=t_from)
        return fr, e2e


@cocotb.test()
async def test_duplex_traffic(dut):
    """FD-01: simultaneous random traffic in both directions (independent PRBS
    streams, random start lanes, bit offsets on both lines): every frame good,
    streams identical end to end, PRBS clean on both sides."""
    tb = DuplexTB(dut, "duplex_traffic")
    tb.ch_ab.set_offset(0, 23)
    tb.ch_ba.set_offset(0, 41)
    await tb.reset()
    t_lock = await tb.wait_both_locked()
    tb.mon_a.prbs, tb.mon_b.prbs = PrbsChecker(31), PrbsChecker(31)
    tb._sent_from = {"A_to_B": len(tb.drv_a.sent_frames), "B_to_A": len(tb.drv_b.sent_frames)}
    for _ in range(200):
        tb.drv_a.send_frame(sequences.random_frame_length(tb.rng))
        tb.drv_b.send_frame(sequences.random_frame_length(tb.rng))
    await tb.drv_a.wait_idle()
    await tb.drv_b.wait_idle(extra_cycles=64)
    fr_ab, e2e_ab = tb.check_direction("A_to_B", tb.drv_a, tb.mon_b, t_lock)
    fr_ba, e2e_ba = tb.check_direction("B_to_A", tb.drv_b, tb.mon_a, t_lock)
    tb.log.info("slips: A->B %d, B->A %d | PRBS B: %d bits %d errors, A: %d bits %d errors",
                tb.ch_ab.slips, tb.ch_ba.slips, tb.mon_b.prbs.bits_checked,
                tb.mon_b.prbs.bit_errors, tb.mon_a.prbs.bits_checked, tb.mon_a.prbs.bit_errors)
    assert fr_ab.ok and fr_ba.ok and e2e_ab.ok and e2e_ba.ok
    assert tb.mon_a.prbs.bit_errors == 0 and tb.mon_b.prbs.bit_errors == 0


@cocotb.test()
async def test_duplex_link_down_one_direction(dut):
    """FD-02: the A->B line goes down (no signal) while traffic flows both ways:
    B loses block lock, the B->A direction is unaffected; when the line comes
    back B re-locks and traffic A->B resumes."""
    tb = DuplexTB(dut, "duplex_link_down")
    await tb.reset()
    t_lock = await tb.wait_both_locked()
    tb._sent_from = {"A_to_B": 0, "B_to_A": 0}
    for _ in range(60):
        tb.drv_b.send_frame(sequences.random_frame_length(tb.rng))
    await ClockCycles(dut.clk_a, 200)
    tb.ch_ab.link_up = False
    t_down = now_ps()
    await ClockCycles(dut.clk_a, 300)
    b_lost = bool(tb.st_b.falls("lock", after=t_down))
    a_lost = bool(tb.st_a.falls("lock", after=t_lock))
    tb.ch_ab.link_up = True
    await tb.wait_both_locked()
    t_up = now_ps()
    tb._sent_from["A_to_B"] = len(tb.drv_a.sent_frames)
    for _ in range(40):
        tb.drv_a.send_frame(sequences.random_frame_length(tb.rng))
    await tb.drv_a.wait_idle()
    await tb.drv_b.wait_idle(extra_cycles=64)
    fr_ab, _ = tb.check_direction("A_to_B", tb.drv_a, tb.mon_b, t_up)
    fr_ba = compare_frames("B_to_A", tb.drv_b.sent_frames,
                           [f for f in tb.mon_a.frames if f.t_start >= t_lock], log=tb.log)
    tb.log.info("B lost lock: %s | A lost lock: %s", b_lost, a_lost)
    assert b_lost, "B kept block lock with no signal on its line"
    assert not a_lost, "A lost block lock although its line was fine"
    assert fr_ba.ok, "traffic B->A disturbed by the A->B outage"
    assert fr_ab.ok, "traffic A->B not recovered after the outage"
