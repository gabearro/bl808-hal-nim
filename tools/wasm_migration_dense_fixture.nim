## Guest compiled from tools/wasm_migration_dense.wat.
import cps/wasm/[linear_memory, types]

const
  WasmDenseModule* = [
    byte 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x06, 0x01, 0x60,
    0x01, 0x7f, 0x01, 0x7f, 0x03, 0x02, 0x01, 0x00, 0x05, 0x04, 0x01, 0x01,
    0x01, 0x01, 0x07, 0x07, 0x01, 0x03, 0x72, 0x75, 0x6e, 0x00, 0x00, 0x0a,
    0x16, 0x01, 0x14, 0x00, 0x41, 0x00, 0x41, 0xa5, 0x01, 0x20, 0x00, 0xfc,
    0x0b, 0x00, 0x20, 0x00, 0x41, 0x04, 0x6b, 0x28, 0x00, 0x00, 0x0b]
  WasmDenseCheckpoint* = 4'u32
  WasmDenseResult* = cast[int32](0xA5A5A5A5'u32)
  WasmDenseProbeBytes* = when defined(bl808lp): 768'i32 else: 6144'i32
  WasmDenseProbeCapacity* = when defined(bl808lp): 1024 else: 8192
  WasmDenseInlineLimit* = when defined(bl808lp): 512 else: 4096

proc denseMemoryFactory*(ctx: pointer, memType: MemType): ref LinearMemory =
  if memType.limits.min != 1 or not memType.limits.hasMax or memType.limits.max != 1:
    return nil
  const chunks = (WasmDenseProbeBytes.uint32 + WasmMemoryChunkBytes - 1) div WasmMemoryChunkBytes
  new(result)
  if result[].initLinearMemory(LinearMemoryConfig(initialPages: 1, maxPages: 1,
      admissionPages: 1, maxCommittedChunks: chunks, residentChunks: chunks)) != lmOk:
    return nil

when defined(wasmStagedMigrationProbe):
  from cps/wasm/runtime import WasmPortableStaging

  when defined(bl808lp):
    var denseStaging: array[WasmDenseProbeCapacity, byte]
  else:
    from bl808/memmap import PsramBase, PsramSize
    const WasmMigrationProbePsramOffset {.intdefine.} = -1
    static:
      doAssert WasmMigrationProbePsramOffset >= 0 and
        WasmMigrationProbePsramOffset <= PsramSize - WasmDenseProbeCapacity and
        WasmMigrationProbePsramOffset mod 512 == 0,
        "reserve an aligned PSRAM workspace for this probe"

  proc denseMigrationStaging*(): WasmPortableStaging =
    ## Arm the probe only after the board owner has initialized PSRAM and
    ## set aside this range for the local core. LP reserves its own SRAM.
    let base = when defined(bl808lp): cast[uint](addr denseStaging[0])
               else: PsramBase + WasmMigrationProbePsramOffset.uint
    WasmPortableStaging(data: cast[ptr UncheckedArray[byte]](base), len: WasmDenseProbeCapacity)
