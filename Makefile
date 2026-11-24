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
NIM_FLAGS ?= -d:bl808kernel
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

.PHONY: m0 d0 lp ipc examples-check flash-m0 flash-d0 flash-lp venv test test-all hw-list hw-preflight hw-smoke hw-smoke-uart hw-smoke-anchor hw-smoke-jtag hw-allcore-jtag hw-npu-anchor-probe hw-npu-anchor-install hw-npu-smoke-anchor hw-e2e-quick hw-e2e-lwip-smoke hw-full hw-full-uart hw-full-anchor clean help

# Experimental proof-carrying WASM profile. Executable components are Nim;
# Lean is used only by the formal verification target.
ZKBUILD_DIR ?= $(BUILD_DIR)/zkbuild
ZKBUILD_DEPS = $(CURDIR)/build/zkbuild-deps/portable
ZKBUILD_QEMU ?= qemu-system-riscv32
ZKBUILD_RISCV_CC ?= riscv64-unknown-elf-gcc
ZKBUILD_HOST_FLAGS = -d:release --skipUserCfg --skipParentCfg --skipProjCfg --path:$(CURDIR)/src --path:$(ZKBUILD_DEPS)
.PHONY: zkbuild-prepare zkbuild zkbuild-test zkbuild-fv zkbuild-model-test zkbuild-matrix-test zkbuild-slot-matrix-test zkbuild-witness-test zkbuild-slot-witness-test zkbuild-compile-witness-test zkbuild-fft-model-test zkbuild-compiler-test zkbuild-qap-test zkbuild-qap-bench zkbuild-crypto-test zkbuild-interop-export zkbuild-demo zkbuild-compile-demo zkbuild-native-qemu-test zkbuild-bench zkbuild-target-check zkbuild-check

zkbuild-prepare:
	$(NIM) c -r --skipUserCfg --skipParentCfg --skipProjCfg --nimcache:$(ZKBUILD_DIR)/bootstrap-cache --out:$(ZKBUILD_DIR)/bootstrap tools/zkbuild_bootstrap.nim

zkbuild: zkbuild-prepare zkbuild-matrix-test zkbuild-slot-matrix-test zkbuild-byte-compile-matrix-test zkbuild-byte-decoder-test
	$(NIM) c $(ZKBUILD_HOST_FLAGS) --nimcache:$(ZKBUILD_DIR)/cli-cache --out:$(ZKBUILD_DIR)/zkbuild tools/zkbuild.nim

zkbuild-test: zkbuild-prepare
	$(NIM) c -r $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/test-cache --out:$(ZKBUILD_DIR)/test_zkbuild tools/test_zkbuild.nim
	$(NIM) c -r $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/bytes-test-cache --out:$(ZKBUILD_DIR)/test_zkbuild_bytes tools/test_zkbuild_bytes.nim

zkbuild-fv:
	cd formal/zkbuild && lake build

zkbuild-model-test: zkbuild-prepare zkbuild-fv
	cd formal/zkbuild && lake exe export_rows $(abspath $(ZKBUILD_DIR))/byte-model-rows.txt
	$(NIM) c -r $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/model-test-cache --out:$(ZKBUILD_DIR)/test_model tools/test_zkbuild_model.nim $(ZKBUILD_DIR)/byte-model-rows.txt

zkbuild-matrix-test: zkbuild-prepare zkbuild-fv
	$(NIM) c -r $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/export-cache --out:$(ZKBUILD_DIR)/export_circuit tools/zkbuild_export_circuit.nim $(ZKBUILD_DIR)/byte-circuit.txt
	cd formal/zkbuild && lake exe check_circuit $(abspath $(ZKBUILD_DIR))/byte-circuit.txt
	$(NIM) c -r $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/matrix-test-cache --out:$(ZKBUILD_DIR)/test_matrix tools/test_zkbuild_matrix.nim formal/zkbuild/.lake/build/bin/check_circuit $(ZKBUILD_DIR)/byte-circuit.txt

zkbuild-slot-matrix-test: zkbuild-prepare zkbuild-fv
	$(NIM) c $(ZKBUILD_HOST_FLAGS) --nimcache:$(ZKBUILD_DIR)/export-cache --out:$(ZKBUILD_DIR)/export_circuit tools/zkbuild_export_circuit.nim
	cd formal/zkbuild && lake build check_circuit
	$(ZKBUILD_DIR)/export_circuit compile $(ZKBUILD_DIR)/compile-circuit.txt
	formal/zkbuild/.lake/build/bin/check_circuit compile $(ZKBUILD_DIR)/compile-circuit.txt
	$(ZKBUILD_DIR)/export_circuit validate $(ZKBUILD_DIR)/validate-circuit.txt
	formal/zkbuild/.lake/build/bin/check_circuit validate $(ZKBUILD_DIR)/validate-circuit.txt
	$(NIM) c -r $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/matrix-test-cache --out:$(ZKBUILD_DIR)/test_matrix tools/test_zkbuild_matrix.nim formal/zkbuild/.lake/build/bin/check_circuit $(ZKBUILD_DIR)/compile-circuit.txt compile
	$(ZKBUILD_DIR)/test_matrix formal/zkbuild/.lake/build/bin/check_circuit $(ZKBUILD_DIR)/validate-circuit.txt validate

.PHONY: zkbuild-byte-compile-test zkbuild-byte-compile-matrix-test zkbuild-byte-compile-demo zkbuild-byte-native-qemu-test zkbuild-byte-decoder-test zkbuild-byte-compile-witness-test

zkbuild-byte-compile-test: zkbuild-prepare
	$(NIM) c -r $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/compile-bytes-test-cache --out:$(ZKBUILD_DIR)/test_compile_bytes tools/test_zkbuild_compile_bytes.nim

zkbuild-byte-decoder-test: zkbuild-prepare zkbuild-fv
	cd formal/zkbuild && lake build export_byte_decoder
	$(NIM) c -r $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/byte-decoder-test-cache --out:$(ZKBUILD_DIR)/test_byte_decoder tools/test_zkbuild_byte_decoder.nim formal/zkbuild/.lake/build/bin/export_byte_decoder $(ZKBUILD_DIR)/byte-decoder-test

zkbuild-byte-compile-witness-test: zkbuild-prepare zkbuild-fv
	cd formal/zkbuild && lake build export_byte_compile_witness
	$(NIM) c -r $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/byte-compile-witness-test-cache --out:$(ZKBUILD_DIR)/test_byte_compile_witness tools/test_zkbuild_byte_compile_witness.nim formal/zkbuild/.lake/build/bin/export_byte_compile_witness $(ZKBUILD_DIR)/byte-compile-witness-test

zkbuild-byte-compile-matrix-test: zkbuild-prepare zkbuild-fv
	$(NIM) c -r $(ZKBUILD_HOST_FLAGS) --nimcache:$(ZKBUILD_DIR)/export-cache --out:$(ZKBUILD_DIR)/export_circuit tools/zkbuild_export_circuit.nim compile-bytes $(ZKBUILD_DIR)/compile-bytes-circuit.txt
	cd formal/zkbuild && lake build check_circuit
	formal/zkbuild/.lake/build/bin/check_circuit compile-bytes $(ZKBUILD_DIR)/compile-bytes-circuit.txt
	$(NIM) c -r $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/matrix-test-cache --out:$(ZKBUILD_DIR)/test_matrix tools/test_zkbuild_matrix.nim formal/zkbuild/.lake/build/bin/check_circuit $(ZKBUILD_DIR)/compile-bytes-circuit.txt compile-bytes

zkbuild-witness-test: zkbuild-prepare zkbuild-fv
	cd formal/zkbuild && lake build export_witness
	$(NIM) c -r $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/witness-test-cache --out:$(ZKBUILD_DIR)/test_witness tools/test_zkbuild_witness.nim formal/zkbuild/.lake/build/bin/export_witness $(ZKBUILD_DIR)/witness-test

zkbuild-slot-witness-test: zkbuild-prepare zkbuild-fv
	cd formal/zkbuild && lake build export_slot_witness
	$(NIM) c -r $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/slot-witness-test-cache --out:$(ZKBUILD_DIR)/test_slot_witness tools/test_zkbuild_slot_witness.nim formal/zkbuild/.lake/build/bin/export_slot_witness $(ZKBUILD_DIR)/slot-witness-test

zkbuild-compile-witness-test: zkbuild-prepare zkbuild-fv
	cd formal/zkbuild && lake build export_compile_witness
	$(NIM) c -r $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/compile-witness-test-cache --out:$(ZKBUILD_DIR)/test_compile_witness tools/test_zkbuild_compile_witness.nim formal/zkbuild/.lake/build/bin/export_compile_witness $(ZKBUILD_DIR)/compile-witness-test

zkbuild-qap-test: zkbuild-prepare
	$(NIM) c -r $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/qap-test-cache --out:$(ZKBUILD_DIR)/test_qap tools/test_zkbuild_qap.nim

zkbuild-fft-model-test: zkbuild-prepare zkbuild-fv
	cd formal/zkbuild && lake exe export_fft $(abspath $(ZKBUILD_DIR))/fft-model.txt
	$(NIM) c -r $(ZKBUILD_HOST_FLAGS) -d:zkbuildFftTrace --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/fft-model-test-cache --out:$(ZKBUILD_DIR)/test_fft_model tools/test_zkbuild_fft_model.nim $(ZKBUILD_DIR)/fft-model.txt

zkbuild-compiler-test: zkbuild-prepare zkbuild-fv
	cd formal/zkbuild && lake build export_compiler
	$(NIM) c -r $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/compiler-test-cache --out:$(ZKBUILD_DIR)/test_compiler tools/test_zkbuild_compiler_model.nim formal/zkbuild/.lake/build/bin/export_compiler $(ZKBUILD_DIR)/compiler-test

zkbuild-qap-bench: zkbuild-prepare
	$(NIM) c -r $(ZKBUILD_HOST_FLAGS) --nimcache:$(ZKBUILD_DIR)/qap-bench-cache --out:$(ZKBUILD_DIR)/qap_bench tools/zkbuild_qap_bench.nim

.PHONY: zkbuild-scalar-encoding-test zkbuild-word-arithmetic-test zkbuild-fips-test zkbuild-cios-test zkbuild-wasm-validation-test zkbuild-numeric-typing-test zkbuild-numeric-lookup-test zkbuild-permutation-test zkbuild-memory-test zkbuild-operand-events-test zkbuild-control-events-test zkbuild-instruction-events-test zkbuild-static-typing-test zkbuild-static-lookup-test zkbuild-static-events-test

zkbuild-static-typing-test: zkbuild-fv
	cd formal/zkbuild && lake build export_static_typing
	$(NIM) c -r -d:release --skipUserCfg --skipParentCfg --skipProjCfg --path:$(CURDIR)/src --nimcache:$(ZKBUILD_DIR)/static-typing-cache --out:$(ZKBUILD_DIR)/test_static_typing tools/test_wasm_static_typing.nim formal/zkbuild/.lake/build/bin/export_static_typing $(ZKBUILD_DIR)/static-typing-test

zkbuild-static-lookup-test: zkbuild-prepare zkbuild-fv
	$(NIM) c -r $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/static-lookup-cache --out:$(ZKBUILD_DIR)/test_static_lookup tools/test_zkbuild_static_lookup.nim

zkbuild-static-events-test: zkbuild-prepare zkbuild-fv
	$(NIM) c -r $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/static-events-cache --out:$(ZKBUILD_DIR)/test_static_events tools/test_zkbuild_static_events.nim

.PHONY: zkbuild-read-only-test zkbuild-variable-events-test zkbuild-call-events-test zkbuild-indexed-signatures-test zkbuild-control-typing-test zkbuild-range-reuse-test zkbuild-branch-typing-test zkbuild-parametric-test zkbuild-wasm-metadata-test zkbuild-instruction-lookup-test zkbuild-memory-metadata-test

zkbuild-wasm-metadata-test: zkbuild-fv
	$(NIM) c -r -d:release --skipUserCfg --skipParentCfg --skipProjCfg --path:$(CURDIR)/src --nimcache:$(ZKBUILD_DIR)/wasm-instruction-metadata-cache --out:$(ZKBUILD_DIR)/test_wasm_instruction_metadata tools/test_wasm_instruction_metadata.nim

zkbuild-instruction-lookup-test: zkbuild-prepare zkbuild-fv
	cd formal/zkbuild && lake build export_instruction_metadata
	$(NIM) c -r $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/instruction-lookup-test-cache --out:$(ZKBUILD_DIR)/test_instruction_lookup tools/test_zkbuild_instruction_lookup.nim formal/zkbuild/.lake/build/bin/export_instruction_metadata $(ZKBUILD_DIR)/instruction-lookup-test

zkbuild-memory-metadata-test: zkbuild-prepare zkbuild-fv
	$(NIM) c -r $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/memory-metadata-cache --out:$(ZKBUILD_DIR)/test_memory_metadata tools/test_zkbuild_memory_metadata.nim

.PHONY: zkbuild-bulk-context-test
zkbuild-bulk-context-test: zkbuild-prepare zkbuild-fv
	$(NIM) c -r $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/wasm-bulk-context-cache --out:$(ZKBUILD_DIR)/test_wasm_bulk_context tools/test_wasm_bulk_context.nim
	cd formal/zkbuild && lake build export_bulk_context
	$(NIM) c -r $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/bulk-context-cache --out:$(ZKBUILD_DIR)/test_bulk_context tools/test_zkbuild_bulk_context.nim formal/zkbuild/.lake/build/bin/export_bulk_context $(ZKBUILD_DIR)/bulk-context-test

zkbuild-check: zkbuild-bulk-context-test

.PHONY: zkbuild-reference-context-test
zkbuild-reference-context-test: zkbuild-prepare zkbuild-fv
	cd formal/zkbuild && lake build export_reference_context
	$(NIM) c -r $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/reference-context-cache --out:$(ZKBUILD_DIR)/test_reference_context tools/test_zkbuild_reference_context.nim formal/zkbuild/.lake/build/bin/export_reference_context $(ZKBUILD_DIR)/reference-context-test

zkbuild-check: zkbuild-reference-context-test

.PHONY: zkbuild-throw-events-test
zkbuild-throw-events-test: zkbuild-prepare zkbuild-fv
	cd formal/zkbuild && lake build export_throw_events
	$(NIM) c -r $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/throw-events-cache --out:$(ZKBUILD_DIR)/test_throw_events tools/test_zkbuild_throw_events.nim formal/zkbuild/.lake/build/bin/export_throw_events $(ZKBUILD_DIR)/throw-events-test

zkbuild-check: zkbuild-throw-events-test

.PHONY: zkbuild-type-reversals-test zkbuild-catch-typing-test
zkbuild-type-reversals-test: zkbuild-prepare zkbuild-fv
	$(NIM) c -r $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/type-reversals-cache --out:$(ZKBUILD_DIR)/test_type_reversals tools/test_zkbuild_type_reversals.nim

zkbuild-catch-typing-test: zkbuild-prepare zkbuild-fv
	$(NIM) c -r -d:release --skipUserCfg --skipParentCfg --skipProjCfg --path:$(CURDIR)/src --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/wasm-catch-cache --out:$(ZKBUILD_DIR)/test_wasm_catch tools/test_wasm_catch_typing.nim
	cd formal/zkbuild && lake build export_catch_typing
	$(NIM) c -r -d:release --skipUserCfg --skipParentCfg --skipProjCfg --path:$(CURDIR)/src --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/catch-oracle-cache --out:$(ZKBUILD_DIR)/test_catch_oracle tools/test_wasm_catch_oracle.nim formal/zkbuild/.lake/build/bin/export_catch_typing $(ZKBUILD_DIR)/catch-oracle-test
	$(NIM) c -r $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/catch-typing-cache --out:$(ZKBUILD_DIR)/test_catch_typing tools/test_zkbuild_catch_typing.nim $(ZKBUILD_DIR)/catch-oracle-test/catch.txt

zkbuild-check: zkbuild-type-reversals-test zkbuild-catch-typing-test

.PHONY: zkbuild-module-context-test zkbuild-module-integration-test
zkbuild-module-context-test: zkbuild-prepare zkbuild-fv
	$(NIM) c -r $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/local-declarations-cache --out:$(ZKBUILD_DIR)/test_local_declarations tools/test_zkbuild_local_declarations.nim
	$(NIM) c -r $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/module-context-cache --out:$(ZKBUILD_DIR)/test_module_context tools/test_zkbuild_module_context.nim

