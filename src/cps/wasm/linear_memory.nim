## Bounded, chunked backing for a WebAssembly 1.0 linear memory.
## Guest page counts are always in 64 KiB units. The 4 KiB chunks below are
## private storage units and are never visible as WebAssembly pages.
##
## Page I/O is performed only when allowIo=true. The progress APIs preserve a
## transfer cursor across lmWouldBlock, so a scheduler can service the pending
## fault outside the guest's execution slot and resume without repeating bytes
## already transferred. A real-time caller must pin its writable working set
## ahead of its slot, then use allowIo=false and treat lmWouldBlock as an
## admission bug.

import std/algorithm

const
  WasmGuestPageBytes* = 65536'u32
  WasmMemoryChunkBytesConfig* {.intdefine.} = 4096
  WasmMemoryChunkBytes* = WasmMemoryChunkBytesConfig.uint32
  WasmChunksPerGuestPage* = WasmGuestPageBytes div WasmMemoryChunkBytes
  WasmMemoryMaxPages* = 65536'u32
  WasmTieredFramesEnabled* = defined(wasmTieredFrames) and not defined(bl808lp)

when WasmTieredFramesEnabled:
  type
    LinearFrameLeaseObj = object
      ctx: pointer
      release: proc(ctx: pointer) {.nimcall, raises: [].}
    LinearFrameLease = ref LinearFrameLeaseObj

  proc `=destroy`(lease: LinearFrameLeaseObj) =
    if lease.release != nil: lease.release(lease.ctx)

type
  LinearMemoryStatus* = enum
    lmOk
    lmOutOfBounds
    lmInvalidConfig
    lmPageLimit
    lmCommitLimit
    lmNoFrame
    lmWouldBlock
    lmBackingFull
    lmBackingUnavailable
    lmBackingReadFailed
    lmBackingWriteFailed

  LinearMemoryReadPage* = proc(ctx: pointer, slot: uint32,
                               dst: ptr UncheckedArray[byte]): bool {.nimcall.}
  LinearMemoryWritePage* = proc(ctx: pointer, slot: uint32,
                                src: ptr UncheckedArray[byte]): bool {.nimcall.}
  LinearMemoryReadPageStatus* = proc(ctx: pointer, slot: uint32,
      dst: ptr UncheckedArray[byte]): LinearMemoryStatus {.nimcall.}
  LinearMemoryWritePageStatus* = proc(ctx: pointer, slot: uint32,
      src: ptr UncheckedArray[byte]): LinearMemoryStatus {.nimcall.}
  LinearMemoryCancelTransfer* = proc(ctx: pointer, slot: uint32,
      frame: ptr UncheckedArray[byte]) {.nimcall, raises: [].}
  LinearMemoryCancelRead* = LinearMemoryCancelTransfer
  LinearMemoryTick* = proc(ctx: pointer): uint64 {.nimcall.}

  LinearMemoryBacking* = object
    ctx*: pointer
    slots*: uint32
    readPage*: LinearMemoryReadPage
    writePage*: LinearMemoryWritePage
    readPageStatus*: LinearMemoryReadPageStatus
    writePageStatus*: LinearMemoryWritePageStatus
    tick*: LinearMemoryTick
    ## A status read may retain dst only on lmWouldBlock. Cancellation must
    ## detach this exact read before returning and retain any transport-owned
    ## response buffer until its request completes.
    cancelRead*: LinearMemoryCancelRead
    ## Status writes have the same retention rule for their source frame.
    cancelWrite*: LinearMemoryCancelTransfer

  LinearMemoryConfig* = object
    initialPages*: uint32
    maxPages*: uint32
    admissionPages*: uint32
    maxCommittedChunks*: uint32
    residentChunks*: uint32

  LinearMemoryStats* = object
    guestPages*: uint32
    committedChunks*: uint32
    residentChunks*: uint32
    backedChunks*: uint32
    pageIns*: uint32
    pageOuts*: uint32
    wouldBlock*: uint32
    backingFailures*: uint32
    pageInTicks*: uint64
    pageOutTicks*: uint64
    maxPageInTicks*: uint64
    maxPageOutTicks*: uint64
    completedFaults*: uint32
    maxFaultWaitTicks*: uint64
    when WasmTieredFramesEnabled:
      sramResidentChunks*, psramResidentChunks*: uint32

  LinearMemoryFault* = object
    pending*: bool
    chunk*: uint32
    forWrite*: bool

  LinearSnapshotRead* = object
    scratch: seq[byte]
    pending: bool
    slot: uint32

  LinearMemoryCopyCursor* = object
    ## Guest memory.copy state retained across backing misses. Keep one cursor
    ## per in-flight copy and pass the same offsets/count until it completes.
    active: bool
    destination, source: uint64
    count, done, partSize, partProgress: uint32
    backward: bool
    writing: bool
    scratch: array[64, byte]

  LinearChunk = object
    number: uint32
    frame: int32
    backingSlot: int32
    dirty: bool
    pins: uint16

  LinearFrame = object
    chunk: int32
    lastUse: uint32

  LinearMemory* = object
    config: LinearMemoryConfig
    backing: LinearMemoryBacking
    pages: uint32
    chunks: seq[LinearChunk]
    frames: seq[LinearFrame]
    ownedData: seq[byte]
    externalData: ptr UncheckedArray[byte]
    nextBackingSlot: uint32
    clock: uint32
    counters: LinearMemoryStats
    fault: LinearMemoryFault
    faultStartedTick: uint64
    faultTimed: bool
    when WasmTieredFramesEnabled:
      psramData: ptr UncheckedArray[byte]
      sramFrames: int
      lease: LinearFrameLease

