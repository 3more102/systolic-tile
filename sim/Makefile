# -----------------------------------------------------------------------------
# Simulation flow (Icarus Verilog).
#
#   make            build vectors and run every test
#   make tile       top-level matmul tests, all cases x all backpressure modes
#   make requant    output-stage arithmetic tests
#   make skew       skew/deskew delay tests
#   make selftest   simulate the design that goes on the FPGA
#   make waves      run one case with VCD output and open GTKWave
#   make clean
#
# Overridable: IVERILOG, VVP, PYTHON, CASE, BP
# -----------------------------------------------------------------------------

IVERILOG ?= iverilog
VVP      ?= vvp
PYTHON   ?= python3
GTKWAVE  ?= gtkwave

ROOT  := ..
RTL   := $(ROOT)/rtl
FPGA  := $(ROOT)/rtl/fpga
TB    := $(ROOT)/tb
WORK  := work
CHECK := $(abspath $(ROOT)/scripts/run_check.sh)

# Order matters: timescale.v first so the RTL inherits a timescale without
# carrying a simulation-only directive in the source.
RTL_SRCS := $(RTL)/mac_pe.sv     $(RTL)/skew_buffer.sv $(RTL)/pe_array.sv \
            $(RTL)/accum_bank.sv $(RTL)/requant.sv     $(RTL)/out_fifo.sv \
            $(RTL)/tile_ctrl.sv  $(RTL)/systolic_tile.sv

IVFLAGS := -g2012 -Wall -Wno-timescale -I$(FPGA)

CASES := basic single multi sat stress
BPS   := 0 1 2

# Defaults for the `waves` target
CASE ?= multi
BP   ?= 2

STAMP := vectors/cases.txt

.PHONY: all vectors tile requant skew selftest waves clean

all: skew requant tile selftest
	@echo ""
	@echo "  all simulations passed"

# ---------------------------------------------------------------- vectors ----
vectors: $(STAMP)

$(STAMP): $(ROOT)/model/gen_vectors.py $(ROOT)/model/golden.py
	$(PYTHON) $(ROOT)/model/gen_vectors.py

$(WORK):
	@mkdir -p $(WORK)

# The FPGA self-test reads its ROMs by bare filename, so they have to sit in the
# simulation working directory.
$(WORK)/.roms: $(wildcard $(FPGA)/*.hex) | $(WORK)
	@cp $(FPGA)/*.hex $(WORK)/
	@touch $@

# ------------------------------------------------------------------- skew ----
skew: $(WORK)/skew.vvp
	@cd $(WORK) && $(CHECK) $(VVP) skew.vvp

$(WORK)/skew.vvp: $(RTL)/skew_buffer.sv $(TB)/tb_skew_buffer.sv timescale.v | $(WORK)
	$(IVERILOG) $(IVFLAGS) -o $@ -s tb_skew_buffer timescale.v \
	    $(RTL)/skew_buffer.sv $(TB)/tb_skew_buffer.sv

# ---------------------------------------------------------------- requant ----
requant: $(WORK)/requant.vvp $(STAMP)
	@cd $(WORK) && $(CHECK) $(VVP) requant.vvp +vecdir=../vectors/requant

$(WORK)/requant.vvp: $(RTL)/requant.sv $(TB)/tb_requant.sv timescale.v | $(WORK)
	$(IVERILOG) $(IVFLAGS) -o $@ -s tb_requant timescale.v \
	    $(RTL)/requant.sv $(TB)/tb_requant.sv

# ------------------------------------------------------------------- tile ----
tile: $(WORK)/tile.vvp $(STAMP)
	@for c in $(CASES); do \
	    for b in $(BPS); do \
	        (cd $(WORK) && $(CHECK) $(VVP) tile.vvp +case=../vectors/$$c +bp=$$b) \
	            || exit 1; \
	    done; \
	done

$(WORK)/tile.vvp: $(RTL_SRCS) $(TB)/tb_systolic_tile.sv timescale.v | $(WORK)
	$(IVERILOG) $(IVFLAGS) -o $@ -s tb_systolic_tile timescale.v \
	    $(RTL_SRCS) $(TB)/tb_systolic_tile.sv

# --------------------------------------------------------------- selftest ----
selftest: $(WORK)/selftest.vvp $(WORK)/.roms
	@cd $(WORK) && $(CHECK) $(VVP) selftest.vvp

$(WORK)/selftest.vvp: $(RTL_SRCS) $(FPGA)/tile_selftest.sv $(FPGA)/selftest_params.svh \
                      $(TB)/tb_selftest.sv timescale.v | $(WORK)
	$(IVERILOG) $(IVFLAGS) -o $@ -s tb_selftest timescale.v \
	    $(RTL_SRCS) $(FPGA)/tile_selftest.sv $(TB)/tb_selftest.sv

# ------------------------------------------------------------------ waves ----
waves: $(WORK)/tile.vvp $(STAMP)
	cd $(WORK) && $(VVP) tile.vvp +case=../vectors/$(CASE) +bp=$(BP) +vcd
	$(GTKWAVE) $(WORK)/waves.vcd $(ROOT)/docs/waves.gtkw 2>/dev/null || \
	    $(GTKWAVE) $(WORK)/waves.vcd

clean:
	rm -rf $(WORK) vectors
