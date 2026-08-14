#!/usr/bin/env bash
# Run a simulation and turn its self-check verdict into an exit code.
#
# Icarus exits 0 even when a testbench reports failures, so the verdict has to
# come from the output. Requiring "RESULT: PASS" to be *present* (rather than
# looking for "FAIL") also catches a simulation that hung or died before it
# reached its final report.
#
# Usage: run_check.sh <command> [args...]
set -u

out=$("$@" 2>&1)
status=$?
echo "$out"

if [ $status -ne 0 ]; then
    echo "*** FAILED (exit $status): $*" >&2
    exit 1
fi

if echo "$out" | grep -q "RESULT: PASS"; then
    exit 0
fi

echo "*** FAILED (no PASS verdict): $*" >&2
exit 1