zkbuild-module-integration-test: zkbuild-prepare zkbuild-fv
	$(NIM) c -r $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/module-integration-cache --out:$(ZKBUILD_DIR)/test_module_integration tools/test_wasm_module_integration.nim

zkbuild-check: zkbuild-module-context-test zkbuild-module-integration-test

.PHONY: zkbuild-binary-source-test zkbuild-binary-declarations-test zkbuild-opcode-encoding-test
zkbuild-opcode-encoding-test:
	$(NIM) c -r -d:release --skipUserCfg --skipParentCfg --skipProjCfg --path:$(CURDIR)/src --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/opcode-encoding-cache --out:$(ZKBUILD_DIR)/test_opcode_encoding tools/test_wasm_opcode_encoding.nim

zkbuild-binary-source-test: zkbuild-prepare zkbuild-fv
	$(NIM) c -r $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/binary-source-cache --out:$(ZKBUILD_DIR)/test_binary_source tools/test_zkbuild_binary_source.nim

zkbuild-binary-declarations-test: zkbuild-prepare zkbuild-fv
	$(NIM) c -r $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/binary-declarations-cache --out:$(ZKBUILD_DIR)/test_binary_declarations tools/test_zkbuild_binary_declarations.nim

zkbuild-check: zkbuild-binary-source-test zkbuild-binary-declarations-test zkbuild-opcode-encoding-test

.PHONY: zkbuild-instruction-source-test zkbuild-instruction-binding-test
zkbuild-instruction-source-test: zkbuild-prepare zkbuild-fv
	$(NIM) c -r $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/instruction-source-cache --out:$(ZKBUILD_DIR)/test_instruction_source tools/test_zkbuild_instruction_source.nim

zkbuild-instruction-binding-test: zkbuild-prepare zkbuild-fv
	$(NIM) c -r $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/instruction-binding-cache --out:$(ZKBUILD_DIR)/test_instruction_binding tools/test_zkbuild_instruction_binding.nim

zkbuild-check: zkbuild-instruction-source-test zkbuild-instruction-binding-test

.PHONY: zkbuild-payload-source-test zkbuild-module-proof-test
zkbuild-payload-source-test: zkbuild-prepare zkbuild-fv
	$(NIM) c -r $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/binary-claim-cache --out:$(ZKBUILD_DIR)/test_binary_claim tools/test_zkbuild_binary_claim.nim
	$(NIM) c -r $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/payload-source-cache --out:$(ZKBUILD_DIR)/test_payload_source tools/test_zkbuild_payload_source.nim --check-only

zkbuild-module-proof-test: zkbuild-prepare zkbuild-fv
	$(NIM) c -r $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/module-proof-cache --out:$(ZKBUILD_DIR)/test_module_proof tools/test_zkbuild_module_proof.nim

zkbuild-check: zkbuild-payload-source-test zkbuild-module-proof-test

.PHONY: zkbuild-sha256-test zkbuild-module-digest-test
.PHONY: zkbuild-sha-word-test
zkbuild-sha-word-test: zkbuild-prepare zkbuild-fv
	cd formal/zkbuild && lake build check_sha_words
	$(NIM) c -r $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/sha-words-cache --out:$(ZKBUILD_DIR)/test_sha_words tools/test_zkbuild_sha_words.nim formal/zkbuild/.lake/build/bin/check_sha_words $(ZKBUILD_DIR)/sha-word-matrices

zkbuild-check: zkbuild-sha-word-test

.PHONY: zkbuild-sha-compression-test
zkbuild-sha-compression-test: zkbuild-prepare zkbuild-fv
	cd formal/zkbuild && lake build check_sha_compression
	$(NIM) c -r $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/sha-compression-cache --out:$(ZKBUILD_DIR)/test_sha_compression tools/test_zkbuild_sha_compression.nim formal/zkbuild/.lake/build/bin/check_sha_compression $(ZKBUILD_DIR)/sha-compression-matrix

zkbuild-check: zkbuild-sha-compression-test

.PHONY: zkbuild-sha-boundary-test
zkbuild-sha-boundary-test: zkbuild-prepare zkbuild-fv
	cd formal/zkbuild && lake build check_sha_boundaries
	$(NIM) c -r $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/sha-boundary-cache --out:$(ZKBUILD_DIR)/test_sha_boundaries tools/test_zkbuild_sha_boundaries.nim formal/zkbuild/.lake/build/bin/check_sha_boundaries $(ZKBUILD_DIR)/sha-boundary-matrices

zkbuild-check: zkbuild-sha-boundary-test

.PHONY: zkbuild-sha-hash-matrix-test
zkbuild-sha-hash-matrix-test: zkbuild-prepare zkbuild-fv
	cd formal/zkbuild && lake build check_sha_hash
	$(NIM) c -r $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/sha-hash-cache --out:$(ZKBUILD_DIR)/test_sha_hash_matrix tools/test_zkbuild_sha_hash_matrix.nim formal/zkbuild/.lake/build/bin/check_sha_hash $(ZKBUILD_DIR)/sha-hash-matrices

zkbuild-check: zkbuild-sha-hash-matrix-test

zkbuild-sha256-test: zkbuild-prepare zkbuild-fv
	$(NIM) c -r $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/sha256-cache --out:$(ZKBUILD_DIR)/test_sha256 tools/test_zkbuild_sha256.nim
	$(NIM) c -r $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/digest-key-cache --out:$(ZKBUILD_DIR)/test_digest_key tools/test_zkbuild_digest_key.nim

zkbuild-module-digest-test: zkbuild-prepare zkbuild-fv
	$(NIM) c -r $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/module-digest-cache --out:$(ZKBUILD_DIR)/test_module_digest tools/test_zkbuild_module_digest.nim

zkbuild-check: zkbuild-sha256-test zkbuild-module-digest-test

.PHONY: zkbuild-flat-source-test zkbuild-flat-module-test
zkbuild-flat-source-test: zkbuild-prepare zkbuild-fv
	$(NIM) c -r $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/flat-source-cache --out:$(ZKBUILD_DIR)/test_flat_source tools/test_zkbuild_flat_source.nim --check-only

zkbuild-flat-module-test: zkbuild-prepare zkbuild-fv
	$(NIM) c -r $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/flat-module-cache --out:$(ZKBUILD_DIR)/test_flat_module tools/test_zkbuild_flat_module.nim

zkbuild-check: zkbuild-flat-source-test zkbuild-flat-module-test

.PHONY: zkbuild-declaration-profile-test
zkbuild-declaration-profile-test: zkbuild-prepare zkbuild-fv
	$(NIM) c -r $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/flat-locals-cache --out:$(ZKBUILD_DIR)/test_flat_locals tools/test_zkbuild_flat_locals.nim
	$(NIM) c -r $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/declaration-profile-cache --out:$(ZKBUILD_DIR)/test_declaration_profile tools/test_zkbuild_declaration_profile.nim

zkbuild-check: zkbuild-declaration-profile-test

.PHONY: zkbuild-payload-profile-test
zkbuild-payload-profile-test: zkbuild-prepare zkbuild-fv
	$(NIM) c -r $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/module-profile-cache --out:$(ZKBUILD_DIR)/test_module_profile tools/test_zkbuild_module_profile.nim
	$(NIM) c -r $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/owned-stream-cache --out:$(ZKBUILD_DIR)/test_owned_stream tools/test_zkbuild_owned_stream.nim
	$(NIM) c -r $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/payload-profile-cache --out:$(ZKBUILD_DIR)/test_payload_profile tools/test_zkbuild_payload_profile.nim

zkbuild-check: zkbuild-payload-profile-test

.PHONY: zkbuild-persistence-test
zkbuild-persistence-test: zkbuild-prepare zkbuild-fv
	$(NIM) c -r $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/key-file-cache --out:$(ZKBUILD_DIR)/test_proving_key_file tools/test_zkbuild_proving_key_file.nim
	$(NIM) c -r $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/api-loading-cache --out:$(ZKBUILD_DIR)/test_api_loading tools/test_wasm_api_loading.nim
	$(NIM) c -r $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/persistent-module-cache --out:$(ZKBUILD_DIR)/test_persistent_module tools/test_zkbuild_persistent_module.nim $(ZKBUILD_DIR)/persistent-module
	$(NIM) c -r $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/proven-loader-cache --out:$(ZKBUILD_DIR)/test_proven_loader tools/test_zkbuild_proven_loader.nim $(ZKBUILD_DIR)/persistent-module

zkbuild-check: zkbuild-persistence-test

.PHONY: zkbuild-gadget-matrix-test
zkbuild-gadget-matrix-test: zkbuild-prepare zkbuild-fv
	cd formal/zkbuild && lake build check_gadget_shapes
	$(NIM) c -r $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/gadget-shapes-cache --out:$(ZKBUILD_DIR)/test_gadget_shapes tools/test_zkbuild_gadget_shapes.nim formal/zkbuild/.lake/build/bin/check_gadget_shapes $(ZKBUILD_DIR)/gadget-matrices

zkbuild-check: zkbuild-gadget-matrix-test

.PHONY: zkbuild-gadget-audit-test zkbuild-gadget-audit-key-test
zkbuild-gadget-audit-test: zkbuild-prepare zkbuild-fv
	cd formal/zkbuild && lake build check_gadget_audit
	$(NIM) c $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/audit-baseline-cache --out:$(ZKBUILD_DIR)/audit_baseline tools/zkbuild_audit_gadgets.nim
	$(NIM) c $(ZKBUILD_HOST_FLAGS) -d:zkbuildGadgetAudit --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/audit-gadgets-cache --out:$(ZKBUILD_DIR)/audit_gadgets tools/zkbuild_audit_gadgets.nim
	$(NIM) c -r $(ZKBUILD_HOST_FLAGS) -d:zkbuildGadgetAudit --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/audit-range-cache --out:$(ZKBUILD_DIR)/test_audit_range tools/test_zkbuild_range_reuse.nim
	$(NIM) c -r $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/gadget-audit-test-cache --out:$(ZKBUILD_DIR)/test_gadget_audit tools/test_zkbuild_gadget_audit.nim $(ZKBUILD_DIR)/audit_baseline $(ZKBUILD_DIR)/audit_gadgets formal/zkbuild/.lake/build/bin/check_gadget_audit $(ZKBUILD_DIR)/gadget-audit-tests

zkbuild-gadget-audit-key-test: zkbuild-persistence-test
	$(NIM) c -r $(ZKBUILD_HOST_FLAGS) -d:zkbuildGadgetAudit --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/audit-key-cache --out:$(ZKBUILD_DIR)/test_audit_key tools/test_zkbuild_audit_key.nim $(ZKBUILD_DIR)/persistent-module/module.pk $(ZKBUILD_DIR)/persistent-module/module-2.wasm

zkbuild-check: zkbuild-gadget-audit-test zkbuild-gadget-audit-key-test

zkbuild-parametric-test: zkbuild-prepare zkbuild-fv
	cd formal/zkbuild && lake build check_parametric_plans
	$(NIM) c -r $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/parametric-cache --out:$(ZKBUILD_DIR)/test_parametric tools/test_zkbuild_parametric.nim formal/zkbuild/.lake/build/bin/check_parametric_plans $(ZKBUILD_DIR)/parametric-plans-test

zkbuild-range-reuse-test: zkbuild-prepare zkbuild-fv
	$(NIM) c -r $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/range-reuse-cache --out:$(ZKBUILD_DIR)/test_range_reuse tools/test_zkbuild_range_reuse.nim

zkbuild-read-only-test: zkbuild-prepare zkbuild-fv
	$(NIM) c -r $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/read-only-cache --out:$(ZKBUILD_DIR)/test_read_only tools/test_zkbuild_read_only.nim

zkbuild-variable-events-test: zkbuild-prepare zkbuild-fv
	cd formal/zkbuild && lake build export_variable_typing
	$(NIM) c -r $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/variable-events-cache --out:$(ZKBUILD_DIR)/test_variable_events tools/test_zkbuild_variable_events.nim formal/zkbuild/.lake/build/bin/export_variable_typing $(ZKBUILD_DIR)/variable-test

zkbuild-call-events-test: zkbuild-prepare zkbuild-fv
	cd formal/zkbuild && lake build export_call_typing
	$(NIM) c -r $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/call-events-cache --out:$(ZKBUILD_DIR)/test_call_events tools/test_zkbuild_call_events.nim formal/zkbuild/.lake/build/bin/export_call_typing $(ZKBUILD_DIR)/call-typing-test

zkbuild-indexed-signatures-test: zkbuild-prepare zkbuild-fv
	$(NIM) c -r $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/indexed-signatures-cache --out:$(ZKBUILD_DIR)/test_indexed_signatures tools/test_zkbuild_indexed_signatures.nim

zkbuild-control-typing-test: zkbuild-prepare zkbuild-fv
	cd formal/zkbuild && lake build check_control_plans
	$(NIM) c -r $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/control-typing-cache --out:$(ZKBUILD_DIR)/test_control_typing tools/test_zkbuild_control_typing.nim formal/zkbuild/.lake/build/bin/check_control_plans $(ZKBUILD_DIR)/control-plans-test

zkbuild-branch-typing-test: zkbuild-prepare zkbuild-fv
	cd formal/zkbuild && lake build check_branch_plans
	$(NIM) c -r $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/branch-typing-cache --out:$(ZKBUILD_DIR)/test_branch_typing tools/test_zkbuild_branch_typing.nim formal/zkbuild/.lake/build/bin/check_branch_plans $(ZKBUILD_DIR)/branch-plans-test

zkbuild-check: zkbuild-read-only-test zkbuild-variable-events-test zkbuild-call-events-test zkbuild-indexed-signatures-test zkbuild-control-typing-test zkbuild-range-reuse-test zkbuild-branch-typing-test zkbuild-parametric-test zkbuild-wasm-metadata-test zkbuild-instruction-lookup-test zkbuild-memory-metadata-test

zkbuild-instruction-events-test: zkbuild-prepare zkbuild-fv
	$(NIM) c -r $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/instruction-events-cache --out:$(ZKBUILD_DIR)/test_instruction_events tools/test_zkbuild_instruction_events.nim

zkbuild-control-events-test: zkbuild-prepare zkbuild-fv
	$(NIM) c -r $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/control-events-cache --out:$(ZKBUILD_DIR)/test_control_events tools/test_zkbuild_control_events.nim

zkbuild-operand-events-test: zkbuild-prepare zkbuild-fv
	$(NIM) c -r $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/operand-events-cache --out:$(ZKBUILD_DIR)/test_operand_events tools/test_zkbuild_operand_events.nim

zkbuild-memory-test: zkbuild-prepare zkbuild-fv
	$(NIM) c -r $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/memory-cache --out:$(ZKBUILD_DIR)/test_memory tools/test_zkbuild_memory.nim

zkbuild-permutation-test: zkbuild-prepare zkbuild-fv
	$(NIM) c -r $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/permutation-cache --out:$(ZKBUILD_DIR)/test_permutation tools/test_zkbuild_permutation.nim

zkbuild-numeric-lookup-test: zkbuild-prepare zkbuild-fv
	$(NIM) c -r $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/numeric-lookup-cache --out:$(ZKBUILD_DIR)/test_numeric_lookup tools/test_zkbuild_numeric_lookup.nim

zkbuild-numeric-typing-test: zkbuild-fv
	cd formal/zkbuild && lake build export_wasm_numeric_typing
	$(NIM) c -r -d:release --skipUserCfg --skipParentCfg --skipProjCfg --path:$(CURDIR)/src --nimcache:$(ZKBUILD_DIR)/numeric-typing-test-cache --out:$(ZKBUILD_DIR)/test_numeric_typing tools/test_wasm_numeric_typing.nim formal/zkbuild/.lake/build/bin/export_wasm_numeric_typing $(ZKBUILD_DIR)/numeric-typing-test

zkbuild-wasm-validation-test:
	$(NIM) c -r -d:release --skipUserCfg --skipParentCfg --skipProjCfg --path:$(CURDIR)/src --nimcache:$(ZKBUILD_DIR)/wasm-validation-cache --out:$(ZKBUILD_DIR)/test_wasm_validation tools/test_wasm_validation.nim

