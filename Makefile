# 18-447 Makefile.
#
# Authors:
#   - 2011: Joshua Wise
#   - 2013: Yoongu Kim
#   - 2016: Zhipeng Zhao
#	- 2016: Brandon Perez

################################################################################
# User Controlled Parameters
################################################################################

# The output directories for simulation and synthesis files and results
OUTPUT_BASE_DIR = output
SIM_OUTPUT = $(OUTPUT_BASE_DIR)/simulation
SYNTH_OUTPUT = $(OUTPUT_BASE_DIR)/synthesis

# Default the output directory to the synthesis for synthesis targets
SYNTH_TARGETS = synth view-timing view-power view-area synth-clean
ifneq ($(filter $(SYNTH_TARGETS),$(MAKECMDGOALS)),)
    OUTPUT = $(SYNTH_OUTPUT)
else
    OUTPUT = $(SIM_OUTPUT)
endif

# The variables that control which assembly file tests are run
DEFAULT_TEST = 447inputs/additest.S
TEST = $(DEFAULT_TEST)
TESTS = $(DEFAULT_TEST)

# The DC script used for synthesizing the processor
SYNTH_SCRIPT = dc/dc_synth.tcl

################################################################################
# General Targets and Variables
################################################################################

# Set the shell to bash for when the Makefile runs shell commands. Enable the
# pipefail option, so if any command in a pipe fails, the whole thing fails.
# This is necessary for when a failing command is piped to `tee`.
SHELL = /bin/bash -o pipefail

# Set the number of threads to use for parallel compilation (2 * cores)
CORES = $(shell getconf _NPROCESSORS_ONLN)
THREADS = $(shell echo $$((2 * $(CORES))))

# Terminal color and modifier attributes
# Return to the normal terminal colors#
n := $(shell tput sgr0)
# Red color
r := $(shell tput setaf 1)
# Green color
g := $(shell tput setaf 2)
# Bold text
b := $(shell tput bold)
# Underlined text
u := $(shell tput smul)

# These targets don't correspond to actual generated files
.PHONY: default all clean veryclean

# By default, display the help message for the Makefile
default all: help

# Clean up most of the intermediate files generated by compilation
clean: assemble-clean sim-clean synth-clean
	@rm -rf $(OUTPUT)
	@rm -rf $(OUTPUT_BASE_DIR)

# Clean up all the intermediate files generated by compilation
veryclean: clean assemble-veryclean sim-veryclean synth-veryclean

# Create the specified output directory, if it doesn't exist
$(OUTPUT):
	@mkdir -p $@

################################################################################
# Assemble Test Programs
################################################################################

# The name of the entrypoint for assembly tests, which matches the typical main
RISCV_ENTRY_POINT = main

# The addresses of the data and text sections in the program
RISCV_TEXT_START = 0x00400000
RISCV_DATA_START = 0x10000000

# The compiler for assembly files, along with its flags
RISCV_CC = riscv64-unknown-elf-gcc
RISCV_CFLAGS = -static -nostdlib -nostartfiles -m32 -Wall -Wextra -std=c99 \
			   -pedantic -g -Werror=implicit-function-declaration
RISCV_AS_LDFLAGS = -Wl,-e$(RISCV_ENTRY_POINT)
RISCV_LDFLAGS = -Wl,--section=.text=$(RISCV_TEXT_START) \
				-Wl,--section=.data=$(RISCV_DATA_START)

# The objcopy utility for ELF files, along with its flags
RISCV_OBJCOPY = riscv64-unknown-elf-objcopy
RISCV_OBJCOPY_FLAGS = -O binary

# The objdump utility for ELF files, along with its flags
RISCV_OBJDUMP = riscv64-unknown-elf-objdump
RISCV_OBJDUMP_FLAGS = -d

# The compiler for hex files, which convert copied binary to ASCII hex files,
# where there is one word per line.
HEX_CC = hexdump
HEX_CFLAGS = -v -e '1/4 "%08x" "\n"'