proc addTicks(total: var uint64, maximum: var uint64,
              startTick, endTick: uint64) {.inline.} =
  if endTick < startTick: return
  let elapsed = endTick - startTick
  total = total + min(elapsed, high(uint64) - total)
  if elapsed > maximum: maximum = elapsed

proc markFault(mem: var LinearMemory, chunk: uint32, forWrite: bool) =
  if not mem.fault.pending or mem.fault.chunk != chunk or
      mem.fault.forWrite != forWrite:
    mem.faultTimed = mem.backing.tick != nil
    if mem.faultTimed:
      mem.faultStartedTick = mem.backing.tick(mem.backing.ctx)
  mem.fault = LinearMemoryFault(pending: true, chunk: chunk,
                                 forWrite: forWrite)

proc clearFault(mem: var LinearMemory) =
  if mem.fault.pending:
    if mem.counters.completedFaults < high(uint32):
      inc mem.counters.completedFaults
    if mem.faultTimed:
      let endTick = mem.backing.tick(mem.backing.ctx)
      if endTick >= mem.faultStartedTick:
        let elapsed = endTick - mem.faultStartedTick
        if elapsed > mem.counters.maxFaultWaitTicks:
          mem.counters.maxFaultWaitTicks = elapsed
  mem.fault.pending = false
  mem.faultTimed = false

proc frameData(mem: var LinearMemory): ptr UncheckedArray[byte] {.inline.} =
  if mem.externalData != nil:
    mem.externalData
  elif mem.ownedData.len > 0:
    cast[ptr UncheckedArray[byte]](addr mem.ownedData[0])
  else:
    nil

proc framePtr(mem: var LinearMemory, frame: int): ptr UncheckedArray[byte] {.inline.} =
  when WasmTieredFramesEnabled:
    if mem.psramData != nil and frame >= mem.sramFrames:
      return cast[ptr UncheckedArray[byte]](cast[uint](mem.psramData) +
        uint(frame - mem.sramFrames) * uint(WasmMemoryChunkBytes))
  cast[ptr UncheckedArray[byte]](cast[uint](mem.frameData()) +
    uint(frame) * uint(WasmMemoryChunkBytes))

proc validConfig(cfg: LinearMemoryConfig): bool =
  if cfg.maxPages == 0:
    return cfg.initialPages == 0 and cfg.admissionPages == 0 and
      cfg.maxCommittedChunks == 0 and cfg.residentChunks == 0
  WasmMemoryChunkBytesConfig >= 512 and
    WasmMemoryChunkBytesConfig <= 4096 and
    (WasmMemoryChunkBytesConfig and (WasmMemoryChunkBytesConfig - 1)) == 0 and
    WasmGuestPageBytes mod WasmMemoryChunkBytes == 0 and
    cfg.maxPages <= WasmMemoryMaxPages and
    cfg.initialPages <= cfg.maxPages and
    cfg.admissionPages >= cfg.initialPages and
    cfg.admissionPages <= cfg.maxPages and
    cfg.maxCommittedChunks > 0 and
    cfg.maxCommittedChunks <= cfg.admissionPages * WasmChunksPerGuestPage and
    cfg.residentChunks > 0 and cfg.residentChunks <= cfg.maxCommittedChunks and
    cfg.residentChunks <= uint32(high(int) div int(WasmMemoryChunkBytes))

