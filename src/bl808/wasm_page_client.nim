## Peer-side asynchronous backing for a bounded LinearMemory chunk cache.
## The full VM suspends first; serviceWasmTaskMemoryFault then drives this
## client from the kernel loop. Every 512/1024/2048/4096-byte chunk uses
## at most 18 bounded RPC fragments in the existing XRAM IPC slots. No
## guest load/store performs a cross-core RPC.

when not (defined(bl808lp) or defined(bl808d0) or defined(wasmPageWireHostTest)):
  {.error: "this page client is for D0 and LP".}

when defined(bl808lp):
  import ./kernel/lp_local_atomic
when defined(bl808kernel):
  import ./kernel/clock

  proc pageTick(ctx: pointer): uint64 =
    discard ctx
    readTick()

import cps/wasm/linear_memory
import ./wasm_page_wire
when defined(wasmPageWireHostTest):
  import cps/runtime
  type WasmPageRpc* = proc(request: openArray[uint8], response: pointer,
      responseBytes: int, responseLen: ptr int,
      timeoutMs: uint64): CpsVoidFuture {.nimcall.}
  var wasmPageRpc*: WasmPageRpc
else:
  import ./ipc
  import ./kernel/[cps, ipcbridge]

const WasmLpPageTimeoutMsDefault* {.intdefine.} = 5000
const WasmLpPagePartBytes* {.intdefine.} = 240
const WasmLpPageWireBytes = WasmPageWireRequestHeaderBytes + WasmLpPagePartBytes

type
  PageTransfer = enum
    ptIdle
    ptRead
    ptWrite

  WasmPageClient* = object
    slots*: uint32
    timeoutMs*: uint64
    session*: uint32
    transfer: PageTransfer
    slot: uint32
    frame: ptr UncheckedArray[byte]
    offset: uint16
    partCount: uint16
    checksum: uint32
    pendingOp: WasmPageWireOp
    future: CpsVoidFuture
    responseLen: int
    wire: array[WasmLpPageWireBytes, byte]

proc initWasmPageClient*(client: var WasmPageClient,
                           slots: uint32,
                           timeoutMs = WasmLpPageTimeoutMsDefault.uint64): bool =
  if slots == 0 or timeoutMs == 0 or WasmLpPagePartBytes <= 0 or
      WasmLpPagePartBytes > WasmPageWirePartBytes or client.transfer != ptIdle or
      (client.future != nil and not client.future.finished): return false
  client = WasmPageClient(slots: slots, timeoutMs: timeoutMs)
  true

proc resetTransfer(client: var WasmPageClient) =
  ## A failed transfer never commits to LinearMemory. The client drops its
  ## session so a later instance must handshake with the current M0 owner.
  client.transfer = ptIdle
  client.frame = nil
  client.session = 0
  client.offset = 0
  client.partCount = 0

proc cancelWasmPageTransfer*(client: var WasmPageClient): bool =
  ## Detach the frame. Keep the client at the same address until the
  ## outstanding RPC finishes writing its response, then it can be freed.
  client.resetTransfer()
  if client.future != nil and not client.future.finished: return false
  client.future = nil
  true

