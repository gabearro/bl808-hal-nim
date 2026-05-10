# BL808 HAL Makefile
#
# Usage:
#   make m0 FILE=examples/m0_blinky.nim          # Build M0 firmware
#   make d0 FILE=examples/d0_uart_hello.nim       # Build D0 firmware
#   make lp FILE=examples/lp_minimal.nim          # Build LP firmware
#   make ipc                                       # Build IPC demo (both cores)
#   make flash-m0 FILE=examples/m0_blinky.nim     # Build + flash M0
#   make clean                                     # Remove build artifacts

NIM ?= nim
OBJCOPY_RV32 ?= riscv32-unknown-elf-objcopy
OBJCOPY_RV64 ?= riscv64-unknown-elf-objcopy
SIZE_RV32 ?= riscv32-unknown-elf-size
SIZE_RV64 ?= riscv64-unknown-elf-size

# Alternative toolchain names (if the above aren't found)
OBJCOPY_RV32_ALT ?= riscv64-unknown-elf-objcopy
SIZE_RV32_ALT ?= riscv64-unknown-elf-size

BUILD_DIR ?= build
VENV ?= .venv
PYTHON ?= $(VENV)/bin/python
UART_PORT ?= /dev/ttyUSB0
FLASH_PORT ?= $(UART_PORT)
FLASH_BAUD ?= 230400
UART_BAUD ?= 230400
HW_VALIDATE ?= $(PYTHON) tools/hw_validate.py
HW_VALIDATE_FLAGS ?=

# Detect which objcopy to use
RV32_OBJCOPY := $(shell command -v $(OBJCOPY_RV32) 2>/dev/null || command -v $(OBJCOPY_RV32_ALT) 2>/dev/null || echo "")
RV32_SIZE := $(shell command -v $(SIZE_RV32) 2>/dev/null || command -v $(SIZE_RV32_ALT) 2>/dev/null || echo "")
RV64_OBJCOPY := $(shell command -v $(OBJCOPY_RV64) 2>/dev/null || echo "")
RV64_SIZE := $(shell command -v $(SIZE_RV64) 2>/dev/null || echo "")

.PHONY: m0 d0 lp ipc examples-check flash-m0 flash-d0 flash-lp venv hw-list hw-preflight hw-smoke hw-smoke-uart hw-smoke-anchor hw-smoke-jtag hw-allcore-jtag hw-e2e-quick hw-full hw-full-uart hw-full-anchor clean help

help:
	@echo "BL808 HAL build system"
	@echo ""
	@echo "Build targets:"
	@echo "  make m0 FILE=<source.nim>   Build firmware for M0 (E907, RV32)"
	@echo "  make d0 FILE=<source.nim>   Build firmware for D0 (C906, RV64)"
	@echo "  make lp FILE=<source.nim>   Build firmware for LP (E902, RV32E)"
	@echo "  make ipc                    Build IPC demo for both cores"
	@echo "  make examples-check         Compile-check all example programs"
	@echo ""
	@echo "Flash targets:"
	@echo "  make flash-m0 FILE=<source> Build and flash M0 firmware"
	@echo "  make flash-d0 FILE=<source> Build and flash D0 firmware"
	@echo "  make venv                   Create/update the hardware harness Python venv"
	@echo "  make hw-list                List hardware validation tests and serial ports"
	@echo "  make hw-preflight           Check UART/JTAG dependencies without flashing"
	@echo "  make hw-smoke UART_PORT=<p> Build, JTAG-flash, and run smoke tests"
	@echo "  make hw-smoke-uart UART_PORT=<p> Build, UART-flash, and run smoke tests"
	@echo "  make hw-smoke-anchor UART_PORT=<p> Build, UART-anchor-flash, and run smoke tests"
	@echo "  make hw-smoke-jtag UART_PORT=<p> Build and run smoke tests from RAM over JTAG"
	@echo "  make hw-allcore-jtag UART_PORT=<p> Run the all-core RAM-load test over JTAG"
	@echo "  make hw-full UART_PORT=<p>  Build, JTAG-flash, and run full tests"
	@echo "  make hw-full-uart UART_PORT=<p> Build, UART-flash, and run full tests"
	@echo "  make hw-full-anchor UART_PORT=<p> Build, UART-anchor-flash, and run full tests"
	@echo "  make hw-e2e-quick UART_PORT=<p> WIFI_SSID=<s> WIFI_PASSWORD=<p>  WiFi blob N=3 e2e soak (Iteration 1)"
	@echo ""
	@echo "Options:"
	@echo "  UART_PORT=/dev/ttyUSB0      Runtime UART; also used for flashing by default"
	@echo "  FLASH_PORT=$(UART_PORT)     Serial port for UART bootloader flashing"
	@echo "  FLASH_BAUD=230400           Baud rate for flashing"
	@echo "  VENV=.venv                  Python venv for the hardware harness"
	@echo "  HW_VALIDATE_FLAGS=...       Extra flags, e.g. --openocd-sudo --ftdi-reset-sudo --sudo-askpass"
	@echo ""
	@echo "Examples:"
	@echo "  make m0 FILE=examples/m0_blinky.nim"
	@echo "  make flash-m0 FILE=examples/m0_uart_hello.nim FLASH_PORT=/dev/ttyACM0"

