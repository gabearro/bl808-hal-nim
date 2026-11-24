## M0-owned adapter from the bounded WASM chunk backend to the dedicated
## preallocated FatFs swap file. Do not use this callback from a deadline slot:
## the I/O is synchronous and may block for an unbounded SD-card latency.

when not defined(bl808m0):
  {.error: "the SD swap-file owner is M0".}

import cps/wasm/linear_memory
import ./kernel/[fatfs, sd_swap_file]
when defined(bl808kernel):
  import ./kernel/clock

type WasmSdBacking* = object
  fs*: ptr SdFs
  file*: ptr SdSwapFile
  firstSlot*, slotCount*: uint32  ## zero count uses the remainder of the file
  ## Required when the VM chunk is smaller than a 4 KiB SD swap slot. Keep
  ## this M0-owned buffer alive for the entire backing lifetime; do not put it
  ## on the guest or RPC call stack.
  scratch*: ptr UncheckedArray[byte]
  scratchBytes*: uint32

proc usableSlots(owner: ptr WasmSdBacking): uint32 {.inline.} =
  if owner.firstSlot >= owner.file[].slots: return 0
  let available = owner.file[].slots - owner.firstSlot
  if owner.slotCount == 0: available
  elif owner.slotCount <= available: owner.slotCount
  else: 0

proc ready(owner: ptr WasmSdBacking): bool {.inline.} =
  owner != nil and owner.fs != nil and owner.file != nil and
    owner.file[].open and owner.usableSlots() != 0 and
    (WasmMemoryChunkBytes == SdSwapPageBytes or
     (owner.scratch != nil and owner.scratchBytes >= SdSwapPageBytes))

when defined(bl808kernel):
  proc backingTick(ctx: pointer): uint64 =
    discard ctx
    readTick()

proc readChunk(ctx: pointer, slot: uint32,
               dst: ptr UncheckedArray[byte]): bool =
  let owner = cast[ptr WasmSdBacking](ctx)
  if not owner.ready() or dst == nil or slot >= owner.usableSlots(): return false
  let diskSlot = owner.firstSlot + slot
  when WasmMemoryChunkBytes == SdSwapPageBytes:
    result = sdSwapReadPage(owner.fs[], owner.file[], diskSlot,
      cast[ptr UncheckedArray[uint8]](dst)) == sdSwapOk
  else:
    if sdSwapReadPage(owner.fs[], owner.file[], diskSlot,
        cast[ptr UncheckedArray[uint8]](owner.scratch)) != sdSwapOk:
      return false
    copyMem(dst, owner.scratch, WasmMemoryChunkBytes.int)
    result = true

proc writeChunk(ctx: pointer, slot: uint32,
                src: ptr UncheckedArray[byte]): bool =
  let owner = cast[ptr WasmSdBacking](ctx)
  if not owner.ready() or src == nil or slot >= owner.usableSlots(): return false
  let diskSlot = owner.firstSlot + slot
  when WasmMemoryChunkBytes == SdSwapPageBytes:
    result = sdSwapWritePage(owner.fs[], owner.file[], diskSlot,
      cast[ptr UncheckedArray[uint8]](src)) == sdSwapOk
  else:
    if src == owner.scratch:
      zeroMem(addr owner.scratch[WasmMemoryChunkBytes.int],
        (SdSwapPageBytes - WasmMemoryChunkBytes).int)
    else:
      zeroMem(owner.scratch, SdSwapPageBytes.int)
      copyMem(owner.scratch, src, WasmMemoryChunkBytes.int)
    result = sdSwapWritePage(owner.fs[], owner.file[], diskSlot,
      cast[ptr UncheckedArray[uint8]](owner.scratch)) == sdSwapOk

proc linearMemoryBacking*(owner: ptr WasmSdBacking): LinearMemoryBacking =
  ## Each VM chunk occupies one preallocated 4 KiB file slot. Smaller chunks
  ## leave the rest zeroed, avoiding partial-slot updates and preserving exact
  ## swap-in. The caller owns the file and optional staging buffer.
  if not owner.ready():
    return LinearMemoryBacking()
  LinearMemoryBacking(ctx: owner, slots: owner.usableSlots(),
    readPage: readChunk, writePage: writeChunk,
    tick: (when defined(bl808kernel): backingTick else: nil))
