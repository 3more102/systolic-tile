#!/usr/bin/env python3
"""Verify DE10-Standard pin assignments against the board reference.

A wrong pin assignment is the worst class of FPGA bug: everything compiles,
timing closes, the bitstream programs, and the board simply does nothing. There
is no error message and nothing to single-step. So the pin table gets the same
treatment as the arithmetic -- a checked-in reference and an automated diff.

The reference (syn/quartus/de10_standard_pins.ref) is transcribed from Terasic's
golden top and cross-checked against independent sources; see its header.

Usage:
    python3 scripts/check_de10_pins.py        # exit 1 on any disagreement
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
REF = ROOT / "syn" / "quartus" / "de10_standard_pins.ref"
TCL = ROOT / "syn" / "quartus" / "build_de10.tcl"

# set_location_assignment PIN_AF14 -to CLOCK_50
ASSIGN_RE = re.compile(
    r"^\s*set_location_assignment\s+(PIN_[A-Z0-9]+)\s+-to\s+(\S+)\s*$"
)


def load_reference() -> dict:
    pins = {}
    for line in REF.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        signal, pin = line.split()
        pins[signal] = pin
    return pins


def load_assignments() -> dict:
    pins = {}
    for lineno, line in enumerate(TCL.read_text().splitlines(), 1):
        m = ASSIGN_RE.match(line)
        if m:
            pin, signal = m.group(1), m.group(2)
            if signal in pins:
                print(f"  DUPLICATE: {signal} assigned twice "
                      f"({pins[signal]} then {pin}, line {lineno})")
            pins[signal] = pin
    return pins


def main() -> int:
    reference = load_reference()
    assigned = load_assignments()

    if not assigned:
        print("ERROR: no pin assignments found in syn/quartus/build_de10.tcl")
        return 1

    errors = []
    for signal, pin in sorted(assigned.items()):
        want = reference.get(signal)
        if want is None:
            errors.append(f"  {signal:<12} {pin:<10} NOT IN REFERENCE "
                          f"(unknown signal for this board)")
        elif want != pin:
            errors.append(f"  {signal:<12} {pin:<10} WRONG -- board has {want}")

    # Two signals assigned to the same physical pin fits every per-signal check
    # individually and still cannot be routed.
    by_pin = {}
    for signal, pin in assigned.items():
        by_pin.setdefault(pin, []).append(signal)
    for pin, signals in sorted(by_pin.items()):
        if len(signals) > 1:
            errors.append(f"  {pin} driven by multiple signals: "
                          f"{', '.join(sorted(signals))}")

    print(f"DE10-Standard pin check: {len(assigned)} assignments against "
          f"{len(reference)} reference pins")

    if errors:
        print("\nFAILED:")
        for e in errors:
            print(e)
        print(f"\nReference: {REF.relative_to(ROOT)}")
        return 1

    print("all assignments match the board reference")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
