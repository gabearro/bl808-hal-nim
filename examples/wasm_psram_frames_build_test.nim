## Isolated M0/D0 validation image. The board must initialize PSRAM and own
## the supplied scratch offset before the debugger arms this test.
import cps/wasm/linear_memory
import bl808/[core, memmap, mmio, startup, wasm_psram_frames, wasm_scheduler]
import bl808/kernel/alloc
import ../tools/wasm_psram_frames_fixture

when not defined(bl808kernel) or not defined(bl808WasmFullScheduler) or
    not defined(wasmChunkedMemory) or not WasmTieredFramesEnabled:
  {.error: "build with the chunked full scheduler and wasmTieredFrames".}

const
  WasmPsramProbeOffset {.intdefine.} = -1
  StatusAddr = when defined(bl808m0): XramBase + 0x3F10'u
    else: XramBase + 0x3F20'u
  ProbeWaiting = 0x5750537F'u32
  ProbeArm = 0x575053A5'u32
  ProbePassed = 0x57505300'u32
  ProbeFailed = 0x57505301'u32

static:
  doAssert WasmPsramProbeOffset >= 0 and
    WasmPsramProbeOffset <= PsramSize - WasmMemoryChunkBytes.int and
    WasmPsramProbeOffset mod WasmMemoryChunkBytes.int == 0,
    "choose an explicitly reserved, chunk-aligned PSRAM probe offset"

var
  hot: array[WasmMemoryChunkBytes.int, byte]
  owner: WasmPsramFrames

proc main() {.exportc, cdecl, noreturn.} =
  systemInit()
  heapInit()
  regWrite(StatusAddr, ProbeWaiting)
  fenceIo()
  while regRead(StatusAddr) != ProbeArm: discard
  let sram = cast[ptr UncheckedArray[byte]](addr hot[0])
  resetWasmScheduler()
  var passed = owner.reserveWasmPsramFrames(sram, WasmMemoryChunkBytes,
    WasmPsramProbeOffset.uint32, WasmMemoryChunkBytes, 2, 2) and
    runPsramFrameTask(owner) and hot[^1] == 0x78
  if passed:
    let address = PsramBase + WasmPsramProbeOffset.uint
    dcacheCleanInvalidateRange(address, WasmMemoryChunkBytes.uint)
    fenceIo()
    passed = regRead(address) == 0x00123456'u32
  regWrite(StatusAddr + 4'u, heapStats().highWaterBytes.uint32)
  regWrite(StatusAddr, if passed: ProbePassed else: ProbeFailed)
  fenceIo()
  while true: wfi()
