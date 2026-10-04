"""
Self-tests of the VIP (no simulator): "verify the verifier" before using the
reference model as the judge of the DUT.

Run from TP4/verif:  python -m pytest -q selftest
"""

import random

import pytest

from vip import baser, prbs, sequences, xgmii
from vip.xgmii import C, D, IDLE, IDLE_WORD, TERM, word


# --------------------------------------------------------------------------
# Known vectors
# --------------------------------------------------------------------------

def test_encode_idle_block():
    assert baser.encode(IDLE_WORD) == (baser.SH_CTRL, 0x000000000000001E)


def test_encode_start_lane0_vector_from_tp3():
    # TP3 lab 3 (course RTL): txd D5555555555555FB / txc 01 -> payload D555555555555578
    assert baser.encode((0xD5555555555555FB, 0x01)) == (baser.SH_CTRL, 0xD555555555555578)


def test_encode_terminate_lane6_vector_from_tp3():
    # TP3 lab 3: txd 07FD15B839350300 / txc C0 -> payload 0015B839350300E1
    assert baser.encode((0x07FD15B839350300, 0xC0)) == (baser.SH_CTRL, 0x0015B839350300E1)


def test_encode_terminate_lane3_vector_from_unh():
    # UNH-IOL 10GbE Clause 49 tutorial: D0 D1 D2 T3 C4..C7 -> "10 b4 D0 D1 D2 00000000"
    w = word([D(0xA0), D(0xA1), D(0xA2), C(TERM)] + [C(IDLE)] * 4)
    assert baser.encode(w) == (baser.SH_CTRL, 0x00000000A2A1A0B4)


def test_encode_data_block():
    assert baser.encode((0x0123456789ABCDEF, 0)) == (baser.SH_DATA, 0x0123456789ABCDEF)


def test_sync_header_convention():
    # bit 0 of hdr is the first bit on the line: data "01", control "10"
    assert baser.SH_DATA & 1 == 0 and baser.SH_DATA >> 1 == 1
    assert baser.SH_CTRL & 1 == 1 and baser.SH_CTRL >> 1 == 0


def test_eblock_and_lblock():
    assert baser.EBLOCK_T[1] == 0x1E | sum(0x1E << (8 + 7 * i) for i in range(8))
    assert baser.r_type(baser.EBLOCK_T) == "E"
    assert baser.LBLOCK_T == (baser.SH_CTRL, 0x0100000001000055)
    assert baser.LBLOCK_R == (0x0100009C0100009C, 0x11)


# --------------------------------------------------------------------------
# Encode / decode consistency
# --------------------------------------------------------------------------

def _legal_words(rng, n_frames=60):
    b = xgmii.XgmiiStreamBuilder(ifg=rng.choice([1, 5, 12]), dic=True, start_lane="random", rng=rng)
    for _ in range(n_frames):
        b.add_frame(sequences.rand_payload(rng, rng.randint(1, 200)), add_fcs=rng.random() < 0.5)
    return b.drain() + sequences.block_format_words(rng)


def test_roundtrip_all_legal_words():
    rng = random.Random(1)
    for w in _legal_words(rng):
        blk = baser.encode(w)
        assert baser.r_type(blk) == baser.t_type(w) != "E", xgmii.fmt_word(w)
        assert baser.decode(blk) == w, xgmii.fmt_word(w)


def test_block_format_words_cover_every_format():
    kinds = {baser.block_kind(baser.encode(w)) for w in sequences.block_format_words(random.Random(5))}
    from vip.coverage import BLOCK_FORMAT_BINS
    assert set(BLOCK_FORMAT_BINS) <= kinds


def test_tx_state_machine_never_errors_on_legal_stream():
    rng = random.Random(2)
    sm = baser.TxStateMachine()
    for w in _legal_words(rng):
        assert sm.step(w) == baser.encode(w)
        assert sm.state != "E"


def test_invalid_tx_words_are_type_e():
    for desc, w in sequences.invalid_tx_words():
        assert baser.t_type(w) == "E", desc


def test_invalid_rx_blocks_are_type_e():
    for desc, blk in sequences.invalid_rx_blocks(random.Random(3)):
        assert baser.r_type(blk) == "E", desc
    for bt in sequences.invalid_block_types():
        assert baser.r_type((baser.SH_CTRL, bt)) == "E"
    assert len(sequences.invalid_block_types()) == 256 - 15


# --------------------------------------------------------------------------
# State diagrams vs. IEEE P802.3df example table
# --------------------------------------------------------------------------