# The runtime environment directory, which has the startup file for C programs
447_RUNTIME_DIR = 447runtime
RISCV_STARTUP_FILE = $(447_RUNTIME_DIR)/crt0.S

# The file extensions for all files generated, including intermediate ones
ELF_EXTENSION = elf
BINARY_EXTENSION = bin
HEX_EXTENSION = hex
DISAS_EXTENSION = disassembly.s

# The hex files generated when the program is assembled. There's one for each
# assembled segment: user and kernel text and data sections.
TEST_NAME = $(basename $(TEST))
HEX_SECTIONS = $(addsuffix .$(HEX_EXTENSION),text data ktext kdata)
TEST_HEX = $(addprefix $(TEST_NAME).,$(HEX_SECTIONS))

# The name of the hex files in the output directory, used by the testbench
OUTPUT_NAME = $(OUTPUT)/mem
TEST_OUTPUT_HEX = $(addprefix $(OUTPUT_NAME).,$(HEX_SECTIONS))

# The ELF and disassembly files generated when the test is assembled
TEST_EXECUTABLE = $(addsuffix .$(ELF_EXTENSION), $(TEST_NAME))
TEST_DISASSEMBLY = $(addsuffix .$(DISAS_EXTENSION), $(TEST_NAME))

# Log file for capturing the output of assembling the test
ASSEMBLE_LOG = $(OUTPUT)/assemble.log

# Always re-run the recipe for copying hex files to the output directory,
# because the specified test can change.
.PHONY: assemble $(TEST_OUTPUT_HEX) assemble-clean assemble-veryclean \
	    assemble-check-compiler assemble-check-test

# Prevent make from automatically deleting the ELF and binary files generated.
# Instead, this is done manually, which prevents the commands from being echoed.
.SECONDARY: %.$(ELF_EXTENSION) %.$(BINARY_EXTENSION)

# User-facing target to assemble the specified test
assemble: $(TEST) $(TEST_OUTPUT_HEX) $(TEST_DISASSEMBLY)

# Copy an assembled ASCII hex file for a given section to the output directory
$(TEST_OUTPUT_HEX): $(OUTPUT_NAME).%.$(HEX_EXTENSION): \
		$(TEST_NAME).%.$(HEX_EXTENSION) | $(OUTPUT)
	@cp $^ $@

# Convert a binary file into an ASCII hex file, with one 4-byte word per line
%.$(HEX_EXTENSION): %.$(BINARY_EXTENSION) | \
		$(OUTPUT) assemble-check-hex-compiler
	@$(HEX_CC) $(HEX_CFLAGS) $^ > $@ |& tee -a $(ASSEMBLE_LOG)
	@rm -f $^

# Extract the given section from the program ELF file, generating a binary
$(TEST_NAME).%.$(BINARY_EXTENSION): $(TEST_EXECUTABLE) | $(OUTPUT) \
		assemble-check-objcopy
	@$(RISCV_OBJCOPY) $(RISCV_OBJCOPY_FLAGS) -j .$* $^ $@ |& \
			tee -a $(ASSEMBLE_LOG)

# Generate a disassembly of the compiled program for debugging proposes
%.$(DISAS_EXTENSION): %.$(ELF_EXTENSION) | $(OUTPUT) assemble-check-objdump
	@$(RISCV_OBJDUMP) $(RISCV_OBJDUMP_FLAGS) $^ > $@ |& tee -a $(ASSEMBLE_LOG)
	@rm -f $^
	@printf "Assembly of the test has completed. The assembly log can be found "
	@printf "at $u$(ASSEMBLE_LOG)$n.\n"
	@printf "A disassembly of the test can be found at "
	@printf "$u$*.$(DISAS_EXTENSION)$n.\n"

# Compile the assembly test program with a *.s extension to create an ELF file
%.$(ELF_EXTENSION): %.s | $(OUTPUT) assemble-check-compiler assemble-check-test
	@printf "Assembling test $u$<$n into hex files...\n"
	@$(RISCV_CC) $(RISCV_CFLAGS) $(RISCV_LDFLAGS) $(RISCV_AS_LDFLAGS) $^ -o $@ \
			|& tee $(ASSEMBLE_LOG)

