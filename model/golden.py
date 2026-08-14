"""Bit-exact reference model for the systolic tile.

Everything the RTL does is defined here first; rtl/ is an implementation of this
file, and tb/ only ever compares against it. Keeping the arithmetic in plain
Python ints (arbitrary precision) makes the intent unambiguous -- the widths in
the RTL are then chosen to be wide enough that they never truncate.

The one subtlety worth stating out loud: Python's ``>>`` on a negative int is a
floor shift, and so is Verilog's ``>>>`` on a signed operand. That is why
``requantize`` below and rtl/requant.sv agree on negative values, which is where
naive implementations usually diverge by one LSB.
"""

from __future__ import annotations

import numpy as np

INT8_MIN, INT8_MAX = -128, 127
INT32_MIN, INT32_MAX = -(2 ** 31), 2 ** 31 - 1


def matmul_int32(a: np.ndarray, w: np.ndarray) -> np.ndarray:
    """A[M,K] @ W[K,N] in exact integer arithmetic, returned as int64.

    The RTL accumulator is 32 bits wide. With INT8 operands the running sum is
    bounded by K * 128 * 128, so K may go up to 2**17 before it can overflow;
    ``check_acc_range`` enforces that rather than leaving it implicit.
    """
    a = np.asarray(a, dtype=np.int64)
    w = np.asarray(w, dtype=np.int64)
    return a @ w


def check_acc_range(acc: np.ndarray) -> None:
    lo, hi = int(acc.min()), int(acc.max())
    if lo < INT32_MIN or hi > INT32_MAX:
        raise ValueError(
            f"accumulator range [{lo}, {hi}] does not fit the 32-bit datapath"
        )


def requantize(acc: int, bias: int, mult: int, shift: int, relu: bool) -> int:
    """INT32 accumulator -> INT8, matching rtl/requant.sv exactly.

        y = clamp( (acc + bias) * mult  rounded>> shift )

    Rounding is round-half-up on the signed value. ``shift == 0`` is a plain
    pass-through with no rounding term, mirroring the RTL.
    """
    v = int(acc) + int(bias)
    v *= int(mult)
    if shift > 0:
        v = (v + (1 << (shift - 1))) >> shift
    lo = 0 if relu else INT8_MIN
    return max(lo, min(INT8_MAX, v))


def requantize_vec(acc: np.ndarray, bias: np.ndarray, mult: int, shift: int,
                   relu: bool) -> np.ndarray:
    """Vectorised ``requantize`` over an [M, N] accumulator with a per-N bias."""
    acc = np.asarray(acc, dtype=object)
    out = np.empty(acc.shape, dtype=np.int64)
    for m in range(acc.shape[0]):
        for n in range(acc.shape[1]):
            out[m, n] = requantize(int(acc[m, n]), int(bias[n]), mult, shift, relu)
    return out


def tile_reference(a: np.ndarray, w: np.ndarray, bias: np.ndarray,
                   mult: int, shift: int, relu: bool) -> tuple:
    """Full reference: returns (acc_int32, y_int8)."""
    acc = matmul_int32(a, w)
    check_acc_range(acc)
    y = requantize_vec(acc, bias, mult, shift, relu)
    return acc, y


def choose_quant(acc: np.ndarray, target: int = 96, shift: int = 20) -> tuple:
    """Pick (mult, shift) so a typical output lands near +/-``target``.

    Chosen from the 99th percentile of |acc| so that a handful of values still
    clamp -- a test where nothing ever saturates would leave the clamp logic
    uncovered.
    """
    scale_ref = np.percentile(np.abs(np.asarray(acc, dtype=np.float64)), 99)
    scale_ref = max(scale_ref, 1.0)
    mult = int(round((target / scale_ref) * (2 ** shift)))
    mult = max(1, min(65535, mult))
    return mult, shift


# ---------------------------------------------------------------------------
# Stream ordering -- the contract between model, RTL and testbench.
# ---------------------------------------------------------------------------

def pack_lanes(values, width_bits: int) -> str:
    """Pack lane 0 into the LSBs, matching bus[lane*W +: W] in the RTL.

    Hex strings are written MSB first, so the highest lane appears leftmost.
    """
    nibbles = width_bits // 4
    mask = (1 << width_bits) - 1
    return "".join(f"{int(v) & mask:0{nibbles}x}" for v in reversed(list(values)))


def activation_beats(a: np.ndarray, rows: int, passes: int):
    """One beat per (pass, output row): lane r carries A[m][pass*rows + r]."""
    m_len = a.shape[0]
    for p in range(passes):
        for m in range(m_len):
            yield pack_lanes(a[m, p * rows:(p + 1) * rows], 8)


def weight_beats(w: np.ndarray, rows: int, cols: int, passes: int):
    """One beat per (pass, array row), array row ``rows-1`` FIRST.

    The shadow chain pushes from the top of each column, so the first beat
    travels furthest and lands in the bottom row. See rtl/pe_array.sv.
    """
    for p in range(passes):
        for i in range(rows):
            k = p * rows + (rows - 1 - i)
            yield pack_lanes(w[k, :cols], 8)


def result_beats(y: np.ndarray):
    """One beat per output row, lane n carrying Y[m][n]."""
    for m in range(y.shape[0]):
        yield pack_lanes(y[m, :], 8)


if __name__ == "__main__":
    rng = np.random.default_rng(0)
    a = rng.integers(-8, 8, size=(4, 8), dtype=np.int64)
    w = rng.integers(-8, 8, size=(8, 8), dtype=np.int64)
    bias = np.zeros(8, dtype=np.int64)
    acc, y = tile_reference(a, w, bias, mult=4096, shift=14, relu=False)
    print("acc[0] =", acc[0])
    print("y[0]   =", y[0])
