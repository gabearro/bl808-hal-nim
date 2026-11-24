import std/os
import bl808/[wasm_migration_wire, wasm_scheduler, wasm_store]
when defined(wasmChunkedMemory):
  import wasm_migration_state_fixture

var image: seq[byte]

proc prepare(migration: WasmTaskMigration): WasmSchedulerResult {.nimcall.} =
  const factory = when defined(wasmChunkedMemory): mutableMemoryFactory else: nil
  prepareFullWasmMigrationImage(
    cast[ptr UncheckedArray[byte]](addr image[0]), image.len.uint32,
    migration, memoryFactory = factory)

proc exchange(receiver: var WasmMigrationReceiver,
              req: WasmMigrationWireRequest,
              data: openArray[byte] = [], routedSourceBit = 1'u16): WasmMigrationWireReply =
  var request: array[WasmMigrationWirePayloadBytes, byte]
  var response: array[WasmMigrationWireReplyBytes, byte]
  let reqLen = req.encodeWasmMigrationRequest(data, request)
  doAssert reqLen >= WasmMigrationWireHeaderBytes
  let respLen = receiver.processWasmMigrationWire(
    request.toOpenArray(0, reqLen - 1), response, routedSourceBit = routedSourceBit)
  doAssert respLen == WasmMigrationWireReplyBytes
  doAssert response.decodeWasmMigrationReply(result)

proc main() =
  doAssert paramCount() in 1..2
  let mutableState = paramCount() == 2 and paramStr(2) == "mutable"
  let sliceFuel = if mutableState: 17'u32 else: 1'u32
  let expected = if mutableState: 16_909_075'i32 else: 42'i32
  let moduleBytes = cast[seq[byte]](readFile(paramStr(1)))
  image = newSeq[byte](WasmProgramHeaderLen.int + moduleBytes.len)
  doAssert initWasmProgramImage(
    cast[ptr UncheckedArray[byte]](addr image[0]), image.len.uint32,
    moduleBytes) == wasmProgramOk
  resetWasmScheduler()
  let source = startFullWasmImageTaskI32(
    cast[ptr UncheckedArray[byte]](addr image[0]), image.len.uint32,
    "run", [], maxTotalFuel = 64, slotLabel = 2)
  doAssert source.status == wasmSchedOk
  doAssert resumeWasmTask(source.id, sliceFuel).state == wasmTaskYielded
  let state = captureWasmTaskMigration(source.id, maxBytes = 512)
  doAssert state.status == wasmMigrationOk
  wasmMigrationPrepareHook = prepare
  var receiver: WasmMigrationReceiver
  doAssert receiver.initWasmMigrationReceiver(0x5678'u32, 2'u32, 512)
  var req = WasmMigrationWireRequest(op: mwoHello, sourceBootId: 44,
    sourceCoreBit: 1)
  doAssert receiver.exchange(req, routedSourceBit = 4).status == mwsInvalid
  doAssert receiver.exchange(req).receiverEpoch == 0x5678
  req = WasmMigrationWireRequest(op: mwoBegin,
    receiverEpoch: 0x5677, sourceBootId: 44, transferId: 101,
    sourceCoreBit: 1,
    slot: state.slot, fuelLimit: state.fuelLimit,
    fuelUsed: state.fuelUsed, affinityMask: 2,
    totalBytes: state.bytes.len.uint32)
  doAssert receiver.exchange(req).status == mwsStaleEpoch
  req.receiverEpoch = receiver.epoch
  req.affinityMask = 4
  doAssert receiver.exchange(req).status == mwsInvalid
  req.affinityMask = 2
  doAssert receiver.exchange(req).state == mwReceiving
  doAssert receiver.exchange(req).state == mwReceiving
  var wrong = req
  wrong.transferId = 102
  doAssert receiver.exchange(wrong).status == mwsBusy
  req.op = mwoPart
  req.offset = high(uint32)
  req.count = 10
  doAssert receiver.exchange(req, state.bytes.toOpenArray(20, 29)).status ==
    mwsOutOfOrder
  req.offset = 20
  doAssert receiver.exchange(req, state.bytes.toOpenArray(20, 29)).status ==
    mwsOutOfOrder
  req.offset = 0
  req.count = 20
  doAssert receiver.exchange(req, state.bytes.toOpenArray(0, 19)).nextOffset == 20
  doAssert receiver.exchange(req, state.bytes.toOpenArray(0, 19)).nextOffset == 20
  var damaged = state.bytes[0 ..< 20]
  damaged[0] = damaged[0] xor 1
  doAssert receiver.exchange(req, damaged).status == mwsOutOfOrder
  req.offset = 20
  req.count = (state.bytes.len - 20).uint16
  doAssert receiver.exchange(req,
    state.bytes.toOpenArray(20, state.bytes.len - 1)).nextOffset ==
      state.bytes.len.uint32
  req.op = mwoPrepare
  req.offset = 0
  req.count = 0
  doAssert receiver.exchange(req).status == mwsPending
  req.op = mwoQuery
  doAssert receiver.exchange(req).state == mwPreparing
  doAssert receiver.serviceWasmMigrationReceiver() == mwsOk
  req.op = mwoPrepare
  let prepared = receiver.exchange(req)
  doAssert prepared.status == mwsOk and prepared.state == mwPrepared and
    prepared.taskId != 0 and
    getWasmTask(prepared.taskId).state == wasmTaskMigrating
  doAssert receiver.exchange(req).taskId == prepared.taskId
  doAssert resumeWasmTask(prepared.taskId, 1).status == wasmSchedBadState
  doAssert retireWasmTaskMigration(source.id) == wasmMigrationOk
  req.op = mwoCommit
  doAssert receiver.exchange(req).state == mwActive
  doAssert receiver.exchange(req).state == mwActive
  var current = getWasmTask(prepared.taskId)
  var attempts = 0
  while current.state == wasmTaskYielded and attempts < 16:
    current = resumeWasmTask(prepared.taskId, 2)
    inc attempts
  doAssert current.status == wasmSchedOk and current.state == wasmTaskExited and
    current.result == expected
  doAssert receiver.finishWasmMigrationReceiver()
  doAssert receiver.state == mwIdle
  discard killWasmTask(prepared.taskId)

  # A new boot on the same source core invalidates a dormant old receiver.
  let second = startFullWasmImageTaskI32(
    cast[ptr UncheckedArray[byte]](addr image[0]), image.len.uint32,
    "run", [], maxTotalFuel = 64, slotLabel = 2)
  doAssert resumeWasmTask(second.id, sliceFuel).state == wasmTaskYielded
  let nextState = captureWasmTaskMigration(second.id, maxBytes = 512)
  doAssert nextState.status == wasmMigrationOk
  doAssert receiver.initWasmMigrationReceiver(888, 2, 512,
    leaseTicks = 100)
  req = WasmMigrationWireRequest(op: mwoBegin,
    receiverEpoch: 888, sourceBootId: 44, sourceCoreBit: 1,
    transferId: 102, slot: nextState.slot,
    fuelLimit: nextState.fuelLimit, fuelUsed: nextState.fuelUsed,
    affinityMask: 2, totalBytes: nextState.bytes.len.uint32)
  var oversized = req
  oversized.totalBytes = 600
  doAssert receiver.exchange(oversized).status == mwsTooLarge
  doAssert receiver.exchange(req).state == mwReceiving
  req.op = mwoPart
  req.count = nextState.bytes.len.uint16
  doAssert receiver.exchange(req, nextState.bytes).status == mwsOk
  req.op = mwoPrepare
  req.count = 0
  doAssert receiver.exchange(req).status == mwsPending
  doAssert receiver.serviceWasmMigrationReceiver() == mwsOk
  let dormantId = receiver.taskId
  doAssert dormantId != 0
  let freshHello = WasmMigrationWireRequest(op: mwoHello,
    sourceBootId: 45, sourceCoreBit: 1)
  doAssert receiver.exchange(freshHello).status == mwsPending
  doAssert receiver.needsWasmMigrationService()
  doAssert receiver.serviceWasmMigrationReceiver() == mwsOk
  doAssert getWasmTask(dormantId).status == wasmSchedNoTask and
    receiver.state == mwIdle
  doAssert receiver.exchange(freshHello).status == mwsOk
  doAssert cancelWasmTaskMigration(second.id) == wasmMigrationOk
  discard killWasmTask(second.id)

  # A missing source cannot keep a receiving slot forever.
  req.op = mwoBegin
  req.sourceBootId = 45
  req.transferId = 103
  doAssert receiver.exchange(req).state == mwReceiving
  doAssert receiver.reapWasmMigrationReceiver(101)
  doAssert receiver.state == mwIdle
  echo "WASM migration wire PASS: fragments, stale ids, prepare, commit, finish"

main()