# Compile the assembly test program with a *.S extension to create an ELF file
%.$(ELF_EXTENSION): %.S | $(OUTPUT) assemble-check-compiler assemble-check-test
	@printf "Assembling test $u$<$n into hex files...\n"
	@$(RISCV_CC) $(RISCV_CFLAGS) $(RISCV_LDFLAGS) $(RISCV_AS_LDFLAGS) $^ -o $@ \
			|& tee $(ASSEMBLE_LOG)

# Compile the C test program with the startup file to create an ELF file
%.$(ELF_EXTENSION): $(RISCV_STARTUP_FILE) %.c | $(OUTPUT) \
		assemble-check-compiler assemble-check-test
	@printf "Assembling test $u$<$n into hex files...\n"
	@$(RISCV_CC) $(RISCV_CFLAGS) $(RISCV_LDFLAGS) $^ -o $@ |& \
			tee $(ASSEMBLE_LOG)

# Checks that the given test exists. This is used when the test doesn't have
# a known extension, and suppresses the 'no rule to make...' error message
$(TEST): assemble-check-test

# Clean up the hex files in the output directory
assemble-clean:
	@printf "Cleaning up assembled hex files in $u$(OUTPUT)$n...\n"
	@rm -f $(TEST_OUTPUT_HEX) $(ASSEMBLE_LOG)

# Clean up all the hex files in the output and project directories
assemble-veryclean: assemble-clean
	@printf "Cleaning up all assembled hex files in the project directory...\n"
	@rm -f $$(find -name '*.$(HEX_EXTENSION)' -o -name '*.$(BINARY_EXTENSION)' \
			-o -name '*.$(ELF_EXTENSION)' -o -name '*.$(DISAS_EXTENSION)')

# Check that the RISC-V compiler exists
assemble-check-compiler:
ifeq ($(shell which $(RISCV_CC) 2> /dev/null),)
	@printf "$rError: $u$(RISCV_CC)$n$r: RISC-V compiler was not found in "
	@printf "your PATH.$n\n"
	@exit 1
endif

# Check that the specified test file exists
assemble-check-test:
ifeq ($(wildcard $(TEST)),)
	@printf "$rError: $u$(TEST)$n$r: RISC-V test file does not exist.$n\n"
	@exit 1
endif

# Check that the RISC-V objcopy binary utility exists
assemble-check-objcopy:
ifeq ($(shell which $(RISCV_OBJCOPY) 2> /dev/null),)
	@printf "$rError: $u$(RISCV_OBJCOPY)$n$r: RISC-V objcopy binary utility "
	@printf "was not found in your PATH.$n\n"
	@exit 1
endif

# Check that the RISC-V objdump binary utility exists
assemble-check-objdump:
ifeq ($(shell which $(RISCV_OBJDUMP) 2> /dev/null),)
	@printf "$rError: $u$(RISCV_OBJDUMP)$n$r: RISC-V objdump binary utility "
	@printf "was not found in your PATH.$n\n"
	@exit 1
endif

# Check that the hex compiler exists (converts binary to ASCII hex)
assemble-check-hex-compiler:
ifeq ($(shell which $(HEX_CC) 2> /dev/null),)
	@printf "$rError: $u$(HEX_CC)$n$r: Hex dump utility was not found in your "
	@printf "PATH.\n"
	@exit 1
endif

################################################################################
# Simulate Verilog
################################################################################

# Compiler for simulation, along with its flags
SIM_CC = vcs
SIM_CFLAGS = -sverilog -debug -q -j$(THREADS) +warn=all \
						 -xzcheck nofalseneg +define+SIMULATION_18447
SIM_INC_FLAGS = +incdir+$(SRC_DIR) +incdir+$(447_SRC_DIR)

# The starter code files provided by the 18-447 staff, all the *.v and *.sv
# files inside of 447src/ as absolute paths
447_SRC_DIR := $(shell readlink -m 447src)
447_SRC = $(shell find $(447_SRC_DIR) -type f -name '*.v' -o -name '*.sv' \
		    -o -name '*.vh')

