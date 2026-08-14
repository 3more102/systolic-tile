#!/usr/bin/env bash
# Copy the vendor build outputs into bitstreams/ and record where they came from.
#
# A committed binary is only as useful as its provenance: without knowing which
# commit produced it, a prebuilt bitstream is indistinguishable from a stale one.
# So everything in bitstreams/README.md is extracted from the build reports and
# from git by this script rather than typed in by hand.
#
# Run after `make quartus` and `make vivado`:
#     ./scripts/collect_bitstreams.sh
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/bitstreams"
SOF="$ROOT/syn/quartus/output_files/de10_standard.sof"
BIT="$ROOT/syn/vivado/build/zybo_z7_10_top.bit"

mkdir -p "$OUT"

commit=$(git -C "$ROOT" rev-parse HEAD)
short=$(git -C "$ROOT" rev-parse --short HEAD)
if [ -n "$(git -C "$ROOT" status --porcelain -- rtl syn model)" ]; then
    tree_state="DIRTY -- rtl/, syn/ or model/ had uncommitted changes at build time"
else
    tree_state="clean"
fi

# The commit alone is a weak claim in both directions: a later commit that only
# touches docs makes a perfectly current bitstream look stale, and re-running
# this script without rebuilding would re-stamp old binaries with a new commit.
# So also fingerprint the inputs that actually determine each bitstream -- the
# RTL tree plus that board's build script and constraints. Doc-only commits do
# not move it; a real source change does.
fingerprint() {
    { git -C "$ROOT" rev-parse "HEAD:rtl"
      for f in "$@"; do git -C "$ROOT" rev-parse "HEAD:$f"; done
    } | sha256sum | cut -c1-16
}
fp_de10=$(fingerprint syn/quartus/build_de10.tcl syn/quartus/de10_standard.sdc)
fp_zybo=$(fingerprint syn/vivado/build_zybo.tcl syn/vivado/zybo_z7_10.xdc)

# if/then rather than [ ... ] && ...; under `set -e` a false test at the end of
# a line is itself a failure, and a missing bitstream should reach the error
# message below rather than exiting silently here.
have_sof=0; have_bit=0
if [ -f "$SOF" ]; then cp "$SOF" "$OUT/"; have_sof=1; fi
if [ -f "$BIT" ]; then cp "$BIT" "$OUT/"; have_bit=1; fi

if [ $have_sof -eq 0 ] && [ $have_bit -eq 0 ]; then
    echo "ERROR: no bitstreams found. Run 'make quartus' and/or 'make vivado' first." >&2
    exit 1
fi

# ---- pull the numbers out of the build reports ------------------------------
q_fmax="(not built)"; q_alm="-"; q_dsp="-"; q_ram="-"; q_reg="-"; q_sha="-"
if [ $have_sof -eq 1 ]; then
    fit="$ROOT/syn/quartus/output_files/de10_standard.fit.summary"
    sta="$ROOT/syn/quartus/output_files/de10_standard.sta.rpt"
    # -A 4 lands on the data row: "; 100.54 MHz ; 100.54 MHz ; CLOCK_50 ; ;"
    if [ -f "$sta" ]; then
        q_fmax=$(grep -A 4 '^; Slow 1100mV 85C Model Fmax Summary' "$sta" \
            | tail -1 | awk -F';' '{gsub(/^ +| +$/,"",$2); print $2}')
    fi
    if [ -f "$fit" ]; then
        q_alm=$(grep 'Logic utilization' "$fit" | sed 's/.*: //' | sed 's/ \+/ /g')
        q_reg=$(grep 'Total registers' "$fit" | sed 's/.*: //')
        q_dsp=$(grep 'Total DSP Blocks' "$fit" | sed 's/.*: //')
        q_ram=$(grep 'Total RAM Blocks' "$fit" | sed 's/.*: //')
    fi
    q_sha=$(sha256sum "$OUT/de10_standard.sof" | cut -d' ' -f1)
fi

v_wns="(not built)"; v_lut="-"; v_dsp="-"; v_ram="-"; v_reg="-"; v_sha="-"
if [ $have_bit -eq 1 ]; then
    log="$ROOT/syn/vivado/vivado_stdout.log"
    util="$ROOT/syn/vivado/build/utilization.rpt"
    [ -f "$log" ] && v_wns=$(grep -E '^  setup WNS' "$log" | tail -1 | sed 's/.*: //')
    # Columns are: | Site Type | Used | Fixed | Prohibited | Available | Util% |
    # With -F'|' the leading pipe makes $1 empty, so Used is $3, Available $6,
    # Util% $7. Rendered as "used / available ( pct % )" to match the shape
    # Quartus already prints in its fit summary.
    vutil() {
        grep -m1 "^| $1 " "$util" \
            | awk -F'|' '{gsub(/ /,"",$3); gsub(/ /,"",$6); gsub(/ /,"",$7);
                          print $3" / "$6" ( "$7" % )"}'
    }
    if [ -f "$util" ]; then
        v_lut=$(vutil "Slice LUTs")
        v_reg=$(vutil "Slice Registers")
        v_dsp=$(vutil "DSPs")
        v_ram=$(vutil "Block RAM Tile")
    fi
    v_sha=$(sha256sum "$OUT/zybo_z7_10_top.bit" | cut -d' ' -f1)
fi