@pytest.mark.parametrize("seq,tx_exp,rx_exp", sequences.IEEE_DF_EXAMPLES)
def test_ieee_df_examples_tx(seq, tx_exp, rx_exp):
    rng = random.Random(4)
    sm = baser.TxStateMachine()
    for _ in range(4):
        sm.step(IDLE_WORD)
    out = "".join(baser.block_symbol(sm.step(sequences.symbol_word(s, rng))) for s in seq)
    assert out == tx_exp


@pytest.mark.parametrize("seq,tx_exp,rx_exp", sequences.IEEE_DF_EXAMPLES)
def test_ieee_df_examples_rx(seq, tx_exp, rx_exp):
    rng = random.Random(4)
    blocks = ([baser.encode(IDLE_WORD)] * 4
              + [baser.encode(sequences.symbol_word(s, rng)) for s in seq]
              + [baser.encode(IDLE_WORD)])
    sm = baser.RxStateMachine()
    outs = [w for w in (sm.push(b) for b in blocks) if w is not None]
    assert "".join(baser.word_symbol(w) for w in outs[4:4 + len(seq)]) == rx_exp


def test_rx_local_fault_while_fault():
    sm = baser.RxStateMachine()
    idle = baser.encode(IDLE_WORD)
    outs = [sm.push(idle, fault=True) for _ in range(5)]
    assert outs[1:] == [baser.LBLOCK_R] * 4


# --------------------------------------------------------------------------
# Scrambler
# --------------------------------------------------------------------------

def _scramble_bit_serial(sreg, payload):
    """Figure 49-8 literally: sreg[0] = S0 (newest) ... sreg[57] = S57."""
    out = 0
    for i in range(64):
        b = ((payload >> i) & 1) ^ sreg[38] ^ sreg[57]
        out |= b << i
        sreg = [b] + sreg[:-1]
    return out, sreg


def test_scrambler_matches_bit_serial_reference():
    rng = random.Random(6)
    state = rng.getrandbits(58)
    sc = baser.Scrambler(state)
    sreg = [(state >> (57 - k)) & 1 for k in range(58)]
    for _ in range(300):
        p = rng.getrandbits(64)
        ref, sreg = _scramble_bit_serial(sreg, p)
        assert sc.scramble(p) == ref


def test_descrambler_self_synchronizes():
    rng = random.Random(7)
    sc, ds = baser.Scrambler(rng.getrandbits(58)), baser.Descrambler(rng.getrandbits(58))
    data = [rng.getrandbits(64) for _ in range(200)]
    out = [ds.descramble(sc.scramble(p)) for p in data]
    assert out[1:] == data[1:]
    assert (out[0] ^ data[0]) >> 58 == 0          # bits 58..63 already correct


def test_descrambler_error_multiplication():
    rng = random.Random(8)
    sc = baser.Scrambler()
    ds = baser.Descrambler(sc.state)               # already synchronized
    data = [rng.getrandbits(64) for _ in range(4)]
    line = [sc.scramble(p) for p in data]
    line[1] ^= 1 << 3                              # one line bit error
    out = [ds.descramble(x) for x in line]
    errs = sum(bin(a ^ b).count("1") for a, b in zip(out, data))
    assert errs == 3                               # positions i, i+39, i+58


# --------------------------------------------------------------------------
# PRBS
# --------------------------------------------------------------------------

def _prbs_bit_serial(n, m, state, count):
    hist = [(state >> j) & 1 for j in range(n)]    # oldest first
    out = []
    for _ in range(count):
        b = hist[-n] ^ hist[-m]
        out.append(b)
        hist.append(b)
    return out


@pytest.mark.parametrize("order", sorted(prbs.POLYS))
def test_prbs_matches_bit_serial(order):
    rng = random.Random(order)
    n, m = prbs.POLYS[order]
    state = rng.getrandbits(n) | 1
    g = prbs.Prbs(order, state)
    got = []
    for chunk in (1, 7, 8, 33, 64, 3, 100):
        v = g.bits(chunk)
        got += [(v >> i) & 1 for i in range(chunk)]
    assert got == _prbs_bit_serial(n, m, state, len(got))


@pytest.mark.parametrize("order", [7, 9, 11, 15])
def test_prbs_period_is_maximal(order):
    period = (1 << order) - 1
    v = prbs.Prbs(order).bits(2 * period)
    first, second = v & ((1 << period) - 1), v >> period
    assert first == second and 0 < first < (1 << period) - 1


def test_prbs_checker_clean_errors_and_resync():
    g = prbs.PrbsGenerator(31, state=12345)
    chk = prbs.PrbsChecker(31)
    for _ in range(10):
        chk.push(g.bytes(100))
    assert chk.locked and chk.bit_errors == 0 and chk.bits_checked > 0
    bad = bytearray(g.bytes(100))
    bad[10] ^= 0x01
    bad[50] ^= 0x80
    chk.push(bad)
    assert chk.bit_errors == 2
    g.bytes(500)                                    # a lost frame
    chk.push(g.bytes(100))
    chk.push(g.bytes(100))
    assert chk.sync_losses == 1 and chk.locked and chk.bit_errors == 2