# The code files created by the student, all the *.v and *.sv files inside of
# src/ as absolute paths. Keep it as relative when printing the help message.
help: SRC_DIR = src
SRC_DIR := $(shell readlink -m src)
SRC = $(shell find $(SRC_DIR) -type f -name '*.v' -o -name '*.sv' \
	  	-o -name '*.vh')

# The name of executable generated for simulation
SIM_EXECUTABLE = riscv_core

# The register dump file generated by running the processor simulator
SIM_REGDUMP = $(OUTPUT)/simulation.reg

# Log files for capturing the output of compilation and the simulator. These
# logs will be in the output directory.
SIM_COMPILE_LOG = sim_compilation.log
SIM_LOG = simulation.log

# The other files generated by VCS compilation and/or running the DVE gui
VCS_FILES = csrc $(SIM_EXECUTABLE).daidir DVEfiles $(SIM_EXECUTABLE).vdb \
			ucli.key inter.vpd
SIM_EXTRA_FILES = $(addprefix $(OUTPUT)/,$(VCS_FILES) $(SIM_LOG) \
				    $(SIM_COMPILE_LOG))

# Always run the simulator to generate the register dump, because the specified
# test can change.
.PHONY: sim sim-gui $(SIM_REGDUMP) sim-check-compiler

# User-facing target to run the simulator with the given test
sim: assemble $(SIM_REGDUMP)
	@printf "The simulator executable can be found at "
	@printf "$u$(OUTPUT)/$(SIM_EXECUTABLE)$n\n"
	@printf "The simulator register dump can be found at $u$(SIM_REGDUMP)$n\n"

# Open the waveform viewer for the processor simulation with the given test.
# Wait until the simulator GUI starts up before finishing.
sim-gui: $(TEST_OUTPUT_HEX) $(OUTPUT)/$(SIM_EXECUTABLE)
	@printf "Starting up the simulator gui in $u$(OUTPUT)$n...\n"
	@cd $(OUTPUT) && ./$(SIM_EXECUTABLE) -gui &
	@sleep 2

# Compile the processor into a simulator executable. This target only depends on
# the output directory existing, so don't force it to re-run because of it.
$(OUTPUT)/$(SIM_EXECUTABLE): $(447_SRC) $(SRC) | $(OUTPUT) sim-check-compiler
	@printf "Compiling design into a simulator in $u$(OUTPUT)$n...\n"
	@cd $(OUTPUT) && $(SIM_CC) $(SIM_CFLAGS) $(SIM_INC_FLAGS) \
		$(filter %.v %.sv,$^) -o $(SIM_EXECUTABLE) |& tee $(SIM_COMPILE_LOG)
	@printf "Compilation of the simulator has completed. The compilation log "
	@printf "can be found at $u$(OUTPUT)/$(SIM_COMPILE_LOG)$n\n"

# Run the processor simulation with the given test, generating a register dump
$(SIM_REGDUMP): $(TEST_OUTPUT_HEX) $(OUTPUT)/$(SIM_EXECUTABLE)
	@printf "Simulating test $u$(TEST)$n in $u$(OUTPUT)$n...\n"
	@cd $(OUTPUT) && ./$(SIM_EXECUTABLE) |& tee $(SIM_LOG)
	@printf "Simulation has completed. The simulation log can be found at "
	@printf "$u$(OUTPUT)/$(SIM_LOG)$n\n"

# Clean up all the files generated by VCS compilation and the DVE GUI
sim-clean:
	@printf "Cleaning up simulation files...\n"
	@rm -rf $(SIM_REGDUMP) $(OUTPUT)/$(SIM_EXECUTABLE) $(SIM_EXTRA_FILES)

# Very clean is the same as clean for simulation
sim-veryclean: sim-clean

# Check that the Verilog simulator compiler exists
sim-check-compiler:
ifeq ($(shell which $(SIM_CC) 2> /dev/null),)
	@printf "$rError: $u$(SIM_CC)$n$r: Verilog simulator compiler was not "
	@printf "found in your $bPATH$n$r.\n$n"
	@exit 1