proc initLinearMemory*(mem: var LinearMemory, cfg: LinearMemoryConfig,
                       backing = LinearMemoryBacking()): LinearMemoryStatus =
  ## Own resident storage in the native heap. For LP and shared XRAM, use
  ## initLinearMemoryIn with a caller-owned buffer instead.
  if not validConfig(cfg): return lmInvalidConfig
  mem = LinearMemory(config: cfg, backing: backing, pages: cfg.initialPages)
  mem.frames = newSeq[LinearFrame](cfg.residentChunks.int)
  mem.ownedData = newSeq[byte](cfg.residentChunks.int * WasmMemoryChunkBytes.int)
  for frame in mem.frames.mitems: frame.chunk = -1
  lmOk

proc initLinearMemoryIn*(mem: var LinearMemory, cfg: LinearMemoryConfig,
                         storage: ptr UncheckedArray[byte],
                         storageBytes: uint32,
                         backing = LinearMemoryBacking()): LinearMemoryStatus =
  ## The storage may live in SRAM or PSRAM. It must remain owned by the caller
  ## for the whole lifetime of mem and be writable from the calling core.
  if not validConfig(cfg) or storage == nil or
      uint64(storageBytes) < uint64(cfg.residentChunks) * WasmMemoryChunkBytes.uint64:
    return lmInvalidConfig
  mem = LinearMemory(config: cfg, backing: backing, pages: cfg.initialPages,
                     externalData: storage)
  mem.frames = newSeq[LinearFrame](cfg.residentChunks.int)
  for frame in mem.frames.mitems: frame.chunk = -1
  lmOk

when WasmTieredFramesEnabled:
  proc initTieredLinearMemoryIn*(mem: var LinearMemory, cfg: LinearMemoryConfig,
      sram, psram: ptr UncheckedArray[byte], sramChunks: uint32,
      sramBytes, psramBytes: uint32, backing = LinearMemoryBacking()): LinearMemoryStatus =
    ## Sizes and capacity refer to caller-reserved physical bytes. The first
    ## frames are SRAM, and only those frames may hold pins.
    if not validConfig(cfg) or sram == nil or
        sramChunks == 0 or sramChunks > cfg.residentChunks:
      return lmInvalidConfig
    let hotSize = sramChunks.uint64 * WasmMemoryChunkBytes.uint64
    let coldSize = (cfg.residentChunks - sramChunks).uint64 * WasmMemoryChunkBytes.uint64
    let hot = cast[uint](sram).uint64
    let addressLimit = high(uint).uint64
    if hotSize > sramBytes.uint64 or hotSize > addressLimit - hot:
      return lmInvalidConfig
    if coldSize != 0:
      let cold = cast[uint](psram).uint64
      if psram == nil or coldSize > psramBytes.uint64 or coldSize > addressLimit - cold or
          (if hot <= cold: hotSize > cold - hot else: coldSize > hot - cold):
        return lmInvalidConfig
    mem = LinearMemory(config: cfg, backing: backing, pages: cfg.initialPages,
      externalData: sram, psramData: (if coldSize == 0: nil else: psram),
      sramFrames: sramChunks.int)
    mem.frames = newSeq[LinearFrame](cfg.residentChunks.int)
    for frame in mem.frames.mitems: frame.chunk = -1
    lmOk

  proc retainLinearFrameReservation*(mem: var LinearMemory, ctx: pointer,
      release: proc(ctx: pointer) {.nimcall, raises: [].}): bool =
    ## Run the release hook once when the last reference to the lease dies.
    if mem.lease != nil or release == nil or mem.externalData == nil:
      return false
    mem.lease = LinearFrameLease(ctx: ctx, release: release)
    true

proc byteLen*(mem: LinearMemory): uint64 {.inline.} =
  mem.pages.uint64 * WasmGuestPageBytes.uint64

proc currentPages*(mem: LinearMemory): uint32 {.inline.} = mem.pages

proc grow*(mem: var LinearMemory, delta: uint32,
           previousPages: var uint32): LinearMemoryStatus =
  ## Implements memory.grow's unsigned page delta without integer overflow.
  previousPages = mem.pages
  let next = mem.pages.uint64 + delta.uint64
  if next > mem.config.maxPages.uint64 or next > mem.config.admissionPages.uint64:
    return lmPageLimit
  mem.pages = next.uint32
  lmOk

