## Per-instance resident frame storage for the full M0/D0 interpreter.
## The board owns controller initialization and assigns disjoint SRAM, PSRAM,
## and optional swap ranges. The interpreter holds a lease until teardown.

import cps/wasm/[linear_memory, types]
when defined(bl808m0) or defined(bl808d0):
  import ./memmap

when not WasmTieredFramesEnabled:
  {.error: "PSRAM frames require wasmTieredFrames and an M0 or D0 build".}

type WasmPsramFrames* = object
  sram, psram: ptr UncheckedArray[byte]
  sramBytes, psramBytes: uint32
  pageLimit, commitLimit: uint32
  swap: LinearMemoryBacking
  firstSlot, swapSlots: uint32
  active: bool

proc `=copy`(dest: var WasmPsramFrames, source: WasmPsramFrames) {.error: "PSRAM reservations cannot be copied".}

proc configureFrames(owner: var WasmPsramFrames, sram, psram: ptr UncheckedArray[byte],
    sramBytes, psramBytes, pageLimit, commitLimit: uint32,
    swap: LinearMemoryBacking, firstSlot, swapSlots: uint32): bool =
  if owner.active or sram == nil or psram == nil or pageLimit == 0 or
      pageLimit > WasmMemoryMaxPages or commitLimit == 0 or
      sramBytes < WasmMemoryChunkBytes or psramBytes < WasmMemoryChunkBytes or
      sramBytes mod WasmMemoryChunkBytes != 0 or psramBytes mod WasmMemoryChunkBytes != 0:
    return false
  let hot = cast[uint](sram)
  let cold = cast[uint](psram)
  if sramBytes.uint > high(uint) - hot or psramBytes.uint > high(uint) - cold or
      (if hot <= cold: sramBytes.uint > cold - hot else: psramBytes.uint > hot - cold):
    return false
  if swapSlots != 0 and
      (firstSlot > swap.slots or swapSlots > swap.slots - firstSlot or
       (swap.readPage == nil and swap.readPageStatus == nil) or
       (swap.writePage == nil and swap.writePageStatus == nil)):
    return false
  owner = WasmPsramFrames(sram: sram, psram: psram, sramBytes: sramBytes, psramBytes: psramBytes,
    pageLimit: pageLimit, commitLimit: commitLimit, swap: swap,
    firstSlot: firstSlot, swapSlots: swapSlots)
  true

when defined(bl808m0) or defined(bl808d0):
  func contains(base, size, address, count: uint): bool =
    address >= base and count <= size and address - base <= size - count

  proc reserveWasmPsramFrames*(owner: var WasmPsramFrames, sram: ptr UncheckedArray[byte],
      sramBytes, psramOffset, psramBytes, pageLimit, commitLimit: uint32,
      swap = LinearMemoryBacking(), firstSlot = 0'u32, swapSlots = 0'u32): bool =
    ## Call after board-level PSRAM setup. Offsets are from PsramBase and
    ## must come from this firmware's memory layout. No device I/O occurs here.
    let addrSram = cast[uint](sram)
    let sramOwned = when defined(bl808m0):
        contains(OcramBase, OcramSize.uint, addrSram, sramBytes.uint) or
          contains(OcramCachedBase, OcramSize.uint, addrSram, sramBytes.uint) or
          contains(WramBase, WramSize.uint, addrSram, sramBytes.uint) or
          contains(WramCachedBase, WramSize.uint, addrSram, sramBytes.uint)
      else:
        contains(DramBase, DramSize.uint, addrSram, sramBytes.uint)
    if not sramOwned or psramOffset mod WasmMemoryChunkBytes != 0 or
        not contains(0, PsramSize.uint, psramOffset.uint, psramBytes.uint):
      return false
    let psram = cast[ptr UncheckedArray[byte]](PsramBase + psramOffset.uint)
    owner.configureFrames(sram, psram, sramBytes, psramBytes, pageLimit, commitLimit,
      swap, firstSlot, swapSlots)

when not (defined(bl808m0) or defined(bl808d0)) or defined(wasmPsramFramesEmulated):
  proc reserveEmulatedPsramFrames*(owner: var WasmPsramFrames,
      sram, psram: ptr UncheckedArray[byte], sramBytes, psramBytes, pageLimit, commitLimit: uint32,
      swap = LinearMemoryBacking(), firstSlot = 0'u32, swapSlots = 0'u32): bool =
    ## Host and emulator stand-in. A target release build uses the real window.
    owner.configureFrames(sram, psram, sramBytes, psramBytes, pageLimit, commitLimit,
      swap, firstSlot, swapSlots)