endif

################################################################################
# Verify Verilog Simulation
################################################################################

# The script used to verify, and the options for it
VERIFY_SCRIPT = sdiff
VERIFY_OPTIONS = --ignore-all-space --ignore-blank-lines

# The reference register dump used to verify the simulator's
REF_REGDUMP = $(basename $(TEST)).reg

# These targets don't correspond to actual generated files
.PHONY: verify verify-single

# Verify that the processor simulator's register dump for the given test(s)
# match the reference register dump, in the corresponding *.reg file
verify:
	@for test in $(TESTS); do \
		make verify-single TEST=$${test} OUTPUT=$(OUTPUT); \
	done

# Verify that the processor simulator's register dump for the given test matches
# the reference register dump, in the correspodning *.reg file
verify-single: $(SIM_REGDUMP) $(REF_REGDUMP) | verify-check-ref-regdump
	@printf "\n"
	@grep -v "Program Counter" $(SIM_REGDUMP) | grep -v "Instruction Count" > $(OUTPUT)/simulation.reg_
	@grep -v "Program Counter" $(REF_REGDUMP) | grep -v "Instruction Count" > $(OUTPUT)/simulation.ref_
	@if $(VERIFY_SCRIPT) $(VERIFY_OPTIONS) $(OUTPUT)/simulation.reg_ $(OUTPUT)/simulation.ref_ &> /dev/null; then \
		printf "$gCorrect! The simulator register dump matches the "; \
		printf "reference.$n\n"; \
	else \
		printf "$u$(SIM_REGDUMP):$n\t\t\t\t\t$u$(REF_REGDUMP):$n\n"; \
		$(VERIFY_SCRIPT) $(VERIFY_OPTIONS) $^; \
		printf "$rIncorrect! The simulator register dump does not match the "; \
		printf "reference.$n\n"; \
	fi

# Suppresses 'no rule to make...' error when the REF_REGDUMP doesn't exist
$(REF_REGDUMP):

# Check that the reference register dump for the specified test exists
verify-check-ref-regdump:
ifeq ($(wildcard $(REF_REGDUMP)),)
	@printf "$rError: $u$(REF_REGDUMP)$n$r: Reference register dump for test "
	@printf "$u$(TEST)$n$r does not exist.\n$n"
	@exit 1
endif

################################################################################
# Synthesize Verilog
################################################################################

# Compiler for synthesis
SYNTH_CC = dc_shell-xg-t

# The DC script used for synthesis. Convert its path to an absolute one.
DC_SCRIPT := $(shell readlink -m $(SYNTH_SCRIPT))

# The files generated by running synthesis, the area, timing, and power reports,
# along with the netlist for the processor.
TIMING_REPORT = timing_riscv_core.rpt
POWER_REPORT = power_riscv_core.rpt
AREA_REPORT = area_riscv_core.rpt
REPORTS = $(TIMING_REPORT) $(POWER_REPORT) $(AREA_REPORT)
NETLIST = netlist_riscv_core.sv
SYNTH_REPORTS = $(addprefix $(OUTPUT)/,$(REPORTS) $(NETLIST))

# Log file for capturing the output of synthesis, stored in the output directory
SYNTH_LOG = synthesis.log

# The other files generated by DC synthesis
DC_FILES = work default.svf command.log
SYNTH_EXTRA_FILES = $(addprefix $(OUTPUT)/,$(DC_FILES) $(SYNTH_LOG))

# These targets don't correspond to actual generated files
.PHONY: synth view-timing view-power view-area synth-check-compiler \
	    synth-check-synth-script

# User-facing target to synthesize the processor into a physical design
synth: $(SYNTH_REPORTS)

# View the timing report from synthesis. If it doesn't exist, run synthesis.
view-timing:
	@if [ ! -e $(OUTPUT)/$(TIMING_REPORT) ]; then \
		make OUTPUT=$(OUTPUT) SYNTH_SCRIPT=$(SYNTH_SCRIPT) synth; \
	fi
	@printf "$uTiming Report: $(OUTPUT)/$(TIMING_REPORT):$n\n\n"
	@cat $(OUTPUT)/$(TIMING_REPORT)

