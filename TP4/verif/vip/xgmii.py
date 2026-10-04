"""
XGMII definitions and simulator-independent helpers (IEEE 802.3 Clause 46).

Word representation used by the whole VIP: ``(data, ctrl)``
  data  64-bit int, lane k in bits [8k+7:8k] (lane 0 = first octet on the wire)
  ctrl   8-bit int, bit k = 1 when lane k carries a control character
This is the 64-bit, single-data-rate XGMII-like bus of the DUT
(xgmii_txd/xgmii_txc, xgmii_rxd/xgmii_rxc).

A "char" is a tuple ``(octet, is_ctrl)``.
"""

import random
import zlib
from collections import Counter, deque
from dataclasses import dataclass, field

# Control characters (Table 46-3 / Table 49-1)
IDLE = 0x07      # /I/
LPI = 0x06       # /LI/ (EEE)
START = 0xFB     # /S/
TERM = 0xFD      # /T/
ERROR = 0xFE     # /E/
SEQ_OS = 0x9C    # /Q/  sequence ordered set
SIG_OS = 0x5C    # /Fsig/ signal ordered set
RESERVED = (0x1C, 0x3C, 0x7C, 0xBC, 0xDC, 0xF7)   # reserved0..5

PREAMBLE = 0x55
SFD = 0xD5

# Link fault signaling ordered sets (Table 46-5): /Q/ + three data octets
LOCAL_FAULT = (0x00, 0x00, 0x01)
REMOTE_FAULT = (0x00, 0x00, 0x02)

CHAR_NAMES = {IDLE: "I", LPI: "LI", START: "S", TERM: "T", ERROR: "E",
              SEQ_OS: "Q", SIG_OS: "Fsig"}
CHAR_NAMES.update({c: f"R{i}" for i, c in enumerate(RESERVED)})


def C(octet):
    """Control char."""
    return (octet & 0xFF, 1)


def D(octet):
    """Data char."""
    return (octet & 0xFF, 0)


def chars(w):
    """(data, ctrl) word -> list of 8 chars, lane 0 first."""
    data, ctrl = w
    return [((data >> (8 * k)) & 0xFF, (ctrl >> k) & 1) for k in range(8)]


def word(char_list):
    """List of 8 chars -> (data, ctrl) word."""
    assert len(char_list) == 8, char_list
    data = 0
    ctrl = 0
    for k, (b, c) in enumerate(char_list):
        data |= (b & 0xFF) << (8 * k)
        ctrl |= (1 if c else 0) << k
    return data, ctrl


IDLE_WORD = word([C(IDLE)] * 8)
ERROR_WORD = word([C(ERROR)] * 8)
LPI_WORD = word([C(LPI)] * 8)


def os_chars(value=LOCAL_FAULT, sig=False):
    """Ordered set column: /Q/ (or /Fsig/) followed by three data octets."""
    return [C(SIG_OS if sig else SEQ_OS)] + [D(b) for b in value]


def os_word(col0=None, col1=None):
    """Word with ordered sets (tuples of 3 octets, or None for 4 idles) per column."""
    c0 = os_chars(col0) if col0 is not None else [C(IDLE)] * 4
    c1 = os_chars(col1) if col1 is not None else [C(IDLE)] * 4
    return word(c0 + c1)


def fmt_char(ch):
    b, c = ch
    if c:
        return "/" + CHAR_NAMES.get(b, f"?{b:02X}") + "/"
    return f"{b:02X}"


def fmt_word(w):
    """Human readable word: lanes 0..7 left to right (wire order) + raw values."""
    data, ctrl = w
    return " ".join(fmt_char(x) for x in chars(w)) + f"  [d={data:016X} c={ctrl:02X}]"


# --------------------------------------------------------------------------
# Frames
# --------------------------------------------------------------------------

def fcs_bytes(payload):
    """IEEE 802.3 CRC-32 (FCS), transmitted least significant octet first."""
    return (zlib.crc32(bytes(payload)) & 0xFFFFFFFF).to_bytes(4, "little")


