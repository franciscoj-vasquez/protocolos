"""
Scoreboards.

StreamScoreboard compares two clocked streams (one item per clock) when the DUT
latency is unknown (black box): both streams are aligned on the first "marker"
item of the expected stream (e.g. the first start block) and then compared item
by item. A constant latency is itself a requirement (no idle insertion/deletion
in this PHY configuration), so any slip shows up as a mismatch.

FrameScoreboard compares transmitted payloads against frames rebuilt by Agent 2.
"""

import logging
from dataclasses import dataclass, field


@dataclass
class CompareResult:
    name: str
    aligned: bool = False
    compared: int = 0
    mismatches: int = 0
    latency_cycles: float = None
    first_mismatches: list = field(default_factory=list)
    ie: int = None            # index of the marker in the expected stream
    ia: int = None            # index of the marker in the observed stream

    def observed_for(self, expected_index, actual):
        """Observed item paired with expected[expected_index] (or None)."""
        k = self.ia + expected_index - self.ie
        return actual[k][1] if self.aligned and 0 <= k < len(actual) else None

    @property
    def ok(self):
        return self.aligned and self.compared > 0 and self.mismatches == 0

    def summary(self):
        if not self.aligned:
            return f"[{self.name}] could not align expected and observed streams"
        lat = f"{self.latency_cycles:g}" if self.latency_cycles is not None else "?"
        return (f"[{self.name}] compared={self.compared} mismatches={self.mismatches} "
                f"latency={lat} cycles")


def compare_streams(name, expected, actual, is_marker, period_ps, fmt=repr,
                    log=None, max_report=8, start_after=0):
    """expected/actual: lists of (time_ps, item).

    `start_after`: ignore expected items before this time (e.g. reset phase).
    Returns a CompareResult; mismatches are logged with simulation times so they
    can be found in the waveform (GTKWave)."""
    log = log or logging.getLogger("cocotb.tb")
    res = CompareResult(name)
    ie = next((i for i, (t, e) in enumerate(expected)
               if t >= start_after and is_marker(e)), None)
    if ie is None:
        log.error("[%s] no marker found in the expected stream", name)
        return res
    marker = expected[ie][1]
    ia = next((i for i, (_, a) in enumerate(actual) if a == marker), None)
    if ia is None:
        log.error("[%s] marker %s never observed at the DUT output", name, fmt(marker))
        return res
    res.aligned = True
    res.ie, res.ia = ie, ia
    res.latency_cycles = round((actual[ia][0] - expected[ie][0]) / period_ps, 3)
    n = min(len(expected) - ie, len(actual) - ia)
    for k in range(n):
        te, e = expected[ie + k]
        ta, a = actual[ia + k]
        res.compared += 1
        if e != a:
            res.mismatches += 1
            if len(res.first_mismatches) < max_report:
                res.first_mismatches.append((ta, e, a))
                log.error("[%s] mismatch @ %.1f ns (input @ %.1f ns)\n  expected %s\n  observed %s",
                          name, ta / 1000, te / 1000, fmt(e), fmt(a))
    log.info(res.summary())
    return res


@dataclass
class FrameResult:
    sent: int = 0
    received: int = 0
    good: int = 0
    payload_mismatch: int = 0
    bad: int = 0
    missing: int = 0
    extra: int = 0

    @property
    def ok(self):
        return (self.sent == self.received == self.good and not self.payload_mismatch
                and not self.missing and not self.extra)


def compare_frames(name, sent_payloads, rx_frames, log=None, max_report=8):
    """In-order comparison of transmitted payloads vs frames seen by Agent 2."""
    log = log or logging.getLogger("cocotb.tb")
    res = FrameResult(sent=len(sent_payloads), received=len(rx_frames))
    reported = 0
    for i, f in enumerate(rx_frames):
        if i >= len(sent_payloads):
            res.extra += 1
            continue
        if not f.good:
            res.bad += 1
            if reported < max_report:
                reported += 1
                log.error("[%s] frame %d bad: errors=%s fcs_ok=%s @ %.1f ns", name, i,
                          f.errors, f.fcs_ok, f.t_start / 1000)
            continue
        if f.payload != sent_payloads[i]:
            res.payload_mismatch += 1
            if reported < max_report:
                reported += 1
                log.error("[%s] frame %d payload mismatch (len sent %d, len rx %d) @ %.1f ns",
                          name, i, len(sent_payloads[i]), len(f.payload), f.t_start / 1000)
            continue
        res.good += 1
    res.missing = max(0, len(sent_payloads) - len(rx_frames))
    log.info("[%s] frames sent=%d received=%d good=%d bad=%d payload_mismatch=%d missing=%d extra=%d",
             name, res.sent, res.received, res.good, res.bad, res.payload_mismatch,
             res.missing, res.extra)
    return res
