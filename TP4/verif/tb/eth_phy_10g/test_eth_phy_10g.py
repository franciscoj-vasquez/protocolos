"""
Top-level tests: taxi_eth_phy_10g (10GBASE-R PCS: encoder + scrambler, block
lock + BER monitor + descrambler + decoder), black box at its XGMII and SERDES
ports.

Arrangements
  split     Agent 1 -> TX -> PcsMonitor             (TX checks)
            PcsDriver -> RX -> Agent 2              (RX checks, independent traffic)
  loopback  Agent 1 -> TX -> Channel -> RX -> Agent 2   ("PCS out -> PCS in")

Plan IDs: PHY-*, TXSM-04, RXSM-04/05, LOCK-*, BER-*, LAT-01, E2E-*, TP-*
(docs/plan_de_verificacion.md). The BER/watchdog timer is scaled with the
COUNT_125US parameter (Makefile) to keep simulations short.
"""

import cocotb
from cocotb.triggers import ClockCycles, RisingEdge

from vip import baser, sequences
from vip.agents import (Channel, PcsDriver, PcsMonitor, StatusMonitor, XgmiiDriver,
                        XgmiiMonitor, now_ps)
from vip.coverage import FRAME_LEN_BINS, Coverage, frame_len_bin
from vip.prbs import PrbsChecker, PrbsGenerator
from vip.scoreboard import compare_frames, compare_streams
from vip.tb_utils import (PERIOD_PS, make_rng, param, pulse_reset, report_path, setup_log,
                          start_clock)
from vip.xgmii import C, IDLE, IDLE_WORD, LOCAL_FAULT, XgmiiStreamBuilder, fmt_word, os_chars, word

IDLE_BLOCK = baser.encode(IDLE_WORD)
LF_ONE = word(os_chars(LOCAL_FAULT) + [C(IDLE)] * 4)      # one LF ordered set + idles
LF_WORDS = (baser.LBLOCK_R, LF_ONE)
COUNT_125US = int(param("COUNT_125US", 195))
PCS_DELAY_MAX_BT = 3584      # 49.2.15 / Table 44-2: PCS transmit + receive delay
BT_PER_CYCLE = 64            # 6.4 ns at 10 Gb/s


class HdrCorrupt:
    """line_hook: force an invalid sync header on the given block indexes."""

    def __init__(self, indexes, value=0b00):
        self.indexes = set(indexes)
        self.value = value

    def __call__(self, i, hdr, data):
        return (self.value, data) if i in self.indexes else (hdr, data)