def frame_chars(payload, add_fcs=True):
    """/S/ + 6 preamble + SFD + payload (+ FCS) + /T/ as a char list.

    On XGMII the /S/ replaces the first preamble octet (46.3.1.2)."""
    body = bytes(payload) + (fcs_bytes(payload) if add_fcs else b"")
    return ([C(START)] + [D(PREAMBLE)] * 6 + [D(SFD)]
            + [D(b) for b in body] + [C(TERM)])


def pack_chars(char_list, start_lane=0, pre=None):
    """Place a char list into words starting at `start_lane` of the first word.

    `pre` are the chars of lanes 0..start_lane-1 of the first word (idles by
    default); the tail of the last word is padded with idles."""
    pre = list(pre) if pre is not None else [C(IDLE)] * start_lane
    assert len(pre) == start_lane
    seq = pre + list(char_list)
    seq += [C(IDLE)] * (-len(seq) % 8)
    return [word(seq[i:i + 8]) for i in range(0, len(seq), 8)]


class XgmiiStreamBuilder:
    """MII part of Agent 1: frames (and raw words) -> one XGMII word per clock.

    * /S/ is only placed on lane 0 or lane 4 (46.3.1.2, 64-bit column alignment).
    * The inter-packet gap, counted from /T/ (inclusive) to the next /S/, is at
      least `ifg` octets; with `dic=True` the deficit idle count of 46.3.1.4 is
      used: the gap may be shortened by up to 3 octets to align /S/, keeping the
      long-term average at `ifg`.
    * /S/ never shares a word with the previous /T/ (no 64B/66B block exists for
      that, see Figure 49-7).
    * start_lane: "any" (earliest legal), "lane0", "lane4" or "random".
    """

    def __init__(self, ifg=12, dic=True, start_lane="any", rng=None):
        self.ifg = ifg
        self.dic = dic
        self.start_lane = start_lane
        self.rng = rng or random.Random(0)
        self._items = deque()
        self._fifo = deque()
        self._wr = 0                  # absolute index of the next char appended
        self._last_t = -(1 << 30)     # absolute index of the last /T/ appended
        self._deficit = 0
        self.gaps = []                # IPG (octets) actually used before each frame

    # -- queueing --------------------------------------------------------
    def add_frame(self, payload, add_fcs=True):
        self._items.append(("frame", bytes(payload), add_fcs))

    def add_words(self, words):
        self._items.append(("words", list(words)))

    def busy(self):
        """True while queued frames/words have not been fully emitted."""
        if self._items:
            return True
        return any(not (c and b == IDLE) for b, c in self._fifo)

    # -- generation ------------------------------------------------------
    def next_word(self):
        self._refill()
        while len(self._fifo) < 8:
            self._append(C(IDLE))
        return word([self._fifo.popleft() for _ in range(8)])

    def drain(self):
        """Emit words until everything queued has been sent (pure use, no sim)."""
        out = []
        while self.busy():
            out.append(self.next_word())
        return out

    def _append(self, ch):
        self._fifo.append(ch)
        self._wr += 1

    def _refill(self):
        while len(self._fifo) < 8 and self._items:
            item = self._items.popleft()
            if item[0] == "frame":
                _, payload, add_fcs = item
                s = self._start_position()
                if self._last_t >= 0:
                    self.gaps.append(s - self._last_t)
                while self._wr < s:
                    self._append(C(IDLE))
                for ch in frame_chars(payload, add_fcs):
                    self._append(ch)
                self._last_t = self._wr - 1
            else:
                while self._wr % 8:
                    self._append(C(IDLE))
                for w in item[1]:
                    for ch in chars(w):
                        if ch == (TERM, 1):
                            self._last_t = self._wr
                        self._append(ch)

    def _start_position(self):
        t = self._last_t
        word_after_t = (t // 8 + 1) * 8 if t >= 0 else 0
        lo = max(self._wr, word_after_t)
        nominal = max(lo, t + self.ifg)
        idle_link = nominal > t + self.ifg     # gap already longer than ifg
        r = nominal % 4
        if r == 0:
            s = nominal
        elif (self.dic and not idle_link and self._deficit + r <= 3
              and nominal - r >= lo):
            s = nominal - r                     # shorten the gap (DIC)
            self._deficit += r
        else:
            s = nominal + 4 - r                 # stretch the gap
            self._deficit = max(0, self._deficit - (4 - r)) if self.dic else 0
        if idle_link:
            self._deficit = 0
        if self.start_lane == "lane0" and s % 8:
            s += 4
        elif self.start_lane == "lane4" and s % 8 != 4:
            s += 4
        elif self.start_lane == "random" and self.rng.random() < 0.5:
            s += 4
        return s


# --------------------------------------------------------------------------
# MAC-level receive view (Agent 2 "MAC" block)
# --------------------------------------------------------------------------

@dataclass
class RxFrame:
    raw: bytearray            # octets after /S/ up to (not including) /T/
    start_lane: int
    t_start: int = 0
    t_end: int = 0
    errors: list = field(default_factory=list)
    has_fcs: bool = True
    complete: bool = False    # ended with /T/

    @property
    def payload(self):
        body = bytes(self.raw[7:])
        return body[:-4] if self.has_fcs and len(body) >= 4 else body

    @property
    def fcs_ok(self):
        if not self.has_fcs:
            return True
        body = bytes(self.raw[7:])
        return len(body) >= 4 and fcs_bytes(body[:-4]) == body[-4:]

    @property
    def good(self):
        return self.complete and not self.errors and self.fcs_ok


class XgmiiFrameParser:
    """Rebuilds frames from an XGMII word stream (RS + MAC receive view).

    A frame starts at /S/ (lane 0 or 4) and ends at /T/. Any other control
    character inside a frame is recorded as an error; /E/ keeps the frame open
    (RX_ER-like), any other control character truncates it. Preamble/SFD and FCS
    are checked when the frame is closed."""

    def __init__(self, has_fcs=True):
        self.has_fcs = has_fcs
        self.frames = []
        self.ordered_sets = []    # (t, lane, (o1, o2, o3), is_signal_os)
        self.stats = Counter()
        self._cur = None

    def push(self, w, t=0):
        ch = chars(w)
        self.stats["words"] += 1
        if self._cur is None:
            for k in (0, 4):
                b, c = ch[k]
                if c and b in (SEQ_OS, SIG_OS) and not any(x[1] for x in ch[k + 1:k + 4]):
                    self.ordered_sets.append((t, k, tuple(x[0] for x in ch[k + 1:k + 4]),
                                              b == SIG_OS))
        os_lanes = set()
        for k in (0, 4):
            if ch[k][1] and ch[k][0] in (SEQ_OS, SIG_OS):
                os_lanes.update(range(k + 1, k + 4))
        for k, (b, c) in enumerate(ch):
            cur = self._cur
            if cur is None:
                if c and b == START:
                    self._cur = RxFrame(bytearray(), k, t_start=t, has_fcs=self.has_fcs)
                    if k not in (0, 4):
                        self._cur.errors.append("start_lane")
                elif c and b == ERROR:
                    self.stats["error_outside_frame"] += 1
                elif not c and k not in os_lanes:
                    self.stats["data_outside_frame"] += 1
            elif not c:
                cur.raw.append(b)
            elif b == TERM:
                cur.complete = True
                self._close(t)
            elif b == ERROR:
                cur.errors.append("E_in_frame")
            else:
                cur.errors.append(f"ctrl_{CHAR_NAMES.get(b, hex(b))}_in_frame")
                self._close(t)
                if b == START:
                    self._cur = RxFrame(bytearray(), k, t_start=t, has_fcs=self.has_fcs)

    def _close(self, t):
        f = self._cur
        self._cur = None
        f.t_end = t
        if len(f.raw) < 7 or any(x != PREAMBLE for x in f.raw[:6]) or f.raw[6] != SFD:
            f.errors.append("preamble_sfd")
        if f.complete and not f.fcs_ok:
            f.errors.append("fcs")
        self.stats["frames"] += 1
        self.stats["frames_good" if f.good else "frames_bad"] += 1
        self.frames.append(f)