$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)

# Build for M0 (E907, RV32IMAFC)
m0: $(BUILD_DIR)
ifndef FILE
	$(error FILE is not set. Usage: make m0 FILE=examples/m0_blinky.nim)
endif
	@echo "=== Building for M0 (E907) ==="
	$(NIM) c -d:bl808m0 --nimcache:$(BUILD_DIR)/nimcache_m0 -o:$(BUILD_DIR)/m0_firmware.elf $(FILE)
	@echo "--- Converting to binary ---"
	$(if $(RV32_OBJCOPY),$(RV32_OBJCOPY),$(error riscv32-unknown-elf-objcopy not found)) \
		-O binary $(BUILD_DIR)/m0_firmware.elf $(BUILD_DIR)/m0_firmware.bin
	@echo "--- Firmware size ---"
	$(if $(RV32_SIZE),$(RV32_SIZE) $(BUILD_DIR)/m0_firmware.elf,ls -la $(BUILD_DIR)/m0_firmware.bin)
	@echo ""
	@echo "Output: $(BUILD_DIR)/m0_firmware.bin"

# Build for D0 (C906, RV64IMAFDC)
d0: $(BUILD_DIR)
ifndef FILE
	$(error FILE is not set. Usage: make d0 FILE=examples/d0_uart_hello.nim)
endif
	@echo "=== Building for D0 (C906) ==="
	$(NIM) c -d:bl808d0 --nimcache:$(BUILD_DIR)/nimcache_d0 -o:$(BUILD_DIR)/d0_firmware.elf $(FILE)
	@echo "--- Converting to binary ---"
	$(if $(RV64_OBJCOPY),$(RV64_OBJCOPY),$(error riscv64-unknown-elf-objcopy not found)) \
		-O binary $(BUILD_DIR)/d0_firmware.elf $(BUILD_DIR)/d0_firmware.bin
	@echo "--- Firmware size ---"
	$(if $(RV64_SIZE),$(RV64_SIZE) $(BUILD_DIR)/d0_firmware.elf,ls -la $(BUILD_DIR)/d0_firmware.bin)
	@echo ""
	@echo "Output: $(BUILD_DIR)/d0_firmware.bin"

# Build for LP (E902, RV32EMC)
lp: $(BUILD_DIR)
ifndef FILE
	$(error FILE is not set. Usage: make lp FILE=examples/lp_minimal.nim)
endif
	@echo "=== Building for LP (E902) ==="
	$(NIM) c -d:bl808lp --nimcache:$(BUILD_DIR)/nimcache_lp -o:$(BUILD_DIR)/lp_firmware.elf $(FILE)
	@echo "--- Converting to binary ---"
	$(if $(RV32_OBJCOPY),$(RV32_OBJCOPY),$(error riscv32-unknown-elf-objcopy not found)) \
		-O binary $(BUILD_DIR)/lp_firmware.elf $(BUILD_DIR)/lp_firmware.bin
	@echo "--- Firmware size ---"
	$(if $(RV32_SIZE),$(RV32_SIZE) $(BUILD_DIR)/lp_firmware.elf,ls -la $(BUILD_DIR)/lp_firmware.bin)
	@echo ""
	@echo "Output: $(BUILD_DIR)/lp_firmware.bin"

# Build IPC demo (both M0 and D0)
ipc: $(BUILD_DIR)
	@echo "=== Building IPC demo for M0 ==="
	$(NIM) c -d:bl808m0 --nimcache:$(BUILD_DIR)/nimcache_ipc_m0 -o:$(BUILD_DIR)/ipc_m0.elf examples/ipc_demo.nim
	$(if $(RV32_OBJCOPY),$(RV32_OBJCOPY),$(error objcopy not found)) \
		-O binary $(BUILD_DIR)/ipc_m0.elf $(BUILD_DIR)/ipc_m0.bin
	@echo "=== Building IPC demo for D0 ==="
	$(NIM) c -d:bl808d0 --nimcache:$(BUILD_DIR)/nimcache_ipc_d0 -o:$(BUILD_DIR)/ipc_d0.elf examples/ipc_demo.nim
	$(if $(RV64_OBJCOPY),$(RV64_OBJCOPY),$(error objcopy not found)) \
		-O binary $(BUILD_DIR)/ipc_d0.elf $(BUILD_DIR)/ipc_d0.bin
	@echo ""
	@echo "Output:"
	@echo "  M0: $(BUILD_DIR)/ipc_m0.bin"
	@echo "  D0: $(BUILD_DIR)/ipc_d0.bin"
	@echo ""
	@echo "Flash with:"
	@echo "  ./tools/upload.sh m0 $(BUILD_DIR)/ipc_m0.bin"
	@echo "  ./tools/upload.sh d0 $(BUILD_DIR)/ipc_d0.bin"