# View the power report from synthesis. If it doesn't exist, run synthesis.
view-power:
	@if [ ! -e $(OUTPUT)/$(POWER_REPORT) ]; then \
		make OUTPUT=$(OUTPUT) SYNTH_SCRIPT=$(SYNTH_SCRIPT) synth; \
	fi
	@printf "$uPower Report: $(OUTPUT)/$(POWER_REPORT):$n\n\n"
	@cat $(OUTPUT)/$(POWER_REPORT)

# View the area report from synthesis. If it doesn't exist, run synthesis.
view-area:
	@if [ ! -e $(OUTPUT)/$(AREA_REPORT) ]; then \
		make OUTPUT=$(OUTPUT) SYNTH_SCRIPT=$(SYNTH_SCRIPT) synth; \
	fi
	@printf "$uArea Report: $(OUTPUT)/$(AREA_REPORT):$n\n\n"
	@cat $(OUTPUT)/$(AREA_REPORT)

# Synthesize the processor into a physical design, generating reports on its
# area, timing, and power
$(SYNTH_REPORTS): $(447_SRC) $(SRC) $(DC_SCRIPT) | $(OUTPUT) \
				  synth-check-compiler synth-check-script
	@printf "Synthesizing design in $u$(OUTPUT)$n..."
	@cd $(OUTPUT) && $(SYNTH_CC) -f $(DC_SCRIPT) -x "set project_dir $(PWD)" \
		|& tee $(SYNTH_LOG)
	@printf "Synthesis has completed. The synthesis log can be found at "
	@printf "$u$(OUTPUT)/$(SYNTH_LOG)$n\n"
	@printf "The timing report can be found at $u$(OUTPUT)/$(TIMING_REPORT)$n\n"
	@printf "The power report can be found at $u$(OUTPUT)/$(POWER_REPORT)$n\n"
	@printf "The area report can be found at $u$(OUTPUT)/$(AREA_REPORT)$n\n"


# Clean up all the files generated by DC synthesis
synth-clean:
	@printf "Cleaning up synthesis files...\n"
	@rm -rf $(SYNTH_REPORTS) $(SYNTH_EXTRA_FILES)

# Very clean is the same as clean for synthesis
synth-veryclean: synth-clean

# Suppresses 'no rule to make...' error when the DC_SCRIPT doesn't exist
$(DC_SCRIPT):

# Check that the Verilog synthesis compiler exists
synth-check-compiler:
ifeq ($(shell which $(SYNTH_CC) 2> /dev/null),)
	@printf "$rError: $u$(SYNTH_CC)$n$r: Verilog synthesis compiler was not "
	@printf "found in your $bPATH$n$r.\n$n"
	@exit 1
endif

# Check that script used for synthesis exists
synth-check-script:
ifeq ($(wildcard $(SYNTH_SCRIPT)),)
	@printf "$rError: $u$(SYNTH_SCRIPT)$n$r: DC synthesis script does not "
	@printf "exist.\n$n"
	@exit 1
endif

################################################################################
# Help Target
################################################################################

# These targets don't correspond to actual generated files
.PHONY: help

