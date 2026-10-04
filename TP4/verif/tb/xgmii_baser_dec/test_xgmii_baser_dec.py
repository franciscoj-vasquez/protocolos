"""
Unit tests: taxi_xgmii_baser_dec (64B/66B -> XGMII decoder), black box.

Stimulus : PcsDriver on encoded_rx_* (unscrambled blocks; this block has no
           descrambler), built with the reference encoder or hand-made invalid blocks.
Checking : Agent 2 (XgmiiMonitor: MII -> MAC -> PRBS) on xgmii_rxd/xgmii_rxc and a
           word-by-word comparison with the reference RX state diagram.
Plan IDs : DEC-01..DEC-06, RXSM-01..RXSM-04 (docs/plan_de_verificacion.md).
"""

import cocotb
from cocotb.triggers import ClockCycles

from vip import baser, sequences
from vip.agents import PcsDriver, StatusMonitor, XgmiiMonitor
from vip.coverage import FRAME_LEN_BINS, Coverage, frame_len_bin
from vip.prbs import PrbsGenerator
from vip.scoreboard import compare_frames, compare_streams
from vip.tb_utils import PERIOD_PS, make_rng, pulse_reset, report_path, setup_log, start_clock
from vip.xgmii import IDLE_WORD, XgmiiStreamBuilder, fmt_word

IDLE_BLOCK = baser.encode(IDLE_WORD)


def not_idle(w):
    return w != IDLE_WORD


class TB:
    def __init__(self, dut, tag):
        self.dut = dut
        self.log = setup_log()
        self.rng = make_rng(tag)
        start_clock(dut.clk)
        dut.rst.value = 1
        dut.rx_gbx_sync_in.value = 0
        self.drv = PcsDriver(dut.encoded_rx_data, dut.encoded_rx_hdr, dut.clk,
                             data_valid=dut.encoded_rx_data_valid,
                             hdr_valid=dut.encoded_rx_hdr_valid, scramble=False)
        self.mon = XgmiiMonitor(dut.xgmii_rxd, dut.xgmii_rxc, dut.clk, valid=dut.xgmii_rx_valid)
        self.status = StatusMonitor(dut.clk, rx_bad_block=dut.rx_bad_block,
                                    rx_sequence_error=dut.rx_sequence_error)
        self.cov = Coverage(tag)
        self.cov.define("rx_block", [f"BT_{bt:02X}" for bt in sorted(baser.VALID_BLOCK_TYPES)]
                        + ["D", "SH_00", "SH_11", "EBLOCK"])
        self.cov.define("frame_len", FRAME_LEN_BINS)

    async def reset(self):
        await pulse_reset(self.dut.clk, [self.dut.rst])

    def expected(self):
        sm = baser.RxStateMachine()
        out, prev_t = [], None
        for t, blk in self.drv.sent:
            w = sm.push(blk)
            if w is not None:
                out.append((prev_t, w))
            prev_t = t
        return out

    async def finish(self, name, strict=True):
        await self.drv.wait_idle(extra_cycles=16)
        exp = self.expected()
        res = compare_streams(name, exp, self.mon.words, not_idle, PERIOD_PS, fmt=fmt_word,
                              log=self.log)
        for _, b in self.drv.sent:
            self.cov.sample("rx_block", baser.block_kind(b))   # undefined types -> <other>
        self.log.info(self.cov.report())
        self.cov.dump(report_path(f"cov_{name}.json"))
        self.log.info("taxi status outputs (informative): rx_bad_block high %d cycles, "
                      "rx_sequence_error high %d cycles", self.status.high_cycles["rx_bad_block"],
                      self.status.high_cycles["rx_sequence_error"])
        if strict:
            assert res.ok, res.summary()
        return exp, res

    def vector_table(self, name, exp, res, labels):
        """labels = {block: description}; report expected vs observed word per vector."""
        rows, bad = [], 0
        for i, (t, blk) in enumerate(self.drv.sent):
            if blk not in labels or i >= len(exp):
                continue
            # exp[i] is the RX output for drv.sent[i] (one block of look-ahead)
            got = res.observed_for(i, self.mon.words)
            ok = got == exp[i][1]
            bad += not ok
            rows.append(f"  {'OK ' if ok else 'BAD'} {labels[blk]:<36} in: {baser.fmt_block(blk)}\n"
                        f"      expected {fmt_word(exp[i][1])}\n"
                        f"      observed {fmt_word(got) if got else None}")
        self.log.info("%s per-vector results:\n%s", name, "\n".join(rows))
        return bad


def marker_block():
    return baser.encode(sequences.MARKER_WORD)


@cocotb.test()
async def test_dec_idle(dut):
    """DEC-01: idle control blocks decode to eight /I/ characters."""
    tb = TB(dut, "dec_idle")
    await tb.reset()
    await ClockCycles(dut.clk, 64)
    tail = tb.mon.words[-32:]
    bad = [(t, w) for t, w in tail if w != IDLE_WORD]
    for t, w in bad[:4]:
        tb.log.error("@%.1f ns observed %s", t / 1000, fmt_word(w))
    assert len(tail) == 32 and not bad


