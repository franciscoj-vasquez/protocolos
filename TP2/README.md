# TP2 — LFSR Generator

## Project structure

```
TP2/
├── primer_archivo.v
├── rtl/
│   ├── lfsr_generator.v
│   ├── lfsr_checker.v
│   └── fsm_style/                  # same functionality, different coding style
│       ├── lfsr_generator.v
│       └── lfsr_checker.v
└── tb/
    ├── tb_lfsr_generator.v
    ├── channel_delay.v             # channel model (N-cycle delay)
    ├── tb_lfsr_system_channel.v     # shared infra + test dispatch (Activity 5)
    └── tests/                       # one file per test, `included by the tb above
        ├── test_direct_connection.v          # C0
        ├── test_fixed_distances.v             # C1
        ├── test_max_delay_traffic.v           # C2
        ├── test_lock_unlock_boundaries.v      # C3
        ├── test_random_distance_transitions.v # C4
        ├── test_chained_transitions.v         # C5
        └── test_reset_mid_traffic.v           # C6
```

---

## Verification status

All testbenches were compiled and simulated with **Icarus Verilog 12.0** (`iverilog -g2012` + `vvp`):

| Testbench | Tests | Result |
|---|---|---|
| `tb_lfsr_generator.v` | TEST 0a, 0b, 0c, 1, 2 (×5 seeds), 3, 4 | 15/15 PASS |
| `tb_lfsr_system_channel.v` | TEST C0, C1 (×5 delays), C2, C3, C4 (×8 iter), C5, C6 (×5 iter) | 20/20 PASS |

To reproduce:

```bash
iverilog -g2012 -o sim_gen.vvp tb/tb_lfsr_generator.v rtl/lfsr_generator.v && vvp sim_gen.vvp
iverilog -g2012 -I tb -o sim_chan.vvp tb/tb_lfsr_system_channel.v tb/channel_delay.v rtl/lfsr_generator.v rtl/lfsr_checker.v && vvp sim_chan.vvp
```

`-I tb` is only needed for the system testbench: it lets `` `include "tests/test_c0.v" `` (and the rest) inside `tb_lfsr_system_channel.v` resolve, since Icarus does not search relative to the including file by default.

`rtl/fsm_style/` is an extension not requested by the assignment — see its own section further below for what it is and how it was verified.

**About `tb_lfsr_system_channel.v` and Activity 5:** originally there were two system-level testbenches — `tb_lfsr_system.v` (generator + checker connected directly, the literal deliverable for Activity 5) and `tb_lfsr_system_channel.v` (the same integration with a channel model inserted in between, an extension not requested by the assignment). Once the latter reached equivalent coverage — `TEST C0` with `delay=0` is a pure combinational passthrough, mathematically identical to a direct connection — `tb_lfsr_system.v` became redundant and was removed; `tb_lfsr_system_channel.v` is now the only system-level testbench and covers Activity 5 through the `delay=0` case.

The first run of the system testbench (then `tb_lfsr_system.v`, without a channel) found and fixed a real race condition in `send_valid`/`send_invalid` (see the `tb_lfsr_system_channel.v` section below) that dropped the last cycle of every burst, preventing the checker from ever locking.

When `o_valid` was added as a registered output of the generator and used to feed the checker (instead of the `i_valid` shared between both DUTs in the testbench), a variant of the same issue appeared: `gen_o_valid` lags `i_valid` by one cycle, so `send_valid`/`send_invalid` needed an extra drain edge at the end of each burst so the checker has time to process the last data word before the task returns.

---

## `primer_archivo.v`

Reference code taken from the executable provided by the course. Implements a 16-bit Galois LFSR with the polynomial x¹⁶ + x¹⁴ + x¹³ + x¹¹ + 1 (taps at bits 11, 13, and 14), with no resets or valid control. Used as a golden reference to confirm the correct topology before building the parameterized generator.

---

## `rtl/lfsr_generator.v`

**Activity 1** — Main RTL module (synthesizable).

Implements the 16-bit Galois LFSR generator with all the required control signals:

| Port | Direction | Description |
|---|---|---|
| `i_clk` | in | System clock |
| `i_rst` | in | **Asynchronous** reset — loads `DEFAULT_SEED` (fixed parameter) |
| `i_soft_reset` | in | **Synchronous** reset — loads the value present on `i_seed` |
| `i_valid` | in | Sequence enable — the LFSR only advances while this is high |
| `i_seed` | in | Runtime-configurable seed (used by `i_soft_reset`) |
| `o_data` | out | LFSR output (current register state) |
| `o_valid` | out | Registered companion of `o_data` — high only on cycles where `o_data` is a genuine PRBS advance |

