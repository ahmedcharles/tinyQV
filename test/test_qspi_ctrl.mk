# Makefile
# See https://docs.cocotb.org/en/stable/quickstart.html for more info

# defaults
SIM ?= icarus
TOPLEVEL_LANG ?= verilog

CPUD = $(PWD)/../cpu
VERILOG_SOURCES += $(CPUD)/qspi_ctrl.v $(PWD)/tb_qspi_ctrl.v
COMPILE_ARGS    += -DSIM

# TOPLEVEL is the name of the toplevel module in your Verilog or VHDL file
TOPLEVEL = tb_qspi_ctrl

# MODULE is the basename of the Python test file
MODULE = test_qspi_ctrl

# include cocotb's make rules to take care of the simulator setup
include $(shell cocotb-config --makefiles)/Makefile.sim