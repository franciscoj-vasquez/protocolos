"""
Directed stimulus shared by unit and top-level tests.

IEEE_DF_EXAMPLES comes from the IEEE P802.3df task force presentation
"Stateless 64B/66B Encode/Decode for 800GbE and 1.6TbE" (E. Opsasnick, Oct
2022), slide "More examples of differences": block-type sequences and the
outputs of the Clause 49/82/119 TX and RX state diagrams. It is an external
reference for the error-handling behaviour (also used to validate our model).
"""

from . import baser
from .xgmii import (C, D, ERROR, IDLE, IDLE_WORD, LOCAL_FAULT, LPI, REMOTE_FAULT, RESERVED,
                    SEQ_OS, START, TERM, frame_chars, os_chars, pack_chars, word)

# (input block types, TX state diagram output, RX state diagram output)
IEEE_DF_EXAMPLES = [
    ("SDDECS", "SDDECS", "SDDECS"),
    ("SDDTESD", "SDDTEED", "SDDEEED"),
    ("SDETCSD", "SDETCSD", "SDETCSD"),
    ("SEDTCSD", "SEDTCSD", "SEDTCSD"),
    ("SDDTTCC", "SDDTECC", "SDDETCC"),
    ("SDDTTSD", "SDDTEED", "SDDETSD"),
    ("SDDCCD", "SDDECE", "SDDECE"),
    ("SDDCSD", "SDDEED", "SDDEED"),
    ("SDDESD", "SDDEED", "SDDEED"),
]


def rand_payload(rng, n):
    return bytes(rng.getrandbits(8) for _ in range(n))


def random_frame_length(rng):
    """Payload length mix: runts (legal for the PCS), small, typical, jumbo."""
    r = rng.random()
    if r < 0.15:
        return rng.randint(1, 59)
    if r < 0.50:
        return rng.randint(60, 127)
    if r < 0.95:
        return rng.randint(128, 1514)
    return rng.randint(1515, 9600)


def find_word(timed_words, w, start=0):
    """Index of the first (t, word) entry equal to `w` at or after `start`."""
    return next((i for i in range(start, len(timed_words)) if timed_words[i][1] == w), None)


def symbol_word(sym, rng):
    """XGMII word whose T_TYPE is `sym` (C, S, D, T or E)."""
    if sym == "C":
        return IDLE_WORD
    if sym == "S":
        return word([C(START)] + [D(0x55)] * 6 + [D(0xD5)])
    if sym == "D":
        return (rng.getrandbits(64), 0x00)
    if sym == "T":
        return word([D(rng.getrandbits(8)) for _ in range(3)] + [C(TERM)] + [C(IDLE)] * 4)
    if sym == "E":
        return word([C(ERROR)] * 8)
    raise ValueError(sym)


def symbol_sequence_words(symbols, rng, lead=4, tail=4):
    """Idles + the example sequence (+ a closing /T/ when it ends in S or D) + idles."""
    words = [IDLE_WORD] * lead + [symbol_word(s, rng) for s in symbols]
    if symbols[-1] in "SD":
        words.append(symbol_word("T", rng))
    return words + [IDLE_WORD] * tail


def block_format_words(rng):
    """Legal word sequence that produces every block format of Figure 49-7."""
    w = [IDLE_WORD] * 4
    w.append(word(os_chars(LOCAL_FAULT) + [C(IDLE)] * 4))                  # 0x4B, O=0x0
    w.append(word([C(IDLE)] * 4 + os_chars(REMOTE_FAULT)))                  # 0x2D
    w.append(word(os_chars(LOCAL_FAULT) + os_chars(REMOTE_FAULT)))          # 0x55
    w.append(word(os_chars((0x12, 0x34, 0x56), sig=True) + [C(IDLE)] * 4))  # 0x4B, O=0xF
    w.append(word([C(r) for r in RESERVED] + [C(IDLE)] * 2))               # 0x1E, /R/ codes
    w += [IDLE_WORD] * 2
    for k in range(8):                                    # 0x78 + /T/ in lane k (0x87..0xFF)
        w += pack_chars(frame_chars(rand_payload(rng, 16 + k), add_fcs=False), start_lane=0)
        w.append(IDLE_WORD)
    for k in range(8):                                    # 0x33 + /T/ in lane (4+k)%8
        w += pack_chars(frame_chars(rand_payload(rng, 16 + k), add_fcs=False), start_lane=4)
    w.append(IDLE_WORD)
    w += pack_chars(frame_chars(rand_payload(rng, 20), add_fcs=False), start_lane=4,
                    pre=os_chars(LOCAL_FAULT))            # 0x66 (ordered set + start)
    # /T/ followed by reserved control characters instead of idles
    w.append(word([C(START)] + [D(0x55)] * 6 + [D(0xD5)]))
    w.append((rng.getrandbits(64), 0x00))
    w.append(word([D(1), D(2), C(TERM)] + [C(r) for r in RESERVED[:5]]))
    # back-to-back frames: /S/ in the word right after /T/ (lane 7)
    w += pack_chars(frame_chars(rand_payload(rng, 23), add_fcs=False), start_lane=0)
    w += pack_chars(frame_chars(rand_payload(rng, 31), add_fcs=False), start_lane=0)
    return w + [IDLE_WORD] * 4


