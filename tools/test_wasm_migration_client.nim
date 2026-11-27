import std/os
import bl808/[wasm_full_manager, wasm_migration_client, wasm_migration_wire,
  wasm_scheduler, wasm_store]
import cps/runtime

when defined(wasmFileMigrationTest):
  import std/tempfiles
  from cps/wasm/runtime import WasmPortableStaging, WasmPortableStorage,
    usesPortableBacking, readPortableRange, writePortableRange

  type TestStagingFile = object
    file: File
    path: string
    storage: WasmPortableStorage
    failRead, failWrite, failSeal: bool
    reads, writes, seals, maxRead: int

  var sourceFile, destinationFile: TestStagingFile
  var inMigrationHandler, holdFilePart: bool

  proc readStaging(ctx: pointer, offset: int, buf: pointer, count: int): bool =
    let stage = cast[ptr TestStagingFile](ctx)
    doAssert not inMigrationHandler
    inc stage.reads
    stage.maxRead = max(stage.maxRead, count)
    if stage.failRead: return false
    stage.file.setFilePos(offset)
    stage.file.readBuffer(buf, count) == count

  proc writeStaging(ctx: pointer, offset: int, buf: pointer, count: int): bool =
    let stage = cast[ptr TestStagingFile](ctx)
    doAssert not inMigrationHandler
    inc stage.writes
    if stage.failWrite: return false
    stage.file.setFilePos(offset)
    stage.file.writeBuffer(buf, count) == count

  proc sealStaging(ctx: pointer): bool =
    let stage = cast[ptr TestStagingFile](ctx)
    doAssert not inMigrationHandler
    inc stage.seals
    if stage.failSeal: return false
    stage.file.flushFile()
    true

  proc openStaging(stage: var TestStagingFile, capacity: int): WasmPortableStaging =
    (stage.file, stage.path) = createTempFile("wasm-migration-", ".stage")
    stage.file.setFilePos(capacity - 1)
    stage.file.write(char(0))
    stage.storage = WasmPortableStorage(ctx: addr stage, read: readStaging,
      write: writeStaging, seal: sealStaging)
    WasmPortableStaging(storage: addr stage.storage, len: capacity)

  proc closeStaging(stage: var TestStagingFile) =
    stage.file.close()
    removeFile(stage.path)

when defined(wasmExtendedMigrationTest):
  from cps/wasm/runtime import WasmPortableStaging
  var corruptStaged: bool
  var expectedSnapshotBytes: int

  when not defined(wasmFileMigrationTest):
    const MaxTestSnapshot = 512 * 1024
    var outgoing, incoming: array[MaxTestSnapshot + 2, byte]

    proc workspace(bytes: var array[MaxTestSnapshot + 2, byte]): WasmPortableStaging =
      WasmPortableStaging(data: cast[ptr UncheckedArray[byte]](addr bytes[1]),
        len: expectedSnapshotBytes)

