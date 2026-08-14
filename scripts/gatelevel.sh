#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Post-synthesis gate-level simulation.
#
# Everything else in this repo simulates the RTL. This synthesises it to gates
# with Yosys and runs the *same* self-checking testbench against the netlist,
# against the *same* golden vectors. Three things it can catch that RTL
# simulation cannot:
#
#   - RTL that simulates one way and synthesises another, which is the entire
#     reason gate-level simulation exists;
#   - X propagation from reset, because a netlist flip-flop starts at x and only
#     a real reset path clears it, where `logic` in RTL is often quietly
#     forgiving;
#   - a construct that Icarus accepts and no synthesiser will map at all.
#
# What it does not prove: this is Yosys's generic synthesis, not Quartus's or
# Vivado's, so it says nothing about either vendor's optimiser or about timing.
#
# --self-test re-runs the flow against a deliberately broken copy and requires
# it to fail, at the cheap geometry. A checker that cannot fail is not a checker.
#
# Overridable: YOSYS, IVERILOG, VVP, PYTHON, SIMCELLS,
#              GL_ROWS, GL_COLS, GL_MAX_M, GL_CASES, GL_BPS
# -----------------------------------------------------------------------------
set -eu

cd "$(dirname "$0")/.."

YOSYS=${YOSYS:-yosys}
IVERILOG=${IVERILOG:-iverilog}
VVP=${VVP:-vvp}
PYTHON=${PYTHON:-python3}

# 8x8 is the geometry both boards build, so it is the one worth the compile.
GL_ROWS=${GL_ROWS:-8}
GL_COLS=${GL_COLS:-8}

# The accumulator is a block RAM on an FPGA and a $mem to Yosys, but `synth`
# maps it to flip-flops -- at the shipped MAX_M=256 that is 64 kbit of them, and
# Icarus would be elaborating the read mux for a long time. 8 rows is enough for
# every case listed below and keeps the netlist at ~105k cells.
GL_MAX_M=${GL_MAX_M:-8}

# Cases whose M fits GL_MAX_M, checked below rather than trusted. `sat` earns its
# place here: it clamps on ~55% of outputs, so it exercises the saturation logic
# that a synthesiser is most likely to rewrite.
GL_CASES=${GL_CASES:-"basic single sat"}
GL_BPS=${GL_BPS:-"0 1 2"}

WORK=gl/work
CHECK=$PWD/scripts/run_check.sh
LOG=$(mktemp)
mut=""
trap 'rm -rf "$LOG" ${mut:+"$mut"}' EXIT

# simcells.v defines the $_AND_/$_DFFE_PN0P_ primitives write_verilog emits.
# yosys-config is not always installed, so fall back to walking from the binary.
if [ -z "${SIMCELLS:-}" ]; then
    for c in "$(yosys-config --datdir 2>/dev/null)/simcells.v" \
             /usr/share/yosys/simcells.v \
             "$(dirname "$(readlink -f "$(command -v "$YOSYS")")")/../share/yosys/simcells.v"; do
        [ -f "$c" ] && { SIMCELLS=$c; break; }
    done
fi
[ -n "${SIMCELLS:-}" ] && [ -f "$SIMCELLS" ] || {
    echo "  Could not find simcells.v. Set SIMCELLS to its path."
    exit 1
}

[ -f sim/vectors/cases.txt ] || $PYTHON model/gen_vectors.py >/dev/null

# Build a netlist from $1 into $2. The reads live here rather than in
# gl/synth.ys so --self-test can point the same recipe at a mutated copy.
synth_to () {
    local src=$1 out=$2 reads="" m
    for m in mac_pe skew_buffer pe_array accum_bank requant out_fifo tile_ctrl systolic_tile; do
        reads="$reads read_verilog -sv $src/$m.sv;"
    done

    # One -p string with `script`, not -s: yosys runs every -s file before any
    # -p command whatever their command-line order, which would put the synth
    # before the -chparam overrides. Same trap as scripts/lint.sh.
    if ! "$YOSYS" -q -p "
        $reads
        hierarchy -check -top systolic_tile \
            -chparam ROWS $GL_ROWS -chparam COLS $GL_COLS -chparam MAX_M $GL_MAX_M;
        script gl/synth.ys;
        tee -q -o $out.stat stat;
        write_verilog -noattr $out" >"$LOG" 2>&1
    then
        echo "  SYNTHESIS FAILED"
        echo "  --- last 20 lines from yosys ---"
        grep -v '^Warning: Replacing memory' "$LOG" | tail -20 | sed 's/^/  /'
        exit 1
    fi
}

