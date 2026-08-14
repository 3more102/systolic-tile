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

Runs over 8 cases × 3 backpressure modes = **24 configurations**:

| Case | Array | M | K | Passes | ReLU | What it is for |
|---|---|---|---|---|---|---|
| `basic` | 8×8 | 4 | 8 | 1 | no | scale exactly ¼, small values, hand-checkable |
| `single` | 8×8 | 1 | 8 | 1 | no | shortest legal stream — M=1 edge case |
| `multi` | 8×8 | 16 | 32 | 4 | yes | K-tiling across 4 passes, plus ReLU |
| `sat` | 8×8 | 8 | 8 | 1 | no | ~6× overscaled, so ~55% of outputs clamp |
| `stress` | 8×8 | 64 | 64 | 8 | no | 8 passes, full INT8 range, longest run |
| `tiny` | 4×4 | 6 | 12 | 3 | yes | smaller array, K-tiling at a different `ROWS` |
| `rect` | **4×8** | 8 | 16 | 4 | no | `ROWS ≠ COLS` — see below |
| `wide` | 16×16 | 8 | 32 | 2 | no | larger array, wider beats |

Backpressure modes: `bp=0` never stalls, `bp=1` accepts ~½ the time, `bp=2`
~¼ plus random bubbles on `a_valid`. Only the aggressive mode reliably fills the
output FIFO — on `stress` it produces 146 stall cycles and 160 input bubbles,
which is the array-wide freeze and the gap-tolerance of the skew buffer both
being exercised for real.

#### Why a non-square case

The RTL is parameterised in `ROWS` and `COLS`, but a parameter that is only ever
elaborated at one value is indistinguishable from a constant. Worse, every
*square* geometry hides a specific bug class: interchanging `ROWS` and `COLS` —
in the input skew depth, the output deskew depth, the drain length, a bus
width — is a no-op whenever they are equal. Five 8×8 cases cannot see it.

`rect` sets `ROWS=4, COLS=8` so each of those is a different number. Together
with `tiny` and `wide` the measured pipeline depth then tracks `ROWS+COLS+5`
across a 3× span:

| Geometry | Measured | `ROWS+COLS+5` |
|---|---|---|
| 4×4 | 13 | 13 |
| 4×8 | 17 | 17 |
| 8×8 | 21 | 21 |
| 16×16 | 37 | 37 |

The asymmetric row is what makes the others meaningful: it is the only one where
reading the wrong parameter produces a different number. All eight cases passed
at every geometry on the first run, so this records a design that was already
correct rather than a bug found — but that is a fact the repo could not state
before and can now.

Mechanically, the DUT's port widths are fixed at elaboration, so each geometry
needs its own compiled binary; `sim/Makefile` builds one per distinct geometry
and passes `-DTB_ROWS`/`-DTB_COLS`. A define rather than a parameter override
because `-D` behaves the same in every simulator in this flow and the override
syntax does not. If the Makefile's geometry ever disagrees with the generator's,
the testbench's existing `N == COLS` and `K == PASSES*ROWS` checks fail the run
rather than letting it pass against mismatched vectors.

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

## The pin gate

`make check-pins` diffs every pin assignment in both boards' constraint files
against a checked-in reference for that board:

| Board | Constraint file | Reference | Source |
|---|---|---|---|
| DE10-Standard | `syn/quartus/build_de10.tcl` | `de10_standard_pins.ref`, 67 pins | Terasic's golden top, cross-checked against two published `.qsf` files and the User Manual |
| Zybo Z7-10 | `syn/vivado/zybo_z7_10.xdc` | `zybo_z7_10_pins.ref`, 20 pins | Digilent's official `Zybo-Z7-Master.xdc` |

This exists because a wrong pin assignment is uniquely nasty: it synthesises,
fits, closes timing, generates a bitstream and programs successfully, and then
the board does nothing. There is no error message, no failing test, and nothing
to single-step — the first symptom is a dark LED on a desk. It is exactly the
kind of thing that should be a checked artifact rather than something reviewed
by eye once.

The check also flags two signals assigned to the same physical pin, which passes
per-signal inspection and still cannot be routed. On the Xilinx side, where the
I/O standard is written per pin rather than set globally, it additionally checks
`IOSTANDARD` — driving LVCMOS33 into a bank the board wired for 1.8 V is a
hardware hazard, not a typo.

One detail worth recording: Digilent ships its master `.xdc` with every line
commented out, to be uncommented as needed. A checker that ignored that would
parse those template lines as real assignments and report a perfect match
against a constraint file that assigns *nothing*. Comment lines are therefore
skipped before matching.

Current state: 22 DE10-Standard and 9 Zybo assignments, all matching. Both
checkers are verified against deliberately corrupted inputs — a wrong pin, a
wrong `IOSTANDARD`, a signal that does not exist on the board, and two signals
on one pin — to confirm they actually fail rather than passing vacuously.

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

- **Only 8×8 is synthesised.** Four geometries are simulated (4×4, 4×8, 8×8,
  16×16), but only the 8×8 build is put through Quartus and Vivado, so the
  others have no timing or utilisation result and no board wrapper. A geometry
  that simulates correctly can still fail to close timing.
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