when defined(wasmAsyncMigrationTest):
  import bl808/[wasm_page_client, wasm_page_wire]
  import cps/wasm/[linear_memory, types]
  from cps/wasm/runtime import WasmPortableStaging
  import wasm_migration_state_fixture

  var pageClient: WasmPageClient
  var pageServer: WasmPageWireServer
  var disk: array[3, array[WasmMemoryChunkBytes.int, byte]]
  var holdRead, failRead: bool
  var delayedFuture: CpsVoidFuture
  var delayedDst: pointer
  var delayedLen: ptr int
  var delayedSize: int
  var reply: array[WasmPageWirePayloadBytes, byte]
  var pageReads, migrationRequests: int
  var destinationDisk: array[3, array[WasmMemoryChunkBytes.int, byte]]
  var destinationFrame: ptr UncheckedArray[byte]
  var destinationSlot: uint32
  var coldSlots = 3'u32
  var coldWrites, coldCancels: int
  var holdColdWrite, failColdWrite: bool
  var asyncCaptureBytes, asyncReceiveBytes: array[512, byte]

  proc workspace(bytes: var array[512, byte]): WasmPortableStaging =
    WasmPortableStaging(data: cast[ptr UncheckedArray[byte]](addr bytes[0]), len: bytes.len)

  proc readDisk(ctx: pointer, slot: uint32, dst: ptr UncheckedArray[byte]): bool =
    if slot >= disk.len.uint32: return false
    inc pageReads
    copyMem(dst, addr disk[slot][0], WasmMemoryChunkBytes.int)
    true

  proc writeDisk(ctx: pointer, slot: uint32, src: ptr UncheckedArray[byte]): bool =
    if slot >= disk.len.uint32: return false
    copyMem(addr disk[slot][0], src, WasmMemoryChunkBytes.int)
    true

  proc pageRpc(request: openArray[byte], response: pointer, responseBytes: int,
               responseLen: ptr int, timeoutMs: uint64): CpsVoidFuture =
    result = newCpsVoidFuture()
    let size = pageServer.processWasmPageWire(request, reply)
    if failRead or size <= 0 or size > responseBytes:
      result.fail(newException(IOError, "page RPC failed"))
    elif holdRead:
      doAssert delayedFuture == nil
      holdRead = false
      delayedFuture = result
      delayedDst = response
      delayedLen = responseLen
      delayedSize = size
    else:
      copyMem(response, addr reply[0], size)
      responseLen[] = size
      result.complete()

  proc releaseReply() =
    doAssert delayedFuture != nil
    copyMem(delayedDst, addr reply[0], delayedSize)
    delayedLen[] = delayedSize
    delayedFuture.complete()
    delayedFuture = nil

  proc pageMemoryFactory(ctx: pointer, memType: MemType): ref LinearMemory =
    new(result)
    let pages = memType.limits.max
    if result[].initLinearMemory(LinearMemoryConfig(initialPages: memType.limits.min,
        maxPages: pages, admissionPages: pages, maxCommittedChunks: 3, residentChunks: 1),
        pageClient.addr.linearMemoryBacking()) != lmOk:
      return nil

  proc readDestination(ctx: pointer, slot: uint32, dst: ptr UncheckedArray[byte]): bool =
    if slot >= coldSlots: return false
    copyMem(dst, addr destinationDisk[slot][0], WasmMemoryChunkBytes.int)
    true

  proc writeDestination(ctx: pointer, slot: uint32,
                        src: ptr UncheckedArray[byte]): LinearMemoryStatus =
    if slot >= coldSlots: return lmBackingFull
    if destinationFrame == nil:
      destinationFrame = src
      destinationSlot = slot
      return lmWouldBlock
    doAssert destinationFrame == src and destinationSlot == slot
    if holdColdWrite: return lmWouldBlock
    destinationFrame = nil
    if failColdWrite and slot == 1: return lmBackingWriteFailed
    copyMem(addr destinationDisk[slot][0], src, WasmMemoryChunkBytes.int)
    inc coldWrites
    lmOk

  proc cancelDestinationWrite(ctx: pointer, slot: uint32,
                              src: ptr UncheckedArray[byte]) =
    if destinationFrame == src and destinationSlot == slot:
      destinationFrame = nil
      inc coldCancels

  proc coldRestoreFactory(ctx: pointer, memType: MemType): ref LinearMemory =
    new(result)
    let pages = memType.limits.max
    if result[].initLinearMemory(LinearMemoryConfig(initialPages: memType.limits.min,
        maxPages: pages, admissionPages: pages, maxCommittedChunks: 3, residentChunks: 1),
        LinearMemoryBacking(slots: coldSlots, readPage: readDestination,
          writePageStatus: writeDestination, cancelWrite: cancelDestinationWrite)) != lmOk:
      return nil

var
  image: seq[byte]
  receiver: WasmMigrationReceiver
  nowTick = 1'u64
  dropPartOnce = true
  dropCommitReplies = 0
  rejectPrepare = false

proc prepare(migration: WasmTaskMigration, _: uint32, _: FullMemoryFactory,
             _: pointer, _: bool): WasmSchedulerResult {.nimcall.} =
  if rejectPrepare:
    return WasmSchedulerResult(status: wasmSchedInitFailed)
  when defined(wasmExtendedMigrationTest):
    doAssert migration.bytes.len == 0
    when defined(wasmFileMigrationTest):
      doAssert migration.staged.data == nil and migration.staged.storage == addr destinationFile.storage
    else:
      doAssert migration.staged.data == workspace(incoming).data
    doAssert migration.staged.len == expectedSnapshotBytes
  when defined(wasmAsyncMigrationTest):
    doAssert migration.bytes.len == 0
    when defined(wasmFileMigrationTest):
      doAssert migration.staged.data == nil and migration.staged.storage == addr destinationFile.storage
    else:
      doAssert migration.staged.data == workspace(asyncReceiveBytes).data
  const factory = when defined(wasmAsyncMigrationTest): coldRestoreFactory else: nil
  prepareFullWasmMigrationImage(
    cast[ptr UncheckedArray[byte]](addr image[0]), image.len.uint32,
    migration, memoryFactory = factory, allowPagedRestore = defined(wasmAsyncMigrationTest))