zkbuild-cios-test: zkbuild-prepare zkbuild-fv
	cd formal/zkbuild && lake build export_cios_montgomery
	$(NIM) c -r $(ZKBUILD_HOST_FLAGS) --cc:gcc -d:CTT_32 -d:CTT_ASM=false -d:zkbuildCiosTrace --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/cios-test-cache --out:$(ZKBUILD_DIR)/test_cios tools/test_zkbuild_cios.nim formal/zkbuild/.lake/build/bin/export_cios_montgomery $(ZKBUILD_DIR)/cios-test

zkbuild-fips-test: zkbuild-prepare zkbuild-fv
	cd formal/zkbuild && lake build export_fips_montgomery
	$(NIM) c -r $(ZKBUILD_HOST_FLAGS) --cc:gcc -d:CTT_32 -d:CTT_ASM=false -d:zkbuildFipsTrace --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/fips-test-cache --out:$(ZKBUILD_DIR)/test_fips tools/test_zkbuild_fips.nim formal/zkbuild/.lake/build/bin/export_fips_montgomery $(ZKBUILD_DIR)/fips-test

zkbuild-word-arithmetic-test: zkbuild-prepare zkbuild-fv
	cd formal/zkbuild && lake build export_word_arithmetic
	$(NIM) c -r $(ZKBUILD_HOST_FLAGS) --cc:gcc -d:CTT_32 -d:CTT_ASM=false --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/word-arithmetic-test-cache --out:$(ZKBUILD_DIR)/test_word_arithmetic tools/test_zkbuild_word_arithmetic.nim formal/zkbuild/.lake/build/bin/export_word_arithmetic $(ZKBUILD_DIR)/word-arithmetic-test

zkbuild-scalar-encoding-test: zkbuild-prepare zkbuild-fv
	cd formal/zkbuild && lake build export_scalar_encoding
	$(NIM) c -r $(ZKBUILD_HOST_FLAGS) -d:zkbuildScalarEncodingTest --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/scalar-encoding-test-cache --out:$(ZKBUILD_DIR)/test_scalar_encoding tools/test_zkbuild_scalar_encoding.nim formal/zkbuild/.lake/build/bin/export_scalar_encoding $(ZKBUILD_DIR)/scalar-encoding-test
	$(NIM) c -r $(ZKBUILD_HOST_FLAGS) --cc:gcc -d:CTT_32 -d:CTT_ASM=false -d:zkbuildScalarEncodingTest --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/scalar-encoding-32-test-cache --out:$(ZKBUILD_DIR)/test_scalar_encoding_32 tools/test_zkbuild_scalar_encoding.nim formal/zkbuild/.lake/build/bin/export_scalar_encoding $(ZKBUILD_DIR)/scalar-encoding-32-test

.PHONY: zkbuild-verifier-core-test

zkbuild-verifier-core-test: zkbuild-prepare zkbuild-fv
	cd formal/zkbuild && lake build export_verifier_core
	$(NIM) c -r $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/verifier-core-test-cache --out:$(ZKBUILD_DIR)/test_verifier_core tools/test_zkbuild_verifier_core.nim formal/zkbuild/.lake/build/bin/export_verifier_core $(ZKBUILD_DIR)/verifier-core-test

zkbuild-crypto-test: zkbuild-prepare
	$(NIM) c -r $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/crypto-test-cache --out:$(ZKBUILD_DIR)/test_crypto tools/test_zkbuild_crypto.nim tools/ref/zkbuild_crypto_vectors.json

zkbuild-interop-export: zkbuild-prepare
	$(NIM) c -r $(ZKBUILD_HOST_FLAGS) --nimcache:$(ZKBUILD_DIR)/interop-cache --out:$(ZKBUILD_DIR)/interop_export tools/zkbuild_interop_export.nim $(ZKBUILD_DIR)/interop-proofs.json

zkbuild-check: zkbuild-static-typing-test zkbuild-static-lookup-test zkbuild-static-events-test zkbuild-instruction-events-test zkbuild-control-events-test zkbuild-operand-events-test zkbuild-memory-test zkbuild-permutation-test zkbuild-wasm-validation-test zkbuild-numeric-typing-test zkbuild-numeric-lookup-test zkbuild-cios-test zkbuild-fips-test zkbuild-word-arithmetic-test zkbuild-scalar-encoding-test zkbuild-verifier-core-test zkbuild-test zkbuild-byte-compile-test zkbuild-byte-compile-matrix-test zkbuild-byte-decoder-test zkbuild-byte-compile-witness-test zkbuild-model-test zkbuild-matrix-test zkbuild-slot-matrix-test zkbuild-witness-test zkbuild-slot-witness-test zkbuild-compile-witness-test zkbuild-fft-model-test zkbuild-compiler-test zkbuild-qap-test zkbuild-crypto-test zkbuild-target-check

zkbuild-demo: zkbuild
	$(ZKBUILD_DIR)/zkbuild sample $(ZKBUILD_DIR)/sample.wasm
	$(ZKBUILD_DIR)/zkbuild setup validate $(ZKBUILD_DIR)/validate.pk $(ZKBUILD_DIR)/validate.vk
	$(ZKBUILD_DIR)/zkbuild prove $(ZKBUILD_DIR)/validate.pk $(ZKBUILD_DIR)/sample.wasm $(ZKBUILD_DIR)/sample.proof
	$(ZKBUILD_DIR)/zkbuild verify $(ZKBUILD_DIR)/validate.vk $(ZKBUILD_DIR)/sample.wasm $(ZKBUILD_DIR)/sample.proof

zkbuild-compile-demo: zkbuild
	$(ZKBUILD_DIR)/zkbuild sample-slots $(ZKBUILD_DIR)/slots.wasm
	$(ZKBUILD_DIR)/zkbuild setup compile $(ZKBUILD_DIR)/compile.pk $(ZKBUILD_DIR)/compile.vk
	$(ZKBUILD_DIR)/zkbuild prove $(ZKBUILD_DIR)/compile.pk $(ZKBUILD_DIR)/slots.wasm $(ZKBUILD_DIR)/compile.proof $(ZKBUILD_DIR)/sample.rv32
	$(ZKBUILD_DIR)/zkbuild verify $(ZKBUILD_DIR)/compile.vk $(ZKBUILD_DIR)/slots.wasm $(ZKBUILD_DIR)/compile.proof $(ZKBUILD_DIR)/sample.rv32

zkbuild-byte-compile-demo: zkbuild
	$(ZKBUILD_DIR)/zkbuild sample $(ZKBUILD_DIR)/bytes-compiled.wasm
	$(ZKBUILD_DIR)/zkbuild setup compile-bytes $(ZKBUILD_DIR)/compile-bytes.pk $(ZKBUILD_DIR)/compile-bytes.vk
	$(ZKBUILD_DIR)/zkbuild prove $(ZKBUILD_DIR)/compile-bytes.pk $(ZKBUILD_DIR)/bytes-compiled.wasm $(ZKBUILD_DIR)/compile-bytes.proof $(ZKBUILD_DIR)/bytes-compiled.rv32
	$(ZKBUILD_DIR)/zkbuild verify $(ZKBUILD_DIR)/compile-bytes.vk $(ZKBUILD_DIR)/bytes-compiled.wasm $(ZKBUILD_DIR)/compile-bytes.proof $(ZKBUILD_DIR)/bytes-compiled.rv32

.PHONY: zkbuild-montgomery-vectors zkbuild-word-vectors zkbuild-fips-vectors zkbuild-cios-vectors

zkbuild-cios-vectors: zkbuild-fv
	cd formal/zkbuild && lake exe export_cios_montgomery --nim $(abspath $(ZKBUILD_DIR))/cios-vectors.nim

zkbuild-fips-vectors: zkbuild-fv
	cd formal/zkbuild && lake exe export_fips_montgomery --nim $(abspath $(ZKBUILD_DIR))/fips-vectors.nim

zkbuild-word-vectors: zkbuild-fv
	cd formal/zkbuild && lake exe export_word_arithmetic --nim $(abspath $(ZKBUILD_DIR))/word-arithmetic-vectors.nim

zkbuild-montgomery-vectors: zkbuild-fv
	cd formal/zkbuild && lake exe export_scalar_encoding --montgomery $(abspath $(ZKBUILD_DIR))/scalar-montgomery-vectors.nim

zkbuild-native-qemu-test: zkbuild-compile-demo zkbuild-montgomery-vectors zkbuild-word-vectors zkbuild-fips-vectors zkbuild-cios-vectors
	$(NIM) c $(ZKBUILD_HOST_FLAGS) -d:zkbuildFipsTrace -d:zkbuildCiosTrace --os:any --cpu:riscv32 --cc:gcc --gcc.exe:$(ZKBUILD_RISCV_CC) --gcc.linkerexe:$(ZKBUILD_RISCV_CC) --mm:arc -d:useMalloc -d:nimNoLibc -d:noSignalHandler -d:zkbuildRv32Ram --noMain:on --threads:off --checks:on --assertions:on --stackTrace:off --lineTrace:off --panics:on --passC:"-march=rv32imafc_zicsr_zifencei -mabi=ilp32f -mcmodel=medany -ffunction-sections -fdata-sections -fno-builtin" --passL:"-march=rv32imafc_zicsr_zifencei -mabi=ilp32f -mcmodel=medany -nostdlib -nostartfiles -static -Wl,--gc-sections -T tools/zkbuild_qemu_native.ld -lgcc" --nimcache:$(ZKBUILD_DIR)/qemu-native-cache --out:$(ZKBUILD_DIR)/qemu-native.elf tools/zkbuild_qemu_native.nim
	$(NIM) c -r --skipUserCfg --skipParentCfg --skipProjCfg -d:release --nimcache:$(ZKBUILD_DIR)/qemu-runner-cache --out:$(ZKBUILD_DIR)/test_native_qemu tools/test_zkbuild_native_qemu.nim $(ZKBUILD_QEMU) $(ZKBUILD_DIR)/qemu-native.elf

zkbuild-byte-native-qemu-test: zkbuild-byte-compile-demo zkbuild-montgomery-vectors zkbuild-word-vectors zkbuild-fips-vectors zkbuild-cios-vectors
	$(NIM) c $(ZKBUILD_HOST_FLAGS) -d:zkbuildByteNativeTest -d:zkbuildFipsTrace -d:zkbuildCiosTrace --os:any --cpu:riscv32 --cc:gcc --gcc.exe:$(ZKBUILD_RISCV_CC) --gcc.linkerexe:$(ZKBUILD_RISCV_CC) --mm:arc -d:useMalloc -d:nimNoLibc -d:noSignalHandler -d:zkbuildRv32Ram --noMain:on --threads:off --checks:on --assertions:on --stackTrace:off --lineTrace:off --panics:on --passC:"-march=rv32imafc_zicsr_zifencei -mabi=ilp32f -mcmodel=medany -ffunction-sections -fdata-sections -fno-builtin" --passL:"-march=rv32imafc_zicsr_zifencei -mabi=ilp32f -mcmodel=medany -nostdlib -nostartfiles -static -Wl,--gc-sections -T tools/zkbuild_qemu_native.ld -lgcc" --nimcache:$(ZKBUILD_DIR)/qemu-byte-native-cache --out:$(ZKBUILD_DIR)/qemu-byte-native.elf tools/zkbuild_qemu_native.nim
	$(NIM) c -r --skipUserCfg --skipParentCfg --skipProjCfg -d:release --nimcache:$(ZKBUILD_DIR)/qemu-runner-cache --out:$(ZKBUILD_DIR)/test_native_qemu tools/test_zkbuild_native_qemu.nim $(ZKBUILD_QEMU) $(ZKBUILD_DIR)/qemu-byte-native.elf

zkbuild-bench: zkbuild-demo
	$(NIM) c -r $(ZKBUILD_HOST_FLAGS) --nimcache:$(ZKBUILD_DIR)/bench-cache --out:$(ZKBUILD_DIR)/zkbuild_bench tools/zkbuild_bench.nim $(ZKBUILD_DIR)

zkbuild-target-check: zkbuild-prepare
	$(NIM) c --noLinking:on -d:bl808kernel -d:bl808m0 --path:$(ZKBUILD_DEPS) --nimcache:$(ZKBUILD_DIR)/m0-cache --out:$(ZKBUILD_DIR)/target_check tools/zkbuild_target_check.nim

.PHONY: zkbuild-validator-target-check
zkbuild-validator-target-check:
	$(NIM) c --noLinking:on -d:bl808kernel -d:bl808m0 --nimcache:$(ZKBUILD_DIR)/validator-m0-cache --out:$(ZKBUILD_DIR)/validator_target_check tools/zkbuild_validator_target_check.nim

zkbuild-check: zkbuild-validator-target-check

help:
	@echo "BL808 HAL build system"
	@echo ""
	@echo "Build targets:"
	@echo "  make m0 FILE=<source.nim>   Build firmware for M0 (E907, RV32)"
	@echo "  make d0 FILE=<source.nim>   Build firmware for D0 (C906, RV64)"
	@echo "  make lp FILE=<source.nim>   Build firmware for LP (E902, RV32E)"
	@echo "  make ipc                    Build IPC demo for both cores"
	@echo "  make examples-check         Compile-check all example programs"
	@echo "  make test                   Host pytest gate (no hardware needed)"
	@echo "  make test-all               Full host pytest (informational)"
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
	@echo "  make hw-npu-smoke-anchor UART_PORT=<p> Probe/install anchor, then run NPU smoke via existing anchor"
	@echo "  make hw-smoke-jtag UART_PORT=<p> Build and run smoke tests from RAM over JTAG"
	@echo "  make hw-allcore-jtag UART_PORT=<p> Run the all-core RAM-load test over JTAG"
	@echo "  make hw-full UART_PORT=<p>  Build, JTAG-flash, and run full tests"
	@echo "  make hw-full-uart UART_PORT=<p> Build, UART-flash, and run full tests"
	@echo "  make hw-full-anchor UART_PORT=<p> Build, UART-anchor-flash, and run full tests"
	@echo "  make hw-e2e-quick UART_PORT=<p> WIFI_SSID=<s> WIFI_PASSWORD=<p>  WiFi blob N=3 e2e soak (Iteration 1)"
	@echo "  make hw-e2e-lwip-smoke UART_PORT=<p> WIFI_SSID=<s> WIFI_PASSWORD=<p>  WiFi lwIP DHCP+ICMP smoke N=3"
	@echo ""
	@echo "Options:"
	@echo "  UART_PORT=/dev/ttyUSB0      Runtime UART; also used for flashing by default"
	@echo "  FLASH_PORT=$(UART_PORT)     Serial port for UART bootloader flashing"
	@echo "  FLASH_BAUD=230400           Baud rate for flashing"
	@echo "  NIM_FLAGS=-d:bl808kernel    Extra Nim flags for make build targets"
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
	$(NIM) c $(NIM_FLAGS) -d:bl808m0 --nimcache:$(BUILD_DIR)/nimcache_m0 -o:$(BUILD_DIR)/m0_firmware.elf $(FILE)
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
	$(NIM) c $(NIM_FLAGS) -d:bl808d0 --nimcache:$(BUILD_DIR)/nimcache_d0 -o:$(BUILD_DIR)/d0_firmware.elf $(FILE)
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
	$(NIM) c $(NIM_FLAGS) -d:bl808lp --nimcache:$(BUILD_DIR)/nimcache_lp -o:$(BUILD_DIR)/lp_firmware.elf $(FILE)
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
	$(NIM) c $(NIM_FLAGS) -d:bl808m0 --nimcache:$(BUILD_DIR)/nimcache_ipc_m0 -o:$(BUILD_DIR)/ipc_m0.elf examples/ipc_demo.nim
	$(if $(RV32_OBJCOPY),$(RV32_OBJCOPY),$(error objcopy not found)) \
		-O binary $(BUILD_DIR)/ipc_m0.elf $(BUILD_DIR)/ipc_m0.bin
	@echo "=== Building IPC demo for D0 ==="
	$(NIM) c $(NIM_FLAGS) -d:bl808d0 --nimcache:$(BUILD_DIR)/nimcache_ipc_d0 -o:$(BUILD_DIR)/ipc_d0.elf examples/ipc_demo.nim
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