proc inBounds(mem: LinearMemory, offset: uint64, count: uint32): bool {.inline.} =
  let limit = mem.byteLen()
  offset <= limit and count.uint64 <= limit - offset

proc findChunk(mem: LinearMemory, number: uint32): int {.inline.} =
  for i in 0 ..< mem.chunks.len:
    if mem.chunks[i].number == number: return i
  -1

proc touch(mem: var LinearMemory, frame: int) {.inline.} =
  inc mem.clock
  mem.frames[frame].lastUse = mem.clock

proc chooseFrame(mem: LinearMemory, first, stop: int): int =
  for i in first ..< stop:
    if mem.frames[i].chunk < 0: return i
  var bestAge = high(uint32)
  result = -1
  for i in first ..< stop:
    let ci = mem.frames[i].chunk.int
    if mem.chunks[ci].pins == 0 and mem.frames[i].lastUse <= bestAge:
      bestAge = mem.frames[i].lastUse
      result = i

when WasmTieredFramesEnabled:
  proc moveFrame(mem: var LinearMemory, source, target: int) =
    ## The target is vacant. Move bytes and preserve the chunk's backing and
    ## dirty state by changing only its frame binding.
    copyMem(mem.framePtr(target), mem.framePtr(source), WasmMemoryChunkBytes.int)
    mem.frames[target] = mem.frames[source]
    mem.frames[source].chunk = -1
    mem.chunks[mem.frames[target].chunk.int].frame = target.int32

  proc promoteFrame(mem: var LinearMemory, source, target: int) =
    if mem.frames[target].chunk < 0:
      mem.moveFrame(source, target)
      return
    # The SRAM victim is unpinned. Exchange bytes without evicting either
    # chunk or allocating a whole shadow frame.
    let src = mem.framePtr(source)
    let dst = mem.framePtr(target)
    var scratch: array[64, byte]
    for offset in countup(0, WasmMemoryChunkBytes.int - 1, scratch.len):
      copyMem(addr scratch[0], addr src[offset], scratch.len)
      copyMem(addr src[offset], addr dst[offset], scratch.len)
      copyMem(addr dst[offset], addr scratch[0], scratch.len)
    swap(mem.frames[source], mem.frames[target])
    mem.chunks[mem.frames[source].chunk.int].frame = source.int32
    mem.chunks[mem.frames[target].chunk.int].frame = target.int32

proc releaseFrame(mem: var LinearMemory, frame: int,
                  allowIo: bool): LinearMemoryStatus =
  let old = mem.frames[frame].chunk
  if old < 0: return lmOk
  let ci = old.int
  if mem.chunks[ci].pins > 0: return lmNoFrame
  if mem.chunks[ci].dirty:
    if mem.backing.writePage == nil and mem.backing.writePageStatus == nil:
      return lmBackingUnavailable
    var slot = mem.chunks[ci].backingSlot
    if slot < 0:
      if mem.nextBackingSlot >= mem.backing.slots: return lmBackingFull
      slot = mem.nextBackingSlot.int32
    if not allowIo:
      inc mem.counters.wouldBlock
      return lmWouldBlock
    let timed = mem.backing.tick != nil
    let startTick = if timed: mem.backing.tick(mem.backing.ctx) else: 0'u64
    let status = if mem.backing.writePageStatus != nil:
      mem.backing.writePageStatus(mem.backing.ctx, slot.uint32,
                                  mem.framePtr(frame))
    elif mem.backing.writePage(mem.backing.ctx, slot.uint32,
                               mem.framePtr(frame)):
      lmOk
    else:
      lmBackingWriteFailed
    if status == lmWouldBlock:
      inc mem.counters.wouldBlock
      return status
    if status != lmOk:
      inc mem.counters.backingFailures
      return status
    if timed:
      addTicks(mem.counters.pageOutTicks,
        mem.counters.maxPageOutTicks, startTick,
        mem.backing.tick(mem.backing.ctx))
    if mem.chunks[ci].backingSlot < 0:
      mem.chunks[ci].backingSlot = slot
      inc mem.nextBackingSlot
    mem.chunks[ci].dirty = false
    inc mem.counters.pageOuts
  mem.chunks[ci].frame = -1
  mem.frames[frame].chunk = -1
  lmOk

