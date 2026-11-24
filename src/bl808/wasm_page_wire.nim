## Bounded peer-to-M0 page transfers over the existing 504-byte ipcbridge
## request/response payloads. One outstanding transfer per peer; M0 owns
## the backing and a 4 KiB staging buffer for each enabled peer. Only a
## suspended chunk fault can start this protocol.

import cps/wasm/linear_memory

const
  WasmPageWireTag* = 0x574D'u16
  WasmPageWirePayloadBytes* = 504
  WasmPageWirePartBytes* = 480
  WasmPageWireRequestHeaderBytes* = 22
  WasmPageWireResponseHeaderBytes* = 14
  WasmPageWireVersion* = 1'u8
  PageMagic = 0x57'u8

type
  WasmPageWireOp* = enum
    pwoHello = 1
    pwoRead = 2
    pwoWrite = 3

  WasmPageWireStatus* = enum
    pwsOk = 0
    pwsBadRequest = 1
    pwsStaleSession = 2
    pwsBadSlot = 3
    pwsIoFailure = 4
    pwsChecksum = 5
    pwsOutOfOrder = 6

  WasmPageWireRequest* = object
    op*: WasmPageWireOp
    session*: uint32
    slot*: uint32
    chunkBytes*: uint16
    offset*: uint16
    count*: uint16
    checksum*: uint32

  WasmPageWireResponse* = object
    op*: WasmPageWireOp
    status*: WasmPageWireStatus
    session*: uint32
    count*: uint16
    checksum*: uint32

  WasmPageWireServer* = object
    backing*: LinearMemoryBacking
    session*: uint32
    nextSession*: uint32
    slotBase, slotCount: uint32
    expectedChunkBytes: uint16
    writeActive: bool
    writeSlot: uint32
    writeChunkBytes: uint16
    writeOffset: uint16
    writeChecksum: uint32
    readValid: bool
    readSlot: uint32
    readChunkBytes: uint16
    readChecksum: uint32
    staging: array[4096, byte]

proc put16(buf: var openArray[byte], off: int, value: uint16) {.inline.} =
  buf[off] = value.byte
  buf[off + 1] = (value shr 8).byte

proc put32(buf: var openArray[byte], off: int, value: uint32) {.inline.} =
  for i in 0 ..< 4: buf[off + i] = (value shr (i * 8)).byte

proc get16(buf: openArray[byte], off: int): uint16 {.inline.} =
  buf[off].uint16 or (buf[off + 1].uint16 shl 8)

proc get32(buf: openArray[byte], off: int): uint32 {.inline.} =
  for i in 0 ..< 4: result = result or (buf[off + i].uint32 shl (i * 8))

