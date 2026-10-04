"""
cocotb agents (they need a running simulation).

  XgmiiDriver    Agent 1: PRBS -> MII. Drives xgmii_txd/xgmii_txc.
  XgmiiMonitor   Agent 2: MII -> MAC -> PRBS. Samples xgmii_rxd/xgmii_rxc,
                 rebuilds frames (preamble/SFD/FCS) and checks the PRBS payload.
  PcsDriver      drives a 66-bit block port (serdes_rx_* or encoded_rx_*) with
                 reference-encoded blocks: scrambling, line error hook and a
                 SERDES bit-slip emulation.
  PcsMonitor     samples a 66-bit block port (serdes_tx_* or encoded_tx_*) and
                 descrambles it with the reference (self-synchronizing) descrambler.
  Channel        PCS link TX port -> RX port ("PCS out -> PCS in" of the class
                 sketch): loopback or full duplex, delay, impairments, bit slip.
  StatusMonitor  transitions of 1-bit status outputs.

Sampling convention: monitors sample after RisingEdge + ReadOnly (settled
post-edge values); drivers write right after RisingEdge, so the DUT samples the
value on the next edge. Every agent logs (time_ps, value) per clock so the
scoreboards can replay the exact stimulus through the reference model.
"""

import logging
from collections import deque

import cocotb
from cocotb.triggers import ReadOnly, RisingEdge
from cocotb.utils import get_sim_time

from . import baser
from .prbs import PrbsChecker, PrbsGenerator
from .xgmii import IDLE_WORD, XgmiiFrameParser, XgmiiStreamBuilder


def now_ps():
    return int(get_sim_time("ps"))


def _logger(handle, name):
    return logging.getLogger("cocotb." + (name or getattr(handle, "_path", "agent")))


class XgmiiDriver:
    """Agent 1 (PRBS -> MII).

    Payloads come from a PRBS generator (the arrow MII -> PRBS of the sketch: the
    MII side pulls octets when it builds a frame). Frames get preamble, SFD and
    FCS and are placed on the bus with a legal IPG (see XgmiiStreamBuilder).
    Raw words can be queued for directed tests."""

    def __init__(self, txd, txc, clock, valid=None, ifg=12, dic=True, start_lane="any",
                 prbs_order=31, seed=1, fcs=True, rng=None, name=None):
        self.log = _logger(txd, name)
        self.txd, self.txc, self.clock = txd, txc, clock
        self.builder = XgmiiStreamBuilder(ifg=ifg, dic=dic, start_lane=start_lane, rng=rng)
        self.prbs = PrbsGenerator(prbs_order, state=seed)
        self.fcs = fcs
        self.sent_frames = []      # payloads, in order
        self.words = []            # (time_ps, word) driven every clock
        txd.value = IDLE_WORD[0]
        txc.value = IDLE_WORD[1]
        if valid is not None:
            valid.value = 1
        self._task = cocotb.start_soon(self._run())

    def send_frame(self, length=None, payload=None):
        if payload is None:
            payload = self.prbs.bytes(length)
        payload = bytes(payload)
        self.builder.add_frame(payload, self.fcs)
        self.sent_frames.append(payload)
        return payload

    def send_words(self, words):
        self.builder.add_words(words)

    @property
    def idle(self):
        return not self.builder.busy()

    async def wait_idle(self, extra_cycles=0):
        while self.builder.busy():
            await RisingEdge(self.clock)
        for _ in range(extra_cycles):
            await RisingEdge(self.clock)

    async def _run(self):
        while True:
            await RisingEdge(self.clock)
            w = self.builder.next_word()
            self.txd.value = w[0]
            self.txc.value = w[1]
            self.words.append((now_ps(), w))


