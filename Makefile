# -----------------------------------------------------------------------------
# Top-level entry points. See sim/Makefile for the simulation flow and
# syn/ for the vendor builds.
#
#   make            regenerate vectors, run every simulation, run the lint gate
#   make sim        simulations only
#   make lint       Yosys structural / latch / driver check
#   make vectors    regenerate simulation vectors and FPGA ROMs
#   make check-roms verify the committed FPGA ROMs still match the model
#   make quartus    build the DE10-Standard bitstream   (needs Quartus 18.1+)
#   make vivado     build the Zybo Z7-10 bitstream      (needs Vivado 2020.1+)
# -----------------------------------------------------------------------------

PYTHON     ?= python3
YOSYS      ?= yosys
QUARTUS_SH ?= quartus_sh
VIVADO     ?= vivado

.PHONY: all sim lint vectors check-roms quartus vivado clean

all: sim lint

sim:
	$(MAKE) -C sim all

lint:
	$(YOSYS) -q syn/yosys/synth_check.ys
	@echo "  yosys: no latches, no undriven or multiply-driven nets"

vectors:
	$(PYTHON) model/gen_vectors.py

check-roms:
	$(PYTHON) model/gen_vectors.py --check

quartus:
	cd syn/quartus && $(QUARTUS_SH) -t build_de10.tcl

vivado:
	cd syn/vivado && $(VIVADO) -mode batch -nojournal -nolog -source build_zybo.tcl

clean:
	$(MAKE) -C sim clean
	rm -f syn/yosys/stat.txt
	rm -rf syn/quartus/db syn/quartus/incremental_db syn/quartus/output_files \
	       syn/quartus/*.qpf syn/quartus/*.qsf syn/quartus/*.qws syn/quartus/*.rpt \
	       syn/quartus/*.summary syn/quartus/*.sof syn/quartus/*.pin syn/quartus/*.jdi
	rm -rf syn/vivado/build syn/vivado/.Xil