class PhyTB:
    def __init__(self, dut, tag, loopback=False, delay=0, **drv_args):
        self.dut = dut
        self.tag = tag
        self.log = setup_log()
        self.rng = make_rng(tag)
        start_clock(dut.tx_clk)
        start_clock(dut.rx_clk)
        dut.tx_rst.value = 1
        dut.rx_rst.value = 1
        dut.tx_gbx_sync.value = 0
        dut.serdes_tx_gbx_req_sync.value = 0
        dut.serdes_tx_gbx_req_stall.value = 0
        dut.serdes_rx_data_valid.value = 1
        dut.serdes_rx_hdr_valid.value = 1
        dut.serdes_rx_gbx_sync.value = 0
        dut.cfg_tx_prbs31_enable.value = 0
        dut.cfg_rx_prbs31_enable.value = 0
        self.xdrv = XgmiiDriver(dut.xgmii_txd, dut.xgmii_txc, dut.tx_clk, valid=dut.xgmii_tx_valid,
                                rng=self.rng, **drv_args)
        self.xmon = XgmiiMonitor(dut.xgmii_rxd, dut.xgmii_rxc, dut.rx_clk, valid=dut.xgmii_rx_valid)
        self.pmon = PcsMonitor(dut.serdes_tx_data, dut.serdes_tx_hdr, dut.tx_clk,
                               data_valid=dut.serdes_tx_data_valid)
        self.pdrv = self.chan = None
        if loopback:
            self.chan = Channel(dut.serdes_tx_data, dut.serdes_tx_hdr, dut.tx_clk,
                                dut.serdes_rx_data, dut.serdes_rx_hdr,
                                rx_slip=dut.serdes_rx_bitslip, delay=delay)
        else:
            self.pdrv = PcsDriver(dut.serdes_rx_data, dut.serdes_rx_hdr, dut.rx_clk,
                                  slip=dut.serdes_rx_bitslip)
        self.status = StatusMonitor(dut.rx_clk, lock=dut.rx_block_lock, hi_ber=dut.rx_high_ber,
                                    rx_status=dut.rx_status, bad_block=dut.rx_bad_block,
                                    seq_err=dut.rx_sequence_error, bitslip=dut.serdes_rx_bitslip)
        self.t_reset_done = 0

    @property
    def line(self):
        return self.chan if self.chan is not None else self.pdrv

    async def reset(self):
        await pulse_reset(self.dut.tx_clk, [self.dut.tx_rst, self.dut.rx_rst])
        self.t_reset_done = now_ps()

    async def wait_lock(self, timeout=20000):
        for _ in range(timeout):
            await RisingEdge(self.dut.rx_clk)
            if int(self.dut.rx_block_lock.value):
                return now_ps()
        raise AssertionError(f"no block lock after {timeout} cycles")

    async def wait_unlock(self, timeout=20000):
        for _ in range(timeout):
            await RisingEdge(self.dut.rx_clk)
            if not int(self.dut.rx_block_lock.value):
                return now_ps()
        raise AssertionError(f"block lock not lost after {timeout} cycles")

    # -- TX side ----------------------------------------------------------
    def tx_check(self, name, strict=True):
        sm = baser.TxStateMachine()
        exp = [(t, sm.step(w)) for t, w in self.xdrv.words]
        res = compare_streams(name + "_tx", exp, self.pmon.blocks, lambda b: b != IDLE_BLOCK,
                              PERIOD_PS, fmt=baser.fmt_block, log=self.log)
        bad_sh = [(t, h) for t, (h, _) in self.pmon.raw
                  if t > self.t_reset_done + 16 * PERIOD_PS and not baser.sh_valid(h)]
        if bad_sh:
            self.log.error("%d TX blocks with an invalid sync header (first @ %.1f ns)",
                           len(bad_sh), bad_sh[0][0] / 1000)
        if strict:
            assert res.ok and not bad_sh, res.summary()
        return res

    # -- RX side ----------------------------------------------------------
    def queue_rx_frames(self, n, ifg=12, start_lane="any"):
        gen = PrbsGenerator(31, state=self.rng.getrandbits(31) | 1)
        b = XgmiiStreamBuilder(ifg=ifg, dic=True, start_lane=start_lane, rng=self.rng)
        payloads = []
        for _ in range(n):
            p = gen.bytes(sequences.random_frame_length(self.rng))
            payloads.append(p)
            b.add_frame(p)
        self.pdrv.send_words(b.drain())
        return payloads

    @staticmethod
    def rx_expected(line):
        ds, sm = baser.Descrambler(), baser.RxStateMachine()
        out, prev = [], None
        for t, (h, d) in line:
            w = sm.push((h, ds.descramble(d)))
            if w is not None:
                out.append((prev, w))
            prev = t
        return out

    def rx_check(self, name, start_after, strict=True):
        res = compare_streams(name + "_rx", self.rx_expected(self.line.line), self.xmon.words,
                              lambda w: w != IDLE_WORD, PERIOD_PS, fmt=fmt_word, log=self.log,
                              start_after=start_after)
        if strict:
            assert res.ok, res.summary()
        return res

    def frames_after(self, t):
        return [f for f in self.xmon.frames if f.t_start >= t]

    def coverage(self, name, payloads):
        cov = Coverage(name)
        cov.define("frame_len", FRAME_LEN_BINS)
        for p in payloads:
            cov.sample("frame_len", frame_len_bin(len(p)))
        self.log.info(cov.report())
        cov.dump(report_path(f"cov_{name}.json"))


# ---------------------------------------------------------------------------
# TX path
# ---------------------------------------------------------------------------

