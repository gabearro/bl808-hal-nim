# BL808 NPU/BLAI Recovery Notes

This document tracks the pure Nim recovery of the BL808 BLAI/CNN NPU path:
typed register overlays, instruction/data/weight planning, bounded CPU
reference fixtures, and hardware smoke coverage. Full generated instruction
stream execution is still being validated model by model.

## Source Inputs

Keep vendor sources and toolchains outside the tracked repository. Configure
local paths with:

```sh
export BL808_M1S_SDK=/path/to/M1s_BL808_SDK
export BLAI_NPU_TOOLCHAIN=/path/to/blai_npu
```

The known upstream locations are:

- `https://github.com/sipeed/M1s_BL808_SDK`
- `https://dl.sipeed.com/shareURL/MAIX/M1s/M1s_Dock/8_Toolchain/blai_npu`

## Recovery Command

Run the THEAD-aware discovery tool and keep the JSON output under `build/`:

```sh
python3 tools/validate_npu_objdump.py \
  --json-out build/npu-recovery/objdump-summary.json
```

The tool reports:

- candidate SDK/toolchain archives and objects containing NPU/BLAI keywords
- globally defined symbols from `riscv64-unknown-elf-nm`
- call relocations and direct call targets from `llvm-objdump -dr`
- immediate constants that land in MM_GLB, MM_MISC, CODEC_MISC, or BLAI windows
- store instructions near recovered functions for manual type recovery

The stable tracked summary of recovered facts is
`tools/ref/npu_recovery_manifest.json`. The `build/npu-recovery/*.json` files
are raw rerunnable tool output and stay ignored.

The manifest records:

- source repository/toolchain expectations and the verified SDK commit
- SDK object/source provenance for each recovered register group
- Nim overlay names, roots, and compile-time checked sizes
- BLAI register offsets and bit fields
- instruction-stream candidate symbols recovered from the encoder archive
- remaining BLAI instruction-stream execution semantics

Verified SDK input:

```sh
git -C build/vendor-cache/M1s_BL808_SDK rev-parse --short HEAD
# bf7e689

BL808_M1S_SDK=build/vendor-cache/M1s_BL808_SDK \
  python3 tools/validate_npu_objdump.py \
  --json-out build/npu-recovery/M1s_BL808_SDK-bf7e689-summary.json
```

That pass finds the BLAI encoder archive at
`components/stage/blai/blai_npu_encoder/lib/libblai_npu_encoder.a`. The public
text symbols recovered from the archive include:

- `BLAI_MEM_alloc`
- `Load_NPU_weights`
- `fetch_BLAI_data_general`
- `fetch_BLAI_data_route`
- `instruction_encode`
- `CONV_DUMP_ZERO`
- `CONV_WEI_DUMP_PIXEL`
- `CONV_WEI_DUMP_3x3`
- `CONV_WEI_DUMP_3x3_DIL`
- `CONV_WEI_DUMP_5x5`
- `CONV_WEI_DUMP_7x7`

The encoder archive is instruction/data generation only; the objdump pass shows
no direct MMIO immediates in the BLAI register windows. Runtime MMIO is in the
SDK source `components/platform/soc/bl808/.../StdDriver/Src/bl80x_npu.c`.
`tools/ref/npu_recovery_manifest.json` records the recovered encoder archive
oracle call graph plus an empty register-hit map for the recovered candidate
symbols. When the local SDK cache is present,
`tools/test_validate_npu_objdump.py` reruns THEAD-aware objdump against
`libblai_npu_encoder.a` and checks that the tracked call graph and no-MMIO
boundary still match the vendor archive, keeping the archive as an oracle for
instruction/data memory behavior rather than a live implementation path.

## Current Recovered Surface

The implemented Nim surface covers only SDK-documented integration registers:

- CNN clock selector/divider in MM_GLB, including typed
  `NpuClockStatusResult` decoding, typed `NpuInitClockSelectRegisterPlan`,
  `NpuClockConfigPlan`, and `NpuClockGatePlan` planning, the SDK-entrypoint
  `NpuClockEnableRegisterPlan`, and pure `MM_CLK_CPU` composition helpers for
  source-only, gate-only, and full enable/source/divider state
- CNN reset in MM_GLB, including typed `NpuResetStatusResult` decoding, typed
  `NpuResetLinePlan` single-write planning, typed `NpuResetPulsePlan`
  assert/settle/release planning, `npuResetSettleReadCountCursor` for the
  recovered settle-read loop bound, and pure `SW_RESET_CODEC_SUB` composition
  for asserted/released state
- BLAI SRAM ownership in MM_MISC, including typed `NpuSramStatusResult`
  decoding, typed `NpuSramReleasePlan` two-write release/latch planning, and
  pure `MM_MISC_VRAM_CTRL` composition helpers for release and SYSRAM_SET latch
  state
- Codec bus QoS and BLAI read/write limiters, including typed
  `NpuCodecQosPlan` and `NpuBusLimiterPlan` planning, typed apply helpers, and
  pure register-word composition helpers for QoS bits and limiter count/mode
  words
- BLAI instruction stream, weight, bias, image buffer, segment count, net
  parameter, interrupt, start/resume/stop, and activation-table aperture words,
  including typed `NpuIntCfgDecode` decoding for command, pending/clear, and
  ReLU-N state plus typed `NpuGeneralCfgDecode` decoding for input mode,
  activation-table base, and AXI idle state, plus typed `NpuTfCfgDecode`
  decoding for TensorFlow/TFLite enable state; `NpuNetParamFieldPlan` covers
  the individual public field setters, and `NpuNetParamRegisterPlan` composes
  unsigned-input, ReLU-N, and TensorFlow/TFLite mode register updates before
  applying them
- typed decoding of the SDK's 16-byte NPU layer instruction header, including
  optional external stride/dilation/group metadata
- typed decoding of recovered SDK CPU/DSP instruction records used to populate
  `cpu_inst_layer_t`: `DSP_HEADER`, `LAYER_INFO`, `GENERAL_FORM`,
  `DETAIL_GENERAL_FORM`, and `DSP_STATUS`
- SDK `check_BLAI_NPU_RUN` layer eligibility logic as
  `blaiNpuEligibilityInto` / `blaiCanRunOnNpu`, including the BL808 B0 stride
  subsample odd-dimension workaround
- SDK layer utility predicates for channel alignment, convolution, weight,
  route, multi-input, upsample, combo-max, and merge/combine classification
- SDK `BLAI_encode` wrapper decisions: eligibility gate, allocation-success
  gate, instruction scratch clear size, route-vs-general emitter selection,
  typed `instCnt` ABI projection through `blaiInstructionCountAbi`, and
  post-allocation memory-plan copies
- SDK `forward_NPU` temporary weight/bias allocation sizing around
  `Load_NPU_weights`: weight-layer detection, 4-byte aligned weight bytes,
  int32 bias bytes, bias offset, and total allocation size
- SDK `blai_cpu_load_weights` CPU model weight/bias count formulas used to
  populate `cpu_inst_layer_t.weights` and `biases` before NPU weight planning
- exact SDK `struct PSRAM_ctrl` memory-plan layout as `BlaiPsramCtrl`, recovered
  from `libblai_npu_encoder.a` DWARF and checked with Nim `offsetof`, with
  recovered allocator `uint32` stores projected through `blaiAllocatorFieldAbi`
- recovered RV64 encoder ABI layout for SDK `cpu_inst_layer_t` as
  `BlaiCpuInstLayer64`, using fixed-width address slots for archived pointer
  fields plus a typed projection into `BlaiDecodedLayer`
- SDK wrapper behavior for optional layer buffer setup, net parameter setup,
  unsigned-input reset, and the start/resume state transition used by
  `bl_npu_start` / `bl_npu_stop`

The register access style is typed overlays rooted at the relevant register
blocks. Public compatibility constants are retained for tests and existing code,
but implementation code should prefer the overlay fields. The base-address to
typed-pointer cast is centralized in `blaiMmioBlock`; individual register block
helpers expose typed overlays without repeating raw pointer casts. Volatile
register reads and writes are similarly centralized in `blaiLoadReg` and
`blaiStoreReg`, which accept typed `uint32` overlay fields and keep `addr`
handling out of call sites.

The current inferred Nim overlay blocks are:

| Overlay | Root | Checked size |
| --- | --- | --- |
| `CnnClockResetRegs` | `MM_GLB_MM_CLK_CPU` | `0x4C` |
| `MmMiscVramRegs` | `MM_MISC_VRAM_CTRL` | `0x04` |
| `MmMiscInterruptRegs` | `MM_INT_STA0` | `0x18` |
| `CodecMiscRegs` | `CODEC_MISC_BASE` | `0x28` |
| `BlaiRegs` | `BLAI_BASE` | `0x200` |
| `BlaiPsramCtrl` | `BLAI_MEM_alloc` output object | `0x270` |
| `BlaiCpuInstLayer64` | RV64 encoder `cpu_inst_layer_t` object | `0x2F0` |

## Recovered BLAI Register Map

The Sipeed SDK `npu_reg.h` / `bl80x_npu.c` recover these NPU aperture offsets:

| Offset | Register | Nim field |
| --- | --- | --- |
| `0x00` | `BALI_GENERAL_CFG` | `BlaiRegs.generalCfg` |
| `0x04` | `BLAI_INT_CFG` | `BlaiRegs.intCfg` |
| `0x10` | `BLAI_WEIGHT_ADDR` | `BlaiRegs.weightAddr` |
| `0x14` | `BLAI_BIAS_ADDR` | `BlaiRegs.biasAddr` |
| `0x18` | `BLAI_INST_ADDR` | `BlaiRegs.instAddr` |
| `0x1C` | `APU_DM0_ADDR` | `BlaiRegs.imageAddr` |
| `0x20` | `APU_DM1_ADDR` | `BlaiRegs.imageSeg` |
| `0x24` | `BLAI_TF_CFG0` | `BlaiRegs.tfCfg0` |
| `0x100..0x1FC` | `BLAI_ACT_TABLE*` | `BlaiRegs.actTable` |

Recovered bit fields:

- `generalCfg[0]`: unsigned image/input flag
- `generalCfg[9:8]`: image input mode (`sound`, `YUV400`, `YUV422`)
- `generalCfg[21:16]` / `[29:24]`: activation-table index/data base fields
  with `NpuActivationTableBaseRegisterPlan` preserving unrelated
  `BALI_GENERAL_CFG` state
- `generalCfg[30]` / `[31]`: AXI write/read idle status
- `actTable[n][7:0]` / `[15:8]` / `[23:16]` / `[31:24]`: four packed
  8-bit activation-table entries per `BLAI_ACT_TABLE*` word, with typed
  `NpuActivationTableEntryCursor` byte-lane projection and
  `NpuActivationTableWordCursor` register-offset/address projection
- `NpuRegisterSnapshot` decodes image-input mode validity plus the
  activation-table index/data base fields from `BALI_GENERAL_CFG`, and exposes
  typed `BALI_GENERAL_CFG` fields through `NpuGeneralCfgDecode` and typed
  `BLAI_INT_CFG` command/status/ReLU-N fields through `NpuIntCfgDecode`, plus
  typed `BLAI_TF_CFG0` mode state through `NpuTfCfgDecode`
- `intCfg[0]`: start
- `intCfg[1]`: stop
- `intCfg[2]`: resume
- `intCfg[8]`: interrupt clear
- `intCfg[9]`: interrupt pending
- `intCfg[20:16]`: ReLU-N value
- `tfCfg0[31]`: TensorFlow/TFLite mode enable

The SDK runtime sequence is:

1. `blai_npu_initCfg(model)` wraps initial layer setup, input-buffer setup,
   net-parameter setup, and interrupt setup for `CNN_IRQn` priority `7,1`.
   The Nim recovery represents the interrupt request as plan data until the
   core-local CNN/APU interrupt routing is verified.
2. `bl_npu_layer_setup(inst, weight, bias)` writes `BLAI_INST_ADDR`,
   `BLAI_WEIGHT_ADDR`, and `BLAI_BIAS_ADDR` only for non-null arguments.
3. `bl_npu_set_input_buffer(buffer, patch_size)` writes `APU_DM0_ADDR` and
   `APU_DM1_ADDR`.
4. `bl_npu_set_net_param(unsigned_input, relu_n, is_tflite)` updates
   `BALI_GENERAL_CFG`, `BLAI_INT_CFG`, and `BLAI_TF_CFG0`.
5. `bl_npu_reset_unsign()` clears `BALI_GENERAL_CFG.imgi_unsign`.
6. `blai_npu_layer_config(inst, weight, bias, input, patch_size, first)` wraps
   layer setup, input-buffer setup, and unsigned-input reset for non-first
   layers.
7. `bl_npu_init()` selects CNN/NPU clock source `2`; local `npuInit` mirrors
   that source selection before reset/release setup.
8. `bl_npu_clk_en(en)` toggles the CNN/NPU clock gate without changing the
   selected source or divider.
9. `bl_npu_start()` read-modify-writes `BLAI_INT_CFG.start` once; later calls
   read-modify-write `resume` until `bl_npu_stop()` read-modify-writes stop
   and clears the wrapper's started state. `NPU_Clr_Int` also preserves the
   other `BLAI_INT_CFG` fields while setting the clear bit.
10. The interrupt handler clears `BLAI_INT_CFG.int_clear` and releases the NPU
   wait semaphore.

The Nim recovery mirrors this as:

- `NpuLayerBuffers`, `NpuLayerBufferRegisterPlan`, and
  `NpuInputBufferRegisterPlan` for optional SDK layer-buffer writes and
  unconditional DATA/segment writes
- `npuConfigureLayerBuffers` / `npuSetInputBuffer`
- `NpuInstructionStreamRegisterPlan` /
  `npuPlanInstructionStreamRegisters` /
  `npuApplyInstructionStreamRegisterPlan`
- `NpuLaunchRegisterPlan` / `npuPlanLaunchRegisters` /
  `npuApplyLaunchRegisterPlan`
- `NpuLayerConfig`, `NpuLayerConfigRegisterPlan`, `npuPlanLayerConfig`,
  `npuPlanLayerConfigRegisters`, and `npuApplyLayerConfig`
- `NpuInitConfig`, `NpuInitConfigRegisterPlan`, `NpuInterruptConfig`,
  `npuPlanInitConfig`, `npuPlanInitConfigRegisters`, and
  `npuApplyInitConfigRegisters`
- `NpuNetParams` / `npuConfigureNetParams`, backed by pure register-word
  composition helpers for unsigned input, image mode, ReLU-N, and TF_CFG0
- `npuResetUnsignedInput`
- `NpuRuntimeInitRegisterPlan`, `npuRuntimeInitRegisterPlan`, and
  `npuApplyRuntimeInitRegisterPlan` compose the recovered `bl_npu_init`
  source-only clock-select, reset-pulse, SRAM-release, and final clock-gate
  sequence.
- `NpuInitClockSelectRegisterPlan`, `npuInitClockSelectRegisterPlan`, and
  `npuApplyInitClockSelectRegisterPlan` mirror `CLKRST_NPU_CLK_Sel(2)` by
  selecting source `2` while preserving the existing clock gate and divider.
- `NpuClockEnableRegisterPlan`, `npuClockEnableRegisterPlan`, and
  `npuApplyClockEnableRegisterPlan` mirror `bl_npu_clk_en(en)` by toggling only
  the CNN/NPU clock gate.
- `npuStart`, `npuStop`, `NpuWrapperStateResult`, `npuWrapperStateInto`,
  `npuWrapperStateFromFlags`, `npuWrapperState`, `npuExecutionStarted`, and
  `npuInstructionStreamConfigured`
- `NpuIntCfgCommandPlan`, `NpuInterruptAckRegisterPlan`,
  `NpuStartTransitionPlan`, `NpuStopTransitionPlan`, `npuPlanIntCfgCommand`,
  `npuInterruptAckRegisterPlan`, `npuPlanStartTransition`,
  `npuPlanStopTransition`, `npuIntCfgWithCommand`, `npuIntCfgWithStart`,
  `npuIntCfgWithResume`, `npuIntCfgWithStop`, and
  `npuIntCfgWithInterruptClear` model the SDK command-bit read-modify-write
  behavior, `bl_npu_ack_irq` / `NPU_Clr_Int`, first-start/later-resume wrapper
  transition, and stop-state clear without clobbering ReLU-N or interrupt status
  fields.
  The active configured smoke checks the start, resume, stop, and interrupt-clear
  command transforms independently.
  Active runtime-init evidence also splits clock disabled/source/divider,
  reset release/assertion, and SRAM release/self-clear checks.

## Recovered Instruction Header

The SDK NPU stream uses 16-byte little-endian bit-addressed instructions.
`fetch_info(inst, base, len)` walks bits starting at `base`, with bit 0 being
byte 0 bit 0. The Nim `BlaiInstruction`, `BlaiExternalLayerInfo`, and
`BlaiDecodedLayer` types encode the currently recovered header without pointer
arithmetic.
`blaiInt32FromBits` and `blaiUint32FromInt32Bits` provide named SDK ABI
reinterpretation helpers for unsigned stream fields that are stored in signed
`cpu_inst_layer_t` slots and later emitted back into instruction bitfields. The
focused parser smoke checks this round trip on-device for recovered TFLite
multiplier fields. Signed descriptor fields use `blaiSignedFieldBits` before
bit emission so TFLite input/output shifts and extra left-shift fields do not
carry direct `cast[uint32]` at the encode sites.

Instruction classification:

- byte 0 bit 0 set and bit 127 clear: external instruction carrying
  stride/dilation/groups for the next normal layer
- byte 0 bit 0 clear: normal layer instruction
- bit 127 set on a normal layer: halt/end marker used by the SDK layer counter

Normal layer fields currently decoded:

| Bits | Field |
| --- | --- |
| `1..12` | output width `w` |
| `13..24` | output height `h` |
| `25..36` | input channels `c` |
| `37..48` | first route/channel count `cn0` |
| `49..60` | output channels `outC` |
| `61..65` | data fractional bits `fdata` |
| `66..70` | weight fractional bits `fweight` |
| `71..75` | bias fractional bits `fbias` |
| `76..80` | route1 fractional bits `froute1` |
| `77..84` | TFLite output offset overlay |
| `81..85` | route2 fractional bits `froute2` |
| `86..90` | output fractional bits `fout` |
| `91..93` | kernel/operation size |
| `94..98` | activation |
| `98..101` | layer-type discriminator bits |
| `102..106` | input layer 1 SRAM/DRAM slot |
| `107..111` | input layer 2 SRAM/DRAM slot |
| `112..116` | output SRAM/DRAM slot |
| `125` | upsample discriminator |
| `126` | alternate maxpool discriminator |
| `127` | halt/end marker |

External layer fields currently decoded:

| Bits | Field |
| --- | --- |
| `37..48` | raw groups divisor |
| `85..87` | stride minus one |
| `88..90` | dilation minus one |

As in the SDK, the final decoded `groups` value is normalized to
`c / rawGroups` when a nonzero raw group value is present, otherwise to `c`.

## Recovered CPU/DSP Instruction Records

The SDK CPU parser uses the same 16-byte little-endian bit-addressed instruction
primitive to fill `cpu_inst_layer_t`. The Nim recovery now names the SDK
`INSTRUCTION_TYPE` values as `BlaiCpuInstructionType` and decodes the field
groups needed before NPU eligibility and encoding:

| SDK record | Nim decoder | Purpose |
| --- | --- | --- |
| `DSP_HEADER` | `decodeBlaiCpuDspHeader` | net version, patch size/count, unsigned input, ReLU-N, TFLite mode, layer count, app type, NPU acceleration flag |
| `LAYER_INFO` | `decodeBlaiCpuLayerInfo` | spatial/channel shape, layer memory slots, input count, output shape |
| `GENERAL_FORM` | `decodeBlaiCpuGeneralForm` | layer type, kernel/stride/dilation/groups, fixed-point or TFLite quantization fields |
| `DETAIL_GENERAL_FORM` | `decodeBlaiCpuDetailGeneralForm` | asymmetric kernel/stride/padding fields |
| `INPUT_LAYERS` | `decodeBlaiCpuInputLayers` / `applyBlaiCpuInputLayers` | graph input layer indices through `BlaiCpuInputLayerEntryCursor` and the shared `BlaiInstructionFieldStrideCursor` plus combined-layer `graphLayer` / next `layerOffset` bookkeeping |
| `YOLO_INFO` | `decodeBlaiCpuYoloInfo` / `applyBlaiCpuYoloInfo` | bounded YOLO class/total decode plus typed mask and bias sidecar storage |
| `EXTRA_LAYER` / `EXTRA_LAYER_6_8` | `decodeBlaiCpuExtraLayer` / `applyBlaiCpuExtraLayer` | bounded extra-input memory/channel/TFLite offset-shift decode through `BlaiCpuExtraLayerEntryCursor`; sidecar parser overload stores SDK pointer-backed arrays in `BlaiCpuExtraInputStorage` |
| `EXTRA_MULTIPLIER` / `EXTRA_MULTIPLIER_6_8` | `decodeBlaiCpuExtraMultiplier` / `applyBlaiCpuExtraMultiplier` | bounded extra TFLite input multiplier decode through `BlaiCpuExtraMultiplierEntryCursor`; sidecar parser overload stores SDK pointer-backed arrays in `BlaiCpuExtraInputStorage` |
| `TFLITE_MULTIPLIER` | `decodeBlaiCpuTfliteMultiplier` / `applyBlaiCpuTfliteMultiplier` | scalar TFLite input/output multipliers plus low route multiplier bits |
| `TFLITE_FLOAT` | `decodeBlaiCpuTfliteFloat` / `applyBlaiCpuTfliteFloat` | raw IEEE-754 input/output scale bits, reinterpreted through `blaiFloat32FromBits` |
| `SSD_INFO` | `decodeBlaiCpuSsdInfo` / `applyBlaiCpuSsdInfo` | SSD scalar geometry/class limits, raw input2/input3 IEEE-754 scale bits, and anchor table offset |
| `DSP_STATUS` | `decodeBlaiCpuDspStatus` / `applyBlaiCpuDspStatus` | NPU/DSP flags, end marker, input count, raw IEEE-754 output scale bits, output layer marker |

Signed TFLite shift fields use the SDK's `unsigned_to_signed(fetch_info(...))`
behavior through `blaiSignedBits`; no pointer casts are used.
TFLite scale records use the SDK's raw-bit float reinterpretation; the Nim
recovery localizes that cast in `blaiFloat32FromBits`.
Instruction bitfield access uses `blaiInstructionBitCursor(uint32)` for
recovered SDK bit positions, avoiding signed index conversion in `blaiBit` and
`blaiPutBits`.
SDK layer-type discriminants are named as `BlaiSdk*Type` constants and
`blaiLayerTypeFromSdk` matches those constants directly; enum ordinal checks are
kept in compile-time assertions only.
SDK activation discriminants are named as `BlaiSdkAct*` constants and
`blaiActivationFromSdk` matches those constants directly, defaulting unknown
values to the SDK-compatible linear activation.
SDK CPU/DSP instruction record discriminants are named as `BlaiSdkCpu*Record`
constants and `decodeBlaiCpuInstructionType` matches those constants directly.
Signed ABI scalar fields that represent counts, including parser-side
`inputNum` and YOLO `n`, are projected through `nonNegativeU32` before being
used as record decode bounds.

The basic `BlaiCpuModelParseResult` /
`blaiParseCpuModelInstructionsInto` / `blaiParseCpuModelInstructions` overload
now composes the recovered header, layer-info, general-form, detail-form, and
status records into a caller-owned `BlaiCpuInstLayer64` table. That narrow
parser is intentionally bounded: it reports overflow, malformed streams, and
recognized-but-unsupported pointer-backed sidecar records instead of fabricating
SDK pointer metadata. Scalar and graph-bookkeeping records whose field effects
are recovered (`INPUT_LAYERS`, `TFLITE_MULTIPLIER`, `TFLITE_FLOAT`, `SSD_INFO`,
and `DSP_STATUS`) are applied directly. The parse result records both the first
unsupported record index and its typed
`BlaiCpuInstructionType`, so callers can route to a sidecar-aware parser without
inspecting raw instruction bytes. `blaiInitCpuModelParseResult`,
`blaiMarkCpuModelParseMalformed`, `blaiMarkCpuModelParseUnsupported`, and
`blaiFinishCpuModelParseResult` keep that lifecycle in typed helpers shared by
all parser overloads. `BlaiCpuRecordIndexAbi` checks CPU/DSP record indexes
before they are stored in SDK `int32` parse diagnostics. The `Into` form keeps
the parse summary in caller-owned storage.

