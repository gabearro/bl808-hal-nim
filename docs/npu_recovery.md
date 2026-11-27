# BL808 NPU and BLAI recovery

The Nim NPU code covers typed registers, bounded instruction and data
planning, and hardware smoke tests. Use the [recovery manifest](../tools/ref/npu_recovery_manifest.json)
for register provenance, known-answer fixtures, and the execution stages or
record kinds still under investigation. Validate each model and output against
a CPU or SDK reference before relying on full graph execution.

## Reproduce a source comparison

The qualified Sipeed M1s SDK checkout is commit `bf7e689`. Keep it under
`build/vendor-cache/` or set `BL808_M1S_SDK` to the corresponding local
checkout. Set `BLAI_NPU_TOOLCHAIN` if you also have the optional converter
distribution. Use a T-Head-aware objdump to recover symbols, relocations,
and register references.

```sh
BL808_M1S_SDK=build/vendor-cache/M1s_BL808_SDK \
  python3 tools/validate_npu_objdump.py \
  --json-out build/npu-recovery/objdump-summary.json
```

The SDK encoder archive is a reference for instruction, weight, and data
preparation. The SDK C driver is the reference for runtime MMIO. Compare both
against [the Nim NPU driver](../src/bl808/npu.nim) and keep raw disassembly
under `build/`.

## Validate on the bench

```sh
.venv/bin/python tools/hw_validate.py --test m0_npu_smoke_test --build-only
make hw-npu-smoke-anchor UART_PORT="$UART_PORT"
```

The Make target probes the UART flash anchor, installs one if needed, then
runs the smoke test. Supply the live UART and add reset flags for your adapter
as described in [hardware validation](hardware_validation_harness.md).
The smoke tests exercise specific register and execution paths. Keep the model,
reference output, firmware identity, and captured output with each result.

The [prior recovery notes](https://github.com/gabearro/bl808-hal-nim/blob/eb932dddbb56ac5131b3d398e5463f18008fc639/docs/npu_recovery.md)
preserve individual recovered offsets and experiments.