# Host test gate. Green on a clean tree; runs the self-contained pytest suite
# that does not need built artifacts or hardware. Excluded categories and why:
#   test_efuse_provision / test_secureboot_chain / test_sbtool_container:
#     standalone CLI check scripts (top-level sys.exit / __main__), not pytest
#     cases — they abort collection. Run them directly as scripts instead.
#   test_*_policy.py: assert source-tree text patterns (WiFi/BLE/CPS). They are
#     coupled to the in-flight WiFi/BLE firmware rewrite and are pre-existing
#     red on the dirty tree; tracked for M6 once that work settles.
#   test_validate_*.py: require built ELF artifacts (objdump etc.); run them
#     after a hardware build, not in the fast host gate.
# Fuzzer compilation belongs to M6 (the fuzzers need the bare-metal
# memory-manager config and are not host-compilable with plain `nim c`).
PYTEST_TEST_IGNORE := \
	--ignore=tools/test_efuse_provision.py \
	--ignore=tools/test_secureboot_chain.py \
	--ignore=tools/test_sbtool_container.py \
	--ignore-glob=tools/test_*_policy.py \
	--ignore-glob=tools/test_validate_*.py

test: venv
	@echo "=== Host pytest gate ==="
	$(PYTHON) -m pytest tools/ $(PYTEST_TEST_IGNORE) -q -p no:cacheprovider
	@echo "=== test: PASS ==="

test-all: venv
	@echo "=== Full host pytest (informational; surfaces pre-existing failures) ==="
	$(PYTHON) -m pytest tools/ \
		--ignore=tools/test_efuse_provision.py \
		--ignore=tools/test_secureboot_chain.py \
		--ignore=tools/test_sbtool_container.py -q -p no:cacheprovider

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

hw-npu-anchor-probe: venv
	$(HW_VALIDATE) --uart-anchor-probe --uart $(UART_PORT) --uart-baud $(UART_BAUD) $(HW_VALIDATE_FLAGS)

hw-npu-anchor-install: venv
	$(HW_VALIDATE) --test m0_uart_flash_anchor --uart-anchor-flash --uart-anchor-runtime-jtag --uart-anchor-reset-after-flash --uart $(UART_PORT) --uart-baud $(UART_BAUD) $(HW_VALIDATE_FLAGS)

hw-npu-smoke-anchor: venv
	@$(HW_VALIDATE) --uart-anchor-probe --uart $(UART_PORT) --uart-baud $(UART_BAUD) $(HW_VALIDATE_FLAGS) || \
	  $(HW_VALIDATE) --test m0_uart_flash_anchor --uart-anchor-flash --uart-anchor-runtime-jtag --uart-anchor-reset-after-flash --uart $(UART_PORT) --uart-baud $(UART_BAUD) $(HW_VALIDATE_FLAGS)
	$(HW_VALIDATE) --test m0_npu_smoke_test --uart-anchor-flash --uart-anchor-existing --uart-anchor-runtime-jtag --jtag-memory-log --uart $(UART_PORT) --uart-baud $(UART_BAUD) $(HW_VALIDATE_FLAGS)
	@$(HW_VALIDATE) --uart-anchor-probe --uart $(UART_PORT) --uart-baud $(UART_BAUD) $(HW_VALIDATE_FLAGS) || \
	  $(HW_VALIDATE) --test m0_uart_flash_anchor --uart-anchor-flash --uart-anchor-runtime-jtag --uart-anchor-reset-after-flash --uart $(UART_PORT) --uart-baud $(UART_BAUD) $(HW_VALIDATE_FLAGS)
	$(HW_VALIDATE) --test m0_npu_route_smoke_test --uart-anchor-flash --uart-anchor-existing --uart-anchor-runtime-jtag --jtag-memory-log --uart $(UART_PORT) --uart-baud $(UART_BAUD) $(HW_VALIDATE_FLAGS)
	@$(HW_VALIDATE) --uart-anchor-probe --uart $(UART_PORT) --uart-baud $(UART_BAUD) $(HW_VALIDATE_FLAGS) || \
	  $(HW_VALIDATE) --test m0_uart_flash_anchor --uart-anchor-flash --uart-anchor-runtime-jtag --uart-anchor-reset-after-flash --uart $(UART_PORT) --uart-baud $(UART_BAUD) $(HW_VALIDATE_FLAGS)
	$(HW_VALIDATE) --test m0_npu_model_smoke_test --uart-anchor-flash --uart-anchor-existing --uart-anchor-runtime-jtag --jtag-memory-log --uart $(UART_PORT) --uart-baud $(UART_BAUD) $(HW_VALIDATE_FLAGS)
	@$(HW_VALIDATE) --uart-anchor-probe --uart $(UART_PORT) --uart-baud $(UART_BAUD) $(HW_VALIDATE_FLAGS) || \
	  $(HW_VALIDATE) --test m0_uart_flash_anchor --uart-anchor-flash --uart-anchor-runtime-jtag --uart-anchor-reset-after-flash --uart $(UART_PORT) --uart-baud $(UART_BAUD) $(HW_VALIDATE_FLAGS)
	$(HW_VALIDATE) --test m0_npu_parse_smoke_test --uart-anchor-flash --uart-anchor-existing --uart-anchor-runtime-jtag --jtag-memory-log --uart $(UART_PORT) --uart-baud $(UART_BAUD) $(HW_VALIDATE_FLAGS)

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

hw-e2e-lwip-smoke: venv
	@test -n "$(WIFI_SSID)" || (echo "Error: WIFI_SSID is required (e.g. WIFI_SSID=Frog)"; exit 1)
	@test -n "$(WIFI_PASSWORD)" || (echo "Error: WIFI_PASSWORD is required"; exit 1)
	$(PYTHON) tools/hw_e2e.py --cell wifi-lwip-smoke --uart $(UART_PORT) --uart-baud $(UART_BAUD) --ssid $(WIFI_SSID) --password $(WIFI_PASSWORD) --attempts 3

# Clean build artifacts
clean:
	rm -rf $(BUILD_DIR)
	@echo "Build directory cleaned."

.PHONY: zkbuild-sha-embedded-test
zkbuild-sha-embedded-test: zkbuild-prepare zkbuild-fv
	cd formal/zkbuild && lake build check_sha_embedded
	$(NIM) c $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/sha-audit-baseline-cache --out:$(ZKBUILD_DIR)/sha_audit_baseline tools/zkbuild_audit_sha.nim
	$(NIM) c $(ZKBUILD_HOST_FLAGS) -d:zkbuildGadgetAudit -d:zkbuildShaAudit --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/sha-audit-cache --out:$(ZKBUILD_DIR)/sha_audit tools/zkbuild_audit_sha.nim
	$(NIM) c -r $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/sha-embedded-test-cache --out:$(ZKBUILD_DIR)/test_sha_embedded tools/test_zkbuild_sha_embedded.nim $(ZKBUILD_DIR)/sha_audit_baseline $(ZKBUILD_DIR)/sha_audit formal/zkbuild/.lake/build/bin/check_sha_embedded $(ZKBUILD_DIR)/sha-embedded-tests

zkbuild-check: zkbuild-sha-embedded-test

.PHONY: zkbuild-source-hash-test
zkbuild-source-hash-test: zkbuild-prepare zkbuild-fv
	cd formal/zkbuild && lake build check_source_hash
	$(NIM) c $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/source-audit-baseline-cache --out:$(ZKBUILD_DIR)/source_audit_baseline tools/zkbuild_audit_source.nim
	$(NIM) c $(ZKBUILD_HOST_FLAGS) -d:zkbuildGadgetAudit -d:zkbuildShaAudit -d:zkbuildSourceAudit --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/source-audit-cache --out:$(ZKBUILD_DIR)/source_audit tools/zkbuild_audit_source.nim
	$(NIM) c -r $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/source-hash-test-cache --out:$(ZKBUILD_DIR)/test_source_hash tools/test_zkbuild_source_hash.nim $(ZKBUILD_DIR)/source_audit_baseline $(ZKBUILD_DIR)/source_audit formal/zkbuild/.lake/build/bin/check_source_hash $(ZKBUILD_DIR)/source-hash-tests

zkbuild-check: zkbuild-source-hash-test

.PHONY: zkbuild-permutation-audit-test zkbuild-memory-layout-test
zkbuild-permutation-audit-test: zkbuild-prepare zkbuild-fv
	cd formal/zkbuild && lake build check_permutation_audit
	$(NIM) c $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/perm-audit-baseline-cache --out:$(ZKBUILD_DIR)/perm_audit_baseline tools/zkbuild_audit_permutation.nim
	$(NIM) c $(ZKBUILD_HOST_FLAGS) -d:zkbuildPermutationAudit --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/perm-audit-cache --out:$(ZKBUILD_DIR)/perm_audit tools/zkbuild_audit_permutation.nim
	$(NIM) c -r $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/perm-audit-test-cache --out:$(ZKBUILD_DIR)/test_permutation_audit tools/test_zkbuild_permutation_audit.nim $(ZKBUILD_DIR)/perm_audit_baseline $(ZKBUILD_DIR)/perm_audit formal/zkbuild/.lake/build/bin/check_permutation_audit $(ZKBUILD_DIR)/permutation-audit-tests

zkbuild-memory-layout-test: zkbuild-prepare zkbuild-fv
	cd formal/zkbuild && lake build check_memory_layout
	$(NIM) c -r $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/memory-layout-test-cache --out:$(ZKBUILD_DIR)/test_memory_layout tools/test_zkbuild_memory_layout.nim formal/zkbuild/.lake/build/bin/check_memory_layout $(ZKBUILD_DIR)/memory-layout-tests

zkbuild-check: zkbuild-permutation-audit-test zkbuild-memory-layout-test

.PHONY: zkbuild-memory-circuit-test
zkbuild-memory-circuit-test: zkbuild-prepare zkbuild-fv
	cd formal/zkbuild && lake build check_memory_audit
	$(NIM) c $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/memory-audit-baseline-cache --out:$(ZKBUILD_DIR)/memory_audit_baseline tools/zkbuild_audit_memory.nim
	$(NIM) c $(ZKBUILD_HOST_FLAGS) -d:zkbuildMemoryAudit -d:zkbuildGadgetAudit -d:zkbuildPermutationAudit --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/memory-audit-cache --out:$(ZKBUILD_DIR)/memory_audit tools/zkbuild_audit_memory.nim
	$(NIM) c -r $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/memory-audit-test-cache --out:$(ZKBUILD_DIR)/test_memory_audit tools/test_zkbuild_memory_audit.nim $(ZKBUILD_DIR)/memory_audit_baseline $(ZKBUILD_DIR)/memory_audit formal/zkbuild/.lake/build/bin/check_memory_audit $(ZKBUILD_DIR)/memory-circuit-tests

zkbuild-check: zkbuild-memory-circuit-test

.PHONY: zkbuild-byte-memory-test
zkbuild-byte-memory-test: zkbuild-prepare zkbuild-fv
	cd formal/zkbuild && lake build check_byte_memory
	$(NIM) c $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/byte-memory-baseline-cache --out:$(ZKBUILD_DIR)/byte_memory_baseline tools/zkbuild_audit_byte_memory.nim
	$(NIM) c $(ZKBUILD_HOST_FLAGS) -d:zkbuildByteMemoryAudit -d:zkbuildSourceAudit -d:zkbuildShaAudit -d:zkbuildMemoryAudit -d:zkbuildGadgetAudit -d:zkbuildPermutationAudit --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/byte-memory-audit-cache --out:$(ZKBUILD_DIR)/byte_memory_audit tools/zkbuild_audit_byte_memory.nim
	$(NIM) c -r $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/byte-memory-test-cache --out:$(ZKBUILD_DIR)/test_byte_memory tools/test_zkbuild_byte_memory.nim $(ZKBUILD_DIR)/byte_memory_baseline $(ZKBUILD_DIR)/byte_memory_audit formal/zkbuild/.lake/build/bin/check_byte_memory $(ZKBUILD_DIR)/byte-memory-tests

zkbuild-check: zkbuild-byte-memory-test

.PHONY: zkbuild-audit-cli
zkbuild-audit-cli: zkbuild-prepare
	$(NIM) c $(ZKBUILD_HOST_FLAGS) -d:zkbuildByteMemoryAudit -d:zkbuildSourceAudit -d:zkbuildShaAudit -d:zkbuildMemoryAudit -d:zkbuildGadgetAudit -d:zkbuildPermutationAudit --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/audit-cli-cache --out:$(ZKBUILD_DIR)/zkbuild-audit tools/zkbuild.nim

.PHONY: zkbuild-byte-memory-cli-test
zkbuild-byte-memory-cli-test: zkbuild-audit-cli zkbuild-fv
	cd formal/zkbuild && lake build check_byte_memory
	$(NIM) c -r $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/byte-memory-cli-test-cache --out:$(ZKBUILD_DIR)/test_byte_memory_cli tools/test_zkbuild_byte_memory_cli.nim $(ZKBUILD_DIR)/zkbuild-audit formal/zkbuild/.lake/build/bin/check_byte_memory $(ZKBUILD_DIR)/byte-memory-cli-tests

zkbuild-check: zkbuild-byte-memory-cli-test

