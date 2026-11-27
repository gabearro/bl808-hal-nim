# Getting started

Run the commands in these guides from the repository root. The project builds
the BL808's three cores separately. Board startup, linker scripts, peripherals,
and the CPS kernel live under [src/bl808](../src/bl808/). Firmware examples
live under [examples](../examples/).

## Toolchain

- Nim 2.2.6 is the version pinned in [CI](../.github/workflows/test.yml).
- Use a RISC-V GCC multilib toolchain that provides
  `riscv64-unknown-elf-gcc` and supports RV32 with hardware float, RV64 with
  hardware float, and RV32E. The cross compiler, `objcopy`, and `size` must
  be on your path. [config.nims](../config.nims) selects the ABI and linker
  script for each core.
- Python 3.12 is the host CI baseline. `make venv` creates `.venv` using
  [requirements-hw.txt](../requirements-hw.txt).
- Initialize the pinned submodules for examples that use their filesystems
  or network dependencies. The Wi-Fi application profile also needs the SDK
  input described in [Vendor firmware provenance](bl808_vendor_blobs.md).

```sh
git submodule update --init --recursive
make venv
make help
```

## Compile an example

| Core | Example command | Build output |
| --- | --- | --- |
| M0, E907 | `make m0 FILE=examples/m0_hello_nim_test.nim` | `build/m0_firmware.elf` and `.bin` |
| D0, C906 | `make d0 FILE=examples/d0_profile_workload.nim` | `build/d0_firmware.elf` and `.bin` |
| LP, E902 | `make lp FILE=examples/lp_allcore_test.nim` | `build/lp_firmware.elf` and `.bin` |

The D0 and LP examples are peers for the observer and all-core tests. Use
their manifest entries to build the matching M0 image and run the full
test. The Makefile enables `bl808kernel` by default. Include it when
setting `NIM_FLAGS` explicitly for an enclave example:

```sh
make m0 FILE=examples/m0_enclave_services_test.nim \
  NIM_FLAGS="-d:bl808kernel -d:bl808enclave"
```

Keep the ELF from the exact build you flash. The debugger and profiler use it
to resolve symbols. For a manifest-managed build, use the harness instead.
It applies the defines, core selection, and memory layout for that test.

```sh
.venv/bin/python tools/hw_validate.py --list
.venv/bin/python tools/hw_validate.py --test m0_hello_nim_test --build-only
```

## Choose a validation path

| Check | Command or guide |
| --- | --- |
| Host regression gate | `make test` |
| Broader host pytest suite | `make test-all` |
| Cross-compile coverage | `make examples-check` |
| Interpreter on QEMU CPUs | [Core WebAssembly](wasm_full_baseline.md) |
| Wi-Fi scheduling and protocol models | [Wi-Fi model fuzzer](wifi_model_fuzzer.md) |
| UART, JTAG, peripheral, or radio behavior on silicon | [Hardware validation](hardware_validation_harness.md) |

The CI workflow and Makefile spell out the tests included in the host gate.
Hardware timing, DMA, and radio tests require the real board and the relevant
peripherals.