class XgmiiMonitor:
    """Agent 2 (MII -> MAC -> PRBS)."""

    def __init__(self, rxd, rxc, clock, valid=None, fcs=True, prbs_order=31,
                 check_prbs=True, name=None):
        self.log = _logger(rxd, name)
        self.rxd, self.rxc, self.clock, self.valid = rxd, rxc, clock, valid
        self.parser = XgmiiFrameParser(has_fcs=fcs)
        self.prbs = PrbsChecker(prbs_order)
        self.check_prbs = check_prbs
        self.words = []            # (time_ps, word)
        self._task = cocotb.start_soon(self._run())

    @property
    def frames(self):
        return self.parser.frames

    async def wait_frames(self, count, timeout_cycles=200000):
        for _ in range(timeout_cycles):
            if len(self.parser.frames) >= count:
                return True
            await RisingEdge(self.clock)
        return len(self.parser.frames) >= count

    async def _run(self):
        while True:
            await RisingEdge(self.clock)
            await ReadOnly()
            if self.valid is not None and not int(self.valid.value):
                continue
            t = now_ps()
            w = (int(self.rxd.value), int(self.rxc.value))
            self.words.append((t, w))
            n = len(self.parser.frames)
            self.parser.push(w, t)
            if self.check_prbs:
                for f in self.parser.frames[n:]:
                    if f.complete:
                        self.prbs.push(f.payload)


class PcsMonitor:
    """Samples a 66-bit block port; `blocks` holds descrambled payloads."""

    def __init__(self, data, hdr, clock, data_valid=None, descramble=True, name=None):
        self.log = _logger(data, name)
        self.data, self.hdr, self.clock, self.data_valid = data, hdr, clock, data_valid
        self.descramble = descramble
        self._desc = baser.Descrambler()
        self.raw = []              # (time_ps, (hdr, data)) as seen on the port
        self.blocks = []           # (time_ps, (hdr, payload)) after descrambling
        self._task = cocotb.start_soon(self._run())

    async def _run(self):
        while True:
            await RisingEdge(self.clock)
            await ReadOnly()
            if self.data_valid is not None and not int(self.data_valid.value):
                continue
            t = now_ps()
            hdr, data = int(self.hdr.value), int(self.data.value)
            self.raw.append((t, (hdr, data)))
            p = self._desc.descramble(data) if self.descramble else data
            self.blocks.append((t, (hdr, p)))


class _LineEmulation:
    """Line impairments shared by PcsDriver and Channel.

    line_hook(index, hdr, data) -> (hdr, data): applied to the scrambled 66-bit
    block (bit errors, bad sync headers...).
    bit_offset: misalignment (0..65 bits) of the 66-bit window seen by the RX;
    each rising edge of the DUT's bitslip output moves it by one bit (edge
    triggered, so the result does not depend on the pulse width)."""

    def _line_init(self, slip):
        self.slip = slip
        self.bit_offset = 0
        self.follow_slip = True
        self.slips = 0
        self.slip_log = []         # (time_ps, bit_offset after the slip)
        self.line_hook = None
        self.line = []             # (time_ps, (hdr, data)) before bit offset
        self._prev66 = 0
        self._slip_prev = 0
        self._index = 0

    @property
    def index(self):
        """Index of the next block to be sent (for line_hook scheduling)."""
        return self._index

    def set_offset(self, t, offset):
        self.bit_offset = offset % 66
        self.slip_log.append((t, self.bit_offset))

    def _line_step(self, t, hdr, data):
        if self.slip is not None:
            s = int(self.slip.value)
            if s and not self._slip_prev and self.follow_slip:
                self.bit_offset = (self.bit_offset + 1) % 66
                self.slips += 1
                self.slip_log.append((t, self.bit_offset))
            self._slip_prev = s
        if self.line_hook is not None:
            hdr, data = self.line_hook(self._index, hdr, data)
        self._index += 1
        self.line.append((t, (hdr, data)))
        cur = ((data & baser.M64) << 2) | (hdr & 3)
        if self.bit_offset:
            v = ((self._prev66 | (cur << 66)) >> (66 - self.bit_offset)) & baser.M66
            hdr, data = v & 3, v >> 2
        self._prev66 = cur
        return hdr, data


