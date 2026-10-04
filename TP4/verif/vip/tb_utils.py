"""Small cocotb helpers shared by the testbenches."""

import logging
import os
import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles

# 10GBASE-R with a 64-bit XGMII: 10.3125 Gb/s / 66 bits = 156.25 MHz
PERIOD_NS = 6.4
PERIOD_PS = 6400
BIT_TIME_PS = 100        # 10 Gb/s MAC rate -> 0.1 ns per bit (delay budget in BT)


def setup_log(level=logging.INFO):
    log = logging.getLogger("cocotb.tb")
    log.setLevel(level)
    return log


def start_clock(signal, period_ns=PERIOD_NS):
    """Positional unit argument: works with cocotb 1.9 and 2.x."""
    cocotb.start_soon(Clock(signal, period_ns, "ns").start())


async def pulse_reset(clock, resets, cycles=8, settle=8):
    for r in resets:
        r.value = 1
    await ClockCycles(clock, cycles)
    for r in resets:
        r.value = 0
    await ClockCycles(clock, settle)


def make_rng(tag=""):
    """Reproducible RNG derived from the cocotb seed (COCOTB_RANDOM_SEED)."""
    seed = getattr(cocotb, "RANDOM_SEED", None)
    if seed is None:
        seed = int(os.environ.get("COCOTB_RANDOM_SEED", os.environ.get("RANDOM_SEED", "1")))
    return random.Random(f"{seed}-{tag}")


def report_path(name):
    d = os.path.join(os.getcwd(), "reports")
    os.makedirs(d, exist_ok=True)
    return os.path.join(d, name)


def param(name, default):
    """Value of a module parameter exported by the Makefile as PARAM_<name>."""
    v = os.environ.get(f"PARAM_{name}", str(default)).strip().strip('"')
    if "'" in v:                    # e.g. 1'b0
        v = v.split("'")[1][1:]
        return int(v, 2) if v else default
    try:
        return int(v)
    except ValueError:
        return float(v)
