import bl808/wasm_page_wire
import cps/wasm/linear_memory

type Backing = object
  pages: array[2, array[4096, byte]]
  failRead: bool
  failWrite: bool

proc readPage(ctx: pointer, slot: uint32,
              dst: ptr UncheckedArray[byte]): bool =
  let backing = cast[ptr Backing](ctx)
  if backing.failRead or slot >= backing.pages.len.uint32: return false
  copyMem(dst, addr backing.pages[slot.int][0], 4096)
  true

proc writePage(ctx: pointer, slot: uint32,
               src: ptr UncheckedArray[byte]): bool =
  let backing = cast[ptr Backing](ctx)
  if backing.failWrite or slot >= backing.pages.len.uint32: return false
  copyMem(addr backing.pages[slot.int][0], src, 4096)
  true

var backing: Backing
var server: WasmPageWireServer
let store = LinearMemoryBacking(ctx: addr backing, slots: 2,
  readPage: readPage, writePage: writePage)
doAssert server.initWasmPageWireServer(store, 99)
var request: array[WasmPageWirePayloadBytes, byte]
var response: array[WasmPageWirePayloadBytes, byte]

proc send(req: WasmPageWireRequest,
          data: ptr UncheckedArray[byte] = nil,
          endpoint = addr server): WasmPageWireResponse =
  let reqLen = req.encodePageRequest(data, request)
  doAssert reqLen > 0
  let respLen = endpoint[].processWasmPageWire(
    request.toOpenArray(0, reqLen - 1), response)
  doAssert respLen > 0 and
    response.toOpenArray(0, respLen - 1).decodePageResponse(result)

let hello = send(WasmPageWireRequest(op: pwoHello))
doAssert hello.status == pwsOk and hello.session == 99
let session = hello.session

for chunkBytes in [1024'u16, 4096'u16]:
  var source: array[4096, byte]
  var output: array[4096, byte]
  for i in 0 ..< chunkBytes.int:
    source[i] = byte((i * 37 + chunkBytes.int) and 255)
  let checksum = wasmPageChecksum(
    cast[ptr UncheckedArray[byte]](addr source[0]), chunkBytes)
  var offset = 0
  while offset < chunkBytes.int:
    let count = min(WasmPageWirePartBytes, chunkBytes.int - offset)
    let req = WasmPageWireRequest(op: pwoWrite, session: session,
      slot: if chunkBytes == 1024: 0'u32 else: 1'u32,
      chunkBytes: chunkBytes, offset: offset.uint16,
      count: count.uint16, checksum: checksum)
    let reply = send(req,
      cast[ptr UncheckedArray[byte]](addr source[offset]))
    doAssert reply.status == pwsOk and reply.count == 0
    offset += count
  let slot = if chunkBytes == 1024: 0 else: 1
  for i in 0 ..< chunkBytes.int:
    doAssert backing.pages[slot][i] == source[i]
  for i in chunkBytes.int ..< 4096:
    doAssert backing.pages[slot][i] == 0
  offset = 0
  while offset < chunkBytes.int:
    let count = min(WasmPageWirePartBytes, chunkBytes.int - offset)
    let reply = send(WasmPageWireRequest(op: pwoRead,
      session: session, slot: slot.uint32, chunkBytes: chunkBytes,
      offset: offset.uint16, count: count.uint16))
    doAssert reply.status == pwsOk and reply.count == count.uint16 and
      reply.checksum == checksum
    copyMem(addr output[offset],
      addr response[WasmPageWireResponseHeaderBytes], count)
    offset += count
  doAssert output == source
  doAssert wasmPageChecksum(
    cast[ptr UncheckedArray[byte]](addr output[0]), chunkBytes) == checksum

let stale = send(WasmPageWireRequest(op: pwoRead, session: session - 1,
  slot: 0, chunkBytes: 1024, offset: 0, count: 1))
doAssert stale.status == pwsStaleSession
let badOrder = send(WasmPageWireRequest(op: pwoWrite, session: session,
  slot: 0, chunkBytes: 1024, offset: 480, count: 1, checksum: 0),
  cast[ptr UncheckedArray[byte]](addr request[0]))
doAssert badOrder.status == pwsOutOfOrder
backing.failRead = true
doAssert send(WasmPageWireRequest(op: pwoRead, session: session,
  slot: 0, chunkBytes: 1024, offset: 0, count: 1)).status == pwsIoFailure
