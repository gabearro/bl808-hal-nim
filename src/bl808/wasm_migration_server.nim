## Opt-in receiver for portable full-VM task handoff. Call the poll hook from
## the ordinary kernel loop only when no reserved hard slot is active.

when not defined(bl808m0) and not defined(bl808d0) and not defined(bl808lp):
  {.error: "WASM migration receiver requires a BL808 core".}
when not defined(bl808WasmFullScheduler):
  {.error: "WASM migration receiver requires the full task scheduler".}

import ./[ipc, wasm_full_manager, wasm_migration_wire]
import ./kernel/[clock, ipcbridge]
import cps/wasm/runtime

var
  migrationReceiver: WasmMigrationReceiver
  migrationHandlerRegistered: bool

proc migrationRequestHandler(tag: uint16,
                             reqData: ptr UncheckedArray[uint8], reqLen: int,
                             respData: ptr UncheckedArray[uint8],
                             respBufSize: int): int {.cdecl.} =
  if tag != WasmMigrationWireTag or reqData == nil or respData == nil or
      reqLen < WasmMigrationWireHeaderBytes or
      reqLen > WasmMigrationWirePayloadBytes or
      respBufSize < WasmMigrationWireReplyBytes:
    return 0
  let source = if ipcRequestFrom(reqData, ipcM0): 1'u16
               elif ipcRequestFrom(reqData, ipcD0): 2'u16
               elif ipcRequestFrom(reqData, ipcLP): 4'u16
               else: return 0
  migrationReceiver.processWasmMigrationWire(
    reqData.toOpenArray(0, reqLen - 1),
    respData.toOpenArray(0, WasmMigrationWireReplyBytes - 1), readTick(), source)

proc initWasmMigrationServer*(bootEpoch: uint32,
                              maxSnapshotBytes = WasmMigrationMaxSnapshotBytes,
                              maxMemoryPages = 0'u32,
                              memoryFactory: FullMemoryFactory = nil,
                              memoryFactoryContext: pointer = nil,
                              staging = WasmPortableStaging()): bool =
  ## The caller supplies a new nonzero boot epoch after every reset. Reusing
  ## it can make an old transfer handle appear current to a restarted core.
  if migrationHandlerRegistered: return false
  const coreBit =
    when defined(bl808m0): 1'u32
    elif defined(bl808d0): 2'u32
    else: 4'u32
  if not migrationReceiver.initWasmMigrationReceiver(bootEpoch, coreBit,
      maxSnapshotBytes, maxMemoryPages = maxMemoryPages,
      memoryFactory = memoryFactory, memoryFactoryContext = memoryFactoryContext,
      staging = staging):
    return false
  if not ipcTryRegisterHandler(WasmMigrationWireTag, migrationRequestHandler):
    return false
  migrationHandlerRegistered = true
  true

proc pollWasmMigrationServer*(): WasmMigrationWireStatus =
  ## Do not poll from an IRQ, IPC handler or a hard reservation. This may
  ## decode a module and allocate a second VM instance on the destination.
  if not migrationHandlerRegistered: return mwsBadState
  discard migrationReceiver.reapWasmMigrationReceiver(readTick())
  if migrationReceiver.needsWasmMigrationService():
    return migrationReceiver.serviceWasmMigrationReceiver()
  if migrationReceiver.state == mwActive:
    discard migrationReceiver.finishWasmMigrationReceiver()
  mwsOk

proc wasmMigrationServerState*(): WasmMigrationWireState {.inline.} =
  migrationReceiver.state

proc wasmMigrationServerTaskId*(): uint32 {.inline.} =
  migrationReceiver.taskId