The sidecar overloads of `blaiParseCpuModelInstructionsInto` and
`blaiParseCpuModelInstructions` accept caller-owned `BlaiCpuExtraInputStorage`
and `BlaiCpuYoloStorage` entries and apply `EXTRA_LAYER*`,
`EXTRA_MULTIPLIER*`, and `YOLO_INFO` records there instead of fabricating the
SDK's raw pointer fields inside `cpu_inst_layer_t`. The YOLO path explicitly
bounds the SDK's three mask/bias pairs and rejects streams whose decoded masks
would index beyond `total`; `BlaiCpuYoloInfoEntryCursor` localizes the packed
`YOLO_INFO` mask/width-bias/height-bias bitfield bases, while
`BlaiYoloBiasPairIndex` names the recovered `biases[mask * 2]` /
`biases[mask * 2 + 1]` pair layout. `BlaiYoloBiasPairCursor`,
`blaiYoloBiasPairCursor`, and `blaiStoreYoloBiasPair` then localize that pair
layout plus the active-mask sidecar slot behind typed bounded storage writes,
with each recovered `uint32` slot projected through `blaiU32ArrayIndexCursor`
before indexing Nim arrays.
`BlaiCpuYoloInfoFieldAbi` checks decoded YOLO classes, total, mask, and bias
scalars before they cross into SDK `int32` layer and sidecar storage fields.
`BlaiCpuSsdInfoFieldAbi` checks decoded SSD class-limit and anchor-offset
scalars before they cross into SDK `int32` layer fields; raw scale bits stay
localized behind `blaiFloat32FromBits`.
`BlaiCpuTfliteRouteMultiplierAbi` composes the `GENERAL_FORM` high route
multiplier bits with the `TFLITE_MULTIPLIER` low bits before updating the SDK
`tfRouteInputMultiplier` field.
`BlaiCpuLayerInfoFieldAbi` checks decoded `LAYER_INFO` shape, memory-slot,
input-count, output-shape, and first-channel fields before they are written into
the SDK layer object.
`BlaiCpuGeneralFormFieldAbi` does the same for `GENERAL_FORM` layer type,
kernel, stride, dilation, group, fixed-point, TFLite offset, activation clamp,
axis, and data-type fields. `BlaiCpuTfliteRouteMultiplierHighAbi` localizes the
high-half route multiplier bit pattern produced by `GENERAL_FORM`.
`BlaiCpuDetailGeneralFormFieldAbi` checks the asymmetric kernel, stride, and
padding fields decoded from `DETAIL_GENERAL_FORM`.
`BlaiCpuDspStatusInputNumAbi` checks the input count decoded from `DSP_STATUS`
before it is applied to the SDK layer object; raw output-scale bits stay
localized behind `blaiFloat32FromBits`.
`BlaiCpuInputLayerFieldAbi` checks the packed graph input entries decoded from
`INPUT_LAYERS`, and `BlaiCpuGraphLayerAbi` checks graph-layer bookkeeping that
combines the parser layer index with the current SDK `layerOffset`.
`BlaiLayerIndexAbi` / `blaiLayerIndexValue` now also project model-execution
diagnostics such as first-failed and last-completed layer indexes, replacing
raw `layerIndex.int32` writes in the recovered execution paths. The same
projection covers CPU weight/bias stream cursor layer indexes and stream-match
checks in the parsed fixed/TFLite reference and workspace materialization
paths.
`BlaiOutputMismatchIndexAbi` checks tensor-output comparison indexes before
they are stored in `firstMismatch` diagnostics for uint8 and fixed/raw-byte
oracle validation.
Recovered layer and activation enum projections are used for graph-combine and
linear-activation semantic checks instead of direct SDK `ord(...).int32`
comparisons in the active parser/evidence paths.
`BlaiCpuTfliteMultiplierBitsAbi` localizes the raw 32-bit multiplier bit-pattern
projection used by `EXTRA_MULTIPLIER*` sidecars and `TFLITE_MULTIPLIER`.
`BlaiCpuBiasBitsAbi` localizes the raw little-endian CPU bias word
reinterpretation before storing decoded bias stream values into SDK `int32`
storage.
Raw SDK bit-pattern ABI helpers use the named `blaiInt32FromBits` projection
instead of direct `cast[int32]` at each recovered store site.
The split TFLite route-multiplier composer also uses
`blaiUint32FromInt32Bits` when extracting high bits from the signed SDK slot,
so both directions of that ABI bit-pattern bridge stay named and localized.
Decoded unsigned SDK scalar fields now pass through `BlaiSdkInt32Field` /
`blaiSdkInt32Field` before they are written into int32-backed SDK ABI storage.
This keeps semantic non-negative fields separate from raw bit-pattern
reinterpretation and removes repeated inline narrowing checks from the
individual ABI helpers.
Descriptor evidence comparisons project signed SDK layer fields through
`nonNegativeU32` before comparing them with decoded unsigned instruction fields.
Fixed SDK capacities used in recovered `uint32` arithmetic are named as
`BlaiMax*U32` constants instead of repeated `.uint32` casts at use sites.
`blaiRouteConvExtraInputCount` names the recovered `Load_NPU_weights`
ROUTE_CONV side-input count and keeps the temporary channel expansion in
bounded `uint32` space.
`BlaiInstructionFieldStrideCursor` localizes the recovered repeated
`base + packed_slot * stride` bitfield projection used by `INPUT_LAYERS`,
`YOLO_INFO`, `EXTRA_LAYER*`, and `EXTRA_MULTIPLIER*` records.
`BlaiCpuExtraLayerEntryCursor` localizes the recovered low/high-bank
`EXTRA_LAYER*` per-input bitfield bases for memory slot, channels, route
fractional bits, and TFLite offset/shift fields, projecting the recovered
packed input slot through `blaiU32ArrayIndexCursor` before computing the bases.
`BlaiCpuExtraLayerFieldAbi` checks the decoded unsigned memory-slot, channel,
route-fraction, and TFLite-offset scalars before they are written into the SDK
`int32` layer and sidecar storage fields.
`BlaiCpuExtraMultiplierEntryCursor` performs the same low/high-bank packed-entry
projection for `EXTRA_MULTIPLIER*` 32-bit multiplier fields.
`BlaiLogicalInputSlotCursor` localizes the recovered SDK logical-input
to zero-based sidecar-slot projection. `BlaiCpuExtraStorageCursor` uses it for
inputs 2 and above in the caller-owned `mlayer_input_info_t` sidecar arrays, so
extra route/TFLite storage reads and writes no longer pass through signed
placeholder indexes.
`BlaiCpuParsedLayer` / `blaiCpuParsedLayer` provide a small value projection of
the aligned layer/extra-input sidecar pair. `BlaiCpuParsedLayerState` /
`blaiCpuParsedLayerState` extend that projection to all recovered sidecars,
including YOLO mask/bias storage. A parser overload can now fill caller-owned
`BlaiCpuParsedLayerState` entries directly, keeping each layer and its sidecars
in one typed value instead of forcing downstream code to maintain parallel
arrays. Focused parser-smoke coverage now exercises both the low extra-input
bank and the recovered TFLite high-bank `EXTRA_LAYER_6_8` /
`EXTRA_MULTIPLIER_6_8` records for inputs 5-7, including route source and
per-input quantization projection without SDK pointer fields.
`BlaiLayerCnCursor`, `blaiLayerCn`, and `blaiSetLayerCn` localize the SDK
logical input `k` to `cn[k - 1]` convention through the same logical-input slot
cursor for recovered sidecar application, route-source projection, fetch
descriptor operands, weight-loader planning, and tensor staging; the recovered
`uint32` input is projected before indexing the Nim `cn` array.
`blaiCpuRouteInputSource` and
`blaiCpuTfliteInputQuant` then project the SDK's per-input ternary selections
(`in_layer1_mem`, `in_layer2_mem`, or `in_layer_mem_n[k-2]`, and the matching
TFLite offset/multiplier/shift fields) as typed values for recovered
CPU-reference and planning code.

`blaiNetParams` projects the parsed header to the SDK runtime NPU parameters
(`unsignedInput`, `reluN`, and TFLite mode). `BlaiParsedForwardModelReadiness`,
`blaiParsedForwardModelReadinessInto`, and `blaiParsedForwardModelReadiness`
make the next ownership boundary explicit: parsed CPU records are not enough to
run `forward_NPU` until the allocator and encoder have filled post-encoder
fields such as `dramPatchSize` and `instCnt`, and until caller-owned layer
storage covers every parsed layer record. The readiness result captures the
first unencoded layer's `BlaiForwardEncodedLayerReadiness`, so callers can
distinguish missing patch planning from missing instruction-stream emission
without rewalking the layer table.
`BlaiParsedForwardModelPlan` / `blaiPlanParsedForwardModelWorkspace` then bridge
encoded parsed layers into the existing reusable `forward_NPU` resource and
workspace planners without allocating, copying weights, or executing hardware.
`blaiPlanParsedForwardModelWorkspaceInto` provides the same bridge with
caller-owned result storage for embedded callers.
`BlaiParsedForwardModelExecuteReadiness`,
`blaiParsedForwardModelExecuteReadinessInto`, and
`blaiParsedForwardModelExecuteReadiness` split parsed-model execution readiness
into parse completeness, encoded forward readiness, workspace-plan readiness,
caller-owned layer-table coverage, and caller-owned workspace byte fit. The
readiness result carries a `BlaiParsedForwardModelExecuteBlock` first-block
reason so callers can distinguish incomplete parsing, stale or short layer
storage, missing workspace plans, and undersized workspace backing before
attempting materialization.
`BlaiParsedForwardModelExecuteResult` /
`blaiMaterializeAndExecuteParsedForwardModelWorkspace` adds the execution-facing
composition: it verifies the parsed plan and caller-owned workspace backing
storage, refuses truncated caller-owned layer tables even when a reusable plan
was produced from a fuller table, then delegates to the per-layer
materialize-and-execute sequence.
`blaiMaterializeAndExecuteParsedForwardModelWorkspaceInto` provides the same
execution composition with caller-owned result storage.
The focused M0 parser smoke now exercises this parsed-model
materialize-and-execute bridge on device for raw layer tables and parsed-layer
state tables, including successful workspace storage, CPU stream cursor
advancement, missing layer storage, and short workspace rejection with a
callback executor.
`BlaiCpuModelForwardWorkspaceParsePlan` /
`blaiParseAndPlanForwardModelWorkspace` gives raw CPU/DSP instruction streams a
single parse-and-plan entry point while still surfacing the unencoded-layer gate
when allocator/encoder fields are not present yet.
`blaiParseAndPlanForwardModelWorkspaceInto` is the caller-owned result variant.
The readiness and workspace planning helpers also accept
`BlaiCpuParsedLayerState` arrays, so parsed models
that keep typed sidecar state do not need to split back into parallel layer
arrays before forward planning or workspace-backed materialize-and-execute
composition.
Parser-facing wrappers for `blaiEncodeDispatch`,
`blaiNpuEligibilityInto`, and `blaiCanRunOnNpu` project through the embedded
CPU layer without detaching typed sidecar storage, so parsed records can be
checked for dispatch and pre-encoder eligibility in the same representation
used by model validation.

`BlaiReleaseLayerPlan` / `blaiAssignReleaseLayers` recover the SDK
`assign_release_layer` analysis without its temporary heap allocations. Callers
provide the layer table and graph-layer map storage; the proc fills each
layer's fixed ABI `releaseLayers` / `releaseMidLayers` arrays, sets `midOut`
for combined layers whose intermediate graph output has a later consumer, and
reports graph-map or release-list overflow explicitly with a typed first-block
reason. `BlaiReleaseSlotCursor` checks the fixed release-list counters before
array writes, `BlaiGraphLayerMapCursor` checks signed graph-layer ids before
writing caller-owned graph maps, and `BlaiLayerIndexAbi` checks recovered
layer-table indexes before storing them in SDK `int32` graph/release fields or
parsed/model-forward diagnostic layer fields.
A parsed-layer state overload applies the same
analysis without
splitting typed extra-input and YOLO sidecar ownership back into parallel raw
layer arrays.

`BlaiCpuOutputShapeResult` / `blaiApplyCpuOutputShapeLater` recover the typed
parts of SDK `set_output_wh_later`: `PAD` output dimensions are derived from
the typed `BlaiCpuPadShapeBias` sidecar, TFLite `TRANSPOSE` output dimensions
are derived from `BlaiCpuTfliteTransposeMask`, and `TRANSPOSE_LK` writes the
SDK `size`, aligned output channel count, preserved width, and output window
count. `BlaiOutputShapeDimAbi` checks derived output dimensions before they are
stored in SDK `int32` shape fields, and `BlaiKernelSizeAbi` checks the
`TRANSPOSE_LK` kernel-size write. The PAD path intentionally requires
caller-owned sidecar values instead of dereferencing the raw ABI `biases`
pointer slot. The result reports a typed first-block reason for unsupported
layers, missing PAD/TRANSPOSE sidecars, invalid dimensions, and invalid
`TRANSPOSE_LK` scalar parameters.
The parsed-layer state overload updates the embedded layer shape while keeping
typed extra-input and YOLO sidecar storage bundled with the parsed record.

## Recovered Layer Eligibility

The SDK encoder first calls `check_BLAI_NPU_RUN(net, layer)`. The `net`
argument is unused by that function; the decision is pure control flow over the
decoded layer metadata. The Nim `blaiNpuEligibilityInto` and
`blaiCanRunOnNpu` procs mirror that behavior:

- convolution: kernel size <= 7, dilation <= 2, stride <= 2, and the BL808 B0
  workaround rejects stride-2 layers where exactly one of width/height is odd
- convolution plus maxpool and route-convolution: kernel size <= 7, dilation <=
  2, stride <= 2
- maxpool: size <= 3 and stride <= 2
- route, route-max, route-upsample, upsample, matmul, and shortcut: eligible
- all other decoded layer types: not eligible

The `Into` form reports which recovered gate rejected the layer: unknown layer,
size, dilation, stride, or the BL808 B0 odd stride-2 workaround.

This is not yet an execution guarantee; the later SDK steps still allocate NPU
buffers and emit instruction/data streams via the encoder archive.

The SDK utility predicates in `blai_inst_util.c` are also recovered as pure Nim
helpers. These are used by the CPU/NPU scheduler and encoder preparation paths:

| SDK helper | Nim helper | Behavior |
| --- | --- | --- |
| `BALI_CHN_ALIGN` | `blaiChannelAlign4` | round channels up to a multiple of four |
| `check_combomax_layer` | `blaiIsComboMax` | maxpool with stride 2 and size 2 |
| `check_upsample_layer` | `blaiIsUpsample` | `UPSAMPLE` or `ROUTE_UPSAMPLE` |
| `check_conv_layer` | `blaiIsConv` | `CONVOLUTIONAL`, `CONV_MAX`, or `ROUTE_CONV` |
| `check_weight_layer` | `blaiUsesWeights` | convolution/route-convolution/conv-max/matmul weight users |
| `check_MultiInput_layer` | `blaiIsMultiInput` | route, shortcut, route-W, and SSD multi-input users |
| `check_route_layer` | `blaiIsRoute` | route-style layers |
| `check_combine_layer` / `check_merge_layer` | `blaiIsCombine`, `blaiMergedLayerCount` | combined graph layers that decrement parsed layer count |

## Recovered Encoder Wrapper

The SDK `BLAI_encode(net, layer, current, ctrl)` is now represented by pure Nim
planning helpers around the recovered bounded allocator and emitters:

- `blaiPlanEncodeInto` and `blaiPlanEncode` mirror the eligibility gate and
  explicit `BLAI_MEM_alloc` success gate.
- `BlaiInstructionScratchSize` is `MAX_Input_num * NPU_INST_SIZE_BYTE * 3`,
  and `blaiClearInstructionScratch` mirrors the SDK instruction-buffer `memset`
  without pointer arithmetic.
- `BlaiNpuInstructionBundle` matches SDK `blai_instruction_t`, and
  `blaiEncodeInstructionsInto` / `blaiEncodeInstructions` mirror
  `instruction_encode`: append `inst_tflite` when `use_tflite != 0`, append
  `inst_extra` when `extra_info != 0`, then always append `inst`. The Nim
  helper checks the destination instruction slice through the shared
  `BlaiUint32AppendFitResult` cursor/append gate and reports `fits=false`
  instead of overflowing it. Parser-smoke hardware coverage exercises the
  TFLite+extra append order/count path and short-buffer no-commit behavior.
- `BlaiNpuShapeDescriptor` and `blaiEncodeShapeDescriptor` recover the base
  normal/tflite descriptor dimensions from `blai_instruction_t`: `layer_w`,
  `layer_h`, `layer_c1`, `layer_c2`, and `layer_o`. `BlaiInstructionBitCursor`
  localizes the recovered little-endian bit numbering used by `blaiBit`,
  `blaiBits`, and `blaiPutBits`.
- `BlaiNpuNormalDescriptor`, `BlaiDecodedNormalDescriptorInstruction`,
  `blaiEncodeNormalDescriptor`, and
  `decodeBlaiNormalDescriptorInstruction` recover the normal descriptor's
  fixed-point width fields (`fdata_w`, `fweight_w`, `fbias_w`, `froute1_w`,
  `froute2_w`, `fout_w`) plus `conv_size` and `act_type`.
- `BlaiNpuTfliteDescriptor`, `BlaiDecodedTfliteDescriptorInstruction`,
  `blaiEncodeTfliteDescriptor`, and
  `decodeBlaiTfliteDescriptorInstruction` recover the TFLite descriptor's
  `tf_input1_offset`, `tf_input2_offset`, `tf_output_offset`, signed
  `tf_output_shift`, `conv_size`, and `act_type` fields.
- `BlaiNpuTfliteQuantDescriptor`, `BlaiDecodedTfliteQuantInstruction`,
  `blaiEncodeTfliteQuantDescriptor`, and
  `decodeBlaiTfliteQuantInstruction` recover the `inst_tflite` side
  instruction appended before TFLite layers:
  signed input shifts, input/output multipliers, and quantized activation
  bounds.
- `BlaiNpuExtraDescriptor`, `BlaiDecodedExtraInstruction`,
  `blaiEncodeExtraDescriptor`, and `decodeBlaiExtraInstruction` recover the
  `inst_extra` side instruction appended before layer headers: segment widths,
  output dimensions, grouped channel counts, stride/dilation, and signed left
  shift.
- `BlaiNpuCommonDescriptor` and `blaiApplyCommonDescriptor` recover the common
  descriptor control and memory-slot fields: `img_in`, `MAX_check`,
  `ROUTE_bit`, `MAC_bit`, input/output/mid SRAM slots, mid-output flags,
  `halt`, `upsample_bit`, `MAC_bit_ext`, and `inst_end_bit`.
- `blaiCommonControlDescriptor` and `blaiCommonDescriptor` derive those common
  control and SRAM slot fields from typed layer data plus the recovered fetch
  memory plan.
- `blaiNormalInstructionBundle` and `blaiTfliteInstructionBundle` assemble the
  recovered side/main descriptors into the SDK `blai_instruction_t` append
  shape consumed by `blaiEncodeInstructions`.
- `blaiLayerInstructionBundle` assembles the same recovered bundle directly
  from `cpu_inst_layer_t` ABI data plus a fetch memory plan. It can either use
  explicit operands for oracle tests or consume `BlaiFetchDescriptorOperands`.
- `blaiPlanFetchDescriptorOperandsInto` and
  `blaiPlanFetchDescriptorOperands` recover the general/route `layer_c2`
  operand and `inst_extra` emission decision into caller-owned result storage
  from typed `cpu_inst_layer_t` and `BlaiPsramCtrl` state, including the SDK
  combo-max special case.
- `blaiPlanRouteDescriptorLoopInto` and `blaiPlanRouteDescriptorLoop` recover
  the bounded
  `fetch_BLAI_data_route` descriptor loop's channel-carrying plan: one
  descriptor for each additional route input, starting from `c` and carrying
  cumulative channel counts through each `cn[]` input. The `Into` form feeds
  route emission through caller-owned loop-plan storage.
  `BlaiRouteDescriptorNextInputCursor` and
  `blaiRouteDescriptorNextInputCursor` localize the recovered next logical
  input to `cn[]` slot projection before the channel plan is staged.
  `BlaiRouteDescriptorStepPosition` and
  `blaiRouteDescriptorStepPosition` bound each recovered step before indexing
  the fixed step table and carry the terminal-step flag used by descriptor-halt
  emission. `BlaiRouteDescriptorStepCursor` continues to bound matching `cn[]`
  entries. `BlaiRouteDescriptorChannelAbi` checks recovered descriptor channel
  counts before staging them in the SDK signed `c` field.
- `blaiEmitRouteLayerInstructionsInto` and
  `blaiEmitRouteLayerInstructions` emit that recovered multi-descriptor route
  loop with the existing typed descriptor encoder, recovered route `SRAM_out[]`
  slots, and bounded instruction append checks. The focused route smoke now
  exercises the two-descriptor route emission path and the short-stream
  no-commit guard on device.
- `blaiPlanRouteSramSlotsInto`, `blaiPlanRouteSramSlots`, and
  `blaiApplyRouteSramSlotPlan` recover the route-specific `SRAM_out[]` cursor
  layout: `SRAM_out[0]` starts after all input patches, later entries hold
  intermediate route outputs, `line_w0` is refreshed from `line_patch_w[0]`,
  and `groups` is clamped to at least one. The `Into` form keeps route fetch
  emission on caller-owned plan storage. `BlaiRouteSlotCursor`,
  `BlaiRouteNextSlotIndex`, `BlaiRoutePreviousOutputSlotCursor`,
  `BlaiRouteOutputSlotCursor`, `blaiRouteSlotCursor`,
  `blaiRouteNextSlotIndex`, `blaiRouteNextSlotCursor`,
  `blaiRoutePreviousOutputSlotCursor`, and `blaiRouteOutputSlotCursor`
  localize the recovered route slot, `slot + 1`, previous-output, and
  output-patch cursor conventions behind bounded typed array indexes.
- `blaiEmitLayerInstructionsInto` and `blaiEmitLayerInstructions` compose the
  recovered CPU-layer bundle, append it with the recovered
  `instruction_encode` order, and update `instCnt` only after the complete
  append fits in the destination stream. `blaiInstructionStreamStartCursor`
  resolves the recovered append start count before the encoder writes
  caller-owned instruction records.
- `blaiInstructionEncodeRequiredInto` and `blaiInstructionEncodeRequired`
  recover the normal/tflite/extra instruction counts appended by
  `instruction_encode`; route descriptor emission accumulates those counts
  through the same typed append-fit helper before committing `instCnt`.
- `blaiEmitFetchLayerInstructionsInto` and
  `blaiEmitFetchLayerInstructions` stage the recovered fetch memory plan,
  dispatch general or route instruction emission, and commit `PSRAM_ctrl`,
  `DRAM_patch_num`, and `instCnt` only when both planning and append bounds
  succeed. `BlaiFetchInputSlotApplyPlan` owns bounded application of planned
  fetch input slots to `SRAM_in[]`, `BlaiFetchOutputSlotApplyPlan` owns
  general fetch application of `SRAM_mid_out` and `SRAM_out[0]`, and
  `BlaiFetchPatchSizeApplyPlan` owns general and route application of
  `PSRAM_patch_size`. `BlaiFetchLayerApplyPlan` owns the general fetch layer-side
  `DRAM_patch_num` projection. The route path uses the recovered route-specific `SRAM_out[]`
  cursor plan before emitting the descriptor loop; `BlaiRouteInputPatchTotalCursor`
  owns the route input patch-count accumulation that seeds the first route
  output slot, and `BlaiRouteFirstOutputSlotPlan` owns that first `SRAM_out[0]`
  slot plus the next patch cursor after `PSRAM_patch_num`.
  `BlaiRouteIntermediateChannelCursor` owns each intermediate cumulative
  channel advance from bounded `cn[]` entries before the corresponding output
  slot is sized, and `BlaiRouteIntermediateOutputSlotPlan` owns the matching
  `SRAM_out[]` commit, output-slot count advance, and next patch cursor.
  `BlaiRouteOutputSlotApplyPlan` owns bounded application of planned route
  output slots to `SRAM_out[]`.
  `BlaiRouteSramLayerApplyPlan` owns the layer-side route application of
  `lineW0`, recovered group normalization, and `DRAM_patch_num`.
- `blaiEncodeCpuLayerInto` and `blaiEncodeCpuLayer` compose the recovered
  `BLAI_encode` wrapper shape: eligibility/allocation gate, instruction scratch
  clear, dispatch selection, staged fetch emission, and failure-state marking.
  The allocator result can still be supplied explicitly for oracle and
  failure-path tests; the `Into` form keeps the encode summary in caller-owned
  storage.
- `blaiEncodeCpuLayerWithAllocatorInto` and `blaiEncodeCpuLayerWithAllocator`
  compose the recovered bounded
  `BLAI_MEM_alloc` planner with `blaiEncodeCpuLayerInto`: it selects and
  applies a typed allocation plan before fetch emission, and routes allocator
  failure through the same wrapper failure state. The `Into` form lets embedded
  callers reuse caller-owned result storage. The focused M0 parser smoke
  exercises the result-returning wrapper on device for a successful single-patch
  route-conv encode and an allocator-failure path that preserves the stream and
  instruction count while clearing `NPU_on`.
- `BlaiMemAllocPatchSegmentCursor` and `blaiMemAllocPatchSegmentCursor` bound
  the recovered 64-entry allocator patch arrays and carry the terminal-patch
  decision for `line_patch_w[]` during line-split planning and
  `wei_patch_out_c[]` during weight/PSRAM patch planning.
  `BlaiMemAllocRouteInputCursor` and `blaiMemAllocRouteInputCursor` localize
  allocator route-channel accumulation from extra input order to bounded `cn[]`
  slots.
- `blaiEncodeDispatch` selects `fetch_BLAI_data_route` only for `ROUTE` or
  `ROUTE_MAX` layers with more than two inputs; all other runnable layers use
  the general emitter path.
- `BlaiFetchDescriptorOperands`, `blaiPlanFetchDescriptorOperandsInto`, and
  `blaiPlanFetchDescriptorOperands` recover the front-end descriptor operand
  decisions as typed diagnostics: the route/general C2 source, aligned first
  input channels through `blaiChannelAlign4`, and each reason an extra
  descriptor is required. The
  ConvMax/RouteMax large-kernel special case is explicit, so weight/group/
  dilation pressure does not accidentally masquerade as an extra-descriptor
  trigger when the SDK only checks line patching. The focused parser smoke now
  exercises second-input C2 alignment, grouped extra-descriptor pressure, and
  the ConvMax combo-max line-patch exception on device.
- `BlaiFetchMemoryPlan`, `blaiPlanFetchMemoryInto`, and
  `blaiPlanFetchMemory` recover the front of `fetch_BLAI_data_general` and
  `fetch_BLAI_data_route`: input PSRAM patch counts, the SDK's bounded
  `PSRAM_patch_size` doubling loop, `SRAM_in` offsets, `SRAM_mid_out`,
  `SRAM_out[0]`, and the resulting `DRAM_patch_num`. The `Into` form keeps
  route-slot planning and fetch emission on caller-owned plan storage.
  `BlaiFetchPatchBudgetPlan` and `blaiFetchPatchBudgetPlan` localize the
  recovered general-vs-route patch budget, including the route descriptor count
  used with `PSRAM_patch_num`. Fixed input patch-count and input-slot arrays
  are indexed through `BlaiU32ArrayIndexCursor`; `BlaiFetchInputPatchCursor`
  owns per-input element counting, patch counting, and total-patch advancement,
  while `BlaiFetchInputSlotCursor` owns the recovered input-slot assignment and
  next-slot advance. `BlaiFetchOutputSlotPlan` owns the final `SRAM_mid_out`,
  `SRAM_out[0]`, and `DRAM_patch_num` cursor layout after input slots have
  been assigned.
- `blaiApplyMemoryPlan` mirrors `gen_npu_inst_layer` after successful encoding:
  it marks `NPU_on`, computes `buf_size` from the layer's allocator-owned
  `DRAM_patch_num` and `PSRAM_patch_size`, then copies input/output slots,
  mid-output slot, patch size, weight slot, and bias slot from `BlaiPsramCtrl`.
- `blaiMarkEncodeFailed` mirrors the wrapper failure state by clearing `NPU_on`.

The functions above recover route-loop emission and bounded wrapper
composition. Remaining control-flow validation is focused on broader
model-specific completion/output oracles.

## Recovered Weight Buffer Planning

The SDK `forward_NPU` wrapper allocates temporary weight and bias buffers only
for `check_weight_layer` layers. The recovered Nim `BlaiWeightBufferPlan`,
`blaiWeightBufferPlanInto`, and `blaiWeightBufferPlan` mirror this sizing:

- `weightBytes = DRAM_nweight * sizeof(fixed_point_t)`, with `fixed_point_t`
  recovered as `int8_t`, so this is the raw weight count in bytes.
- `alignedWeightBytes = ((weightBytes + 3) >> 2) << 2`.
- `biasBytes = DRAM_nbias * BlaiNpuBiasElementBytes`, recovered from
  `sizeof(int)` as four bytes per NPU bias entry, is projected through
  `blaiBiasWordCountBytes` before storage in the uint32 plan field.
- `biasOffset = alignedWeightBytes`; the SDK computes `bias_buf` immediately
  after the aligned weight region.
- `totalBytes = alignedWeightBytes + biasBytes`, checked through
  `BlaiUint32AppendFitResult` so overflow saturates the diagnostic byte count
  instead of wrapping.

The `Into` form fills caller-owned result storage so forward wrapper planning
and weight materialization can embed the same sizing plan without temporary
result objects.

`blaiWeightBufferFitsInto` and `blaiWeightBufferFits` check caller-provided
split buffers against the recovered sizes. The `Into` form reports weight and
bias capacity failures separately.

The register-free planning part of `Load_NPU_weights` is now recovered as
`BlaiNpuWeightLoadPlan`, `blaiPlanNpuWeightLoadInto`, and
`blaiPlanNpuWeightLoad`:

- `weightPadding` is zero for non-TFLite models and `tfInput2Offset` for
  TFLite models, matching the recovered load from `cpu_inst_layer_t + 0xA4`.