# --------------------------------------------------------------------------
# Frames, stream builder, MAC parser
# --------------------------------------------------------------------------

def test_fcs_is_ieee_crc32():
    assert xgmii.fcs_bytes(b"123456789") == (0xCBF43926).to_bytes(4, "little")


@pytest.mark.parametrize("dic", [True, False])
def test_builder_and_parser(dic):
    rng = random.Random(9)
    b = xgmii.XgmiiStreamBuilder(ifg=12, dic=dic, rng=rng)
    payloads = [sequences.rand_payload(rng, rng.randint(1, 300)) for _ in range(200)]
    for p in payloads:
        b.add_frame(p)
    words = b.drain()
    parser = xgmii.XgmiiFrameParser()
    for w in words:
        assert baser.t_type(w) != "E"
        parser.push(w)
    assert [f.payload for f in parser.frames] == payloads
    assert all(f.good and f.start_lane in (0, 4) for f in parser.frames)
    gaps = b.gaps
    assert min(gaps) >= (9 if dic else 12)
    if dic:
        assert abs(sum(gaps) / len(gaps) - 12) < 0.5


def test_parser_detects_errors():
    parser = xgmii.XgmiiFrameParser()
    good = xgmii.pack_chars(xgmii.frame_chars(b"\x11" * 60))
    bad_fcs = list(good)
    bad_fcs[2] = (bad_fcs[2][0] ^ 1, bad_fcs[2][1])
    with_e = xgmii.pack_chars(xgmii.frame_chars(b"\x22" * 60)[:20] + [C(0xFE)]
                              + xgmii.frame_chars(b"\x22" * 60)[20:])
    truncated = xgmii.pack_chars(xgmii.frame_chars(b"\x33" * 60)[:-1] + [C(IDLE)])
    for w in good + bad_fcs + with_e + truncated:
        parser.push(w)
    f0, f1, f2, f3 = parser.frames
    assert f0.good
    assert "fcs" in f1.errors
    assert "E_in_frame" in f2.errors
    assert not f3.complete and not f3.good


# --------------------------------------------------------------------------
# Block lock
# --------------------------------------------------------------------------

def test_block_lock_needs_64_valid_headers():
    m = baser.BlockLockModel()
    for i in range(63):
        m.push(baser.SH_DATA)
        assert not m.block_lock
    m.push(baser.SH_CTRL)
    assert m.block_lock


def test_line_bit_offset_window():
    """bit_offset k: the RX sees the 66-bit window that starts k bits earlier."""
    from vip.agents import _LineEmulation
    rng = random.Random(11)
    em = _LineEmulation()
    em._line_init(None)
    k = 23
    em.bit_offset = k
    blocks = [(rng.getrandbits(2), rng.getrandbits(64)) for _ in range(20)]
    stream = 0
    for i, (h, d) in enumerate(blocks):
        stream |= (h | (d << 2)) << (66 * i)
    for i, (h, d) in enumerate(blocks):
        hh, dd = em._line_step(0, h, d)
        if i:
            assert hh | (dd << 2) == (stream >> (66 * i - k)) & baser.M66


def test_slip_emulation_reaches_lock_with_reference_fsm():
    """Misaligned scrambled idles + one bit slip per SLIP of the Clause 49 lock
    FSM: lock is reached exactly when the offset wraps to 0, after (66 - k) slips."""
    from vip.agents import _LineEmulation
    for k in (1, 17, 33, 65):
        em = _LineEmulation()
        em._line_init(None)
        em.bit_offset = k
        sc, lock = baser.Scrambler(), baser.BlockLockModel()
        idle = baser.encode(IDLE_WORD)
        for _ in range(3000):
            h, d = em._line_step(0, idle[0], sc.scramble(idle[1]))
            if lock.push(h):
                em.bit_offset = (em.bit_offset + 1) % 66
            if lock.block_lock:
                break
        assert lock.block_lock and em.bit_offset == 0 and lock.slips == 66 - k, (k, lock.slips)


def test_block_lock_loss_threshold():
    m = baser.BlockLockModel()
    for _ in range(64):
        m.push(baser.SH_DATA)
    assert m.block_lock
    for i in range(64):                    # 15 invalid in a 64-header window: keep lock
        m.push(0b00 if i < 15 else baser.SH_DATA)
    assert m.block_lock
    for i in range(16):                    # 16 invalid in the next window: lose lock
        slip = m.push(0b11)
    assert not m.block_lock and slip
