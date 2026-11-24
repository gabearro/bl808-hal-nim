## Build-only firmware gate for the scheduler's portable full-VM suspension.
## The optional mutable probe restores a guest with memory, globals and a table.

import bl808/[startup, core, mmio, wasm_migration_corpus,
  wasm_scheduler, wasm_store]
import bl808/kernel/alloc
when defined(bl808m0) or defined(bl808d0):
  import bl808/memmap

when not defined(bl808WasmFullScheduler):
  {.error: "build with -d:bl808WasmFullScheduler".}

when defined(wasmMutableMigrationProbe):
  when not defined(wasmChunkedMemory):
    {.error: "build the mutable probe with -d:wasmChunkedMemory".}
  import ../tools/wasm_migration_state_fixture
  const
    ModuleBytes = WasmMutableModule
    SliceFuel = WasmMutableInstructionsBeforeCapture
    Expected = WasmMutableResult
    Factory = mutableMemoryFactory
else:
  const
    ModuleBytes = WasmMigrationModule
    SliceFuel = 1'u32
    Expected = 42'i32
    Factory = nil

when defined(bl808m0):
  const StatusAddr = XramBase + 0x3F60'u
elif defined(bl808d0):
  const StatusAddr = XramBase + 0x3F70'u
elif defined(bl808lp):
  const StatusAddr = 0x40002E90'u
else:
  {.error: "select a BL808 core".}

proc main() {.exportc, cdecl, noreturn.} =
  systemInit()
  heapInit()
  var status = 0x574D_4701'u32
  var snapshotBytes = 0'u32
  var finalFuel = 0'u32
  var image = newSeq[byte](WasmProgramHeaderLen.int + ModuleBytes.len)
  if initWasmProgramImage(
      cast[ptr UncheckedArray[byte]](addr image[0]), image.len.uint32,
      ModuleBytes) == wasmProgramOk:
    let base = cast[ptr UncheckedArray[byte]](addr image[0])
    resetWasmScheduler()
    let source = startFullWasmImageTaskI32(base, image.len.uint32,
      "run", [], maxTotalFuel = 64, slotLabel = 2, memoryFactory = Factory)
    if source.status == wasmSchedOk and
        resumeWasmTask(source.id, SliceFuel).state == wasmTaskYielded:
      let saved = captureWasmTaskMigration(source.id, maxBytes = 512)
      snapshotBytes = saved.bytes.len.uint32
      if saved.status == wasmMigrationOk and
          retireWasmTaskMigration(source.id) == wasmMigrationOk:
        let dest = prepareFullWasmMigrationImage(base, image.len.uint32, saved,
          memoryFactory = Factory)
        if dest.status == wasmSchedOk and
            activateWasmTaskMigration(dest.id) == wasmMigrationOk:
          var current = getWasmTask(dest.id)
          var attempts = 0
          while current.state == wasmTaskYielded and attempts < 16:
            current = resumeWasmTask(dest.id, 2)
            inc attempts
          finalFuel = current.fuelUsed
          if current.status == wasmSchedOk and
              current.state == wasmTaskExited and current.result == Expected:
            status = 0x574D_4700'u32
          discard killWasmTask(dest.id)
  regWrite(StatusAddr + 4'u, heapStats().highWaterBytes.uint32)
  regWrite(StatusAddr + 8'u, snapshotBytes)
  regWrite(StatusAddr + 12'u, finalFuel)
  regWrite(StatusAddr, status)
  when defined(bl808d0):
    dcacheFlushAll()
    fenceIo()
  while true: wfi()