- `biasPack` is `BlaiNpuFixedBiasPack` (4) for non-TFLite and
  `BlaiNpuTfliteBiasPack` (1) for TFLite.
- `ROUTE_CONV` temporarily expands `c` by adding `cn[0 ..< input_num - 1]`
  before restoring the layer field.
- grouped convolutions use a temporary integer weight buffer only when
  `groups > 1` and `min(effectiveInputChannels, outC) / groups <=
  BlaiNpuTemporaryGroupChannelLimit` (3); the temporary allocation is
  projected through `blaiNpuTemporaryWeightBytes`, which checks
  `DRAM_nweight * BlaiNpuTemporaryWeightElementBytes` before storing the byte
  count.
- the `Into` form lets forward resource planning and weight materialization
  fill nested caller-owned plan fields directly.
- kernel dispatch selects the recovered helpers for normal `<=3x3`, dilated
  `3x3`, `5x5`, and `7x7`; unsupported size/dilation combinations are
  reported as plan data rather than silently accepted.

The two primitive weight-emission helpers are also recovered:

- `BlaiUint32AppendFitResult`, `blaiUint32AppendFitInto`, and
  `blaiUint32AppendFits` hold the shared recovered cursor/append/required-count
  fit arithmetic for caller-owned uint32 streams.
- `blaiCanNpuAppendWeightBytesInto` / `blaiCanNpuAppendWeightBytes` and
  `blaiCanNpuAppendBiasWordsInto` / `blaiCanNpuAppendBiasWords` guard recovered
  weight and bias stream appends with cursor and required-capacity diagnostics,
  mapping the shared count result into byte- and word-named public fields.
- `blaiNpuDumpZero` mirrors `CONV_DUMP_ZERO`, appending
  `num * PACK * PACK` low-byte padding values to the output weight stream.
- `blaiNpuDumpWeightPixel` mirrors `CONV_WEI_DUMP_PIXEL`, appending one
  `PACK x PACK` tile. Out-of-range output channels or input channels append
  padding; valid cells read
  `(((effectiveInputChannels / groups) * out + (cin - c_start)) * size * size) + wt`.
- `blaiNpuDumpWeights3x3` mirrors `CONV_WEI_DUMP_3x3`. For each
  `size * size` weight tap, it emits one pixel tile only when both `outin` and
  `cin` are aligned to `PACK`; unaligned cursors skip emission for that tap.
  The SDK uses this helper for normal kernels up to `3x3`.
- `blaiNpuDumpWeights3x3Dilated` mirrors `CONV_WEI_DUMP_3x3_DIL`. It uses the
  recovered sparse 5x5 schedule for a dilated 3x3 kernel: zero runs are emitted
  between the nine real 3x3 taps, and the helper exits without writing when
  `outin` or `cin` is not `PACK`-aligned.
- `blaiNpuDumpWeights5x5` mirrors `CONV_WEI_DUMP_5x5`, using the recovered
  5x5 schedule of pixel-tap runs and zero-padding runs. It follows the same
  alignment gate as the dilated helper.
- `blaiNpuDumpWeights7x7` mirrors `CONV_WEI_DUMP_7x7`, using the recovered
  7x7 schedule of loop-compressed pixel-tap runs and zero-padding runs.
- `BlaiNpuWeightScheduleSummary` and `blaiNpuWeightScheduleSummary` expose
  compact shape evidence for the recovered sparse schedules: dilated `3x3`
  has 9 pixel taps plus 72 zero tiles, `5x5` has 25 pixel taps plus 56 zero
  tiles, and `7x7` has 49 pixel taps plus 32 zero tiles. Each schedule emits
  81 `PACK x PACK` tile units.
- `BlaiNpuPackedWeightSizePlan`, `blaiPlanNpuPackedWeightSizeInto`, and
  `blaiPlanNpuPackedWeightSize` expose PACK-expanded NPU weight stream sizing
  before materialization. The plan records active/support status, `PACK`,
  tile units, bytes per tile, output tile groups, input tile groups, overflow,
  and the final byte count. `blaiNpuKernelTapCountInto` and
  `blaiNpuKernelTapCount` own the recovered square-kernel tap projection for
  temporary grouping and simple `3x3` tile counts. `blaiNpuPackTileBytes` owns
  the exact recovered `PACK x PACK` byte projection. Tile and total byte
  diagnostics use `blaiU64SaturatedU32Count`, while the per-tile byte count
  must pass `blaiU64ExactU32Count`; `blaiNpuPackedWeightBytes` is now the
  scalar wrapper around this typed plan.
- `blaiNpuDumpWeightKernel` mirrors the recovered `Load_NPU_weights`
  size/dilation dispatcher. It rejects inactive or unsupported plans and
  forwards `groups` and `weightPadding` from `BlaiNpuWeightLoadPlan` to the
  selected bounded schedule emitter. Weight byte writes now flow through
  `blaiNpuAppendWeightByte` / `blaiNpuAppendRepeatedWeightByte`, so buffer
  writes and cursor advancement are kept behind one checked append boundary.
  `BlaiNpuWeightPackAlignment` and `blaiNpuWeightPackAlignment` localize the
  recovered `outIn`/`cin` PACK-alignment gate shared by the direct, dilated,
  5x5, and 7x7 emitters.
	  Weight output cursors, logical source-weight indexes, bias output cursors,
	  logical source-bias indexes, and temporary grouped-weight destinations are
	  projected through `BlaiNpuWeightSourceProjection`,
	  `BlaiNpuWeightPackEntryCursor`, `blaiNpuWeightBufferCursor`,
	  `blaiNpuWeightSourceCursor`, `blaiNpuBiasBufferCursor`,
	  `blaiNpuBiasSourceCursor`, and
	  `blaiNpuTemporaryWeightCursor` before any caller-owned materialization buffer
	  is indexed.
  `BlaiNpuWeightKernelDispatchEvidence` and
  `blaiNpuWeightKernelDispatchEvidence` expose a compact branch-coverage
  contract for normal `3x3`, dilated `3x3`, `5x5`, `7x7`, unsupported,
  zero-pack, unaligned no-commit, and short-buffer rejection behavior; the M0
  model smoke checks those recovered branches on device.
- `BlaiNpuWeightGroupPartition` and `blaiNpuWeightGroupPartition` localize the
  grouped output/input channel partition recovered from `Load_NPU_weights`.
  `BlaiNpuWeightChannelRangePlan`, `blaiPlanNpuWeightChannelRangeInto`, and
  `blaiPlanNpuWeightChannelRange` expose the resulting `c_start` / `c_end`
  calculation with named group-count, per-group channel-count, selected-group,
  and validity diagnostics. `blaiNpuWeightChannelRange` remains the tuple
  compatibility wrapper around the typed plan.
- `blaiNpuDumpBiasPack` mirrors the recovered bias-pack loop. It emits
  `biasPack` signed 32-bit entries at aligned output channels and zero-pads
  entries beyond `out_c`; `BlaiNpuBiasPackCursor` and
  `BlaiNpuBiasPackEntryCursor` localize the alignment gate and per-entry output
  channel projection. Each word is appended through
  `blaiNpuAppendBiasWord` after the same typed fit check used by the public
  bias append helpers.
- `blaiNpuDumpWeightStreamInto` and `blaiNpuDumpWeightStream` run the
  recovered `outin` / `cin` loop around the dispatcher and bias-pack emitter
  for plans that do not need temporary grouped reordering. The `Into` form
  reports success and output cursors in caller-owned result storage.
- `BlaiNpuTemporaryGroupPlan`, `blaiPlanNpuTemporaryGroupsInto`, and
  `blaiPlanNpuTemporaryGroups` expose the grouped temporary reorder dimensions:
  original group count, temporary group count as `min(c, out_c) / PACK`,
  original input/output channels per group, and kernel tap count.
  `blaiNpuMaterializeTemporaryGroupedWeights` consumes that typed plan to
  mirror the SDK `int` reorder buffer, preserving weights for matching original
  input/output groups and filling cross-group entries with `weightPadding`.
	  `BlaiNpuTemporaryGroupSourceCursor` owns the recovered source-group
	  projection and same-group gate. Source and destination positions then use
	  the same checked `BlaiNpuWeightSourceProjection`; individual writes go through
	  `blaiStoreTemporaryGroupedWeight`, which keeps the temporary reorder
	  destination bounds check beside the store.
- `blaiNpuDumpWeightStreamWithTemporaryInto` and
  `blaiNpuDumpWeightStreamWithTemporary` wrap the temporary materializer and
  then run the bounded stream loop with the temporary group count, again
  reporting stream cursors through caller-owned result storage.
- `blaiNpuMaterializeWeightBuffersInto` and
  `blaiNpuMaterializeWeightBuffers` are the caller-owned boundary equivalent to
  `Load_NPU_weights` after `forward_NPU` has obtained weight, bias, and optional
  temporary scratch buffers. They validate recovered buffer sizes, run the
  appropriate direct or temporary stream path, and report output cursors. The
  result also preserves split weight/bias fit diagnostics and required/provided
  temporary scratch element counts. `BlaiNpuWeightMaterializeBlock`,
  `BlaiNpuWeightMaterializeReadiness`,
  `blaiNpuWeightMaterializeReadinessInto`, and
  `blaiNpuWeightMaterializeReadiness` expose the first blocking gate:
  inactive, unsupported, short weight/bias buffers, short temporary scratch, or
  stream materialization failure. The `Into` form keeps the aggregate result in
  caller-owned storage.

The `CONV_WEI_DUMP_*` helper schedules, direct `Load_NPU_weights` dispatcher,
bias pack emission, grouped channel bounds, grouped temporary materialization,
and bounded caller-owned materialization are now recovered. The remaining work
above `Load_NPU_weights` is wiring this materializer into the broader
`forward_NPU` execution path once model buffer ownership and instruction
generation are recovered.

The CPU-side model weight loader in `blai_cpu_load_weights` is also partially
recovered as sizing helpers over `BlaiCpuInstLayer64`:

- `blaiCpuLoadUsesWeights`: `CONVOLUTIONAL`, `MATMUL`, `CONV_MAX`,
  `ROUTE_CONV`, and `SSD` consume weight stream bytes.
- `blaiCpuLoadUsesBiases`: `CONVOLUTIONAL`, `MATMUL`, `CONV_MAX`, and
  `ROUTE_CONV` consume bias stream entries; `SSD` does not.
- `blaiEffectiveGroups`: zero groups become one before weight sizing.
- `blaiEffectiveKernelW` / `blaiEffectiveKernelH`: detail-form `size_x` /
  `size_y` override square `size` when present.
- `blaiCpuWeightInputChannels`: starts with `c` and adds `cn[0]` when
  `input_num > 1`.
- `blaiCpuWeightElementCount`: for `SSD`, `w * h * c`; otherwise
  `kernel_w * kernel_h * out_c * input_c / groups`.
- `blaiCpuBiasElementCount`: `out_c` for bias-consuming layers.
- `blaiCpuBiasBytesPerElement`: one byte for fixed-point models, four bytes for
  TFLite models.
- `blaiFindNextCpuWeightLayer` / `blaiFindNextCpuBiasLayer`: scan forward to
  the next `DSP_on` layer that consumes that stream.
- `blaiCpuWeightStreamPlanInto` / `blaiCpuWeightStreamPlan` and
  `blaiCpuBiasStreamPlanInto` / `blaiCpuBiasStreamPlan`: package the selected
  layer index, layer type, recovered sizing inputs, storage width, and final
  byte count into caller-owned plan storage before stream reads or stores. The
  recovered signed layer cursor is checked with `blaiI32ArrayIndexCursor` before
  indexing caller-owned raw or parsed layer tables.
- `blaiCpuStreamCursor`, `BlaiCpuStreamCursorStep`,
  `blaiCpuStreamCursorStepInto`, `blaiCpuStreamCursorStep`,
  `blaiCpuWeightStreamSegmentInto` / `blaiCpuWeightStreamSegment`, and
  `blaiCpuBiasStreamSegmentInto` / `blaiCpuBiasStreamSegment`: recover the SDK
  `current_layer` / `cur` cursor advancement across complete weight and bias
  streams, including short-stream detection and zero-length stream records at
  the end of a backing buffer. Weight and bias segment builders share the typed
  cursor-step helper after stream-specific layer selection; segment start-layer
  resolution goes through `blaiCpuStreamStartLayerCursor` so the SDK's negative
  cursor-as-zero rule is preserved before indexing Nim layer tables.
- `BlaiCpuStreamTotals`, `blaiCpuStreamTotalsInto`, and
  `blaiCpuStreamTotals`: compute the complete model stream sizes and the number
  of weight/bias-consuming CPU records implied by the layer table, including
  the first layer that owns each CPU stream. Forward model resource planning
  stores the same totals alongside the legacy byte fields.
- `blaiCpuWeightStreamTotalBytes` / `blaiCpuBiasStreamTotalBytes`: compatibility
  wrappers over the typed totals result.
- `BlaiCpuByteWindow`, `blaiCheckedIntByteWindow`,
  `blaiCpuBiasReadWindow`, and `blaiReadCpuBias`: reconstruct the SDK
  little-endian accumulated bias value from one or four bytes through a checked
  typed byte window and `BlaiLe32ByteCursor`. CPU bias and stream windows share
  the same recovered uint32 range to Nim `int` slice conversion, backed by the
  typed `BlaiUint32AddressRangeFitResult` bus-range boundary.
- `blaiStoreCpuWeightsI8Into` / `blaiStoreCpuWeightsI8`,
  `blaiStoreCpuWeightsI32Into` / `blaiStoreCpuWeightsI32`, and
  `blaiStoreCpuWeightValuesInto` / `blaiStoreCpuWeightValues`: copy one
  planned weight stream segment into caller-owned typed buffers, sign-extending
  `fixed_point_t` bytes for `int` storage through `BlaiCpuStreamWindow` typed
  source views. The `Into` forms report storage compatibility, bounds, and
  store status in caller-owned result storage.
- `blaiStoreCpuBiasesInto` / `blaiStoreCpuBiases`: copies one planned bias
  stream segment into a caller-owned `int32` buffer using the SDK
  little-endian accumulation rule through the same checked stream window and
  `BlaiLe32ByteCursor`, with bounds and store status reported through
  caller-owned result storage. `blaiCpuBiasElementWidth` owns the exact
  recovered `bytesPerElement` projection and the 32-bit little-endian lane
  limit before the store loop indexes the stream window.
- `blaiStoreFixedCpuBiasesInto` / `blaiStoreFixedCpuBiases`: copies the
  fixed-point one-byte bias stream form into caller-owned `int8` buffers for
  recovered fixed-reference execution, reporting storage width, bounds, and
  store status through caller-owned result storage.

The actual heap allocation and assignment to `cpu_inst_layer_t.weights` /
`biases` is still outside this HAL slice; the recovered helpers expose the
stream accounting and bounded buffer writes without adding blob dependencies or
pointer arithmetic.

## Recovered Forward Wrapper Planning

The SDK `forward_NPU` wrapper is represented by `BlaiForwardNpuPlan`,
`blaiPlanForwardNpuInto`, and `blaiPlanForwardNpu` for the decisions that
happen after instruction generation has marked a layer runnable. The `Into`
forms let higher-level planners fill caller-owned nested plan storage directly:

- The plan is runnable only when `NPU_on` is set, matching the SDK early return
  after `gen_npu_inst_layer`.
- `firstLayer` mirrors the `l_current == 0` flag passed to
  `blai_npu_layer_config`.
- `patchSize` mirrors `l->DRAM_patch_size`.
- `weightBuffer` embeds the recovered temporary `Load_NPU_weights` allocation
  sizing through `blaiWeightBufferPlanInto`.
- `inputs`, `inputCleanRanges`, `output`, `outputInvalidateRange`, and
  `midOutputInvalidateRange` compose the recovered tensor staging/readback and
  cache range plans.
- `blaiForwardNpuDataBufferPlanInto` and `blaiForwardNpuDataBufferPlan` fold
  every recovered DATA-buffer input, output, mid-output, and cache-maintenance
  range into caller-owned sizing result storage through the shared
  `BlaiUint32AppendFitResult` cursor/append helper, preserving overflow
  diagnostics without raw offset arithmetic.
- `blaiForwardNpuBufferFitsInto` and `blaiForwardNpuBufferFits` check every
  recovered DATA-buffer input, output, mid-output, and cache-maintenance range
  before a caller attempts staged copies or hardware execution. The `Into` form
  reports whether the DATA plan overflowed or the caller buffer was short.
- `blaiMaterializeForwardNpuWeightsInto` and
  `blaiMaterializeForwardNpuWeights` mirror the weight-layer step after the
  SDK runnable gate. They skip non-weight layers, refuse `NPU_on == 0` layers,
  and delegate weight-layer materialization to the caller-owned
  `Load_NPU_weights` replacement. `BlaiForwardNpuWeightMaterializeReadiness`,
  `blaiForwardNpuWeightMaterializeReadinessInto`, and
  `blaiForwardNpuWeightMaterializeReadiness` expose the runnable/weight-layer
  materialization gate as typed result state with
  `BlaiForwardNpuWeightMaterializeBlock` first-block reasons. The focused M0 model smoke now
  exercises this boundary directly on device for regular weight/bias
  materialization, route-layer no-weight skipping, inactive-layer rejection, and
  temporary grouped-weight materialization.
- `blaiPlanForwardNpuRunInto` and `blaiPlanForwardNpuRun` compose the
  recovered pre-execution run plan:
  checked DATA-buffer fit, cache clean/invalidate ranges in SDK order,
  `blai_npu_layer_config` arguments, first-layer unsigned-input reset
  behavior, and the SDK null weight/bias pointer convention for non-weight
  layers. The `Into` form lets higher-level model execution planners fill
  caller-owned nested run-plan storage directly.
- `blaiForwardNpuRunConfigReadinessInto` and
  `blaiForwardNpuRunConfigReadiness` split that run-plan `configurable` gate
  into typed diagnostics for runnable state, DATA-buffer fit, required
  instruction/DATA addresses, and optional weight/bias buffer addresses. The
  readiness result exposes the first failed gate as
  `BlaiForwardNpuRunConfigBlock`.
- `blaiForwardPreparedRunReadinessInto` /
  `blaiForwardPreparedRunReadiness` and
  `blaiForwardModelPrepareReadinessInto` /
  `blaiForwardModelPrepareReadiness` carry the same first-block style through
  encoded layer preparation and model-wide workspace preparation as
  `BlaiForwardPreparedRunBlock` and `BlaiForwardModelPrepareBlock`.
- `blaiCacheRangeAddress`, `blaiApplyCacheRange`,
  `blaiApplyForwardNpuCacheRangesInto`, and
  `blaiApplyForwardNpuCacheRanges` translate those DATA-buffer-relative cache
  ranges into absolute addresses, reject 32-bit address wraparound, and call the
  recovered T-Head per-address cache clean/invalidate wrappers on BL808 targets.
  `BlaiUint32AddressRangeFitResult`, `blaiUint32AddressEndExclusive`,
  `blaiUint32AddressRangeEndFits`, `blaiUint32AddressRangeFitInto`,
  `blaiUint32AddressRangeFit`, `blaiUint32AddressRangeFits`, and
  `blaiUint32RelativeAddressRangeFits` keep absolute and DATA-relative bus range
  checks in one typed boundary shared by cache and temporary weight/bias staging.
- `npuRunConfigured` mirrors the SDK inference wrapper for an already
  configured instruction stream: preserve clock configuration while enabling the
  gate, start/resume the BLAI engine, poll the recovered interrupt status bit,
  acknowledge completion, and disable the clock gate. It fails closed with
  `npuUnsupported` until a nonzero instruction stream address has been supplied.
  `blaiExecuteForwardNpuRun` combines this with the recovered layer config and
  cache-range sequence. `BlaiForwardNpuExecuteOutcome`,
  `blaiForwardNpuExecuteOutcomeInto`, and `blaiForwardNpuExecuteOutcome` expose
  the final runnable/configurable/cache/wait gate as typed result state. The
  focused M0 model smoke also validates that an overflowing pre-start clean
  range returns a non-started `npuBusy` cache-fit failure instead of entering
  the live wait path.
- `npuRunLayer` is retained as a compatibility wrapper over
  `npuRunConfigured`; it no longer returns `npuUnsupported` unconditionally, but
  it still requires callers to provide a validated encoded instruction stream.
  `NpuLayerRunReadiness`, `NpuLayerRunPlan`, `NpuLayerRunResult`,
  `npuLayerRunReadinessInto`, `npuLayerRunReadiness`,
  `npuPlanLayerRunInto`, `npuPlanLayerRun`, `npuRunLayerInto`, and
  `npuRunLayerResult` expose that fail-closed gate and the derived completion
  wait policy as typed state before touching the live wait routine, while
  preserving the legacy `NpuError` return wrapper. The M0 NPU smoke checks the
  configured-stream state after layer-buffer setup, applies the recovered
  input/weight/bias address registers, and clears stream state so stale streams
  cannot be run accidentally. The focused M0 model smoke also confirms the
  legacy dimension-based convolution facade records a typed compatibility plan
  with first-block diagnostics for the address-backed instruction-stream gate
  and the empty address-subset gate. The plan also records whether legacy
  dimensions are nonzero and representable by the recovered single-size,
  single-stride descriptor shape before reporting the remaining encoded-stream
  gate; nonsquare kernel, stride, or padding arguments now fail closed with a
  typed dimension block instead of being conflated with valid-but-unencoded
  plans. `NpuConvCompatibilityApplyResult`, `NpuConvCompatibilityEvidence`,
  `NpuInstructionStreamGuardEvidence`,
  `npuApplyConvLayerCompatibilityInto`, `npuConfigureConvLayerResult`,
  `npuConvCompatibilityEvidence`, and `npuInstructionStreamGuardEvidence`
  expose the register-backed side effects from that facade, including whether
  layer buffers, the input buffer, and stream-state clearing were applied. The
  plan, apply result, and evidence also separate input/weight/bias as
  register-backed addresses from the legacy output address that remains
  plan-only until encoded stream generation owns DATA layout. The focused model
  smoke checks those side-effect flags through the result-returning configure
  wrapper, proves
  configured wrapper/readiness state is runnable before the facade clears it,
  records the clean first-block and timeout-bearing readiness predicates on both
  sides of that invalidation, and confirms `npuRunLayerResult` reports a
  non-started unsupported result when no encoded stream is configured.
- `blaiForwardModelRunSequenceReadinessInto` and
  `blaiForwardModelRunSequenceReadiness` split the model run-sequence
  `workspaceReady` gate into typed diagnostics for supported resources,
  supported/fitting workspace, and required instruction/DATA workspace segments.
  Run-sequence readiness, configurability, and plans now expose
  `BlaiForwardModelRunSequenceReadinessBlock` /
  `BlaiForwardModelRunSequenceBlock` first-block reasons and capture the first
  blocked layer's `BlaiForwardNpuRunConfigReadiness`, so callers can
  distinguish resource/workspace gates, short layer storage, missing
  instruction/DATA buffers, and missing weight/bias workspace when a model is
  not fully configurable.
- `blaiForwardModelWorkspaceExecuteReadinessInto` and
  `blaiForwardModelWorkspaceExecuteReadiness` add the caller-owned workspace byte
  fit to that pre-execution state, separating a runnable reusable-workspace model
  from one whose backing storage is too short to materialize safely. The
  readiness exposes the first pre-materialization block as
  `BlaiForwardModelWorkspaceExecuteReadinessBlock`. The
  execution result also reports caller-owned layer-table fit against the model
  resource plan before any per-layer workspace materialization is attempted.
- `NpuBusyStatusResult`, `npuBusyStatusFromGeneralCfgInto`,
  `npuBusyStatusFromGeneralCfg`, `npuBusyStatusInto`, and `npuBusyStatus`
  decode the recovered `BALI_GENERAL_CFG` AXI write/read idle status bits into
  typed state. The legacy `npuIsBusy` boolean now delegates through that typed
  projection. The focused model smoke exercises both synthetic busy and idle
  register states.

The plan intentionally does not own the SDK FreeRTOS mutex/semaphore layer. Full
model execution validation still requires running generated instruction streams
on hardware and comparing outputs with known CPU-reference results.

Validation should include simple hardware model fixtures: 1x1, 3x3, 5x5, and
7x7 convolutions, dilated 3x3, grouped/depthwise convolutions, route/concat into
route-conv, and channel-alignment/padding cases with known CPU reference
outputs.

## Recovered CPU Reference Fixtures

The first fixture oracle is recovered from SDK `forward_CONVOLUTIONAL` and its
fixed-point helpers:

- `BlaiReferenceConv2d` describes HWC int8 input, output-channel-major weights,
  kernel size, stride, dilation, groups, fixed-point scale widths, activation,
  and first-layer unsigned-input handling.
- `blaiReferenceConv2d` mirrors the SDK loop structure for valid convolution
  fixture shapes: output channel, output row, output column, grouped input
  channels, then centered kernel taps with zero padding. Input samples and
  output HWC addresses are projected through `blaiHwcIndex`.
- `BlaiReferenceConvBlock` and `blaiReferenceConvReadinessInto` report typed
  first-block diagnostics for input shape, odd-kernel support, group shape, and
  caller-owned input, weight, bias, and output buffers.
  `blaiU64SaturatedMul`, `blaiU64SaturatedAdd`,
  `blaiReferenceHwcElementCount`, `blaiReferenceHwcStrideExtent`,
  `blaiReferenceRouteInputExtent`, `blaiReferenceScaledDimExtent`,
  `blaiReferenceUpsampleOutputExtent`,
  `blaiReferenceTfliteRouteWSegmentExtent`,
  `blaiReferenceMatmulActivationElements`,
  `blaiReferenceMatmulWeightElements`,
  `blaiReferenceDepthwiseOutputChannels`,
  `blaiReferencePaddedDim`,
  `blaiReferenceTransposeLkInputElements`,
  `blaiReferenceTransposeLkOutputChannels`,
  `blaiReferenceTransposeLkOutputElements`,
  `blaiNpuPackedWeightGroupBytes`,
  `blaiReferenceGroupedKernelElementCount`, and
  `blaiReferenceKernelElementCount` keep recovered HWC, strided-HWC,
  route-sidecar HWC, route-W axis segment, MATMUL matrix, depthwise
  output-channel, PAD dimensions, TRANSPOSELK sequence/channel/window,
  upsample-expanded output, PACK-expanded weight tile groups, grouped-kernel,
  depthwise-kernel, TFLite/NMSIS convolution, max-pool, TFLite unary, and
  shortcut same-shape element-count projections, plus parsed-model activation,
  TFLite reshape, TFLite transpose, and pre-transconv HWC buffer extents, from
  wrapping before they are checked
  against caller-owned buffers.
- Fixed-point convolution, conv-max, matmul, shortcut, depthwise, TFLite
  convolution, TFLite dequantize, TFLite logistic, TFLite reshape, TFLite
  shortcut, TFLite transpose-LK, maxpool, upsample, route-upsample, route-max,
  route-concat, and TFLite route readiness paths project their recovered uint64
  element counts through `blaiU64ExactU32Count` before storing uint32 diagnostic
  counts. TFLite mean spatial-element diagnostics use `blaiU64ExactI32Count`
  because the stored count is later consumed by recovered int32 arithmetic.
  CPU stream byte-span diagnostics that mirror SDK-style saturated reporting
  use `blaiU64SaturatedU32Count`.
  Route-family "largest input required" diagnostics use
  `blaiU64MaxExactU32Count` so the max update stays behind the same recovered
  uint32 ABI guard.