@cocotb.test()
@cocotb.parametrize(("start_lane", ["any", "random"]))
async def test_phy_tx_frames(dut, start_lane="any"):
    """PHY-TX-01..03: descrambled serdes_tx blocks equal the reference encoder
    output (validates encoder + scrambler polynomial), sync headers are never
    scrambled (always 01/10), constant TX latency."""
    tb = PhyTB(dut, f"phy_tx_{start_lane}", start_lane=start_lane)
    await tb.reset()
    for _ in range(150):
        tb.xdrv.send_frame(sequences.random_frame_length(tb.rng))
    await tb.xdrv.wait_idle(extra_cycles=32)
    res = tb.tx_check("phy_tx")
    tb.coverage(f"phy_tx_{start_lane}", tb.xdrv.sent_frames)
    tb.log.info("TX latency (XGMII in -> serdes out): %s cycles", res.latency_cycles)


@cocotb.test()
async def test_phy_tx_lblock_in_reset(dut):
    """TXSM-04 (TX_INIT): while the transmit reset is asserted the PCS sends
    LBLOCK_T (Local Fault ordered sets)."""
    tb = PhyTB(dut, "phy_tx_reset")
    await tb.reset()
    await ClockCycles(dut.tx_clk, 64)
    dut.tx_rst.value = 1
    await ClockCycles(dut.tx_clk, 48)
    seen = [b for _, b in tb.pmon.blocks[-32:]]       # pipeline has settled
    dut.tx_rst.value = 0
    kinds = {}
    for b in seen:
        k = "LBLOCK_T" if b == baser.LBLOCK_T else baser.block_kind(b)
        kinds[k] = kinds.get(k, 0) + 1
    tb.log.info("TX blocks while tx_rst = 1: %s", kinds)
    assert kinds == {"LBLOCK_T": len(seen)}, f"expected only LBLOCK_T during reset, got {kinds}"


# ---------------------------------------------------------------------------
# RX path
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_phy_rx_frames(dut):
    """PHY-RX-01..03: scrambled reference traffic -> XGMII RX word-exact vs the
    RX state diagram; Agent 2 receives every frame good, PRBS payload clean."""
    tb = PhyTB(dut, "phy_rx")
    await tb.reset()
    t_lock = await tb.wait_lock()
    tb.xmon.prbs = PrbsChecker(31)
    payloads = tb.queue_rx_frames(150)
    await tb.pdrv.wait_idle(extra_cycles=64)
    res = tb.rx_check("phy_rx", t_lock)
    fr = compare_frames("phy_rx", payloads, tb.frames_after(t_lock), log=tb.log)
    tb.coverage("phy_rx", payloads)
    tb.log.info("RX latency (serdes in -> XGMII out): %s cycles", res.latency_cycles)
    assert fr.ok
    assert tb.xmon.prbs.locked and tb.xmon.prbs.bit_errors == 0


@cocotb.test()
async def test_phy_rx_lock_offsets(dut):
    """LOCK-01/02: from bit offsets 1..65 the receiver requests one slip at a time
    until aligned (66 - offset slips) and asserts block lock only after >= 64
    valid sync headers; traffic is then received correctly."""
    tb = PhyTB(dut, "phy_rx_lock_offsets")
    await tb.reset()
    await tb.wait_lock()
    rows, errors = [], []
    for off in sorted(set(range(1, 66, 4)) | {2, 64}):         # 19 offsets, 1..65
        t0 = now_ps()
        slips0 = tb.pdrv.slips
        tb.pdrv.set_offset(t0, off)
        await tb.wait_unlock(timeout=2000)
        t_lock = await tb.wait_lock(timeout=20000)
        t_aligned = max((t for t, o in tb.pdrv.slip_log if o == 0 and t >= t0), default=None)
        if t_aligned is None:
            errors.append(f"offset {off}: locked at bit offset {tb.pdrv.bit_offset} (misaligned)")
            continue
        n_valid = (t_lock - t_aligned) / PERIOD_PS
        slips = tb.pdrv.slips - slips0
        rows.append(f"  offset {off:2d}: slips {slips:2d} (expected {66 - off:2d}), lock "
                    f"{n_valid:5.1f} cycles after alignment, total {(t_lock - t0) / PERIOD_PS:6.0f}")
        if slips != 66 - off:
            errors.append(f"offset {off}: {slips} slips")
        if not 64 <= n_valid <= 64 + 32:
            errors.append(f"offset {off}: lock {n_valid} cycles after alignment")
        await ClockCycles(dut.rx_clk, 20)
    tb.log.info("block lock acquisition:\n%s", "\n".join(rows))
    t_ok = now_ps()
    payloads = tb.queue_rx_frames(20)
    await tb.pdrv.wait_idle(extra_cycles=64)
    fr = compare_frames("after_relock", payloads, tb.frames_after(t_ok), log=tb.log)
    assert not errors, errors
    assert fr.ok


