## Build-only receiver image. A real sender must install the exact same
## CRC-checked module in the destination slot before this can run.

when not defined(bl808WasmFullScheduler) or not defined(bl808kernel):
  {.error: "build with the BL808 full-VM kernel scheduler".}

import bl808/[startup, core, mmio, memmap, wasm_migration_server,
  wasm_migration_wire, wasm_scheduler]
import bl808/kernel/[alloc, clock, ipcbridge, sched]

when defined(wasmPagedMigrationProbe):
  when not defined(wasmChunkedMemory) or not (defined(bl808lp) or defined(bl808d0)):
    {.error: "build the pager-backed receiver for D0 or LP with chunked memory".}
  import bl808/wasm_page_client
  import cps/wasm/[linear_memory, types]
  var
    pager: WasmPageClient
    resident: array[WasmMemoryChunkBytes.int, byte]

  proc destinationMemory(ctx: pointer, memType: MemType): ref LinearMemory =
    if memType.limits.min != 2 or memType.limits.max != 2: return nil
    new(result)
    let cfg = LinearMemoryConfig(initialPages: 2, maxPages: 2, admissionPages: 2,
      maxCommittedChunks: 2, residentChunks: 1)
    if result[].initLinearMemoryIn(cfg, cast[ptr UncheckedArray[byte]](addr resident[0]),
        resident.len.uint32, pager.addr.linearMemoryBacking()) != lmOk:
      return nil

  const Factory = destinationMemory
elif defined(wasmStagedMigrationProbe):
  when not defined(wasmChunkedMemory):
    {.error: "build the staged probe with -d:wasmChunkedMemory".}
  import ../tools/wasm_migration_dense_fixture
  const Factory = denseMemoryFactory
elif defined(wasmMutableMigrationProbe):
  when not defined(wasmChunkedMemory):
    {.error: "build the mutable probe with -d:wasmChunkedMemory".}
  import ../tools/wasm_migration_state_fixture
  const Factory = mutableMemoryFactory
else:
  const Factory = nil

const StatusAddr =
  when defined(bl808lp): 0x40002EB0'u
  elif defined(bl808m0): XramBase + 0x3EB0'u
  elif defined(wasmStagedMigrationProbe): XramBase + 0x3F90'u
  else: XramBase + 0x3EC0'u

proc pollReceiver() =
  discard pollWasmMigrationServer()
  let taskId = wasmMigrationServerTaskId()
  if wasmMigrationServerState() == mwActive and taskId != 0:
    when defined(wasmChunkedMemory):
      let task = if getWasmTask(taskId).state == wasmTaskBlockedMemory:
                   serviceWasmTaskMemoryFault(taskId)
                 else:
                   resumeWasmTask(taskId, 8)
    else:
      let task = resumeWasmTask(taskId, 8)
    if task.state in {wasmTaskExited, wasmTaskTrapped}:
      regWrite(StatusAddr + 4'u, cast[uint32](task.result))
      regWrite(StatusAddr + 8'u, task.fuelUsed)
      when defined(wasmPagedMigrationProbe):
        let memory = getWasmTaskMemoryTelemetry(taskId)
        regWrite(StatusAddr + 12'u, memory.pageIns)
        regWrite(StatusAddr + 16'u, memory.pageOuts)
        let passed = task.state == wasmTaskExited and task.result == 305419896 and
          memory.pageIns > 0 and memory.pageOuts > 0
      elif defined(wasmStagedMigrationProbe):
        let passed = task.state == wasmTaskExited and task.result == WasmDenseResult
      else:
        let passed = task.state == wasmTaskExited
      regWrite(StatusAddr, if passed:
        0x574D_5300'u32 else: 0x574D_5301'u32)
      discard killWasmTask(taskId)

proc main() {.exportc, cdecl, noreturn.} =
  systemInit()
  heapInit()
  schedulerInit()
  ipcBridgeInit()
  when defined(wasmStagedMigrationProbe):
    const armAddr = StatusAddr + 0x14'u
    regWrite(armAddr, 0)
    regWrite(StatusAddr, 0x574D_537E'u32)
    while regRead(armAddr) != 0x574D_53A5'u32: discard
  let bootEpoch = (readTick() xor 0x574D_5345'u64).uint32 or 1'u32
  let ready = when defined(wasmPagedMigrationProbe):
    pager.initWasmPageClient(4) and initWasmMigrationServer(bootEpoch, maxSnapshotBytes = 512,
      maxMemoryPages = 2, memoryFactory = Factory)
  elif defined(wasmStagedMigrationProbe):
    initWasmMigrationServer(bootEpoch, maxSnapshotBytes = WasmDenseProbeCapacity,
      maxMemoryPages = 1, memoryFactory = Factory, staging = denseMigrationStaging())
  else:
    initWasmMigrationServer(bootEpoch, memoryFactory = Factory)
  if not ready:
    regWrite(StatusAddr, 0x574D_53FF'u32)
  else:
    regWrite(StatusAddr, 0x574D_537F'u32)
  setSchedulerPollHook(pollReceiver)
  runScheduler()