- `blaiFixed32ToFixed8`, `blaiFixed8ToFixed32`, and
  `blaiApplyReferenceActivation` recover the SDK fixed-point rounding,
  saturation, bias expansion, ReLU, ReLU6, and leaky-ReLU behavior used by that
  path.
- `blaiReferenceInputSampleValue` names the SDK first-layer unsigned-input
  projection for int8 samples, replacing direct signed-to-uint8 casts in the
  recovered convolution, conv-max, and matmul reference paths.
- `BlaiReferenceConvMax2d` and `blaiReferenceConvMax2d` recover the
  deterministic odd-kernel SDK `forward_CONV_MAX` path: fixed-point convolution
  windows use the same arithmetic as `forward_CONVOLUTIONAL`, then adjacent
  2x2 windows are folded into one output slot by writing the even/even window
	  and max-updating the remaining windows. Input samples and folded output HWC
	  addresses are projected through `blaiHwcIndex`; grouped weights use the
	  recovered output-channel-major matrix through `blaiRowMajorIndex`.
	  `BlaiReferenceConvMaxBlock` and
  `blaiReferenceConvMaxReadinessInto` report typed first-block diagnostics for
  input shape, odd-kernel support, group shape, folded-output shape, and
  caller-owned input, weight, bias, and output buffers. A compact parsed
  single-layer `CONV_MAX` case is exercised on-device with byte-weight and
  one-byte-bias cursor checks.
- `BlaiReferenceFixedLayerResult` and `blaiReferenceFixedLayer2d` provide a
  bounded dispatch layer from recovered `cpu_inst_layer_t` records into the
  fixed-point CPU fixtures for convolution, conv-max, matmul, maxpool, upsample,
  and shortcut. Unsupported layer kinds are reported as data rather than routed
  through SDK pointer fields. `BlaiReferenceFixedLayerBlock` preserves the first
  dispatch-level block and the leaf fixture first-block reason for failed
  dispatches. Compact convolution, conv-max, matmul, maxpool, and upsample
  dispatch paths are exercised on-device by the M0 NPU smoke.
- `BlaiReferenceTfliteLayerResult` and the TFLite dispatch helpers preserve
  typed dispatch-level blocks plus leaf first-block reasons for recovered
  uint8 and float-output CPU layer records, including route-family and reshape
  leaf diagnostics. This keeps direct tensor fixtures, typed sidecar transform
  fixtures, and unsupported layer guards observable without falling back to SDK
  pointer fields.
- `BlaiReferenceMatmul2d` and `blaiReferenceMatmul2d` recover the SDK
  `forward_MATMUL` scalar fixed-point path: H-by-C int8 input is multiplied by
  output-channel-major weights, per-output bias and activation are applied, and
  the result is converted with `fixed32_to_fixed8`. The SDK loops over `w` but
  indexes input/output without `win`; the fixture exposes the resulting
  H-by-outC behavior. Input and output activations are projected as height-by-1
  HWC tensors through `blaiHwcIndex`, while weights use the recovered
  output-channel-major matrix through `blaiRowMajorIndex`.
  `BlaiReferenceMatmulBlock` and
  `blaiReferenceMatmulReadinessInto` report typed first-block diagnostics for
  input shape and caller-owned input, weight, bias, and output buffers. A
  compact parsed single-layer `MATMUL` case and the readiness diagnostics are
  exercised on-device with byte-weight and one-byte-bias cursor checks.
- `BlaiReferenceDepthwiseConv2d` and `blaiReferenceDepthwiseConv2d` recover the
  SDK TFLite/NMSIS depthwise fixture path used by
  `forward_DEPTHWISE_CONVOLUTIONAL_tflite_nmsis`: HWC uint8 tensors,
  kernel-tap by output-channel kernel layout, channel multiplier,
  input/filter/output offsets, scalar output multiplier/shift copied to every
  output channel, activation clamp, and the SDK/NMSIS requantization helper.
  Input samples and output writes are projected through `blaiHwcIndex`; kernel
  taps and output channels are projected through `blaiRowMajorIndex`.
  `BlaiReferenceDepthwiseConvBlock` and
  `blaiReferenceDepthwiseConvReadinessInto` report typed first-block diagnostics
  for input/output shape and caller-owned input, kernel, bias, and output
  buffers. A compact 1x1 depthwise/NMSIS fixture and the readiness diagnostics
  are exercised on-device by the M0 NPU smoke.
- `BlaiReferenceTfliteConv2d` and `blaiReferenceTfliteConv2d` recover the SDK
  `forward_CONVOLUTIONAL_tflite_nmsis` scalar reference behavior:
  output-channel-major kernels, HWC uint8 tensors, input/filter/output offsets,
  scalar output multiplier/shift copied to every output channel, per-output
  bias, and activation clamp. Input samples and output writes are projected
  through `blaiHwcIndex`; kernel taps, input-channel columns, and output-channel
  rows are projected through `blaiRowMajorIndex`. `BlaiReferenceTfliteConvBlock` and
  `blaiReferenceTfliteConvReadinessInto` report typed first-block diagnostics
  for input/output shape and caller-owned input, kernel, bias, and output
  buffers. A compact 1x1 TFLite/NMSIS convolution fixture and the readiness
  diagnostics are exercised on-device by the M0 NPU smoke.
- `BlaiReferenceTfliteScalarConv2d` and
  `blaiReferenceTfliteScalarConv2d` recover the deterministic odd-kernel SDK
  `forward_CONVOLUTIONAL_tflite` path: stride 2 starts at row/column 1, grouped
  HWC uint8 input is sampled through `blaiHwcIndex` with `-tf_input1_offset`,
	  out-of-range taps use raw zero padding, grouped kernels use the recovered
	  output-channel-major matrix through `blaiRowMajorIndex`, weights are adjusted
	  by `-tf_input2_offset`, optional int32 bias is added, and the result is
	  requantized, offset, activation-clamped, and written through `blaiHwcIndex`.
  `BlaiReferenceTfliteScalarConvBlock` and
  `blaiReferenceTfliteScalarConvReadinessInto` report typed first-block
  diagnostics for odd-kernel support, input/group/output shape, and
  caller-owned input, kernel, bias, and output buffers.
- `BlaiReferenceTfliteScalarConvMax2d` and
  `blaiReferenceTfliteScalarConvMax2d` recover the deterministic odd-kernel SDK
  `forward_CONV_MAX_tflite` path: each scalar TFLite convolution window is
  computed with the same quantization rules, then adjacent 2x2 windows are
  folded into one output slot by writing the even/even window and max-updating
	  the remaining windows. Input samples and folded output HWC addresses are
	  projected through `blaiHwcIndex`; grouped kernels use the same recovered
	  output-channel-major matrix through `blaiRowMajorIndex`.
	  `BlaiReferenceTfliteScalarConvMaxBlock` and
  `blaiReferenceTfliteScalarConvMaxReadinessInto` report typed first-block
  diagnostics for odd-kernel support, input/group/folded-output shape, and
  caller-owned input, kernel, bias, and output buffers. A compact parsed
  single-layer `CONV_MAX_tflite` case is exercised on-device with byte-weight
  and int32-bias cursor checks.
- `BlaiReferenceTfliteLayerResult` and `blaiReferenceTfliteLayer2d` provide a
  bounded dispatch layer from recovered TFLite `cpu_inst_layer_t` records into
  scalar convolution, conv-max, maxpool, average-pooling, and shortcut fixtures.
  Route-family records remain on their sidecar-aware plan helpers because they
  require typed multi-input storage.
- `BlaiReferenceTfliteParsedLayerResult` and
  `blaiReferenceTfliteParsedLayer2d` execute one parsed-state TFLite
  CPU-reference layer from caller-owned tensor buffers and CPU weight/bias
  streams, advancing the same typed stream cursors used by the recovered
  forward path. Route-family records preserve typed sidecar storage; unsupported
  graph/runtime cases are reported instead of following SDK pointer fields.
  `blaiReferenceTfliteParsedSingleLayer2d` provides the same bounded stream and
  sidecar boundary for one known layer without requiring an array of full
  parsed-layer states, keeping small firmware validation paths inside the M0
  stack budget.
- `BlaiReferenceFixedParsedLayerResult` and
  `blaiReferenceFixedParsedLayer2d` provide the matching parsed-state bridge for
  fixed-point fixtures that use recovered byte-weight CPU streams. It decodes
  fixed weights and one-byte biases into caller-owned buffers, advances the same
  typed stream cursors, dispatches route and route-max records through recovered
  typed sidecar storage, and reports unsupported non-byte fixed weight storage
  separately from missing stream data instead of fabricating SDK pointers.
  `blaiReferenceFixedParsedSingleLayer2d` exposes the same low-footprint
  single-layer boundary for firmware smoke tests and other stack-constrained
  validation code.
- `BlaiReferenceFixedParsedModelResult` and
  `blaiReferenceFixedParsedModel2d` sequence simple linear fixed-point parsed
  models through that layer bridge with caller-owned scratch buffers and exact
  CPU stream consumption checks. Inactive parsed entries are skipped without
  consuming streams, empty models are valid only with empty streams, and TFLite
  inputs are rejected at the fixed oracle boundary. A sidecar overload accepts
  per-layer second-input source plans for simple shortcut fixtures, allowing the
  original model input or previous activation to be supplied without SDK pointer
  state. `BlaiReferenceFixedParsedModelValidity`,
  `blaiReferenceFixedParsedModelValidityInto`, and
  `blaiReferenceFixedParsedModelValidity` split strict fixed oracle validity
  into runnable state, layer completion, exact CPU weight-stream consumption,
  and exact CPU bias-stream consumption. Executed layer failures also capture
  the first failed `BlaiReferenceFixedParsedLayerResult`, while terminal
  validity failures such as trailing CPU streams deliberately leave that capture
  unset. `BlaiReferenceFixedParsedBufferPlan`,
  `blaiReferenceFixedParsedBufferPlanInto`, and
  `blaiReferenceFixedParsedBufferPlan` report typed `BlaiCpuStreamTotals`,
  legacy CPU stream byte totals, and maximum decoded byte-weight/one-byte-bias
  workspace sizes needed by that oracle, while flagging non-byte fixed weight
  storage as unsupported. `BlaiReferenceFixedParsedBufferSupport`,
  `blaiReferenceFixedParsedBufferSupportInto`, and
  `blaiReferenceFixedParsedBufferSupport` expose activation-shape and
  weight-storage support as one typed predicate, including the first layer that
  failed activation-shape or fixed weight-storage support. Checked-oracle
  readiness carries the same first-offender indices alongside its first-block
  reason, so callers can reject unsupported models without retaining the full
  buffer plan. The plan also reports shape-only activation workspace sizes for
  supported simple linear fixtures: maximum ping-pong scratch elements for
  intermediate active layers and final output elements for the last active
  layer.
  `BlaiReferenceFixedParsedSingleLayerReadiness`,
  `blaiReferenceFixedParsedSingleLayerReadinessInto`, and
  `blaiReferenceFixedParsedSingleLayerReadiness` split the low-footprint
  single-layer oracle execution gate into active layer, fixed-mode, stream
  cursor, weight-storage, layer support, tensor-fit state, and the nested
  fixed reference dispatch first-block reason.
  `BlaiCpuStreamCursorCompareResult`, `blaiCompareCpuStreamCursorInto`, and
  `blaiCompareCpuStreamCursor` provide typed comparison evidence for recovered
  CPU stream advancement, preserving expected/actual layer index and byte
  offset diagnostics for weight and bias cursor checks.
  `BlaiInt8OutputCompareResult`, `blaiCompareInt8OutputsInto`, and
  `blaiCompareInt8Outputs` provide allocation-free fixed-output oracle
  comparison evidence for model validation, including length agreement, total
  compared elements, trailing length delta, mismatch count, and first-mismatch
  values. `BlaiInt8OutputRawByteProjectionResult`,
  `blaiProjectInt8OutputRawBytesInto`, and
  `blaiProjectInt8OutputRawBytes` project fixed CPU-oracle `int8` tensors into
  raw NPU workspace bytes with typed output-fit and first-block diagnostics, so
  generated fixed fixtures can feed the byte-oriented live readback validators
  without casts or pointer reinterpretation.
  `BlaiInt8OutputRawByteCompareResult`,
  `blaiCompareInt8OutputRawBytesInto`, and
  `blaiCompareInt8OutputRawBytes` compose that projection with the existing
  uint8 compare evidence for raw NPU readback, promoting projection length
  diagnostics, compared/trailing counts, and first-mismatch byte diagnostics to
  the top-level result. `BlaiUint8OutputRawByteProjectionResult`,
  `blaiProjectUint8OutputRawBytesInto`, and
  `blaiProjectUint8OutputRawBytes` provide the matching TFLite path by copying
  uint8 CPU-oracle output into caller-owned raw workspace expected bytes with
  typed fit and trailing-byte diagnostics.
  `blaiReferenceFixedParsedBuffersFitInto` and
  `blaiReferenceFixedParsedBuffersFit` check caller-owned model input, CPU
  stream, decoded, scratch, and output buffers against that plan before
  execution. The fit result carries required and caller-provided CPU stream
  totals alongside the per-buffer booleans. `blaiReferenceFixedParsedPreflightInto` and
  `blaiReferenceFixedParsedPreflight` derive the plan from parsed layer state
  and return both the plan and fit result for one oracle call.
  `BlaiReferenceFixedParsedCheckedReadiness`,
  `blaiReferenceFixedParsedCheckedReadinessInto`, and
  `blaiReferenceFixedParsedCheckedReadiness` make the checked-oracle execution
  gate explicit from activation-shape support, weight-storage support, and
  buffer fit, including a typed first blocking gate.
  `blaiReferenceFixedParsedCheckedModel2d` wraps that preflight gate around the
  sequential oracle, returning without execution when any caller-owned buffer is
  too small. This is intentionally narrower than the full graph runtime:
  layer-level route sidecars are supported, but model-level route graph
  ownership remains out of scope until its activation storage is recovered.
  `BlaiReferenceFixedParsedEndToEndResult`,
  `blaiReferenceFixedParsedEndToEndInto`, and
  `blaiReferenceFixedParsedEndToEnd` combine the checked oracle, strict stream
  consumption, completion count, first checked gate, and final int8 output
  comparison into one fixture-validity result for compact model validation.
- `BlaiReferenceTfliteParsedModelResult` and
  `blaiReferenceTfliteParsedModel2d` sequence simple parsed-state TFLite HWC
  models through that layer oracle with caller-owned ping-pong scratch buffers
  and final output storage. This gives hardware validation a pure CPU oracle for
  linear fixture models without adopting the SDK heap or pointer-backed graph
  runtime. Inactive parsed entries are skipped without consuming input or
  streams, so the first active layer still reads the caller-provided model
  input. The result also reports total CPU weight/bias stream bytes and whether
  each stream was consumed exactly, so fixture validation can reject trailing
  oracle data without conflating that with layer execution success.
  `modelValid` is the strict fixture gate: the run must be TFLite-runnable,
  every active layer must complete, and both CPU streams must be consumed
  exactly. `BlaiReferenceTfliteParsedModelValidity`,
  `blaiReferenceTfliteParsedModelValidityInto`, and
  `blaiReferenceTfliteParsedModelValidity` expose that strict validity gate as
  typed terminal state. `firstFailure` classifies the first failed active layer as a stream
  cursor mismatch, unavailable stream data, unsupported layer, tensor-fit
  failure, or a missing planned previous activation, which keeps hardware
  validation diagnostics out of nested layer booleans. `modelFailure` extends
  that to strict fixture validity by also reporting trailing CPU weight or bias
  stream data after all layers complete. Executed layer failures capture the
  first failed `BlaiReferenceTfliteParsedLayerResult`; guard failures and
  trailing-stream validity failures keep that capture unset. A sidecar overload accepts per-layer
  second-input source plans for simple two-input fixtures, allowing
  shortcut/residual validation against the model input or previous activation
  without adopting SDK pointer-backed graph state.
  `BlaiReferenceTfliteParsedCheckedReadiness` mirrors the checked-oracle
  preflight gate for TFLite fixtures and reports a typed first blocking gate
  before execution is attempted.
  `BlaiReferenceTfliteParsedBufferPlan`,
  `blaiReferenceTfliteParsedBufferPlanInto`, and
  `blaiReferenceTfliteParsedBufferPlan` report the same typed CPU stream totals
  and legacy byte totals used by the parsed oracle preflight.
  `BlaiReferenceTfliteParsedBufferSupport`,
  `blaiReferenceTfliteParsedBufferSupportInto`, and
  `blaiReferenceTfliteParsedBufferSupport` expose the TFLite activation-shape
  support gate as typed plan state.
  `BlaiCpuByteSpanFit`, `blaiCpuByteSpanFitsInto`,
  `blaiCpuByteSpanFits`, `blaiCanReadCpuBiasInto`,
  `blaiCanStoreCpuWeightsInto`, and `blaiCanStoreCpuBiasesInto` expose the
  underlying byte/element fit checks with start-index and required-capacity
  diagnostics while preserving the older boolean wrappers. Bias reads and
  weight/bias stream stores share the same byte-span fit helper before applying
  stream-specific element-capacity checks.
  and the maximum decoded int32 bias workspace needed by the oracle; TFLite
  weight streams remain bounded byte slices and do not require decoded weight
  storage. It also reports the supported shape-only activation workspace sizes:
  maximum ping-pong scratch elements for intermediate active layers and final
  output elements for the last active layer.
  `BlaiReferenceTfliteParsedSingleLayerReadiness`,
  `blaiReferenceTfliteParsedSingleLayerReadinessInto`, and
  `blaiReferenceTfliteParsedSingleLayerReadiness` expose the matching
  low-footprint TFLite single-layer oracle gate, including active layer,
  TFLite-mode, stream cursor, layer support, tensor-fit state, and the nested
  TFLite reference dispatch first-block reason.
  `BlaiUint8OutputCompareResult`, `blaiCompareUint8OutputsInto`, and
  `blaiCompareUint8Outputs` provide the matching byte-level comparison evidence
  for TFLite or NPU uint8 outputs, including compared/trailing element counts,
  without depending on a heap-backed diagnostic buffer.
  `blaiReferenceTfliteParsedBuffersFitInto` and
  `blaiReferenceTfliteParsedBuffersFit` check caller-owned model input, CPU
  stream, decoded bias, scratch, and output buffers against that plan before
  execution, carrying required and caller-provided CPU stream totals in the fit
  result. `blaiReferenceTfliteParsedPreflightInto` and
  `blaiReferenceTfliteParsedPreflight` derive the plan from parsed layer state
  and return both the plan and fit result for one oracle call.
  `BlaiReferenceTfliteParsedCheckedReadiness`,
  `blaiReferenceTfliteParsedCheckedReadinessInto`, and
  `blaiReferenceTfliteParsedCheckedReadiness` expose the equivalent checked
  TFLite oracle gate from activation-shape support and buffer fit.
  `blaiReferenceTfliteParsedCheckedModel2d` wraps that preflight gate around the
  sequential oracle, returning without execution when any caller-owned buffer is
  too small.
  `BlaiReferenceTfliteParsedEndToEndResult`,
  `blaiReferenceTfliteParsedEndToEndInto`, and
  `blaiReferenceTfliteParsedEndToEnd` provide the matching TFLite fixture
  summary, tying checked execution, exact stream consumption, completion count,
  first checked gate, and uint8 output comparison into one validation result.
- `BlaiReferenceMaxPool2d` and `blaiReferenceMaxPool2d` recover the SDK
  `forward_MAXPOOL_tflite_nmsis` path through `riscv_max_pool_u8`: HWC uint8
  tensors, stride/padding window clipping, per-channel maxima, and activation
  clamp. The SDK wrapper currently supplies an activation range of `[0, 255]`;
  the reference type keeps the clamp explicit for edge-case fixtures. Input and
  output HWC addresses are projected through `blaiHwcIndex`.
  `BlaiReferenceMaxPoolBlock` and `blaiReferenceMaxPoolReadinessInto` report
  typed first-block diagnostics for input/output shape, clipped-window coverage,
  and caller-owned input/output buffers. A compact TFLite/NMSIS maxpool fixture
  and the readiness diagnostics are exercised on-device by the M0 NPU smoke.
- `BlaiReferenceFixedMaxPool2d` and `blaiReferenceFixedMaxPool2d` recover
  the deterministic odd-kernel SDK `forward_MAXPOOL` path: HWC int8 input is
  sampled around each stride-selected center using the SDK dilation spacing,
  out-of-range taps use padding `-128`, and the max is written without an
  activation clamp. Input and output HWC addresses are projected through
  `blaiHwcIndex`. The SDK even-kernel helper leaves part of its temporary buffer
  uninitialized, so the pure-Nim fixture reports that path unsupported with
  typed first-block diagnostics for shape, stride, dilation, kernel, and
  input/output buffer gates.
- `BlaiReferenceTfliteScalarMaxPool2d` and
  `blaiReferenceTfliteScalarMaxPool2d` recover the deterministic odd-kernel
  SDK `forward_MAXPOOL_tflite` path: stride 2 starts at row/column 1, HWC uint8
  samples are adjusted by `-tf_input1_offset`, out-of-range taps use raw
  padding `-128`, the max is requantized with `BL_MultiplyByQuantizedMultiplier`,
  and activation clamp follows the SDK's uint8 cast. Input and output HWC
  addresses are projected through `blaiHwcIndex`. A compact parsed single-layer
  `MAXPOOL_tflite` case is exercised on-device with unchanged CPU weight/bias
  cursor checks, and the scalar fixture exposes typed first-block diagnostics
  for shape, stride, odd-kernel support, window/output shape, and input/output
  buffer gates.
- `BlaiReferenceAvgPool2d` and `blaiReferenceAvgPool2d` recover the SDK
  `forward_AVGPOOL_tflite` path: per-channel HWC uint8 accumulation with
  explicit padded input/output channel strides, SDK rounding
  `(sum + h*w/2) / (h*w)`, and activation clamp. The divisor intentionally
  remains `h*w`, matching the SDK even when `stride > 1`. Strided input reads,
  1x1 output writes, and output-stride padding writes are projected through
  `blaiHwcStrideIndex`. The fixture exposes typed first-block diagnostics for
  shape, stride, effective channel strides, and caller-owned input/output buffer
  gates.
- `BlaiReferenceTfliteMean2d` and `blaiReferenceTfliteMean2d` recover the SDK
  `forward_MEAN_tflite` path: per-channel HWC uint8 reduction with explicit
  input channel stride, input/output zero-point handling, the SDK general
  quantized multiplier helper, signed half-divisor averaging, and `[0, 255]`
  clamp. Strided input reads and 1x1 output writes are projected through
  `blaiHwcStrideIndex`. The fixture reports typed first-block diagnostics for
  shape, spatial divisor range, output-shift range, effective input stride, and
  caller-owned input/output buffer gates.
- `BlaiReferenceTfliteSoftmax2d` and `blaiReferenceTfliteSoftmax2d` recover
  the SDK `forward_SOFTMAX_tflite` DATA-buffer path. Despite the name, this SDK
  branch copies HWC uint8 samples through graph-derived input/output channel
  strides and does not compute softmax probabilities. Strided input/output HWC
  addresses are projected through `blaiHwcStrideIndex`. The fixture reports
  typed first-block diagnostics for shape, effective input/output channel
  strides, and caller-owned input/output buffer gates.
- `BlaiReferenceTfliteTranspose2d` and `blaiReferenceTfliteTranspose2d`
  recover the SDK `forward_TRANSPOSE_tflite` path: rank-3 HWC masks use axes
  `{0,1,2}`, rank-4 NHWC masks use the last three axes `{1,2,3}`, and the
  output H/W/C dimensions and indices follow the SDK mux rules. Input and
  permuted-output HWC addresses are projected through `blaiHwcIndex`.
  `BlaiReferenceTfliteTransposeBlock` and
  `blaiReferenceTfliteTransposeReadinessInto` split invalid input shape, rank,
  duplicate/invalid permutations, output-shape failure, and short input/output
  buffers into typed first-block diagnostics.
- `BlaiCpuTfliteTransposeMask`, `blaiReferenceTfliteTransposePlan`, and
  `blaiReferenceTfliteTransposeLayer2d` dispatch `TRANSPOSE` CPU layer records
  through typed sidecar mask storage instead of dereferencing the SDK pointer
  field inside `cpu_inst_layer_t`.
- `BlaiReferenceTfliteTransposeLk1d` and
  `blaiReferenceTfliteTransposeLk1d` recover the direct SDK
  `forward_TRANSPOSELK_tflite` path: the sequence axis is selected from `w ==
  1`, kernel size is aligned with `blaiChannelAlign4`, dilation controls the
  source tap spacing, and aligned tail entries are filled with the SDK padding
  value `128`. Sequence input addresses are projected as `position x 1 x
  channels`, and output windows are projected as `window x channel x
  alignedKernelSize` through `blaiHwcIndex`. The fixture reports typed
  first-block diagnostics for shape, kernel, stride, dilation, short-window, and
  caller-owned input/output buffer gates.
- `blaiReferenceTfliteTransposeLkV2_1d` recovers the rolling SDK
  `forward_TRANSPOSELK_V2_tflite` path: window zero is materialized directly,
  later windows copy the previous channel slice shifted by stride, newly
  exposed taps are fetched from input, and aligned tail entries are padded with
  `128`. Rolling previous-window reads, fresh input reads, and output writes use
  the same checked `blaiHwcIndex` projections as the direct path. The V2 path
  shares the typed readiness helper and additionally reports a rolling-stride
  block when `stride > kernelSize`.
- `blaiReferenceTfliteTransposeLkPlan` and
  `blaiReferenceTfliteTransposeLkLayer1d` dispatch `TRANSPOSELK` CPU layer
  records into either the direct or rolling V2 fixture using typed layer fields
  for input extent, channel count, kernel size, stride, and dilation.
- `BlaiReferenceTflitePreTransconv2d` and
  `blaiReferenceTflitePreTransconv2d` recover the SDK
  `forward_PRE_TRANSCONV_tflite` path: input HWC samples are copied to odd
  output rows and columns, odd-row even-column gaps are filled with
  `tf_input1_offset`, and each even output row is filled with the same padding
  byte. Input, copied-output, odd-row padding, and even-row padding addresses
  are projected through `blaiHwcIndex`. The fixture reports typed first-block
  diagnostics for input shape, expanded output-shape requirements, and
  caller-owned input/output buffer gates.
- `BlaiReferenceTfliteDequantize2d` and `blaiReferenceTfliteDequantize2d`
  recover the SDK `forward_DEQUANTIZE_tflite` path: HWC uint8 input is
  converted to float32 as `(sample - tf_input1_offset) * input_scale`. The SDK
  reads output zero-point and output scale fields here but does not use them.
  Per-element HWC addresses are projected through `blaiHwcIndex`. The fixture
  reports typed first-block diagnostics for input shape and
  caller-owned uint8 input/float32 output buffer gates.
- `BlaiReferenceTfliteFloatLayerResult` and
  `blaiReferenceTfliteDequantizeLayer2d` dispatch `DEQUANTIZE` CPU layer
  records into that float-output fixture without mixing it into the uint8
  transform dispatcher. The dispatch result preserves both the float-layer
  first-block reason and the dequantize leaf block.