proc ensureChunk(mem: var LinearMemory, number: uint32,
                 forWrite, allowIo: bool, forPin = false): LinearMemoryStatus =
  when WasmTieredFramesEnabled:
    let pinToSram = forPin and mem.psramData != nil
    let frameLimit = if pinToSram: mem.sramFrames else: mem.frames.len
  else:
    let frameLimit = mem.frames.len
  var ci = mem.findChunk(number)
  if ci < 0 and not forWrite: return lmOk  # never written: implicit zero
  if ci >= 0 and mem.chunks[ci].frame >= 0:
    var resident = mem.chunks[ci].frame.int
    when WasmTieredFramesEnabled:
      if pinToSram and resident >= frameLimit:
        let sram = mem.chooseFrame(0, frameLimit)
        if sram < 0: return lmNoFrame
        mem.promoteFrame(resident, sram)
        resident = sram
    mem.touch(resident)
    return lmOk
  if ci < 0 and mem.chunks.len.uint32 >= mem.config.maxCommittedChunks:
    return lmCommitLimit
  let frame = mem.chooseFrame(0, frameLimit)
  if frame < 0: return lmNoFrame
  if ci >= 0 and mem.chunks[ci].backingSlot >= 0 and not allowIo:
    inc mem.counters.wouldBlock
    return lmWouldBlock
  let eviction = when WasmTieredFramesEnabled:
      if pinToSram and mem.frames[frame].chunk >= 0: mem.chooseFrame(frameLimit, mem.frames.len)
      else: frame
    else: frame
  if eviction < 0: return lmNoFrame
  let evicted = mem.releaseFrame(eviction, allowIo)
  if evicted != lmOk: return evicted
  when WasmTieredFramesEnabled:
    if eviction != frame: mem.moveFrame(frame, eviction)
  if ci < 0:
    ci = mem.chunks.len
    mem.chunks.add(LinearChunk(number: number, frame: -1, backingSlot: -1))
    zeroMem(mem.framePtr(frame), WasmMemoryChunkBytes.int)
  elif mem.chunks[ci].backingSlot >= 0:
    if mem.backing.readPage == nil and mem.backing.readPageStatus == nil:
      return lmBackingUnavailable
    let timed = mem.backing.tick != nil
    let startTick = if timed: mem.backing.tick(mem.backing.ctx) else: 0'u64
    let status = if mem.backing.readPageStatus != nil:
      mem.backing.readPageStatus(mem.backing.ctx,
        mem.chunks[ci].backingSlot.uint32, mem.framePtr(frame))
    elif mem.backing.readPage(mem.backing.ctx,
        mem.chunks[ci].backingSlot.uint32, mem.framePtr(frame)):
      lmOk
    else:
      lmBackingReadFailed
    if status == lmWouldBlock:
      inc mem.counters.wouldBlock
      return status
    if status != lmOk:
      inc mem.counters.backingFailures
      return status
    if timed:
      addTicks(mem.counters.pageInTicks,
        mem.counters.maxPageInTicks, startTick,
        mem.backing.tick(mem.backing.ctx))
    inc mem.counters.pageIns
  else:
    zeroMem(mem.framePtr(frame), WasmMemoryChunkBytes.int)
  mem.chunks[ci].frame = frame.int32
  mem.frames[frame].chunk = ci.int32
  mem.touch(frame)
  lmOk

proc pendingFault*(mem: LinearMemory): LinearMemoryFault {.inline.} =
  mem.fault

proc snapshotChunkOrder*(mem: LinearMemory): seq[tuple[number: uint32, index: int]] =
  ## Guest order is independent of the core's frame layout or eviction order.
  result = newSeq[tuple[number: uint32, index: int]](mem.chunks.len)
  for i in 0 ..< result.len: result[i] = (mem.chunks[i].number, i)
  result.sort()

proc snapshotChunkBytes*(mem: var LinearMemory, index: int,
    read: var LinearSnapshotRead, data: var ptr UncheckedArray[byte],
    allowAsync: static bool): LinearMemoryStatus =
  ## Read an evicted chunk without replacing a guest frame or touching LRU.
  ## The caller must retry the same index or cancel before releasing the cursor.
  let chunk = mem.chunks[index]
  if chunk.frame >= 0:
    data = mem.framePtr(chunk.frame.int)
    return lmOk
  if chunk.backingSlot < 0: return lmBackingUnavailable
  if mem.backing.readPage == nil:
    when allowAsync:
      if mem.backing.readPageStatus == nil or mem.backing.cancelRead == nil:
        return lmBackingUnavailable
    else:
      return lmBackingUnavailable
  let slot = chunk.backingSlot.uint32
  if read.scratch.len == 0: read.scratch.setLen(WasmMemoryChunkBytes.int)
  data = cast[ptr UncheckedArray[byte]](addr read.scratch[0])
  if mem.backing.readPage != nil:
    return if mem.backing.readPage(mem.backing.ctx, slot, data): lmOk else: lmBackingReadFailed
  when allowAsync:
    read.slot = slot
    read.pending = true
    result = mem.backing.readPageStatus(mem.backing.ctx, slot, data)
    read.pending = result == lmWouldBlock
  else:
    lmBackingUnavailable

