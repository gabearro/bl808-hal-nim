## Opt-in receiver for portable full-VM task handoff. Call the poll hook from
## the ordinary kernel loop only when no reserved hard slot is active.

when not defined(bl808m0) and not defined(bl808d0) and not defined(bl808lp):
  {.error: "WASM migration receiver requires a BL808 core".}
when not defined(bl808WasmFullScheduler):
  {.error: "WASM migration receiver requires the full task scheduler".}

import ./[ipc, wasm_full_manager, wasm_migration_wire]
import ./kernel/[clock, ipcbridge]
import cps/wasm/runtime
when defined(wasmManagedMigration):
  import ./wasm_steal_client

when defined(wasmManagedMigration) and defined(bl808m0):
  import ./wasm_migration_relay
  import ./kernel/runtime
  var
    migrationRelay: WasmMigrationRelay
    relayFutures: array[2, CpsVoidFuture]
    relayReplyLengths: array[2, int]
    relayEnabled: bool
    relayTimeoutMs: uint64

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
  when defined(wasmManagedMigration) and defined(bl808m0):
    if reqData.toOpenArray(0, reqLen - 1).wasmMigrationRelayIngress():
      if not relayEnabled: return 0
      return migrationRelay.processWasmMigrationRelay(reqData.toOpenArray(0, reqLen - 1),
        respData.toOpenArray(0, WasmMigrationWireReplyBytes - 1), source)
  if migrationReceiver.epoch == 0: return 0
  migrationReceiver.processWasmMigrationWire(
    reqData.toOpenArray(0, reqLen - 1),
    respData.toOpenArray(0, WasmMigrationWireReplyBytes - 1), readTick(), source)

proc registerMigrationHandler(): bool =
  if migrationHandlerRegistered: return true
  if not ipcTryRegisterHandler(WasmMigrationWireTag, migrationRequestHandler): return false
  migrationHandlerRegistered = true
  true

when defined(wasmManagedMigration) and defined(bl808m0):
  proc initM0WasmMigrationRelay*(timeoutMs = 250'u64): bool =
    if relayEnabled or timeoutMs == 0 or not registerMigrationHandler(): return false
    relayEnabled = true
    relayTimeoutMs = timeoutMs
    true

  proc pollM0WasmMigrationRelay*() =
    ## The handler only stages bytes. Drive the outgoing IPC from the M0
    ## kernel loop, outside hard reservations.
    if not relayEnabled: return
    for i, source in [2'u16, 4'u16]:
      let packet = migrationRelay.wasmMigrationRelayPacket(source)
      if relayFutures[i] != nil:
        if not relayFutures[i].finished: continue
        let size = if relayFutures[i].getError() == nil: relayReplyLengths[i] else: 0
        packet[].finishWasmMigrationRelayPacket(size)
        relayFutures[i] = nil
      let size = packet[].takeWasmMigrationRelayPacket()
      if size == 0: continue
      let target = if wasmMigrationRelayTarget(source) == 2: ipcD0 else: ipcLP
      relayReplyLengths[i] = 0
      relayFutures[i] = ipcCallTo(target, WasmMigrationWireTag,
        packet.request.toOpenArray(0, size - 1), addr packet.response[0],
        packet.response.len, addr relayReplyLengths[i], timeoutMs = relayTimeoutMs)
      if relayFutures[i] == nil: packet[].finishWasmMigrationRelayPacket(0)

proc initWasmMigrationServer*(bootEpoch: uint32,
                              maxSnapshotBytes = WasmMigrationMaxSnapshotBytes,
                              maxMemoryPages = 0'u32,
                              memoryFactory: FullMemoryFactory = nil,
                              memoryFactoryContext: pointer = nil,
                              staging = WasmPortableStaging()): bool =
  ## The caller supplies a new nonzero boot epoch after every reset. Reusing
  ## it can make an old transfer handle appear current to a restarted core.
  if migrationReceiver.epoch != 0: return false
  const coreBit =
    when defined(bl808m0): 1'u32
    elif defined(bl808d0): 2'u32
    else: 4'u32
  if not migrationReceiver.initWasmMigrationReceiver(bootEpoch, coreBit,
      maxSnapshotBytes, maxMemoryPages = maxMemoryPages,
      memoryFactory = memoryFactory, memoryFactoryContext = memoryFactoryContext,
      staging = staging):
    return false
  if not registerMigrationHandler():
    migrationReceiver.epoch = 0
    return false
  true

proc pollWasmMigrationServer*(): WasmMigrationWireStatus =
  ## Do not poll from an IRQ, IPC handler or a hard reservation. This may
  ## decode a module and allocate a second VM instance on the destination.
  if migrationReceiver.epoch == 0: return mwsBadState
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

when defined(wasmManagedMigration):
  proc bindWasmMigrationServerWorker*(worker: ptr WasmStealClient): bool =
    ## Keep the initialized client alive and connected to the broker while
    ## the migration server is up. Drive broker RPC from the server poll.
    migrationReceiver.epoch != 0 and migrationReceiver.bindWasmMigrationWorker(worker)
