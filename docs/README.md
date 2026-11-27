# BL808 HAL documentation

Nim firmware, drivers, and runtime examples for the Bouffalo Lab BL808. The
hardware instructions use the Pine64 Ox64 unless a guide names another board.

| Task | Guide |
| --- | --- |
| Set up the toolchain and build an example | [Getting started](getting_started.md) |
| Flash, RAM-load, validate, or recover a board | [Hardware validation](hardware_validation_harness.md) |
| Run an application under the resident USB UART anchor | [USB UART anchor](usb_uart_anchor.md) |
| Build or operate the internet radio | [FreeNetRadio](freenetradio.md) |
| Measure CPU time, hardware events, or playback latency | [Profiling](profiling.md) |
| Understand Wi-Fi service, DMA ownership, or packet loss | [Wi-Fi](wifi.md) |
| Run repeatable Wi-Fi scheduling and protocol checks on a host | [Wi-Fi model fuzzer](wifi_model_fuzzer.md) |
| Build and test the interpreter across M0, D0, and LP | [Core WebAssembly](wasm_full_baseline.md) |
| Check Component Model support, features, and limits | [WebAssembly components](wasm_component_model.md) |
| Run jobs across cores or migrate a suspended task | [WebAssembly work stealing and migration](wasm_work_stealing.md) |
| Verify a bounded WASM or native-code claim | [Proof-carrying WebAssembly](zkbuild.md) |
| Review enclave assumptions and SRAM PUF evidence | [Enclave threat model](secure_enclave_threat_model.md), [SRAM PUF](sram_puf.md) |

## Hardware and vendor references

- [Vendor firmware provenance](bl808_vendor_blobs.md) records the pinned
  archives, build inputs, and reference checks.
- [AGC microcode](bl808_agc_microcode.md) contains the annotated BL808
  program and the evidence for the decoder.
- [Wi-Fi CSI research](bl808_wifi_csi_research.md) tracks the capture paths and
  the limits of the measured channel estimates.
- [NPU recovery](npu_recovery.md) links the recovered programming model,
  reference manifest, and hardware tests.

Use the [hardware test manifest](../tools/hardware_validation.json) for exact
test names, builds, and pass criteria. [AGENTS.md](../AGENTS.md) records the
current bench wiring, reset behavior, and recovery procedures.

The earlier [documentation snapshot](https://github.com/gabearro/bl808-hal-nim/tree/eb932dddbb56ac5131b3d398e5463f18008fc639/docs)
contains the original bring-up plans, detailed measurements, and research
traces. Use the live guides above for runnable instructions.