- `BlaiReferenceTfliteLogistic2d` and `blaiReferenceTfliteLogistic2d` recover
  the SDK `forward_LOGISTIC_tflite` path: HWC uint8 input is scaled to float,
  passed through the SDK's cutoff-based sigmoid approximation, then converted
  back through output scale and zero point without an activation clamp.
  Per-element HWC addresses are projected through `blaiHwcIndex`. The fixture
  reports typed first-block diagnostics for input shape, zero output scale, and
  caller-owned input/output buffer gates.
- `BlaiReferenceUpsample2d` and `blaiReferenceUpsample2d` recover the SDK
  `forward_UPSAMPLE` path: HWC int8 samples are converted with
  `fixed8_to_fixed8(fdata - fout)`, replicated over the square stride window,
  and written through explicit output width/channel metadata. Input and expanded
  output HWC addresses are projected through `blaiHwcIndex`. The fixture reports
  typed first-block diagnostics for input shape, stride, explicit output shape,
  and caller-owned input/output buffer gates.
- `BlaiReferenceRouteUpsample2d` and `blaiReferenceRouteUpsample2d` recover the
  SDK `forward_ROUTE_UPSAMPLE` path: two HWC int8 inputs are channel-concatenated
  with per-route fractional conversion into `fdata`, converted again to `fout`,
  then replicated over the square stride window. Route input and expanded output
  HWC addresses are projected through `blaiHwcIndex`. The fixture reports typed
  first-block diagnostics for input shape, stride, route channel/output-channel
  agreement, explicit output shape, and caller-owned input/output buffer gates.
  A compact two-input route-upsample fixture is exercised on-device by the M0
  NPU smoke.
- `BlaiReferenceTflitePad2d` and `blaiReferenceTflitePad2d` recover the SDK
  `forward_PAD_tflite` implemented branch: HWC uint8 spatial padding with
  `tf_output_offset` as the fill value. Channel-wise padding still reports data
  movement as unsupported because the SDK branch only prints a warning, but the
  recovered fixture now reports the SDK-visible `out_c/out_w/out_h` shape
  mutation from all six padding fields. Input and padded-output HWC addresses
  are projected through `blaiHwcIndex`. `BlaiReferenceTflitePadBlock` and
  `blaiReferenceTflitePadReadinessInto` split invalid input shape, channel
  padding, output-shape overflow, short input, and short output into typed
  first-block diagnostics.
- `BlaiReferenceRouteConcat2d` and `blaiReferenceRouteConcat2d` recover the SDK
  `forward_ROUTE` fixed-point concat path: each input is an HWC int8 tensor,
  output channels are formed by appending `c` plus each active `cn[]` channel
  group, and every copied sample is rescaled with `fixed8_to_fixed8(fdata -
  fout)` before it is written to the HWC output tensor. The fixture reports
  typed first-block diagnostics for input shape, input count, inactive/zero
  channel inputs, caller-owned input buffers, output-channel overflow, and
  caller-owned output buffers.
- `blaiReferenceRouteInput`, `blaiReferenceRouteConcatPlan`, and
  `blaiReferenceRouteMaxPlan` project parsed `cpu_inst_layer_t` metadata plus
  typed `BlaiCpuExtraInputStorage` sidecars into the route reference fixtures.
  This localizes the SDK `SRAM_in * patch_size` buffer offset translation
  through `BlaiPatchSlotOffset` without following raw pointer fields.
  `blaiReferenceRouteInputCursor` bounds fixed route/TFLite route input arrays
  during plan projection, readiness checks, and route input selection.
- `blaiReferenceFixedRouteLayer2d` dispatches sidecar-backed fixed-point
  `ROUTE` and `ROUTE_MAX` CPU layer records into those fixtures without
  dereferencing SDK pointer fields.
- `BlaiReferenceTfliteRoute2d` and `blaiReferenceTfliteRoute2d` recover the
  SDK `forward_ROUTE_tflite` path: channel ranges select each input tensor,
  per-input offset/multiplier/shift values are projected through the typed
  sidecar storage, and the result is output-scaled and activation-clamped. The
  fixture reports typed first-block diagnostics for input shape, input count,
  positive output/input shifts, invalid activation range, inactive/zero-channel
  inputs, caller-owned input buffers, output-channel mismatch, and caller-owned
  output buffers.
- `BlaiReferenceTfliteRouteMax2d` and `blaiReferenceTfliteRouteMax2d` recover
  the SDK `forward_ROUTE_MAX_tflite` path: input selection and TFLite
  requantization match `forward_ROUTE_tflite`, then output coordinates and
  first-write/max-update behavior match fixed-point `forward_ROUTE_MAX`. Input
  and folded-output element addresses are projected through `blaiHwcIndex` and
  `blaiHwcIndexWithBase` before indexing caller-owned buffers. The
  fixture reports typed first-block diagnostics for input shape, folded output
  shape, stride, input count, positive output/input shifts, invalid activation
  range, inactive/zero-channel inputs, caller-owned input buffers,
  output-channel mismatch, and caller-owned output buffers.
- `BlaiReferenceTfliteRouteW2d` and `blaiReferenceTfliteRouteW2d` recover the
  SDK `forward_ROUTE_W_tflite` path, including the axis-0 raw-copy fast path
  and the general axis-selected TFLite requantization path. The axis-selected
  input and output element addresses are projected through `blaiHwcIndex` and
  `blaiHwcIndexWithBase`. The fixture reports
  typed first-block diagnostics for input shape, input count, axis, positive
  output/input shifts, invalid activation range, inactive/zero-channel inputs,
  caller-owned input buffers, axis extent mismatch, and caller-owned output
  buffers.
- `blaiReferenceTfliteRouteLayer2d` dispatches sidecar-backed TFLite `ROUTE`,
  `ROUTE_MAX`, and `ROUTE_W` CPU layer records into those fixtures without
  dereferencing SDK pointer fields. Its generic dispatch result carries the
  route-family leaf first-block reason alongside the dispatch-level block.
- `BlaiReferenceTfliteReshape2d` and `blaiReferenceTfliteReshape2d` recover the
  SDK `forward_RESHAPE_tflite` data movement after the graph-neighbor padding
  decision: explicit input/output channel strides, the raw memcpy fast path, and
  the padded copy path that skips output padding holes without writing them.
  Strided input addresses and flattened output groups are projected through
  `blaiHwcStrideIndex`. The fixture reports typed first-block diagnostics for
  input shape, input/output stride validity, sample-count/output-shape overflow,
  and caller-owned input/output buffer gates.
- `blaiReferenceTfliteTransformLayer2d` dispatches simple uint8 TFLite transform
  records (`MEAN`, `SOFTMAX`, `LOGISTIC`, `PAD`, `RESHAPE`, and
  `PRE_TRANSCONV`) into typed fixtures. `DEQUANTIZE` remains on its float-output
  dispatcher because its output storage has a different element type.
- `BlaiReferenceRouteMax2d` and `blaiReferenceRouteMax2d` recover the SDK
  `forward_ROUTE_MAX` fixed-point path: input channels are selected and
  rescaled like `forward_ROUTE`, then the SDK folds `(hin, win)` into
  `(hin / 2, win / 2)` output coordinates and keeps the larger sample after the
  stride-based first-write predicate. Input and folded-output element addresses
  are projected through `blaiHwcIndex` and `blaiHwcIndexWithBase`. The fixture
  reports typed first-block
  diagnostics for input shape, folded output shape, stride, input count,
  inactive/zero-channel inputs, caller-owned input buffers, output-channel
  overflow, and caller-owned output buffers.
- `BlaiReferenceShortcut2d` and `blaiReferenceShortcut2d` recover the SDK
  `forward_SHORTCUT` fixed-point path: two same-shape HWC int8 inputs are
  aligned to the smaller fractional width with `fixed8_to_fixed8`, added as an
  int32 value, passed through the fixed-point activation helper, and converted
  to the output fractional width with `fixed32_to_fixed8`. Per-element HWC
  addresses are projected through `blaiHwcIndex`. The fixture reports typed
  first-block diagnostics for input shape and caller-owned input/output buffer
  gates.
- `BlaiReferenceTfliteShortcut2d` and `blaiReferenceTfliteShortcut2d` recover
  the SDK `forward_SHORTCUT_tflite` path: two same-shape HWC uint8 inputs are
  offset-adjusted, shifted by the SDK's fixed left shift of 20, scaled with
  `BL_MultiplyByQuantizedMultiplierSmallerThanOneExp`, summed, output-scaled,
  offset-adjusted, and activation-clamped. Per-element HWC addresses are
  projected through `blaiHwcIndex`. The fixture reports typed first-block
  diagnostics for input shape, positive shift fields, invalid activation range,
  and caller-owned input/output buffer gates. A compact parsed single-layer
  `SHORTCUT_tflite` case is exercised on-device with unchanged CPU weight/bias
  cursor checks.

These helpers are deliberately bounded and return `fits=false` for malformed
fixtures or undersized buffers. They are intended as CPU oracles for the small
hardware NPU models listed above, not as a replacement for the full BLAI CPU
runtime.

## Recovered Tensor Transfer Planning

The SDK `Store_tensor_data_to_NPU` and `Load_NPU_data_to_tensor` routines are
partially recovered as byte-count and padding plans:

- `blaiNpuInputTransferPlanInto` and `blaiNpuInputTransferPlan` compute the
  DRAM input slot, actual channels, padded channels, row-padding flag, element
  count, and byte count for each input tensor.
- First-layer inputs with `c == 3` copy four channels; first-layer `c == 1` and
  channel counts already divisible by four use direct copies.
- Other input channel counts are rounded to four-channel rows.
- Extra multi-input tensors are active only for SDK multi-input layer types and
  use `cn[k - 1]` as their channel count.
- `blaiNpuOutputTransferPlanInto` and `blaiNpuOutputTransferPlan` compute
  padded output readback bytes and the optional mid-output readback.
- Output readback has two SDK branches: 4-aligned `out_c` uses
  `out_w * out_h * out_c`, while padded `out_c` uses `w * h *
  align4(out_c)`.
- Mid-output size uses `w * h * out_c` for `CONV_MAX`; route-style mid outputs
  use `w * h * (c + sum(cn[0 .. n-2]))`.
- `BlaiPatchSlotOffset`, `blaiPatchSlotOffset`, `blaiTensorBufferOffset`,
  `BlaiDataBufferRangeFit`, `blaiDataBufferRangeFitsInto`,
  `blaiDataBufferRangeFits`, `blaiTensorBufferFitsInto`,
  `blaiTensorBufferFits`, `blaiBufferLenU32`,
  `BlaiTensorBufferWindow`, `blaiTensorBufferWindow`,
  `blaiCacheRangeFitsInto`, `blaiCacheRangeFits`,
  `blaiForwardNpuBufferFitsInto`, `blaiCompactTensorBytes`,
  `blaiCompactTensorFitsInto`, and `blaiCompactTensorFits` expose checked
  buffer requirements. The `Into` forms report offset arithmetic overflow or
  required compact tensor bytes separately from a short caller buffer. Tensor
  transfer windows reuse `blaiCheckedByteWindow`, and tensor movement converts
  host `openArray` lengths through the same bounded `uint32` helper before
  applying recovered DATA-buffer fit checks. Cache-maintenance fit checks share
  the same typed DATA-buffer
  range helper once recovered slot arithmetic has produced a relative offset;
  that range helper uses `BlaiUint32AppendFitResult` for both uint32 range
  validity and caller-buffer capacity checks.
  `blaiCheckedIntByteWindow` is the shared conversion from recovered uint32 byte
  windows to bounded Nim byte slices for CPU stream and compact tensor
  store/load loops, reusing `BlaiUint32AddressRangeFitResult` before converting
  to target `int` indexes.
- `blaiForwardNpuDataBufferPlan` folds all recovered forward input, output,
  mid-output, and cache ranges into the minimum caller-owned DATA-buffer size.
- `blaiPlanForwardResourcesInto` and `blaiPlanForwardResources` collect the
  caller-owned instruction scratch, DATA, weight, bias, and temporary
  grouped-weight requirements for one recovered `forward_NPU` layer. The
  `Into` form lets model-level planners fold each layer without returning an
  intermediate plan object.
- `blaiForwardResourcesFitInto` and `blaiForwardResourcesFit` check a caller's
  instruction, DATA, weight, bias, and temporary grouped-weight capacities
  against one layer resource plan. The `Into` form reports the failing capacity
  class instead of collapsing everything to a boolean.
  `BlaiForwardResourceFitBlock`, `BlaiForwardResourceFitReadiness`,
  `blaiForwardResourceFitReadinessInto`, and
  `blaiForwardResourceFitReadiness` expose that per-layer fit gate as typed
  result state, with first-block reasons for unsupported layers, instruction
  scratch, DATA buffer, weight/bias buffers, and temporary grouped-weight
  scratch.
- `blaiPlanForwardModelResources` folds a CPU layer table into reusable NPU
  buffer maxima plus total CPU weight/bias stream sizes. This is the first
  graph-level ownership boundary for simple model validation without SDK heap
  allocation or pointer fields.
- `blaiForwardModelResourcesFitInto` and `blaiForwardModelResourcesFit` check
  caller-owned model buffers against that graph-level plan. The `Into` form
  reports the first failing instruction, DATA, weight, bias, temporary, or CPU
  stream capacity class as `BlaiForwardModelResourceFitBlock`, and carries both
  required and caller-provided CPU stream totals for diagnostics.
  `BlaiForwardModelResourceFitReadiness`,
  `blaiForwardModelResourceFitReadinessInto`, and
  `blaiForwardModelResourceFitReadiness` expose the graph-level fit gate as
  typed result state.
- `blaiPlanForwardModelWorkspace` lays the reusable instruction, DATA, weight,
  bias, and temporary-weight buffers out relative to a caller-provided base
  address with alignment and 32-bit overflow checks.
- `BlaiForwardWorkspaceBufferBinding`,
  `blaiBindForwardWorkspaceBufferInto`, and
  `blaiBindForwardWorkspaceBuffer` bind that typed workspace layout to a real
  caller-owned byte array for live hardware execution. The helper is the narrow
  documented boundary that takes the array's base address, projects cached
  OCRAM/WRAM/DRAM/VRAM aliases to the hardware-visible non-cached bus address
  through `blaiProjectHardwareAddress`, isolates raw byte-buffer address
  extraction in `blaiRawByteAddress`, uses `blaiUintAddressInRange` for
  overflow-safe half-open memory range tests, including WRAM residency
  evidence for bound workspaces, rejects empty or non-addressable storage,
  reuses the workspace fit gate, and returns the checked
  instruction/DATA/weight/bias addresses that BLAI registers consume when
  binding is possible. The focused M0 model smoke exercises the typed alias
  projection, address gate, and empty/short-buffer first-block reporting on
  device.
  `blaiBindForwardWorkspaceAddressInto` and
  `blaiBindForwardWorkspaceAddress` cover the companion case where the caller
  already has a hardware-visible workspace base address. They avoid Nim pointer
  address inference, reject the zero-address sentinel explicitly, and still
  return the same binding object and fit diagnostics used by byte-array
  binding.
- `BlaiForwardWorkspaceSegmentFitBlock`,
  `BlaiForwardWorkspaceSegmentWindow`, `blaiForwardWorkspaceSegmentWindow`,
  `blaiForwardWorkspaceSegmentByteWindow`,
  `blaiReadForwardWorkspaceSegmentByte`,
  `blaiWriteForwardWorkspaceSegmentByte`,
  `blaiForwardWorkspaceSegmentByteEquals`,
  `blaiForwardWorkspaceSegmentFitsInto`, `blaiForwardWorkspaceSegmentFits`,
  `blaiForwardWorkspaceFitsInto`, `blaiForwardWorkspaceFits`,
  `BlaiUint32AppendFitResult`, and `blaiUint32AppendFitInto` keep reusable
  workspace segment layout and caller-buffer fit checks on the same typed
  cursor/append/required-count path used by recovered instruction and weight
  streams.
  `blaiClearForwardWorkspaceSegment`, `blaiClearForwardModelWorkspaceInto`,
  and `blaiClearForwardModelWorkspace` validate and zero caller-owned byte
  storage for the typed workspace segments without raw pointer arithmetic. The
  segment fit result distinguishes inactive/no-block, invalid segment layout,
  and short caller backing storage; the workspace `Into` forms report which
  segment failed the caller-buffer check, and complete workspace fit results
  expose the first failing storage gate as `BlaiForwardWorkspaceFitBlock`.
  The typed segment-window plus byte read/write/equality helpers keep smoke
  fixtures and DATA-slot evidence on segment-relative offsets instead of raw
  workspace-array indexes; segment windows share the recovered
  `blaiCheckedIntByteWindow` conversion after segment layout and requested byte
  count checks and reuse `BlaiUint32AddressRangeFitResult` for the final
  segment-relative range check before applying the workspace-specific buffer
  length gate. When fixture/evidence code already holds the recovered workspace
  byte capacity as `uint32`, `blaiForwardWorkspaceSegmentByteWindow` owns the
  checked projection into a Nim slice capacity rather than leaving `.int`
  conversions at call sites. `blaiForwardWorkspaceSegmentWindowMatches` uses the
  same exact projection when evidence compares a Nim byte window with recovered
  workspace offset/size fields. `blaiForwardWorkspaceRelativeByteOffset` owns the
  segment-relative byte-offset projection before read/write helpers combine it
  with the checked segment window. `blaiU32ExactIntCount` is the shared exact
  `uint32`-to-`int` projection for checked byte-window and CPU stream element
  counts, keeping those conversions named and reusable.
  Whole-workspace binding, clearing, materialization/execution readiness, and
  workspace DATA tensor I/O now pass caller-owned byte capacities through
  `blaiBufferLenU32` before applying recovered workspace fit checks, keeping
  host `openArray` lengths out of raw `uint32` casts. The workspace-specific
  `blaiForwardWorkspaceBufferBytes` helper is now a semantic alias over that
  shared conversion. `BlaiTensorRowLayout` and `blaiTensorRowLayout` now own
  checked projection of recovered compact/padded tensor row counts and channel
  counts into Nim loop bounds before DATA-buffer staging/readback;
  `BlaiTensorRowIndex` owns flat row/channel byte-index projection for both
  compact tensor bytes and padded DATA bytes;
  `blaiBindForwardWorkspaceFixtureAddressInto` and
  `blaiBindForwardWorkspaceFixtureAddress` name the configured-live fixture
  case where address zero must still bind the recovered workspace shape so the
  later hardware-address readiness gate reports the zero-address block, while
  the normal explicit-address binder continues to reject zero addresses early.
  `blaiOpenArrayLenU32` and `blaiInt32BufferBytes` extend that boundary to
  element counts and int32 bias-buffer byte capacities; `blaiInt32BufferBytes`
  delegates to `blaiBiasWordCountBytes` so the same exact word-to-byte
  projection is reused before saturating the compatibility result. This avoids
  wrapped `len.uint32 * 4` calculations in the recovered `Load_NPU_weights` and
  temporary forward_NPU weight/bias materialization paths; the low-level
  recovered weight-byte, bias-word, source-weight, and grouped-temporary
  append checks now use the same typed element-count conversion before
  comparing stream cursors. CPU weight/bias stream store windows also use the
  typed element-count conversion for destination decoded buffers, and
  `blaiCpuStreamStartCursor` resolves recovered CPU stream byte offsets through
  `blaiU32ExactIntCount` before exposing Nim openArray start indexes for
  int8/int32 stream copies or TFLite weight stream slices.
  Parsed
  CPU-reference/forward materialization paths use it for caller-provided
  weight/bias byte stream capacities before recovered cursor windows are
  checked. Fixed and TFLite parsed reference preflight wrappers also use this
  boundary for decoded tensor, scratch, output, and model-input capacities
  before passing counts into the recovered `uint32` ABI. Instruction-stream
  append/evidence paths and reusable-workspace instruction/weight/bias
  copy/evidence paths now use `BlaiU32CountCursor` and
  `blaiInstructionStreamCountCursor` before iterating recovered instruction
  row counts or comparing those counts with caller-owned buffers. Temporary
  forward_NPU and reusable-workspace weight/bias paths use
  `blaiForwardWeightByteCountCursor` and `blaiForwardBiasWordCountCursor`
  before iterating recovered byte or int32-bias counts. Parsed fixed/TFLite
  CPU-reference paths use `blaiZeroBasedOpenArrayStop` and
  `blaiStartedOpenArrayStop` before turning recovered element or stream-byte
  counts into `toOpenArray` stop indexes. CPU-reference output
  compare/projection helpers also use these conversions for expected, actual,
  output, copied/converted, compared, and trailing element counters so
  diagnostic metadata cannot wrap on oversized host buffers. CPU model parser
  projection/storage gates now use `BlaiU32ArrayIndexCursor` for caller-owned
  layer, extra-input, YOLO, and parsed-layer state reads/writes, and
  parsed-forward readiness uses the same typed conversion before comparing
  recovered `storedLayerCount` cursors. CPU weight/bias stream-plan layer
  selection uses `blaiI32ArrayIndexCursor` for recovered signed layer cursors
  before reading caller-owned layer tables, and stream segments use
  `blaiCpuStreamStartLayerCursor` before starting the next plan scan.
  Fetch memory planning uses the same checked cursor before indexing fixed input
  patch-count and input-slot arrays. Route descriptor planning and emission use
  `BlaiRouteDescriptorStepCursor` before indexing fixed route step tables and
  corresponding `cn[]` channel entries. Extra-input sidecar application and
  projection use `BlaiCpuExtraStorageCursor` before indexing caller-owned
  route/TFLite sidecar arrays. Release-layer analysis uses
  `BlaiReleaseSlotCursor` and `BlaiGraphLayerMapCursor` before writing fixed
  release arrays or caller-owned graph maps. `BLAI_MEM_alloc` patch planning
  uses `blaiWeightPatchCursor` before writing fixed line-width and
  weight-output-channel patch arrays. Route CPU-reference plans use
  `blaiReferenceRouteInputCursor` before reading or writing fixed route input
  arrays. Recovered `Load_NPU_weights` materialization uses
  `blaiNpuWeightBufferCursor`, `blaiNpuWeightSourceCursor`,
  `blaiNpuBiasBufferCursor`, `blaiNpuBiasSourceCursor`, and
  `blaiNpuTemporaryWeightCursor` before touching caller-owned weight, bias, or
  temporary grouped-weight buffers. Parsed-layer CPU-reference and forward
  workspace paths use `blaiRecoveredLayerCursor` before reading caller-owned raw
  or parsed layer tables. Forward_NPU DATA input staging and workspace evidence
  use `blaiForwardInputCursor` before reading fixed input transfer or `dramIn`
  slot arrays. Parsed-forward
  layer-table iteration and resource planning use `blaiBoundedU32Count` to
  clamp recovered `uint32` layer counts to Nim container capacities before
  converting through `blaiU32ExactIntCount` to `int` indexes. Generic
  `blaiU32ArrayIndexCursor` selectors use the same exact projection after
  capacity checks. CPU parser loops for `INPUT_LAYERS` and
  `YOLO_INFO`, release-graph input checks, route-conv effective weight-channel
  accumulation, fetch/route descriptor slot loops, and `forward_NPU` cache-range
  append/apply/evidence loops use named bounded helpers before indexing fixed
  Nim arrays. Layer-count metadata, parsed single-layer
  guards, parsed forward execute readiness, and recovered weight-schedule
  summaries no longer use direct `len.uint32` casts; all remaining openArray
  length crossings in the NPU module go through the typed conversion helpers.
  Temporary `forward_NPU` weight/bias packing now uses the same
  `BlaiUint32AppendFitResult` cursor append for the aligned weight prefix plus
  bias byte span, and evidence-side bias range checks reuse
  `blaiCheckedByteWindow` instead of duplicating offset arithmetic.
  `BlaiForwardWorkspaceFitReadiness`, `blaiForwardWorkspaceFitReadinessInto`,
  and `blaiForwardWorkspaceFitReadiness` expose the complete workspace backing
  storage gate as typed result state. `BlaiForwardWorkspaceClearReadiness`,
  `blaiForwardWorkspaceClearReadinessInto`, and
  `blaiForwardWorkspaceClearReadiness` expose the clear gate and underlying
  workspace fit first-block reason in the clear result; clear verification uses
  segment-relative byte equality for instruction, DATA, weight, and bias
  storage.
- `blaiStoreForwardInstructionsInWorkspaceInto` and
  `blaiStoreForwardInstructionsInWorkspace` copy typed 16-byte BLAI
  instruction records into the instruction workspace segment with stream,
  segment, and backing-buffer bounds reported separately. `blaiInstructionCountBytes`
  projects the recovered instruction count through `blaiU64ExactU32Count`
  before byte-capacity checks, typed instruction-stream length projections, or
  fixture evidence consume it. Byte indexing is
  routed through the checked segment-window helper plus
  `BlaiCheckedByteIndex`, `BlaiFixedRowByteCursor`, and
  `BlaiInstructionByteCursor`, which record the recovered fixed 16-byte
  instruction row layout before bytes are copied or compared. Fixture evidence
  checks stored and trailing bytes through `blaiForwardWorkspaceSegmentByteEquals`,
  keeping those checks relative to the typed instruction segment. The public
  storage gate and static stored-byte assertions both use
  `blaiInstructionCountBytes` before comparing segment byte counts. The public
  storage gate still requires the declared instruction segment to fit in the
  caller buffer. The
  result and readiness expose the first blocking copy gate as
  `BlaiForwardInstructionWorkspaceBlock`.
  `BlaiForwardInstructionWorkspaceReadiness`,
  `blaiForwardInstructionWorkspaceReadinessInto`, and
  `blaiForwardInstructionWorkspaceReadiness` expose that storage gate as typed
  result state.
- `blaiStoreForwardWeightsInWorkspaceInto` and
  `blaiStoreForwardWeightsInWorkspace` copy materialized NPU weight bytes and
  bias int32s into the reusable workspace using the recovered
  `BlaiNpuBiasElementBytes` word size, with weight input/segment, bias
  input/segment, and backing-buffer bounds reported separately. Their writes use
  the same checked segment-window boundary as instruction storage: byte copy and
  little-endian bias packing helpers receive only segment-relative offsets, and
  their inner byte/word positions are expressed with
  `BlaiCheckedByteIndex`, `BlaiForwardWeightByteCursor`,
  `blaiForwardBiasWordByteOffset`, `BlaiForwardBiasWordCursor`, and
  `BlaiLe32ByteCursor`. `blaiNpuBiasWordByteCount` owns the recovered
  `BlaiNpuBiasElementBytes` conversion before LE32 loops and checked byte-window
  word-size comparisons, `blaiForwardWorkspaceLe32LaneOffset` owns LE32
  byte-lane offset appends through `BlaiUint32AppendFitResult`, and
  `blaiBiasWordCountBytes` projects recovered bias word counts through
  `blaiU64ExactU32Count` before workspace byte-capacity checks.
  `blaiReadForwardWorkspaceSegmentLe32`,
  `blaiWriteForwardWorkspaceSegmentLe32`,
  `blaiForwardWorkspaceSegmentLe32Equals`, and
  `blaiStoreForwardBiasWordsInWorkspaceSegment` keep reusable-workspace bias
  staging and byte-evidence checks on typed workspace segments instead of
  absolute byte-array indexes. Fixture evidence for materialized weight bytes
  now uses `blaiForwardWorkspaceSegmentByteEquals` so copied bytes remain
  relative to the typed weight segment. `blaiForwardWorkspaceAbsoluteOffset`
  owns recovered base-plus-relative byte projections for trailing instruction
  sentinels and DATA slot evidence, while DATA slot evidence reuses
  `blaiPatchSlotOffset` for recovered slot-times-patch-size projections before
  any uint32 workspace offset is reported.
  The result and readiness expose the first blocking copy gate as
  `BlaiForwardWeightWorkspaceBlock`.