proc wasmPageChecksum*(data: ptr UncheckedArray[byte], count: uint16): uint32 =
  ## CRC-32/ISO-HDLC. The receiving side checks a whole chunk before it
  ## commits a write or exposes a completed read to the memory backend.
  result = 0xFFFF_FFFF'u32
  for i in 0 ..< count.int:
    result = result xor data[i].uint32
    for _ in 0 ..< 8:
      let mask = 0'u32 - (result and 1'u32)
      result = (result shr 1) xor (0xEDB8_8320'u32 and mask)
  result = not result

proc encodePageRequest*(req: WasmPageWireRequest,
                        data: ptr UncheckedArray[byte],
                        outBuf: var openArray[byte]): int =
  let payload = if req.op == pwoWrite: req.count.int else: 0
  if outBuf.len < WasmPageWireRequestHeaderBytes + payload or
      req.count.int > WasmPageWirePartBytes or
      (payload != 0 and data == nil): return 0
  outBuf[0] = PageMagic
  outBuf[1] = WasmPageWireVersion
  outBuf[2] = req.op.ord.byte
  outBuf[3] = 0
  outBuf.put32(4, req.session)
  outBuf.put32(8, req.slot)
  outBuf.put16(12, req.chunkBytes)
  outBuf.put16(14, req.offset)
  outBuf.put16(16, req.count)
  outBuf.put32(18, req.checksum)
  for i in 0 ..< payload: outBuf[WasmPageWireRequestHeaderBytes + i] = data[i]
  WasmPageWireRequestHeaderBytes + payload

proc decodePageRequest*(buf: openArray[byte], req: var WasmPageWireRequest): bool =
  if buf.len < WasmPageWireRequestHeaderBytes or buf[0] != PageMagic or
      buf[1] != WasmPageWireVersion or buf[2] notin {1'u8, 2'u8, 3'u8}:
    return false
  req = WasmPageWireRequest(op: WasmPageWireOp(buf[2]),
    session: buf.get32(4), slot: buf.get32(8),
    chunkBytes: buf.get16(12), offset: buf.get16(14),
    count: buf.get16(16), checksum: buf.get32(18))
  let payload = if req.op == pwoWrite: req.count.int else: 0
  if req.count.int > WasmPageWirePartBytes or
      buf.len != WasmPageWireRequestHeaderBytes + payload:
    return false
  if req.op == pwoHello:
    return req.count == 0 and req.chunkBytes == 0 and req.offset == 0
  req.chunkBytes in {512'u16, 1024'u16, 2048'u16, 4096'u16} and
    req.offset.int <= req.chunkBytes.int and
    req.count.int <= req.chunkBytes.int - req.offset.int and
    req.count > 0

proc encodePageResponse*(resp: WasmPageWireResponse,
                         data: ptr UncheckedArray[byte],
                         outBuf: var openArray[byte]): int =
  if outBuf.len < WasmPageWireResponseHeaderBytes + resp.count.int or
      resp.count.int > WasmPageWirePartBytes or
      (resp.count != 0 and data == nil): return 0
  outBuf[0] = PageMagic
  outBuf[1] = WasmPageWireVersion
  outBuf[2] = resp.status.ord.byte
  outBuf[3] = resp.op.ord.byte
  outBuf.put32(4, resp.session)
  outBuf.put16(8, resp.count)
  outBuf.put32(10, resp.checksum)
  for i in 0 ..< resp.count.int:
    outBuf[WasmPageWireResponseHeaderBytes + i] = data[i]
  WasmPageWireResponseHeaderBytes + resp.count.int

proc decodePageResponse*(buf: openArray[byte],
                         resp: var WasmPageWireResponse): bool =
  if buf.len < WasmPageWireResponseHeaderBytes or buf[0] != PageMagic or
      buf[1] != WasmPageWireVersion or buf[2] > pwsOutOfOrder.ord.byte or
      buf[3] notin {1'u8, 2'u8, 3'u8}:
    return false
  resp = WasmPageWireResponse(status: WasmPageWireStatus(buf[2]),
    op: WasmPageWireOp(buf[3]), session: buf.get32(4),
    count: buf.get16(8), checksum: buf.get32(10))
  resp.count.int <= WasmPageWirePartBytes and
    buf.len == WasmPageWireResponseHeaderBytes + resp.count.int

proc validWasmPageSlotRange*(backing: LinearMemoryBacking,
                              first, count: uint32): bool =
  count != 0 and first < backing.slots and count <= backing.slots - first

proc initWasmPageWireRange*(server: var WasmPageWireServer,
                            backing: LinearMemoryBacking, sessionSeed: uint32,
                            firstSlot, slots: uint32,
                            expectedChunkBytes: uint16): bool =
  if not backing.validWasmPageSlotRange(firstSlot, slots) or
      expectedChunkBytes notin {0'u16, 512'u16, 1024'u16, 2048'u16, 4096'u16} or
      (backing.readPage == nil and backing.readPageStatus == nil) or
      (backing.writePage == nil and backing.writePageStatus == nil):
    return false
  server.backing = backing
  server.session = 0
  server.nextSession = if sessionSeed == 0: 1'u32 else: sessionSeed
  server.slotBase = firstSlot
  server.slotCount = slots
  server.expectedChunkBytes = expectedChunkBytes
  server.writeActive = false
  server.readValid = false
  true

proc initWasmPageWireServer*(server: var WasmPageWireServer,
                             backing: LinearMemoryBacking,
                             sessionSeed: uint32): bool =
  server.initWasmPageWireRange(backing, sessionSeed, 0, backing.slots, 0)

proc readBacking(server: var WasmPageWireServer, slot: uint32): bool =
  let dst = cast[ptr UncheckedArray[byte]](addr server.staging[0])
  let backingSlot = server.slotBase + slot
  if server.backing.readPageStatus != nil:
    server.backing.readPageStatus(server.backing.ctx, backingSlot, dst) == lmOk
  else:
    server.backing.readPage(server.backing.ctx, backingSlot, dst)

proc writeBacking(server: var WasmPageWireServer, slot: uint32): bool =
  let src = cast[ptr UncheckedArray[byte]](addr server.staging[0])
  let backingSlot = server.slotBase + slot
  if server.backing.writePageStatus != nil:
    server.backing.writePageStatus(server.backing.ctx, backingSlot, src) == lmOk
  else:
    server.backing.writePage(server.backing.ctx, backingSlot, src)

proc processWasmPageWire*(server: var WasmPageWireServer,
                          request: openArray[byte],
                          response: var openArray[byte]): int =
  ## Server-side handler for one existing ipcbridge RPC payload. The caller
  ## owns the XRAM cache handoff and invokes this outside deadline slots.
  var req: WasmPageWireRequest
  if server.slotCount == 0 or not request.decodePageRequest(req): return 0
  var reply = WasmPageWireResponse(op: req.op, session: server.session)
  if req.op == pwoHello:
    server.session = server.nextSession
    inc server.nextSession
    if server.nextSession == 0: server.nextSession = 1
    server.writeActive = false
    server.readValid = false
    reply.session = server.session
  elif req.session == 0 or req.session != server.session:
    reply.status = pwsStaleSession
  elif req.slot >= server.slotCount:
    reply.status = pwsBadSlot
  elif server.expectedChunkBytes != 0 and req.chunkBytes != server.expectedChunkBytes:
    reply.status = pwsBadRequest
  elif req.op == pwoRead:
    if server.writeActive:
      reply.status = pwsOutOfOrder
    elif req.offset == 0:
      server.readValid = server.readBacking(req.slot)
      if server.readValid:
        server.readSlot = req.slot
        server.readChunkBytes = req.chunkBytes
        server.readChecksum = wasmPageChecksum(
          cast[ptr UncheckedArray[byte]](addr server.staging[0]), req.chunkBytes)
      else:
        reply.status = pwsIoFailure
    elif not server.readValid or server.readSlot != req.slot or
        server.readChunkBytes != req.chunkBytes:
      reply.status = pwsOutOfOrder
    if reply.status == pwsOk:
      reply.count = req.count
      reply.checksum = server.readChecksum
      return reply.encodePageResponse(
        cast[ptr UncheckedArray[byte]](addr server.staging[req.offset.int]),
        response)
  elif req.op == pwoWrite:
    if req.offset == 0:
      server.writeActive = true
      server.writeSlot = req.slot
      server.writeChunkBytes = req.chunkBytes
      server.writeOffset = 0
      server.writeChecksum = req.checksum
      zeroMem(addr server.staging[0], server.staging.len)
      server.readValid = false
    if not server.writeActive or server.writeSlot != req.slot or
        server.writeChunkBytes != req.chunkBytes or
        server.writeChecksum != req.checksum or
        server.writeOffset != req.offset:
      reply.status = pwsOutOfOrder
    else:
      for i in 0 ..< req.count.int:
        server.staging[req.offset.int + i] =
          request[WasmPageWireRequestHeaderBytes + i]
      server.writeOffset += req.count
      if server.writeOffset == req.chunkBytes:
        server.writeActive = false
        if wasmPageChecksum(
            cast[ptr UncheckedArray[byte]](addr server.staging[0]),
            req.chunkBytes) != req.checksum:
          reply.status = pwsChecksum
        elif not server.writeBacking(req.slot):
          reply.status = pwsIoFailure
  reply.encodePageResponse(nil, response)