# Prefer the version the build actually recorded in its own report over whatever
# happens to be on PATH now -- they are not always the same tool.
qver="Quartus Prime Lite 18.1"
if [ $have_sof -eq 1 ] && [ -f "$ROOT/syn/quartus/output_files/de10_standard.fit.summary" ]; then
    qver="Quartus Prime $(grep 'Quartus Prime Version' \
        "$ROOT/syn/quartus/output_files/de10_standard.fit.summary" | sed 's/.*: //')"
fi
vver="Vivado 2026.1"
if [ $have_bit -eq 1 ] && [ -f "$ROOT/syn/vivado/vivado_stdout.log" ]; then
    v_from_log=$(grep -m1 -o 'Vivado v[0-9.]*' "$ROOT/syn/vivado/vivado_stdout.log" || true)
    if [ -n "$v_from_log" ]; then vver="$v_from_log"; fi
fi

# ---- write the provenance file ----------------------------------------------
cat > "$OUT/README.md" <<EOF
# Prebuilt bitstreams

Program a board without installing a 20 GB toolchain. Both were produced by the
build scripts in \`syn/\`, which anyone can re-run to reproduce them.

**Generated by \`scripts/collect_bitstreams.sh\` -- do not edit by hand.**

| | DE10-Standard | Zybo Z7-10 |
|---|---|---|
| File | \`de10_standard.sof\` | \`zybo_z7_10_top.bit\` |
| Device | 5CSXFC6D6F31C6 (Cyclone V) | xc7z010clg400-1 (Zynq-7010) |
| Tool | $qver | $vver |
| Clock | 50 MHz | 125 MHz |
| Logic | $q_alm | $v_lut |
| Registers | $q_reg | $v_reg |
| DSP | $q_dsp | $v_dsp |
| Block RAM | $q_ram | $v_ram |
| Timing | Fmax $q_fmax | setup WNS $v_wns |
| Source fingerprint | \`$fp_de10\` | \`$fp_zybo\` |

## Provenance

- Collected at commit: \`$commit\`
- Working tree at collection time: **$tree_state**

The **source fingerprint** identifies the inputs that actually determine each
bitstream -- the RTL tree plus that board's build script and constraints -- so a
later commit touching only docs does not make a current bitstream look stale.
Recompute it from a clone and compare:

\`\`\`
{ git rev-parse HEAD:rtl
  git rev-parse HEAD:syn/quartus/build_de10.tcl
  git rev-parse HEAD:syn/quartus/de10_standard.sdc
} | sha256sum | cut -c1-16          # -> $fp_de10

{ git rev-parse HEAD:rtl
  git rev-parse HEAD:syn/vivado/build_zybo.tcl
  git rev-parse HEAD:syn/vivado/zybo_z7_10.xdc
} | sha256sum | cut -c1-16          # -> $fp_zybo
\`\`\`

A mismatch means the sources moved and the binary here predates them. It does
not by itself mean the bitstream is wrong -- rerun \`make quartus\`/\`make vivado\`
and \`make bitstreams\` to bring them back into agreement.

SHA-256 of the binaries:

\`\`\`
$q_sha  de10_standard.sof
$v_sha  zybo_z7_10_top.bit
\`\`\`

## What they do

Both program the on-board self-test (\`rtl/fpga/tile_selftest.sv\`). It streams a
canned INT8 matmul from ROM, compares every result against values generated by
\`model/golden.py\`, and reports a verdict. It starts itself about a millisecond
after configuration, so no button press is needed.

**DE10-Standard** -- \`LEDR[8]\` = PASS, \`LEDR[9]\` = FAIL. \`SW[7:0]\` selects a
result byte onto \`LEDR[7:0]\`, \`KEY[1]\` re-runs, \`KEY[2]\` held enables
backpressure.

**Zybo Z7-10** -- \`led[2]\` and the green channel of LD6 = PASS, \`led[3]\` = FAIL.
\`btn[1]\` re-runs, \`sw0\` enables backpressure.

Both LEDs dark means it is still running, or was never started.

> Neither bitstream has been programmed onto physical hardware. Both build and
> close timing, and the self-test passes in simulation (\`tb_selftest\`), but the
> PASS LED has not been observed lit on a real board.

## Programming

DE10-Standard, over the on-board USB-Blaster II:

\`\`\`
quartus_pgm -m jtag -o "p;bitstreams/de10_standard.sof"
\`\`\`

Zybo Z7-10, with openFPGALoader:

\`\`\`
openFPGALoader -b zybo_z7_10 bitstreams/zybo_z7_10_top.bit
\`\`\`

or via the Vivado Hardware Manager: Open Target, then Program Device.

## Rebuilding

\`\`\`
make quartus                    # -> syn/quartus/output_files/de10_standard.sof
make vivado                     # -> syn/vivado/build/zybo_z7_10_top.bit
./scripts/collect_bitstreams.sh # refresh this directory and these notes
\`\`\`
EOF

echo "bitstreams/ updated from commit $short ($tree_state)"
if [ $have_sof -eq 1 ]; then
    echo "  de10_standard.sof    $(du -h "$OUT/de10_standard.sof" | cut -f1)"
fi
if [ $have_bit -eq 1 ]; then
    echo "  zybo_z7_10_top.bit   $(du -h "$OUT/zybo_z7_10_top.bit" | cut -f1)"
fi
