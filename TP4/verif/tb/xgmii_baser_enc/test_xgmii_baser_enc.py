"""
Unit tests: taxi_xgmii_baser_enc (XGMII -> 64B/66B encoder), black box.

Stimulus : Agent 1 (XgmiiDriver) on xgmii_txd/xgmii_txc.
Checking : PcsMonitor on encoded_tx_* (this block has no scrambler) compared
           with the reference TX state diagram fed with the exact driven words.
Plan IDs : ENC-01..ENC-06, TXSM-01..TXSM-03 (docs/plan_de_verificacion.md).
"""

import cocotb
from cocotb.triggers import ClockCycles

from vip import baser, sequences
from vip.agents import PcsMonitor, StatusMonitor, XgmiiDriver
from vip.coverage import BLOCK_FORMAT_BINS, FRAME_LEN_BINS, Coverage, frame_len_bin
from vip.scoreboard import compare_streams
from vip.tb_utils import PERIOD_PS, make_rng, pulse_reset, report_path, setup_log, start_clock
from vip.xgmii import IDLE_WORD, fmt_word

IDLE_BLOCK = baser.encode(IDLE_WORD)


def not_idle(block):
    return block != IDLE_BLOCK


class TB:
    def __init__(self, dut, tag, **drv_args):
        self.dut = dut
        self.log = setup_log()
        self.rng = make_rng(tag)
        start_clock(dut.clk)
        dut.rst.value = 1
        dut.xgmii_tx_valid.value = 1
        dut.tx_gbx_sync_in.value = 0
        dut.tx_os.value = 0
        dut.tx_os_sig.value = 0
        dut.tx_os_valid.value = 0
        self.drv = XgmiiDriver(dut.xgmii_txd, dut.xgmii_txc, dut.clk, rng=self.rng, **drv_args)
        self.mon = PcsMonitor(dut.encoded_tx_data, dut.encoded_tx_hdr, dut.clk,
                              data_valid=dut.encoded_tx_data_valid, descramble=False)
        self.status = StatusMonitor(dut.clk, tx_bad_block=dut.tx_bad_block)
        self.cov = Coverage(tag)
        self.cov.define("block_format", BLOCK_FORMAT_BINS)
        self.cov.define("t_lane", range(8))
        self.cov.define("s_lane", (0, 4))
        self.cov.define("frame_len", FRAME_LEN_BINS)

    async def reset(self):
        await pulse_reset(self.dut.clk, [self.dut.rst])

    def expected(self):
        sm = baser.TxStateMachine()
        return [(t, sm.step(w)) for t, w in self.drv.words]

    async def finish(self, name, strict=True):
        await self.drv.wait_idle(extra_cycles=16)
        exp = self.expected()
        res = compare_streams(name, exp, self.mon.blocks, not_idle, PERIOD_PS,
                              fmt=baser.fmt_block, log=self.log)
        for _, b in self.mon.blocks:
            kind = baser.block_kind(b)
            self.cov.sample("block_format", kind)
            bt = b[1] & 0xFF
            if kind != "D" and bt in baser.BT_TERM:
                self.cov.sample("t_lane", baser.BT_TERM.index(bt))
            if kind == f"BT_{baser.BT_START_0:02X}":
                self.cov.sample("s_lane", 0)
            elif kind in (f"BT_{baser.BT_START_4:02X}", f"BT_{baser.BT_OS_START:02X}"):
                self.cov.sample("s_lane", 4)
        for p in self.drv.sent_frames:
            self.cov.sample("frame_len", frame_len_bin(len(p)))
        self.log.info(self.cov.report())
        self.cov.dump(report_path(f"cov_{name}.json"))
        self.log.info("tx_bad_block high for %d cycles (taxi status output, informative)",
                      self.status.high_cycles["tx_bad_block"])
        if strict:
            assert res.ok, res.summary()
        return exp, res

    def vector_table(self, name, exp, res, labels):
        """Per-vector report: labels = {word: description} of the inputs to show."""
        rows, bad = [], 0
        for i, (t, w) in enumerate(self.drv.words):
            if w not in labels or i < (res.ie or 0):
                continue
            got = res.observed_for(i, self.mon.blocks)
            ok = got == exp[i][1]
            bad += not ok
            rows.append(f"  {'OK ' if ok else 'BAD'} {labels[w]:<40} in: {fmt_word(w)}\n"
                        f"      expected {baser.fmt_block(exp[i][1])}  "
                        f"observed {baser.fmt_block(got) if got else None}")
        self.log.info("%s per-vector results:\n%s", name, "\n".join(rows))
        return bad