proc fakeRpc(request: openArray[byte], response: pointer,
             responseBytes: int, responseLen: ptr int,
             timeoutMs: uint64): CpsVoidFuture =
  discard timeoutMs
  when defined(wasmAsyncMigrationTest): inc migrationRequests
  result = newCpsVoidFuture()
  var decoded: WasmMigrationWireRequest
  if not request.decodeWasmMigrationRequest(decoded):
    result.fail(newException(IOError, "bad migration request"))
    return
  when defined(wasmStreamingMigrationTest) and defined(wasmAsyncMigrationTest):
    # Model the LP's single outstanding XRAM call slot.
    doAssert delayedFuture == nil or delayedFuture.finished
  when defined(wasmExtendedMigrationTest):
    if decoded.op == mwoPrepare and corruptStaged:
      corruptStaged = false
      when defined(wasmFileMigrationTest):
        let view = WasmPortableStaging(storage: addr destinationFile.storage, len: expectedSnapshotBytes)
        var b: byte
        doAssert view.readPortableRange(4096, addr b, 1)
        b = b xor 1
        doAssert view.writePortableRange(4096, addr b, 1)
      else:
        incoming[4097] = incoming[4097] xor 1
  when defined(wasmFileMigrationTest):
    if decoded.op == mwoPart and not holdFilePart and receiver.needsWasmMigrationService():
      discard receiver.serviceWasmMigrationReceiver()
  if decoded.op == mwoQuery and receiver.state == mwPreparing:
    discard receiver.serviceWasmMigrationReceiver()
    when defined(wasmAsyncMigrationTest):
      if receiver.state == mwPreparing and receiver.taskId != 0:
        doAssert activateWasmTaskMigration(receiver.taskId) == wasmMigrationBadState
        doAssert resumeWasmTask(receiver.taskId).status == wasmSchedBadState
        var early = decoded
        early.op = mwoCommit
        var earlyBytes: array[WasmMigrationWireHeaderBytes, byte]
        var earlyReply: array[WasmMigrationWireReplyBytes, byte]
        var decodedReply: WasmMigrationWireReply
        doAssert early.encodeWasmMigrationRequest([], earlyBytes) == earlyBytes.len
        doAssert receiver.processWasmMigrationWire(earlyBytes, earlyReply, nowTick) == earlyReply.len
        doAssert earlyReply.decodeWasmMigrationReply(decodedReply) and decodedReply.status == mwsBadState
  let dst = cast[ptr UncheckedArray[byte]](response)
  when defined(wasmFileMigrationTest): inMigrationHandler = true
  let size = receiver.processWasmMigrationWire(request,
    dst.toOpenArray(0, responseBytes - 1), nowTick)
  when defined(wasmFileMigrationTest):
    inMigrationHandler = false
    var wireReply: WasmMigrationWireReply
    let partAccepted = dst.toOpenArray(0, responseBytes - 1).decodeWasmMigrationReply(wireReply) and
      wireReply.status == mwsOk
  else:
    const partAccepted = true
  inc nowTick
  if size != WasmMigrationWireReplyBytes:
    result.fail(newException(IOError, "bad migration reply"))
  elif decoded.op == mwoPart and dropPartOnce and partAccepted:
    dropPartOnce = false
    result.fail(newException(IOError, "lost part reply"))
  elif decoded.op == mwoCommit and dropCommitReplies > 0:
    dec dropCommitReplies
    result.fail(newException(IOError, "lost commit reply"))
  else:
    responseLen[] = size
    result.complete()

