import cps/wasm/linear_memory

type TestBacking = object
  data: array[8, array[WasmMemoryChunkBytes.int, byte]]
  failRead: bool
  failWrite: bool
  tick: uint64

type DeferredBacking = object
  data: array[2, array[WasmMemoryChunkBytes.int, byte]]
  writePending: bool
  readPending: bool
  ready: bool
  tick: uint64

proc backingTick(ctx: pointer): uint64 =
  cast[ptr TestBacking](ctx).tick

proc deferredTick(ctx: pointer): uint64 =
  cast[ptr DeferredBacking](ctx).tick

proc readPage(ctx: pointer, slot: uint32,
              dst: ptr UncheckedArray[byte]): bool =
  let backing = cast[ptr TestBacking](ctx)
  if backing.failRead or slot >= backing.data.len.uint32: return false
  backing.tick += 7
  copyMem(dst, addr backing.data[slot.int][0], WasmMemoryChunkBytes.int)
  true

proc writePage(ctx: pointer, slot: uint32,
               src: ptr UncheckedArray[byte]): bool =
  let backing = cast[ptr TestBacking](ctx)
  if backing.failWrite or slot >= backing.data.len.uint32: return false
  backing.tick += 11
  copyMem(addr backing.data[slot.int][0], src, WasmMemoryChunkBytes.int)
  true

proc deferredRead(ctx: pointer, slot: uint32,
                  dst: ptr UncheckedArray[byte]): LinearMemoryStatus =
  let backing = cast[ptr DeferredBacking](ctx)
  if slot >= backing.data.len.uint32: return lmBackingFull
  if not backing.ready:
    backing.readPending = true
    return lmWouldBlock
  backing.tick += 7
  copyMem(dst, addr backing.data[slot.int][0], WasmMemoryChunkBytes.int)
  backing.ready = false
  backing.readPending = false
  lmOk

proc deferredWrite(ctx: pointer, slot: uint32,
                   src: ptr UncheckedArray[byte]): LinearMemoryStatus =
  let backing = cast[ptr DeferredBacking](ctx)
  if slot >= backing.data.len.uint32: return lmBackingFull
  if not backing.ready:
    backing.writePending = true
    return lmWouldBlock
  backing.tick += 11
  copyMem(addr backing.data[slot.int][0], src, WasmMemoryChunkBytes.int)
  backing.ready = false
  backing.writePending = false
  lmOk

proc makeConfig(resident = 1'u32, committed = 8'u32): LinearMemoryConfig =
  LinearMemoryConfig(initialPages: 1, maxPages: 2, admissionPages: 2,
    maxCommittedChunks: committed, residentChunks: resident)

