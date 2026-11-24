## Build-only LP full-VM page-fault worker. Its M0 peer must own and serve a
## dedicated swap file before this image can be exercised on the Ox64.
## The core-local scheduler drives bounded XRAM RPC only after VM suspension.

when not defined(bl808lp) or not defined(bl808kernel) or
    not defined(bl808WasmFullScheduler) or not defined(wasmChunkedMemory):
  {.error: "build as the LP chunked full-VM scheduler".}

import bl808/[startup, core, mmio, wasm_lp_softfloat, wasm_lp_page_client,
  wasm_remote_page_corpus, wasm_runtime, wasm_scheduler, wasm_store]
import bl808/kernel/[alloc, cps, ipcbridge, sched]
import cps/wasm/[linear_memory, types]

const
  StatusAddr = 0x40002E90'u
  StatusStarted = 0x5750_4C7F'u32
  StatusPassed = 0x5750_4C00'u32
  StatusFailed = 0x5750_4C01'u32
  MaxPolls = 2000

static:
  doAssert WasmLpNativeStackBytes == 5632,
    "the LP page client build requires its measured native stack reservation"

var
  pageClient: WasmLpPageClient
  resident: array[WasmMemoryChunkBytes.int, byte]
  memory: ref LinearMemory

proc makeMemory(ctx: pointer, memType: MemType): ref LinearMemory =
  discard ctx
  if memType.limits.min != 2 or memType.limits.max != 2:
    return nil
  memory

proc taskPassed(task: WasmSchedulerResult, pageIns, pageOuts: uint32): bool =
  task.status == wasmSchedOk and task.state == wasmTaskExited and
    task.result == 305419896'i32 and pageIns > 0 and pageOuts > 0

proc worker(): CpsVoidFuture {.cps.} =
  var status = StatusFailed
  var pageIns = 0'u32
  var pageOuts = 0'u32
  var image = newSeq[byte](WasmProgramHeaderLen.int + WasmRemotePageCorpus.len)
  if initWasmProgramImage(
      cast[ptr UncheckedArray[byte]](addr image[0]), image.len.uint32,
      WasmRemotePageCorpus) == wasmProgramOk:
    resetWasmScheduler()
    let started = startFullWasmImageTaskI32(
      cast[ptr UncheckedArray[byte]](addr image[0]), image.len.uint32,
      "cross_page", [], maxTotalFuel = 64, maxMemoryPages = 2,
      memoryFactory = makeMemory)
    if started.status == wasmSchedOk:
      var current = started
      var polls = 0
      while current.state in {wasmTaskReady, wasmTaskYielded,
                              wasmTaskBlockedMemory} and polls < MaxPolls:
        if current.state == wasmTaskBlockedMemory:
          current = serviceWasmTaskMemoryFault(started.id)
        else:
          current = resumeWasmTask(started.id, 10)
        inc polls
        await yieldNow()
      let telemetry = getWasmTaskMemoryTelemetry(started.id)
      pageIns = telemetry.pageIns
      pageOuts = telemetry.pageOuts
      if taskPassed(current, pageIns, pageOuts):
        status = StatusPassed
      discard killWasmTask(started.id)
  regWrite(StatusAddr + 4'u, pageIns)
  regWrite(StatusAddr + 8'u, pageOuts)
  regWrite(StatusAddr + 12'u, heapStats().highWaterBytes.uint32)
  regWrite(StatusAddr, status)
  fenceIo()

proc main() {.exportc, cdecl, noreturn.} =
  systemInit()
  heapInit()
  regWrite(StatusAddr, StatusStarted)
  schedulerInit()
  ipcBridgeInit()
  if not pageClient.initWasmLpPageClient(4):
    regWrite(StatusAddr, StatusFailed)
  else:
    new(memory)
    let config = LinearMemoryConfig(initialPages: 2, maxPages: 2,
      admissionPages: 2, maxCommittedChunks: 4, residentChunks: 1)
    let backing = pageClient.addr.linearMemoryBacking()
    if memory[].initLinearMemoryIn(config,
        cast[ptr UncheckedArray[byte]](addr resident[0]),
        resident.len.uint32, backing) == lmOk:
      discard worker()
    else:
      regWrite(StatusAddr, StatusFailed)
  runScheduler()