proc readSwap(ctx: pointer, slot: uint32, dst: ptr UncheckedArray[byte]): LinearMemoryStatus =
  let owner = cast[ptr WasmPsramFrames](ctx)
  if slot >= owner.swapSlots: return lmBackingFull
  let index = owner.firstSlot + slot
  if owner.swap.readPageStatus != nil:
    return owner.swap.readPageStatus(owner.swap.ctx, index, dst)
  if owner.swap.readPage(owner.swap.ctx, index, dst): lmOk else: lmBackingReadFailed

proc writeSwap(ctx: pointer, slot: uint32, src: ptr UncheckedArray[byte]): LinearMemoryStatus =
  let owner = cast[ptr WasmPsramFrames](ctx)
  if slot >= owner.swapSlots: return lmBackingFull
  owner.swap.writePageStatus(owner.swap.ctx, owner.firstSlot + slot, src)

proc readSwapForSnapshot(ctx: pointer, slot: uint32, dst: ptr UncheckedArray[byte]): bool =
  let owner = cast[ptr WasmPsramFrames](ctx)
  slot < owner.swapSlots and owner.swap.readPage(owner.swap.ctx, owner.firstSlot + slot, dst)

proc cancelSwapRead(ctx: pointer, slot: uint32, dst: ptr UncheckedArray[byte]) =
  let owner = cast[ptr WasmPsramFrames](ctx)
  if slot < owner.swapSlots:
    owner.swap.cancelRead(owner.swap.ctx, owner.firstSlot + slot, dst)

proc cancelSwapWrite(ctx: pointer, slot: uint32, src: ptr UncheckedArray[byte]) =
  let owner = cast[ptr WasmPsramFrames](ctx)
  if slot < owner.swapSlots:
    owner.swap.cancelWrite(owner.swap.ctx, owner.firstSlot + slot, src)

proc writeSwapSync(ctx: pointer, slot: uint32, src: ptr UncheckedArray[byte]): bool =
  let owner = cast[ptr WasmPsramFrames](ctx)
  slot < owner.swapSlots and owner.swap.writePage(owner.swap.ctx, owner.firstSlot + slot, src)

proc swapTick(ctx: pointer): uint64 =
  let swap = addr cast[ptr WasmPsramFrames](ctx).swap
  swap.tick(swap.ctx)

proc releaseFrames(ctx: pointer) {.nimcall, raises: [].} =
  cast[ptr WasmPsramFrames](ctx).active = false

proc wasmPsramMemoryFactory*(ctx: pointer, memType: MemType): ref LinearMemory {.nimcall.} =
  ## Use from the owning core's serialized scheduler. Keep the reservation at
  ## a stable address and retain its buffers and swap slice until release.
  ## An asynchronous backing owns its request cancellation and must quiesce
  ## any transfer using a released reservation before reuse.
  let owner = cast[ptr WasmPsramFrames](ctx)
  if owner == nil or owner.active or owner.sram == nil: return nil
  let pages = if memType.limits.hasMax: min(owner.pageLimit, memType.limits.max)
    else: owner.pageLimit
  if memType.limits.min > pages: return nil
  new(result)
  if pages == 0:
    if result[].initLinearMemory(LinearMemoryConfig()) != lmOk: return nil
    return
  let sramChunks = owner.sramBytes div WasmMemoryChunkBytes
  let frameCount = sramChunks + owner.psramBytes div WasmMemoryChunkBytes
  let backing = if owner.swapSlots == 0: LinearMemoryBacking()
    else: LinearMemoryBacking(ctx: ctx, slots: owner.swapSlots,
      readPage: if owner.swap.readPage == nil: nil else: readSwapForSnapshot,
      readPageStatus: readSwap,
      writePageStatus: if owner.swap.writePageStatus == nil: nil else: writeSwap,
      writePage: if owner.swap.writePage == nil: nil else: writeSwapSync,
      cancelRead: if owner.swap.cancelRead == nil: nil else: cancelSwapRead,
      cancelWrite: if owner.swap.cancelWrite == nil: nil else: cancelSwapWrite,
      tick: if owner.swap.tick == nil: nil else: swapTick)
  let committed = min(min(owner.commitLimit, pages * WasmChunksPerGuestPage).uint64,
                      frameCount.uint64 + backing.slots.uint64).uint32
  let cfg = LinearMemoryConfig(initialPages: memType.limits.min, maxPages: pages,
    admissionPages: pages, maxCommittedChunks: committed, residentChunks: min(frameCount, committed))
  let status = result[].initTieredLinearMemoryIn(cfg, owner.sram, owner.psram,
    min(sramChunks, cfg.residentChunks), owner.sramBytes, owner.psramBytes, backing)
  if status != lmOk or not result[].retainLinearFrameReservation(ctx, releaseFrames): return nil
  owner.active = true
