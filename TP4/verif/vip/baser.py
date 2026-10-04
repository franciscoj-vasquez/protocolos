"""
Reference model of the 10GBASE-R PCS (IEEE 802.3 Clause 49).

Written from the standard (Table 49-1, Figure 49-7, 49.2.6, 49.2.13 state
diagrams), independently of the DUT sources and of the taxi/cocotbext models, so
that the scoreboard does not share the designer's interpretation of the spec.

66-bit block representation: ``(hdr, payload)``
  payload  64-bit int, bit i = block bit i+2 (bit 0 = first payload bit on the
           line); octet j of the block (D0..D7 / block type) is bits [8j+7:8j].
  hdr      2-bit sync header, bit 0 = block bit 0 (first bit on the line). The
           standard's data header "01" is therefore the integer 0b10 and the
           control header "10" is 0b01 (same convention as the DUT bus with
           BIT_REVERSE=0: serdes_*_hdr[0] is the first transmitted bit).

XGMII words are ``(data, ctrl)`` tuples (see vip.xgmii).
"""

from .xgmii import (C, D, ERROR, IDLE, LOCAL_FAULT, LPI, SEQ_OS, SIG_OS, START, TERM,
                    chars, os_chars, word)

M64 = (1 << 64) - 1
M58 = (1 << 58) - 1
M66 = (1 << 66) - 1

SH_DATA = 0b10   # "01"
SH_CTRL = 0b01   # "10"

# Table 49-1: XGMII control character -> 7-bit 10GBASE-R control code
CODE = {IDLE: 0x00, LPI: 0x06, ERROR: 0x1E,
        0x1C: 0x2D, 0x3C: 0x33, 0x7C: 0x4B, 0xBC: 0x55, 0xDC: 0x66, 0xF7: 0x78}
CODE_INV = {v: k for k, v in CODE.items()}
# O codes of the ordered set characters
OCODE = {SEQ_OS: 0x0, SIG_OS: 0xF}
OCODE_INV = {v: k for k, v in OCODE.items()}

# Figure 49-7 block type field values
BT_CTRL = 0x1E       # C0 C1 C2 C3 C4 C5 C6 C7
BT_OS_4 = 0x2D       # C0 C1 C2 C3 O4 D5 D6 D7
BT_START_4 = 0x33    # C0 C1 C2 C3 S4 D5 D6 D7
BT_OS_START = 0x66   # O0 D1 D2 D3 S4 D5 D6 D7
BT_OS_04 = 0x55      # O0 D1 D2 D3 O4 D5 D6 D7
BT_START_0 = 0x78    # S0 D1 D2 D3 D4 D5 D6 D7
BT_OS_0 = 0x4B       # O0 D1 D2 D3 C4 C5 C6 C7
BT_TERM = (0x87, 0x99, 0xAA, 0xB4, 0xCC, 0xD2, 0xE1, 0xFF)   # index = lane of /T/
VALID_BLOCK_TYPES = frozenset((BT_CTRL, BT_OS_4, BT_START_4, BT_OS_START, BT_OS_04,
                               BT_START_0, BT_OS_0) + BT_TERM)

_LANES_1_3 = 0x00000000FFFFFF00
_LANES_5_7 = 0xFFFFFF0000000000


# --------------------------------------------------------------------------
# Transmit side: T_TYPE and ENCODE (49.2.13.2.3, Figure 49-7)
# --------------------------------------------------------------------------

def _c7(ch):
    """Valid control character with a 7-bit code (i.e. not /O/, /S/ nor /T/)."""
    b, c = ch
    return bool(c) and b in CODE


def _os_col(ch, col):
    """Column `col` (lanes 4col..4col+3) is a valid ordered set: /O/ + 3 data."""
    b, c = ch[4 * col]
    return bool(c) and b in OCODE and not any(x[1] for x in ch[4 * col + 1:4 * col + 4])


