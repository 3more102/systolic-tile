# Verification

## The principle: one definition of correct

`model/golden.py` is the specification. The RTL is an implementation of it, and
every test compares against it. Nothing in `tb/` contains a hand-written
expected value.

That matters because hand-written expectations rot. Someone tweaks the rounding
mode, updates the golden values in the testbench to match, and the test now
passes against the bug. Here the only way to change what "correct" means is to
change the model, and the model is 130 lines of readable numpy.

The same files feed the FPGA self-test, so **a board that lights its PASS LED is
asserting the same property the simulation asserts**: bit-exactness with the
Python model.

```
model/golden.py
      │
      └── model/gen_vectors.py
              ├── sim/vectors/…      → tb_systolic_tile, tb_requant
              └── rtl/fpga/*.hex     → tile_selftest → on-board PASS LED
                                       (CI diffs these against a fresh
                                        regeneration so they cannot go stale)
```

---

## What each testbench pins down

### `tb_systolic_tile` — the whole tile

Streams a full matmul case and checks every output beat. Also checks
`y_last` lands on the final beat, that no result appears before the last pass,
and that no extra beats arrive after the stream ends.

Runs over 5 cases × 3 backpressure modes = **15 configurations**:

| Case | M | K | Passes | ReLU | What it is for |
|---|---|---|---|---|---|
| `basic` | 4 | 8 | 1 | no | scale exactly ¼, small values, hand-checkable |
| `single` | 1 | 8 | 1 | no | shortest legal stream — M=1 edge case |
| `multi` | 16 | 32 | 4 | yes | K-tiling across 4 passes, plus ReLU |
| `sat` | 8 | 8 | 1 | no | ~6× overscaled, so ~55% of outputs clamp |
| `stress` | 64 | 64 | 8 | no | 8 passes, full INT8 range, longest run |

Backpressure modes: `bp=0` never stalls, `bp=1` accepts ~½ the time, `bp=2`
~¼ plus random bubbles on `a_valid`. Only the aggressive mode reliably fills the
output FIFO — on `stress` it produces 146 stall cycles and 160 input bubbles,
which is the array-wide freeze and the gap-tolerance of the skew buffer both
being exercised for real.

### `tb_requant` — the output stage

320 vectors, each carrying its **own** `(mult, shift, relu)`, streamed one per
cycle. This does double duty:

1. Covers the arithmetic corners: round-half-up on negatives, both saturation
   limits, ReLU, `shift == 0`, the widest multiply, and bias pushing a value
   over the edge. 20 directed cases, then 300 fuzz cases.
2. Because the config changes every cycle, it proves the config pipeline inside
   `requant` is staged correctly. **An implementation that used the raw `shift`
   input at stage 2 instead of the twice-registered copy would pass a
   constant-config test and fail this one.**

### `tb_skew_buffer` — the delays

Drives a timestamp onto every lane and asserts that lane *i*'s output at cycle
*t* is the timestamp from cycle *t−DLY*, in both skew and deskew directions.
Then freezes `en` and asserts the delayed lanes do not advance.

This is tested in isolation on purpose. An off-by-one in the skew does not
crash — it pairs each activation with the wrong partial sum, and every result is
quietly wrong. Debugging that from the top level is miserable; pinning it here
takes 60 lines.

### `tb_selftest` — the thing that ships on the board

Simulates `tile_selftest` exactly as synthesised, twice (clean and with hardware
backpressure), and independently verifies the probe read-back path against the
golden file. The board build has no console — it reports one LED — so it is
worth proving the harness itself is right, otherwise a dark LED is ambiguous
between "the tile is broken" and "the self-test is broken".

---

## The structural gate

`make lint` runs Yosys and fails on:

- inferred latches (`$dlatch`, `$dlatchsr`, `$sr`)
- undriven or multiply-driven nets, and combinational loops (`check -assert`)
- a hierarchy that does not elaborate (`hierarchy -check`)

These are the failures that simulate perfectly and then bite in the vendor tool.
It runs in a couple of seconds on every push.

Cell counts after coarse mapping — the numbers are meaningful because
`memory -nomap` keeps the accumulator as a `$mem` rather than flattening 64 kbit
into flip-flops:

| Cell | Count |
|---|---|
| `$mul` | 72 (64 PE + 8 requant) |
| `$add` | 94 |
| `$mem_v2` | 1 (accumulator) |
| registers | ~478 multi-bit cells |

---

## Sampling discipline

Stimulus is driven on `negedge`, handshakes are sampled on `negedge` (every
`ready` is register-derived and therefore stable there), and result monitors sit
on `posedge` where they observe pre-edge values. No clocking blocks, because not
every simulator in this flow supports them — and no races either.

Randomisation uses a plain LFSR rather than `$random`, so stimulus is identical
under Icarus in CI and ModelSim locally.

---

## Coverage reported per run

Each `tb_systolic_tile` run prints beats checked, measured pipeline depth, stall
cycles, input bubbles and clamping beats. These are counters, not assertions —
they exist so that "the test passed" can be distinguished from "the test passed
without exercising anything".

---

## What this does *not* prove

Stated plainly, because a verification story with no limitations section is not
a verification story:

- **Only 8×8 is tested.** The RTL is parameterised in `ROWS`/`COLS`, but
  `gen_vectors.py` emits 8-wide weights, so other geometries are unverified.
- **No formal verification.** There are no SVA properties and no proof of the
  handshake or the freeze invariant. A bounded model check of "stall never loses
  a beat" would be the highest-value addition here.
- **No gate-level simulation.** Post-synthesis and post-route netlists are not
  simulated, so nothing here would catch a synthesis-tool bug or an
  X-propagation difference at reset.
- **Not yet run on hardware.** Both bitstreams build and the self-test passes in
  simulation, but neither has been programmed onto a physical board.
- **`MAX_M` is not enforced in hardware.** Streaming more than `MAX_M` output
  rows in one run wraps the accumulator address silently; the testbench never
  does it.
- **Single clock domain.** The only asynchronous inputs are the buttons and
  switches, handled by two-flop synchronisers in `selftest_shell`. There is no
  CDC to verify beyond that, and no CDC linting is run.
