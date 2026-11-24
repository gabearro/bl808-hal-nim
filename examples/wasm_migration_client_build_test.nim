## Build-only source image for M0<->D0 or M0<->LP portable guest transfer.
## The receiver must have the same module bytes in flash slot 2. This entry
## is not a validated Ox64 handoff or a general migration admission policy.

when not defined(bl808WasmFullScheduler) or not defined(bl808kernel):
  {.error: "build with the BL808 full-VM kernel scheduler".}

import bl808/[startup, core, mmio, memmap, wasm_migration_client,
  wasm_migration_corpus, wasm_scheduler, wasm_store]
import bl808/kernel/[alloc, clock, ipcbridge, sched]

const StagedProbe = defined(wasmStagedMigrationProbe) or defined(wasmSdMigrationSourceProbe)
const PagedProbe = defined(wasmPagedMigrationProbe) or defined(wasmStreamMigrationProbe)

when defined(wasmSdMigrationSourceProbe):
  when not defined(bl808m0) or not defined(wasmStorageMigration) or
      defined(wasmMigrationTargetLP) or PagedProbe:
    {.error: "build the SD staging source on M0 with -d:wasmStorageMigration targeting D0".}
  import bl808/wasm_sd_migration
  import bl808/kernel/[fatfs, sd_swap_file]
  var
    stageFs: SdFs
    stageFile: SdSwapFile
    stageOwner: WasmSdMigration

  proc openSnapshotFile(): bool =
    const stageDir = "bl808swap_safe"
    if stageFs.mount() != frOk: return false
    if stageFs.mkdir(stageDir) notin {frOk, frExist}: return false
    sdSwapOpenOrCreate(stageFs, stageFile, stageDir & "/source_stage.swap", 32) == sdSwapOk

when PagedProbe:
  when not defined(wasmChunkedMemory) or not (defined(bl808d0) or defined(bl808lp)):
    {.error: "build paged migration on D0 or LP with -d:wasmChunkedMemory".}
  import bl808/[wasm_page_client, wasm_remote_page_corpus]
  import cps/wasm/[linear_memory, types]
  when defined(wasmStreamMigrationProbe):
    when not defined(wasmStreamMigration):
      {.error: "build the stream probe with -d:wasmStreamMigration".}
    import ../tools/wasm_migration_dense_fixture
    const
      ProbePages = 1'u32
      ProbeChunks = 4'u32
      ProbeFillBytes = 2048'i32
      ModuleBytes = WasmDenseModule
      SliceFuel = WasmDenseCheckpoint
      EntryName = "run"
    static: doAssert WasmMemoryChunkBytes == 512
  else:
    const
      ProbePages = 2'u32
      ProbeChunks = 2'u32
      ModuleBytes = WasmRemotePageCorpus
      SliceFuel = 3'u32
      EntryName = "cross_page"
  var
    pager: WasmPageClient
    resident: array[WasmMemoryChunkBytes.int, byte]
    pagingTask: WasmSchedulerResult

  proc pagedMemory(ctx: pointer, memType: MemType): ref LinearMemory =
    discard ctx
    if memType.limits.min != ProbePages or memType.limits.max != ProbePages: return nil
    new(result)
    let cfg = LinearMemoryConfig(initialPages: ProbePages, maxPages: ProbePages,
      admissionPages: ProbePages, maxCommittedChunks: ProbeChunks, residentChunks: 1)
    if result[].initLinearMemoryIn(cfg,
        cast[ptr UncheckedArray[byte]](addr resident[0]), resident.len.uint32,
        pager.addr.linearMemoryBacking()) != lmOk:
      return nil

  const Factory = pagedMemory
elif StagedProbe:
  when not defined(wasmChunkedMemory):
    {.error: "build the staged probe with -d:wasmChunkedMemory".}
  import ../tools/wasm_migration_dense_fixture
  const
    ModuleBytes = WasmDenseModule
    SliceFuel = WasmDenseCheckpoint
    Factory = denseMemoryFactory
    EntryName = "run"
elif defined(wasmMutableMigrationProbe):
  when not defined(wasmChunkedMemory):
    {.error: "build the mutable probe with -d:wasmChunkedMemory".}
  import ../tools/wasm_migration_state_fixture
  const
    ModuleBytes = WasmMutableModule
    SliceFuel = WasmMutableInstructionsBeforeCapture
    Factory = mutableMemoryFactory
    EntryName = "run"
else:
  const
    ModuleBytes = WasmMigrationModule
    SliceFuel = 1'u32
    Factory = nil
    EntryName = "run"

const
  StatusAddr = when defined(bl808lp): 0x40002EC0'u
               elif defined(bl808m0): XramBase + 0x3EC0'u
               else: XramBase + 0x3ED0'u
  TargetBit = when defined(bl808m0):
    (when defined(wasmMigrationTargetLP): 4'u32 else: 2'u32)
  else: 1'u32

