## Build-only all-core full-VM hard-slot candidate. This has not run on the
## Ox64; its tick limits are exploratory until board interference is measured.
import cps/wasm/linear_memory
when not defined(bl808kernel) or not defined(bl808WasmFull) or
    not defined(bl808WasmFullScheduler) or not defined(bl808WasmRtPolicy) or
    not defined(wasmChunkedMemory) or WasmMemoryChunkBytesConfig != 512:
  {.error: "build with the 512-byte chunked full-VM RT scheduler".}

import bl808/[startup, core, mmio, wasm_rt_kernel, wasm_rt_policy, wasm_rt_resident,
  wasm_scheduler, wasm_store]
import bl808/kernel/[alloc, clock, sched]
import cps/wasm/types
when defined(bl808m0) or defined(bl808d0):
  import bl808/memmap
when defined(bl808lp):
  from bl808/wasm_runtime import WasmLpNativeStackBytes
  static:
    doAssert WasmLpNativeStackBytes == 5632,
      "the LP resident RT build needs its QEMU-measured stack reservation"

when defined(bl808m0):
  const StatusAddr = XramBase + 0x3F10'u
  const CoreBit = 1'u32
elif defined(bl808d0):
  const StatusAddr = XramBase + 0x3F20'u
  const CoreBit = 2'u32
elif defined(bl808lp):
  const StatusAddr = 0x40002E90'u
  const CoreBit = 4'u32
else:
  {.error: "select a BL808 core".}

const
  RtStarted = 0x5752547F'u32
  RtPassed = 0x57525400'u32
  RtFailed = 0x57525401'u32

var
  resident: array[WasmMemoryChunkBytes.int, byte]
  memory: ref LinearMemory
  image: seq[byte]
  taskId: uint32

proc makeMemory(ctx: pointer, memType: MemType): ref LinearMemory =
  discard ctx
  if memType.limits.min != 1 or not memType.limits.hasMax or
      memType.limits.max != 1: return nil
  memory

proc publishStatus(status: uint32) =
  let timing = wasmSchedulerRtTelemetry()
  regWrite(StatusAddr + 4'u, heapStats().highWaterBytes.uint32)
  regWrite(StatusAddr + 8'u, timing.maxSliceTicks.uint32)
  regWrite(StatusAddr + 12'u, timing.maxStartJitterTicks.uint32)
  regWrite(StatusAddr, status)
  when defined(bl808d0):
    dcacheFlushAll()
    fenceIo()

proc reportAfterSlot(now: uint64): uint64 =
  discard now
  let task = getWasmTask(taskId)
  let memStats = getWasmTaskMemoryTelemetry(taskId)
  let timing = wasmSchedulerRtTelemetry()
  let passed = task.status == wasmSchedOk and task.state == wasmTaskExited and
    task.result == 305419899'i32 and memStats.found and
    memStats.committedChunks == 1 and memStats.residentChunks == 1 and
    memStats.wouldBlock == 0 and memStats.pageIns == 0 and memStats.pageOuts == 0 and
    timing.starts == 1 and timing.missedReservations == 0 and
    timing.hardFaults == 0 and timing.deadlineMisses == 0 and
    timing.sliceOverruns == 0 and timing.startJitterMisses == 0
  detachWasmRtKernel()
  discard killWasmTask(taskId)
  publishStatus(if passed: RtPassed else: RtFailed)
  0

proc main() {.exportc, cdecl, noreturn.} =
  systemInit()
  heapInit()
  schedulerInit()
  regWrite(StatusAddr, RtStarted)
  new(memory)
  if memory[].initLinearMemoryIn(LinearMemoryConfig(
      initialPages: 1, maxPages: 1, admissionPages: 1,
      maxCommittedChunks: 1, residentChunks: 1),
      cast[ptr UncheckedArray[byte]](addr resident[0]),
      resident.len.uint32) == lmOk and
      memory[].pinRange(256, 4, writable = true) == lmOk:
    image = newSeq[byte](WasmProgramHeaderLen.int + WasmRtResidentModule.len)
    if initWasmProgramImage(
        cast[ptr UncheckedArray[byte]](addr image[0]), image.len.uint32,
        WasmRtResidentModule) == wasmProgramOk:
      resetWasmScheduler()
      let started = startFullWasmImageTaskI32(
        cast[ptr UncheckedArray[byte]](addr image[0]), image.len.uint32,
        "hard-slot", [], maxTotalFuel = 64, maxMemoryPages = 1,
        memoryFactory = makeMemory)
      if started.status == wasmSchedOk:
        # Leave a sleep interval before the reservation. The kernel timer
        # now drives dispatch from its normal WFI loop.
        let epoch = deadlineFromNow(100_000)
        if initWasmRtScheduler(CoreBit, epoch, 1_000_000) == wrOk and
            admitWasmTaskRt(started.id, WasmRtSpec(
              class: wrHard, releaseTick: epoch, budgetTicks: 150_000,
              maxSliceTicks: 100_000, startJitterTicks: 50_000,
              affinityMask: CoreBit, slotOffsetTicks: 0,
              slotLengthTicks: 500_000, residentWorkingSet: true,
              boundedImports: true, noPeerDependency: true,
              noFlashMutation: true)) == wrOk and attachWasmRtKernel() and
            addSchedulerTimedPollHook(reportAfterSlot, epoch + 500_000):
          taskId = started.id
          runScheduler()
        detachWasmRtKernel()
        discard killWasmTask(started.id)
  publishStatus(RtFailed)
  while true: wfi()
