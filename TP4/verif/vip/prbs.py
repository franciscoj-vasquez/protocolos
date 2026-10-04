"""
PRBS generator and self-synchronizing checker (the "PRBS" boxes of the agents).

Polynomials x^n + x^m + 1 (ITU-T O.150 style): b_i = b_(i-n) ^ b_(i-m).
Bits are packed into octets LSB first (bit 0 of an octet is sent first on
Ethernet), so the PRBS order is preserved on the line.

The checker follows the same idea as the LFSR checker of TP2: while UNLOCKED it
seeds its reference from the received bits and needs `lock_bits` correct
predictions to LOCK; while LOCKED it compares against its own free-running
reference (no error multiplication) and drops back to UNLOCKED when a chunk is
mostly wrong (lost or shifted data).
"""

POLYS = {
    7: (7, 6),
    9: (9, 5),
    11: (11, 9),
    15: (15, 14),
    23: (23, 18),
    31: (31, 28),
}


def _popcount(x):
    return bin(x).count("1")


class Prbs:
    """Bit-exact PRBS sequence generator with word-level evaluation.

    `state` holds the last n output bits: bit j = b_(j-n) (bit n-1 is newest).
    Each step produces m new bits at once (b_i only depends on bits >= m back)."""

    def __init__(self, order=31, state=None):
        self.n, self.m = POLYS[order]
        self._mask_n = (1 << self.n) - 1
        self._mask_m = (1 << self.m) - 1
        self._d = self.n - self.m
        state = self._mask_n if state is None else state & self._mask_n
        if state == 0:
            raise ValueError("PRBS state must be non-zero")
        self._h = state
        self._buf = 0
        self._buf_len = 0

    def bits(self, count):
        """Next `count` bits as an int (first bit = LSB)."""
        while self._buf_len < count:
            chunk = (self._h ^ (self._h >> self._d)) & self._mask_m
            self._buf |= chunk << self._buf_len
            self._buf_len += self.m
            self._h = (self._h | (chunk << self.n)) >> self.m
        out = self._buf & ((1 << count) - 1)
        self._buf >>= count
        self._buf_len -= count
        return out

    def bytes(self, count):
        return self.bits(8 * count).to_bytes(count, "little") if count else b""


class PrbsGenerator(Prbs):
    """Payload source of Agent 1."""


class PrbsChecker:
    """Self-synchronizing PRBS checker for a byte stream delivered in chunks
    (one chunk = the payload of one received frame)."""

    def __init__(self, order=31, lock_bits=64, loss_ratio=0.25):
        self.order = order
        self.n, _ = POLYS[order]
        self.lock_bits = lock_bits
        self.loss_ratio = loss_ratio
        self.locked = False
        self._ref = None
        self._acc = 0
        self._acc_len = 0
        self.bits_checked = 0
        self.bit_errors = 0
        self.syncs = 0
        self.sync_losses = 0

    @property
    def ber(self):
        return self.bit_errors / self.bits_checked if self.bits_checked else 0.0

    def push(self, data):
        if data:
            self._consume(int.from_bytes(bytes(data), "little"), 8 * len(data))

    def _consume(self, bits, nbits):
        if self.locked:
            exp = self._ref.bits(nbits)
            err = _popcount(bits ^ exp)
            if nbits >= 32 and err > self.loss_ratio * nbits:
                # not bit errors but lost/shifted data: resynchronize on this chunk
                self.locked = False
                self.sync_losses += 1
            else:
                self.bits_checked += nbits
                self.bit_errors += err
                return
        self._acc |= bits << self._acc_len
        self._acc_len += nbits
        self._try_lock()

    def _try_lock(self):
        need = self.n + self.lock_bits
        mask = (1 << self.lock_bits) - 1
        while self._acc_len >= need:
            ref = Prbs(self.order, self._acc & ((1 << self.n) - 1) or 1)
            if ref.bits(self.lock_bits) == (self._acc >> self.n) & mask:
                self.locked = True
                self.syncs += 1
                self._ref = ref
                rest, rest_len = self._acc >> need, self._acc_len - need
                self._acc, self._acc_len = 0, 0
                if rest_len:
                    self._consume(rest, rest_len)
                return
            self._acc >>= 1
            self._acc_len -= 1