when defined(wasmStreamMigrationProbe):
  const Args = [ProbeFillBytes]
elif StagedProbe:
  const Args = when TargetBit == 4: [768'i32] else: [WasmDenseProbeBytes]
else:
  const Args = default(array[0, int32])

when PagedProbe or StagedProbe:
  const
    ArmAddr = StatusAddr + 0x10'u
    ArmValue = 0x574D_43A5'u32

when PagedProbe:
  const
    M0PageStatus = XramBase + 0x2E10'u
    M0PageReady = 0x5750_4D00'u32

var
  client: WasmMigrationClient
  migrationImage: seq[byte]
  attempted: bool
  done: bool

proc failSource(id: uint32) =
  if id != 0: discard killWasmTask(id)
  done = true
  regWrite(StatusAddr, 0x574D_43FF'u32)

proc pollSource() =
  if done: return
  let now = readTick()
  if not attempted:
    when PagedProbe or StagedProbe:
      if regRead(ArmAddr) != ArmValue: return
    when PagedProbe:
      if regRead(M0PageStatus) != M0PageReady or not pager.initWasmPageClient(4):
        failSource(0)
        return
    attempted = true
    when defined(wasmSdMigrationSourceProbe):
      if not openSnapshotFile():
        failSource(0)
        return
    migrationImage = newSeq[byte](WasmProgramHeaderLen.int + ModuleBytes.len)
    if initWasmProgramImage(
        cast[ptr UncheckedArray[byte]](addr migrationImage[0]),
        migrationImage.len.uint32,
        ModuleBytes) != wasmProgramOk:
      failSource(0)
      return
    let started = startFullWasmImageTaskI32(
      cast[ptr UncheckedArray[byte]](addr migrationImage[0]),
      migrationImage.len.uint32,
      EntryName, Args, maxTotalFuel = 64, slotLabel = 2, memoryFactory = Factory)
    if started.status != wasmSchedOk:
      failSource(started.id)
      return
    when PagedProbe:
      pagingTask = started
    else:
      if resumeWasmTask(started.id, SliceFuel).state != wasmTaskYielded:
        failSource(started.id)
        return
      let accepted = when defined(wasmSdMigrationSourceProbe):
        client.beginWasmTaskMigration(started.id, now,
          staging = stageOwner.sdMigrationStaging(addr stageFs, addr stageFile))
      elif defined(wasmStagedMigrationProbe):
        client.beginWasmTaskMigration(started.id, now, staging = denseMigrationStaging())
      else:
        client.beginWasmTaskMigration(started.id, now)
      if not accepted:
        failSource(started.id)
        return
  when PagedProbe:
    if pagingTask.id != 0:
      let id = pagingTask.id
      if pagingTask.state == wasmTaskBlockedMemory:
        pagingTask = serviceWasmTaskMemoryFault(id)
        if pagingTask.state == wasmTaskBlockedMemory: return
      if pagingTask.state in {wasmTaskReady, wasmTaskYielded} and pagingTask.fuelUsed < SliceFuel:
        pagingTask = resumeWasmTask(id, SliceFuel - pagingTask.fuelUsed)
        if pagingTask.state == wasmTaskBlockedMemory: return
      pagingTask.id = 0
      if pagingTask.state != wasmTaskYielded or getWasmTaskMemoryTelemetry(id).pageOuts == 0:
        failSource(id)
        return
      let accepted = when defined(wasmStreamMigrationProbe):
        client.beginWasmTaskStreamingMigration(id, now, maxSnapshotBytes = 4096)
      else:
        client.beginWasmTaskMigration(id, now)
      if not accepted:
        failSource(id)
        return
  if client.state == wmcPending:
    discard client.pollWasmTaskMigration(now)
  case client.state
  of wmcComplete:
    done = true
    regWrite(StatusAddr + 4'u, client.telemetry.bytes)
    when defined(wasmStreamMigrationProbe):
      regWrite(StatusAddr + 8'u, heapStats().highWaterBytes.uint32)
    regWrite(StatusAddr, 0x574D_4300'u32)
  of wmcFailed:
    done = true
    regWrite(StatusAddr, 0x574D_4301'u32)
  of wmcUncertain:
    done = true
    regWrite(StatusAddr, 0x574D_4302'u32)
  else:
    discard

proc main() {.exportc, cdecl, noreturn.} =
  systemInit()
  heapInit()
  schedulerInit()
  ipcBridgeInit()
  let bootId = (readTick() xor 0x574D_434C'u64).uint32 or 1'u32
  if not client.initWasmMigrationClient(bootId, TargetBit, TargetBit):
    done = true
    regWrite(StatusAddr, 0x574D_43FF'u32)
  else:
    when PagedProbe or StagedProbe: regWrite(ArmAddr, 0)
    regWrite(StatusAddr, 0x574D_437F'u32)
  setSchedulerPollHook(pollSource)
  runScheduler()