class PcsDriver(_LineEmulation):
    """Drives a 66-bit block port from a queue of (unscrambled) blocks; sends
    idle control blocks when the queue is empty."""

    def __init__(self, data, hdr, clock, data_valid=None, hdr_valid=None, slip=None,
                 scramble=True, name=None):
        self.log = _logger(data, name)
        self.data, self.hdr, self.clock = data, hdr, clock
        self.scramble = scramble
        self.scrambler = baser.Scrambler()
        self.queue = deque()
        self.idle_block = baser.encode(IDLE_WORD)
        self.sent = []             # (time_ps, block) before scrambling
        self._line_init(slip)
        data.value = 0
        hdr.value = 0
        for v in (data_valid, hdr_valid):
            if v is not None:
                v.value = 1
        self._task = cocotb.start_soon(self._run())

    def send_blocks(self, blocks):
        self.queue.extend(blocks)

    def send_words(self, words):
        """Stateless ENCODE of each word (type E words become EBLOCK_T)."""
        self.queue.extend(baser.encode(w) for w in words)

    @property
    def idle(self):
        return not self.queue

    async def wait_idle(self, extra_cycles=0):
        while self.queue:
            await RisingEdge(self.clock)
        for _ in range(extra_cycles):
            await RisingEdge(self.clock)

    async def _run(self):
        while True:
            await RisingEdge(self.clock)
            t = now_ps()
            blk = self.queue.popleft() if self.queue else self.idle_block
            self.sent.append((t, blk))
            hdr, p = blk
            data = self.scrambler.scramble(p) if self.scramble else p
            hdr, data = self._line_step(t, hdr, data)
            self.hdr.value = hdr
            self.data.value = data


class Channel(_LineEmulation):
    """Forwards the 66-bit stream of a TX port to an RX port, clocked by the TX
    clock (the RX of the link partner runs on that clock, as a recovered clock
    would). `link_up = False` drives all-zero blocks (invalid headers = no signal)."""

    def __init__(self, tx_data, tx_hdr, tx_clock, rx_data, rx_hdr, rx_slip=None,
                 delay=0, tx_valid=None, name=None):
        self.log = _logger(tx_data, name)
        self.tx_data, self.tx_hdr, self.tx_clock = tx_data, tx_hdr, tx_clock
        self.rx_data, self.rx_hdr, self.tx_valid = rx_data, rx_hdr, tx_valid
        self.delay = max(0, int(delay))
        self.link_up = True
        self._dl = deque()
        self._line_init(rx_slip)
        rx_data.value = 0
        rx_hdr.value = 0
        self._task = cocotb.start_soon(self._run())

    async def _run(self):
        while True:
            await RisingEdge(self.tx_clock)
            t = now_ps()
            self._dl.append((int(self.tx_hdr.value), int(self.tx_data.value)))
            hdr, data = self._dl.popleft() if len(self._dl) > self.delay else (0, 0)
            if not self.link_up:
                hdr, data = 0, 0
            hdr, data = self._line_step(t, hdr, data)
            self.rx_hdr.value = hdr
            self.rx_data.value = data


class StatusMonitor:
    """Transitions and high-cycle counts of 1-bit outputs: StatusMonitor(clk, lock=dut.rx_block_lock, ...)."""

    def __init__(self, clock, **signals):
        self.clock = clock
        self.signals = signals
        self.value = {n: None for n in signals}
        self.history = {n: [] for n in signals}       # (time_ps, value)
        self.high_cycles = {n: 0 for n in signals}
        self._task = cocotb.start_soon(self._run())

    def rises(self, name, after=0):
        return [t for t, v in self.history[name] if v and t >= after]

    def falls(self, name, after=0):
        return [t for t, v in self.history[name] if not v and t >= after]

    def value_at(self, name, t):
        v = None
        for tt, vv in self.history[name]:
            if tt > t:
                break
            v = vv
        return v

    def ever_high(self, name, after=0):
        """High at time `after` or at any later sample."""
        return self.value_at(name, after) == 1 or bool(self.rises(name, after))

    async def _run(self):
        while True:
            await RisingEdge(self.clock)
            await ReadOnly()
            t = now_ps()
            for n, h in self.signals.items():
                v = int(h.value)
                self.high_cycles[n] += v
                if v != self.value[n]:
                    self.value[n] = v
                    self.history[n].append((t, v))