The next-state logic is combinational (`lfsr_next`), separate from the sequential block. The control priority is: `i_rst` > `i_soft_reset` > `i_valid` > hold.

`o_valid` was added because the valid signal must always travel together with the data it qualifies, instead of being reconstructed by each consumer from a separately shared enable signal. It is implemented as a flip-flop that follows exactly the same priority chain as `lfsr`: it stays at 0 after `i_rst` or `i_soft_reset` (the resulting data is a reset/reseed, not a new sequence step) and goes to 1 only when the `i_valid` branch is the one that won that cycle. This matters even when `i_valid` is high at the same time as `i_soft_reset`: since `i_soft_reset` has priority and the LFSR does not advance that cycle, `o_valid` must report 0 (see TEST 0c in `tb_lfsr_generator.v`).

---

## `rtl/lfsr_checker.v`

**Activity 4** — Verification RTL module (synthesizable).

Connected to the generator's output, it verifies on every valid cycle that the received value matches the expected PRBS sequence. Internally it keeps its own reference LFSR (same polynomial) and compares it against `i_data`.

| Port | Direction | Description |
|---|---|---|
| `i_clk` | in | System clock |
| `i_rst` | in | Asynchronous reset — returns to the UNLOCKED state |
| `i_valid` | in | Indicates that new data is available for checking |
| `i_data` | in | Data coming from the generator |
| `o_lock` | out | HIGH when the sequence is verified and the checker is locked |

The module itself is agnostic about who drives `i_valid`; in `tb_lfsr_system_channel.v` (Activity 5) it is connected to the channel's output (`chan_o_valid`, which in turn travels together with `lfsr_generator`'s `o_valid` from the channel's input), so the valid/data pair travels intact from the generator all the way to the checker instead of being derived separately in the testbench.

**Two**-state state machine (no separate `ACQUIRE` state):

- **UNLOCKED**: compares `i_data` against the predicted value. Match → accumulates consecutive matches, and upon reaching 5 → `o_lock = 1` and moves to LOCKED. Mismatch → there is no special state for this: there simply isn't (yet) anything to compare against, so it takes `i_data` as the new reference and resets the match counter. That same branch covers both the initial resynchronization (what a separate `ACQUIRE` state used to handle) and any later loss of sync, without spending an extra state or cycle.
- **LOCKED**: accumulates consecutive errors. Upon reaching 3 → `o_lock = 0` and returns to UNLOCKED. A match resets the error counter.

The internal reference (`lfsr_ref`) is initialized to `0` — a value the PRBS sequence never produces (it does not belong to the maximal cycle of 2¹⁶−1 nonzero states) — both on reset and upon unlocking. This "sentinel" guarantees that the first comparison after either of those two events fails on purpose and triggers UNLOCKED resynchronization, instead of risking a chance match against the real data (as could happen if it were seeded with `DEFAULT_SEED`, the value the generator usually starts from: the comparison could match by pure coincidence and the checker would lock one cycle earlier than expected, breaking the boundary tests). Thanks to the sentinel, the exact time needed to lock/relock did not change compared to the three-state design, so the system testbench needed no adjustment to any cycle counts.

---

## `rtl/fsm_style/` (extension — not requested by the assignment)

A rewrite of `lfsr_generator.v` and `lfsr_checker.v` using the two-separate-`always` pattern: one combinational block (`always @*`) with a `case` for the next-state logic, and one sequential block (`always @(posedge i_clk or posedge i_rst)`) that only registers what the combinational block decided. Same module name and same interface as the originals — designed so it can be recompiled against the existing testbenches without touching a single line of those testbenches. `rtl/lfsr_generator.v` and `rtl/lfsr_checker.v` (already verified) remain untouched; this is a parallel version, not a replacement.

**Why `i_rst` doesn't enter the combinational `case`:** it is asynchronous, and for that to be real in hardware (not a synchronous reset in disguise) it has to be resolved in the sequential `always` block's own sensitivity list (`posedge i_clk or posedge i_rst`). The combinational block only resolves the `i_soft_reset` > `i_valid` > hold priority (generator) or the `case` on `state` (checker); `i_rst` wins outside that case, in the sequential block.

**Defaults against latches:** both combinational blocks assign "hold" values to all their `next_*` signals before the `case`, and the `case` also has an explicit `default` branch — double coverage so that no signal is left undefined on any path through the block.

