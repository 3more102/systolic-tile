#!/usr/bin/env python3
"""Generate simulation vectors and the on-board self-test ROMs.

Everything downstream -- the RTL testbenches and the FPGA self-test that runs on
real hardware -- is checked against files produced here, so there is exactly one
definition of "correct" in the repository.

Usage:
    python3 model/gen_vectors.py            # write sim vectors + FPGA ROMs
    python3 model/gen_vectors.py --check    # regenerate ROMs and diff (CI)

Output layout:
    sim/vectors/<case>/{meta,a,w,bias,y}.hex   matmul cases for tb_systolic_tile
    sim/vectors/requant/vectors.hex            directed + fuzz cases for tb_requant
    rtl/fpga/rom/selftest_*.hex                committed ROMs for the FPGA build
    rtl/fpga/selftest_params.svh               committed geometry for the FPGA build
"""

from __future__ import annotations

import argparse
import filecmp
import shutil
import sys
import tempfile
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import golden  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
SIM_VECTORS = ROOT / "sim" / "vectors"
# The ROMs sit alongside tile_selftest.sv rather than in a subdirectory: Vivado
# resolves a bare $readmemh filename relative to the source file, so this is the
# one location all three toolchains find without extra search-path plumbing.
FPGA_ROM = ROOT / "rtl" / "fpga"
FPGA_PARAMS = ROOT / "rtl" / "fpga" / "selftest_params.svh"

ROWS = 8
COLS = 8

# The `quant` column is either an explicit (mult, shift) pair, None to auto-fit
# the output range, or a float meaning "auto-fit, then multiply the scale by
# this" -- which is how the saturation case is forced to clamp hard without
# clamping *everything* and thereby testing nothing else.
#
# name        M    K   relu  amplitude  quant
CASES = [
    ("basic",   4,   8, False,   8, (4096, 14)),   # scale exactly 1/4, hand-checkable
    ("single",  1,   8, False, 128, None),         # shortest legal stream
    ("multi",  16,  32, True,  128, None),         # 4 passes of K tiling + relu
    ("sat",     8,   8, False, 128, 6.0),          # ~6x overscale: clamps hard, not totally
    ("stress", 64,  64, False, 128, None),         # 8 passes, full INT8 range
]

# The case burned into the FPGA self-test ROMs.
SELFTEST_CASE = "multi"


def write_lines(path: Path, lines) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(lines) + "\n")


