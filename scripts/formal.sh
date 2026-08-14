#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Bounded model check of the backpressure scheme.
#
# The simulation suite drives the tile with the stimulus somebody thought to
# write. This proves four properties over *every* input sequence within a bound:
# the ones in rtl/out_fifo.sv, rtl/tile_ctrl.sv and rtl/systolic_tile.sv, guarded
# by `ifdef FORMAL so no other tool in this repo ever sees them.
#
# Nothing beyond yosys is needed -- `sat` uses the solver built into it, so this
# runs in the same CI job that already installs yosys, with no SMT solver, no
# SymbiYosys and no license.
#
# Three things this script does that a bare `sat -prove-asserts` does not:
#
#   1. It runs cover queries first. A bounded proof over a design that never
#      reaches the interesting state is green and worthless. These ask the
#      solver to *find* a trace that produces a result beat, that asserts
#      stall, and that fills the FIFO to its threshold -- so if a future change
#      slows the pipeline past the bound, CI says the bound is too short instead
#      of quietly proving nothing.
#
#   2. It checks a small geometry, because that is what terminates. See
#      docs/verification.md for what that does and does not buy.
#
#   3. --self-test re-runs the proof against a deliberately broken copy and
#      requires it to fail. A checker that cannot fail is not a checker.
#
# About five minutes and 1.5 GB, nearly all of it in the two proofs.
#
# Overridable: YOSYS, FV_ROWS, FV_COLS, FV_MAX_M, FV_FIFO_DEPTH, FV_DEPTH,
#              FV_ASSERTS
# -----------------------------------------------------------------------------
set -eu

cd "$(dirname "$0")/.."

YOSYS=${YOSYS:-yosys}

# The properties are about control, and the control structure does not change
# with the array size -- but the solver's work does, steeply. 2x2 with a
# 4-entry accumulator is the smallest instance that still contains every
# mechanism the properties talk about: a skew, a deskew, a K-tiling accumulator,
# a requant stage and the FIFO whose occupancy drives the global enable.
#
# FIFO_DEPTH stays at the shipped 8. Shrinking it would reach the full-FIFO
# state sooner and cost less, but the whole point of F1 is the arithmetic
# relating the stall threshold to the depth, and that is the number the boards
# are built with.
ROWS=${FV_ROWS:-2}
COLS=${FV_COLS:-2}
MAX_M=${FV_MAX_M:-4}
FIFO_DEPTH=${FV_FIFO_DEPTH:-8}

# Measured, not guessed: every cover below passes at 24 steps, so 32 leaves room
# for the design to grow a few cycles slower before the covers start failing.
DEPTH=${FV_DEPTH:-32}

THRESH=$((FIFO_DEPTH - 2))

MODULES="mac_pe skew_buffer pe_array accum_bank requant out_fifo tile_ctrl systolic_tile"

# One yosys run over $1, ending in the sat command $2. Returns yosys's status.
#
# Everything goes in a single -p string and the shared lowering is pulled in with
# yosys's own `script` command: yosys runs every -s file before any -p command
# regardless of their order on the command line, so mixing the two would run the
# lowering before the hierarchy overrides. Same trap as scripts/lint.sh.
fv_run () {
    local src=$1 sat_cmd=$2 reads="" m
    for m in $MODULES; do reads="$reads read_verilog -sv -formal -DFORMAL $src/$m.sv;"; done

    "$YOSYS" -q -p "
        $reads
        hierarchy -check -top systolic_tile \
            -chparam ROWS $ROWS -chparam COLS $COLS \
            -chparam MAX_M $MAX_M -chparam FIFO_DEPTH $FIFO_DEPTH;
        script fv/prep.ys;
        $sat_cmd" >/dev/null 2>&1
}

# A cover: -verify makes yosys fail when the solver finds no model, so success
# here means "this state is reachable within DEPTH steps".
cover () {
    if fv_run rtl "sat -seq $DEPTH -set-at 1 rst_n 0 -set-at $DEPTH $1 $2 -verify"; then
        echo "  cover  $3"
    else
        echo "  COVER FAILED: $3 is unreachable within $DEPTH steps."
        echo "  The proof would still pass, and would prove nothing. Raise FV_DEPTH."
        exit 1
    fi
}

PROOF="sat -prove-asserts -verify -seq $DEPTH -set-at 1 rst_n 0"

# The count in the summary line is not typed by hand -- yosys asserts it. A
# property added without updating this number, or an `ifdef FORMAL block that
# silently stopped elaborating, would otherwise show up as a green run whose
# summary quietly overstates what was proved. This costs no SAT time.
NASSERTS=${FV_ASSERTS:-8}

echo "  formal: ${ROWS}x${COLS}, MAX_M=$MAX_M, FIFO_DEPTH=$FIFO_DEPTH, $DEPTH steps from reset"

if ! fv_run rtl "select -assert-count $NASSERTS t:\$assert"; then
    echo "  ASSERTION COUNT CHANGED: the design does not lower to $NASSERTS assertions."
    echo "  Set FV_ASSERTS, or fix the \`ifdef FORMAL block that stopped elaborating."
    exit 1
fi

cover rq_valid       1        "a result beat is produced"
cover stall          1        "backpressure engages"
cover u_fifo.count   $THRESH  "the FIFO reaches its stall threshold"

if fv_run rtl "$PROOF"; then
    echo "  proof  $NASSERTS assertions hold over every input sequence of $DEPTH steps"
else
    echo "  PROOF FAILED"
    exit 1
fi

# ---------------------------------------------------------------------------
# Does the check still have teeth?
#
# The mutation drops the `&& en` from the FIFO write enable -- the single
# documented hazard of this design, and the one thing every comment about
# backpressure in the RTL warns about. A frozen requant stage holds its valid
# high, so an unqualified write pushes the same beat in on every stalled cycle
# until the FIFO is full and the next one is discarded. F1 must catch it.
# ---------------------------------------------------------------------------
if [ "${1:-}" = "--self-test" ]; then
    mut=$(mktemp -d)
    trap 'rm -rf "$mut"' EXIT
    cp rtl/*.sv "$mut/"
    sed -i 's/\.wr_en    (rq_valid && en)/.wr_en    (rq_valid)/' "$mut/systolic_tile.sv"
    grep -q '\.wr_en    (rq_valid)' "$mut/systolic_tile.sv" || {
        echo "  SELF-TEST BROKEN: the mutation did not apply; rtl/systolic_tile.sv moved."
        exit 1
    }

    if fv_run "$mut" "$PROOF"; then
        echo "  SELF-TEST FAILED: the proof passed on a design with an unqualified"
        echo "  FIFO write. It is not proving what it claims -- most likely FV_DEPTH"
        echo "  is too short to reach the overflow."
        exit 1
    fi
    echo "  self-test  an unqualified FIFO write is caught"
fi