block:
  var backing: TestBacking
  var memory: LinearMemory
  doAssert memory.initLinearMemory(makeConfig(),
    LinearMemoryBacking(ctx: addr backing, slots: 8,
      readPage: readPage, writePage: writePage,
      tick: backingTick)) == lmOk
  doAssert memory.currentPages() == 1
  var bytes: array[3, byte]
  doAssert memory.readAt(4095, cast[ptr UncheckedArray[byte]](addr bytes[0]), 3) == lmOk
  doAssert bytes == [0'u8, 0, 0]
  doAssert memory.stats().committedChunks == 0

  let written = [0xA1'u8, 0xB2, 0xC3]
  doAssert memory.writeAt(4095, cast[ptr UncheckedArray[byte]](unsafeAddr written[0]), 3) == lmWouldBlock
  doAssert memory.stats().wouldBlock == 1
  # The retry is idempotent after the scheduler permits page I/O.
  doAssert memory.writeAt(4095, cast[ptr UncheckedArray[byte]](unsafeAddr written[0]), 3,
                          allowIo = true) == lmOk
  doAssert memory.stats().pageOuts >= 1
  doAssert memory.readAt(4095, cast[ptr UncheckedArray[byte]](addr bytes[0]), 3,
                         allowIo = true) == lmOk
  doAssert bytes == written
  doAssert memory.stats().pageIns >= 1
  doAssert memory.stats().maxPageInTicks == 7 and
    memory.stats().maxPageOutTicks == 11 and
    memory.stats().completedFaults >= 1 and
    memory.stats().maxFaultWaitTicks >= 11

  var old: uint32
  doAssert memory.grow(1, old) == lmOk and old == 1 and memory.currentPages() == 2
  let crossPage = [0x19'u8, 0x23]
  doAssert memory.writeAt(65535, cast[ptr UncheckedArray[byte]](unsafeAddr crossPage[0]), 2,
                          allowIo = true) == lmOk
  var result: array[2, byte]
  doAssert memory.readAt(65535, cast[ptr UncheckedArray[byte]](addr result[0]), 2,
                         allowIo = true) == lmOk
  doAssert result == crossPage
  doAssert memory.grow(1, old) == lmPageLimit and old == 2
  doAssert memory.grow(high(uint32), old) == lmPageLimit and old == 2
  doAssert memory.readAt(memory.byteLen(), cast[ptr UncheckedArray[byte]](addr result[0]), 0) == lmOk
  doAssert memory.readAt(memory.byteLen(), cast[ptr UncheckedArray[byte]](addr result[0]), 1) == lmOutOfBounds
  doAssert memory.writeAt(high(uint64), cast[ptr UncheckedArray[byte]](addr result[0]), 1) == lmOutOfBounds

block:
  var backing: TestBacking
  var memory: LinearMemory
  doAssert memory.initLinearMemory(makeConfig(resident = 2, committed = 4),
    LinearMemoryBacking(ctx: addr backing, slots: 8,
      readPage: readPage, writePage: writePage)) == lmOk
  doAssert memory.fillAt(4088, 0x5A, 24) == lmOk
  doAssert memory.copyWithin(4092, 4088, 20, allowIo = true) == lmOk
  var output: array[24, byte]
  doAssert memory.readAt(4088, cast[ptr UncheckedArray[byte]](addr output[0]), 24,
                         allowIo = true) == lmOk
  for value in output: doAssert value == 0x5A
  doAssert memory.pinRange(4088, 24, writable = true) == lmOk
  doAssert memory.stats().residentChunks == 2
  let next = [0x4B'u8]
  doAssert memory.writeAt(9000, cast[ptr UncheckedArray[byte]](unsafeAddr next[0]), 1,
                          allowIo = true) == lmNoFrame
  memory.unpinRange(4088, 24)
  doAssert memory.writeAt(9000, cast[ptr UncheckedArray[byte]](unsafeAddr next[0]), 1,
                          allowIo = true) == lmOk

block:
  var memory: LinearMemory
  doAssert memory.initLinearMemory(makeConfig(resident = 1, committed = 1)) == lmOk
  let value = [0x7F'u8]
  doAssert memory.writeAt(0, cast[ptr UncheckedArray[byte]](unsafeAddr value[0]), 1) == lmOk
  doAssert memory.writeAt(4096, cast[ptr UncheckedArray[byte]](unsafeAddr value[0]), 1) == lmCommitLimit
  doAssert memory.currentPages() == 1

block:
  var backing: TestBacking
  var memory: LinearMemory
  doAssert memory.initLinearMemory(makeConfig(resident = 1, committed = 2),
    LinearMemoryBacking(ctx: addr backing, slots: 2,
      readPage: readPage, writePage: writePage)) == lmOk
  let value = [0x7F'u8]
  doAssert memory.writeAt(0, cast[ptr UncheckedArray[byte]](unsafeAddr value[0]), 1) == lmOk
  backing.failWrite = true
  doAssert memory.writeAt(4096, cast[ptr UncheckedArray[byte]](unsafeAddr value[0]), 1,
                          allowIo = true) == lmBackingWriteFailed
  backing.failWrite = false
  doAssert memory.writeAt(4096, cast[ptr UncheckedArray[byte]](unsafeAddr value[0]), 1,
                          allowIo = true) == lmOk
  var got: array[1, byte]
  backing.failRead = true
  doAssert memory.readAt(0, cast[ptr UncheckedArray[byte]](addr got[0]), 1,
                         allowIo = true) == lmBackingReadFailed
  backing.failRead = false
  doAssert memory.readAt(0, cast[ptr UncheckedArray[byte]](addr got[0]), 1,
                         allowIo = true) == lmOk
  doAssert got[0] == 0x7F
  doAssert memory.stats().backingFailures == 2

block:
  # One resident frame cannot hold this three-chunk transfer at once. The
  # transfer cursor must make progress after each separately serviced fault.
  var backing: TestBacking
  var memory: LinearMemory
  doAssert memory.initLinearMemory(makeConfig(resident = 1, committed = 4),
    LinearMemoryBacking(ctx: addr backing, slots: 8,
      readPage: readPage, writePage: writePage)) == lmOk
  var source: array[WasmMemoryChunkBytes.int * 2 + 19, byte]
  var output: array[source.len, byte]
  for i in 0 ..< source.len: source[i] = byte(i and 255)
  var progress = 0'u32
  var faults = 0
  while progress < source.len.uint32:
    let before = progress
    let status = memory.writeAtProgress(3,
      cast[ptr UncheckedArray[byte]](addr source[0]),
      source.len.uint32, progress)
    if status == lmWouldBlock:
      doAssert progress >= before and memory.pendingFault().pending
      inc faults
      doAssert faults < 8
      doAssert memory.servicePendingFault() == lmOk
    else:
      doAssert status == lmOk and progress == source.len.uint32
  doAssert faults >= 2
  doAssert not memory.pendingFault().pending
  progress = 0
  faults = 0
  while progress < output.len.uint32:
    let before = progress
    let status = memory.readAtProgress(3,
      cast[ptr UncheckedArray[byte]](addr output[0]),
      output.len.uint32, progress)
    if status == lmWouldBlock:
      doAssert progress >= before and memory.pendingFault().pending
      inc faults
      doAssert faults < 8
      doAssert memory.servicePendingFault() == lmOk
    else:
      doAssert status == lmOk and progress == output.len.uint32
  doAssert output == source
  doAssert memory.stats().pageOuts >= 2
  doAssert memory.stats().pageIns >= 2

block:
  # A suspended overlapping copy must continue from its cursor. Replaying
  # the whole instruction after a partial backward copy corrupts the source.
  var backing: TestBacking
  var memory: LinearMemory
  doAssert memory.initLinearMemory(makeConfig(resident = 1, committed = 4),
    LinearMemoryBacking(ctx: addr backing, slots: 8,
      readPage: readPage, writePage: writePage)) == lmOk
  var source: array[WasmMemoryChunkBytes.int * 2 + 19, byte]
  var expected: array[source.len + 8, byte]
  var output: array[expected.len, byte]
  for i in 0 ..< source.len:
    source[i] = byte((i * 29) and 255)
    expected[i] = source[i]
  moveMem(addr expected[8], addr expected[0], source.len)
  doAssert memory.writeAt(0,
    cast[ptr UncheckedArray[byte]](addr source[0]), source.len.uint32,
    allowIo = true) == lmOk
  var cursor: LinearMemoryCopyCursor
  var faults = 0
  while true:
    let status = memory.copyWithinProgress(8, 0, source.len.uint32, cursor)
    if status == lmOk: break
    doAssert status == lmWouldBlock and memory.pendingFault().pending
    inc faults
    doAssert faults < 1000
    doAssert memory.servicePendingFault() == lmOk
  doAssert faults > 0
  doAssert memory.readAt(0,
    cast[ptr UncheckedArray[byte]](addr output[0]), output.len.uint32,
    allowIo = true) == lmOk
  doAssert output == expected

block:
  # The backing owner can start an IPC/SD transfer and report lmWouldBlock.
  # The guest remains suspended until a later service call sees it complete.
  var backing: DeferredBacking
  backing.tick = 100
  var memory: LinearMemory
  doAssert memory.initLinearMemory(makeConfig(resident = 1, committed = 2),
    LinearMemoryBacking(ctx: addr backing, slots: 2,
      readPageStatus: deferredRead, writePageStatus: deferredWrite,
      tick: deferredTick)) == lmOk
  let first = [0xA5'u8]
  let second = [0x5A'u8]
  doAssert memory.writeAt(0,
    cast[ptr UncheckedArray[byte]](unsafeAddr first[0]), 1) == lmOk
  doAssert memory.writeAt(WasmMemoryChunkBytes.uint64,
    cast[ptr UncheckedArray[byte]](unsafeAddr second[0]), 1) == lmWouldBlock
  doAssert memory.servicePendingFault() == lmWouldBlock and backing.writePending
  doAssert memory.pendingFault().pending
  backing.tick = 120
  backing.ready = true
  doAssert memory.servicePendingFault() == lmOk
  doAssert memory.writeAt(WasmMemoryChunkBytes.uint64,
    cast[ptr UncheckedArray[byte]](unsafeAddr second[0]), 1) == lmOk
  var got: array[1, byte]
  doAssert memory.readAt(0,
    cast[ptr UncheckedArray[byte]](addr got[0]), 1) == lmWouldBlock
  doAssert memory.servicePendingFault() == lmWouldBlock and backing.writePending
  backing.ready = true
  doAssert memory.servicePendingFault() == lmWouldBlock and backing.readPending
  backing.ready = true
  doAssert memory.servicePendingFault() == lmOk
  doAssert memory.readAt(0,
    cast[ptr UncheckedArray[byte]](addr got[0]), 1) == lmOk
  doAssert got[0] == 0xA5
  doAssert memory.stats().pageOuts == 2 and memory.stats().pageIns == 1
  doAssert memory.stats().pageOutTicks == 22 and
    memory.stats().pageInTicks == 7 and
    memory.stats().completedFaults == 2 and
    memory.stats().maxFaultWaitTicks >= 31

echo "chunked WASM memory PASS: bounds, grow, cross-chunk, swap, pin, suspend, failure"
