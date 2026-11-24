import bl808/[wasm_psram_frames, wasm_scheduler, wasm_store]

## tools/wasm_d0_page_roundtrip.wat. Three dirty chunks force a swap with
## only one SRAM and one PSRAM frame. The cross-page reload checks the bytes.
const WasmD0PageModule* = [
  byte 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x05, 0x01, 0x60,
  0x00, 0x01, 0x7f, 0x03, 0x02, 0x01, 0x00, 0x05, 0x04, 0x01, 0x01, 0x02,
  0x02, 0x07, 0x0d, 0x01, 0x09, 0x72, 0x6f, 0x75, 0x6e, 0x64, 0x74, 0x72,
  0x69, 0x70, 0x00, 0x00, 0x0a, 0x20, 0x01, 0x1e, 0x00, 0x41, 0xff, 0xff,
  0x03, 0x41, 0xf8, 0xac, 0xd1, 0x91, 0x01, 0x36, 0x00, 0x00, 0x41, 0x00,
  0x41, 0xd5, 0x00, 0x3a, 0x00, 0x00, 0x41, 0xff, 0xff, 0x03, 0x28, 0x00,
  0x00, 0x0b]

type D0PageImage* = array[WasmProgramHeaderLen.int + WasmD0PageModule.len, byte]

proc startD0PageRoundtrip*(image: var D0PageImage,
                            owner: var WasmPsramFrames,
                            slotLabel = -1'i32): WasmSchedulerResult =
  let base = cast[ptr UncheckedArray[byte]](addr image[0])
  if initWasmProgramImage(base, image.len.uint32, WasmD0PageModule) != wasmProgramOk:
    return WasmSchedulerResult(status: wasmSchedOpenFailed)
  startFullWasmImageTaskI32(base, image.len.uint32, "roundtrip", [],
    maxTotalFuel = 64, maxMemoryPages = 2, slotLabel = slotLabel,
    memoryFactory = wasmPsramMemoryFactory,
    memoryFactoryContext = addr owner)

proc d0PageRoundtripPassed*(task: WasmSchedulerResult,
                             memory: WasmSchedulerMemoryTelemetry): bool =
  task.status == wasmSchedOk and task.state == wasmTaskExited and
    task.result == 305419896 and memory.fullInterpreter and
    memory.committedChunks == 3 and memory.sramResidentChunks == 1 and
    memory.psramResidentChunks == 1 and memory.pageIns > 0 and
    memory.pageOuts > 0 and memory.completedFaults > 0 and
    memory.backingFailures == 0
