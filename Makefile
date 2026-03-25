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
FLASH_PORT ?= /dev/ttyUSB0
FLASH_BAUD ?= 2000000

# Detect which objcopy to use
RV32_OBJCOPY := $(shell command -v $(OBJCOPY_RV32) 2>/dev/null || command -v $(OBJCOPY_RV32_ALT) 2>/dev/null || echo "")
RV32_SIZE := $(shell command -v $(SIZE_RV32) 2>/dev/null || command -v $(SIZE_RV32_ALT) 2>/dev/null || echo "")
RV64_OBJCOPY := $(shell command -v $(OBJCOPY_RV64) 2>/dev/null || echo "")
RV64_SIZE := $(shell command -v $(SIZE_RV64) 2>/dev/null || echo "")

.PHONY: m0 d0 lp ipc flash-m0 flash-d0 flash-lp clean help

help:
	@echo "BL808 HAL build system"
	@echo ""
	@echo "Build targets:"
	@echo "  make m0 FILE=<source.nim>   Build firmware for M0 (E907, RV32)"
	@echo "  make d0 FILE=<source.nim>   Build firmware for D0 (C906, RV64)"
	@echo "  make lp FILE=<source.nim>   Build firmware for LP (E902, RV32E)"
	@echo "  make ipc                    Build IPC demo for both cores"
	@echo ""
	@echo "Flash targets:"
	@echo "  make flash-m0 FILE=<source> Build and flash M0 firmware"
	@echo "  make flash-d0 FILE=<source> Build and flash D0 firmware"
	@echo ""
	@echo "Options:"
	@echo "  FLASH_PORT=/dev/ttyUSB0     Serial port for flashing"
	@echo "  FLASH_BAUD=2000000          Baud rate for flashing"
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

# Flash targets
flash-m0: m0
	./tools/upload.sh m0 $(BUILD_DIR)/m0_firmware.bin $(FLASH_PORT) $(FLASH_BAUD)

flash-d0: d0
	./tools/upload.sh d0 $(BUILD_DIR)/d0_firmware.bin $(FLASH_PORT) $(FLASH_BAUD)

flash-lp: lp
	./tools/upload.sh lp $(BUILD_DIR)/lp_firmware.bin $(FLASH_PORT) $(FLASH_BAUD)

# Clean build artifacts
clean:
	rm -rf $(BUILD_DIR)
	@echo "Build directory cleaned."