proc startSource(denseBytes = 65_399'i32, sparse = false): uint32 =
  const factory = when defined(wasmAsyncMigrationTest): pageMemoryFactory else: nil
  let args = when defined(wasmExtendedMigrationTest): [denseBytes] else: default(array[0, int32])
  let exportName = if sparse: "sparse" else: "run"
  let task = startFullWasmImageTaskI32(
    cast[ptr UncheckedArray[byte]](addr image[0]), image.len.uint32,
    exportName, args, maxTotalFuel = (if sparse: 1_024'u32 else: 64'u32),
    slotLabel = 2, memoryFactory = factory)
  doAssert task.status == wasmSchedOk, $task.status & ": " & $task.managerError
  when defined(wasmAsyncMigrationTest):
    var current = task
    var polls = 0
    while current.fuelUsed < WasmMutableInstructionsBeforeCapture:
      doAssert polls < 40
      inc polls
      if current.state == wasmTaskBlockedMemory:
        current = serviceWasmTaskMemoryFault(task.id)
      else:
        current = resumeWasmTask(task.id, WasmMutableInstructionsBeforeCapture - current.fuelUsed)
      doAssert current.state in {wasmTaskBlockedMemory, wasmTaskYielded}
    doAssert getWasmTaskMemoryTelemetry(task.id).pageOuts == 2
  elif defined(wasmExtendedMigrationTest):
    # Suspend after the fill or expansion loop, before reading the result.
    let checkpoint = if sparse: 167'u32 else: 4'u32
    doAssert resumeWasmTask(task.id, checkpoint).state == wasmTaskYielded
  else:
    doAssert resumeWasmTask(task.id, 1).state == wasmTaskYielded
  task.id

proc drive(client: var WasmMigrationClient) =
  const maxPolls = when defined(wasmFileMigrationTest): 3_000
                   elif defined(wasmExtendedMigrationTest): 1_500
                   else: 50
  var polls = 0
  while client.state == wmcPending and polls < maxPolls:
    discard client.pollWasmTaskMigration(nowTick)
    inc polls
  doAssert polls < maxPolls

proc finishDestination(sparse = false) =
  let id = receiver.taskId
  doAssert id != 0 and receiver.state == mwActive
  var task = getWasmTask(id)
  var attempts = 0
  const runnable = when defined(wasmAsyncMigrationTest): {wasmTaskYielded, wasmTaskBlockedMemory}
                   else: {wasmTaskYielded}
  while task.state in runnable and attempts < 80:
    when defined(wasmAsyncMigrationTest):
      if task.state == wasmTaskBlockedMemory:
        task = serviceWasmTaskMemoryFault(id)
      else:
        task = resumeWasmTask(id, 2)
    else:
      task = resumeWasmTask(id, 2)
    inc attempts
  let expected = when defined(wasmAsyncMigrationTest): WasmMutableResult
                 elif defined(wasmExtendedMigrationTest):
                   if sparse: 0xA500A5'i32 else: cast[int32](0xA5A5A5A5'u32)
                 else: 42'i32
  doAssert task.state == wasmTaskExited and task.result == expected
  when defined(wasmAsyncMigrationTest):
    let memory = getWasmTaskMemoryTelemetry(id)
    doAssert memory.residentChunks == 1 and memory.pageOuts >= 2 and memory.pageIns > 0
  doAssert receiver.finishWasmMigrationReceiver()
  discard killWasmTask(id)