# Display a help message about how to use the Makefile to the user
help:
	@printf "18-447 Makefile: Help\n"
	@printf "\n"
	@printf "$bUsage:$n\n"
	@printf "\tmake [$uvariable$n ...] $utarget$n\n"
	@printf "\n"
	@printf ""
	@printf "$bTargets:$n\n"
	@printf "\t$bsim$n\n"
	@printf "\t    Compiles the Verilog files in the $u$(SRC_DIR)$n directory\n"
	@printf "\t    into a simulator, and then runs the simulator with the\n"
	@printf "\t    specified $bTEST$n program. Generates a simulation\n"
	@printf "\t    executable at $u$bOUTPUT$n$u/$(SIM_EXECUTABLE)$n.\n"
	@printf "\n"
	@printf "\t$bsim-gui$n\n"
	@printf "\t    Performs the same actions as sim, but runs the specified\n"
	@printf "\t    $bTEST$n with the waveform viewer.\n"
	@printf "\n"
	@printf "\t$bverify$n\n"
	@printf "\t    Runs and verifies all of the tests specified by $bTESTS$n.\n"
	@printf "\t    Takes the same steps as the $bsim$n target and then\n"
	@printf "\t    compares simulation's register dump against the reference.\n"
	@printf "\n"
	@printf "\t$bsynth$n\n"
	@printf "\t    Compiles the Verilog files in the $u$(SRC_DIR)$n into a\n"
	@printf "\t    physical design using the specified $bSYNTH_SCRIPT$n. All\n"
	@printf "\t    outputs are placed in in $bOUTPUT$n.\n"
	@printf "\n"
	@printf "\t$bview-timing, view-power, view-area$n\n"
	@printf "\t    Displays the timing, power, or area report from the last\n"
	@printf "\t    synthesis run. Re-runs 'synth' if the report doesn't exist.\n"
	@printf "\n"
	@printf "\t$bassemble$n\n"
	@printf "\t    Assembles the specified $bTEST$n program into hex files\n"
	@printf "\t    for each code section. The hex files are placed in the\n"
	@printf "\t    test's directory under $u<test_name>.<section>.hex$n.\n"
	@printf "\n"
	@printf "\t$bclean$n\n"
	@printf "\t    Cleans up all of the files generated by compilation in the\n"
	@printf "\t    $bOUTPUT$n directory.\n"
	@printf "\n"
	@printf "\t$bveryclean$n\n"
	@printf "\t    Takes the same steps as the $bclean$n target and also\n"
	@printf "\t    cleans up all hex files in the inputs directories\n"
	@printf "\t    generated from assembling in the tests.\n"
	@printf "\n"
	@printf "$bVariables:$n\n"
	@printf "\t$bTEST$n\n"
	@printf "\t    The program to assemble or run with processor simulation.\n"
	@printf "\t    This is a single RISC-V assembly file or C file. Defaults\n"
	@printf "\t    to $u$(DEFAULT_TEST)$n.\n"
	@printf "\n"
	@printf "\t$bTESTS$n\n"
	@printf "\t    A list of programs to verify processor simulation with.\n"
	@printf "\t    This is only used for the 'verify' target. The variable\n"
	@printf "\t    supports glob patterns, a list when quoted, or a single\n"
	@printf "\t    program. Defaults to $u$(DEFAULT_TEST)$n.\n"
	@printf "\n"
	@printf "\t$bSYNTH_SCRIPT$n\n"
	@printf "\t    The TCL script to use for synthesizing the processor into\n"
	@printf "\t    a design. This is only used for the 'synth' target.\n"
	@printf "\t    Defaults to $u$(SYNTH_SCRIPT)$n.\n"
	@printf "\n"
	@printf "\t$bOUTPUT$n\n"
	@printf "\t    Specifies the output directory where generated files are\n"
	@printf "\t    are placed. For simulation targets, defaults to\n"
	@printf "\t    $u$(SIM_OUTPUT)$n. For the synthesis target, defaults to\n"
	@printf "\t    $u$(SYNTH_OUTPUT)$n.\n"
	@printf "\n"
	@printf "$bExamples:$n\n"
	@printf "\tmake sim TEST=inputs/mytest.S\n"
	@printf "\tmake sim TEST=inputs/mytest.S OUTPUT=myoutput\n"
	@printf "\tmake sim-gui TEST=inputs/mytest.S\n"
	@printf "\tmake verify TESTS=inputs/mytest.S\n"
	@printf "\tmake verify TESTS=\"inputs/mytest1.S inputs/mytest2.S\"\n"
	@printf "\tmake verify TESTS=447inputs/*.S\n"
	@printf "\tmake synth\n"
	@printf "\tmake synth SYNTH_SCRIPT=myscript.dc OUTPUT=myoutput\n"
	@printf "\tmake view-timing\n"
