# make test   - all cocotb benches (Verilator; SIM=icarus for Icarus)
# make lint   - Verilator lint, all warnings, every synthesizable top
# make syn    - Vivado batch synthesis + place & route + reports (Linux; on Windows run syn\build.bat)
# make clean

PY    ?= python3
TOPS  ?= axis_skid axis_fifo
RTL   := $(wildcard rtl/*.sv)

.PHONY: test lint syn clean

test:
	$(PY) tb/run.py

lint:
	@for t in $(TOPS); do \
	  echo "lint $$t"; \
	  verilator --lint-only -Wall -Wno-DECLFILENAME -Wno-MULTITOP --top-module $$t $(RTL) || exit 1; \
	done
	@echo "lint clean"

syn:
	vivado -mode batch -nojournal -nolog -source syn/build.tcl -tclargs $(firstword $(TOPS))

clean:
	rm -rf sim_build syn/out .Xil results.xml