- Generator selector: `ctrl_sel = {i_soft_reset, i_valid}` (`fsm_style/lfsr_generator.v:60`) — the on/off control signals are used directly as the input to the `case` that builds `next_lfsr`/`next_o_valid`.
- Checker selector: `case (state)` (`fsm_style/lfsr_checker.v:106`) — a natural fit, since the checker already had an explicit 2-state FSM.

**Equivalence verification:** `tb_lfsr_generator.v` and `tb_lfsr_system_channel.v` were recompiled, **without modification**, pointing at these files instead of the originals:

```bash
iverilog -g2012 -o sim_gen_fsm.vvp tb/tb_lfsr_generator.v rtl/fsm_style/lfsr_generator.v && vvp sim_gen_fsm.vvp
iverilog -g2012 -I tb -o sim_chan_fsm.vvp tb/tb_lfsr_system_channel.v tb/channel_delay.v rtl/fsm_style/lfsr_generator.v rtl/fsm_style/lfsr_checker.v && vvp sim_chan_fsm.vvp
```

Result: the same 35/35 PASS as the original versions (15 + 20). Additionally, outside of these testbenches (an exploratory stress test, not version-controlled), both versions were compared cycle by cycle over 20,000 cycles with random and simultaneous `i_rst`/`i_soft_reset`/`i_valid` — 0 differences, including (for the checker) the full internal state (`state`, `lfsr_ref`, `valid_cnt`, `invalid_cnt`), not just `o_lock`.

---

## `tb/tb_lfsr_generator.v`

**Activities 2 and 3** — Testbench for the generator in isolation.

Verifies the `lfsr_generator` module independently. Includes:

**Infrastructure (Activity 2):**
- 10 MHz clock (period = 100 ns).
- `task_set_seed`: changes `i_seed` during simulation.
- `task_async_reset`: pulses `i_rst` for a random duration in [1 µs, 250 µs].
- `task_soft_reset`: pulses `i_soft_reset` for a random duration in [1 µs, 250 µs].
- Random valid process: `rand_valid` is randomized every posedge when `rand_valid_en = 1`. The `i_valid` signal is a mux wire between `forced_valid` (deterministic tests) and `rand_valid` (random mode), avoiding driver conflicts. Exercised by TEST 4.

**Tests (Activity 3):**
- **TEST 0a**: verifies that `o_data == DEFAULT_SEED` immediately after `i_rst`, and that `o_valid == 0` (the data is the product of a reset, not an advance).
- **TEST 0b**: verifies that `o_data == i_seed` immediately after `i_soft_reset`, and that `o_valid == 0`.
- **TEST 0c**: verifies priority — `i_soft_reset` and `i_valid` asserted simultaneously; the reset must win and `o_valid` must stay at 0 (key test that `o_valid` is not a bare echo of `i_valid`).
- **TEST 1**: measures the LFSR's period with `DEFAULT_SEED`; must be exactly 65,535.
- **TEST 2**: repeats the period measurement with 5 different random seeds; all must yield 65,535.
- **TEST 3**: verifies the output does not advance over 50 cycles with `i_valid = 0`, and that `o_valid` stays at 0 during that span.
- **TEST 4**: enables `rand_valid_en` and compares `o_data`, cycle by cycle over 3000 cycles, against a reference model (`lfsr_step`) that only advances on cycles where the sampled `i_valid` was 1 — verifies gating under genuinely intermittent valid. In the same loop it compares `o_valid` against the `i_valid` sampled one cycle earlier, confirming it correctly travels alongside `o_data` under intermittent valid.

---

## `tb/channel_delay.v` and `tb/tb_lfsr_system_channel.v`

**Activity 5** (via `delay=0` in TEST C0) **+ channel extension not requested by the assignment** (`delay>0` in the remaining tests).