- `blaiPrepareForwardLayerInstructionsInWorkspaceInto` and
  `blaiPrepareForwardLayerInstructionsInWorkspace` compose workspace-backed
  layer preparation with instruction workspace storage so an encoded,
  resource-fitting instruction stream can be staged in caller-owned workspace
  storage before run-configuration readiness is available. The
  result and readiness expose the first composed blocking gate as
  `BlaiForwardLayerInstructionWorkspaceBlock` while preserving the underlying
  instruction-storage first-block reason. Instruction stream evidence resolves
  the recovered `layerInstructionIndex` through `blaiInstructionStreamCursor`
  before decoding the layer instruction or TFLite descriptor from caller-owned
  stream storage.
  `BlaiForwardLayerInstructionWorkspaceReadiness`,
  `blaiForwardLayerInstructionWorkspaceReadinessInto`, and
  `blaiForwardLayerInstructionWorkspaceReadiness` expose that prepared-and-stored
  gate as typed result state.
- `blaiMaterializeForwardLayerWorkspaceInto` and
  `blaiMaterializeForwardLayerWorkspace` populate the reusable instruction,
  weight, and bias workspace bytes for one prepared layer while advancing CPU
  model weight/bias stream cursors only after the layer workspace is complete.
  The result and readiness expose the first composed materialization gate as
  `BlaiForwardLayerWorkspaceMaterializeBlock` while preserving the underlying
  instruction and weight-workspace first-block reasons. Fixture evidence for
  the composed instruction, weight, and bias bytes now reads through typed
  workspace segments rather than absolute workspace offsets.
  `BlaiForwardLayerWorkspaceMaterializeReadiness`,
  `blaiForwardLayerWorkspaceMaterializeReadinessInto`, and
  `blaiForwardLayerWorkspaceMaterializeReadiness` expose the instruction/weight
  storage gate as typed result state. `BlaiForwardMaterializedLaunchBridgeEvidence`
  and `blaiForwardMaterializedLaunchBridgeEvidence` compose materialization,
  decoded stream semantics, byte evidence, DATA mapping, SDK-style temporary
  weight/bias preparation, and run-plan evidence into one launch-coherence
  predicate for active configured-workspace fixtures.
- `blaiMaterializeForwardModelWorkspace` sequences that per-layer materializer
  across an NPU-enabled layer table, leaving the reusable workspace populated
  with the last ready layer and returning the consumed CPU stream cursors. The
  model result/readiness expose the first model-level materialization gate as
  `BlaiForwardModelWorkspaceMaterializeBlock` and preserve the first blocked
  layer's composed instruction/weight first-block reasons.
  `blaiMaterializeForwardModelWorkspaceInto` provides the same model
  materialization with caller-owned result storage. The result now carries
  `BlaiForwardModelWorkspaceMaterializeReadiness`, also available through
  `blaiForwardModelWorkspaceMaterializeReadinessInto` and
  `blaiForwardModelWorkspaceMaterializeReadiness`, so callers can inspect the
  derived blocked-layer and caller-owned layer-storage gates without
  reimplementing the summary predicate.
- `blaiMaterializeAndExecuteForwardModelWorkspace` materializes one NPU layer
  into the reusable workspace and executes it before advancing to the next
  layer, so callers can run simple models without relying on stale workspace
  contents from an earlier layer.
  `blaiMaterializeAndExecuteForwardModelWorkspaceInto` provides the same
  sequencing with caller-owned result storage and blocks truncated layer tables
  before invoking the per-layer materializer or executor. The execution result
  exposes the first blocked execution gate as
  `BlaiForwardModelWorkspaceExecuteBlock` and preserves the first blocked
  layer's materialization first-block reasons.
- `blaiStoreForwardWeightsInWorkspaceInto` and
  `blaiStoreForwardWeightsInWorkspace` copy already materialized NPU weight
  bytes and signed bias values into the weight and bias workspace segments,
  reporting source, segment, and backing-buffer bounds separately.
  `BlaiForwardWeightWorkspaceReadiness`,
  `blaiForwardWeightWorkspaceReadinessInto`, and
  `blaiForwardWeightWorkspaceReadiness` expose that storage gate as typed result
  state.
- `blaiMaterializeForwardLayerWeightsInWorkspaceInto` and
  `blaiMaterializeForwardLayerWeightsInWorkspace` connect the recovered CPU
  model weight/bias stream cursors to `Load_NPU_weights` materialization and
  then store the reordered NPU buffers into the reusable workspace. The `Into`
  form keeps the per-layer result in caller-owned storage and also supports
  `BlaiCpuParsedLayerState` arrays. The result embeds
  `BlaiForwardLayerWeightWorkspaceReadiness`, with
  `blaiForwardLayerWeightWorkspaceReadinessInto` and
  `blaiForwardLayerWeightWorkspaceReadiness` exposing the stream, CPU decode,
  NPU materialization, and workspace-copy gates as typed state plus
  `BlaiForwardLayerWeightWorkspaceBlock` first-block reasons. Layer
  workspace byte evidence uses `blaiForwardWorkspaceSegmentByteEquals` and
  `blaiForwardWorkspaceSegmentLe32Equals`, so weight and bias checks stay
  segment-relative instead of indexing absolute workspace offsets.
- `blaiMaterializeForwardModelWeightsInWorkspaceInto` and
  `blaiMaterializeForwardModelWeightsInWorkspace` sequence that same bridge
  across an NPU-enabled model layer table, advancing typed CPU stream cursors
  only after the layer's reordered weight/bias data has reached workspace. Both
  raw `BlaiCpuInstLayer64` arrays and `BlaiCpuParsedLayerState` arrays are
  supported, so parser sidecars can stay in typed state through weight staging.
  The model summary now derives expected CPU weight/bias end cursors with
  `blaiCpuStreamEndCursorsInto`, compares them with the actual cursors returned
  by the materializer, and treats mismatched stream consumption as its own
  typed `BlaiForwardModelWeightWorkspaceBlock` reason.
  The result embeds `BlaiForwardModelWeightWorkspaceStorage`, with
  `blaiForwardModelWeightWorkspaceStorageInto` and
  `blaiForwardModelWeightWorkspaceStorage` available to recompute the same
  stored/blocked-layer predicate and `BlaiForwardModelWeightWorkspaceBlock`
  first-block reason from caller-owned result storage. It also
  captures the first blocked layer's
  `BlaiForwardLayerWeightWorkspaceReadiness` snapshot, so short or missing
  workspace storage failures can be reported without re-reading the last-layer
  aggregate.
- `blaiMaterializeForwardModelWorkspace`,
  `blaiMaterializeForwardModelWorkspaceInto`,
  `blaiPrepareForwardModelInWorkspaceInto`, and
  `blaiPrepareForwardModelInWorkspace` also accept `BlaiCpuParsedLayerState`
  arrays, preserving typed parser sidecars through model-wide workspace
  materialization and preparation.
- `blaiPrepareForwardNpuLayerInto` and `blaiPrepareForwardNpuLayer` compose
  recovered allocator-backed instruction encoding, resource sizing, and run
  configuration into one readiness result without taking ownership of caller
  buffers. Instruction stream capacity is projected into the recovered `uint32`
  ABI with `blaiU64SaturatedU32Count`, matching the other forward byte-count
  diagnostics. `BlaiForwardPreparedRunReadiness`,
  `blaiForwardPreparedRunReadinessInto`, and
  `blaiForwardPreparedRunReadiness` expose the runnable/encoded/resource/run
  gate as typed result state.
- `blaiPrepareForwardNpuLayerInWorkspaceInto` and
  `blaiPrepareForwardNpuLayerInWorkspace` feed typed model workspace segment
  addresses and capacities into that preparation path, so callers do not repeat
  address or buffer-size plumbing per layer.
- `blaiPrepareForwardModelInWorkspaceInto` and
  `blaiPrepareForwardModelInWorkspace` run that preparation across a layer
  table, skipping layers that are not marked for NPU, and reporting ready,
  blocked, first-blocked, and caller-owned layer-storage counts without owning
  the model buffers. The result embeds `BlaiForwardModelPrepareReadiness`, with
  matching
  `blaiForwardModelPrepareReadinessInto` and
  `blaiForwardModelPrepareReadiness` helpers, so supported/workspace-ready and
  blocked-layer gates are exposed as one typed predicate.
- `blaiForwardEncodedLayerReadyInto`, `blaiForwardEncodedLayerReadiness`, and
  `blaiForwardEncodedLayerReady` expose the parsed-layer post-encoder gate as
  typed pure Nim diagnostics, separating non-NPU pass-through from missing
  patch-size and instruction-count state before model-wide forward planning.
  Parsed-state overloads keep typed parser sidecars bundled while checking the
  embedded CPU layer.
- `blaiPlanForwardModelRunSequence` derives ordered run-configuration metadata
  from the prepared layer table and workspace, reporting configurable, skipped,
  blocked, first-blocked, and aggregate cache-range counts without starting the
  NPU. The planner also reports whether caller-owned layer storage covers the
  resource plan's expected layer count, so truncated prepared tables cannot be
  treated as fully configurable. `blaiPlanForwardModelRunSequenceInto` exposes
  the same planner with caller-owned result storage for embedded callers that
  cannot safely return larger aggregate objects. The result embeds
  `BlaiForwardModelRunSequenceConfigurability`, and
  `blaiForwardModelRunSequenceConfigurabilityInto` /
  `blaiForwardModelRunSequenceConfigurability` recompute the same terminal
  per-layer configurability predicate from the aggregate plan.
- `blaiExecuteForwardModelRunSequence` runs the same ordered sequence through a
  caller-supplied layer executor. This keeps graph execution sequencing in pure
  Nim while allowing tests to use fake executors and hardware callers to choose
  when to invoke the live single-layer NPU executor. The run-sequence helpers
  also accept `BlaiCpuParsedLayerState` arrays and preserve first blocked
  run-config readiness through both the aggregate plan and configurability view,
  keeping typed parser sidecars through callback-driven execution planning.
  `blaiExecuteForwardModelRunSequenceInto` provides the caller-owned result
  form for the same reason. The shared `BlaiForwardModelExecuteResult` embeds
  `BlaiForwardModelExecuteCompletion`, and
  `blaiForwardModelExecuteCompletionInto` /
  `blaiForwardModelExecuteCompletion` expose the same terminal failed-layer
  predicate and caller-owned layer-storage fit for callback-driven and
  configured live execution paths. `BlaiForwardModelExecuteBlock` records the
  first top-level execution gate, separating run-sequence rejection,
  caller-owned layer-storage gaps, and layer executor failure. The aggregate
  result preserves the first
  failed execution object when a layer executor actually ran, while leaving that
  capture flag clear for pre-executor guard failures. The focused M0 model smoke
  now exercises run-sequence planning and callback execution on device for raw
  layer tables and parsed-layer state tables, including skipped non-NPU layers,
  missing layer storage, and failing-executor completion summaries.
- `blaiMaterializeAndExecuteParsedForwardModelWorkspace` and its parsed-state
  overload feed the supplied caller-owned layer count into
  `BlaiParsedForwardModelExecuteReadiness`, and the checked overloads recompute
  the current layer-table resource plan before entry. Stale plans now fail
  closed with `planMatchesLayers = false` and
  `blaiParsedForwardModelExecutePlan` rather than reaching materialization with
  undersized workspace segments. `blaiSameNpuNetParams`,
  `blaiSameForwardEncodedLayerReadiness`,
  `blaiSameParsedForwardModelReadiness`, `blaiSameCpuStreamTotals`, and
  `blaiSameForwardModelResourcePlan` make this plan comparison explicit, so the
  check does not depend on generated object equality helpers. The parsed
  execution readiness and result also preserve typed first-block reasons for
  parse, forward-readiness, plan,
  workspace-plan, and workspace-backing failures. The focused M0 parser smoke
  validates the parse-to-execution bridge, stale raw/parsed-state plan
  rejection, and the parsed-state reusable-workspace execution path with a
  callback executor, including instruction workspace storage, packed weight
  workspace sizing, skipped non-NPU layers, missing layer storage, first-block
  reasons, and failing-executor completion.
- `blaiMaterializeForwardModelWorkspace` preserves a compact readiness snapshot
  for the first layer that blocks standalone workspace materialization. This
  keeps the blocked-layer reason available without copying the full per-layer
  materialization result into the aggregate result.
- `blaiMaterializeAndExecuteForwardModelWorkspace` embeds
  `BlaiForwardModelWorkspaceExecuteCompletion`, with
  `blaiForwardModelWorkspaceExecuteCompletionInto` and
  `blaiForwardModelWorkspaceExecuteCompletion` available to recompute the same
  terminal blocked/failed-layer predicate from a completed execution result. The
  execution result also captures the first blocked layer readiness snapshot, so
  short workspace failures retain the exact gate evidence that stopped
  execution without copying the full per-layer workspace result.
  The focused M0 model smoke exercises this raw reusable-workspace
  materialize-and-execute bridge on device, including instruction/weight/bias
  workspace storage, skipped non-NPU layers, missing layer storage,
  failing-executor completion, and short workspace rejection.
- `blaiExecuteForwardModelConfiguredInto` and
  `blaiExecuteForwardModelConfigured` sequence the recovered live
  `blaiExecuteForwardNpuRunInto` executor across a prepared model. They assume
  the caller has already populated instruction, DATA, weight, and bias workspace
  buffers with validated contents; the `Into` form keeps the aggregate result
  in caller-owned storage. The focused M0 model smoke exercises the
  non-starting guard paths on device: unsupported completion waits, blocked
  single-run execution, and invalid raw/parsed configured-model inputs that must
  fail before applying a live NPU layer config. Each
  `BlaiForwardNpuExecuteResult` preserves the wait plan it was asked to run
  with, so aggregate first-failure evidence can be tied to the timeout,
  clear-on-complete, and clock-disable policy used for that layer. The live
  bridge also records the recovered runtime ownership plan and stops a started
  stream after inference, matching the SDK `forward_NPU` wrapper.
- `BlaiParsedForwardConfiguredWorkspaceFixtureResult`,
  `BlaiParsedForwardConfiguredWorkspaceFixtureReadiness`,
  `blaiValidateParsedForwardConfiguredWorkspaceFixtureInto`, and
  `blaiValidateParsedForwardConfiguredWorkspaceFixture`,
  `blaiValidateParsedForwardConfiguredWorkspaceAddressFixtureInto`, and
  `blaiValidateParsedForwardConfiguredWorkspaceAddressFixture`,
  `blaiMaterializeAndValidateParsedForwardConfiguredWorkspaceFixtureInto`, and
  `blaiParsedForwardConfiguredWorkspaceFixtureReadinessInto`, and
  `blaiParsedForwardConfiguredWorkspaceFixtureReadiness` bind either projected
  caller-owned workspace bytes or an explicit hardware-visible workspace base
  to parsed model resources, stage compact DATA input, run the prepared
  parsed-state model through the live configured runner, validate
  bound-workspace output against the expected tensor, and project the result
  into a compact readiness summary. The result preserves binding,
  hardware-address, input, execution, configured-run-sequence first block,
  run-sequence readiness first block, first blocked layer/run-config reason,
  skipped/attempted/completed/failed execution counts, first failed layer, and
  output first-block diagnostics. The
  focused M0 model smoke currently exercises the readiness summary for the
  zero-address hardware-readiness guard, projected-buffer skipped-layer input
  and output validation, a positive-address skipped-layer path that stages DATA
  input, completes configured execution without starting a live NPU layer, and
  validates preseeded workspace output, plus a positive-address active-layer
  guard where input staging succeeds, missing weight workspace blocks
  run-sequence configurability, and execution returns before live NPU start.
- `BlaiNpuRuntimeOwnershipPlan`, `BlaiNpuRuntimeWaitPrimitive`,
  `BlaiNpuRuntimeLockPrimitive`, `NpuGlbMcuInterruptSourceCursor`,
  `NpuInterruptLineOwnership`, `NpuInterruptGlbRouteMap`,
  `NpuMmAggregatePendingClass`,
  `NpuMmAggregateRawIndexPlan`,
  `NpuMmAggregateSubrouteCatalogEvidence`,
  `NpuMmAggregateInterruptSnapshot`,
  `NpuMmAggregateRawIndexSnapshotEvidence`,
  `NpuMmAggregateRawIndexClearEvidence`,
  `NpuMmAggregatePendingIndexScanEvidence`,
  `NpuMmAggregateInterruptRouteEvidence`,
  `NpuInterruptCoreBindingPolicy`, `NpuInterruptBindingOperationPlan`,
  `NpuInterruptBindingOperationReadiness`,
  `NpuInterruptBindingApiContract`,
  `BlaiNpuStopAfterInferencePath`, `BlaiNpuStopAfterInferenceEvidence`,
  `BlaiNpuPostCompletionCachePath`,
  `BlaiNpuPostCompletionCacheEvidence`,
  `BlaiParsedForwardConfiguredWorkspaceActiveOutputCacheGateEvidence`,
  `BlaiParsedForwardConfiguredWorkspaceActiveOutputReadbackPlanEvidence`,
  `BlaiParsedForwardConfiguredWorkspaceActiveOutputTransferScopeEvidence`,
  `BlaiParsedForwardConfiguredWorkspaceActiveExitCleanupEvidence`,
  `BlaiParsedForwardConfiguredWorkspaceActiveRecoveryFrontierEvidence`,
  `BlaiParsedForwardConfiguredWorkspaceCompletionRouteTargetBlock`,
  `BlaiParsedForwardConfiguredWorkspaceCompletionRouteTargetEvidence`,
  `BlaiParsedForwardConfiguredWorkspaceActiveCompletionRouteAggregateBlock`,
  `BlaiParsedForwardConfiguredWorkspaceOutputEquivalenceFrontierEvidence`,
  `BlaiParsedForwardConfiguredWorkspaceActiveCompletionToOutputHandoffEvidence`,
  `BlaiParsedForwardConfiguredWorkspaceActiveCompletionWaitBudgetEvidence`,
  `BlaiParsedForwardConfiguredWorkspaceActivePostBudgetOutputGateEvidence`,
  `BlaiParsedForwardConfiguredWorkspaceOutputEquivalenceReadinessBlock`,
  `BlaiParsedForwardConfiguredWorkspaceActiveRecoveryRouteFrontierBlock`,
  `BlaiParsedForwardConfiguredWorkspaceActiveCompletionRouteResolutionBlock`,
  `BlaiParsedForwardConfiguredWorkspaceOutputEquivalenceReadinessEvidence`,
  `NpuInterruptBindingReadiness`,
  `blaiNpuRuntimeOwnershipPlan`, `blaiNpuStopAfterInferenceEvidence`,
  `blaiNpuPostCompletionCacheEvidence`, and
  `npuInterruptBindingOperationReadinessInto`,
  `npuInterruptBindingOperationReadiness`, and
  `npuInterruptBindingReadiness` expose the
  SDK runtime boundary as pure data: `blai_npu_init` creates a counting
  interrupt semaphore and execution mutex, while `forward_NPU` takes/releases
  the mutex around layer config, inference, and stop. The recovered SDK
  `CNN_IRQn` request and priority 7,1 are now checked separately from local IRQ
  line ownership, SDK-header GLB route-map facts, MM_MISC aggregate interrupt
  status/mask/clear bitmap evidence, core-specific binding policy,
  binding operation plan, HAL IRQ API contract, and
  binding readiness; `NpuGlbMcuInterruptSourceCursor` projects recovered line 55
  into GLB MCU source offset 39 for the SDK `CNN_IRQn` request, which is named as
  APU in the D0/E907 views, but the M0 header excludes APU and the MCU GLB
  source map reuses source 39 for I2C1 while exposing the multimedia domain as
  aggregate source `MM_IRQ_ALL` rather than a direct CNN source. The DSP
  all-interrupt map leaves source 39 reserved, so handler registration and IRQ
  enable operations are suppressed on the active M0 path until the MM aggregate
  demux/subroute is recovered. The MM_MISC headers expose `MM_INT_STA0`,
  `MM_INT_MASK0`, and write-one clear `MM_INT_CLR_0` as raw 32-bit bitmaps; the
  E907 register view also exposes the second raw bank at `MM_INT_STA1`,
  `MM_INT_MASK1`, and `MM_INT_CLR_1`. `NpuMmAggregateSubrouteCatalogEvidence`
  records that the standard peripheral view names bank 0, the E907 view names
  both raw bitmap banks, and neither header names a CNN/NPU/APU sub-bit.
  `NpuMmAggregateRawIndexCursor` captures the recovered SDK
  `GLB_MCU_*_DSP_Int*` raw addressing rule: indexes 0..31 select bank 0,
  indexes 32..63 select bank 1, and the low five bits select the status/mask
  bit. `NpuMmAggregateRawIndexPlan` copies that typed cursor into the public
  planning API, keeping raw aggregate experiments typed without naming an
  unverified NPU subroute. `NpuMmAggregateRawIndexSnapshotEvidence` projects one such raw
  index through a decoded snapshot, reporting raw pending, mask state,
  unmasked-pending, masked-only, and clear-write evidence without open-coded
  bank or bit arithmetic. `NpuMmAggregateRawIndexClearEvidence` then projects a
  one-bit write-one clear for that same raw index, proving whether bank 0, bank
  1, or neither would be written while preserving the broader aggregate clear
  plan. `NpuMmAggregatePendingIndexScanEvidence` scans the full recovered
  64-index aggregate surface and records counts plus first raw, first
  unmasked, and first masked-only indexes for compact candidate-subroute
  summaries. The focused M0 model smoke logs the live wait-exit aggregate
  status/mask words, raw/unmasked/masked-only counts, and first candidate
  indexes through the JTAG-backed validation log so completion-route recovery
  can distinguish a true no-pending timeout from an unnamed pending subroute.
  The current live run reports both raw status banks as zero, with the
  first-candidate indexes left at the 64-index sentinel, so the observed
  timeout is not hiding an unmasked or masked MM aggregate pending bit.
  `NpuMmAggregateInterruptClearPlan` and `npuMmAggregateInterruptClearPlan` keep
  those write-one clear words as typed plan data before any clear is applied. The
  pure Nim evidence decodes pending-versus-masked aggregate words while
  preserving polling until the sub-bit map is recovered. The API contract maps
  the recovered SDK
  handler registration, clear-pending, priority/level, and enable side effects
  to existing typed HAL interrupt wrappers while proving those calls remain
  deferred on M0, which is explicitly classified as polling required and still
  uses single-thread execution, while the result keeps both the SDK primitive
  and active primitive visible. Stop-after-inference evidence
  separately classifies no-start/no-stop, stopped-after-timeout, and
  stopped-after-completion cleanup paths. Post-completion cache evidence
  separates no-start/no-cache, timeout with deferred output invalidation, and
  completed output-invalidate application. Active output/cache gate evidence
  ties deferred workspace output readback to deferred output-cache invalidation;
  active output-readback plan evidence ties the primary output transfer byte
  count, DATA slot offset, and invalidate range to that same deferred gate;
  active output-transfer scope evidence proves the current simple fixture is a
  primary-output-only equivalence target, with no mid-output readback or
  invalidate range pending;
  active exit-cleanup evidence ties the timeout policy, suppressed interrupt
  clear, clock gate, stop-after-inference, deferred invalidate, and deferred
  output readback into one contract. Active recovery-frontier evidence then
  shows the remaining blocker is the missing completion signal on the M0 polling
  path, not cleanup or output equivalence. Completion-route-target evidence
  keeps the recovered SDK semaphore/`CNN_IRQn` request tied to the preserved D0
  APU route target while proving the M0 handler/clear/priority/enable side
  effects remain deferred and polling is preserved until local binding is
  verified. Output-equivalence frontier evidence then proves that the frontier
  is live-route-backed, output readback and compare have not started on the
  active timeout path, no mismatch has been observed, and output equivalence
  becomes the next meaningful frontier only after the completion route is
  resolved. Completion-to-output handoff
  evidence composes those facts so the active path has one explicit contract:
  resolve the deferred completion route, then validate the primary output
  readback/compare plan. Active completion-wait-budget evidence separately
  composes the recovered completion policy, polling-wait terminal, timeout
  registers, and wait-exit classification to prove the observed terminal is the
  deterministic exhausted polling budget, not an output stall or an unconfigured
  wait. Active post-budget output-gate evidence then ties that exhausted budget
  to the live-route-backed handoff and deferred primary-output readback/compare
  plan, proving output equivalence is the next stage after completion recovery
  rather than the current active failure. Active gap output-route evidence then
  binds the earlier completion-gap reason to that live-route-backed output gate,
  keeping the active blocker classified as missing completion signal instead of
  output equivalence. Active recovery route-frontier evidence now ties the
  cleanup/frontier state to the live route aggregate and output-gate bridge, so
  the current recovery frontier is explicitly completion-route recovery; its
  typed first-block reason distinguishes frontier, route-aggregate,
  gap-output-route, completion-signal, polling, live-route, output-gate, and
  output-equivalence bridge failures. Active completion-route resolution
  evidence then ties that live frontier back to the concrete SDK/D0 route
  target while preserving M0 polling and deferred local IRQ operations. The
  route target now also carries typed first-block diagnostics for frontier,
  signal, binding, API-contract, SDK-route, D0-route, M0-polling,
  local-binding, API-call, operation-plan, GLB-route, and MM-aggregate route
  failures. Active completion-route aggregate evidence carries the matching
  live MM aggregate first-block diagnostics for frontier, signal, wait-exit,
  route-target, snapshot, interrupt, subroute, polling, and deferred-target
  failures; route-resolution diagnostics then classify route-target,
  route-frontier, SDK route, local-binding, route-operation, polling,
  live-frontier, and output-gate failures.