examples-check: $(BUILD_DIR)
	python3 tools/compile_examples.py --keep-going

# Flash targets
flash-m0: m0
	./tools/upload.sh m0 $(BUILD_DIR)/m0_firmware.bin $(FLASH_PORT) $(FLASH_BAUD)

flash-d0: d0
	./tools/upload.sh d0 $(BUILD_DIR)/d0_firmware.bin $(FLASH_PORT) $(FLASH_BAUD)

flash-lp: lp
	./tools/upload.sh lp $(BUILD_DIR)/lp_firmware.bin $(FLASH_PORT) $(FLASH_BAUD)

# Hardware validation harness: UART boot/logs plus OpenOCD JTAG reset/snapshots
venv:
	python3 -m venv $(VENV)
	$(PYTHON) -m pip install --upgrade pip
	$(PYTHON) -m pip install -r requirements-hw.txt

hw-list: venv
	$(HW_VALIDATE) --list

hw-preflight: venv
	$(HW_VALIDATE) --preflight --uart $(UART_PORT) --uart-baud $(UART_BAUD) $(HW_VALIDATE_FLAGS)

hw-smoke: venv
	$(HW_VALIDATE) --tier smoke --jtag-flash --uart $(UART_PORT) --flash-port $(FLASH_PORT) --uart-baud $(UART_BAUD) --flash-baud $(FLASH_BAUD) $(HW_VALIDATE_FLAGS)

hw-smoke-uart: venv
	$(HW_VALIDATE) --tier smoke --uart $(UART_PORT) --flash-port $(FLASH_PORT) --uart-baud $(UART_BAUD) --flash-baud $(FLASH_BAUD) $(HW_VALIDATE_FLAGS)

hw-smoke-anchor: venv
	$(HW_VALIDATE) --tier smoke --uart-anchor-flash --uart-anchor-runtime-jtag --uart $(UART_PORT) --uart-baud $(UART_BAUD) $(HW_VALIDATE_FLAGS)

hw-smoke-jtag: venv
	$(HW_VALIDATE) --tier smoke --jtag-load --uart $(UART_PORT) --flash-port $(FLASH_PORT) --uart-baud $(UART_BAUD) --flash-baud $(FLASH_BAUD) --keep-going $(HW_VALIDATE_FLAGS)

hw-allcore-jtag: venv
	$(HW_VALIDATE) --test m0_allcore_test --jtag-load --uart $(UART_PORT) --flash-port $(FLASH_PORT) --uart-baud $(UART_BAUD) --flash-baud $(FLASH_BAUD) --keep-going $(HW_VALIDATE_FLAGS)

hw-full: venv
	$(HW_VALIDATE) --tier full --jtag-flash --uart $(UART_PORT) --flash-port $(FLASH_PORT) --uart-baud $(UART_BAUD) --flash-baud $(FLASH_BAUD) --keep-going $(HW_VALIDATE_FLAGS)

hw-full-uart: venv
	$(HW_VALIDATE) --tier full --uart $(UART_PORT) --flash-port $(FLASH_PORT) --uart-baud $(UART_BAUD) --flash-baud $(FLASH_BAUD) --keep-going $(HW_VALIDATE_FLAGS)

hw-full-anchor: venv
	$(HW_VALIDATE) --tier full --uart-anchor-flash --uart-anchor-runtime-jtag --uart $(UART_PORT) --uart-baud $(UART_BAUD) --keep-going $(HW_VALIDATE_FLAGS)

hw-e2e-quick: venv
	@test -n "$(WIFI_SSID)" || (echo "Error: WIFI_SSID is required (e.g. WIFI_SSID=Frog)"; exit 1)
	@test -n "$(WIFI_PASSWORD)" || (echo "Error: WIFI_PASSWORD is required"; exit 1)
	$(PYTHON) tools/hw_e2e.py --cell wifi-blob --uart $(UART_PORT) --uart-baud $(UART_BAUD) --ssid $(WIFI_SSID) --password $(WIFI_PASSWORD) --attempts 3

# Clean build artifacts
clean:
	rm -rf $(BUILD_DIR)
	@echo "Build directory cleaned."