@cocotb.test()
async def test_enc_idle(dut):
    """ENC-01: a continuous /I/ stream is coded as 0x1E blocks with /I/ codes (0x00)."""
    tb = TB(dut, "enc_idle")
    await tb.reset()
    await ClockCycles(dut.clk, 64)
    tail = tb.mon.blocks[-32:]
    bad = [(t, b) for t, b in tail if b != IDLE_BLOCK]
    for t, b in bad[:4]:
        tb.log.error("@%.1f ns observed %s, expected %s", t / 1000, baser.fmt_block(b),
                     baser.fmt_block(IDLE_BLOCK))
    assert len(tail) == 32 and not bad


@cocotb.test()
async def test_enc_block_formats(dut):
    """ENC-02..05: every block format of Figure 49-7 (/T/ on the 8 lanes, /S/ on
    lanes 0 and 4, /Q/ and /Fsig/ ordered sets, reserved codes, back-to-back)."""
    tb = TB(dut, "enc_block_formats")
    await tb.reset()
    tb.drv.send_words(sequences.block_format_words(tb.rng))
    await tb.finish("enc_block_formats")
    holes = tb.cov.holes("block_format")
    assert not holes, f"block formats not exercised: {holes}"


@cocotb.test()
@cocotb.parametrize(
    ("ifg", [12, 1]),
    ("dic", [True, False]),
    ("start_lane", ["any", "random"]),
)
async def test_enc_random_frames(dut, ifg=12, dic=True, start_lane="any"):
    """ENC-06: random frames (PRBS payload, 1..9600 octets, IPG/DIC/start lane
    variations) compared block by block with the reference encoder."""
    name = f"enc_random_ifg{ifg}_{'dic' if dic else 'nodic'}_{start_lane}"
    tb = TB(dut, name, ifg=ifg, dic=dic, start_lane=start_lane)
    await tb.reset()
    for _ in range(150):
        tb.drv.send_frame(sequences.random_frame_length(tb.rng))
    await tb.finish(name)
    assert not tb.cov.holes("t_lane"), tb.cov.holes("t_lane")


@cocotb.test()
async def test_enc_invalid_xgmii(dut):
    """TXSM-01/02: words that are not a valid block (T_TYPE = E), both between
    frames (TX_C) and inside a frame (TX_D), must be sent as EBLOCK_T (TX_E)."""
    tb = TB(dut, "enc_invalid_xgmii")
    await tb.reset()
    labels = {}
    words = [sequences.MARKER_WORD]
    for desc, bad in sequences.invalid_tx_words():
        labels[bad] = desc
        words += [IDLE_WORD, bad, IDLE_WORD]                              # in idle
        words += [sequences.symbol_word(s, tb.rng) for s in "SD"] + [bad] # inside a frame
        words += [sequences.symbol_word(s, tb.rng) for s in "DT"] + [IDLE_WORD] * 2
    tb.drv.send_words(words)
    exp, res = await tb.finish("enc_invalid_xgmii", strict=False)
    bad = tb.vector_table("enc_invalid_xgmii", exp, res, labels)
    assert res.ok, f"{res.summary()} ({bad} invalid-word vectors differ from the TX state diagram)"


@cocotb.test()
async def test_enc_ieee_sequences(dut):
    """TXSM-03: block sequences of the IEEE P802.3df example table; the observed
    block types must match the TX state diagram column of that table."""
    tb = TB(dut, "enc_ieee_sequences")
    await tb.reset()
    seq_words = [sequences.symbol_sequence_words(seq, tb.rng) for seq, _, _ in sequences.IEEE_DF_EXAMPLES]
    tb.drv.send_words([sequences.MARKER_WORD] + [w for ws in seq_words for w in ws])
    exp, res = await tb.finish("enc_ieee_sequences", strict=False)
    base = sequences.find_word(tb.drv.words, sequences.MARKER_WORD) + 1
    lines, fails = [], 0
    for (seq, tx_exp, _), ws in zip(sequences.IEEE_DF_EXAMPLES, seq_words):
        idx = range(base + 4, base + 4 + len(seq))       # skip the 4 leading idles
        got = "".join(baser.block_symbol(b) if b else "?" for b in
                      (res.observed_for(i, tb.mon.blocks) for i in idx))
        model = "".join(baser.block_symbol(exp[i][1]) for i in idx)
        fails += got != tx_exp
        lines.append(f"  in {seq:<8} IEEE {tx_exp:<8} model {model:<8} DUT {got:<8} "
                     f"{'OK' if got == tx_exp else 'DIFF'}")
        base += len(ws)
    tb.log.info("IEEE P802.3df examples (TX):\n%s", "\n".join(lines))
    assert fails == 0 and res.ok, f"{fails} example sequences differ; {res.summary()}"