@cocotb.test()
async def test_phy_rx_lock_hold_and_loss(dut):
    """LOCK-03: 15 consecutive invalid sync headers keep block lock.
    LOCK-04: 31 consecutive invalid headers (>= 16 in some 64-header window) drop
    it, and lock is regained >= 64 headers after the errors stop."""
    tb = PhyTB(dut, "phy_rx_lock_loss")
    await tb.reset()
    await tb.wait_lock()
    tb.pdrv.follow_slip = False            # line stays aligned; we only observe lock
    start = tb.pdrv.index + 8
    tb.pdrv.line_hook = HdrCorrupt(range(start, start + 15))
    t_a = now_ps()
    await ClockCycles(dut.rx_clk, 300)
    falls_a = tb.status.falls("lock", after=t_a)
    start = tb.pdrv.index + 8
    tb.pdrv.line_hook = HdrCorrupt(range(start, start + 31))
    t_b = now_ps()
    await ClockCycles(dut.rx_clk, 400)
    t_first = tb.pdrv.line[start][0]
    t_last = tb.pdrv.line[start + 30][0]
    falls_b = tb.status.falls("lock", after=t_b)
    rises_b = tb.status.rises("lock", after=t_b)
    tb.log.info("15 bad headers: lock falls %s | 31 bad headers: falls %s rises %s",
                falls_a, falls_b, rises_b)
    assert not falls_a, "block lock lost with only 15 invalid sync headers"
    assert falls_b, "block lock kept with 31 consecutive invalid sync headers"
    assert falls_b[0] - t_first <= (31 + 16) * PERIOD_PS, "lock loss detected too late"
    assert rises_b and rises_b[0] - t_last >= 64 * PERIOD_PS, "re-lock before 64 valid headers"


@cocotb.test()
async def test_phy_rx_hi_ber(dut):
    """BER-01..03: with the 125 us timer = COUNT_125US cycles, 15 invalid headers
    in a window do not set hi_ber; 31 (spread so block lock is kept) do; hi_ber
    clears after a clean window: high >= 1 window, cleared <= 2 windows after the
    last error."""
    W = COUNT_125US
    tb = PhyTB(dut, "phy_rx_hi_ber")
    await tb.reset()
    await tb.wait_lock()
    tb.pdrv.follow_slip = False
    start = tb.pdrv.index + 8
    tb.pdrv.line_hook = HdrCorrupt(range(start, start + 15 * 5, 5))
    t_a = now_ps()
    await ClockCycles(dut.rx_clk, 3 * W + 100)
    hi_a = tb.status.ever_high("hi_ber", after=t_a)
    start = tb.pdrv.index + 8
    idx = list(range(start, start + 31 * 5, 5))
    tb.pdrv.line_hook = HdrCorrupt(idx)
    t_b = now_ps()
    await ClockCycles(dut.rx_clk, 4 * W + 300)
    t_last = tb.pdrv.line[idx[-1]][0]
    rises = tb.status.rises("hi_ber", after=t_b)
    falls = [t for t in tb.status.falls("hi_ber", after=t_b) if rises and t > rises[0]]
    lock_falls = tb.status.falls("lock", after=t_a)
    tb.log.info("W=%d cycles | 15 bad: hi_ber=%s | 31 bad: rise %s fall %s | lock falls %s",
                W, hi_a, rises, falls, lock_falls)
    assert not lock_falls, "block lock lost (test assumes it is kept)"
    assert not hi_a, "hi_ber set with only 15 invalid headers"
    assert rises, "hi_ber not set with 31 invalid headers inside 125 us"
    assert falls, "hi_ber never cleared"
    assert falls[0] - rises[0] >= (W - 8) * PERIOD_PS, "hi_ber cleared before a full window"
    assert falls[0] - t_last <= (2 * W + 32) * PERIOD_PS, "hi_ber cleared too late"


