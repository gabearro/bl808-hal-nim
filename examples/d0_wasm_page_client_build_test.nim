## D0 full-VM SD paging probe. Arm it after M0 reports that the dedicated
## swap file is open and board firmware has initialized and reserved PSRAM.

when not (defined(bl808d0) and defined(bl808kernel) and
    defined(bl808WasmFullScheduler) and defined(wasmChunkedMemory) and
    defined(wasmTieredFrames)):
  {.error: "build as the D0 chunked full-VM scheduler with tiered frames".}

import bl808/[core, memmap, mmio, startup, wasm_page_client, wasm_psram_frames,
  wasm_scheduler]
import bl808/kernel/[cps, ipcbridge]
import cps/wasm/linear_memory
import ../tools/wasm_d0_page_fixture

const
  WasmPsramProbeOffset {.intdefine.} = -1
  StatusAddr = XramBase + 0x3F60'u
  ArmAddr = StatusAddr + 0x10'u
  ArmValue = 0x5750_44A5'u32
  M0PageStatusAddr = XramBase + 0x2E10'u
  M0PageReady = 0x5750_4D00'u32
  StatusWaiting = 0x5750_447F'u32
  StatusPassed = 0x5750_4400'u32
  StatusFailed = 0x5750_4401'u32
  SwapSlots = 4'u32

static:
  doAssert WasmPsramProbeOffset >= 0 and
    WasmPsramProbeOffset <= PsramSize - WasmMemoryChunkBytes.int and
    WasmPsramProbeOffset mod WasmMemoryChunkBytes.int == 0,
    "choose an explicitly reserved, chunk-aligned probe offset"

var
  client: WasmPageClient
  hot: array[WasmMemoryChunkBytes.int, byte]
  owner: WasmPsramFrames
  image: D0PageImage

proc worker(): CpsVoidFuture {.cps.} =
  while regRead(ArmAddr) != ArmValue:
    await sleepMs(10)
  var status = StatusFailed
  var telemetry: WasmSchedulerMemoryTelemetry
  if regRead(M0PageStatusAddr) == M0PageReady and client.initWasmPageClient(SwapSlots) and
      owner.reserveWasmPsramFrames(cast[ptr UncheckedArray[byte]](addr hot[0]),
        WasmMemoryChunkBytes, WasmPsramProbeOffset.uint32, WasmMemoryChunkBytes,
        2, 3, client.addr.linearMemoryBacking(), swapSlots = SwapSlots):
    let started = startD0PageRoundtrip(image, owner)
    if started.status == wasmSchedOk:
      var current = started
      let start = readTick()
      while current.state in {wasmTaskReady, wasmTaskYielded, wasmTaskBlockedMemory} and
          readTick() - start < msToTicks(30_000):
        if current.state == wasmTaskBlockedMemory:
          current = serviceWasmTaskMemoryFault(started.id)
          if current.state == wasmTaskBlockedMemory: await sleepMs(1)
        else:
          current = resumeWasmTask(started.id, 10)
      telemetry = getWasmTaskMemoryTelemetry(started.id)
      if d0PageRoundtripPassed(current, telemetry): status = StatusPassed
      discard client.cancelWasmPageTransfer()
      discard killWasmTask(started.id)
  regWrite(StatusAddr + 4'u, telemetry.pageIns)
  regWrite(StatusAddr + 8'u, telemetry.pageOuts)
  regWrite(StatusAddr + 12'u, heapStats().highWaterBytes.uint32)
  fenceIo()
  regWrite(StatusAddr, status)

proc main() {.exportc, cdecl, noreturn.} =
  systemInit()
  heapInit()
  schedulerInit()
  ipcBridgeInit()
  resetWasmScheduler()
  regWrite(ArmAddr, 0)
  regWrite(StatusAddr, StatusWaiting)
  fenceIo()
  discard worker()
  runScheduler()