backing.failRead = false
var changed: array[1024, byte]
for i in 0 ..< changed.len: changed[i] = byte((i * 11) and 255)
let goodCrc = wasmPageChecksum(
  cast[ptr UncheckedArray[byte]](addr changed[0]), 1024)
let original = backing.pages[0]
changed[13] = changed[13] xor 1
var offset = 0
while offset < changed.len:
  let count = min(WasmPageWirePartBytes, changed.len - offset)
  let reply = send(WasmPageWireRequest(op: pwoWrite, session: session,
    slot: 0, chunkBytes: 1024, offset: offset.uint16,
    count: count.uint16, checksum: goodCrc),
    cast[ptr UncheckedArray[byte]](addr changed[offset]))
  if offset + count == changed.len:
    doAssert reply.status == pwsChecksum
  else:
    doAssert reply.status == pwsOk
  offset += count
doAssert backing.pages[0] == original

backing.failWrite = true
let changedCrc = wasmPageChecksum(
  cast[ptr UncheckedArray[byte]](addr changed[0]), 1024)
offset = 0
while offset < changed.len:
  let count = min(WasmPageWirePartBytes, changed.len - offset)
  let reply = send(WasmPageWireRequest(op: pwoWrite, session: session,
    slot: 0, chunkBytes: 1024, offset: offset.uint16,
    count: count.uint16, checksum: changedCrc),
    cast[ptr UncheckedArray[byte]](addr changed[offset]))
  if offset + count == changed.len:
    doAssert reply.status == pwsIoFailure
  else:
    doAssert reply.status == pwsOk
  offset += count
doAssert backing.pages[0] == original

backing.failWrite = false
var lpServer, d0Server: WasmPageWireServer
doAssert not d0Server.initWasmPageWireRange(store, 1, 1, 2, 512)
doAssert lpServer.initWasmPageWireRange(store, 89, 0, 1, 512)
doAssert d0Server.initWasmPageWireRange(store, 12, 1, 1, 512)
let lpSession = send(WasmPageWireRequest(op: pwoHello), endpoint = addr lpServer).session
let d0Session = send(WasmPageWireRequest(op: pwoHello), endpoint = addr d0Server).session
var readReq = WasmPageWireRequest(op: pwoRead, session: lpSession,
  slot: 0, chunkBytes: 512, count: 1)
doAssert send(readReq, endpoint = addr d0Server).status == pwsStaleSession
readReq.session = d0Session
readReq.slot = 1
doAssert send(readReq, endpoint = addr d0Server).status == pwsBadSlot
readReq.slot = 0
readReq.chunkBytes = 1024
doAssert send(readReq, endpoint = addr d0Server).status == pwsBadRequest
readReq.chunkBytes = 512

var lpData, d0Data: array[512, byte]
for i in 0 ..< 512:
  lpData[i] = byte(i and 127)
  d0Data[i] = lpData[i] or 128'u8
let lpCrc = wasmPageChecksum(cast[ptr UncheckedArray[byte]](addr lpData[0]), 512)
let d0Crc = wasmPageChecksum(cast[ptr UncheckedArray[byte]](addr d0Data[0]), 512)
for off in [0, 256]:
  let lpWrite = WasmPageWireRequest(op: pwoWrite, session: lpSession,
    slot: 0, chunkBytes: 512, offset: off.uint16, count: 256, checksum: lpCrc)
  let d0Write = WasmPageWireRequest(op: pwoWrite, session: d0Session,
    slot: 0, chunkBytes: 512, offset: off.uint16, count: 256, checksum: d0Crc)
  doAssert send(lpWrite, cast[ptr UncheckedArray[byte]](addr lpData[off]),
    addr lpServer).status == pwsOk
  doAssert send(d0Write, cast[ptr UncheckedArray[byte]](addr d0Data[off]),
    addr d0Server).status == pwsOk
  if off == 0:
    doAssert send(readReq, endpoint = addr d0Server).status == pwsOutOfOrder
doAssert backing.pages[0][0 ..< 512] == @lpData
doAssert backing.pages[1][0 ..< 512] == @d0Data
doAssert send(readReq, endpoint = addr d0Server).checksum == d0Crc
doAssert response[WasmPageWireResponseHeaderBytes] == d0Data[0]
readReq.session = lpSession
doAssert send(readReq, endpoint = addr lpServer).checksum == lpCrc
doAssert response[WasmPageWireResponseHeaderBytes] == lpData[0]
echo "WASM page wire PASS: bounded transfer, peer slots and sessions, CRC, order, I/O"
