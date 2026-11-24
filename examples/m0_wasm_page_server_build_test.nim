## Build-only M0 owner for full-VM chunk backing. A board run requires an
## SD card, the matching peer image, and a trigger from the test harness.
## Opening the dedicated swap file is a boot/setup operation, not a guest slot
## action. No flash or unrelated SD file is changed by this example.

when not defined(bl808m0) or not defined(bl808kernel):
  {.error: "build as M0 kernel firmware".}

import bl808/[startup, core, mmio, memmap, wasm_page_server,
  wasm_sd_backing]
import bl808/kernel/[alloc, fatfs, ipcbridge, sched, sd_swap_file]
import cps/wasm/linear_memory

const MigrationProbe = defined(wasmPagedMigrationProbe) or defined(wasmSdMigrationProbe)

when defined(wasmSdMigrationProbe):
  when not defined(wasmStorageMigration):
    {.error: "SD migration staging requires -d:wasmStorageMigration".}
  import bl808/wasm_sd_migration

when MigrationProbe:
  when not (defined(bl808WasmFullScheduler) and defined(wasmChunkedMemory)):
    {.error: "build paged migration with the full scheduler and chunked memory".}
  import bl808/[wasm_migration_server, wasm_migration_wire, wasm_scheduler]
  import bl808/kernel/clock
  import cps/wasm/types

const
  StatusAddr = XramBase + 0x2E10'u
  TriggerAddr = StatusAddr + 0x30'u
  TriggerValue = 0x5750_4745'u32
  StatusIdle = 0x5750_4D7F'u32
  StatusNoSd = 0x5750_4D01'u32
  StatusFileFailed = 0x5750_4D02'u32
  StatusIpcReady = 0x5750_4D00'u32
  SwapDir = "bl808swap_safe"
  D0Slots = when defined(wasmD0PageServerProbe): 4'u32 else: 0'u32
  SwapPath = when defined(wasmSdMigrationProbe): "bl808swap_safe/staged_pages.swap"
             elif MigrationProbe: "bl808swap_safe/migrate_wasm.swap"
             elif D0Slots > 0: "bl808swap_safe/full_wasm.swap"
             else: "bl808swap_safe/lp_wasm.swap"
  PeerSlots = 4'u32 + D0Slots
  RestoreSlots = when defined(wasmSdMigrationProbe): 12'u32
                 elif MigrationProbe: 2'u32
                 else: 0'u32
  SwapSlots = PeerSlots + RestoreSlots

var
  fs: SdFs
  swap: SdSwapFile
  backing: WasmSdBacking

when WasmMemoryChunkBytes < SdSwapPageBytes:
  var backingScratch: array[SdSwapPageBytes.int, byte]

when MigrationProbe:
  const
    MigrationStatus = StatusAddr + 0x20'u
    RestorePages = when defined(wasmSdMigrationProbe): 1'u32 else: 2'u32
  var restoreBacking: WasmSdBacking

  when defined(wasmSdMigrationProbe):
    const StageSlots = 32'u32
    static: doAssert WasmMemoryChunkBytes == 512
    var stageFile: SdSwapFile
    var stageOwner: WasmSdMigration

  proc destinationMemory(ctx: pointer, memType: MemType): ref LinearMemory =
    discard ctx
    if memType.limits.min != RestorePages or memType.limits.max != RestorePages: return nil
    new(result)
    let cfg = LinearMemoryConfig(initialPages: RestorePages, maxPages: RestorePages,
      admissionPages: RestorePages, maxCommittedChunks: RestoreSlots, residentChunks: 1)
    if result[].initLinearMemory(cfg, restoreBacking.addr.linearMemoryBacking()) != lmOk:
      return nil

  proc pollMigration() =
    let status = pollWasmMigrationServer()
    if status in {mwsBackingFailed, mwsPrepareFailed}:
      regWrite(MigrationStatus, 0x574D_5302'u32)
    if wasmMigrationServerState() != mwActive: return
    let id = wasmMigrationServerTaskId()
    let task = if getWasmTask(id).state == wasmTaskBlockedMemory:
                 serviceWasmTaskMemoryFault(id)
               else:
                 resumeWasmTask(id, 16)
    if task.state in {wasmTaskExited, wasmTaskTrapped}:
      let memory = getWasmTaskMemoryTelemetry(id)
      regWrite(MigrationStatus + 4'u, cast[uint32](task.result))
      regWrite(MigrationStatus + 8'u, memory.pageIns)
      regWrite(MigrationStatus + 12'u, memory.pageOuts)
      let matches = when defined(wasmSdMigrationProbe):
        task.result == cast[int32](0xA5A5A5A5'u32)
      else:
        task.result == 305419896 and memory.pageIns > 0
      regWrite(MigrationStatus,
        if task.state == wasmTaskExited and matches and memory.pageOuts > 0:
          0x574D_5300'u32 else: 0x574D_5301'u32)
      discard killWasmTask(id)

proc registerPageServices(): bool =
  if not initWasmPageServerWithSd(addr backing, D0Slots): return false
  when MigrationProbe:
    restoreBacking = backing
    restoreBacking.firstSlot = PeerSlots
    restoreBacking.slotCount = RestoreSlots
    let epoch = (readTick() xor 0x574D_5345'u64).uint32 or 1'u32
    when defined(wasmSdMigrationProbe):
      if sdSwapOpenOrCreate(fs, stageFile, SwapDir & "/stage_wasm.swap", StageSlots) != sdSwapOk:
        return false
      let staging = stageOwner.sdMigrationStaging(addr fs, addr stageFile)
      if not initWasmMigrationServer(epoch, maxSnapshotBytes = staging.len,
          maxMemoryPages = RestorePages, memoryFactory = destinationMemory,
          staging = staging): return false
    else:
      if not initWasmMigrationServer(epoch, maxSnapshotBytes = 512,
          maxMemoryPages = RestorePages, memoryFactory = destinationMemory): return false
    regWrite(MigrationStatus, 0x574D_537F'u32)
    setSchedulerPollHook(pollMigration)
  true

proc main() {.exportc, cdecl, noreturn.} =
  systemInit()
  heapInit()
  regWrite(StatusAddr, StatusIdle)
  schedulerInit()
  ipcBridgeInit()
  if regRead(TriggerAddr) == TriggerValue:
    if fs.mount() != frOk:
      regWrite(StatusAddr, StatusNoSd)
    else:
      let mkdirStatus = fs.mkdir(SwapDir)
      if mkdirStatus notin {frOk, frExist} or
          sdSwapOpenOrCreate(fs, swap, SwapPath, SwapSlots) != sdSwapOk:
        regWrite(StatusAddr, StatusFileFailed)
      else:
        backing.fs = addr fs
        backing.file = addr swap
        backing.slotCount = PeerSlots
        when WasmMemoryChunkBytes < SdSwapPageBytes:
          backing.scratch =
            cast[ptr UncheckedArray[byte]](addr backingScratch[0])
          backing.scratchBytes = backingScratch.len.uint32
        if registerPageServices():
          regWrite(StatusAddr + 4'u, PeerSlots)
          regWrite(StatusAddr, StatusIpcReady)
        else:
          regWrite(StatusAddr, StatusFileFailed)
  fenceIo()
  runScheduler()