when defined(wasmExtendedMigrationTest):
  proc checkExtendedTransfer(fillBytes: int32, sparse: bool) =
    when defined(wasmFileMigrationTest):
      let src = sourceFile.openStaging(expectedSnapshotBytes)
      defer: sourceFile.closeStaging()
      let dst = destinationFile.openStaging(expectedSnapshotBytes)
      defer: destinationFile.closeStaging()
      doAssert src.usesPortableBacking() and dst.usesPortableBacking()
    else:
      outgoing[0] = 0x11
      outgoing[expectedSnapshotBytes + 1] = 0x22
      incoming[0] = 0x33
      incoming[expectedSnapshotBytes + 1] = 0x44
      let src = workspace(outgoing)
      let dst = workspace(incoming)
    var client: WasmMigrationClient
    doAssert client.initWasmMigrationClient(55, 4, 4, sourceCoreBit = 1)
    doAssert not receiver.initWasmMigrationReceiver(777, 4, dst.len + 1, staging = dst)
    doAssert receiver.initWasmMigrationReceiver(777, 4, 512, leaseTicks = 100)
    let source = startSource(fillBytes, sparse)
    doAssert captureWasmTaskMigration(source).status == wasmMigrationTooLarge
    doAssert not client.beginWasmTaskMigration(source, nowTick)
    doAssert client.beginWasmTaskMigration(source, nowTick, staging = src)
    client.drive()
    doAssert client.state == wmcFailed and client.telemetry.fragments == 0
    doAssert getWasmTask(source).state == wasmTaskYielded

    doAssert receiver.initWasmMigrationReceiver(778, 4, dst.len, leaseTicks = 100, staging = dst)
    when defined(wasmFileMigrationTest):
      sourceFile.failWrite = true
      doAssert not client.beginWasmTaskMigration(source, nowTick, staging = src)
      doAssert getWasmTask(source).state == wasmTaskYielded and receiver.state == mwIdle
      sourceFile.failWrite = false
      holdFilePart = true
      let writesBefore = destinationFile.writes
      doAssert client.beginWasmTaskMigration(source, nowTick, staging = src)
      var polls = 0
      while not receiver.needsWasmMigrationService():
        doAssert client.state == wmcPending and polls < 10
        inc polls
        discard client.pollWasmTaskMigration(nowTick)
      doAssert receiver.state == mwReceiving
      doAssert receiver.reapWasmMigrationReceiver(nowTick + 101)
      holdFilePart = false
      client.drive()
      doAssert client.state == wmcFailed and getWasmTask(source).state == wasmTaskYielded
      doAssert destinationFile.writes == writesBefore and receiver.state == mwIdle
      for failure in 0..2:
        destinationFile.failWrite = failure == 0
        destinationFile.failSeal = failure == 1
        destinationFile.failRead = failure == 2
        doAssert client.beginWasmTaskMigration(source, nowTick, staging = src)
        client.drive()
        doAssert client.state == wmcFailed and receiver.state == mwPrepareFailed
        doAssert receiver.taskId == 0 and getWasmTask(source).state == wasmTaskYielded
        doAssert receiver.reapWasmMigrationReceiver(nowTick + 101)
      destinationFile.failRead = false
    let previousBytes = client.telemetry.bytes
    corruptStaged = true
    doAssert client.beginWasmTaskMigration(source, nowTick, staging = src)
    client.drive()
    doAssert client.state == wmcFailed and receiver.state == mwPrepareFailed
    doAssert client.telemetry.bytes - previousBytes == src.len.uint32
    doAssert getWasmTask(source).state == wasmTaskYielded
    doAssert receiver.reapWasmMigrationReceiver(nowTick + 101)

    dropPartOnce = true
    dropCommitReplies = WasmMigrationRpcRetries + 1
    doAssert client.beginWasmTaskMigration(source, nowTick, staging = src)
    client.drive()
    doAssert client.state == wmcUncertain and receiver.state == mwActive
    doAssert client.telemetry.bytes - previousBytes == 2'u32 * src.len.uint32
    doAssert getWasmTask(source).status == wasmSchedNoTask
    doAssert client.retryWasmMigrationCommit(nowTick)
    client.drive()
    doAssert client.state == wmcComplete
    finishDestination(sparse)
    when defined(wasmFileMigrationTest):
      var a, b: array[512, byte]
      for offset in countup(0, src.len - 1, a.len):
        let count = min(a.len, src.len - offset)
        doAssert src.readPortableRange(offset, addr a[0], count)
        doAssert dst.readPortableRange(offset, addr b[0], count)
        doAssert a == b
      doAssert sourceFile.maxRead <= 512 and destinationFile.maxRead <= 512
      doAssert sourceFile.seals > 0 and destinationFile.seals > 0
      doAssert getFileSize(sourceFile.path) == src.len and
        getFileSize(destinationFile.path) == dst.len
      echo "file migration PASS: ", src.len, " bytes, storage failures, CRC failure, lost replies"
    else:
      doAssert outgoing[0] == 0x11 and outgoing[expectedSnapshotBytes + 1] == 0x22
      doAssert incoming[0] == 0x33 and incoming[expectedSnapshotBytes + 1] == 0x44
      for i in 0 ..< src.len: doAssert src.data[i] == dst.data[i]
      echo "staged migration PASS: ", src.len, " bytes, inline rejection, CRC failure, lost replies"