def lpi_words(n=16):
    """Idle -> LPI (8 x /LI/) -> idle (EEE, optional capability)."""
    return [IDLE_WORD] * 4 + [word([C(LPI)] * 8)] * n + [IDLE_WORD] * 4


def invalid_tx_words():
    """XGMII words whose T_TYPE is E, with a description."""
    return [
        ("control 0x00 (not a control character)", word([C(0x00)] + [C(IDLE)] * 7)),
        ("/S/ in lane 2", word([C(IDLE)] * 2 + [C(START)] + [D(0x55)] * 5)),
        ("/S/ in lane 4 after data", word([D(1), D(2), D(3), D(4), C(START)] + [D(0x55)] * 3)),
        ("/T/ followed by data", word([D(1), C(TERM), D(2)] + [C(IDLE)] * 5)),
        ("/T/ followed by /T/", word([D(1), C(TERM), C(TERM)] + [C(IDLE)] * 5)),
        ("/Q/ in lane 2", word([C(IDLE)] * 2 + [C(SEQ_OS), D(0), D(0), D(1)] + [C(IDLE)] * 2)),
        ("/E/ among idles", word([C(IDLE)] * 3 + [C(ERROR)] + [C(IDLE)] * 4)),
        ("data octet among idles", word([C(IDLE)] * 3 + [D(0xAA)] + [C(IDLE)] * 4)),
        ("control after /S/", word([C(START), D(0x55), C(IDLE)] + [D(0x55)] * 5)),
        ("/LI/ mixed with /I/", word([C(LPI)] * 4 + [C(IDLE)] * 4)),
    ]


def invalid_rx_blocks(rng):
    """66-bit blocks whose R_TYPE is E, with a description (unscrambled)."""
    sh = baser.SH_CTRL

    def ctrl_block(codes):
        p = baser.BT_CTRL
        for i, c in enumerate(codes):
            p |= c << (8 + 7 * i)
        return (sh, p)

    idle_codes = [0x00] * 8
    return [
        ("sync header 00", (0b00, rng.getrandbits(64))),
        ("sync header 11", (0b11, rng.getrandbits(64))),
        ("block type 0x00", (sh, rng.getrandbits(56) << 8)),
        ("0x1E with invalid code 0x7F", ctrl_block([0x7F] + idle_codes[1:])),
        ("0x1E with an /E/ code among idles", ctrl_block(idle_codes[:3] + [0x1E] + idle_codes[4:])),
        ("0x4B with O code 0x5", (sh, baser.BT_OS_0 | (0x010000 << 8) | (0x5 << 32))),
        ("0x2D with invalid code", (sh, baser.BT_OS_4 | (0x7F << 8) | (0x0 << 36))),
        ("0x55 with O code 0x3", (sh, baser.BT_OS_04 | (0x3 << 32))),
        ("0x66 with O code 0x9", (sh, baser.BT_OS_START | (0x9 << 32) | (0x555555 << 40))),
        ("0x33 with invalid code", (sh, baser.BT_START_4 | (0x40 << 8) | (0x555555 << 40))),
        ("0x87 with invalid code", (sh, baser.BT_TERM[0] | (0x7F << 15))),
    ]


def invalid_block_types():
    return [bt for bt in range(256) if bt not in baser.VALID_BLOCK_TYPES]


# Unique, valid control word used to locate directed sequences in a recorded
# stream: /Fsig/ ordered set carrying 0xC0FFEE (block type 0x4B, O code 0xF).
MARKER_WORD = word(os_chars((0xC0, 0xFF, 0xEE), sig=True) + [C(IDLE)] * 4)