# Compile $1 into $2. TB_GATELEVEL drops the testbench's two hierarchical probes
# into dut.en -- a net that does not survive synthesis -- and nothing else.
compile_to () {
    "$IVERILOG" -g2012 -Wno-timescale -o "$2" -s tb_systolic_tile \
        -DTB_ROWS="$GL_ROWS" -DTB_COLS="$GL_COLS" -DTB_MAX_M="$GL_MAX_M" \
        -DTB_GATELEVEL \
        sim/timescale.v "$SIMCELLS" "$1" gl/gl_shim.sv tb/tb_systolic_tile.sv
}

mkdir -p "$WORK"

echo "  gate-level: ${GL_ROWS}x${GL_COLS}, MAX_M=$GL_MAX_M"
echo "  using: $("$YOSYS" -V 2>/dev/null | head -1)"

# meta.hex line 1 is M in hex. A case that needs more output rows than the
# accumulator has would wrap its address and fail with a wall of wrong data --
# true, but a rotten way to find out the case list and GL_MAX_M disagree.
for c in $GL_CASES; do
    meta=sim/vectors/$c/meta.hex
    [ -f "$meta" ] || { echo "  no vectors for case '$c' -- run 'make vectors'"; exit 1; }
    m=$((16#$(head -1 "$meta" | tr -d '\r')))
    [ "$m" -le "$GL_MAX_M" ] || {
        echo "  case '$c' needs M=$m output rows but GL_MAX_M is $GL_MAX_M."
        exit 1
    }
done

synth_to rtl "$WORK/netlist.v"
echo "  synth  $(awk '/Number of cells/{n=$NF} END{print n}' "$WORK/netlist.v.stat") cells"

# Icarus spends several minutes elaborating ~105k cell instances at 8x8. The
# binary is reused across every case and backpressure mode below.
compile_to "$WORK/netlist.v" "$WORK/gl.vvp"

for c in $GL_CASES; do
    for b in $GL_BPS; do
        (cd sim && "$CHECK" "$VVP" "../$WORK/gl.vvp" +case="vectors/$c" +bp="$b") >/dev/null \
            || { echo "  GATE-LEVEL FAILED: case $c, bp=$b"
                 (cd sim && "$VVP" "../$WORK/gl.vvp" +case="vectors/$c" +bp="$b") | tail -20
                 exit 1; }
    done
    echo "  gates  $c: matches the model over ${GL_BPS// /, } backpressure modes"
done

# ---------------------------------------------------------------------------
# Does the check still have teeth?
#
# The mutation drops the round-half-up term before the arithmetic shift, turning
# the requantiser into a truncating one. It synthesises perfectly, it is a
# plausible thing to write by accident, and it is invisible to anything that
# does not compare bit-exactly against the model -- which makes it the right
# thing to demand this flow notice.
#
# Run at 4x4, because what is being tested is that the netlist reaches the
# testbench's verdict at all, and that is not geometry-dependent. At 8x8 it
# would cost another seven minutes of Icarus elaboration to learn the same fact.
# ---------------------------------------------------------------------------
if [ "${1:-}" = "--self-test" ]; then
    GL_ROWS=4 GL_COLS=4

    mut=$(mktemp -d)
    cp rtl/*.sv "$mut/"
    sed -i 's/= (prod_q + rnd) >>> shift1;/= (prod_q) >>> shift1;/' "$mut/requant.sv"
    grep -q '= (prod_q) >>> shift1;' "$mut/requant.sv" || {
        echo "  SELF-TEST BROKEN: the mutation did not apply; rtl/requant.sv moved."
        exit 1
    }

    synth_to "$mut" "$WORK/netlist_mut.v"
    compile_to "$WORK/netlist_mut.v" "$WORK/gl_mut.vvp"

    if (cd sim && "$CHECK" "$VVP" "../$WORK/gl_mut.vvp" +case=vectors/tiny +bp=0) >/dev/null 2>&1; then
        echo "  SELF-TEST FAILED: a truncating requantiser passed. The netlist is not"
        echo "  reaching the testbench's comparison against model/golden.py."
        exit 1
    fi
    echo "  self-test  a truncating requantiser is caught"
fi