when defined(wasmStreamingMigrationTest) and defined(wasmExtendedMigrationTest):
  proc checkStreamingTransfer(fillBytes: int32, sparse: bool) =
    const capacity = 512 * 1024
    let dst = destinationFile.openStaging(capacity)
    defer: destinationFile.closeStaging()
    var client: WasmMigrationClient
    doAssert client.initWasmMigrationClient(32, 1, 1, sourceCoreBit = 4)
    let source = startSource(fillBytes, sparse)
    doAssert receiver.initWasmMigrationReceiver(900, 1, 512, leaseTicks = 100)
    doAssert client.beginWasmTaskStreamingMigration(source, nowTick, capacity)
    client.drive()
    doAssert client.state == wmcFailed and client.telemetry.bytes == 0
    doAssert getWasmTask(source).state == wasmTaskYielded

    doAssert receiver.initWasmMigrationReceiver(901, 1, capacity, 100, staging = dst)
    doAssert client.beginWasmTaskStreamingMigration(source, nowTick, 512)
    client.drive()
    doAssert client.state == wmcFailed and client.telemetry.bytes > 0
    doAssert receiver.state == mwReceiving and getWasmTask(source).state == wasmTaskYielded
    doAssert receiver.reapWasmMigrationReceiver(nowTick + 101)

    corruptStaged = true
    doAssert client.beginWasmTaskStreamingMigration(source, nowTick, capacity)
    client.drive()
    doAssert client.state == wmcFailed and receiver.state == mwPrepareFailed
    doAssert getWasmTask(source).state == wasmTaskYielded
    doAssert receiver.reapWasmMigrationReceiver(nowTick + 101)

    let before = client.telemetry.bytes
    dropPartOnce = true
    dropCommitReplies = WasmMigrationRpcRetries + 1
    doAssert client.beginWasmTaskStreamingMigration(source, nowTick, capacity)
    client.drive()
    doAssert client.state == wmcUncertain and receiver.state == mwActive
    doAssert getWasmTask(source).status == wasmSchedNoTask
    doAssert client.retryWasmMigrationCommit(nowTick)
    client.drive()
    doAssert client.state == wmcComplete
    doAssert client.telemetry.bytes - before == expectedSnapshotBytes.uint32
    finishDestination(sparse)
    doAssert getFileSize(destinationFile.path) == capacity
    doAssert destinationFile.maxRead <= 512
    echo "stream migration PASS: ", expectedSnapshotBytes,
      " bytes, receiver and producer quotas, CRC rejection, lost replies"