proc cancelLinearSnapshotRead*(mem: var LinearMemory, read: var LinearSnapshotRead) =
  if read.pending:
    mem.backing.cancelRead(mem.backing.ctx, read.slot,
      cast[ptr UncheckedArray[byte]](addr read.scratch[0]))
  read = LinearSnapshotRead()

proc snapshotPageLimit*(mem: LinearMemory): uint32 =
  mem.config.admissionPages

proc snapshotRequiresBacking*(mem: LinearMemory, chunks: uint32): bool =
  chunks > mem.config.residentChunks

proc canRestoreLinearSnapshot*(mem: LinearMemory, pages, chunks: uint32,
                                allowPaging = false): bool =
  if pages < mem.pages or pages > mem.config.admissionPages or
      chunks > mem.config.maxCommittedChunks or mem.fault.pending:
    return false
  if mem.snapshotRequiresBacking(chunks):
    # Slots remain assigned after page-in. Every restored chunk can later
    # become dirty and need a slot before its replacement can be read.
    if not allowPaging or mem.backing.slots < chunks or
        (mem.backing.readPage == nil and mem.backing.readPageStatus == nil) or
        (if mem.backing.writePageStatus != nil: mem.backing.cancelWrite == nil
         else: mem.backing.writePage == nil):
      return false
  for chunk in mem.chunks:
    if chunk.pins != 0: return false
  true

proc resetLinearForSnapshot*(mem: var LinearMemory, pages: uint32) =
  ## Call only on an admitted, dormant destination. Writes to newly committed
  ## chunks zero their whole frame before applying the snapshot's sparse bytes.
  mem.pages = pages
  mem.chunks.setLen(0)
  mem.nextBackingSlot = 0
  mem.clock = 0
  for frame in mem.frames.mitems: frame.chunk = -1

proc cancelLinearRestore*(mem: var LinearMemory) =
  ## Ordered snapshot replay only blocks while evicting an older chunk. The
  ## dormant instance cannot change the eviction candidate between polls.
  if mem.fault.pending and mem.fault.forWrite and mem.backing.cancelWrite != nil:
    let frame = mem.chooseFrame(0, mem.frames.len)
    if frame >= 0 and mem.frames[frame].chunk >= 0:
      let chunk = mem.chunks[mem.frames[frame].chunk.int]
      let slot = if chunk.backingSlot < 0: mem.nextBackingSlot else: chunk.backingSlot.uint32
      mem.backing.cancelWrite(mem.backing.ctx, slot, mem.framePtr(frame))
  mem.fault.pending = false
  mem.faultTimed = false

proc servicePendingFault*(mem: var LinearMemory): LinearMemoryStatus =
  ## Call from the backing owner, outside a guest deadline slot. A failed
  ## service leaves the same fault pending for a later retry or cancellation.
  if not mem.fault.pending: return lmOk
  let status = mem.ensureChunk(mem.fault.chunk, mem.fault.forWrite, true)
  if status == lmOk: mem.clearFault()
  status

proc readAtProgress*(mem: var LinearMemory, offset: uint64,
                     dst: ptr UncheckedArray[byte], count: uint32,
                     progress: var uint32,
                     allowIo = false): LinearMemoryStatus =
  ## `progress` starts at zero and belongs to this transfer. Keep `dst` alive
  ## across suspensions; the caller may move it only after completion.
  if progress > count or not mem.inBounds(offset, count): return lmOutOfBounds
  if count > 0 and dst == nil: return lmInvalidConfig
  while progress < count:
    let at = offset + progress.uint64
    let chunk = uint32(at div WasmMemoryChunkBytes.uint64)
    let inner = uint32(at mod WasmMemoryChunkBytes.uint64)
    let size = min(count - progress, WasmMemoryChunkBytes - inner)
    let status = mem.ensureChunk(chunk, false, allowIo)
    if status == lmWouldBlock:
      mem.markFault(chunk, false)
    if status != lmOk: return status
    let ci = mem.findChunk(chunk)
    if ci < 0:
      zeroMem(addr dst[progress.int], size.int)
    else:
      copyMem(addr dst[progress.int],
        addr mem.framePtr(mem.chunks[ci].frame.int)[inner.int], size.int)
    progress += size
  mem.clearFault()
  lmOk