@cocotb.test()
async def test_phy_rx_hi_ber_reset_on_unlock(dut):
    """BER-04: the BER monitor state diagram is held in BER_MT_INIT (hi_ber =
    false) while !block_lock (Clause 49 BER monitor; to be confirmed against the
    edition used by the course)."""
    tb = PhyTB(dut, "phy_rx_hi_ber_unlock")
    await tb.reset()
    await tb.wait_lock()
    tb.pdrv.follow_slip = False
    t0 = now_ps()
    tb.pdrv.set_offset(t0, 29)               # line misaligned for good: lock is lost
    t_unlock = await tb.wait_unlock(timeout=2000)
    await ClockCycles(dut.rx_clk, 2 * COUNT_125US + 100)
    lo = t_unlock + 8 * PERIOD_PS
    hi_while_unlocked = tb.status.ever_high("hi_ber", after=lo) and not tb.status.ever_high("lock", after=lo)
    tb.log.info("hi_ber transitions after unlock: %s", tb.status.history["hi_ber"][-4:])
    assert not hi_while_unlocked, "hi_ber asserted while block_lock = false"


@cocotb.test()
async def test_phy_rx_local_fault(dut):
    """RXSM-04: while !block_lock (and while hi_ber) the receive state diagram is
    in RX_INIT and the XGMII carries LBLOCK_R (Local Fault ordered sets)."""
    tb = PhyTB(dut, "phy_rx_lf")
    tb.pdrv.follow_slip = False
    tb.pdrv.set_offset(0, 33)               # misaligned and never corrected
    await tb.reset()
    t0 = now_ps()
    await ClockCycles(dut.rx_clk, 400)
    never_locked = not tb.status.ever_high("lock", after=t0)
    words = [w for t, w in tb.xmon.words if t > t0 + 16 * PERIOD_PS]
    lf_unlocked = sum(w in LF_WORDS for w in words)
    hist = {}
    for w in words:
        hist[fmt_word(w)] = hist.get(fmt_word(w), 0) + 1
    top = sorted(hist.items(), key=lambda kv: -kv[1])[:4]
    tb.log.info("!block_lock: %d/%d words are Local Fault; most frequent:\n%s",
                lf_unlocked, len(words), "\n".join(f"  {n:4d} x {w}" for w, n in top))
    # hi_ber case: realign, lock, then 31 spread header errors
    tb.pdrv.set_offset(now_ps(), 0)
    await tb.wait_lock()
    start = tb.pdrv.index + 8
    tb.pdrv.line_hook = HdrCorrupt(range(start, start + 31 * 5, 5))
    await ClockCycles(dut.rx_clk, 4 * COUNT_125US + 300)
    rises = tb.status.rises("hi_ber", after=t0)
    falls = [t for t in tb.status.falls("hi_ber", after=t0) if rises and t > rises[0]]
    hi_words = []
    if rises and falls:
        lo, hi = rises[0] + 8 * PERIOD_PS, falls[0] - 8 * PERIOD_PS
        hi_words = [w for t, w in tb.xmon.words if lo <= t <= hi]
    lf_hiber = sum(w in LF_WORDS for w in hi_words)
    tb.log.info("hi_ber: %d/%d words are Local Fault", lf_hiber, len(hi_words))
    assert never_locked, "test setup: the receiver locked on a misaligned line"
    assert words and lf_unlocked == len(words), \
        f"only {lf_unlocked}/{len(words)} XGMII words are Local Fault while !block_lock"
    assert hi_words and lf_hiber == len(hi_words), \
        f"only {lf_hiber}/{len(hi_words)} XGMII words are Local Fault while hi_ber"