proc checkDefaultTransfers() =
  when defined(wasmAsyncMigrationTest):
    doAssert pageServer.initWasmPageWireRange(LinearMemoryBacking(slots: 3,
      readPage: readDisk, writePage: writeDisk), 81, 0, 3, WasmMemoryChunkBytes.uint16)
    doAssert pageClient.initWasmPageClient(3)
    wasmPageRpc = pageRpc
    const sourceBit = when defined(wasmStreamingMigrationTest): 4'u32 else: 2'u32
    const targetBit = 1'u32
  else:
    const sourceBit = 1'u32
    const targetBit = 2'u32
  when defined(wasmAsyncMigrationTest):
    when defined(wasmFileMigrationTest):
      let srcStage = sourceFile.openStaging(512)
      defer: sourceFile.closeStaging()
      let dstStage = destinationFile.openStaging(512)
      defer: destinationFile.closeStaging()
    else:
      let srcStage = workspace(asyncCaptureBytes)
      let dstStage = workspace(asyncReceiveBytes)
    doAssert receiver.initWasmMigrationReceiver(777, targetBit, 512,
      leaseTicks = 100, staging = dstStage)
  else:
    doAssert receiver.initWasmMigrationReceiver(777, targetBit, 512, leaseTicks = 100)
  var client: WasmMigrationClient
  doAssert client.initWasmMigrationClient(55, targetBit, targetBit,
    sourceCoreBit = sourceBit)

  let first = startSource()
  dropCommitReplies = 1
  when defined(wasmAsyncMigrationTest):
    let reads = pageReads
    let memoryBefore = getWasmTaskMemoryTelemetry(first)
    holdRead = true
    when defined(wasmStreamingMigrationTest):
      doAssert client.beginWasmTaskStreamingMigration(first, nowTick, 512)
      var firstPagePolls = 0
      while delayedFuture == nil:
        doAssert client.state == wmcPending and firstPagePolls < 40
        inc firstPagePolls
        discard client.pollWasmTaskMigration(nowTick)
    else:
      doAssert client.beginWasmTaskMigration(first, nowTick, staging = srcStage)
  else:
    doAssert client.beginWasmTaskMigration(first, nowTick)
  when defined(wasmAsyncMigrationTest):
    doAssert delayedFuture != nil
    let requestsBeforeWait = migrationRequests
    when not defined(wasmStreamingMigrationTest): doAssert requestsBeforeWait == 0
    doAssert client.pollWasmTaskMigration(nowTick) == wmcPending
    doAssert migrationRequests == requestsBeforeWait
    doAssert resumeWasmTask(first).status == wasmSchedBadState
    doAssert retireWasmTaskMigration(first) == wasmMigrationBadState
    doAssert getWasmTaskMemoryTelemetry(first) == memoryBefore
    releaseReply()
  client.drive()
  when defined(wasmAsyncMigrationTest):
    doAssert pageReads == reads + 2 and coldWrites == 2,
      "reads=" & $(pageReads - reads) & " writes=" & $coldWrites &
      " client=" & $client.state & " receiver=" & $receiver.state
  doAssert client.state == wmcComplete and
    getWasmTask(first).status == wasmSchedNoTask and
    client.telemetry.retries == 2 and client.telemetry.committed == 1
  finishDestination()

  let second = startSource()
  rejectPrepare = true
  doAssert client.beginWasmTaskMigration(second, nowTick)
  client.drive()
  doAssert client.state == wmcFailed and
    getWasmTask(second).state == wasmTaskYielded and
    receiver.state == mwPrepareFailed
  doAssert receiver.reapWasmMigrationReceiver(nowTick + 101)
  discard killWasmTask(second)
  rejectPrepare = false

  let third = startSource()
  dropCommitReplies = WasmMigrationRpcRetries + 1
  doAssert client.beginWasmTaskMigration(third, nowTick)
  client.drive()
  doAssert client.state == wmcUncertain and
    getWasmTask(third).status == wasmSchedNoTask and
    receiver.state == mwActive
  doAssert client.retryWasmMigrationCommit(nowTick)
  client.drive()
  doAssert client.state == wmcComplete
  finishDestination()
  when defined(wasmAsyncMigrationTest):
    let timedOut = startSource()
    holdRead = true
    let requests = migrationRequests
    doAssert client.beginWasmTaskMigration(timedOut, nowTick)
    doAssert client.pollWasmTaskMigration(nowTick + client.maxTransferTicks) == wmcFailed
    doAssert getWasmTask(timedOut).state == wasmTaskYielded and migrationRequests == requests
    var resumed = resumeWasmTask(timedOut, 32)
    doAssert resumed.state == wasmTaskBlockedMemory
    doAssert serviceWasmTaskMemoryFault(timedOut).state == wasmTaskBlockedMemory
    releaseReply()
    var attempts = 0
    while resumed.state in {wasmTaskBlockedMemory, wasmTaskYielded}:
      doAssert attempts < 60
      inc attempts
      resumed = if resumed.state == wasmTaskBlockedMemory: serviceWasmTaskMemoryFault(timedOut)
                else: resumeWasmTask(timedOut, 32)
    doAssert resumed.state == wasmTaskExited and resumed.result == WasmMutableResult
    discard killWasmTask(timedOut)

    let failed = startSource()
    failRead = true
    doAssert client.beginWasmTaskMigration(failed, nowTick)
    doAssert client.pollWasmTaskMigration(nowTick) == wmcFailed
    doAssert getWasmTask(failed).state == wasmTaskYielded and migrationRequests == requests
    failRead = false
    doAssert client.beginWasmTaskMigration(failed, nowTick)
    client.drive()
    doAssert client.state == wmcComplete
    finishDestination()

    let killed = startSource()
    holdRead = true
    when defined(wasmStreamingMigrationTest):
      doAssert client.beginWasmTaskStreamingMigration(killed, nowTick, 512)
      var killPolls = 0
      while delayedFuture == nil:
        doAssert client.state == wmcPending and killPolls < 40
        inc killPolls
        discard client.pollWasmTaskMigration(nowTick)
    else:
      doAssert client.beginWasmTaskMigration(killed, nowTick)
    discard killWasmTask(killed)
    doAssert client.pollWasmTaskMigration(nowTick) == wmcFailed
    releaseReply()
    when defined(wasmStreamingMigrationTest):
      doAssert receiver.reapWasmMigrationReceiver(nowTick + 101)
    echo "async page migration PASS: suspended capture, timeout, read failure, kill"

    let writeFailed = startSource()
    let writes = coldWrites
    failColdWrite = true
    doAssert client.beginWasmTaskMigration(writeFailed, nowTick)
    client.drive()
    doAssert client.state == wmcFailed and getWasmTask(writeFailed).state == wasmTaskYielded
    doAssert receiver.taskId == 0 and coldWrites == writes + 1 and destinationFrame == nil
    doAssert receiver.reapWasmMigrationReceiver(nowTick + 101)
    discard killWasmTask(writeFailed)
    failColdWrite = false

    when defined(wasmFileMigrationTest):
      let lostFile = startSource()
      doAssert client.beginWasmTaskMigration(lostFile, nowTick)
      var filePolls = 0
      while receiver.taskId == 0:
        doAssert client.state == wmcPending and filePolls < 40
        inc filePolls
        discard client.pollWasmTaskMigration(nowTick)
      let dormant = receiver.taskId
      doAssert receiver.state == mwPreparing
      destinationFile.failRead = true
      client.drive()
      destinationFile.failRead = false
      doAssert client.state == wmcFailed and getWasmTask(lostFile).state == wasmTaskYielded
      doAssert getWasmTask(dormant).status == wasmSchedNoTask and receiver.taskId == 0
      doAssert receiver.reapWasmMigrationReceiver(nowTick + 101)
      discard killWasmTask(lostFile)

    let shortBacking = startSource()
    coldSlots = 2
    doAssert client.beginWasmTaskMigration(shortBacking, nowTick)
    client.drive()
    doAssert client.state == wmcFailed and coldWrites == writes + 1
    doAssert getWasmTask(shortBacking).state == wasmTaskYielded
    doAssert receiver.reapWasmMigrationReceiver(nowTick + 101)
    discard killWasmTask(shortBacking)
    coldSlots = 3

    let expired = startSource()
    holdColdWrite = true
    doAssert client.beginWasmTaskMigration(expired, nowTick)
    var polls = 0
    while destinationFrame == nil and client.state == wmcPending:
      doAssert polls < 40
      inc polls
      discard client.pollWasmTaskMigration(nowTick)
    let preparingId = receiver.taskId
    doAssert destinationFrame != nil and receiver.state == mwPreparing and preparingId != 0
    doAssert receiver.reapWasmMigrationReceiver(nowTick + 101)
    doAssert coldCancels == 1 and destinationFrame == nil
    doAssert getWasmTask(preparingId).status == wasmSchedNoTask
    client.drive()
    doAssert client.state == wmcFailed and getWasmTask(expired).state == wasmTaskYielded
    discard killWasmTask(expired)
    echo "cold destination PASS: one frame, write failure, admission, lease cancellation"
  echo "WASM migration client PASS: retries, failure, uncertain commit"