def build_case(name: str, m: int, k: int, relu: bool, amp: int, quant, seed: int):
    if k % ROWS:
        raise ValueError(f"case {name}: K={k} must be a multiple of ROWS={ROWS}")
    passes = k // ROWS

    rng = np.random.default_rng(seed)
    a = rng.integers(-amp, amp, size=(m, k), dtype=np.int64)
    w = rng.integers(-amp, amp, size=(k, COLS), dtype=np.int64)

    acc = golden.matmul_int32(a, w)
    golden.check_acc_range(acc)

    # Bias is sized from the accumulator it will be added to: big enough to
    # shift the result visibly, small enough that it cannot dominate. A fixed
    # absolute range would swamp the small cases entirely.
    bias_amp = max(1, int(np.percentile(np.abs(acc), 50)) // 4)
    bias = rng.integers(-bias_amp, bias_amp + 1, size=COLS, dtype=np.int64)

    biased = acc + bias[np.newaxis, :]
    if isinstance(quant, tuple):
        mult, shift = quant
    elif isinstance(quant, float):
        mult, shift = golden.choose_quant(biased, target=int(96 * quant))
    else:
        mult, shift = golden.choose_quant(biased)

    y = golden.requantize_vec(acc, bias, mult, shift, relu)

    # Count real clamps only. Under relu a y of 0 is usually just a negative
    # value being rectified, which is not the clamp path we care about covering.
    lo = 0 if relu else -128
    clamped = 0
    for i in range(m):
        for j in range(COLS):
            v = (int(acc[i, j]) + int(bias[j])) * mult
            if shift:
                v = (v + (1 << (shift - 1))) >> shift
            if v > 127 or v < lo:
                clamped += 1

    return dict(
        name=name, m=m, k=k, passes=passes, relu=relu,
        mult=mult, shift=shift, a=a, w=w, bias=bias, acc=acc, y=y,
        clamped=clamped,
    )


def emit_case(case: dict, outdir: Path) -> None:
    name = case["name"]
    outdir.mkdir(parents=True, exist_ok=True)

    write_lines(outdir / "meta.hex", [
        f"{case['m']:04x}",
        f"{case['k']:04x}",
        f"{COLS:04x}",
        f"{case['passes']:04x}",
        f"{case['mult']:04x}",
        f"{case['shift']:04x}",
        f"{int(case['relu']):04x}",
    ])
    write_lines(outdir / "a.hex",
                list(golden.activation_beats(case["a"], ROWS, case["passes"])))
    write_lines(outdir / "w.hex",
                list(golden.weight_beats(case["w"], ROWS, COLS, case["passes"])))
    write_lines(outdir / "bias.hex", [golden.pack_lanes(case["bias"], 32)])
    write_lines(outdir / "y.hex", list(golden.result_beats(case["y"])))

    pct = 100.0 * case["clamped"] / case["y"].size
    print(f"  {name:8s} M={case['m']:3d} K={case['k']:3d} passes={case['passes']} "
          f"relu={int(case['relu'])} mult={case['mult']:5d} shift={case['shift']:2d} "
          f"clamped={pct:5.1f}%")


# ---------------------------------------------------------------------------
# requant directed + fuzz vectors
# ---------------------------------------------------------------------------

def requant_vectors():
    """(acc, bias, mult, shift, relu) tuples, directed cases first.

    The rounding cases are the point of this list: round-half-up on a negative
    value is where a hand-written RTL shifter and a Python model most often
    disagree by one LSB.
    """
    directed = [
        (0, 0, 1, 0, False),            # pass-through of zero
        (0, 0, 1, 1, False),            # rounding term with a zero operand
        (1, 0, 1, 1, False),            # +0.5 rounds up to 1
        (-1, 0, 1, 1, False),           # -0.5 rounds up to 0, not down to -1
        (3, 0, 1, 1, False),            # +1.5 -> 2
        (-3, 0, 1, 1, False),           # -1.5 -> -1
        (127, 0, 1, 0, False),          # exactly the positive limit
        (128, 0, 1, 0, False),          # one past it -> clamps
        (-128, 0, 1, 0, False),         # exactly the negative limit
        (-129, 0, 1, 0, False),         # one past it -> clamps
        (-129, 0, 1, 0, True),          # relu floors at 0
        (-1, 0, 1, 0, True),            # relu on a small negative
        (100, 27, 1, 0, False),         # bias carries it to the limit
        (100, 28, 1, 0, False),         # bias carries it past the limit
        (2 ** 30, 0, 65535, 31, False),  # widest multiply, large shift
        (-(2 ** 30), 0, 65535, 31, True),
        (2 ** 31 - 1, 0, 1, 24, False),  # top of the INT32 range
        (-(2 ** 31), 0, 1, 24, False),   # bottom of the INT32 range
        (12345, -12345, 1234, 12, False),
        (-5000, 5000, 4321, 10, True),
    ]

    rng = np.random.default_rng(12345)
    fuzz = []
    for _ in range(300):
        acc = int(rng.integers(-(2 ** 24), 2 ** 24))
        bias = int(rng.integers(-(2 ** 16), 2 ** 16))
        mult = int(rng.integers(1, 65536))
        shift = int(rng.integers(0, 32))
        relu = bool(rng.integers(0, 2))
        fuzz.append((acc, bias, mult, shift, relu))
    return directed + fuzz


def emit_requant(outdir: Path) -> None:
    lines = []
    for acc, bias, mult, shift, relu in requant_vectors():
        y = golden.requantize(acc, bias, mult, shift, relu)
        lines.append(
            f"{acc & 0xffffffff:08x}"
            f"{bias & 0xffffffff:08x}"
            f"{mult & 0xffff:04x}"
            f"{shift & 0xff:02x}"
            f"{int(relu):02x}"
            f"{y & 0xff:02x}"
        )
    write_lines(outdir / "vectors.hex", lines)
    write_lines(outdir / "count.hex", [f"{len(lines):04x}"])
    print(f"  requant {len(lines)} vectors "
          f"({len(requant_vectors()) - 300} directed + 300 fuzz)")


# ---------------------------------------------------------------------------
# FPGA self-test ROMs
# ---------------------------------------------------------------------------

def emit_fpga(case: dict, romdir: Path, params: Path) -> None:
    romdir.mkdir(parents=True, exist_ok=True)
    write_lines(romdir / "selftest_a.hex",
                list(golden.activation_beats(case["a"], ROWS, case["passes"])))
    write_lines(romdir / "selftest_w.hex",
                list(golden.weight_beats(case["w"], ROWS, COLS, case["passes"])))
    write_lines(romdir / "selftest_bias.hex", [golden.pack_lanes(case["bias"], 32)])
    write_lines(romdir / "selftest_y.hex", list(golden.result_beats(case["y"])))

    params.write_text(
        "// AUTO-GENERATED by model/gen_vectors.py -- do not edit by hand.\n"
        f"// Source case: '{case['name']}' (M={case['m']}, K={case['k']}, "
        f"N={COLS}, relu={int(case['relu'])})\n"
        "//\n"
        "// Regenerate with:  python3 model/gen_vectors.py\n"
        "// CI checks these stay in sync with the model via --check.\n"
        f"localparam int ST_ROWS    = {ROWS};\n"
        f"localparam int ST_COLS    = {COLS};\n"
        f"localparam int ST_M       = {case['m']};\n"
        f"localparam int ST_PASSES  = {case['passes']};\n"
        f"localparam int ST_MULT    = {case['mult']};\n"
        f"localparam int ST_SHIFT   = {case['shift']};\n"
        f"localparam int ST_RELU    = {int(case['relu'])};\n"
        f"localparam int ST_A_DEPTH = {case['passes'] * case['m']};\n"
        f"localparam int ST_W_DEPTH = {case['passes'] * ROWS};\n"
        f"localparam int ST_Y_DEPTH = {case['m']};\n"
    )
    print(f"  fpga     self-test ROMs from case '{case['name']}' "
          f"({case['passes'] * case['m']} a-beats, {case['m']} y-beats)")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--check", action="store_true",
                    help="regenerate the committed FPGA ROMs and fail on any diff")
    args = ap.parse_args()

    print("generating vectors:")
    cases = {}
    for seed, (name, m, k, relu, amp, quant) in enumerate(CASES):
        case = build_case(name, m, k, relu, amp, quant, seed=seed)
        cases[name] = case
        emit_case(case, SIM_VECTORS / name)

    emit_requant(SIM_VECTORS / "requant")
    write_lines(SIM_VECTORS / "cases.txt", [c[0] for c in CASES])

    st = cases[SELFTEST_CASE]
    if args.check:
        tmp = Path(tempfile.mkdtemp())
        emit_fpga(st, tmp / "rom", tmp / "selftest_params.svh")
        stale = []
        for f in sorted((tmp / "rom").iterdir()):
            if not (FPGA_ROM / f.name).exists() or \
                    not filecmp.cmp(f, FPGA_ROM / f.name, shallow=False):
                stale.append(f"rtl/fpga/{f.name}")
        if not FPGA_PARAMS.exists() or \
                not filecmp.cmp(tmp / "selftest_params.svh", FPGA_PARAMS, shallow=False):
            stale.append("rtl/fpga/selftest_params.svh")
        shutil.rmtree(tmp)
        if stale:
            print("\nERROR: committed FPGA self-test data is out of sync with the model:")
            for s in stale:
                print(f"  {s}")
            print("Run: python3 model/gen_vectors.py")
            return 1
        print("\ncommitted FPGA self-test data matches the model")
        return 0

    emit_fpga(st, FPGA_ROM, FPGA_PARAMS)
    print("\ndone")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