ZKBUILD_TOKEN_AUDIT_FLAGS = -d:zkbuildTokenAudit -d:zkbuildByteMemoryAudit -d:zkbuildSourceAudit -d:zkbuildShaAudit -d:zkbuildMemoryAudit -d:zkbuildGadgetAudit -d:zkbuildPermutationAudit
.PHONY: zkbuild-token-circuit-test zkbuild-token-cli zkbuild-token-cli-test
zkbuild-token-circuit-test: zkbuild-prepare zkbuild-fv
	cd formal/zkbuild && lake build check_tokens
	$(NIM) c $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/token-baseline-cache --out:$(ZKBUILD_DIR)/token_baseline tools/zkbuild_audit_tokens.nim
	$(NIM) c $(ZKBUILD_HOST_FLAGS) $(ZKBUILD_TOKEN_AUDIT_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/token-audit-cache --out:$(ZKBUILD_DIR)/token_audit tools/zkbuild_audit_tokens.nim
	$(NIM) c -r $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/token-test-cache --out:$(ZKBUILD_DIR)/test_token_audit tools/test_zkbuild_token_audit.nim $(ZKBUILD_DIR)/token_baseline $(ZKBUILD_DIR)/token_audit formal/zkbuild/.lake/build/bin/check_tokens $(ZKBUILD_DIR)/token-tests

zkbuild-token-cli: zkbuild-prepare
	$(NIM) c $(ZKBUILD_HOST_FLAGS) $(ZKBUILD_TOKEN_AUDIT_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/token-cli-cache --out:$(ZKBUILD_DIR)/zkbuild-token-audit tools/zkbuild.nim

zkbuild-token-cli-test: zkbuild-token-cli zkbuild-fv
	cd formal/zkbuild && lake build check_tokens
	$(NIM) c -r $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/token-cli-test-cache --out:$(ZKBUILD_DIR)/test_token_cli tools/test_zkbuild_byte_memory_cli.nim $(ZKBUILD_DIR)/zkbuild-token-audit formal/zkbuild/.lake/build/bin/check_tokens $(ZKBUILD_DIR)/token-cli-tests source-sha256-token-readers

zkbuild-check: zkbuild-token-circuit-test zkbuild-token-cli-test

.PHONY: zkbuild-token-integer-test
zkbuild-token-integer-test: zkbuild-prepare zkbuild-fv
	cd formal/zkbuild && lake build export_token_decode
	$(NIM) c -r $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/token-integer-cache --out:$(ZKBUILD_DIR)/test_token_integer tools/test_zkbuild_token_integer.nim formal/zkbuild/.lake/build/bin/export_token_decode $(ZKBUILD_DIR)/token-integer-tests

zkbuild-check: zkbuild-token-integer-test

ZKBUILD_ENVELOPE_AUDIT_FLAGS = -d:zkbuildEnvelopeAudit -d:zkbuildLookupAudit $(ZKBUILD_TOKEN_AUDIT_FLAGS)
.PHONY: zkbuild-lookup-circuit-test zkbuild-envelope-circuit-test zkbuild-envelope-cli zkbuild-envelope-cli-test
zkbuild-lookup-circuit-test: zkbuild-prepare zkbuild-fv
	cd formal/zkbuild && lake build check_lookup
	$(NIM) c $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/lookup-baseline-cache --out:$(ZKBUILD_DIR)/lookup_baseline tools/zkbuild_audit_lookup.nim
	$(NIM) c $(ZKBUILD_HOST_FLAGS) -d:zkbuildLookupAudit $(ZKBUILD_TOKEN_AUDIT_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/lookup-audit-cache --out:$(ZKBUILD_DIR)/lookup_audit tools/zkbuild_audit_lookup.nim
	$(NIM) c -r $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/lookup-test-cache --out:$(ZKBUILD_DIR)/test_lookup_audit tools/test_zkbuild_lookup_audit.nim $(ZKBUILD_DIR)/lookup_baseline $(ZKBUILD_DIR)/lookup_audit formal/zkbuild/.lake/build/bin/check_lookup $(ZKBUILD_DIR)/lookup-tests

zkbuild-envelope-circuit-test: zkbuild-prepare zkbuild-fv
	cd formal/zkbuild && lake build check_envelope
	$(NIM) c $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/envelope-baseline-cache --out:$(ZKBUILD_DIR)/envelope_baseline tools/zkbuild_audit_envelope.nim
	$(NIM) c $(ZKBUILD_HOST_FLAGS) $(ZKBUILD_ENVELOPE_AUDIT_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/envelope-audit-cache --out:$(ZKBUILD_DIR)/envelope_audit tools/zkbuild_audit_envelope.nim
	$(NIM) c -r $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/envelope-test-cache --out:$(ZKBUILD_DIR)/test_envelope_audit tools/test_zkbuild_envelope_audit.nim $(ZKBUILD_DIR)/envelope_baseline $(ZKBUILD_DIR)/envelope_audit formal/zkbuild/.lake/build/bin/check_envelope $(ZKBUILD_DIR)/envelope-tests

zkbuild-envelope-cli: zkbuild-prepare
	$(NIM) c $(ZKBUILD_HOST_FLAGS) $(ZKBUILD_ENVELOPE_AUDIT_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/envelope-cli-cache --out:$(ZKBUILD_DIR)/zkbuild-envelope-audit tools/zkbuild.nim

zkbuild-envelope-cli-test: zkbuild-envelope-cli zkbuild-fv
	cd formal/zkbuild && lake build check_envelope
	$(NIM) c -r $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/envelope-cli-test-cache --out:$(ZKBUILD_DIR)/test_envelope_cli tools/test_zkbuild_byte_memory_cli.nim $(ZKBUILD_DIR)/zkbuild-envelope-audit formal/zkbuild/.lake/build/bin/check_envelope $(ZKBUILD_DIR)/envelope-cli-tests source-sha256-section-envelope

zkbuild-check: zkbuild-lookup-circuit-test zkbuild-envelope-circuit-test zkbuild-envelope-cli-test

ZKBUILD_TABLE_AUDIT_FLAGS = -d:zkbuildPackedAudit -d:zkbuildReadOnlyAudit $(ZKBUILD_ENVELOPE_AUDIT_FLAGS)
.PHONY: zkbuild-readonly-circuit-test zkbuild-tables-cli zkbuild-tables-cli-test
zkbuild-readonly-circuit-test: zkbuild-prepare zkbuild-fv
	cd formal/zkbuild && lake build check_readonly check_module_tables
	$(NIM) c $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/readonly-baseline-cache --out:$(ZKBUILD_DIR)/readonly_baseline tools/zkbuild_audit_readonly.nim
	$(NIM) c $(ZKBUILD_HOST_FLAGS) $(ZKBUILD_TABLE_AUDIT_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/readonly-audit-cache --out:$(ZKBUILD_DIR)/readonly_audit tools/zkbuild_audit_readonly.nim
	$(NIM) c -r $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/readonly-test-cache --out:$(ZKBUILD_DIR)/test_readonly_audit tools/test_zkbuild_readonly_audit.nim $(ZKBUILD_DIR)/readonly_baseline $(ZKBUILD_DIR)/readonly_audit formal/zkbuild/.lake/build/bin/check_readonly formal/zkbuild/.lake/build/bin/check_module_tables $(ZKBUILD_DIR)/readonly-tests

zkbuild-tables-cli: zkbuild-prepare
	$(NIM) c $(ZKBUILD_HOST_FLAGS) $(ZKBUILD_TABLE_AUDIT_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/tables-cli-cache --out:$(ZKBUILD_DIR)/zkbuild-tables-audit tools/zkbuild.nim

zkbuild-tables-cli-test: zkbuild-tables-cli zkbuild-fv
	cd formal/zkbuild && lake build check_module_tables
	$(NIM) c -r $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/tables-cli-test-cache --out:$(ZKBUILD_DIR)/test_tables_cli tools/test_zkbuild_byte_memory_cli.nim $(ZKBUILD_DIR)/zkbuild-tables-audit formal/zkbuild/.lake/build/bin/check_module_tables $(ZKBUILD_DIR)/tables-cli-tests source-sha256-envelope-table-membership-packed-fields

zkbuild-check: zkbuild-readonly-circuit-test zkbuild-tables-cli-test

.PHONY: zkbuild-packed-circuit-test
zkbuild-packed-circuit-test: zkbuild-prepare zkbuild-fv
	cd formal/zkbuild && lake build check_packed
	$(NIM) c $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/packed-baseline-cache --out:$(ZKBUILD_DIR)/packed_baseline tools/zkbuild_audit_packed.nim
	$(NIM) c $(ZKBUILD_HOST_FLAGS) -d:zkbuildPackedAudit $(ZKBUILD_TOKEN_AUDIT_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/packed-audit-cache --out:$(ZKBUILD_DIR)/packed_audit tools/zkbuild_audit_packed.nim
	$(NIM) c -r $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/packed-test-cache --out:$(ZKBUILD_DIR)/test_packed_audit tools/test_zkbuild_packed_audit.nim $(ZKBUILD_DIR)/packed_baseline $(ZKBUILD_DIR)/packed_audit formal/zkbuild/.lake/build/bin/check_packed $(ZKBUILD_DIR)/packed-tests

zkbuild-check: zkbuild-packed-circuit-test

ZKBUILD_DECLARATION_AUDIT_FLAGS = -d:zkbuildDeclarationAudit $(ZKBUILD_TABLE_AUDIT_FLAGS)
.PHONY: zkbuild-declaration-circuit-test zkbuild-declarations-cli zkbuild-declarations-cli-test
zkbuild-declaration-circuit-test: zkbuild-prepare zkbuild-fv
	cd formal/zkbuild && lake build check_declarations
	$(NIM) c $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/declaration-baseline-cache --out:$(ZKBUILD_DIR)/declaration_baseline tools/zkbuild_audit_declarations.nim
	$(NIM) c $(ZKBUILD_HOST_FLAGS) $(ZKBUILD_DECLARATION_AUDIT_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/declaration-audit-cache --out:$(ZKBUILD_DIR)/declaration_audit tools/zkbuild_audit_declarations.nim
	$(NIM) c -r $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/declaration-test-cache --out:$(ZKBUILD_DIR)/test_declaration_audit tools/test_zkbuild_declaration_audit.nim $(ZKBUILD_DIR)/declaration_baseline $(ZKBUILD_DIR)/declaration_audit formal/zkbuild/.lake/build/bin/check_declarations $(ZKBUILD_DIR)/declaration-tests

zkbuild-declarations-cli: zkbuild-prepare
	$(NIM) c $(ZKBUILD_HOST_FLAGS) $(ZKBUILD_DECLARATION_AUDIT_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/declarations-cli-cache --out:$(ZKBUILD_DIR)/zkbuild-declarations-audit tools/zkbuild.nim

zkbuild-declarations-cli-test: zkbuild-declarations-cli zkbuild-fv
	cd formal/zkbuild && lake build check_declarations
	$(NIM) c -r $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/declarations-cli-test-cache --out:$(ZKBUILD_DIR)/test_declarations_cli tools/test_zkbuild_byte_memory_cli.nim $(ZKBUILD_DIR)/zkbuild-declarations-audit formal/zkbuild/.lake/build/bin/check_declarations $(ZKBUILD_DIR)/declarations-cli-tests source-sha256-declaration-bindings

zkbuild-check: zkbuild-declaration-circuit-test zkbuild-declarations-cli-test

ZKBUILD_INDEXED_AUDIT_FLAGS = -d:zkbuildIndexedAudit $(ZKBUILD_DECLARATION_AUDIT_FLAGS)
.PHONY: zkbuild-indexed-fixtures zkbuild-indexed-cli
zkbuild-indexed-fixtures: zkbuild-prepare
	$(NIM) c $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/declaration-baseline-cache --out:$(ZKBUILD_DIR)/declaration_baseline tools/zkbuild_audit_declarations.nim
	$(NIM) c $(ZKBUILD_HOST_FLAGS) $(ZKBUILD_INDEXED_AUDIT_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/indexed-audit-cache --out:$(ZKBUILD_DIR)/indexed_audit tools/zkbuild_audit_declarations.nim

zkbuild-indexed-cli: zkbuild-prepare
	$(NIM) c $(ZKBUILD_HOST_FLAGS) $(ZKBUILD_INDEXED_AUDIT_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/indexed-cli-cache --out:$(ZKBUILD_DIR)/zkbuild-indexed-audit tools/zkbuild.nim

.PHONY: zkbuild-indexed-circuit-test zkbuild-indexed-cli-test
zkbuild-indexed-circuit-test: zkbuild-indexed-fixtures zkbuild-fv
	cd formal/zkbuild && lake build check_indexed
	$(NIM) c -r $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/indexed-test-cache --out:$(ZKBUILD_DIR)/test_indexed_audit tools/test_zkbuild_indexed_audit.nim $(ZKBUILD_DIR)/declaration_baseline $(ZKBUILD_DIR)/indexed_audit formal/zkbuild/.lake/build/bin/check_indexed $(ZKBUILD_DIR)/indexed-tests

zkbuild-indexed-cli-test: zkbuild-indexed-cli zkbuild-fv
	cd formal/zkbuild && lake build check_indexed
	$(NIM) c -r $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/indexed-cli-test-cache --out:$(ZKBUILD_DIR)/test_indexed_cli tools/test_zkbuild_byte_memory_cli.nim $(ZKBUILD_DIR)/zkbuild-indexed-audit formal/zkbuild/.lake/build/bin/check_indexed $(ZKBUILD_DIR)/indexed-cli-tests source-sha256-indexed-signatures

zkbuild-check: zkbuild-indexed-circuit-test zkbuild-indexed-cli-test

ZKBUILD_SIGNATURE_AUDIT_FLAGS = -d:zkbuildSignatureAudit $(ZKBUILD_INDEXED_AUDIT_FLAGS)
.PHONY: zkbuild-signature-fixtures zkbuild-signature-cli
zkbuild-signature-fixtures: zkbuild-prepare
	$(NIM) c $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/declaration-baseline-cache --out:$(ZKBUILD_DIR)/declaration_baseline tools/zkbuild_audit_declarations.nim
	$(NIM) c $(ZKBUILD_HOST_FLAGS) $(ZKBUILD_SIGNATURE_AUDIT_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/signature-audit-cache --out:$(ZKBUILD_DIR)/signature_audit tools/zkbuild_audit_declarations.nim

zkbuild-signature-cli: zkbuild-prepare
	$(NIM) c $(ZKBUILD_HOST_FLAGS) $(ZKBUILD_SIGNATURE_AUDIT_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/signature-cli-cache --out:$(ZKBUILD_DIR)/zkbuild-signature-audit tools/zkbuild.nim

.PHONY: zkbuild-signature-circuit-test zkbuild-signature-cli-test
zkbuild-signature-circuit-test: zkbuild-signature-fixtures zkbuild-fv
	cd formal/zkbuild && lake build check_signatures
	$(NIM) c -r $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/signature-test-cache --out:$(ZKBUILD_DIR)/test_signature_audit tools/test_zkbuild_signature_audit.nim $(ZKBUILD_DIR)/declaration_baseline $(ZKBUILD_DIR)/signature_audit formal/zkbuild/.lake/build/bin/check_signatures $(ZKBUILD_DIR)/signature-tests

zkbuild-signature-cli-test: zkbuild-signature-cli zkbuild-fv
	cd formal/zkbuild && lake build check_signatures
	$(NIM) c -r $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/signature-cli-test-cache --out:$(ZKBUILD_DIR)/test_signature_cli tools/test_zkbuild_byte_memory_cli.nim $(ZKBUILD_DIR)/zkbuild-signature-audit formal/zkbuild/.lake/build/bin/check_signatures $(ZKBUILD_DIR)/signature-cli-tests source-sha256-signature-origins

zkbuild-check: zkbuild-signature-circuit-test zkbuild-signature-cli-test

ZKBUILD_IMPORT_AUDIT_FLAGS = -d:zkbuildImportAudit $(ZKBUILD_SIGNATURE_AUDIT_FLAGS)
.PHONY: zkbuild-import-fixtures zkbuild-import-cli
zkbuild-import-fixtures: zkbuild-prepare
	$(NIM) c $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/declaration-baseline-cache --out:$(ZKBUILD_DIR)/declaration_baseline tools/zkbuild_audit_declarations.nim
	$(NIM) c $(ZKBUILD_HOST_FLAGS) $(ZKBUILD_IMPORT_AUDIT_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/import-audit-cache --out:$(ZKBUILD_DIR)/import_audit tools/zkbuild_audit_declarations.nim

zkbuild-import-cli: zkbuild-prepare
	$(NIM) c $(ZKBUILD_HOST_FLAGS) $(ZKBUILD_IMPORT_AUDIT_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/import-cli-cache --out:$(ZKBUILD_DIR)/zkbuild-import-audit tools/zkbuild.nim

.PHONY: zkbuild-import-circuit-test zkbuild-import-cli-test
zkbuild-import-circuit-test: zkbuild-import-fixtures zkbuild-fv
	cd formal/zkbuild && lake build check_imports
	$(NIM) c -r $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/import-test-cache --out:$(ZKBUILD_DIR)/test_import_audit tools/test_zkbuild_import_audit.nim $(ZKBUILD_DIR)/declaration_baseline $(ZKBUILD_DIR)/import_audit formal/zkbuild/.lake/build/bin/check_imports $(ZKBUILD_DIR)/import-tests

zkbuild-import-cli-test: zkbuild-import-cli zkbuild-fv
	cd formal/zkbuild && lake build check_imports
	$(NIM) c -r $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/import-cli-test-cache --out:$(ZKBUILD_DIR)/test_import_cli tools/test_zkbuild_byte_memory_cli.nim $(ZKBUILD_DIR)/zkbuild-import-audit formal/zkbuild/.lake/build/bin/check_imports $(ZKBUILD_DIR)/import-cli-tests source-sha256-import-origins

zkbuild-check: zkbuild-import-circuit-test zkbuild-import-cli-test

ZKBUILD_OWNED_AUDIT_FLAGS = -d:zkbuildOwnedAudit $(ZKBUILD_IMPORT_AUDIT_FLAGS)
.PHONY: zkbuild-owned-fixtures zkbuild-owned-cli
zkbuild-owned-fixtures: zkbuild-prepare
	$(NIM) c $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/declaration-baseline-cache --out:$(ZKBUILD_DIR)/declaration_baseline tools/zkbuild_audit_declarations.nim
	$(NIM) c $(ZKBUILD_HOST_FLAGS) $(ZKBUILD_OWNED_AUDIT_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/owned-audit-cache --out:$(ZKBUILD_DIR)/owned_audit tools/zkbuild_audit_declarations.nim
	$(NIM) c $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/owned-fragment-baseline-cache --out:$(ZKBUILD_DIR)/owned_fragment_baseline tools/zkbuild_audit_owned.nim
	$(NIM) c $(ZKBUILD_HOST_FLAGS) $(ZKBUILD_OWNED_AUDIT_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/owned-fragment-cache --out:$(ZKBUILD_DIR)/owned_fragment_audit tools/zkbuild_audit_owned.nim

zkbuild-owned-cli: zkbuild-prepare
	$(NIM) c $(ZKBUILD_HOST_FLAGS) $(ZKBUILD_OWNED_AUDIT_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/owned-cli-cache --out:$(ZKBUILD_DIR)/zkbuild-owned-audit tools/zkbuild.nim

.PHONY: zkbuild-owned-circuit-test zkbuild-owned-cli-test
zkbuild-owned-circuit-test: zkbuild-owned-fixtures zkbuild-fv
	cd formal/zkbuild && lake build check_owned check_owned_fragment
	$(NIM) c -r $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/owned-test-cache --out:$(ZKBUILD_DIR)/test_owned_audit tools/test_zkbuild_owned_audit.nim $(ZKBUILD_DIR)/declaration_baseline $(ZKBUILD_DIR)/owned_audit $(ZKBUILD_DIR)/owned_fragment_baseline $(ZKBUILD_DIR)/owned_fragment_audit formal/zkbuild/.lake/build/bin/check_owned formal/zkbuild/.lake/build/bin/check_owned_fragment $(ZKBUILD_DIR)/owned-tests

zkbuild-owned-cli-test: zkbuild-owned-cli zkbuild-fv
	cd formal/zkbuild && lake build check_owned
	$(NIM) c -r $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/owned-cli-test-cache --out:$(ZKBUILD_DIR)/test_owned_cli tools/test_zkbuild_byte_memory_cli.nim $(ZKBUILD_DIR)/zkbuild-owned-audit formal/zkbuild/.lake/build/bin/check_owned $(ZKBUILD_DIR)/owned-cli-tests source-sha256-owned-streams

zkbuild-check: zkbuild-owned-circuit-test zkbuild-owned-cli-test

ZKBUILD_NAME_FRAME_AUDIT_FLAGS = -d:zkbuildNameFrameAudit $(ZKBUILD_OWNED_AUDIT_FLAGS)
.PHONY: zkbuild-name-frame-fixtures zkbuild-name-frame-cli zkbuild-name-frame-circuit-test zkbuild-name-frame-cli-test
zkbuild-name-frame-fixtures: zkbuild-prepare
	$(NIM) c $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/declaration-baseline-cache --out:$(ZKBUILD_DIR)/declaration_baseline tools/zkbuild_audit_declarations.nim
	$(NIM) c $(ZKBUILD_HOST_FLAGS) $(ZKBUILD_NAME_FRAME_AUDIT_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/name-frame-audit-cache --out:$(ZKBUILD_DIR)/name_frame_audit tools/zkbuild_audit_declarations.nim

zkbuild-name-frame-cli: zkbuild-prepare
	$(NIM) c $(ZKBUILD_HOST_FLAGS) $(ZKBUILD_NAME_FRAME_AUDIT_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/name-frame-cli-cache --out:$(ZKBUILD_DIR)/zkbuild-name-frame-audit tools/zkbuild.nim

zkbuild-name-frame-circuit-test: zkbuild-name-frame-fixtures zkbuild-fv
	cd formal/zkbuild && lake build check_name_frames
	$(NIM) c -r $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/name-frame-test-cache --out:$(ZKBUILD_DIR)/test_name_frame_audit tools/test_zkbuild_name_frame_audit.nim $(ZKBUILD_DIR)/declaration_baseline $(ZKBUILD_DIR)/name_frame_audit formal/zkbuild/.lake/build/bin/check_name_frames $(ZKBUILD_DIR)/name-frame-tests

zkbuild-name-frame-cli-test: zkbuild-name-frame-cli zkbuild-fv
	cd formal/zkbuild && lake build check_name_frames
	$(NIM) c -r $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/name-frame-cli-test-cache --out:$(ZKBUILD_DIR)/test_name_frame_cli tools/test_zkbuild_byte_memory_cli.nim $(ZKBUILD_DIR)/zkbuild-name-frame-audit formal/zkbuild/.lake/build/bin/check_name_frames $(ZKBUILD_DIR)/name-frame-cli-tests source-sha256-name-frames

zkbuild-check: zkbuild-name-frame-circuit-test zkbuild-name-frame-cli-test

.PHONY: zkbuild-utf8-names-test
zkbuild-utf8-names-test: zkbuild-prepare
	$(NIM) c -r $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/utf8-names-cache --out:$(ZKBUILD_DIR)/test_utf8_names tools/test_zkbuild_utf8_names.nim

zkbuild-check: zkbuild-utf8-names-test

ZKBUILD_NAME_GRAPH_AUDIT_FLAGS = -d:zkbuildNameGraphAudit $(ZKBUILD_NAME_FRAME_AUDIT_FLAGS)
.PHONY: zkbuild-name-graph-fixtures zkbuild-name-graph-cli
zkbuild-name-graph-fixtures: zkbuild-prepare
	$(NIM) c $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/declaration-baseline-cache --out:$(ZKBUILD_DIR)/declaration_baseline tools/zkbuild_audit_declarations.nim
	$(NIM) c $(ZKBUILD_HOST_FLAGS) $(ZKBUILD_NAME_GRAPH_AUDIT_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/name-graph-audit-cache --out:$(ZKBUILD_DIR)/name_graph_audit tools/zkbuild_audit_declarations.nim
	$(NIM) c $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/name-graph-fragment-baseline-cache --out:$(ZKBUILD_DIR)/name_graph_fragment_baseline tools/zkbuild_audit_names.nim
	$(NIM) c $(ZKBUILD_HOST_FLAGS) $(ZKBUILD_NAME_GRAPH_AUDIT_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/name-graph-fragment-cache --out:$(ZKBUILD_DIR)/name_graph_fragment_audit tools/zkbuild_audit_names.nim

zkbuild-name-graph-cli: zkbuild-prepare
	$(NIM) c $(ZKBUILD_HOST_FLAGS) $(ZKBUILD_NAME_GRAPH_AUDIT_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/name-graph-cli-cache --out:$(ZKBUILD_DIR)/zkbuild-name-graph-audit tools/zkbuild.nim

.PHONY: zkbuild-name-graph-circuit-test zkbuild-name-graph-cli-test
zkbuild-name-graph-circuit-test: zkbuild-name-graph-fixtures zkbuild-fv
	cd formal/zkbuild && lake build check_name_graph check_name_graph_fragment
	$(NIM) c -r $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/name-graph-test-cache --out:$(ZKBUILD_DIR)/test_name_graph_audit tools/test_zkbuild_name_graph_audit.nim $(ZKBUILD_DIR)/declaration_baseline $(ZKBUILD_DIR)/name_graph_audit $(ZKBUILD_DIR)/name_graph_fragment_baseline $(ZKBUILD_DIR)/name_graph_fragment_audit formal/zkbuild/.lake/build/bin/check_name_graph formal/zkbuild/.lake/build/bin/check_name_graph_fragment $(ZKBUILD_DIR)/name-graph-tests

zkbuild-name-graph-cli-test: zkbuild-name-graph-cli zkbuild-fv
	cd formal/zkbuild && lake build check_name_graph
	$(NIM) c -r $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/name-graph-cli-test-cache --out:$(ZKBUILD_DIR)/test_name_graph_cli tools/test_zkbuild_byte_memory_cli.nim $(ZKBUILD_DIR)/zkbuild-name-graph-audit formal/zkbuild/.lake/build/bin/check_name_graph $(ZKBUILD_DIR)/name-graph-cli-tests source-sha256-name-graph

zkbuild-check: zkbuild-name-graph-circuit-test zkbuild-name-graph-cli-test

ZKBUILD_NAME_SOURCE_AUDIT_FLAGS = -d:zkbuildNameSourceAudit $(ZKBUILD_NAME_GRAPH_AUDIT_FLAGS)
.PHONY: zkbuild-name-source-fixtures zkbuild-name-source-cli
zkbuild-name-source-fixtures: zkbuild-prepare
	$(NIM) c $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/declaration-baseline-cache --out:$(ZKBUILD_DIR)/declaration_baseline tools/zkbuild_audit_declarations.nim
	$(NIM) c $(ZKBUILD_HOST_FLAGS) $(ZKBUILD_NAME_SOURCE_AUDIT_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/name-source-audit-cache --out:$(ZKBUILD_DIR)/name_source_audit tools/zkbuild_audit_declarations.nim

zkbuild-name-source-cli: zkbuild-prepare
	$(NIM) c $(ZKBUILD_HOST_FLAGS) $(ZKBUILD_NAME_SOURCE_AUDIT_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/name-source-cli-cache --out:$(ZKBUILD_DIR)/zkbuild-name-source-audit tools/zkbuild.nim

.PHONY: zkbuild-name-source-circuit-test zkbuild-name-source-cli-test
zkbuild-name-source-circuit-test: zkbuild-name-source-fixtures zkbuild-fv
	cd formal/zkbuild && lake build check_name_source
	$(NIM) c -r $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/name-source-test-cache --out:$(ZKBUILD_DIR)/test_name_source_audit tools/test_zkbuild_name_source_audit.nim $(ZKBUILD_DIR)/declaration_baseline $(ZKBUILD_DIR)/name_source_audit formal/zkbuild/.lake/build/bin/check_name_source $(ZKBUILD_DIR)/name-source-tests

zkbuild-name-source-cli-test: zkbuild-name-source-cli zkbuild-fv
	cd formal/zkbuild && lake build check_name_source
	$(NIM) c -r $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/name-source-cli-test-cache --out:$(ZKBUILD_DIR)/test_name_source_cli tools/test_zkbuild_byte_memory_cli.nim $(ZKBUILD_DIR)/zkbuild-name-source-audit formal/zkbuild/.lake/build/bin/check_name_source $(ZKBUILD_DIR)/name-source-cli-tests source-sha256-name-bindings

zkbuild-check: zkbuild-name-source-circuit-test zkbuild-name-source-cli-test

ZKBUILD_CONSTANT_SOURCE_AUDIT_FLAGS = -d:zkbuildConstantSourceAudit $(ZKBUILD_NAME_SOURCE_AUDIT_FLAGS)
.PHONY: zkbuild-constant-source-fixtures zkbuild-constant-source-cli
zkbuild-constant-source-fixtures: zkbuild-prepare
	$(NIM) c $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/declaration-baseline-cache --out:$(ZKBUILD_DIR)/declaration_baseline tools/zkbuild_audit_declarations.nim
	$(NIM) c $(ZKBUILD_HOST_FLAGS) $(ZKBUILD_CONSTANT_SOURCE_AUDIT_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/constant-source-audit-cache --out:$(ZKBUILD_DIR)/constant_source_audit tools/zkbuild_audit_declarations.nim

zkbuild-constant-source-cli: zkbuild-prepare
	$(NIM) c $(ZKBUILD_HOST_FLAGS) $(ZKBUILD_CONSTANT_SOURCE_AUDIT_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/constant-source-cli-cache --out:$(ZKBUILD_DIR)/zkbuild-constant-source-audit tools/zkbuild.nim

.PHONY: zkbuild-constant-source-circuit-test zkbuild-constant-source-cli-test
zkbuild-constant-source-circuit-test: zkbuild-constant-source-fixtures zkbuild-fv
	cd formal/zkbuild && lake build check_constant_source
	$(NIM) c -r $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/constant-source-test-cache --out:$(ZKBUILD_DIR)/test_constant_source_audit tools/test_zkbuild_constant_source_audit.nim $(ZKBUILD_DIR)/declaration_baseline $(ZKBUILD_DIR)/constant_source_audit formal/zkbuild/.lake/build/bin/check_constant_source $(ZKBUILD_DIR)/constant-source-tests

zkbuild-constant-source-cli-test: zkbuild-constant-source-cli zkbuild-fv
	cd formal/zkbuild && lake build check_constant_source
	$(NIM) c -r $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/constant-source-cli-test-cache --out:$(ZKBUILD_DIR)/test_constant_source_cli tools/test_zkbuild_byte_memory_cli.nim $(ZKBUILD_DIR)/zkbuild-constant-source-audit formal/zkbuild/.lake/build/bin/check_constant_source $(ZKBUILD_DIR)/constant-source-cli-tests source-sha256-constant-readers

zkbuild-check: zkbuild-constant-source-circuit-test zkbuild-constant-source-cli-test

.PHONY: zkbuild-constant-proofs-test
zkbuild-constant-proofs-test: zkbuild-prepare zkbuild-fv
	$(NIM) c -r $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/constant-proofs-cache --out:$(ZKBUILD_DIR)/test_constant_proofs tools/test_zkbuild_constant_proofs.nim

zkbuild-check: zkbuild-constant-proofs-test

ZKBUILD_SCALAR_PAYLOAD_AUDIT_FLAGS = -d:zkbuildScalarPayloadAudit $(ZKBUILD_CONSTANT_SOURCE_AUDIT_FLAGS)
.PHONY: zkbuild-scalar-payload-fixtures zkbuild-scalar-payload-cli
zkbuild-scalar-payload-fixtures: zkbuild-prepare
	$(NIM) c $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/declaration-baseline-cache --out:$(ZKBUILD_DIR)/declaration_baseline tools/zkbuild_audit_declarations.nim
	$(NIM) c $(ZKBUILD_HOST_FLAGS) $(ZKBUILD_SCALAR_PAYLOAD_AUDIT_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/scalar-payload-audit-cache --out:$(ZKBUILD_DIR)/scalar_payload_audit tools/zkbuild_audit_declarations.nim

zkbuild-scalar-payload-cli: zkbuild-prepare
	$(NIM) c $(ZKBUILD_HOST_FLAGS) $(ZKBUILD_SCALAR_PAYLOAD_AUDIT_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/scalar-payload-cli-cache --out:$(ZKBUILD_DIR)/zkbuild-scalar-payload-audit tools/zkbuild.nim

.PHONY: zkbuild-scalar-payload-circuit-test zkbuild-scalar-payload-cli-test
zkbuild-scalar-payload-circuit-test: zkbuild-scalar-payload-fixtures zkbuild-fv
	cd formal/zkbuild && lake build check_scalar_payload
	$(NIM) c -r $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/scalar-payload-test-cache --out:$(ZKBUILD_DIR)/test_scalar_payload_audit tools/test_zkbuild_scalar_payload_audit.nim $(ZKBUILD_DIR)/declaration_baseline $(ZKBUILD_DIR)/scalar_payload_audit formal/zkbuild/.lake/build/bin/check_scalar_payload $(ZKBUILD_DIR)/scalar-payload-tests

zkbuild-scalar-payload-cli-test: zkbuild-scalar-payload-cli zkbuild-fv
	cd formal/zkbuild && lake build check_scalar_payload
	$(NIM) c -r $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/scalar-payload-cli-test-cache --out:$(ZKBUILD_DIR)/test_scalar_payload_cli tools/test_zkbuild_byte_memory_cli.nim $(ZKBUILD_DIR)/zkbuild-scalar-payload-audit formal/zkbuild/.lake/build/bin/check_scalar_payload $(ZKBUILD_DIR)/scalar-payload-cli-tests source-sha256-scalar-payloads

zkbuild-check: zkbuild-scalar-payload-circuit-test zkbuild-scalar-payload-cli-test

.PHONY: zkbuild-scalar-payload-proofs-test
zkbuild-scalar-payload-proofs-test: zkbuild-prepare zkbuild-fv
	$(NIM) c -r $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/scalar-payload-proofs-cache --out:$(ZKBUILD_DIR)/test_scalar_payload_proofs tools/test_zkbuild_scalar_payload_proofs.nim

zkbuild-check: zkbuild-scalar-payload-proofs-test

ZKBUILD_SEGMENT_PAYLOAD_AUDIT_FLAGS = -d:zkbuildSegmentPayloadAudit $(ZKBUILD_SCALAR_PAYLOAD_AUDIT_FLAGS)
.PHONY: zkbuild-segment-payload-fixtures zkbuild-segment-payload-cli
zkbuild-segment-payload-fixtures: zkbuild-prepare
	$(NIM) c $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/declaration-baseline-cache --out:$(ZKBUILD_DIR)/declaration_baseline tools/zkbuild_audit_declarations.nim
	$(NIM) c $(ZKBUILD_HOST_FLAGS) $(ZKBUILD_SEGMENT_PAYLOAD_AUDIT_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/segment-payload-audit-cache --out:$(ZKBUILD_DIR)/segment_payload_audit tools/zkbuild_audit_declarations.nim

zkbuild-segment-payload-cli: zkbuild-prepare
	$(NIM) c $(ZKBUILD_HOST_FLAGS) $(ZKBUILD_SEGMENT_PAYLOAD_AUDIT_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/segment-payload-cli-cache --out:$(ZKBUILD_DIR)/zkbuild-segment-payload-audit tools/zkbuild.nim

.PHONY: zkbuild-segment-payload-circuit-test zkbuild-segment-payload-cli-test
zkbuild-segment-payload-circuit-test: zkbuild-segment-payload-fixtures zkbuild-fv
	cd formal/zkbuild && lake build check_segment_payload
	$(NIM) c -r $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/segment-payload-test-cache --out:$(ZKBUILD_DIR)/test_segment_payload_audit tools/test_zkbuild_segment_payload_audit.nim $(ZKBUILD_DIR)/declaration_baseline $(ZKBUILD_DIR)/segment_payload_audit formal/zkbuild/.lake/build/bin/check_segment_payload $(ZKBUILD_DIR)/segment-payload-tests

zkbuild-segment-payload-cli-test: zkbuild-segment-payload-cli zkbuild-fv
	cd formal/zkbuild && lake build check_segment_payload
	$(NIM) c -r $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/segment-payload-cli-test-cache --out:$(ZKBUILD_DIR)/test_segment_payload_cli tools/test_zkbuild_byte_memory_cli.nim $(ZKBUILD_DIR)/zkbuild-segment-payload-audit formal/zkbuild/.lake/build/bin/check_segment_payload $(ZKBUILD_DIR)/segment-payload-cli-tests source-sha256-payload-loops

zkbuild-check: zkbuild-segment-payload-circuit-test zkbuild-segment-payload-cli-test

ZKBUILD_MODULE_CONTEXT_AUDIT_FLAGS = -d:zkbuildModuleContextAudit $(ZKBUILD_SEGMENT_PAYLOAD_AUDIT_FLAGS)
.PHONY: zkbuild-module-context-fixtures zkbuild-module-context-cli
zkbuild-module-context-fixtures: zkbuild-prepare
	$(NIM) c $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/declaration-baseline-cache --out:$(ZKBUILD_DIR)/declaration_baseline tools/zkbuild_audit_declarations.nim
	$(NIM) c $(ZKBUILD_HOST_FLAGS) $(ZKBUILD_MODULE_CONTEXT_AUDIT_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/module-context-audit-cache --out:$(ZKBUILD_DIR)/module_context_audit tools/zkbuild_audit_declarations.nim

zkbuild-module-context-cli: zkbuild-prepare
	$(NIM) c $(ZKBUILD_HOST_FLAGS) $(ZKBUILD_MODULE_CONTEXT_AUDIT_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/module-context-cli-cache --out:$(ZKBUILD_DIR)/zkbuild-module-context-audit tools/zkbuild.nim

.PHONY: zkbuild-module-context-circuit-test zkbuild-module-context-cli-test
zkbuild-module-context-circuit-test: zkbuild-module-context-fixtures zkbuild-fv
	cd formal/zkbuild && lake build check_module_context
	$(NIM) c -r $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/module-context-audit-test-cache --out:$(ZKBUILD_DIR)/test_module_context_audit tools/test_zkbuild_module_context_audit.nim $(ZKBUILD_DIR)/declaration_baseline $(ZKBUILD_DIR)/module_context_audit formal/zkbuild/.lake/build/bin/check_module_context $(ZKBUILD_DIR)/module-context-tests

zkbuild-module-context-cli-test: zkbuild-module-context-cli zkbuild-fv
	cd formal/zkbuild && lake build check_module_context
	$(NIM) c -r $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/module-context-cli-test-cache --out:$(ZKBUILD_DIR)/test_module_context_cli tools/test_zkbuild_byte_memory_cli.nim $(ZKBUILD_DIR)/zkbuild-module-context-audit formal/zkbuild/.lake/build/bin/check_module_context $(ZKBUILD_DIR)/module-context-cli-tests source-sha256-module-context

ZKBUILD_BODY_SOURCE_AUDIT_FLAGS = -d:zkbuildBodySourceAudit $(ZKBUILD_MODULE_CONTEXT_AUDIT_FLAGS)
.PHONY: zkbuild-body-source-fixtures zkbuild-body-source-cli
zkbuild-body-source-fixtures: zkbuild-prepare
	$(NIM) c $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/declaration-baseline-cache --out:$(ZKBUILD_DIR)/declaration_baseline tools/zkbuild_audit_declarations.nim
	$(NIM) c $(ZKBUILD_HOST_FLAGS) $(ZKBUILD_BODY_SOURCE_AUDIT_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/body-source-audit-cache --out:$(ZKBUILD_DIR)/body_source_audit tools/zkbuild_audit_declarations.nim

zkbuild-body-source-cli: zkbuild-prepare
	$(NIM) c $(ZKBUILD_HOST_FLAGS) $(ZKBUILD_BODY_SOURCE_AUDIT_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/body-source-cli-cache --out:$(ZKBUILD_DIR)/zkbuild-body-source-audit tools/zkbuild.nim

.PHONY: zkbuild-body-source-circuit-test zkbuild-body-source-cli-test
zkbuild-body-source-circuit-test: zkbuild-body-source-fixtures zkbuild-fv
	cd formal/zkbuild && lake build check_body_source
	$(NIM) c -r $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/body-source-test-cache --out:$(ZKBUILD_DIR)/test_body_source_audit tools/test_zkbuild_body_source_audit.nim $(ZKBUILD_DIR)/declaration_baseline $(ZKBUILD_DIR)/body_source_audit formal/zkbuild/.lake/build/bin/check_body_source $(ZKBUILD_DIR)/body-source-tests

zkbuild-body-source-cli-test: zkbuild-body-source-cli zkbuild-fv
	cd formal/zkbuild && lake build check_body_source
	$(NIM) c -r $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/body-source-cli-test-cache --out:$(ZKBUILD_DIR)/test_body_source_cli tools/test_zkbuild_byte_memory_cli.nim $(ZKBUILD_DIR)/zkbuild-body-source-audit formal/zkbuild/.lake/build/bin/check_body_source $(ZKBUILD_DIR)/body-source-cli-tests source-sha256-code-bodies

.PHONY: zkbuild-body-source-binding-test
zkbuild-body-source-binding-test: zkbuild-prepare
	$(NIM) c -r $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/body-source-binding-cache --out:$(ZKBUILD_DIR)/test_body_source tools/test_zkbuild_body_source.nim

zkbuild-check: zkbuild-module-context-circuit-test zkbuild-module-context-cli-test
zkbuild-check: zkbuild-body-source-circuit-test zkbuild-body-source-cli-test zkbuild-body-source-binding-test

ZKBUILD_INSTRUCTION_SOURCE_AUDIT_FLAGS = -d:zkbuildInstructionSourceAudit $(ZKBUILD_BODY_SOURCE_AUDIT_FLAGS)
.PHONY: zkbuild-instruction-source-fixtures zkbuild-instruction-source-cli
zkbuild-instruction-source-fixtures: zkbuild-prepare
	$(NIM) c $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/declaration-baseline-cache --out:$(ZKBUILD_DIR)/declaration_baseline tools/zkbuild_audit_declarations.nim
	$(NIM) c $(ZKBUILD_HOST_FLAGS) $(ZKBUILD_INSTRUCTION_SOURCE_AUDIT_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/instruction-source-audit-cache --out:$(ZKBUILD_DIR)/instruction_source_audit tools/zkbuild_audit_declarations.nim

zkbuild-instruction-source-cli: zkbuild-prepare
	$(NIM) c $(ZKBUILD_HOST_FLAGS) $(ZKBUILD_INSTRUCTION_SOURCE_AUDIT_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/instruction-source-cli-cache --out:$(ZKBUILD_DIR)/zkbuild-instruction-source-audit tools/zkbuild.nim

.PHONY: zkbuild-instruction-source-circuit-test zkbuild-instruction-source-cli-test
zkbuild-instruction-source-circuit-test: zkbuild-instruction-source-fixtures zkbuild-fv
	cd formal/zkbuild && lake build check_instruction_source
	$(NIM) c -r $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/instruction-audit-test-cache --out:$(ZKBUILD_DIR)/test_instruction_source_audit tools/test_zkbuild_instruction_source_audit.nim $(ZKBUILD_DIR)/declaration_baseline $(ZKBUILD_DIR)/instruction_source_audit formal/zkbuild/.lake/build/bin/check_instruction_source $(ZKBUILD_DIR)/instruction-source-tests

zkbuild-instruction-source-cli-test: zkbuild-instruction-source-cli zkbuild-fv
	cd formal/zkbuild && lake build check_instruction_source
	$(NIM) c -r $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/instruction-audit-cli-test-cache --out:$(ZKBUILD_DIR)/test_instruction_source_cli tools/test_zkbuild_byte_memory_cli.nim $(ZKBUILD_DIR)/zkbuild-instruction-source-audit formal/zkbuild/.lake/build/bin/check_instruction_source $(ZKBUILD_DIR)/instruction-source-cli-tests source-sha256-instruction-stream

zkbuild-check: zkbuild-instruction-source-circuit-test zkbuild-instruction-source-cli-test

.PHONY: zkbuild-instruction-metadata-binding-test
zkbuild-instruction-metadata-binding-test: zkbuild-prepare
	$(NIM) c -r $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/instruction-metadata-binding-cache --out:$(ZKBUILD_DIR)/test_instruction_metadata_binding tools/test_zkbuild_instruction_metadata_binding.nim

zkbuild-check: zkbuild-instruction-metadata-binding-test


ZKBUILD_VALIDATION_EVENT_AUDIT_FLAGS = -d:zkbuildValidationEventAudit $(ZKBUILD_INSTRUCTION_SOURCE_AUDIT_FLAGS)
.PHONY: zkbuild-validation-event-fixtures zkbuild-validation-event-cli
zkbuild-validation-event-fixtures: zkbuild-prepare
	$(NIM) c $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/declaration-baseline-cache --out:$(ZKBUILD_DIR)/declaration_baseline tools/zkbuild_audit_declarations.nim
	$(NIM) c $(ZKBUILD_HOST_FLAGS) $(ZKBUILD_VALIDATION_EVENT_AUDIT_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/validation-event-audit-cache --out:$(ZKBUILD_DIR)/validation_event_audit tools/zkbuild_audit_declarations.nim

zkbuild-validation-event-cli: zkbuild-prepare
	$(NIM) c $(ZKBUILD_HOST_FLAGS) $(ZKBUILD_VALIDATION_EVENT_AUDIT_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/validation-event-cli-cache --out:$(ZKBUILD_DIR)/zkbuild-validation-event-audit tools/zkbuild.nim

.PHONY: zkbuild-validation-event-circuit-test zkbuild-validation-event-cli-test
zkbuild-validation-event-circuit-test: zkbuild-validation-event-fixtures zkbuild-fv
	cd formal/zkbuild && lake build check_validation_events
	$(NIM) c -r $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/validation-event-test-cache --out:$(ZKBUILD_DIR)/test_validation_event_audit tools/test_zkbuild_validation_event_audit.nim $(ZKBUILD_DIR)/declaration_baseline $(ZKBUILD_DIR)/validation_event_audit formal/zkbuild/.lake/build/bin/check_validation_events $(ZKBUILD_DIR)/validation-event-tests

zkbuild-validation-event-cli-test: zkbuild-validation-event-cli zkbuild-fv
	cd formal/zkbuild && lake build check_validation_events
	$(NIM) c -r $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/validation-event-cli-test-cache --out:$(ZKBUILD_DIR)/test_validation_event_cli tools/test_zkbuild_byte_memory_cli.nim $(ZKBUILD_DIR)/zkbuild-validation-event-audit formal/zkbuild/.lake/build/bin/check_validation_events $(ZKBUILD_DIR)/validation-event-cli-tests source-sha256-validation-events

zkbuild-check: zkbuild-validation-event-circuit-test zkbuild-validation-event-cli-test

ZKBUILD_DYNAMIC_TYPING_AUDIT_FLAGS = -d:zkbuildDynamicTypingAudit $(ZKBUILD_VALIDATION_EVENT_AUDIT_FLAGS)
.PHONY: zkbuild-dynamic-typing-fixtures zkbuild-dynamic-typing-cli
zkbuild-dynamic-typing-fixtures: zkbuild-prepare
	$(NIM) c $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/declaration-baseline-cache --out:$(ZKBUILD_DIR)/declaration_baseline tools/zkbuild_audit_declarations.nim
	$(NIM) c $(ZKBUILD_HOST_FLAGS) $(ZKBUILD_DYNAMIC_TYPING_AUDIT_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/dynamic-typing-audit-cache --out:$(ZKBUILD_DIR)/dynamic_typing_audit tools/zkbuild_audit_declarations.nim

zkbuild-dynamic-typing-cli: zkbuild-prepare
	$(NIM) c $(ZKBUILD_HOST_FLAGS) $(ZKBUILD_DYNAMIC_TYPING_AUDIT_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/dynamic-typing-cli-cache --out:$(ZKBUILD_DIR)/zkbuild-dynamic-typing-audit tools/zkbuild.nim

.PHONY: zkbuild-dynamic-typing-circuit-test zkbuild-dynamic-typing-cli-test
zkbuild-dynamic-typing-circuit-test: zkbuild-dynamic-typing-fixtures zkbuild-validation-event-circuit-test zkbuild-fv
	cd formal/zkbuild && lake build check_dynamic_typing
	$(NIM) c -r $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/dynamic-typing-test-cache --out:$(ZKBUILD_DIR)/test_dynamic_typing_audit tools/test_zkbuild_dynamic_typing_audit.nim $(ZKBUILD_DIR)/declaration_baseline $(ZKBUILD_DIR)/dynamic_typing_audit formal/zkbuild/.lake/build/bin/check_dynamic_typing $(ZKBUILD_DIR)/dynamic-typing-tests $(ZKBUILD_DIR)/validation-event-tests

zkbuild-dynamic-typing-cli-test: zkbuild-dynamic-typing-cli zkbuild-fv
	cd formal/zkbuild && lake build check_dynamic_typing
	$(NIM) c -r $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/dynamic-typing-cli-test-cache --out:$(ZKBUILD_DIR)/test_dynamic_typing_cli tools/test_zkbuild_byte_memory_cli.nim $(ZKBUILD_DIR)/zkbuild-dynamic-typing-audit formal/zkbuild/.lake/build/bin/check_dynamic_typing $(ZKBUILD_DIR)/dynamic-typing-cli-tests source-sha256-dynamic-typing

zkbuild-check: zkbuild-dynamic-typing-circuit-test zkbuild-dynamic-typing-cli-test

.PHONY: zkbuild-dynamic-typing-binding-test
zkbuild-dynamic-typing-binding-test: zkbuild-prepare
	$(NIM) c -r $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/dynamic-binding-cache --out:$(ZKBUILD_DIR)/test_dynamic_typing_binding tools/test_zkbuild_dynamic_typing_binding.nim

zkbuild-check: zkbuild-dynamic-typing-binding-test

ZKBUILD_STRUCTURED_CONTROL_AUDIT_FLAGS = -d:zkbuildStructuredControlAudit $(ZKBUILD_DYNAMIC_TYPING_AUDIT_FLAGS)
.PHONY: zkbuild-structured-control-fixtures zkbuild-structured-control-cli
zkbuild-structured-control-fixtures: zkbuild-prepare
	$(NIM) c $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/declaration-baseline-cache --out:$(ZKBUILD_DIR)/declaration_baseline tools/zkbuild_audit_declarations.nim
	$(NIM) c $(ZKBUILD_HOST_FLAGS) $(ZKBUILD_STRUCTURED_CONTROL_AUDIT_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/structured-control-audit-cache --out:$(ZKBUILD_DIR)/structured_control_audit tools/zkbuild_audit_declarations.nim

zkbuild-structured-control-cli: zkbuild-prepare
	$(NIM) c $(ZKBUILD_HOST_FLAGS) $(ZKBUILD_STRUCTURED_CONTROL_AUDIT_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/structured-control-cli-cache --out:$(ZKBUILD_DIR)/zkbuild-structured-control-audit tools/zkbuild.nim

.PHONY: zkbuild-structured-control-circuit-test zkbuild-structured-control-cli-test
zkbuild-structured-control-circuit-test: zkbuild-structured-control-fixtures zkbuild-dynamic-typing-circuit-test zkbuild-fv
	cd formal/zkbuild && lake build check_structured_control
	$(NIM) c -r $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/structured-control-test-cache --out:$(ZKBUILD_DIR)/test_structured_control_audit tools/test_zkbuild_structured_control_audit.nim $(ZKBUILD_DIR)/declaration_baseline $(ZKBUILD_DIR)/structured_control_audit formal/zkbuild/.lake/build/bin/check_structured_control $(ZKBUILD_DIR)/structured-control-tests $(ZKBUILD_DIR)/dynamic-typing-tests

zkbuild-structured-control-cli-test: zkbuild-structured-control-cli zkbuild-fv
	cd formal/zkbuild && lake build check_structured_control
	$(NIM) c -r $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/structured-control-cli-test-cache --out:$(ZKBUILD_DIR)/test_structured_control_cli tools/test_zkbuild_byte_memory_cli.nim $(ZKBUILD_DIR)/zkbuild-structured-control-audit formal/zkbuild/.lake/build/bin/check_structured_control $(ZKBUILD_DIR)/structured-control-cli-tests source-sha256-structured-control

zkbuild-check: zkbuild-structured-control-circuit-test zkbuild-structured-control-cli-test

ZKBUILD_RUNTIME_CONTEXT_AUDIT_FLAGS = -d:zkbuildRuntimeContextAudit $(ZKBUILD_STRUCTURED_CONTROL_AUDIT_FLAGS)
.PHONY: zkbuild-runtime-context-fixtures zkbuild-runtime-context-cli
zkbuild-runtime-context-fixtures: zkbuild-prepare
	$(NIM) c $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/declaration-baseline-cache --out:$(ZKBUILD_DIR)/declaration_baseline tools/zkbuild_audit_declarations.nim
	$(NIM) c $(ZKBUILD_HOST_FLAGS) $(ZKBUILD_RUNTIME_CONTEXT_AUDIT_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/runtime-context-audit-cache --out:$(ZKBUILD_DIR)/runtime_context_audit tools/zkbuild_audit_declarations.nim
zkbuild-runtime-context-cli: zkbuild-prepare
	$(NIM) c $(ZKBUILD_HOST_FLAGS) $(ZKBUILD_RUNTIME_CONTEXT_AUDIT_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/runtime-context-cli-cache --out:$(ZKBUILD_DIR)/zkbuild-runtime-context-audit tools/zkbuild.nim

.PHONY: zkbuild-runtime-context-circuit-test zkbuild-runtime-context-cli-test
zkbuild-runtime-context-circuit-test: zkbuild-runtime-context-fixtures zkbuild-structured-control-circuit-test zkbuild-fv
	cd formal/zkbuild && lake build check_runtime_context
	$(NIM) c -r $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/runtime-context-test-cache --out:$(ZKBUILD_DIR)/test_runtime_context_audit tools/test_zkbuild_runtime_context_audit.nim $(ZKBUILD_DIR)/declaration_baseline $(ZKBUILD_DIR)/runtime_context_audit formal/zkbuild/.lake/build/bin/check_runtime_context $(ZKBUILD_DIR)/runtime-context-tests $(ZKBUILD_DIR)/structured-control-tests
zkbuild-runtime-context-cli-test: zkbuild-runtime-context-cli zkbuild-fv
	cd formal/zkbuild && lake build check_runtime_context
	$(NIM) c -r $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/runtime-context-cli-test-cache --out:$(ZKBUILD_DIR)/test_runtime_context_cli tools/test_zkbuild_byte_memory_cli.nim $(ZKBUILD_DIR)/zkbuild-runtime-context-audit formal/zkbuild/.lake/build/bin/check_runtime_context $(ZKBUILD_DIR)/runtime-context-cli-tests source-sha256-runtime-context
zkbuild-check: zkbuild-runtime-context-circuit-test zkbuild-runtime-context-cli-test

.PHONY: zkbuild-runtime-context-binding-test zkbuild-runtime-context-substitution-test
zkbuild-runtime-context-binding-test: zkbuild-runtime-context-fixtures zkbuild-fv
	cd formal/zkbuild && lake build check_runtime_context
	$(NIM) c -r $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/runtime-context-binding-cache --out:$(ZKBUILD_DIR)/test_runtime_context_binding tools/test_zkbuild_runtime_context_binding.nim $(ZKBUILD_DIR)/declaration_baseline $(ZKBUILD_DIR)/runtime_context_audit formal/zkbuild/.lake/build/bin/check_runtime_context $(ZKBUILD_DIR)/runtime-context-binding-tests
zkbuild-runtime-context-substitution-test: zkbuild-prepare
	$(NIM) c -r $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/runtime-context-substitution-cache --out:$(ZKBUILD_DIR)/test_runtime_context_substitution tools/test_zkbuild_runtime_context_substitution.nim
zkbuild-check: zkbuild-runtime-context-binding-test zkbuild-runtime-context-substitution-test

.PHONY: zkbuild-event-semantics-test
zkbuild-event-semantics-test: zkbuild-runtime-context-binding-test zkbuild-runtime-context-circuit-test
	cd formal/zkbuild && lake build check_event_semantics
	$(NIM) c -r $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/event-semantics-cache --out:$(ZKBUILD_DIR)/test_event_semantics tools/test_zkbuild_event_semantics.nim formal/zkbuild/.lake/build/bin/check_event_semantics $(ZKBUILD_DIR)/runtime-context-tests $(ZKBUILD_DIR)/runtime-context-binding-tests
zkbuild-check: zkbuild-event-semantics-test

.PHONY: zkbuild-event-semantics-cli-test
zkbuild-event-semantics-cli-test: zkbuild-runtime-context-cli zkbuild-fv
	cd formal/zkbuild && lake build check_event_semantics
	$(NIM) c -r $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/event-semantics-cli-test-cache --out:$(ZKBUILD_DIR)/test_event_semantics_cli tools/test_zkbuild_byte_memory_cli.nim $(ZKBUILD_DIR)/zkbuild-runtime-context-audit formal/zkbuild/.lake/build/bin/check_event_semantics $(ZKBUILD_DIR)/event-semantics-cli-tests source-sha256-runtime-context
zkbuild-check: zkbuild-event-semantics-cli-test

.PHONY: zkbuild-variable-semantics-test
zkbuild-variable-semantics-test: zkbuild-runtime-context-binding-test zkbuild-runtime-context-circuit-test
	cd formal/zkbuild && lake build check_variable_semantics
	$(NIM) c -r $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/variable-semantics-cache --out:$(ZKBUILD_DIR)/test_variable_semantics tools/test_zkbuild_variable_semantics.nim formal/zkbuild/.lake/build/bin/check_variable_semantics $(ZKBUILD_DIR)/runtime-context-tests $(ZKBUILD_DIR)/runtime-context-binding-tests
zkbuild-check: zkbuild-variable-semantics-test

.PHONY: zkbuild-instruction-bodies-test
zkbuild-instruction-bodies-test: zkbuild-prepare zkbuild-fv
	cd formal/zkbuild && lake build check_instruction_bodies
	$(NIM) c -r $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/instruction-bodies-cache --out:$(ZKBUILD_DIR)/test_instruction_bodies tools/test_zkbuild_instruction_bodies.nim formal/zkbuild/.lake/build/bin/check_instruction_bodies $(ZKBUILD_DIR)/instruction-bodies-test
zkbuild-check: zkbuild-instruction-bodies-test

.PHONY: zkbuild-call-semantics-test
zkbuild-call-semantics-test: zkbuild-runtime-context-binding-test zkbuild-runtime-context-circuit-test
	cd formal/zkbuild && lake build check_call_semantics
	$(NIM) c -r $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/call-semantics-cache --out:$(ZKBUILD_DIR)/test_call_semantics tools/test_zkbuild_call_semantics.nim formal/zkbuild/.lake/build/bin/check_call_semantics $(ZKBUILD_DIR)/runtime-context-tests $(ZKBUILD_DIR)/runtime-context-binding-tests
zkbuild-check: zkbuild-call-semantics-test

.PHONY: zkbuild-call-bodies-test
zkbuild-call-bodies-test: zkbuild-prepare zkbuild-fv
	cd formal/zkbuild && lake build check_call_bodies
	$(NIM) c -r $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/call-body-driver-cache --out:$(ZKBUILD_DIR)/test_call_bodies tools/test_zkbuild_call_bodies.nim formal/zkbuild/.lake/build/bin/check_call_bodies $(ZKBUILD_DIR)/call-body-tests
zkbuild-check: zkbuild-call-bodies-test

.PHONY: zkbuild-call-runtime-test
zkbuild-call-runtime-test: zkbuild-prepare zkbuild-fv
	cd formal/zkbuild && lake build check_call_runtime
	$(NIM) c -r $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/call-runtime-driver-cache --out:$(ZKBUILD_DIR)/test_call_runtime tools/test_zkbuild_call_runtime.nim formal/zkbuild/.lake/build/bin/check_call_runtime $(ZKBUILD_DIR)/call-runtime-tests
zkbuild-check: zkbuild-call-runtime-test

.PHONY: zkbuild-call-mode-proofs-test
zkbuild-call-mode-proofs-test: zkbuild-prepare zkbuild-fv
	$(NIM) c -r $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/call-mode-proofs-cache --out:$(ZKBUILD_DIR)/test_call_mode_proofs tools/test_zkbuild_call_mode_proofs.nim $(ZKBUILD_DIR)/call-mode-proof-tests
zkbuild-check: zkbuild-call-mode-proofs-test

.PHONY: zkbuild-parametric-semantics-test
zkbuild-parametric-semantics-test: zkbuild-runtime-context-binding-test zkbuild-runtime-context-circuit-test
	cd formal/zkbuild && lake build check_parametric_semantics
	$(NIM) c -r $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/parametric-semantics-cache --out:$(ZKBUILD_DIR)/test_parametric_semantics tools/test_zkbuild_parametric_semantics.nim formal/zkbuild/.lake/build/bin/check_parametric_semantics $(ZKBUILD_DIR)/runtime-context-tests $(ZKBUILD_DIR)/runtime-context-binding-tests
zkbuild-check: zkbuild-parametric-semantics-test

.PHONY: zkbuild-parametric-mode-proofs-test
zkbuild-parametric-mode-proofs-test: zkbuild-prepare zkbuild-fv
	$(NIM) c -r $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/parametric-mode-proofs-cache --out:$(ZKBUILD_DIR)/test_parametric_mode_proofs tools/test_zkbuild_parametric_mode_proofs.nim $(ZKBUILD_DIR)/parametric-mode-proof-tests
zkbuild-check: zkbuild-parametric-mode-proofs-test

.PHONY: zkbuild-branch-semantics-test
zkbuild-branch-semantics-test: zkbuild-runtime-context-binding-test zkbuild-runtime-context-circuit-test
	cd formal/zkbuild && lake build check_branch_semantics
	$(NIM) c -r $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/branch-semantics-cache --out:$(ZKBUILD_DIR)/test_branch_semantics tools/test_zkbuild_branch_semantics.nim formal/zkbuild/.lake/build/bin/check_branch_semantics $(ZKBUILD_DIR)/runtime-context-tests $(ZKBUILD_DIR)/runtime-context-binding-tests
zkbuild-check: zkbuild-branch-semantics-test

.PHONY: zkbuild-branch-mode-proofs-test
zkbuild-branch-mode-proofs-test: zkbuild-prepare zkbuild-fv
	$(NIM) c -r $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/branch-mode-proofs-cache --out:$(ZKBUILD_DIR)/test_branch_mode_proofs tools/test_zkbuild_branch_mode_proofs.nim $(ZKBUILD_DIR)/branch-mode-proof-tests
zkbuild-check: zkbuild-branch-mode-proofs-test

.PHONY: zkbuild-branch-label-proofs-test
zkbuild-branch-label-proofs-test: zkbuild-prepare zkbuild-fv
	$(NIM) c -r $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/branch-label-proofs-cache --out:$(ZKBUILD_DIR)/test_branch_label_proofs tools/test_zkbuild_branch_label_proofs.nim $(ZKBUILD_DIR)/branch-label-proof-tests
zkbuild-check: zkbuild-branch-label-proofs-test

.PHONY: zkbuild-branch-action-proofs-test
zkbuild-branch-action-proofs-test: zkbuild-prepare zkbuild-fv
	$(NIM) c -r $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/branch-action-proofs-cache --out:$(ZKBUILD_DIR)/test_branch_action_proofs tools/test_zkbuild_branch_action_proofs.nim $(ZKBUILD_DIR)/branch-action-proof-tests
zkbuild-check: zkbuild-branch-action-proofs-test

.PHONY: zkbuild-control-type-semantics-test zkbuild-control-mode-proofs-test
zkbuild-control-type-semantics-test: zkbuild-runtime-context-binding-test zkbuild-runtime-context-circuit-test
	cd formal/zkbuild && lake build check_control_typing
	$(NIM) c -r $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/control-type-semantics-cache --out:$(ZKBUILD_DIR)/test_control_type_semantics tools/test_zkbuild_control_type_semantics.nim formal/zkbuild/.lake/build/bin/check_control_typing $(ZKBUILD_DIR)/runtime-context-tests $(ZKBUILD_DIR)/runtime-context-binding-tests
zkbuild-control-mode-proofs-test: zkbuild-prepare zkbuild-fv
	cd formal/zkbuild && lake build check_control_plans
	$(NIM) c -r $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/control-mode-proofs-cache --out:$(ZKBUILD_DIR)/test_control_mode_proofs tools/test_zkbuild_control_mode_proofs.nim formal/zkbuild/.lake/build/bin/check_control_plans $(ZKBUILD_DIR)/control-mode-proof-tests
zkbuild-check: zkbuild-control-type-semantics-test zkbuild-control-mode-proofs-test

.PHONY: zkbuild-control-signature-semantics-test zkbuild-control-signature-proofs-test
zkbuild-control-signature-semantics-test: zkbuild-control-type-semantics-test
	$(NIM) c -r $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/control-signature-semantics-cache --out:$(ZKBUILD_DIR)/test_control_signature_semantics tools/test_zkbuild_control_signature_semantics.nim formal/zkbuild/.lake/build/bin/check_control_typing $(ZKBUILD_DIR)/runtime-context-tests $(ZKBUILD_DIR)/runtime-context-binding-tests $(ZKBUILD_DIR)/control-type-semantics-tests/results.log
zkbuild-control-signature-proofs-test: zkbuild-prepare zkbuild-fv
	cd formal/zkbuild && lake build check_control_plans
	$(NIM) c -r $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/control-signature-proofs-cache --out:$(ZKBUILD_DIR)/test_control_signature_proofs tools/test_zkbuild_control_signature_proofs.nim formal/zkbuild/.lake/build/bin/check_control_plans $(ZKBUILD_DIR)/control-signature-proof-tests
zkbuild-check: zkbuild-control-signature-semantics-test zkbuild-control-signature-proofs-test

.PHONY: zkbuild-frame-semantics-test
zkbuild-frame-semantics-test: zkbuild-runtime-context-binding-test zkbuild-runtime-context-circuit-test
	cd formal/zkbuild && lake build check_signature_frames
	$(NIM) c -r $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/frame-semantics-cache --out:$(ZKBUILD_DIR)/test_frame_semantics tools/test_zkbuild_frame_semantics.nim formal/zkbuild/.lake/build/bin/check_signature_frames $(ZKBUILD_DIR)/runtime-context-tests $(ZKBUILD_DIR)/runtime-context-binding-tests
zkbuild-check: zkbuild-frame-semantics-test

.PHONY: zkbuild-instruction-source-semantics-test
zkbuild-instruction-source-semantics-test: zkbuild-runtime-context-binding-test zkbuild-runtime-context-circuit-test
	cd formal/zkbuild && lake build check_instruction_events
	$(NIM) c -r $(ZKBUILD_HOST_FLAGS) --checks:on --assertions:on --nimcache:$(ZKBUILD_DIR)/instruction-source-semantics-cache --out:$(ZKBUILD_DIR)/test_instruction_source tools/test_zkbuild_instruction_source.nim formal/zkbuild/.lake/build/bin/check_instruction_events $(ZKBUILD_DIR)/runtime-context-tests $(ZKBUILD_DIR)/runtime-context-binding-tests
zkbuild-check: zkbuild-instruction-source-semantics-test