proc main() =
  when defined(wasmExtendedMigrationTest): doAssert paramCount() in 1..2
  else: doAssert paramCount() == 1
  let moduleBytes = cast[seq[byte]](readFile(paramStr(1)))
  image = newSeq[byte](WasmProgramHeaderLen.int + moduleBytes.len)
  doAssert initWasmProgramImage(
    cast[ptr UncheckedArray[byte]](addr image[0]), image.len.uint32,
    moduleBytes) == wasmProgramOk
  resetWasmScheduler()
  wasmMigrationRpc = fakeRpc
  wasmMigrationPrepareHook = prepare
  when defined(wasmExtendedMigrationTest):
    let mode = if paramCount() == 2: paramStr(2) else: "legacy"
    when defined(wasmStreamingMigrationTest):
      case mode
      of "dense":
        expectedSnapshotBytes = 70_248
        checkStreamingTransfer(70_000, false)
      of "sparse":
        expectedSnapshotBytes = 458_900
        checkStreamingTransfer(0, true)
      else: doAssert false
    else:
      case mode
      of "legacy":
        expectedSnapshotBytes = 65_535
        checkExtendedTransfer(65_399, false)
      of "dense":
        expectedSnapshotBytes = 70_144
        checkExtendedTransfer(70_000, false)
      of "sparse":
        expectedSnapshotBytes = 458_892
        checkExtendedTransfer(0, true)
      else: doAssert false
  else: checkDefaultTransfers()

main()