def t_type(w):
    """T_TYPE(tx_raw): 'C', 'S', 'T', 'D', 'LI' or 'E'."""
    ch = chars(w)
    ctl = [c for _, c in ch]
    if not any(ctl):
        return "D"
    if all(c and b == LPI for b, c in ch):
        return "LI"
    # C a) eight valid control characters other than /O/ /S/ /T/ /LI/ /E/
    if all(_c7(x) and x[0] not in (LPI, ERROR) for x in ch):
        return "C"
    os0, os1 = _os_col(ch, 0), _os_col(ch, 1)
    c0 = all(_c7(x) for x in ch[:4])
    c1 = all(_c7(x) for x in ch[4:])
    # C b) one ordered set + four control characters, c) two ordered sets
    if (os0 and os1) or (os0 and c1) or (c0 and os1):
        return "C"
    # S: /S/ in lane 0, or in lane 4 after four control characters / an ordered set
    if ch[0] == (START, 1) and not any(ctl[1:]):
        return "S"
    if ch[4] == (START, 1) and not any(ctl[5:]) and (c0 or os0):
        return "S"
    # T: data before /T/, valid control characters (not O/S/T) after it
    k = ctl.index(1)
    if ch[k] == (TERM, 1) and all(_c7(x) for x in ch[k + 1:]):
        return "T"
    return "E"


def _pack_codes(ch_list):
    v = 0
    for i, (b, _) in enumerate(ch_list):
        v |= CODE[b] << (7 * i)
    return v


def encode(w):
    """ENCODE(tx_raw) -> (hdr, payload). Words of type E give EBLOCK_T."""
    t = t_type(w)
    data, _ = w
    if t == "D":
        return (SH_DATA, data)
    if t == "E":
        return EBLOCK_T
    ch = chars(w)
    if t in ("C", "LI"):
        os0, os1 = _os_col(ch, 0), _os_col(ch, 1)
        if os0 and os1:
            p = (BT_OS_04 | (data & _LANES_1_3) | (OCODE[ch[0][0]] << 32)
                 | (OCODE[ch[4][0]] << 36) | (data & _LANES_5_7))
        elif os0:
            p = (BT_OS_0 | (data & _LANES_1_3) | (OCODE[ch[0][0]] << 32)
                 | (_pack_codes(ch[4:]) << 36))
        elif os1:
            p = (BT_OS_4 | (_pack_codes(ch[:4]) << 8) | (OCODE[ch[4][0]] << 36)
                 | (data & _LANES_5_7))
        else:
            p = BT_CTRL | (_pack_codes(ch) << 8)
        return (SH_CTRL, p)
    if t == "S":
        if ch[0] == (START, 1):
            return (SH_CTRL, BT_START_0 | (data & ~0xFF & M64))
        if _os_col(ch, 0):
            p = (BT_OS_START | (data & _LANES_1_3) | (OCODE[ch[0][0]] << 32)
                 | (data & _LANES_5_7))
        else:
            p = BT_START_4 | (_pack_codes(ch[:4]) << 8) | (data & _LANES_5_7)
        return (SH_CTRL, p)
    # 'T': D0..D(k-1) | pad (7-k bits, zero) | C(k+1)..C7
    k = [c for _, c in ch].index(1)
    p = (BT_TERM[k] | ((data & ((1 << (8 * k)) - 1)) << 8)
         | (_pack_codes(ch[k + 1:]) << (15 + 7 * k)))
    return (SH_CTRL, p)


EBLOCK_T = (SH_CTRL, BT_CTRL | (_pack_codes([C(ERROR)] * 8) << 8))
LF_WORD = word(os_chars(LOCAL_FAULT) * 2)      # two Local Fault ordered sets
LBLOCK_T = encode(LF_WORD)

EBLOCK_R = word([C(ERROR)] * 8)
LBLOCK_R = LF_WORD
LI_R = word([C(LPI)] * 8)


# --------------------------------------------------------------------------
# Receive side: R_TYPE and DECODE
# --------------------------------------------------------------------------

def _code_at(p, off):
    return (p >> off) & 0x7F


def r_type(block):
    """R_TYPE(rx_coded): 'C', 'S', 'T', 'D', 'LI' or 'E'."""
    hdr, p = block
    if hdr == SH_DATA:
        return "D"
    if hdr != SH_CTRL:
        return "E"
    bt = p & 0xFF

    def codes_ok(offsets):
        return all(_code_at(p, o) in CODE_INV for o in offsets)

    if bt == BT_CTRL:
        cs = [_code_at(p, 8 + 7 * i) for i in range(8)]
        if all(c == CODE[LPI] for c in cs):
            return "LI"
        if all(c in CODE_INV and c not in (CODE[ERROR], CODE[LPI]) for c in cs):
            return "C"
        return "E"
    if bt == BT_OS_4:
        ok = ((p >> 36) & 0xF) in OCODE_INV and codes_ok([8 + 7 * i for i in range(4)])
        return "C" if ok else "E"
    if bt == BT_OS_0:
        ok = ((p >> 32) & 0xF) in OCODE_INV and codes_ok([36 + 7 * i for i in range(4)])
        return "C" if ok else "E"
    if bt == BT_OS_04:
        ok = ((p >> 32) & 0xF) in OCODE_INV and ((p >> 36) & 0xF) in OCODE_INV
        return "C" if ok else "E"
    if bt == BT_START_4:
        return "S" if codes_ok([8 + 7 * i for i in range(4)]) else "E"
    if bt == BT_OS_START:
        return "S" if ((p >> 32) & 0xF) in OCODE_INV else "E"
    if bt == BT_START_0:
        return "S"
    if bt in BT_TERM:
        k = BT_TERM.index(bt)
        return "T" if codes_ok([15 + 7 * k + 7 * i for i in range(7 - k)]) else "E"
    return "E"


