#!/usr/bin/env python3
"""Verify FPGA pin assignments against a per-board reference.

A wrong pin assignment is the worst class of FPGA bug: everything compiles,
timing closes, the bitstream programs, and the board simply does nothing. There
is no error message and nothing to single-step. So the pin tables get the same
treatment as the arithmetic -- a checked-in reference and an automated diff.

Both boards are covered, because the failure mode does not care which vendor
produced the constraint file:

    DE10-Standard  syn/quartus/build_de10.tcl  vs  syn/quartus/de10_standard_pins.ref
    Zybo Z7-10     syn/vivado/zybo_z7_10.xdc   vs  syn/vivado/zybo_z7_10_pins.ref

Each reference cites its own source in its header. The Xilinx flow also carries
an I/O standard per pin, which is checked when the reference supplies one --
LVCMOS33 against a 1.8 V bank is a real hardware hazard, not a typo.

Usage:
    python3 scripts/check_pins.py             # exit 1 on any disagreement
    python3 scripts/check_pins.py de10        # one board only
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# Quartus: set_location_assignment PIN_AF14 -to CLOCK_50
QUARTUS_RE = re.compile(
    r"^\s*set_location_assignment\s+(PIN_[A-Z0-9]+)\s+-to\s+(\S+)\s*$"
)

# Vivado: set_property -dict { PACKAGE_PIN K17 IOSTANDARD LVCMOS33 } \
#             [get_ports { sysclk }]
# Commented-out template lines must not count as assignments, hence the
# leading-# exclusion -- Digilent master files ship every pin commented out, and
# a checker that read those would pass against a constraint file that assigns
# nothing at all.
VIVADO_RE = re.compile(
    r"^\s*set_property\s+-dict\s*\{\s*PACKAGE_PIN\s+(\S+)\s+"
    r"IOSTANDARD\s+(\S+)\s*\}\s*\[\s*get_ports\s*\{\s*(\S+)\s*\}\s*\]"
)

BOARDS = {
    "de10": {
        "name": "DE10-Standard",
        "ref": ROOT / "syn" / "quartus" / "de10_standard_pins.ref",
        "src": ROOT / "syn" / "quartus" / "build_de10.tcl",
        "flow": "quartus",
    },
    "zybo": {
        "name": "Zybo Z7-10",
        "ref": ROOT / "syn" / "vivado" / "zybo_z7_10_pins.ref",
        "src": ROOT / "syn" / "vivado" / "zybo_z7_10.xdc",
        "flow": "vivado",
    },
}


def load_reference(path: Path) -> dict:
    """signal -> (pin, iostandard or None)."""
    pins = {}
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        fields = line.split()
        signal, pin = fields[0], fields[1]
        std = fields[2] if len(fields) > 2 else None
        pins[signal] = (pin, std)
    return pins


def load_assignments(path: Path, flow: str) -> tuple[dict, list]:
    """signal -> (pin, iostandard or None), plus any duplicate-signal notes."""
    pins, notes = {}, []
    regex = QUARTUS_RE if flow == "quartus" else VIVADO_RE
    for lineno, line in enumerate(path.read_text().splitlines(), 1):
        if line.lstrip().startswith("#"):
            continue
        m = regex.match(line)
        if not m:
            continue
        if flow == "quartus":
            pin, std, signal = m.group(1), None, m.group(2)
        else:
            pin, std, signal = m.group(1), m.group(2), m.group(3)
        if signal in pins:
            notes.append(f"  DUPLICATE: {signal} assigned twice "
                         f"({pins[signal][0]} then {pin}, line {lineno})")
        pins[signal] = (pin, std)
    return pins, notes


def check_board(key: str) -> int:
    board = BOARDS[key]
    reference = load_reference(board["ref"])
    assigned, errors = load_assignments(board["src"], board["flow"])

    if not assigned:
        print(f"ERROR: no pin assignments found in "
              f"{board['src'].relative_to(ROOT)}")
        return 1

    for signal, (pin, std) in sorted(assigned.items()):
        want = reference.get(signal)
        if want is None:
            errors.append(f"  {signal:<12} {pin:<10} NOT IN REFERENCE "
                          f"(unknown signal for this board)")
            continue
        want_pin, want_std = want
        if want_pin != pin:
            errors.append(f"  {signal:<12} {pin:<10} WRONG -- "
                          f"board has {want_pin}")
        # Only checked when both sides state one; the Quartus flow sets its I/O
        # standard globally rather than per pin.
        if want_std and std and want_std != std:
            errors.append(f"  {signal:<12} {pin:<10} IOSTANDARD {std} -- "
                          f"board wants {want_std}")

    # Two signals on one physical pin fits every per-signal check individually
    # and still cannot be routed.
    by_pin = {}
    for signal, (pin, _) in assigned.items():
        by_pin.setdefault(pin, []).append(signal)
    for pin, signals in sorted(by_pin.items()):
        if len(signals) > 1:
            errors.append(f"  {pin} driven by multiple signals: "
                          f"{', '.join(sorted(signals))}")

    print(f"{board['name']:<14} {len(assigned):>3} assignments against "
          f"{len(reference):>3} reference pins", end="")

    if errors:
        print("   FAILED")
        for e in errors:
            print(e)
        print(f"  reference: {board['ref'].relative_to(ROOT)}")
        return 1

    print("   all match")
    return 0


def main(argv: list) -> int:
    wanted = argv[1:] or list(BOARDS)
    for key in wanted:
        if key not in BOARDS:
            print(f"unknown board '{key}' -- choose from "
                  f"{', '.join(BOARDS)}")
            return 2
    return max(check_board(k) for k in wanted)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
