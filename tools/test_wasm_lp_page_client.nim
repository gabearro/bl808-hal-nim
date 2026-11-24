import bl808/[wasm_lp_page_client, wasm_page_wire]
import cps/runtime
import cps/wasm/linear_memory

type Backing = object
  pages: array[3, array[4096, byte]]
  failRead: bool

proc readPage(ctx: pointer, slot: uint32,
              dst: ptr UncheckedArray[byte]): bool =
  let backing = cast[ptr Backing](ctx)
  if backing.failRead or slot >= backing.pages.len.uint32: return false
  copyMem(dst, addr backing.pages[slot.int][0], 4096)
  true

proc writePage(ctx: pointer, slot: uint32,
               src: ptr UncheckedArray[byte]): bool =
  let backing = cast[ptr Backing](ctx)
  if slot >= backing.pages.len.uint32: return false
  copyMem(addr backing.pages[slot.int][0], src, 4096)
  true

var backing: Backing
var server: WasmPageWireServer
doAssert server.initWasmPageWireServer(LinearMemoryBacking(
  ctx: addr backing, slots: 3, readPage: readPage,
  writePage: writePage), 17)
var calls = 0
var failNext = false
var holdNext = false
var heldFuture: CpsVoidFuture
var heldResponseLen: ptr int

proc rpc(request: openArray[uint8], response: pointer,
         responseBytes: int, responseLen: ptr int,
         timeoutMs: uint64): CpsVoidFuture =
  discard timeoutMs
  inc calls
  result = newCpsVoidFuture()
  if holdNext:
    holdNext = false
    heldFuture = result
    heldResponseLen = responseLen
    return
  if failNext:
    failNext = false
    result.fail(newException(IOError, "peer reset"))
    return
  var answer: array[WasmPageWirePayloadBytes, byte]
  let size = server.processWasmPageWire(request, answer)
  if size <= 0 or size > responseBytes:
    result.fail(newException(IOError, "bad page response"))
    return
  copyMem(response, addr answer[0], size)
  responseLen[] = size
  result.complete()

wasmLpPageRpc = rpc
var client: WasmLpPageClient
doAssert client.initWasmLpPageClient(3)
var resident: array[WasmMemoryChunkBytes.int, byte]
var memory: LinearMemory
doAssert memory.initLinearMemoryIn(LinearMemoryConfig(
  initialPages: 1, maxPages: 1, admissionPages: 1,
  maxCommittedChunks: 3, residentChunks: 1),
  cast[ptr UncheckedArray[byte]](addr resident[0]), resident.len.uint32,
  client.addr.linearMemoryBacking()) == lmOk

let first = [0xA5'u8]
let second = [0x5A'u8]
doAssert memory.writeAt(0,
  cast[ptr UncheckedArray[byte]](unsafeAddr first[0]), 1) == lmOk
doAssert memory.writeAt(WasmMemoryChunkBytes.uint64,
  cast[ptr UncheckedArray[byte]](unsafeAddr second[0]), 1) == lmWouldBlock
var serviced = 0
while true:
  let status = memory.servicePendingFault()
  inc serviced
  if status == lmOk: break
  doAssert status == lmWouldBlock and serviced < 20
doAssert client.session == 17 and serviced > 2
doAssert memory.writeAt(WasmMemoryChunkBytes.uint64,
  cast[ptr UncheckedArray[byte]](unsafeAddr second[0]), 1) == lmOk
doAssert backing.pages[0][0] == 0xA5

var got: array[1, byte]
doAssert memory.readAt(0,
  cast[ptr UncheckedArray[byte]](addr got[0]), 1) == lmWouldBlock
serviced = 0
while true:
  let status = memory.servicePendingFault()
  inc serviced
  if status == lmOk: break
  doAssert status == lmWouldBlock and serviced < 50
doAssert memory.readAt(0,
  cast[ptr UncheckedArray[byte]](addr got[0]), 1) == lmOk
doAssert got[0] == 0xA5 and backing.pages[1][0] == 0x5A
doAssert memory.stats().pageIns == 1 and memory.stats().pageOuts == 2

doAssert memory.readAt(WasmMemoryChunkBytes.uint64,
  cast[ptr UncheckedArray[byte]](addr got[0]), 1) == lmWouldBlock
failNext = true
doAssert memory.servicePendingFault() == lmWouldBlock
doAssert memory.servicePendingFault() == lmBackingReadFailed
doAssert client.session == 0 and memory.pendingFault().pending

let remote = client.addr.linearMemoryBacking()
var nextFrame: array[WasmMemoryChunkBytes.int, byte]
let dst = cast[ptr UncheckedArray[byte]](addr nextFrame[0])
holdNext = true
doAssert remote.readPageStatus(remote.ctx, 0, dst) == lmWouldBlock
doAssert not client.cancelWasmPageTransfer()
doAssert not client.initWasmLpPageClient(3)
let pendingCalls = calls
doAssert remote.readPageStatus(remote.ctx, 0, dst) == lmWouldBlock
doAssert calls == pendingCalls
heldResponseLen[] = 0
heldFuture.complete()
doAssert client.cancelWasmPageTransfer()
doAssert client.initWasmLpPageClient(3)
for i in 0 ..< 100:
  let status = remote.readPageStatus(remote.ctx, 0, dst)
  if status == lmOk: break
  doAssert status == lmWouldBlock and i < 99
doAssert nextFrame[0] == 0xA5
echo "LP page client PASS: XRAM fragments, exact swap-in, peer failure, cancellation"