def decode(block):
    """DECODE(rx_coded) for blocks whose R_TYPE is C, S, T, D or LI."""
    hdr, p = block
    if hdr == SH_DATA:
        return (p, 0)
    bt = p & 0xFF

    def lane(j):
        return D((p >> (8 * j)) & 0xFF)

    def code(off):
        return C(CODE_INV[_code_at(p, off)])

    def ocode(off):
        return C(OCODE_INV[(p >> off) & 0xF])

    if bt == BT_CTRL:
        ch = [code(8 + 7 * i) for i in range(8)]
    elif bt == BT_OS_4:
        ch = [code(8 + 7 * i) for i in range(4)] + [ocode(36)] + [lane(j) for j in (5, 6, 7)]
    elif bt == BT_START_4:
        ch = [code(8 + 7 * i) for i in range(4)] + [C(START)] + [lane(j) for j in (5, 6, 7)]
    elif bt == BT_OS_START:
        ch = [ocode(32)] + [lane(j) for j in (1, 2, 3)] + [C(START)] + [lane(j) for j in (5, 6, 7)]
    elif bt == BT_OS_04:
        ch = [ocode(32)] + [lane(j) for j in (1, 2, 3)] + [ocode(36)] + [lane(j) for j in (5, 6, 7)]
    elif bt == BT_START_0:
        ch = [C(START)] + [lane(j) for j in range(1, 8)]
    elif bt == BT_OS_0:
        ch = [ocode(32)] + [lane(j) for j in (1, 2, 3)] + [code(36 + 7 * i) for i in range(4)]
    elif bt in BT_TERM:
        k = BT_TERM.index(bt)
        ch = ([lane(j + 1) for j in range(k)] + [C(TERM)]
              + [code(15 + 7 * k + 7 * i) for i in range(7 - k)])
    else:
        raise ValueError(f"cannot decode block type 0x{bt:02X}")
    return word(ch)


# --------------------------------------------------------------------------
# State diagrams (Figures 49-16 / 49-17 of 802.3-2022; 49-14/15 in older editions)
# --------------------------------------------------------------------------

class TxStateMachine:
    """PCS transmit state diagram, one step per 64-bit XGMII block (tx_raw).

    The state entered on a block decides how that same block is coded:
    ENCODE(tx_raw) in TX_C/TX_D/TX_T/TX_LI, EBLOCK_T in TX_E. LBLOCK_T is only
    sent while reset is asserted (TX_INIT)."""

    _NEXT = {
        "INIT": {"C": "C", "S": "D"},
        "C": {"C": "C", "S": "D", "LI": "LI"},
        "D": {"D": "D", "T": "T"},
        "T": {"C": "C", "S": "D", "LI": "LI"},
        "E": {"C": "C", "D": "D", "T": "T", "LI": "LI"},
        "LI": {"C": "C", "LI": "LI"},
    }

    def __init__(self):
        self.state = "INIT"

    def reset(self):
        self.state = "INIT"

    def step(self, w, reset=False):
        if reset:
            self.state = "INIT"
            return LBLOCK_T
        self.state = self._NEXT[self.state].get(t_type(w), "E")
        return EBLOCK_T if self.state == "E" else encode(w)