proc writeAtProgress*(mem: var LinearMemory, offset: uint64,
                      src: ptr UncheckedArray[byte], count: uint32,
                      progress: var uint32,
                      allowIo = false): LinearMemoryStatus =
  ## The caller must keep `src` unchanged until this transfer completes.
  if progress > count or not mem.inBounds(offset, count): return lmOutOfBounds
  if count > 0 and src == nil: return lmInvalidConfig
  while progress < count:
    let at = offset + progress.uint64
    let chunk = uint32(at div WasmMemoryChunkBytes.uint64)
    let inner = uint32(at mod WasmMemoryChunkBytes.uint64)
    let size = min(count - progress, WasmMemoryChunkBytes - inner)
    let status = mem.ensureChunk(chunk, true, allowIo)
    if status == lmWouldBlock:
      mem.markFault(chunk, true)
    if status != lmOk: return status
    let ci = mem.findChunk(chunk)
    copyMem(addr mem.framePtr(mem.chunks[ci].frame.int)[inner.int],
            addr src[progress.int], size.int)
    mem.chunks[ci].dirty = true
    progress += size
  mem.clearFault()
  lmOk

proc readAt*(mem: var LinearMemory, offset: uint64,
             dst: ptr UncheckedArray[byte], count: uint32,
             allowIo = false): LinearMemoryStatus =
  var progress = 0'u32
  mem.readAtProgress(offset, dst, count, progress, allowIo)

proc writeAt*(mem: var LinearMemory, offset: uint64,
              src: ptr UncheckedArray[byte], count: uint32,
              allowIo = false): LinearMemoryStatus =
  var progress = 0'u32
  mem.writeAtProgress(offset, src, count, progress, allowIo)

proc fillAt*(mem: var LinearMemory, offset: uint64, value: byte,
             count: uint32, allowIo = false): LinearMemoryStatus =
  if not mem.inBounds(offset, count): return lmOutOfBounds
  var scratch: array[64, byte]
  for cell in scratch.mitems: cell = value
  var done = 0'u32
  while done < count:
    let size = min(count - done, scratch.len.uint32)
    let status = mem.writeAt(offset + done.uint64,
      cast[ptr UncheckedArray[byte]](addr scratch[0]), size, allowIo)
    if status != lmOk: return status
    done += size
  lmOk

proc copyWithinProgress*(mem: var LinearMemory, destination, source: uint64,
                         count: uint32, cursor: var LinearMemoryCopyCursor,
                         allowIo = false): LinearMemoryStatus =
  ## The cursor preserves both a bounded scratch buffer and exact byte
  ## progress. This matters for overlapping copies: retrying from byte zero
  ## after a page miss could read data already overwritten by an earlier step.
  if not mem.inBounds(source, count) or not mem.inBounds(destination, count):
    return lmOutOfBounds
  if cursor.active:
    if cursor.destination != destination or cursor.source != source or
        cursor.count != count:
      return lmInvalidConfig
  else:
    cursor = LinearMemoryCopyCursor(active: true, destination: destination,
      source: source, count: count,
      backward: destination > source and destination - source < count.uint64)
  while cursor.done < count:
    if cursor.partSize == 0:
      cursor.partSize = min(count - cursor.done, cursor.scratch.len.uint32)
      cursor.partProgress = 0
      cursor.writing = false
    let start = if cursor.backward: count - cursor.done - cursor.partSize
                else: cursor.done
    if not cursor.writing:
      let status = mem.readAtProgress(source + start.uint64,
        cast[ptr UncheckedArray[byte]](addr cursor.scratch[0]),
        cursor.partSize, cursor.partProgress, allowIo)
      if status != lmOk: return status
      cursor.writing = true
      cursor.partProgress = 0
    let status = mem.writeAtProgress(destination + start.uint64,
      cast[ptr UncheckedArray[byte]](addr cursor.scratch[0]),
      cursor.partSize, cursor.partProgress, allowIo)
    if status != lmOk: return status
    cursor.done += cursor.partSize
    cursor.partSize = 0
  cursor.active = false
  lmOk

