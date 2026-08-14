# Architecture

An 8×8 INT8 weight-stationary systolic array that computes

```
C[M][N] = requant( sum_k A[M][K] · W[K][N] + bias[N] )
```

with INT8 operands, INT32 accumulation and an INT8 result.

---

## Block diagram

```mermaid
flowchart LR
    AIN["a_valid / a_data<br/>ROWS bytes"] --> SK["skew_buffer<br/>row r delayed r cycles"]
    SK --> ARR
    WIN["w_valid / w_data<br/>COLS bytes"] --> ARR["pe_array<br/>ROWS × COLS<br/>weight-stationary"]
    ARR --> DS["skew_buffer REVERSE<br/>col c delayed COLS−1−c"]
    DS --> AC["accum_bank<br/>K-tiling accumulator"]
    AC --> RQ["requant<br/>bias, ×mult, ≫shift, clamp"]
    RQ --> FF["out_fifo<br/>depth 8"]
    FF --> YOUT["y_valid / y_data<br/>COLS bytes"]
    FF -. "stall" .-> EN(["en = ~stall<br/>freezes every stage"])
    EN -. .-> SK
    EN -. .-> ARR
    EN -. .-> DS
    EN -. .-> AC
    EN -. .-> RQ
```

---

## Why weight-stationary

Three dataflows are possible in a systolic array, named for whichever operand
stays put:

| Dataflow | Stationary | Cost |
|---|---|---|
| Output-stationary | partial sums | activations *and* weights stream every cycle |
| Weight-stationary | weights | activations stream, partial sums stream |
| Row-stationary | a mix | most control complexity |

For inference, the same weight tile is reused across every row of the activation
matrix. Weight-stationary loads a weight once and amortises it over all `M`
rows, so weight bandwidth is `ROWS·COLS` bytes per *pass* instead of per cycle.
With `M = 64`, that is a 64× reduction in weight traffic. This is the same
reason Google's TPU v1 is weight-stationary.

---

## The array

Each PE holds one weight and does one multiply-accumulate per cycle. Three
things move through the array, each advancing exactly one PE per cycle:

```
                 w  (weight shadow chain, north → south)
                 │
                 ▼
            ┌─────────┐
   a ──────▶│  ×  +   │──────▶ a      activations: west → east
  (west)    │         │       (east)
            └─────────┘
                 │
   s ───────────▶│──────────▶ s       partial sums: north → south
 (north)                     (south)
```

`a` and `s` are both registered on the way out, so PE(r,c) contributes
`a·w` to the partial sum descending its column and hands the activation
sideways one cycle later.

## The skew, derived

This is the part that makes or breaks a systolic array, and an off-by-one here
does not crash anything — it silently pairs each activation with the wrong
partial sum and every result is subtly wrong.

Number cycles from when beat *m* is presented at the west edge.

**Activations move east one PE per cycle.** So an activation entering row *r* at
cycle *t* reaches PE(r,c) at cycle `t + c`.

**Partial sums move south one PE per cycle.** The sum for output `C[m][n]` starts
at PE(0,n) and must meet `A[m][0]·W[0][n]` there, then `A[m][1]·W[1][n]` at
PE(1,n) one cycle later, and so on.

So PE(r,c) must see `A[m][r]` exactly `r` cycles after PE(0,c) saw `A[m][0]`.
Combining with the eastward hop, `A[m][r]` must **enter** row *r* at cycle
`m + r`. That is the input skew: **row r is delayed r cycles**.

With that in place, column *n*'s result for row *m* emerges from the bottom at
cycle `m + n + ROWS` — the `+n` because the whole column's work was shifted
right by the eastward propagation. Columns therefore finish at *staggered*
times, and the output deskew undoes it: **column c is delayed COLS−1−c cycles**,
after which all columns present row *m* simultaneously.

For a 4×4 corner, ✱ marks where `A[m][r]` is at each cycle:

```
cycle:      0     1     2     3     4     5     6
row 0:      ✱ ───▶✱ ───▶✱ ───▶✱
row 1:            ✱ ───▶✱ ───▶✱ ───▶✱
row 2:                  ✱ ───▶✱ ───▶✱ ───▶✱
row 3:                        ✱ ───▶✱ ───▶✱ ───▶✱
                                    │     │     │
                              col 0 ┘     │     │   result out at m+ROWS+0
                                    col 1 ┘     │   ... +1
                                          col 2 ┘   ... +2   → deskew realigns
```

The valid bit travels the same structure rather than being recomputed: a
`COLS`-deep chain along the top edge, then down each column inside the PEs,
then through a `skew_buffer` instantiated with `W=1`. Control physically cannot
drift away from data, because it goes through the same shape of logic.

**Bubbles are free.** Because the skew buffer applies a fixed per-lane delay
rather than tracking beat boundaries, a gap in `a_valid` shifts a beat's entire
diagonal wavefront together. `a_valid` may deassert at any time.

---

## Weight loading and double buffering

Weights shift in at the top of each column, one array row per `w_shift`, into a
*shadow* register. `w_commit` then copies shadow → active in every PE at once.
The next weight tile can therefore be loaded while the current one is still
computing.

> **Load order gotcha.** The first beat pushed travels furthest, so it lands in
> row `ROWS−1`. The weight stream must present **array row ROWS−1 first** and row
> 0 last. `model/golden.py:weight_beats()` emits exactly that order, and it is
> the single easiest thing to get backwards in this design.

---

## K larger than the array

The array is only `ROWS` deep, so a `K > ROWS` matmul is split into
`ceil(K/ROWS)` passes. Each pass loads a new weight tile and re-streams the
matching slice of activations. `accum_bank` keeps a running INT32 accumulator
per (output row, column) in a block RAM, addressed by a beat counter that resets
at each pass:

- `first_pass` → overwrite (nothing stale to clear)
- `last_pass` → also release the result downstream

Because the address advances by one per beat, the stage-2 write-back and the
stage-1 read never touch the same address, so no bypass network is needed.

`MAX_M` sets the accumulator depth and therefore the largest `M` a single run
may stream.

---

## Requantisation

```
y = clamp( (acc + bias) × mult  round≫ shift )
```

Bounds are `[-128,127]`, or `[0,127]` with ReLU. Rounding is round-half-up on
the signed value: add `1<<(shift-1)` before the arithmetic right shift.

Verilog's `>>>` on a signed operand and Python's `>>` on an int are both *floor*
shifts, which is why `rtl/requant.sv` and `model/golden.py` agree exactly on
negative values — the usual place a hand-written requantiser drifts one LSB from
its model.

`mult` is unsigned so the multiplier is 33×17 signed rather than 33×32. Three
pipeline stages (bias add / multiply / shift+saturate) keep the widest operation
in the design off the critical path.

---

## Backpressure

Full valid/ready handshaking inside a systolic array is impractical — the
diagonal wavefront must stay aligned. Instead the output FIFO's occupancy drives
a single **array-wide clock enable**:

```
stall = (fifo_count >= DEPTH-2)
en    = ~stall
```

Every register upstream of the FIFO is gated by `en`. Nothing advances, so
nothing loses alignment.

The one rule this imposes: **a consumer at the `en` boundary must qualify with
`en`**. A frozen producer holds its `valid` high, so the FIFO write is
`rq_valid && en` — without that, a stall would push the same beat in on every
stalled cycle. The same applies in `tile_ctrl`, where even the single-cycle
`COMMIT` state is `en`-guarded: otherwise a stall on the commit cycle would
advance the FSM while the PEs ignored `w_commit`, and the array would go on to
compute with the *previous* tile's weights.

---

## Performance

| Quantity | Value at 8×8 |
|---|---|
| Throughput | 1 activation beat/cycle = **64 MAC/cycle** |
| Pipeline depth | **21 cycles** (measured by the testbench, matches `ROWS + COLS + 5`) |
| Weight load | `ROWS` cycles/pass, overlappable via the shadow chain |
| Peak @ 50 MHz | 3.2 GMAC/s |
| Peak @ 125 MHz | 8.0 GMAC/s |

Pipeline depth breaks down as `ROWS` (array) + `COLS−1` (column skew) + 2
(accumulator) + 3 (requant) + 1 (FIFO).

---

## Timing

Both targets close. The route to getting there on the Zynq is worth recording,
because it is a clean example of a critical path that no amount of tool
persuasion fixes — only changing what the arithmetic maps onto.

**DE10-Standard / Cyclone V** closes with roughly 2× margin: Fmax 100.5 MHz
against a 50 MHz requirement. A Cyclone V DSP block holds two 9×9 multipliers,
so Quartus packs the 64 8×8 MACs into 48 DSPs on its own.

**Zybo Z7-10 / Zynq-7010** was the interesting one. The part has exactly 80
DSP48E1 slices, and by default Vivado spent only 16 of them — on the requant
multipliers — leaving all 64 PE multiply-accumulates in LUT and carry-chain
logic. The critical path was then a fabric 8×8 multiply feeding a 32-bit carry
chain: 12 logic levels, 7 `CARRY4`s, from a PE weight register to the deskew
buffer. At the board's native 125 MHz it missed by **-0.096 ns**.

Implementation directives did not rescue it. `PerformanceOptimized` +
`ExtraTimingOpt` + `AggressiveExplore` + `Explore` moved the number to
**-0.111 ns** — marginally *worse*, which is the useful signal: a path that
strong directives cannot improve is not a placement problem, it is a mapping
problem.

The fix is `(* use_dsp = "yes" *)` on `mac_pe`. The PE's
`s_in + a_in*w_active` maps directly onto a DSP48E1 as `A*B + C -> P`, replacing
the twelve-level fabric path with one hard macro:

| | fabric MAC | DSP48 MAC |
|---|---|---|
| Setup WNS @ 125 MHz | −0.096 ns (fails) | **+0.508 ns (met)** |
| Slice LUTs | 6,891 (39%) | **1,998 (11%)** |
| DSPs | 16 / 80 | 80 / 80 |

A 3.4× reduction in LUTs *and* 0.6 ns of slack, paid for in DSP blocks.

The cost is real and worth being explicit about: this consumes **the entire DSP
budget of the 7010** (64 PE + 16 requant = 80). A second tile will not fit on
this part, and neither will anything else that wants a multiplier. On a larger
Zynq the same attribute is free; on this one it is the whole device.

---

## Parameters

| Parameter | Default | Meaning |
|---|---|---|
| `ROWS` | 8 | array height = K tile size |
| `COLS` | 8 | array width = N output channels |
| `ACC_W` | 32 | accumulator width |
| `MAX_M` | 256 | accumulator depth = largest M per run |
| `FIFO_DEPTH` | 8 | output FIFO depth |

The RTL is parameterised, but the vector generator currently emits 8-wide
weights, so only 8×8 is covered by the test suite. See
[verification.md](verification.md) for what that does and does not prove.

Accumulator bound: with INT8 operands the running sum is limited by
`K · 128 · 128`, so `K` may reach 2¹⁷ before a 32-bit accumulator can overflow.
`model/golden.py:check_acc_range()` enforces this when generating vectors rather
than leaving it as a comment.
