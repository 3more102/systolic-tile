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
- an array that elaborated to the wrong number of PEs
  (`select -assert-count $((ROWS*COLS)) */t:*mac_pe*`)

These are the failures that simulate perfectly and then bite in the vendor tool.
It runs in a couple of seconds on every push.

### Run once per geometry

`scripts/lint.sh` sweeps all four array sizes, re-elaborating from scratch each
time with `hierarchy -chparam ROWS n -chparam COLS m`. The reason is the same one
that motivates the multi-geometry simulation, applied to a different property:
only 8×8 is elaborated by Quartus and Vivado, so only 8×8 was ever *proven to
build*. The simulation suite proves the other geometries behave; it cannot see a
latch, and a latch inferred only at 4×8 would have sat there undetected.

Cell counts after coarse mapping — the numbers are meaningful because
`memory -nomap` keeps the accumulator as a `$mem` rather than flattening 64 kbit
into flip-flops:

| Geometry | `$mul` | `$add` | `$mem_v2` | Total cells |
|---|---|---|---|---|
| 4×4 | 20 | 34 | 1 | 363 |
| 4×8 | 40 | 62 | 1 | 615 |
| 8×8 | **72** | 94 | 1 | 925 |
| 16×16 | 272 | 310 | 1 | 3,057 |

`$mul` is `ROWS·COLS + COLS` at every size — one per PE, plus one per output
column in `requant` — and the single `$mem_v2` is the accumulator, which stays
one memory regardless of how large the array gets. Neither of those is asserted;
they are just the shape the numbers take when the parameters are wired through
correctly, and a table that only ever had one row could not show it.

The PE-count assertion *is* checked, and it is the part that makes the sweep more
than a smoke test. A generate loop that bounds both dimensions with `ROWS` — an
easy thing to write and an invisible thing to review — builds a 4×4 array when
4×8 was requested. Simulation would catch that at 4×8 too, via the testbench's
`N == COLS` check; the assertion catches it in the job that has no Python, no
generated vectors and no simulator, four seconds after the push.

The geometry list in `scripts/lint.sh` is a second copy of the one in
`model/gen_vectors.py`, deliberately: the lint job installs Yosys and nothing
else, so it cannot read the generator. A disagreement between the two is not
dangerous — it means some geometry is linted but not simulated, or the reverse —
but the two lists matching is the point of the sweep.

---

## The formal gate

Simulation covers the stimulus somebody thought to write. `make formal` proves
five properties — eight assertions — over **every** input sequence of 32 cycles
from reset, using the SAT solver built into yosys: no SymbiYosys, no SMT solver,
no license, the same `yosys` package the lint job already installs.

The properties are guarded by `` `ifdef FORMAL `` and each one lives in the module
it is about, so the RTL the vendor tools read is byte-for-byte unchanged.

| | Where | Property | The bug it excludes |
|---|---|---|---|
| **F1** | `out_fifo` | `!(wr_en && count == DEPTH)` | a result beat silently dropped |
| **F2** | `out_fifo` | `count <= DEPTH` and `wptr - rptr == count` | pointer/count desync — every beat arrives, in order, carrying the wrong data |
| **T1** | `systolic_tile` | while `y_ready` is low, `y_valid` holds and `y_data`/`y_last` do not move | a stalled consumer losing or corrupting the beat it was offered |
| **T2** | `systolic_tile` | `ycnt` cannot advance while `en` is low | `y_last` marking the wrong beat, cutting the stream in the wrong place |
| **C1** | `tile_ctrl` | no handshake, commit or clear output asserts while `en` is low | the sequencer running ahead of the frozen datapath |

### Why F1 is the one that matters

`do_wr = wr_en && (count < DEPTH)`. That mask is the only place in the design
where a result can disappear with nothing to show for it — no counter moves, no
flag is raised, the FIFO simply does not take the beat. Proving the mask is dead
code is proving the backpressure scheme.

T1 then rests on F1. `y_data` is `mem[rptr]`; during a stall `rptr` holds still,
but the entry underneath it is safe from being overwritten only because the write
pointer can never wrap onto it. A design that overfilled the FIFO fails T1 as
silent data corruption before anyone notices a beat has gone missing.

### Writing the freeze property exactly is what found the exception

The obvious statement of "everything freezes together" is that no register
advances while `en` is low. That is **false** here, and the counterexample is one
line of `tile_ctrl`: `S_IDLE → S_LOADW` on `start` is the single transition not
qualified with `en`. It is safe — every output the FSM drives is `&& en`, so a
stalled tile that accepts a `start` still cannot do anything with it — but it is
an exception, and it was a comment before it was a checked property. C1 asserts
what is actually true: not that the state is frozen, but that nothing observable
happens while the datapath is.

### A bounded proof that never reaches the interesting state is green and worthless

This is the same problem as a test that passes without exercising anything, and
`tb_systolic_tile` already prints counters for it. The formal flow does the
equivalent: before proving anything, `scripts/formal.sh` runs three **cover**
queries — asking the solver to *find* a trace, and failing when it cannot.

```
$ make formal
  formal: 2x2, MAX_M=4, FIFO_DEPTH=8, 32 steps from reset
  cover  a result beat is produced
  cover  backpressure engages
  cover  the FIFO reaches its stall threshold
  proof  8 assertions hold over every input sequence of 32 steps
  self-test  an unqualified FIFO write is caught