class RxStateMachine:
    """PCS receive state diagram. R_TYPE_NEXT needs the following block, so
    push() returns the XGMII word of the *previous* block (or None)."""

    _NEXT = {
        "INIT": {"C": "C", "S": "D"},
        "C": {"C": "C", "S": "D", "LI": "LI"},
        "T": {"C": "C", "S": "D", "LI": "LI"},
        "LI": {"C": "C", "LI": "LI"},
    }

    def __init__(self):
        self.state = "INIT"
        self._pending = None

    def reset(self):
        self.state = "INIT"
        self._pending = None

    def push(self, block, fault=False):
        """fault = reset + hi_ber + !block_lock at this block time (-> RX_INIT)."""
        prev, self._pending = self._pending, (block, fault)
        if prev is None:
            return None
        return self._step(prev[0], block, prev[1])

    def _step(self, cur, nxt, fault):
        if fault:
            self.state = "INIT"
            return LBLOCK_R
        r, rn = r_type(cur), r_type(nxt)
        s = self.state
        if s in ("D", "E") and r == "T":
            n = "T" if rn in ("S", "C", "LI") else "E"
        elif s == "D":
            n = "D" if r == "D" else "E"
        elif s == "E":
            n = {"C": "C", "D": "D", "LI": "LI"}.get(r, "E")
        else:
            n = self._NEXT[s].get(r, "E")
        self.state = n
        if n == "E":
            return EBLOCK_R
        if n == "LI":
            return LI_R
        return decode(cur)


# --------------------------------------------------------------------------
# Scrambler (49.2.6, Figure 49-8): G(x) = 1 + x^39 + x^58, self-synchronizing
# --------------------------------------------------------------------------

class Scrambler:
    """s_i = d_i ^ s_(i-39) ^ s_(i-58), payload bits in line order (LSB first).

    `state` keeps the last 58 scrambled bits: bit j = s_(j-58) (bit 57 newest).
    Word-level evaluation in 16-bit chunks (every dependency is >= 39 bits back)."""

    def __init__(self, state=M58):
        self.state = state & M58

    def scramble(self, payload):
        h = self.state
        for c in range(0, 64, 16):
            d = (payload >> c) & 0xFFFF
            s = d ^ ((h >> (c + 19)) & 0xFFFF) ^ ((h >> c) & 0xFFFF)
            h |= s << (58 + c)
        self.state = h >> 64
        return (h >> 58) & M64


class Descrambler:
    """d_i = r_i ^ r_(i-39) ^ r_(i-58); synchronizes after 58 received bits."""

    def __init__(self, state=0):
        self.state = state & M58

    def descramble(self, payload):
        x = self.state | ((payload & M64) << 58)
        self.state = x >> 64
        return (payload ^ (x >> 19) ^ x) & M64


# --------------------------------------------------------------------------
# Block lock state diagram (Figure 49-14 / 49-12)
# --------------------------------------------------------------------------

def sh_valid(hdr):
    return hdr in (SH_DATA, SH_CTRL)


class BlockLockModel:
    """64 valid sync headers -> block_lock; 16 invalid in a 64-header window (or
    any invalid while unlocked) -> SLIP and block_lock = false. Slip completion
    time is implementation specific and not modelled (slip_done immediate)."""

    def __init__(self):
        self.block_lock = False
        self.slips = 0
        self._reset_cnt()

    def _reset_cnt(self):
        self.sh_cnt = 0
        self.sh_invalid_cnt = 0

    def push(self, hdr):
        """Returns True when this header triggers a SLIP."""
        self.sh_cnt += 1
        if sh_valid(hdr):
            if self.sh_cnt == 64:
                if self.sh_invalid_cnt == 0:
                    self.block_lock = True
                self._reset_cnt()
            return False
        self.sh_invalid_cnt += 1
        if self.sh_invalid_cnt == 16 or not self.block_lock:
            self.block_lock = False
            self.slips += 1
            self._reset_cnt()
            return True
        if self.sh_cnt == 64:
            self._reset_cnt()
        return False


# --------------------------------------------------------------------------
# Helpers for logs and coverage
# --------------------------------------------------------------------------

def fmt_block(block):
    hdr, p = block
    sh = f"{hdr & 1}{(hdr >> 1) & 1}"      # 802.3 notation, first bit left
    return f"sh={sh} {p:016X}"


def block_kind(block):
    """Coverage bin of a block: 'D', 'BT_xx', 'EBLOCK' or 'SH_xx' (bad header)."""
    hdr, p = block
    if hdr == SH_DATA:
        return "D"
    if hdr != SH_CTRL:
        return f"SH_{hdr & 1}{(hdr >> 1) & 1}"
    if block == EBLOCK_T:
        return "EBLOCK"
    return f"BT_{p & 0xFF:02X}"


def block_symbol(block):
    """One-letter view used for the IEEE example sequences (EBLOCK -> 'E')."""
    return "E" if block == EBLOCK_T else r_type(block)


def word_symbol(w):
    return "E" if w == EBLOCK_R else t_type(w)