proc copyWithin*(mem: var LinearMemory, destination, source: uint64,
                 count: uint32, allowIo = false): LinearMemoryStatus =
  ## WASM memory.copy overlap semantics. The scratch buffer is bounded and
  ## copies backward when destination overlaps the source from above.
  if not mem.inBounds(source, count) or not mem.inBounds(destination, count):
    return lmOutOfBounds
  var scratch: array[64, byte]
  if destination > source and destination - source < count.uint64:
    var remaining = count
    while remaining > 0:
      let size = min(remaining, scratch.len.uint32)
      let start = remaining - size
      let readStatus = mem.readAt(source + start.uint64,
        cast[ptr UncheckedArray[byte]](addr scratch[0]), size, allowIo)
      if readStatus != lmOk: return readStatus
      let writeStatus = mem.writeAt(destination + start.uint64,
        cast[ptr UncheckedArray[byte]](addr scratch[0]), size, allowIo)
      if writeStatus != lmOk: return writeStatus
      remaining = start
  else:
    var done = 0'u32
    while done < count:
      let size = min(count - done, scratch.len.uint32)
      let readStatus = mem.readAt(source + done.uint64,
        cast[ptr UncheckedArray[byte]](addr scratch[0]), size, allowIo)
      if readStatus != lmOk: return readStatus
      let writeStatus = mem.writeAt(destination + done.uint64,
        cast[ptr UncheckedArray[byte]](addr scratch[0]), size, allowIo)
      if writeStatus != lmOk: return writeStatus
      done += size
  lmOk

proc pinRange*(mem: var LinearMemory, offset: uint64, count: uint32,
               writable: bool, allowIo = false): LinearMemoryStatus =
  ## Preload and pin chunks before a hard slot. Writable pins commit zero
  ## chunks now; read-only pins need only load chunks that have backing.
  if not mem.inBounds(offset, count): return lmOutOfBounds
  if count == 0: return lmOk
  let first = uint32(offset div WasmMemoryChunkBytes.uint64)
  let last = uint32((offset + count.uint64 - 1) div WasmMemoryChunkBytes.uint64)
  var chunk = first
  while chunk <= last:
    let status = mem.ensureChunk(chunk, writable, allowIo, forPin = true)
    if status != lmOk:
      for pinned in first ..< chunk:
        let ci = mem.findChunk(pinned)
        if ci >= 0 and mem.chunks[ci].pins > 0: dec mem.chunks[ci].pins
      return status
    let ci = mem.findChunk(chunk)
    if ci >= 0:
      if mem.chunks[ci].pins == high(uint16):
        for pinned in first ..< chunk:
          let previous = mem.findChunk(pinned)
          if previous >= 0 and mem.chunks[previous].pins > 0:
            dec mem.chunks[previous].pins
        return lmNoFrame
      inc mem.chunks[ci].pins
    inc chunk
  lmOk

proc unpinRange*(mem: var LinearMemory, offset: uint64, count: uint32) =
  if count == 0 or not mem.inBounds(offset, count): return
  let first = uint32(offset div WasmMemoryChunkBytes.uint64)
  let last = uint32((offset + count.uint64 - 1) div WasmMemoryChunkBytes.uint64)
  for chunk in first .. last:
    let ci = mem.findChunk(chunk)
    if ci >= 0 and mem.chunks[ci].pins > 0:
      dec mem.chunks[ci].pins

proc hardResidentReady*(mem: LinearMemory): bool =
  ## A conservative hard-slot admission check: every committed chunk must
  ## already occupy a pinned frame, and the commit quota must be exhausted so
  ## a guest write cannot allocate a new frame inside the slot. The caller
  ## still has to establish that the guest does not write an uncommitted
  ## chunk, grow memory, or use an unbounded bulk operation.
  if mem.fault.pending or
      mem.chunks.len.uint32 != mem.config.maxCommittedChunks:
    return false
  for chunk in mem.chunks:
    if chunk.frame < 0 or chunk.pins == 0: return false
    when WasmTieredFramesEnabled:
      if mem.psramData != nil and chunk.frame.int >= mem.sramFrames: return false
  true

proc stats*(mem: LinearMemory): LinearMemoryStats =
  result = mem.counters
  result.guestPages = mem.pages
  result.committedChunks = mem.chunks.len.uint32
  result.backedChunks = mem.nextBackingSlot
  for index, frame in mem.frames:
    if frame.chunk < 0: continue
    inc result.residentChunks
    when WasmTieredFramesEnabled:
      if index < mem.sramFrames:
        inc result.sramResidentChunks
      elif mem.psramData != nil:
        inc result.psramResidentChunks