@cocotb.test()
async def test_phy_rx_error_handling(dut):
    """RXSM-05: payload bit errors and invalid blocks injected in the RX line;
    XGMII RX compared word by word with the RX state diagram fed with the same
    line stream (descrambler error multiplication included)."""
    tb = PhyTB(dut, "phy_rx_errors")
    await tb.reset()
    t_lock = await tb.wait_lock()
    tb.pdrv.follow_slip = False
    rng = tb.rng
    hits = []

    def hook(i, hdr, data):
        if rng.random() < 1 / 150:
            hits.append(i)
            data ^= 1 << rng.randrange(64)          # payload only: keeps lock/hi_ber stable
        return hdr, data

    tb.pdrv.line_hook = hook
    for _ in range(40):
        tb.queue_rx_frames(2)
        _, blk = rng.choice(sequences.invalid_rx_blocks(rng)[2:])     # no header errors
        tb.pdrv.send_blocks([IDLE_BLOCK, blk, IDLE_BLOCK])
    await tb.pdrv.wait_idle(extra_cycles=64)
    tb.log.info("%d payload bit errors injected", len(hits))
    tb.rx_check("phy_rx_errors", t_lock)


# ---------------------------------------------------------------------------
# Loopback: Agent 1 -> TX -> channel -> RX -> Agent 2
# ---------------------------------------------------------------------------

@cocotb.test()
@cocotb.parametrize(("delay", [0, 5]), ("offset", [0, 17]))
async def test_phy_loopback(dut, delay=0, offset=0):
    """E2E-01..03, LAT-01: lock from a bit offset, every frame good end to end,
    XGMII RX stream identical to the XGMII TX stream, PRBS clean, TX + RX
    latency within the 3584 BT budget."""
    name = f"phy_loop_d{delay}_o{offset}"
    tb = PhyTB(dut, name, loopback=True, delay=delay, start_lane="random")
    tb.chan.set_offset(0, offset)
    await tb.reset()
    t_lock = await tb.wait_lock()
    tb.xmon.prbs = PrbsChecker(31)
    for _ in range(200):
        tb.xdrv.send_frame(sequences.random_frame_length(tb.rng))
    await tb.xdrv.wait_idle(extra_cycles=64 + delay)
    fr = compare_frames(name, tb.xdrv.sent_frames, tb.frames_after(t_lock), log=tb.log)
    e2e = compare_streams(name + "_e2e", tb.xdrv.words, tb.xmon.words, lambda w: w != IDLE_WORD,
                          PERIOD_PS, fmt=fmt_word, log=tb.log, start_after=t_lock)
    tx = tb.tx_check(name, strict=False)
    tb.coverage(name, tb.xdrv.sent_frames)
    pcs_cycles = e2e.latency_cycles - delay if e2e.aligned else None
    if pcs_cycles is not None:
        tb.log.info("latency: e2e %s cycles, channel %d, PCS TX+RX %s cycles = %s BT (max %d)",
                    e2e.latency_cycles, delay, pcs_cycles, pcs_cycles * BT_PER_CYCLE,
                    PCS_DELAY_MAX_BT)
    tb.log.info("slips used to align: %d", tb.chan.slips)
    assert fr.ok and e2e.ok and tx.ok
    assert tb.xmon.prbs.locked and tb.xmon.prbs.bit_errors == 0
    assert pcs_cycles * BT_PER_CYCLE <= PCS_DELAY_MAX_BT