proc sendRequest(client: var WasmPageClient,
                 op: WasmPageWireOp): bool =
  let chunkBytes = WasmMemoryChunkBytes.uint16
  let count = if op == pwoHello: 0'u16
              else: min(WasmLpPagePartBytes,
                        chunkBytes.int - client.offset.int).uint16
  var req = WasmPageWireRequest(op: op, session: client.session,
    slot: client.slot, chunkBytes: if op == pwoHello: 0'u16 else: chunkBytes,
    offset: client.offset, count: count,
    checksum: if op == pwoWrite: client.checksum else: 0'u32)
  let data = if op == pwoWrite:
    cast[ptr UncheckedArray[byte]](cast[uint](client.frame) + client.offset.uint)
  else:
    nil
  let reqLen = req.encodePageRequest(data, client.wire)
  if reqLen == 0: return false
  client.pendingOp = op
  client.partCount = count
  client.responseLen = 0
  when defined(wasmPageWireHostTest):
    if wasmPageRpc == nil: return false
    client.future = wasmPageRpc(
      client.wire.toOpenArray(0, reqLen - 1), addr client.wire[0],
      client.wire.len, addr client.responseLen, client.timeoutMs)
  else:
    client.future = ipcCallTo(ipcM0, WasmPageWireTag,
      client.wire.toOpenArray(0, reqLen - 1), addr client.wire[0],
      client.wire.len, addr client.responseLen,
      timeoutMs = client.timeoutMs)
  client.future != nil

proc advance(client: var WasmPageClient, op: PageTransfer,
             slot: uint32,
             frame: ptr UncheckedArray[byte]): LinearMemoryStatus =
  if slot >= client.slots or frame == nil: return lmInvalidConfig
  if client.transfer == ptIdle:
    if client.future != nil:
      if not client.future.finished: return lmWouldBlock
      client.future = nil
    client.transfer = op
    client.slot = slot
    client.frame = frame
    client.offset = 0
    if op == ptWrite:
      client.checksum = wasmPageChecksum(frame, WasmMemoryChunkBytes.uint16)
    if client.session == 0:
      if not client.sendRequest(pwoHello):
        client.resetTransfer()
        return lmBackingUnavailable
    elif not client.sendRequest(if op == ptRead: pwoRead else: pwoWrite):
      client.resetTransfer()
      return lmBackingUnavailable
    return lmWouldBlock
  if client.transfer != op or client.slot != slot or client.frame != frame or
      client.future == nil:
    return lmInvalidConfig
  if not client.future.finished: return lmWouldBlock
  let error = client.future.getError()
  client.future = nil
  if error != nil:
    client.resetTransfer()
    return if op == ptRead: lmBackingReadFailed else: lmBackingWriteFailed
  var reply: WasmPageWireResponse
  if client.responseLen <= 0 or client.responseLen > client.wire.len or
      not client.wire.toOpenArray(0, client.responseLen - 1).decodePageResponse(reply) or
      reply.op != client.pendingOp or reply.status != pwsOk or
      (client.pendingOp != pwoHello and reply.session != client.session):
    client.resetTransfer()
    return if op == ptRead: lmBackingReadFailed else: lmBackingWriteFailed
  if client.pendingOp == pwoHello:
    if reply.session == 0 or reply.count != 0:
      client.resetTransfer()
      return lmBackingUnavailable
    client.session = reply.session
  elif client.pendingOp == pwoRead:
    if reply.count != client.partCount:
      client.resetTransfer()
      return lmBackingReadFailed
    if client.offset == 0:
      client.checksum = reply.checksum
    elif reply.checksum != client.checksum:
      client.resetTransfer()
      return lmBackingReadFailed
    copyMem(cast[pointer](cast[uint](client.frame) + client.offset.uint),
      addr client.wire[WasmPageWireResponseHeaderBytes], client.partCount.int)
    client.offset += client.partCount
  else:
    if reply.count != 0:
      client.resetTransfer()
      return lmBackingWriteFailed
    client.offset += client.partCount
  if client.offset == WasmMemoryChunkBytes.uint16 and
      client.pendingOp != pwoHello:
    if op == ptRead and wasmPageChecksum(client.frame,
        WasmMemoryChunkBytes.uint16) != client.checksum:
      client.resetTransfer()
      return lmBackingReadFailed
    client.transfer = ptIdle
    client.frame = nil
    return lmOk
  if not client.sendRequest(if op == ptRead: pwoRead else: pwoWrite):
    client.resetTransfer()
    return lmBackingUnavailable
  lmWouldBlock

proc readChunk(ctx: pointer, slot: uint32,
               dst: ptr UncheckedArray[byte]): LinearMemoryStatus =
  if ctx == nil: return lmBackingUnavailable
  cast[ptr WasmPageClient](ctx)[].advance(ptRead, slot, dst)

proc writeChunk(ctx: pointer, slot: uint32,
                src: ptr UncheckedArray[byte]): LinearMemoryStatus =
  if ctx == nil: return lmBackingUnavailable
  cast[ptr WasmPageClient](ctx)[].advance(ptWrite, slot, src)

proc cancelChunk(ctx: pointer, slot: uint32, frame: ptr UncheckedArray[byte],
                 operation: PageTransfer) =
  let client = cast[ptr WasmPageClient](ctx)
  if client != nil and client.transfer == operation and
      client.slot == slot and client.frame == frame:
    # The caller may free the frame now. Keep the response future for advance to
    # drain before reusing the client's response buffer.
    client[].resetTransfer()

proc cancelReadChunk(ctx: pointer, slot: uint32, dst: ptr UncheckedArray[byte]) =
  cancelChunk(ctx, slot, dst, ptRead)

proc cancelWriteChunk(ctx: pointer, slot: uint32, src: ptr UncheckedArray[byte]) =
  cancelChunk(ctx, slot, src, ptWrite)

proc linearMemoryBacking*(client: ptr WasmPageClient): LinearMemoryBacking =
  if client == nil or client.slots == 0: return LinearMemoryBacking()
  LinearMemoryBacking(ctx: client, slots: client.slots,
    readPageStatus: readChunk, writePageStatus: writeChunk, cancelRead: cancelReadChunk,
    cancelWrite: cancelWriteChunk,
    tick: (when defined(bl808kernel): pageTick else: nil))
