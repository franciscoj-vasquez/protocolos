"""
Minimal functional coverage collector (no external dependency).

Coverpoints have a fixed list of bins; samples outside the bins are counted
under "<other>". report() prints hits per bin and the list of holes; dump()
writes a JSON file that tools/summarize_results.py can merge.
"""

import json
import os
from collections import OrderedDict

from . import baser

BLOCK_FORMAT_BINS = ["D"] + [f"BT_{bt:02X}" for bt in
                             (baser.BT_CTRL, baser.BT_OS_4, baser.BT_START_4, baser.BT_OS_START,
                              baser.BT_OS_04, baser.BT_START_0, baser.BT_OS_0) + baser.BT_TERM]
FRAME_LEN_BINS = ["1-59", "60", "61-127", "128-511", "512-1514", "1515-9600"]


def frame_len_bin(n):
    if n < 60:
        return "1-59"
    if n == 60:
        return "60"
    if n < 128:
        return "61-127"
    if n < 512:
        return "128-511"
    if n <= 1514:
        return "512-1514"
    return "1515-9600"


class Coverage:
    def __init__(self, name):
        self.name = name
        self.points = OrderedDict()

    def define(self, point, bins):
        self.points[point] = OrderedDict((str(b), 0) for b in bins)
        self.points[point]["<other>"] = 0

    def sample(self, point, value):
        bins = self.points[point]
        key = str(value)
        bins[key if key in bins else "<other>"] += 1

    def holes(self, point):
        return [b for b, n in self.points[point].items() if n == 0 and b != "<other>"]

    def percent(self, point):
        bins = [b for b in self.points[point] if b != "<other>"]
        hit = sum(1 for b in bins if self.points[point][b])
        return 100.0 * hit / len(bins) if bins else 100.0

    def report(self):
        lines = [f"Coverage [{self.name}]"]
        for point, bins in self.points.items():
            lines.append(f"  {point}: {self.percent(point):5.1f}%  holes={self.holes(point)}")
            lines.append("    " + "  ".join(f"{b}:{n}" for b, n in bins.items() if n))
        return "\n".join(lines)

    def dump(self, path):
        os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
        with open(path, "w") as f:
            json.dump({"name": self.name, "points": self.points}, f, indent=1)
