#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Mutation score for the simulation suite.
#
# Every other gate here asks "does the design pass?". This one asks the question
# underneath that: **would these tests notice if it didn't?** It injects one
# deliberate bug at a time into a copy of the RTL and requires the testbench to
# fail. A mutant that survives is a real hole -- a behaviour the suite cannot
# distinguish from correct.
#
# Each verification tier in this repo already ships with one hand-picked mutation
# it must catch (see scripts/formal.sh and scripts/gatelevel.sh). This is the
# same idea applied across the whole RTL, and turned into a number.
#
# The mutants are in mut/mutants.txt, one per line, with the rationale for the
# list -- and for what is deliberately not in it -- at the top of that file.
#
# Deliberately fast: a reduced case set, and the first failing run kills the
# mutant and moves on. The point is coverage of the *bugs*, not of the cases.
#
# Overridable: IVERILOG, VVP, PYTHON, MUT_RUNS
# -----------------------------------------------------------------------------
set -eu

cd "$(dirname "$0")/.."

IVERILOG=${IVERILOG:-iverilog}
VVP=${VVP:-vvp}
PYTHON=${PYTHON:-python3}

# case:geometry:backpressure, tried in this order and stopped at the first
# failure. `multi` first because K-tiling plus ReLU plus backpressure exercises
# the most mechanisms at once, and `rect` is here because it is the only
# non-square geometry -- a ROWS/COLS interchange is invisible everywhere else.
# `stress:8x8:1` earns its place on its own: it is the only entry here that
# kills the mac_pe freeze mutant (registers that ignore `en`), which needs the
# long run and the specific bubble timing that bp=1 produces on the largest
# case to ever diverge from a correct design. Found by running the full
# 8-case x 4-geometry x 3-bp suite against that mutant when this shortlist
# first reported it as a survivor.
MUT_RUNS=${MUT_RUNS:-"multi:8x8:2 multi:8x8:0 sat:8x8:2 rect:4x8:0 rect:4x8:2 stress:8x8:1"}

MODULES="mac_pe skew_buffer pe_array accum_bank requant out_fifo tile_ctrl systolic_tile"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

[ -f sim/vectors/cases.txt ] || $PYTHON model/gen_vectors.py >/dev/null

# Build tb_systolic_tile against the RTL in $1 at geometry $2, into $3.
build () {
    local src=$1 geom=$2 out=$3 srcs="" m
    for m in $MODULES; do srcs="$srcs $src/$m.sv"; done

    # shellcheck disable=SC2086
    "$IVERILOG" -g2012 -Wno-timescale -o "$out" -s tb_systolic_tile \
        -DTB_ROWS="${geom%x*}" -DTB_COLS="${geom#*x}" \
        sim/timescale.v $srcs tb/tb_systolic_tile.sv 2>/dev/null
}

# 0 if the run reports PASS. Anything else -- a FAIL verdict, a crash, a hang
# cut short by $finish never arriving -- counts as the mutant being caught,
# which is the correct reading: the suite noticed.
passes () {
    (cd sim && "$VVP" "$1" +case="vectors/$2" +bp="$3" 2>&1) | grep -q "RESULT: PASS"
}

# Run the case set against the RTL in $1. Prints the run that failed, if any.
first_failure () {
    local src=$1 r c g b bin
    for r in $MUT_RUNS; do
        c=${r%%:*}; g=$(echo "$r" | cut -d: -f2); b=${r##*:}
        bin=$WORK/$(basename "$src")_$g.vvp
        [ -f "$bin" ] || build "$src" "$g" "$bin" || { echo "build:$g"; return 0; }
        passes "$bin" "$c" "$b" || { echo "$c bp=$b"; return 0; }
    done
    return 1
}

# --------------------------------------------------------------------- baseline
# If the unmutated design does not pass this subset, every mutant below would be
# scored as killed for the wrong reason and the score would be a fiction.
echo "  mutation score for: ${MUT_RUNS// /, }"
if bad=$(first_failure rtl); then
    echo "  BASELINE BROKEN: unmutated RTL fails '$bad'. Fix that before reading any score."
    exit 1
fi
echo "  baseline  unmutated RTL passes all $(echo "$MUT_RUNS" | wc -w) runs"

# --------------------------------------------------------------------- mutants
killed=0
total=0
survivors=""

while IFS='|' read -r file from to desc; do
    case "${file# }" in ''|'#'*) continue;; esac
    total=$((total + 1))

    src=$WORK/m$total
    mkdir -p "$src"
    cp rtl/*.sv "$src/"

    # Fixed-string, exactly-once replacement. A `from` that no longer matches is
    # a stale mutant list, not a surviving mutant, and must not be scored as one.
    n=$(grep -cF "$from" "$src/$(basename "$file")")
    if [ "$n" != "1" ]; then
        echo "  STALE MUTANT $total: '$from' matches $n times in $file (want 1)."
        echo "  mut/mutants.txt is out of date with the RTL."
        exit 1
    fi
    $PYTHON - "$src/$(basename "$file")" "$from" "$to" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1])
p.write_text(p.read_text().replace(sys.argv[2], sys.argv[3]))
PY

    if caught=$(first_failure "$src"); then
        killed=$((killed + 1))
        printf '  killed    %-58s (%s)\n' "$desc" "$caught"
    else
        survivors="$survivors\n    - $desc [$file]"
        printf '  SURVIVED  %s\n' "$desc"
    fi
    rm -rf "$src"
done < mut/mutants.txt

echo ""
echo "  mutation score: $killed / $total"

if [ "$killed" != "$total" ]; then
    # A survivor is a fact about the test suite, not an accident. It is reported
    # and it fails the run, because the alternative is a number that drifts
    # downward one quiet commit at a time.
    printf '  survivors -- behaviours these tests cannot distinguish from correct:%b\n' "$survivors"
    exit 1
fi