@cocotb.test()
async def test_dec_block_formats(dut):
    """DEC-02..04: every valid block format decodes to the right XGMII characters."""
    tb = TB(dut, "dec_block_formats")
    await tb.reset()
    tb.drv.send_words(sequences.block_format_words(tb.rng))
    await tb.finish("dec_block_formats")


@cocotb.test()
@cocotb.parametrize(("ifg", [12, 1]), ("start_lane", ["any", "random"]))
async def test_dec_random_frames(dut, ifg=12, start_lane="any"):
    """DEC-05: random frames encoded by the reference model; word-exact comparison
    plus MAC-level checks (preamble, SFD, FCS) and PRBS payload check (Agent 2)."""
    name = f"dec_random_ifg{ifg}_{start_lane}"
    tb = TB(dut, name)
    await tb.reset()
    gen = PrbsGenerator(31, state=7)
    builder = XgmiiStreamBuilder(ifg=ifg, dic=True, start_lane=start_lane, rng=tb.rng)
    payloads = []
    for _ in range(150):
        p = gen.bytes(sequences.random_frame_length(tb.rng))
        payloads.append(p)
        builder.add_frame(p)
        tb.cov.sample("frame_len", frame_len_bin(len(p)))
    tb.drv.send_words(builder.drain())
    await tb.finish(name)
    fr = compare_frames(name, payloads, tb.mon.frames, log=tb.log)
    assert fr.ok
    assert tb.mon.prbs.locked and tb.mon.prbs.bit_errors == 0, \
        f"PRBS: locked={tb.mon.prbs.locked} errors={tb.mon.prbs.bit_errors}"


@cocotb.test()
async def test_dec_invalid_blocks(dut):
    """DEC-06 / RXSM-01: invalid sync headers, invalid control/O codes; between
    frames and inside a frame. Expected: EBLOCK_R (eight /E/) per R_TYPE = E."""
    tb = TB(dut, "dec_invalid_blocks")
    await tb.reset()
    labels = {}
    blocks = [marker_block()]
    enc = baser.encode
    for desc, bad in sequences.invalid_rx_blocks(tb.rng):
        labels[bad] = desc
        blocks += [IDLE_BLOCK, bad, IDLE_BLOCK]                                       # in idle
        blocks += [enc(sequences.symbol_word(s, tb.rng)) for s in "SD"] + [bad]       # in frame
        blocks += [enc(sequences.symbol_word(s, tb.rng)) for s in "DT"] + [IDLE_BLOCK] * 2
    tb.drv.send_blocks(blocks)
    exp, res = await tb.finish("dec_invalid_blocks", strict=False)
    bad = tb.vector_table("dec_invalid_blocks", exp, res, labels)
    assert res.ok, f"{res.summary()} ({bad} vectors differ from the RX state diagram)"


@cocotb.test()
async def test_dec_invalid_block_types(dut):
    """DEC-06: the 241 block type values not defined in Figure 49-7 (sync = 10)
    must be decoded as errors (EBLOCK_R)."""
    tb = TB(dut, "dec_invalid_block_types")
    await tb.reset()
    labels = {}
    blocks = [marker_block()]
    for bt in sequences.invalid_block_types():
        blk = (baser.SH_CTRL, bt | (tb.rng.getrandbits(56) << 8))
        labels[blk] = f"block type 0x{bt:02X}"
        blocks += [IDLE_BLOCK, blk, IDLE_BLOCK]
    tb.drv.send_blocks(blocks)
    exp, res = await tb.finish("dec_invalid_block_types", strict=False)
    bad = tb.vector_table("dec_invalid_block_types", exp, res, labels)
    assert res.ok, f"{res.summary()} ({bad} block types not reported as errors)"


@cocotb.test()
async def test_dec_ieee_sequences(dut):
    """RXSM-02/03: IEEE P802.3df example sequences (includes the R_TYPE_NEXT
    check of terminate blocks); observed types vs the RX state diagram column."""
    tb = TB(dut, "dec_ieee_sequences")
    await tb.reset()
    seq_blocks = [[baser.encode(w) for w in sequences.symbol_sequence_words(seq, tb.rng)]
                  for seq, _, _ in sequences.IEEE_DF_EXAMPLES]
    tb.drv.send_blocks([marker_block()] + [b for bs in seq_blocks for b in bs])
    exp, res = await tb.finish("dec_ieee_sequences", strict=False)
    base = next(i for i, (_, b) in enumerate(tb.drv.sent) if b == marker_block()) + 1
    lines, fails = [], 0
    for (seq, _, rx_exp), bs in zip(sequences.IEEE_DF_EXAMPLES, seq_blocks):
        idx = range(base + 4, base + 4 + len(seq))
        got = "".join(baser.word_symbol(w) if w else "?" for w in
                      (res.observed_for(i, tb.mon.words) for i in idx))
        model = "".join(baser.word_symbol(exp[i][1]) for i in idx)
        fails += got != rx_exp
        lines.append(f"  in {seq:<8} IEEE {rx_exp:<8} model {model:<8} DUT {got:<8} "
                     f"{'OK' if got == rx_exp else 'DIFF'}")
        base += len(bs)
    tb.log.info("IEEE P802.3df examples (RX):\n%s", "\n".join(lines))
    assert fails == 0 and res.ok, f"{fails} example sequences differ; {res.summary()}"