- `BlaiNpuCompletionWaitPlan`, `NpuInterruptPollResult`,
  `NpuInterruptPollTerminalPlan`,
  `BlaiNpuCompletionStatusResult`,
  `BlaiNpuCompletionStartPlan`, `BlaiNpuCompletionExitPlan`,
  `BlaiNpuPollingWaitTerminal`, `BlaiNpuPollingWaitEvidencePlan`,
  `BlaiNpuPollingWaitEvidence`,
  `BlaiNpuCompletionSideEffectPath`,
  `BlaiNpuCompletionSideEffectPlan`, `BlaiNpuCompletionSideEffectEvidence`,
  `BlaiNpuClockExitPath`, `BlaiNpuClockExitEvidence`,
  `BlaiParsedForwardConfiguredWorkspaceActivePollingSignalEvidence`,
  `BlaiParsedForwardConfiguredWorkspaceActiveMmAggregateWaitExitBlock`,
  `BlaiParsedForwardConfiguredWorkspaceActiveMmAggregateWaitExitEvidence`,
  `BlaiNpuCompletionWaitResult`, `blaiNpuCompletionStatusInto`,
  `blaiNpuCompletionStatusResult`, `blaiNpuPollingWaitEvidencePlanInto`,
  `blaiNpuPollingWaitEvidencePlan`, `blaiNpuPollingWaitEvidence`,
  `blaiNpuCompletionSideEffectPlanInto`,
  `blaiNpuCompletionSideEffectPlan`, `blaiNpuCompletionSideEffectEvidence`,
  `blaiNpuClockExitEvidence`,
  `npuPlanCompletionWait`, `blaiNpuCompletionStartPlanInto`,
  `blaiNpuCompletionStartPlan`, `blaiNpuCompletionExitPlanInto`,
  `blaiNpuCompletionExitPlan`, `blaiPlanForwardNpuCompletionWaitInto`,
  `blaiPlanForwardNpuCompletionWait`, `npuWaitForCompletionInto`, and
  `npuWaitForCompletion`, `npuInterruptPollTerminalPlanInto`,
  `npuInterruptPollTerminalPlan`, `npuWaitForInterruptInto`, and
  `npuWaitForInterruptResult` expose the recovered
  `blai_npu_inference`
  start/resume, interrupt wait, acknowledgement, and clock-disable policy as
  typed pure Nim state. The start plan owns the initial unsupported-vs-starting
  decision before clock/start/poll side effects, the poll terminal and polling
  evidence plans own exhausted-vs-completed budget classification, the exit
  plan owns the post-poll interrupt-clear and clock-gate decisions, and the
  side-effect plan owns public evidence for those side effects. The wait result echoes the configured timeout,
  clear-on-complete, and clock-disable policy; the poll result records the
  configured budget, polls consumed, final interrupt sample, and budget
  exhaustion so callers can audit the live wait boundary after an unsupported,
  timed-out, or completed run. Completion status preserves whether a run was
  unsupported, timed out, or observed the completion interrupt before collapsing
  to the legacy `NpuError`. Polling-wait evidence now classifies unsupported,
  observed-interrupt, and timeout terminals explicitly and checks that the
  terminal reason matches the status projection. Side-effect evidence separately
  classifies unsupported no-start, timeout no-clear/clock-exit, and completed
  interrupt-clear/clock-exit paths. Clock-exit evidence ties the retained
  320 MHz wait-exit clock snapshot to the post-wait clock gate. `BlaiParsedForwardConfiguredWorkspaceCompletionSignalEvidence`
  ties the SDK CNN IRQ semaphore expectation, recovered interrupt request,
  unverified local binding, active polling wait, and missing live interrupt bit
  into one typed result. Active polling-signal evidence ties that result to the
  measured poll trace: the full budget was consumed, the final sample was clear,
  no interrupt was observed, and local binding remains deferred. Active MM
  aggregate wait-exit evidence classifies the live raw status/mask snapshot with
  typed first-block diagnostics for signal, route, catalog, snapshot, bank,
  raw-bank, clear-plan, interrupt, pending-class, named-subroute, subroute, and
  polling failures. The focused M0 model smoke now checks the runtime
  ownership projection, interrupt-binding readiness, completion status
  projection, explicit wait-plan options, run-plan-derived wait policy, and
  active completion signal source on device.
- `blaiExecuteForwardModelConfiguredInto` and
  `blaiExecuteForwardModelConfigured` also accept `BlaiCpuParsedLayerState`
  arrays, so parsed model sidecars can flow through live configured execution
  without being flattened back into parallel raw layer tables.
- `blaiCacheRangeInto`, `blaiNpuInputCleanRangeInto`, and
  `blaiNpuOutputInvalidateRangeInto` recover the SDK cache-maintenance ranges
  as caller-owned DATA-buffer offsets and lengths; the result-returning forms
  remain convenience wrappers. `blaiCacheRangeAddress` and
  `blaiApplyForwardNpuCacheRanges` are exercised on device by the focused M0
  model smoke for clean/invalidate range addresses, overflow rejection, and
  aggregate cache-range application; the same image now checks the
  `blaiExecuteForwardNpuRun` pre-start overflow guard.
- `blaiStoreTensorToNpuBufferInto` / `blaiStoreTensorToNpuBuffer` stage compact
  tensor bytes into row-padded NPU buffers and write zero padding. The `Into`
  form reports DATA-buffer fit, tensor fit, typed DATA-window fit, and movement
  status in caller-owned result storage. `BlaiTensorRowByteCursor` records the
  recovered compact row index, padded DATA index, and whether the byte is data or
  padding before store/load helpers touch the window.
  `blaiStoreTensorRowPatternToNpuBuffer` is the typed fixture writer for
  deterministic output rows; `blaiTensorRowPatternValue` owns the recovered
  row-stride/channel byte projection, and the writer uses the same tensor
  window and row cursor instead of seeding DATA buffers with absolute byte
  indexes.
- `blaiLoadTensorFromNpuBufferInto` / `blaiLoadTensorFromNpuBuffer` compact
  padded NPU output rows back into tensor bytes, with the same caller-owned
  movement result.
- `blaiStageForwardNpuInputInto`, `blaiStageForwardNpuInput`,
  `blaiLoadForwardNpuOutputInto`, and `blaiLoadForwardNpuOutput` compose the
  recovered `forward_NPU` input/output plans with caller-owned DATA-buffer
  bounds checks for the common model-validation path. The movement results keep
  the detailed DATA-buffer fit, compact tensor fit, and slot-level move evidence
  alongside compatibility booleans. The `Into` forms keep the tensor I/O result
  in caller-owned storage. The focused M0 model smoke now exercises forward input
  staging and output readback on device, including required/provided byte
  diagnostics for successful movement, short compact tensors, and short
  DATA-buffer rejection.
  `BlaiForwardTensorIoBlock`, `BlaiForwardTensorIoReadiness`,
  `blaiForwardTensorIoReadinessInto`, and `blaiForwardTensorIoReadiness` split
  the movement gate into runnable layer, active transfer, DATA-buffer fit, and
  compact tensor fit state, with first-block reasons for each rejected gate; the
  staging and loading results carry that readiness alongside the compatibility
  booleans.
  `BlaiForwardWorkspaceTensorIoResult`,
  `blaiStageForwardWorkspaceInputInto`,
  `blaiStageForwardWorkspaceInput`, `blaiLoadForwardWorkspaceOutputInto`, and
  `blaiLoadForwardWorkspaceOutput` extend the same movement helpers to a bound
  whole-model workspace. They check the live workspace binding and DATA segment
  fit before delegating to the DATA-buffer movement routines, so generated live
  fixtures do not need to manually slice the DATA segment out of the workspace
  byte array. The focused M0 model smoke exercises successful whole-workspace
  input staging/output readback plus unbound and short DATA-segment first-block
  reporting on device.
  `BlaiForwardModelOutputValidationBlock`,
  `BlaiForwardModelOutputValidationResult`,
  `blaiForwardModelOutputValidationInto`, and
  `blaiForwardModelOutputValidation` combine reusable-workspace or live
  configured-model completion, compact output readback, and CPU-reference
  output comparison into one post-run validation result. The result carries
  expected and actual element counts, length-match state, compared, trailing,
  and mismatch counts, direct first-mismatch expected/actual byte evidence, and
  a typed first-block reason that separates execution, readback, and compare
  failures. It also preserves the first execution block
  from the path that supplied the result, so reusable workspace and configured
  live runs can feed the same output-equivalence gate.
  `BlaiForwardModelOutputValidationReadiness`,
  `blaiForwardModelOutputValidationReadinessInto`, and
  `blaiForwardModelOutputValidationReadiness` derive the same gate as a compact
  public readiness summary, including expected/actual element counts,
  length-match state, and direct first-mismatch byte evidence.
  `blaiForwardModelOutputFirstMismatch` gives generated fixtures a named,
  allocation-free accessor for the first mismatch index without inflating the
  stored validation record.
  `blaiValidateForwardModelOutputInto` and
  `blaiValidateForwardModelOutput` compose readback, byte comparison, and that
  typed validation result for both reusable-workspace and configured live
  execution results. This is the validation surface intended for generated live
  NPU fixtures once those models produce hardware output.
  `BlaiForwardWorkspaceOutputValidationResult`,
  `blaiValidateForwardWorkspaceOutputInto`, and
  `blaiValidateForwardWorkspaceOutput` add the same post-run validation gate for
  bound whole-model workspaces while preserving the whole-workspace readback
  diagnostics, expected/actual/trailing element counts, length-match state,
  full `BlaiUint8OutputCompareResult`, and direct first-mismatch
  expected/actual byte evidence. Live generated fixtures
  can therefore compare NPU output directly from a bound workspace and still
  distinguish execution, workspace readback, and CPU-reference mismatch
  failures. `blaiForwardWorkspaceOutputFirstMismatch` exposes the same first
  mismatch index for bound workspace output checks, with expected/actual bytes
  preserved in the nested compare detail.
  `BlaiForwardWorkspaceOutputValidationReadiness`,
  `blaiForwardWorkspaceOutputValidationReadinessInto`, and
  `blaiForwardWorkspaceOutputValidationReadiness` expose the bound-workspace
  output-equivalence gate with nested model-output readiness, workspace
  readback state, expected/actual/trailing element counts, length-match state,
  direct first-mismatch byte evidence, and mirrored execution/readback/compare
  first-block reasons.
  `BlaiForwardWorkspaceHardwareAddressReadiness`,
  `blaiForwardWorkspaceHardwareAddressReadinessInto`, and
  `blaiForwardWorkspaceHardwareAddressReadiness` split live hardware register
  configurability from byte-buffer binding. This catches the important zero
  address sentinel case: a caller-owned byte array may be valid for safe DATA
  slicing, while still being unusable as BLAI instruction/DATA/weight/bias
  register addresses. Explicit-address binding lets fixture generators pass a
  known nonzero workspace base through the same readiness gate without relying
  on host-language pointer casts.
  `BlaiForwardWorkspaceFixtureValidationResult`,
  `blaiValidateForwardWorkspaceFixtureInto`, and
  `blaiValidateForwardWorkspaceFixture` compose the raw-layer fixture path:
  bind caller-owned workspace bytes, stage compact input through the DATA
  segment, materialize/execute with a caller-supplied layer executor, and
  validate bound-workspace output against a CPU-reference tensor. The executor
  hook keeps fake-executor smoke tests and live NPU fixture runs on the same
  typed validation surface.
  `blaiValidateForwardWorkspaceAddressFixtureInto` and
  `blaiValidateForwardWorkspaceAddressFixture` provide the same raw-layer
  fixture validation when generated fixtures already know the hardware-visible
  workspace base address.
  `BlaiForwardWorkspaceFixtureValidationReadiness`,
  `blaiForwardWorkspaceFixtureValidationReadinessInto`, and
  `blaiForwardWorkspaceFixtureValidationReadiness` derive the same raw fixture
  first-block decision from caller-owned result storage, so generated fixtures
  can report the top-level gate without rewalking nested binding/input/execute
  and output objects. The readiness result embeds the bound-workspace output
  readiness summary and directly exposes output-match state, compared-element
  count, mismatch count, first-mismatch index, and first-mismatch expected/actual
  byte evidence.
  `BlaiParsedForwardWorkspaceFixtureValidationResult`,
  `blaiValidateParsedForwardWorkspaceFixtureInto`, and
  `blaiValidateParsedForwardWorkspaceFixture` provide the same composition for
  parsed-layer state tables. They bind the parsed model resource plan to live
  workspace bytes, splice that bound workspace into the parsed execution plan,
  stage input, execute, and compare output while preserving parsed sidecar
  state. `blaiValidateParsedForwardWorkspaceAddressFixtureInto` and
  `blaiValidateParsedForwardWorkspaceAddressFixture` run the parsed fixture
  path from an explicit hardware-visible workspace base instead of an inferred
  Nim byte-array address.
  `BlaiParsedForwardWorkspaceFixtureValidationReadiness` and its `Into`/
  convenience helpers provide the matching parsed-state fixture projection with
  the same nested output-readiness summary and direct output-equivalence
  mismatch evidence, including top-level expected/actual/trailing element
  counts and length-match state copied from the nested output gate.
  `BlaiTfliteParsedWorkspaceOracleValidationResult`,
  `BlaiTfliteParsedWorkspaceOracleValidationReadiness`,
  `blaiTfliteParsedWorkspaceOracleValidationInto`, and
  `blaiTfliteParsedWorkspaceOracleValidation` combine a checked TFLite CPU
  oracle with the parsed workspace fixture verdict, preserving the reference
  first block, fixture first block, output-valid state, uint8 compare evidence,
  completed-layer count, expected/actual/trailing element counts, length-match
  state, compared-element count, mismatch count, output first-block evidence,
  top-level oracle-vs-fixture failure classification,
  and `blaiTfliteParsedWorkspaceOracleFirstMismatch` for stack-safe compare
  diagnostics in generated model fixtures; the readiness helpers expose the
  same verdict plus compact output-validation readiness and nested
  parsed-fixture readiness.
  `BlaiTfliteParsedWorkspaceOracleAddressFixtureResult`,
  `BlaiTfliteParsedWorkspaceOracleAddressFixtureReadiness`,
  `blaiValidateTfliteParsedWorkspaceOracleAddressFixtureInto`, and
  `blaiValidateTfliteParsedWorkspaceOracleAddressFixture` compose the generated
  TFLite fixture boundary from a checked CPU oracle, raw workspace byte
  projection, explicit hardware-visible workspace base, parsed fixture
  execution, and oracle-vs-fixture validation while preserving projection,
  validation first-block diagnostics, output-valid/output-match state,
  expected/actual/trailing element counts, length-match state, compare counts,
  first-mismatch expected/actual byte evidence, output first-block diagnostics, and
  `blaiTfliteParsedWorkspaceOracleAddressFirstMismatch`; the readiness helpers
  expose the same top-level gates plus compact output-validation readiness and
  nested parsed-fixture readiness. The fixed-point parsed workspace oracle
  address fixture exposes the same top-level output evidence after projecting
  int8 CPU-reference output into raw workspace bytes.
  `BlaiParsedForwardConfiguredWorkspaceFixtureResult` and its `Into`/
  convenience helpers provide the prepared configured-live variant for generated
  fixtures: an explicit workspace address is bound, DATA input is staged, the
  parsed-state model is run through the live configured executor, and the
  workspace output is validated with binding, address, input, execution, and
  output first-block diagnostics preserved. Its readiness projection also
  carries the nested output-readiness summary plus direct output-equivalence
  mismatch evidence, expected/actual/trailing element counts, and length-match
  state for generated live output-equivalence fixtures.
  `BlaiParsedForwardConfiguredWorkspaceOutputEquivalenceReadinessEvidence`
  now names the generated live output-equivalence gate explicitly: the
  recovered output transfer/compare plan is ready, but readback and comparison
  remain blocked until the active completion route is resolved. The readiness
  evidence carries a typed first-block reason for route-resolution, handoff,
  post-budget, output-frontier, and completion gates.
  `blaiMaterializeAndValidateParsedForwardConfiguredWorkspaceAddressFixtureInto`
  adds the generated-fixture composition boundary: it binds an explicit
  hardware-visible workspace base, materializes parsed instruction/weight/bias
  workspace bytes with pure Nim helpers, and then enters the same configured
  live validation path while returning materialization and fixture evidence in
  caller-owned output records. Early exits still preserve typed configured
  fixture evidence: binding failures report the binding first block, and
  materialization failures keep the successful binding plus hardware-address
  readiness projection before live input staging is skipped.
  `BlaiTfliteParsedConfiguredWorkspaceOracleAddressFixtureResult`,
  `BlaiTfliteParsedConfiguredWorkspaceOracleAddressFixtureReadiness`,
  `blaiValidateTfliteParsedConfiguredWorkspaceOracleAddressFixtureInto`,
  `blaiValidateTfliteParsedConfiguredWorkspaceOracleAddressFixture`,
  `blaiTfliteParsedConfiguredWorkspaceOracleAddressFixtureReadinessInto`, and
  `blaiTfliteParsedConfiguredWorkspaceOracleAddressFixtureReadiness` add the
  TFLite CPU-oracle projection layer on top of that configured-live fixture, so
  generated TFLite live fixtures can carry CPU-reference projection, reference
  validity, configured fixture first-block diagnostics, output-valid state,
  output-match evidence, completed-layer count, compared-element count,
  mismatch count, first-mismatch index and expected/actual byte evidence,
  output validation first-block evidence,
  `blaiTfliteParsedConfiguredWorkspaceOracleAddressFirstMismatch`, direct
  compact output-validation readiness, and nested fixture-readiness evidence
  through one typed result.
  `blaiMaterializeAndValidateTfliteParsedConfiguredWorkspaceOracleAddressFixtureInto`
  composes the same oracle projection with parsed workspace materialization
  before entering the configured-live fixture.
  `blaiValidateTfliteParsedConfiguredWorkspaceOracleFixtureInto` and
  `blaiMaterializeAndValidateTfliteParsedConfiguredWorkspaceOracleFixtureInto`
  provide the same generated-oracle composition for projected caller-owned
  workspace buffers, so cached RAM aliases are converted to hardware-visible
  addresses before live register planning instead of requiring a synthetic base
  address from the caller. Focused smoke coverage currently
  keeps this path on the zero-address hardware-readiness guard, the
  materialize-wrapper binding guard, and a positive-address skipped-layer output
  validation path before live NPU layer start, exercises the projected-buffer
  generated-oracle wrappers on the skipped-layer path including nested
  execution/run-sequence readiness diagnostics, requires the wrapper
  readiness records to mirror the top-level execution counters and terminal
  execution flags, proves the projected-buffer first-mismatch accessor name
  on the configured-live output-mismatch result, and proves that a
  positive-address skipped-layer output mismatch fails through the output-compare first block
  with first-mismatch evidence directly available from both the typed result
  and readiness summary, and carries an active-layer positive-address
  missing-weight run-config guard through the configured fixture and oracle
  wrappers after input staging and before live NPU start, including the first
  blocked layer and recovered `blaiForwardNpuRunConfigWeightBuffers` reason.
  A separate active 1x1 convolution probe materializes real instruction,
  DATA, weight, and bias workspace storage through projected caller-owned
  memory, attempts the live configured runner, and classifies the
  materialization, grouped run-sequence classification, readiness, execution,
  and output gates through typed classification evidence with split materialization,
  run-sequence, fixture, and output predicates, a typed terminal-gate snapshot, grouped
  snapshot coherence evidence, snapshot output evidence, grouped snapshot terminal-detail
  evidence, and snapshot runtime evidence plus grouped terminal-gate and execution-gate
  evidence without claiming hardware output equivalence.
  The on-device smoke now also requires the snapshot's execution counters,
  output comparison counters, first-mismatch expected/actual byte evidence,
  run-sequence readiness block, first-blocked run-config reason plus its typed
  readiness detail, first-failed and last-execution wait plans, typed
  runtime-init evidence, workspace-cache and DATA cache-apply results plus
  reusable workspace/DATA cache evidence, launch/post-start register captures, wait-exit
  interrupt/busy/clock register snapshots, completion status decisions,
  interrupt-clear/clock-disable side effects, first-failed execution status,
  and last-execution terminal flags to mirror the configured fixture result.
  Current hardware evidence shows this active fixture now materializes fully with
  split storage/expected/skipped/attempted/ready layer counters, no missing or
  blocked layers, last-ready-layer, first-block, and readiness mirror evidence,
  classifies the terminal path as materialization/run-sequence clear, execution
  gated, and output deferred,
  binds a typed projected workspace address with split WRAM projection, address
  fit, alias, base-in-WRAM, and per-segment WRAM evidence, stages
  input, and reaches live execution before timing out in the completion wait. Wait-exit register
  grouped execution-gate evidence now includes both decoded state and raw `BLAI_INT_CFG` /
  `BALI_GENERAL_CFG` bit checks showing no completion interrupt, clean command
  bits, retained clock, BLAI still busy/idle state evidence, and deferred-output
  zero-counter/no-mismatch evidence; first-failed and last-execution runtime
  snapshots now mirror status, wait-exit BLAI interrupt, live MM_MISC aggregate
  interrupt snapshot, busy/clock state, and completion side effects, and the
  active cache contract groups workspace instruction/weight/bias cleans with the
  first DATA clean; launch-to-start register retention now mirrors the active
  addresses, segment, net-param bits, clean command bits, and observed start;
  active DATA mapping evidence ties the layer-config DATA address, first clean
  DATA range, staged input byte, and planned output slot together; active engine
  progress evidence now ties the execution terminal, run-sequence readiness,
  exact one-attempt/zero-complete/one-fail counters, first-failed capture/start,
  and timeout terminal together; active completion-policy evidence ties the
  configured wait plan, 11-poll timeout, clear-on-complete/clock-disable policy,
  no-interrupt timeout decision, suppressed interrupt clear, and clock-disabled
  exit together; active polling-wait terminal evidence classifies the live
  terminal as timeout with exhausted poll budget and no interrupt; active
  completion-boundary evidence groups completion policy,
  engine progress, timeout evidence, deferred output, no completion interrupt,
  and busy/idle state into one contract; active wait-exit evidence groups the
  raw no-interrupt state, clean command bits, AXI activity classification,
  retained 320 MHz clock, and timeout status, and now classifies the terminal
  as idle, write-active, read-active, or read/write-active through typed
  `BlaiParsedForwardConfiguredWorkspaceWaitExitMode`; the active tiny fixture now
  records a dedicated wait-exit mode evidence object proving the measured timeout
  terminal has a coherent AXI-mode classification with no completion interrupt
  and retained clock. Active output-blocked
  evidence now proves the fixture/readiness gates stop at execution before
  workspace-output movement or compare logic; active completion-gap evidence ties the boundary,
  wait-exit, and output-blocked contracts together, so the remaining active
  block is classified by `BlaiParsedForwardConfiguredWorkspaceActiveGapReason`
  as either missing completion/progress or output equivalence pending; active
  completion-signal evidence now classifies the live notification source as
  bare-metal polling while preserving the core binding policy, suppressed binding
  operation plan, SDK CNN IRQ semaphore request, D0/E907 APU line candidate, M0
  APU header exclusion, GLB MCU source-39 I2C1 alias conflict, SDK-header GLB
  route map, MM_MISC aggregate interrupt surface, unresolved MM aggregate
  subroute, live wait-exit aggregate bitmap decode, and unverified local IRQ
  binding gate. Active MM aggregate wait-exit evidence now
  classifies the live aggregate sample as a valid decoded bank0/E907-bank1
  bitmap with source-header catalog parity, clear-plan parity, typed
  none/unmasked/masked-only pending classification, embedded raw-index scan
  counts plus first raw, unmasked, and masked-only candidate indexes,
  no named CNN/NPU/APU subroute, no BLAI interrupt at the same boundary, and
  polling preserved until the aggregate subroute bit is identified. Active route
  aggregate evidence now ties
  that live aggregate sample to the completion route target, proving the route
  remains deferred through the unknown MM_MISC subroute while the active M0 path
  stays on polling. The completion-to-output handoff now requires that live
  aggregate-backed route evidence before declaring output readback/compare the
  next stage after completion recovery, and active recovery route-frontier
  evidence carries that live route requirement back to the active recovery
  frontier. Active completion-route resolution evidence now binds the concrete
  route target to that live frontier.
  The
  current active hardware terminal is the missing completion signal path, not
  instruction copy, stream termination, packed weight copy, bias copy,
  hardware-address, SDK layer-config argument mapping, input staging, reaching
  the NPU engine attempt, completion-wait policy, output deferral,
  output-readiness classification, or wait-exit terminal classification. The
  active probe's caller-owned workspace
  is now placed in a
  dedicated WRAM linker section and projected from the cached `0x6203_8000`
  region to the hardware-visible `0x2203_8000` region; focused hardware smoke
  coverage proves the projected base plus instruction, DATA, weight, and bias
  workspace segment addresses are all in WRAM while the terminal state remains
  no interrupt plus BLAI busy, ruling out stack OCRAM placement as the active
  fixture blocker.
  The focused model smoke also uses its validation-only linker script to place
  the stack at the top of WRAM, above the JTAG log and NPU workspace, so the
  large typed fixture records can be exercised on device without overflowing
  the 64 KiB M0 RAM stack window used by normal firmware.
  The same active probe now proves the SDK raw NPU clock source (`2`) is
  selected with divider zero and the gate enabled, CNN reset is released, and
  BLAI SRAM ownership is released before the live start; the `SYSRAM_SET`
  request bit reads back clear on hardware, matching pulse/self-clearing
  behavior rather than a persistent latch. Wait-exit evidence also proves the
  NPU clock gate remains enabled at the timeout, so the active block is not
  caused by clock disable, reset assertion, or unreleased BLAI SRAM ownership.
  A typed launch/start register evidence helper, built from typed register
  snapshot evidence and fed by the launch and post-start captures mirrored
  through the terminal gate snapshot, now exposes split launch/start capture
  predicates and the started-state mirror while proving the BLAI instruction,
  weight, bias, DATA address, segment count, and split unsigned-input,
  TensorFlow-mode, and relu-N net-parameter bits match the projected workspace
  before start, and that
  `BLAI_INT_CFG` has split clean predicates for stale start, resume, stop,
  interrupt-clear, and pending interrupt-status bits before launch. The same
  aggregate evidence proves the wait path observed the start
  transition. A
  post-start snapshot proves those same address and split net-parameter
  registers are still visible immediately after the start pulse and that split
  resume, stop, interrupt-clear, and pending interrupt-status bits are not
  spuriously set. Wait-exit evidence preserves the same split resume, stop,
  interrupt-clear, and pending interrupt-status clean predicates while the
  timeout still reports no interrupt, split AXI write/read activity behind
  the BLAI busy state, and split wait-exit clock source-known, 320 MHz source,
  and zero-divider evidence.
  Reusable-workspace cache preparation now cleans the instruction,
  packed-weight, and bias segments before the live start, and the active smoke
  proves through grouped workspace/DATA cache evidence that those absolute clean
  ranges, byte spans, and the first DATA clean range are applied on device. A
  typed active instruction-stream evidence helper now decodes the
  emitted layer descriptor, rebuilds the descriptor bundle, and proves
  byte-for-byte stream equivalence. The active smoke also proves the DATA-buffer cache plan for the tiny
  model: split DATA slot evidence proves distinct input/output slots, projected
  input/output offsets, fit checks, staged-byte presence, and the staged input
  byte cleaned at the projected DATA address while the output byte is planned
  for invalidate at the output slot. The active smoke logs the live fetch
  surface as data too: instruction/DATA/temporary weight/bias addresses,
  instruction/weight/bias byte counts, DATA slot offsets and first bytes, and
  the first two 16-byte instruction records as little-endian words. The current
  live run uses instruction `0x22047400`, DATA `0x22047580`, temporary weight
  `0x22055070`, and temporary bias `0x22055080`, with two 16-byte instructions,
  16 weight bytes, four bias bytes, input slot 0 holding `0x07`, output slot 1
  initially zero, and instruction words
  `00000001 00000000 FFFFE000 1FE00FFF` /
  `02002002 00020000 88000000 80210010`. A typed materialized-workspace
  byte-evidence helper now splits instruction byte-count, fit, and match
  evidence, trailing zero-padding evidence, weight fit/match evidence, and
  bias alignment/fit/match evidence for the instruction, weight, and bias
  workspace segments passed to the live launch. The active smoke also logs the
  raw launch, post-start, and wait-exit BLAI register words alongside decoded
  busy/AXI idle, interrupt-pending, and clock state, so active hardware runs can
  distinguish a bad launch register, lost post-start state, and a
  started-but-no-completion wait terminal. The current live run captures a valid
  launch snapshot with `BALI_GENERAL_CFG = 0xC7050000`, matching instruction,
  weight, bias, DATA, and segment addresses, then a post-start and wait-exit
  `BALI_GENERAL_CFG = 0x47050000`: the start transition clears the idle state,
  leaves the engine busy with AXI write idle and AXI read active, retains the
  320 MHz clock, and still has no `BLAI_INT_CFG` completion bit. The active
  smoke now also snapshots the MM_MISC `codec_misc_1` BLAI command counter and
  the CODEC_MISC BLAI read/write limiter command counters at the same execution
  gate, so the next hardware run can separate descriptor/command consumption
  from a bus-read stall before completion. Current UART/JTAG evidence reports
  `mmRaw=0x00000000`, read limiter `0x00000000`, and write limiter
  `0x00000000` at that boundary, so the active timeout now has a zero-command
  counter snapshot alongside busy/read-active AXI state. The focused active
  fixture now applies the SDK demo's `CODEC_MISC_BLAI_Limit_RD/WR(0x10f)`
  limiter value through the typed Nim bus-limiter plan before launch, with
  pre-launch readback evidence, to test whether the zero limiter state was part
  of the live stall. Current hardware evidence shows those limiter registers
  latch as `0x8000010F`; with the limiter enabled, launch, post-start, and
  wait-exit all read `BALI_GENERAL_CFG = 0xC7050000` (both AXI channels idle)
  and still no `BLAI_INT_CFG` completion bit. That separates the prior
  read-active stall from a limiter-enabled idle/no-completion terminal. A
  timeout-only diagnostic now applies the planned primary output invalidate
  after the failed wait and reads back the active output slot: current hardware
  evidence reports `invAddr=0x22047584`, `invBytes=0x00000004`,
  `invApplied=1`, and `outputByte=0x00000000`, so the limiter-enabled terminal
  is not hiding a stale cached primary-output write. The active fixture now runs
  this one-layer model as SDK layer index 0 and parameterizes register-snapshot
  evidence for the expected first-layer unsigned-input state; current hardware
  reads `BALI_GENERAL_CFG = 0xC7050001` at launch, post-start, and wait-exit,
  confirming the SDK first-layer unsigned bit is preserved while completion and
  primary-output movement are still absent. The active smoke now also proves the
  recovered `Load_NPU_weights` plan for this tiny TFLite 1x1 convolution:
  typed split packed-byte and tile evidence plus active supported 3x3-helper dispatch, one effective input
  channel, one output channel, no temporary grouped buffer, a single 16-byte
  PACK-expanded weight tile whose first byte is the CPU weight and whose
  padding bytes use `tfInput2Offset`, plus split evidence for the one int32
  TFLite bias pack.
  A typed SDK-style
  temporary weight/bias buffer helper and evidence helper now own split
  address-projection, typed-result fit/count/offset, byte-copy,
  `BlaiCheckedByteWindow` range projection wrapped around
  `blaiCheckedIntByteWindow` slice conversion, `BlaiLe32ByteCursor` byte-lane
  extraction/merge, checked
  little-endian bias-word stores and readback shared by temporary and
  reusable-workspace bias staging,
  `BlaiNpuBiasElementBytes` alignment/indexing through
  `BlaiForwardBiasWordCursor`, checked temporary subrange windows, and
  `blaiByteBufferCursor` for recovered byte-offset evidence reads, and
  active/fit/apply/operation/address/byte cache evidence plus the aligned
  weight/bias layout, hardware-address projection, byte contents, and
  cache-clean evidence used for live launch. The reusable workspace cache
  evidence now exposes
  split fit/apply evidence for the grouped workspace clean and split active, fit,
  apply, clean-operation, address, and byte evidence for the instruction,
  weight, and bias cache spans, plus split first-DATA cache range count, active,
  fit, apply, operation, address, and byte evidence.
  Snapshot coherence evidence now exposes split state, first-block, and execution mirror groups,
  including individual materialized/bound/address/input/run/execution/output state mirrors.
  First-block mirror evidence is split across materialization, execution, run-sequence, and output
  block selectors.
  Execution mirror evidence is split across first-failed capture plus last-execution start/status.
  Snapshot output evidence now exposes split layer-count, element-count, length, mismatch-count,
  first-mismatch counter, and expected/actual first-mismatch byte mirrors.
  Snapshot terminal-detail evidence is split across run-sequence readiness/first-blocked
  detail and first-failed/last-execution terminal status bits.
  Snapshot runtime evidence is split across first-failed/last wait plans, cache
  results, launch/start register captures, wait-exit register mirrors, status
  decisions, completion side effects, and run-config readiness.
  Terminal-gate evidence now exposes split known-gate, valid-flag, selected-gate,
  per-branch gate predicates, and active execution-gate predicates.
  Execution-gate evidence now exposes core execution-start/failure predicates plus
  split status classification for timeout, unsupported, busy, and unexpected-ok
  terminal states in addition to wait detail.
  A typed run-plan evidence helper now splits the recovered
  `blai_npu_layer_config` argument projection into layer index, first-layer/reset
  policy, patch size, instruction/DATA/weight/bias buffer addresses, and first
  DATA clean cache range presence/operation/offset/byte-fit evidence. The
  active stream is decoded on device as a single halted TFLite convolution
  stream built from parser-like convolution defaults (`Linear` activation and
  int8 data type), with the recovered fetch operand planner selecting no extra
  descriptor and a zero C2 operand for the single-input 1x1 case. The same
  active smoke now independently rebuilds the TFLite descriptor bundle from the
  recovered fetch-memory plan and verifies the two emitted 16-byte instructions
  match the live stream byte-for-byte; local vendor DWARF/objdump evidence keeps
  the raw `conv_size`, `act_type`, and common control bitfield convention tied
  to the encoder ABI. A typed active-stream semantic evidence helper owns the
  focused smoke's split stream decode/rebuild readiness and bundle match details,
  split one-layer/no-extra/halt, split operand-plan, split parser-like layer defaults,
  per-dimension 1x1 shape, split input/output slot, split stride/dilation/group,
  split fractional fields, split activation/TF-output-offset,
  split common descriptor control bits decoded into `BlaiDecodedLayer`
  (`img_in`, `MAX_check`, `ROUTE_bit`, `MAC_bit`, mid-output state, upsample,
  MAC extension, and `inst_end`),
  split descriptor-bundle plan, and TFLite split side-instruction
  shift/multiplier/clamp checks through a typed decoded quant instruction.
  Instruction preparation now decouples encoding/resource fit from
  run-configuration readiness, and weight workspace planning uses the
  PACK-expanded NPU weight stream instead of the logical CPU stream length.
  The underlying parsed configured fixture covers the same execution gate
  directly.
  `BlaiFixedParsedConfiguredWorkspaceOracleAddressFixtureResult`,
  `BlaiFixedParsedConfiguredWorkspaceOracleAddressFixtureReadiness`,
  `blaiValidateFixedParsedConfiguredWorkspaceOracleAddressFixtureInto`,
  `blaiValidateFixedParsedConfiguredWorkspaceOracleAddressFixture`,
  `blaiFixedParsedConfiguredWorkspaceOracleAddressFixtureReadinessInto`, and
  `blaiFixedParsedConfiguredWorkspaceOracleAddressFixtureReadiness` provide the
  matching fixed-point configured-live oracle composition, projecting int8
  CPU-reference output through the recovered raw-byte mapping before entering
  the same configured-live fixture gates and exposing the same top-level
  output-valid, output-match, completed-layer, compared-element,
  mismatch-count, first-mismatch byte evidence, output-block,
  `blaiFixedParsedConfiguredWorkspaceOracleAddressFirstMismatch`, direct
  compact output-validation readiness, and nested fixture-readiness evidence.
  `blaiMaterializeAndValidateFixedParsedConfiguredWorkspaceOracleAddressFixtureInto`
  adds the fixed-point oracle projection plus parsed workspace materialization
  composition. `blaiValidateFixedParsedConfiguredWorkspaceOracleFixtureInto`
  and `blaiMaterializeAndValidateFixedParsedConfiguredWorkspaceOracleFixtureInto`
  mirror the fixed-point oracle composition for projected caller-owned
  workspace buffers. The focused smoke
  exercises its materialize-wrapper binding guard, positive-address
  skipped-layer output validation and output-mismatch paths, projected-buffer
  skipped-layer generated-oracle validation with nested execution diagnostics
  plus mirrored top-level execution counters and terminal execution flags,
  projected-buffer first-mismatch accessor evidence on the shared configured
  result type,
  and active-layer run-config guard
  alongside the TFLite path.
  `BlaiFixedParsedWorkspaceOracleValidationResult`,
  `BlaiFixedParsedWorkspaceOracleValidationReadiness`, and their
  `Into`/convenience helpers provide the same typed final verdict for fixed
  parsed CPU oracles while preserving the raw workspace byte comparison,
  `blaiFixedParsedWorkspaceOracleFirstMismatch`, compact output-validation
  readiness, and nested parsed-fixture readiness used by live NPU readback.
  `BlaiFixedParsedWorkspaceOracleAddressFixtureResult`,
  `BlaiFixedParsedWorkspaceOracleAddressFixtureReadiness`,
  `blaiValidateFixedParsedWorkspaceOracleAddressFixtureInto`, and
  `blaiValidateFixedParsedWorkspaceOracleAddressFixture` provide the matching
  fixed-point generated-fixture composition path, projecting int8 CPU-oracle
  outputs through the recovered raw-byte mapping before running the parsed
  explicit-address workspace fixture; the readiness helpers carry projection,
  validation, first-mismatch expected/actual byte evidence,
  `blaiFixedParsedWorkspaceOracleAddressFirstMismatch`, compact
  output-validation readiness, and nested parsed-fixture gates as typed data.