@cocotb.test()
async def test_phy_loopback_bit_errors(dut):
    """E2E-04: random line bit errors after lock (~1 per 300 blocks): no corrupted
    frame may be delivered as good (FCS/E detection), lock is kept, PRBS sees them."""
    tb = PhyTB(dut, "phy_loop_ber", loopback=True)
    await tb.reset()
    t_lock = await tb.wait_lock()
    tb.xmon.prbs = PrbsChecker(31)
    rng = tb.rng
    hits = []

    def hook(i, hdr, data):
        if rng.random() < 1 / 300:
            b = rng.randrange(66)
            hits.append(i)
            if b < 2:
                hdr ^= 1 << b
            else:
                data ^= 1 << (b - 2)
        return hdr, data

    tb.chan.line_hook = hook
    for _ in range(300):
        tb.xdrv.send_frame(sequences.random_frame_length(tb.rng))
    await tb.xdrv.wait_idle(extra_cycles=64)
    tb.chan.line_hook = None
    sent, ptr = tb.xdrv.sent_frames, 0
    delivered = flagged = undetected = 0
    for f in tb.frames_after(t_lock):
        if not f.good:
            flagged += 1
            continue
        try:
            ptr = sent.index(f.payload, ptr) + 1
            delivered += 1
        except ValueError:
            undetected += 1
    lost = len(sent) - delivered - flagged
    tb.log.info("bit errors injected %d | frames sent %d, good %d, flagged bad %d, "
                "lost %d, UNDETECTED %d | PRBS errors %d (syncs %d)", len(hits), len(sent),
                delivered, flagged, lost, undetected, tb.xmon.prbs.bit_errors,
                tb.xmon.prbs.syncs)
    assert undetected == 0, "corrupted frame delivered as good"
    assert not tb.status.falls("lock", after=t_lock), "block lock lost"
    assert flagged > 0 and tb.xmon.prbs.bit_errors > 0, "errors were not observable"


# ---------------------------------------------------------------------------
# PRBS31 test-pattern mode (optional in 802.3, implemented by the DUT)
# ---------------------------------------------------------------------------

def prbs31_polarity(bits, n):
    """'normal' / 'inverted' if the n-bit stream follows x^31 + x^28 + 1, else None."""
    y = ((bits ^ (bits << 28) ^ (bits << 31)) >> 31) & ((1 << (n - 31)) - 1)
    if y == 0:
        return "normal"
    if y == (1 << (n - 31)) - 1:
        return "inverted"
    return None


@cocotb.test(skip=not param("PRBS31_EN", 0))
async def test_phy_prbs31(dut):
    """TP-01/02 (49.2.8 / 49.2.12): TX sends PRBS31 on the 66-bit line; the RX
    checker counts no errors on a clean loopback and counts injected errors."""
    tb = PhyTB(dut, "phy_prbs31", loopback=True)
    await tb.reset()
    dut.cfg_tx_prbs31_enable.value = 1
    dut.cfg_rx_prbs31_enable.value = 1
    counts = []

    async def count_errors():
        while True:
            await RisingEdge(dut.rx_clk)
            counts.append(int(dut.rx_error_count.value))

    cocotb.start_soon(count_errors())
    await ClockCycles(dut.tx_clk, 200)
    raw = tb.pmon.raw[-100:]
    bits, n = 0, 0
    for _, (h, d) in raw:
        bits |= (h | (d << 2)) << n
        n += 66
    pol = prbs31_polarity(bits, n)
    c0 = len(counts)
    await ClockCycles(dut.rx_clk, 200)
    clean_errors = sum(counts[c0:])
    rng = tb.rng
    injected = []

    def hook(i, hdr, data):
        if rng.random() < 1 / 20:
            injected.append(i)
            data ^= 1 << rng.randrange(64)
        return hdr, data

    tb.chan.line_hook = hook
    c1 = len(counts)
    await ClockCycles(dut.rx_clk, 400)
    tb.chan.line_hook = None
    await ClockCycles(dut.rx_clk, 20)
    counted = sum(counts[c1:])
    tb.log.info("PRBS31 TX polarity: %s | RX errors clean: %d | injected %d bit errors -> "
                "counted %d", pol, clean_errors, len(injected), counted)
    assert pol is not None, "TX line stream is not PRBS31"
    assert clean_errors == 0
    assert injected and len(injected) <= counted <= 3 * len(injected)