```

All three are reachable by step 24, measured rather than assumed, so 32 leaves
the pipeline room to grow a few cycles slower before the covers start failing.
If a future change pushes it past the bound, CI reports that the bound is now too
short instead of quietly proving nothing.

The `8` on the proof line is not typed by hand either — the script asserts the
count with `select -assert-count 8 t:$assert` before it starts solving, so a
property added without updating the summary, or an `` `ifdef FORMAL `` block that
stopped elaborating, fails the run rather than producing a green line that
overstates what was checked. The whole flow takes about five minutes and peaks
around 1.5 GB, essentially all of it in the two proofs.

### The proof can still fail

`--self-test` re-runs the whole proof against a copy of the RTL with one
mutation: the `&& en` dropped from the FIFO write enable. That is the single
documented hazard of this design — a frozen requant stage holds its valid high,
so an unqualified write pushes the same beat in on every stalled cycle until the
FIFO fills and the next one is discarded. F1 must catch it, and the script fails
if the proof comes back green.

That check is not decoration, because a bound chosen by eye is very easy to get
wrong in the direction that looks like success. The mutation needs the FIFO to
fill past its threshold and then take one more write attempt, which does not
happen until well into the run; a proof that stops before then reports the broken
design as correct, in the same words and the same green, as a proof that stops
after.

### What the bound and the geometry cost

The proof runs at ROWS=COLS=2 with a 4-entry accumulator, which is the smallest
instance that still contains every mechanism the properties talk about: an input
skew, a deskew, a K-tiling accumulator, a requant stage, and the FIFO whose
occupancy drives the global enable. `FIFO_DEPTH` stays at the shipped 8, because
F1 is a statement about the arithmetic relating the stall threshold to the depth
and that is the number the boards are built with.

What that leaves uncovered, plainly:

- **It is bounded.** Nothing is proved about cycle 33 onward. A bug that needs a
  longer run to express — an accumulator address wrapping after `MAX_M` beats,
  say — is outside it.
- **It is one geometry.** The control structure does not vary with `ROWS`/`COLS`,
  and `make lint` now elaborates all four sizes, but this proof was run at 2×2.
- **`MAX_M` is 4, not 256.** `memory_map` turns the accumulator into flip-flops
  for the solver, so the shipped depth would not terminate.
- **Datapath values are untouched.** Nothing here says a single product is
  correct. That is what `model/golden.py` and 27 simulations are for. These five
  properties are about the handshake, and only the handshake.

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

- **Only 8×8 reaches a vendor tool.** All four geometries (4×4, 4×8, 8×8, 16×16)
  are simulated and structurally checked, but only 8×8 is put through Quartus
  and Vivado, so the others have no timing or utilisation result and no board
  wrapper. Elaborating cleanly under Yosys is a real property and a much weaker
  one than closing timing on a part; 16×16 in particular has four times the
  multipliers of a design that already consumes the 7010's entire DSP budget,
  and would not fit that device at all.
- **Formal is bounded and narrow.** Five properties covering the handshake and
  the freeze are proved over every input sequence of 32 cycles at 2×2, and that
  is the whole of it. Nothing is unbounded, nothing covers the datapath, and
  nothing there says the tile computes the right numbers — that rests entirely
  on simulation against the model.
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