These helpers recover the byte movement, cache range planning, per-layer
preparation logic, model-level resource accounting, and typed workspace address
layout without pointer arithmetic. The remaining live validation work is running
simple generated model fixtures on the NPU and comparing hardware outputs
against CPU-reference outputs.

## Recovered Memory Plan Layout

`BLAI_MEM_alloc(net, layer, ctrl)` reads SDK `cpu_inst_layer_t` metadata and
writes a `struct PSRAM_ctrl` memory plan. The encoder archive carries DWARF for
both structures. The Nim `BlaiCpuInstLayer64` object matches the RV64 encoder
ABI for `cpu_inst_layer_t`; SDK pointer fields are fixed-width `uint64` address
slots so the layout is documented without pretending to be a live M0 pointer
overlay.

Important `cpu_inst_layer_t` offsets:

| Offset | SDK field | Nim field |
| --- | --- | --- |
| `0x000` | `type` | `layerType` |
| `0x004` | `activation` | `activation` |
| `0x008` | `output_layer` | `outputLayer` |
| `0x00C` | `h` | `h` |
| `0x010` | `w` | `w` |
| `0x014` | `c` | `c` |
| `0x018` | `cn[7]` | `cn` |
| `0x034` | `out_h` | `outH` |
| `0x038` | `out_w` | `outW` |
| `0x03C` | `out_c` | `outC` |
| `0x044` | `groups` | `groups` |
| `0x048` | `size` | `size` |
| `0x04C` | `stride` | `stride` |
| `0x050` | `dilation` | `dilation` |
| `0x058` | `in_layer1_mem` | `inLayer1Mem` |
| `0x05C` | `in_layer2_mem` | `inLayer2Mem` |
| `0x060` | `out_layer_mem` | `outLayerMem` |
| `0x068` | `in_layer_mem_n` pointer | `inLayerMemN` |
| `0x080` | `fdata` | `fdata` |
| `0x084` | `fweight` | `fweight` |
| `0x088` | `fbias` | `fbias` |
| `0x08C` | `fout` | `fout` |
| `0x090` | `froute1` | `froute1` |
| `0x094` | `froute2` | `froute2` |
| `0x098` | `frouten` pointer | `frouten` |
| `0x110` | `weights` pointer | `weights` |
| `0x118` | `biases` pointer | `biases` |
| `0x140` | `output` pointer | `output` |
| `0x150` | `input[8]` pointer array | `input` |
| `0x280` | `NPU_inst` pointer | `npuInst` |
| `0x290` | `DRAM_in[8]` | `dramIn` |
| `0x2B0` | `DRAM_out[8]` | `dramOut` |
| `0x2D0` | `DRAM_mid_out` | `dramMidOut` |
| `0x2D4` | `DRAM_patch_size` | `dramPatchSize` |
| `0x2D8` | `DRAM_WEI_patch_num` | `dramWeiPatchNum` |
| `0x2DC` | `DRAM_patch_num` | `dramPatchNum` |
| `0x2E0` | `DRAM_weight` | `dramWeight` |
| `0x2E4` | `DRAM_nweight` | `dramNWeight` |
| `0x2E8` | `DRAM_bias` | `dramBias` |
| `0x2EC` | `DRAM_nbias` | `dramNBias` |

The helper `toDecodedLayer(BlaiCpuInstLayer64)` projects the recovered ABI into
the smaller `BlaiDecodedLayer` shape used by `blaiCanRunOnNpu`.

The local SDK source header includes a `builtin_code` field in this region, but
the encoder archive DWARF used by `libblai_npu_encoder.a` does not. DWARF places
`layer_offset` at `0x20C` and `input_layers` at `0x210`, so
`BlaiCpuInstLayer64` follows the blob ABI rather than the newer local header.

The Nim `BlaiPsramCtrl` object matches the `PSRAM_ctrl` output ABI exactly:

| Offset | SDK field | Nim field |
| --- | --- | --- |
| `0x000` | `SRAM_in[8]` | `sramIn` |
| `0x020` | `SRAM_in_2` | `sramIn2` |
| `0x024` | `SRAM_out[8]` | `sramOut` |
| `0x044` | `SRAM_mid_out` | `sramMidOut` |
| `0x048` | `SRAM_weight` | `sramWeight` |
| `0x04C` | `SRAM_bias` | `sramBias` |
| `0x050` | `dw_groups` | `depthwiseGroups` |
| `0x054` | `wei_patch_num` | `weightPatchCount` |
| `0x058` | `line_patch_num` | `linePatchCount` |
| `0x05C` | `line_w_0` | `lineW0` |
| `0x060` | `wei_patch_out_c[64]` | `weightPatchOutC` |
| `0x160` | `line_patch_w[64]` | `linePatchW` |
| `0x260` | `psram_num` | `psramCount` |
| `0x264` | `PSRAM_patch_size` | `psramPatchSize` |
| `0x268` | `PSRAM_patch_num` | `psramPatchCount` |
| `0x26C` | `PSRAM_mid_patch_num` | `psramMidPatchCount` |

The Nim layout exposes named `BlaiPsramCtrl...Offset` constants for these ABI
slots. The host objdump regression test now re-derives the allocator's `sw`
targets from `libblai_npu_encoder.a` and requires the recovered stores to map
through those constants and `offsetof` assertions, so the typed layout is
guarded against vendor-archive or toolchain drift.

The first bounded allocator search is recovered as
`BlaiMemAllocStartPatchPressure`, `BlaiMemAllocStartPatchPlan`, and
`BlaiMemAllocLinePatchPlan`:

- The SDK starts from the larger of the input and output 4 KiB split counts,
  then tries up to 128 larger split counts before failing.
- `blaiMemAllocStartPatchPressure` owns the initial pressure calculation:
  routed channel accumulation, shortcut double-input pressure, convolution
  output-pressure suppression, per-side byte counts, and the final starting
  split count.
- `blaiPlanMemAllocStartPatchInto` and `blaiPlanMemAllocStartPatch` expose that
  pressure through the stable allocator plan API used by the line search.
- `blaiMemAllocLinePatchProbe` owns each candidate line-patch pressure check:
  even input-line rounding, upsample output-line scaling, routed mid-output
  kernel padding, and the input/output 4 KiB fit decision.
- `blaiPlanLinePatchMemAllocInto` fills caller-owned line-patch plan storage.
  `BlaiMemAllocLinePatchApplyPlan` owns the checked int32 ABI projection for
  `line_patch_num` and `line_patch_w[]`, and `blaiApplyLinePatchMemAlloc`
  writes those typed values into the exact `PSRAM_ctrl` fields used by the SDK
  branch.

The high-weight branch after line splitting is recovered as
`BlaiMemAllocWeightPatchPressure` and `BlaiMemAllocWeightPatchPlan`:

- `blaiMemAllocWeightPatchPressure` mirrors the SDK's size/group/dilation
  pressure expression used before weight patching and records which recovered
  formula branch was selected: 1x1, dilated/large-kernel, or normal small
  kernel.
- `blaiEstimateWeightPatchBytes` remains as the stable byte-returning wrapper
  around that typed pressure estimate.
- Layers with recovered weight pressure above
  `BlaiMemAllocWeightPatchThresholdBytes` (8192 bytes) choose a power-of-two
  output-channel patch width.
- `blaiMemAllocWeightPatchStoreEntry` owns each recovered patch-store
  iteration: bounded `wei_patch_out_c[]` slot selection, final-patch channel
  count, output/mid-output byte pressure, PSRAM patch-size contribution, and
  emitted-channel cursor advance.
- `blaiMemAllocPatchCountPlan` owns the final `PSRAM_patch_num` and optional
  `PSRAM_mid_patch_num` calculation after patch-size selection, including the
  recovered `CONV_MAX` extra `wei_patch_num` adjustment.
- `blaiPlanHighWeightPatchMemAllocInto` writes caller-owned `wei_patch_num`,
  `wei_patch_out_c[]`, final `PSRAM_patch_size`, `PSRAM_patch_num`, and
  optional `PSRAM_mid_patch_num` plan values.
- `BlaiMemAllocWeightPatchApplyPlan` owns the checked int32 ABI projection for
  those high-weight/PSRAM patch stores before `blaiApplyHighWeightPatchMemAlloc`
  writes the typed values into `PSRAM_ctrl`.
- `BlaiMemAllocPatchBranchPlan` owns the recovered high-weight versus
  lower-threshold PSRAM branch choice after line splitting, before the composed
  allocator plan falls back to the one-patch path.

The lower-threshold PSRAM patch branch is recovered as
`BlaiMemAllocPsramPatchPressure`, `blaiPlanPsramPatchMemAllocInto`, and
`blaiPlanPsramPatchMemAlloc`:

- The branch is selected when the high-weight estimate is at most
  `BlaiMemAllocWeightPatchThresholdBytes` (8192 bytes) but line-split PSRAM
  pressure still exceeds `BlaiMemAllocPsramPatchThresholdBytes` (4096 bytes).
- `blaiMemAllocPsramPatchPressure` mirrors the SDK per-line output pressure and
  the SDK type-9 (`CONV_MAX`) special case, exposing both the base output-line
  pressure and the recovered route-floor pressure.
- `blaiEstimatePsramPatchBytes` remains as the stable byte-returning wrapper
  around that typed PSRAM pressure estimate.
- The branch reuses the recovered patch-store loop, so `wei_patch_num`,
  `wei_patch_out_c[]`, `PSRAM_patch_size`, `PSRAM_patch_num`, and
  `PSRAM_mid_patch_num` match the high-weight branch store shape.

The small-layer one-patch fallback stores from `BLAI_MEM_alloc` are exposed as
`BlaiMemAllocSinglePatchShape`, `BlaiMemAllocSinglePatchPlan`,
`blaiPlanSinglePatchMemAllocInto`, and `blaiPlanSinglePatchMemAlloc`:

- `weightPatchCount` is fixed to one and `firstWeightPatchOutC` mirrors
  `out_c`.
- `blaiMemAllocSinglePatchShape` owns `out_w * out_h * align4(out_c)`, aligned
  output-channel diagnostics, and the optional mid-output source calculation.
- `psramPatchCount` is fixed to one.
- `psramMidPatchCount` is zero unless `mid_out == 1`; when active it is
  `ceil(w * h * c / psramPatchSize)`, except softmax uses `out_c` instead of
  `c`.
- `midSource` and `midInputElements` record whether that active mid-output
  split used the normal `w * h * c` source or the softmax `w * h * out_c`
  source.
- `BlaiMemAllocSinglePatchApplyPlan` owns the checked int32 ABI projection for
  those stores, and `blaiApplySinglePatchMemAlloc` writes the typed values into
  the exact `PSRAM_ctrl` fields used by the SDK fallback path.

The recovered branch selection is now represented by `BlaiMemAllocPlan`:

- `blaiPlanMemAllocInto` and `blaiPlanMemAlloc` run the line split search,
  then select high-weight patching, lower-threshold PSRAM patching, or the
  one-patch fallback. The `Into` form now composes only caller-owned allocator
  subplans, keeping allocator-backed encoding on caller-owned plan storage.
- `BlaiMemAllocControlApplyPlan` owns the checked composed `PSRAM_ctrl`
  projection for the selected allocator branch, and `blaiApplyMemAllocPlan`
  applies only that pre-validated store plan without offset arithmetic.
- `blaiEncodeCpuLayerWithAllocatorInto` and `blaiEncodeCpuLayerWithAllocator`
  wire that bounded planner into the
  recovered `BLAI_encode` wrapper while preserving explicit allocator-gate
  tests through `blaiEncodeCpuLayerInto` and its result-returning wrapper.
  The focused M0 parser smoke now exercises high-weight patch branch selection,
  lower-threshold PSRAM patch branch selection, and typed `BlaiPsramCtrl`
  application for both paths, plus the route/mid-output line-patch search where
  kernel padding forces the split count beyond the initial 4 KiB pressure
  estimate, in addition to the allocator-backed single-patch encode and
  allocator-failure preservation cases.

The remaining allocator validation work is checking model-specific edge cases
against the vendor oracle and exercising those plans inside complete model
fixtures.

The recovered fetch-memory planner now preserves the SDK patch-growth
diagnostics in `BlaiFetchMemoryPlan`: `patchBudget`, `totalInputPatches`,
`growAttempts`, and `patchGrowCount`. General fetch plans use
`BlaiFetchMaxPatchSlots` (30 slots), while route fetch plans derive the budget
from the route descriptor-loop count and `PSRAM_patch_num`. Both paths expose
the recovered bounded `BlaiFetchPatchGrowTries` (five attempts) behavior before
the descriptor bundle is emitted or caller-visible state is committed.

## Open Recovery Items

- Continue validating BLAI instruction-stream encoding against model-specific
  vendor-oracle fixtures, especially multi-descriptor and edge-case allocator
  branches.
- Use a known SDK sample or generated tiny model as a live output-equivalence
  reference, then feed the configured run result through the shared output
  validation gate.
- Keep the legacy dimension-based convolution facade fail-closed until encoded
  instruction-stream generation for those arguments is validated model by
  model.

## Hardware Smoke Flow

Use the UART flash anchor before flashing NPU work firmware:

```sh
.venv/bin/python tools/hw_validate.py --uart-anchor-probe \
  --uart "$UART_PORT" --uart-baud "${UART_BAUD:-230400}"
```

If the anchor is missing or unresponsive, install it with `--uart-anchor-flash`.
After the anchor is live, flash focused NPU smoke builds with:

```sh
.venv/bin/python tools/hw_validate.py --test m0_npu_smoke_test \
  --uart-anchor-flash --uart-anchor-existing --uart-anchor-runtime-jtag \
  --jtag-memory-log --uart "$UART_PORT" --uart-baud "${UART_BAUD:-230400}"
```

The M0 NPU smoke now also runs parsed-layer CPU oracles on-device: full
parsed-layer fixed/TFLite conv fixtures plus tiny low-footprint parsed
single-layer fixed-point conv+maxpool and TFLite conv+avgpool fixtures. These
are still CPU-reference validation paths, not live BLAI instruction-stream
execution, but they prove the recovered stream cursor, decoded-parameter, layer
math, and dispatch helpers link and run under the same firmware image that
exercises the recovered NPU register and planner surface. Full parsed-layer
results and single-layer readiness both preserve the nested dispatch
first-block reason so stream, support, and tensor-fit failures can be separated
from the recovered layer implementation that rejected execution.
Weight and bias stream cursor advancement is checked as separate on-device
markers using `blaiCompareCpuStreamCursor`, so stream regressions are separated
from layer math failures.
The smoke checks each intermediate/final oracle tensor through
`blaiCompareInt8Outputs` or `blaiCompareUint8Outputs`, so a failed run reports
lengths, compared/trailing element counts, mismatch count, and the first
differing byte instead of only a raw array-equality failure.
The M0 smoke also runs the tiny checked parsed-state model wrappers for the
same fixed-point and TFLite fixtures, including successful execution, short
model-input rejection, inactive parsed-layer skipping, typed second-input
shortcut fixtures, and missing previous-activation failure classification. It
also checks zero-active parsed models and strict model
invalidity for trailing CPU weight and bias streams after all layers complete.
The same image now exercises sidecar-backed fixed-point `ROUTE` and
`ROUTE_MAX` parsed-layer dispatch so route input storage is validated without
following SDK pointer graphs.
Sidecar-backed TFLite `ROUTE`, `ROUTE_MAX`, and `ROUTE_W` parsed-layer
dispatch are covered as well in a smaller route-family smoke image, avoiding
the monolithic M0 NPU smoke's UART/JTAG marker volume while still exercising the
requantized and easy-copy sidecar paths on-device.
Sequential fixed-point conv+maxpool and TFLite conv+avgpool checked models are
covered in a focused parsed-model smoke image, including typed buffer-plan
stream/scratch/output sizing, strict preflight, scratch/output contents, layer
completion, exact CPU stream consumption, and short model-input rejection. The
same focused image covers previous-activation second-input shortcut models for
both fixed-point and TFLite checked model paths.
Recovered CPU/DSP model instruction parsing is covered in a focused parser
smoke image, including typed parsed-layer state, YOLO sidecars, extra-input
sidecars, extra TFLite multipliers, raw float scales, SSD metadata, and
`blaiNetParams` projection. The same image validates the parsed-to-forward
workspace bridge by checking the unencoded-layer gate, post-encoder readiness,
parsed-state workspace planning, executable workspace backing, missing layer
storage rejection, and short workspace rejection. It also validates the
allocation-free `assign_release_layer` recovery by checking normal and
intermediate release arrays, stale counter reset, graph-layer map output, and
graph-map overflow reporting. The parser smoke also validates recovered
`set_output_wh_later` side effects for TRANSPOSE, TRANSPOSE_LK, and PAD,
including missing sidecar and invalid output-shape rejection.
TFLite transform dispatch for MEAN, SOFTMAX's SDK copy path, LOGISTIC's
recovered sigmoid/cutoff path, PAD, RESHAPE, and PRE_TRANSCONV is also
exercised on-device with compact uint8 fixtures.
TFLite TRANSPOSE dispatch is covered with typed mask sidecar storage, including
explicit missing-mask and wrong-layer rejection.
TFLite TRANSPOSELK direct and rolling V2 dispatch are covered on-device with
compact sequence fixtures and wrong-layer rejection.
TFLite DEQUANTIZE dispatch is covered with exact float32 bit checks for the
separate float-output path and wrong-layer rejection.
Short weight/bias stream layer failures and unsupported fixed-point weight
storage gates are also covered in the smoke image, along with fixed/TFLite mode
rejection and TFLite unsupported-layer classification.
Larger parsed-state model coverage remains in compile-time tests until each
remaining fixture is split into a small enough focused M0 smoke image.

The Makefile wraps the same discipline:

```sh
make hw-npu-smoke-anchor UART_PORT=/dev/ttyUSB0
```

That target probes the existing anchor first, installs the persistent
`m0_uart_flash_anchor` firmware if the probe fails, then flashes
`m0_npu_smoke_test` with `--uart-anchor-existing` and validates the mirrored
JTAG memory log so dense UART output cannot hide late markers.
