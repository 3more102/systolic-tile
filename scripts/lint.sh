#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Structural check, run once per array geometry.
#
# Only 8x8 is elaborated by the two vendor builds, so only 8x8 is proven to
# synthesise by them. The other geometries live in the simulation suite, which
# proves they *behave* correctly and says nothing about whether they *build* --
# a latch inferred only at 4x8, or a net left undriven only at 16x16, would sit
# there undetected. This closes that gap for the price of four seconds of CI.
#
# The PE count assertion is the part that makes the sweep more than a smoke
# test: it fails if the array elaborated the wrong number of multiply-accumulate
# cells, which is what a ROWS/COLS mix-up looks like after elaboration.
#
# Overridable: YOSYS, GEOMS
# -----------------------------------------------------------------------------
set -eu

cd "$(dirname "$0")/.."

YOSYS=${YOSYS:-yosys}

# Must agree with the `rows`/`cols` columns in model/gen_vectors.py. The two
# lists are separate because this job runs without Python and without generated
# vectors; a disagreement is not dangerous -- it means a geometry is linted but
# not simulated, or the reverse -- but the point of the sweep is that they match.
GEOMS=${GEOMS:-"8x8 4x4 4x8 16x16"}

for g in $GEOMS; do
    rows=${g%x*}
    cols=${g#*x}
    pes=$((rows * cols))

    # The two files are pulled in with the `script` command rather than with
    # -s, because yosys runs every -s file before any -p command no matter what
    # order they appear in on the command line -- so -s read -p hierarchy -s
    # check would silently run the checks *before* elaborating, and then fail on
    # latches that elaboration would have removed. Inside one -p string the
    # order is exactly as written.
    #
    # `select -clear` matters too: an assertion leaves its selection active, and
    # every command after it would otherwise operate on that subset alone.
    "$YOSYS" -q -p "
        script syn/yosys/read_design.ys;
        hierarchy -check -top systolic_tile -chparam ROWS $rows -chparam COLS $cols;
        select -assert-count $pes */t:*mac_pe*;
        select -clear;
        script syn/yosys/synth_check.ys;
        tee -q -o syn/yosys/stat_$g.txt stat -top systolic_tile"

    echo "  yosys ${rows}x${cols}: $pes PEs, no latches, no undriven or multiply-driven nets"
done
