# Core WebAssembly

The full interpreter uses the same decoder, validator, and guest execution
model on M0, D0, and LP. The checked-in
[baseline guest](../tools/wasm_full_baseline.wat) exercises i32 and f64
arithmetic and `call_indirect`. The runner compares generated guest bytes
with the embedded fixture, runs the host interpreter, cross-links firmware,
and executes a matching QEMU image for each CPU.

## Run the baseline

Install the [cross toolchain](getting_started.md), `wat2wasm`,
`qemu-system-riscv32`, and `qemu-system-riscv64`.

```sh
python3 tools/run_wasm_full_baseline.py
```

The runner writes to `build/wasm-full-baseline/`. It exercises RV32, RV64,
and RV32E with their matching ABI settings. The LP build uses the vendored
[RV32E compiler runtime](../vendor/compiler_rt_rv32e/) and
[software math](../vendor/musl_math_rv32e/). LP firmware starts with a
16 KiB writable region and a 4 KiB native stack in the full-interpreter
profile. Guest arena sizing depends on the actual module and firmware
layout.

## Focused runs

The options below add targeted cases to the baseline. See
[the runner](../tools/run_wasm_full_baseline.py) and its `--help` output
for the current list.

| Area | Runner options |
| --- | --- |
| D0 execute-in-place build | `--d0-xip` |
| Function-reference subtypes and indirect calls | `--function-references` |
| Shared types, memories, tables, globals, and atomic operations | `--shared-core-types` |
| Cooperative atomic wait and notify | `--atomic-wait` |
| CRC-checked flash/store adapter | `--manager-qemu` |
| Full scheduler on QEMU and firmware cross-link | `--scheduler-qemu --scheduler-firmware` |
| Reserved resident frames and SRAM/PSRAM tiering | `--rt-resident-qemu --psram-frames-qemu` |
| D0/LP paging over the M0 service | `--d0-pager-client-qemu --lp-pager-client-qemu` |
| Repeated invocation counts under emulation | `--bench` |

## Use the results

QEMU checks the guest behavior and target ABI. Its cycle counts and heap
peaks describe the emulator and that fixture. Use the
[hardware manifest](../tools/hardware_validation.json) and
[profiler](profiling.md) for silicon timing and board memory behavior.
Small fixture peaks are useful regressions, but larger modules need their
own admission and memory measurements.

The main entry points are the
[binary decoder](../src/cps/wasm/binary.nim), the
[validator](../src/cps/wasm/validate.nim), and the
[full interpreter](../src/cps/wasm/runtime.nim). The separate guides cover
[components](wasm_component_model.md),
[cross-core jobs and migration](wasm_work_stealing.md), and
[bounded proofs](zkbuild.md).

For earlier per-core sizes, benchmark tables, and probe traces, see the
[baseline reference snapshot](https://github.com/gabearro/bl808-hal-nim/blob/eb932dddbb56ac5131b3d398e5463f18008fc639/docs/wasm_full_baseline.md).