Testbench for the full system: generator → channel → checker. Includes an error-injection port (`i_inject_error` on `channel_delay.v`, see below) that forces incorrect data into the checker without altering the generator. `u_chk.i_valid` is connected to `chan_o_valid` (the channel's output), not to the testbench's `i_valid` — the valid/data pair travels intact from the generator, through the channel, all the way to the checker, instead of the testbench delivering it to each module separately.

**File split and test dispatch:** `tb_lfsr_system_channel.v` itself only holds the shared infrastructure — DUT instances, clock, the `o_lock` monitor, and the reset/send helper tasks described below. Each test (C0..C6) lives in its own file under `tb/tests/`, named after what it verifies rather than its test ID, wrapped as a task (`test_C0` .. `test_C6`, matching the `[TEST Cn]` labels in the console output) and pulled in via `` `include `` — the tasks need direct access to the enclosing module's signals (DUT outputs, control regs), which is why `` `include `` is used instead of separate compilation units. Which test(s) run is decided at run time by a `case` on a `+TEST=<name>` plusarg:

```bash
vvp sim_chan.vvp                # no plusarg -> runs the full suite C0..C6, same as +TEST=ALL
vvp sim_chan.vvp +TEST=C3       # runs only test C3
```

This keeps a single compilation covering the whole suite (unlike TP1's `` `define TESTn ``, which selects at compile time and needs a recompile per test) while still letting each test be inspected or debugged on its own, in its own file.

**`o_lock` monitor:** an `always @(o_lock)` process prints a console message every time the lock state changes, showing the previous and new value.

**`channel_delay.v`:** a shift register with `MAX_DELAY` stages that **always** shifts, cycle by cycle, regardless of `i_delay`'s value — `i_delay` only selects which stage is read from, it never stops or skips the shifting. `data` and `valid` always advance together, stage by stage (same principle as `o_valid`/`o_data` in `lfsr_generator.v`, now applied to every stage of the channel instead of a single flip-flop). `i_delay = 0` is a combinational passthrough — the generator and checker end up connected directly, with no extra latency cycle.

Changing `i_delay` while data is in flight would make the read "jump" to a different age within the buffer (repeated data if N increases, skipped data if N decreases) — that's not a bug in the module, it's what would happen in real life if a cable's length were changed on the fly. The responsibility of changing `i_delay` at a safe moment belongs to the testbench, not the module:

- `set_channel_delay(n)` (`tb_lfsr_system_channel.v`, task `set_channel_delay`): pulses the channel's `i_rst` together with the `chan_delay` change, so it starts out "empty" at the new distance — like reconnecting the cable.
- `randomize_channel_delay()` (`tb_lfsr_system_channel.v`, task `randomize_channel_delay`): picks `n` with `$urandom_range(0, MAX_DELAY)` and calls `set_channel_delay` — simulates reconnecting at a random distance between bursts.

**Error injection:** it is a port on `channel_delay.v` (`i_inject_error`), not a mux in the testbench — the testbench connects its `inject_error` reg directly to that port, and the module corrupts `i_data` internally, **before** the data enters the pipeline (feeding the first stage). The corruption flips a **single, randomly chosen bit** (`err_bit`, redrawn every cycle with `<=` inside an `always @(posedge i_clk)` — same mechanism as `rand_valid`, never a blocking assignment outside an `always`) instead of the whole word: this better models a real transmission bit-flip than inverting the entire data word, and it still guarantees a mismatch just as before — flipping a single bit of a `DATA_WIDTH`-bit value can never reproduce that same value, whichever bit is chosen, so the property the tests rely on ("with `i_inject_error=1` the checker ALWAYS sees data different from the expected value") is unchanged. Verified with an exploratory probe (not version-controlled): 15 consecutive cycles of `i_inject_error=1`, each one changed exactly 1 bit and the position varied cycle to cycle. `i_inject_error` does not model real channel noise — it is a verification hook to force incorrect data without touching the generator (see the comment in `channel_delay.v`). Once the data enters the pipeline, the channel carries it faithfully, whether correct or deliberately corrupted, the same way a real channel doesn't "fix" bits that arrive wrong.

**Helper tasks:**
- `reset_generator` / `reset_checker`: random asynchronous reset [1 µs, 250 µs] of each module separately.
- `send_valid(n)` / `send_invalid(n)`: deliver `n` correct / incorrect data words to the checker. `i_valid` is **not** held continuously high: it is a mux wire between `forced_valid` (deterministic control) and `rand_valid` (50/50 gated, selected while `rand_valid_en=1`) — the same pattern as `i_valid` in `tb_lfsr_generator.v`. The task enables `rand_valid_en` and keeps it that way until exactly `n` cycles came out with `i_valid=1`. The checker only reacts on those cycles, so `n` still means "`n` data words actually processed" — the gaps with `i_valid=0` interleaved in between don't add to or subtract from any test's cycle counts (`CYCLES_TO_LOCK`, the 4+1, 2+1, 5+3 patterns, etc.), they just stretch the burst over a random (≥ `n`) number of clock cycles instead of `n` consecutive ones.

  `rand_valid` is updated with `<=` inside an `always @(posedge i_clk)` — never with a blocking assignment right after a `@(posedge i_clk)` inside the task, because that would compete for the same edge with the generator's/channel's/checker's `always @(posedge i_clk)` blocks (the same class of race that already forces the drain, see below). Also, right when `rand_valid_en` is enabled there is a `#1` before the first read of `i_valid`: reading a continuous assignment (the mux) at the exact instant its selector just changed, with no delay in between, can lose the race against the wire's re-evaluation and return the old value — a mismatch between what the task counts as sent and what the generator actually saw, which in practice let one extra data word slip through uncounted. This bug was found by instrumenting `u_chk` with an ad-hoc debug testbench (tracing `state`/`lfsr_ref`/`valid_cnt` cycle by cycle) after seeing TEST 2 and TEST 3 fail intermittently when random gating was first added (at the time in the channel-less testbench, `tb_lfsr_system.v`, now removed); the fix was validated by running 30 different random seeds with no failures, on top of the standard run, and that same validation was repeated when the mechanism was ported here.

  **Drain:** with a channel, the last data word of a burst takes 1 cycle (the generator's own register) + `chan_delay` cycles (propagation through the channel) to reach the checker — `gen_o_valid` lags `i_valid` by one cycle, and each channel stage adds one more cycle. `send_valid`/`send_invalid` wait `repeat (chan_delay + 1) @(posedge i_clk)` after the last cycle, before returning, so the checker has time to process the burst's last data word — with `chan_delay = 0` the 1+0 cycles are still needed just the same (the pass through the generator's register), so the formula has no special case.
- `lock_checker`: resets the checker and sends it the cycles needed to reach the LOCKED state.

**Tests** (each one a task in its own file under `tb/tests/`):
- **TEST C0** (`tests/test_direct_connection.v`): `delay = 0` — generator and checker connected directly. Includes a soft reset to a known seed (0xCAFE): verifies the generator loads it and that the checker manages to lock starting from that new seed. This is the literal deliverable for Activity 5.
- **TEST C1** (`tests/test_fixed_distances.v`): lock across 5 fixed distances (0, 4, 8, 12, 16 cycles).
- **TEST C2** (`tests/test_max_delay_traffic.v`): valid traffic with `i_valid` gated randomly 50/50 and `delay = MAX_DELAY` (31, the maximum that fits in `i_delay`'s 5 bits) — must not unlock until a full period of valid data (65,535) has been delivered.
- **TEST C3** (`tests/test_lock_unlock_boundaries.v`): lock/unlock boundary conditions — 4 valid + 1 invalid (never locks) and, once locked, (2 invalid + 1 valid) × 10 (never unlocks) — with `delay = 7`.
- **TEST C4** (`tests/test_random_distance_transitions.v`): 8 lock→unlock iterations, each with a different random distance between bursts (via `randomize_channel_delay`), resetting the generator and checker before each attempt.
- **TEST C5** (`tests/test_chained_transitions.v`): chained transition — pattern (`CYCLES_TO_LOCK` valid + `UNLOCK_THRESHOLD` invalid) × 5, **without** resetting the generator/checker between iterations (unlike C4), with the channel delay re-randomized before every iteration. Verifies it always alternates between LOCKED and UNLOCKED under continuous traffic and a varying channel distance, not just after a clean reset at a fixed delay.
- **TEST C6** (`tests/test_reset_mid_traffic.v`): random reset of the checker **in the middle of traffic** (not from a clean state) × 5 — valid burst of random duration, reset halfway through, must always relock.

Result: 20/20 PASS (C0=3, C1=5 individual + 1 aggregate, C2=1, C3=2, C4=1 aggregate over 8 iterations, C5=1 aggregate over 5 iterations, C6=5 individual + 1 aggregate over 5 iterations — same counting criterion as the tables above: lines containing the word PASS in a clean run). It was also verified, outside of this testbench (exploratory probe, not version-controlled), that the channel reproduces data and valid bit-exact with the expected delay: 2447 samples compared against a reference queue for delay ∈ {0, 1, 5, 20, 31}, 0 mismatches (31 = `MAX_DELAY`, the channel's actual limit).

To reproduce:

```bash
iverilog -g2012 -I tb -o sim_chan.vvp tb/tb_lfsr_system_channel.v tb/channel_delay.v rtl/lfsr_generator.v rtl/lfsr_checker.v && vvp sim_chan.vvp

# or run a single test:
vvp sim_chan.vvp +TEST=C6
```
