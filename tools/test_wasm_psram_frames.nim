import bl808/[wasm_psram_frames, wasm_scheduler]
import cps/wasm/[linear_memory, types]
import wasm_psram_frames_fixture

const Chunk = WasmMemoryChunkBytes

type Swap = object
  data: array[4, array[Chunk.int, byte]]
  lastRead, lastWrite: uint32
  failRead, failWrite: bool

proc readSwap(ctx: pointer, slot: uint32, dst: ptr UncheckedArray[byte]): bool =
  let swap = cast[ptr Swap](ctx)
  if slot >= swap.data.len.uint32 or swap.failRead: return false
  swap.lastRead = slot
  copyMem(dst, addr swap.data[slot.int][0], Chunk.int)
  true

proc writeSwap(ctx: pointer, slot: uint32, src: ptr UncheckedArray[byte]): bool =
  let swap = cast[ptr Swap](ctx)
  if slot >= swap.data.len.uint32 or swap.failWrite: return false
  swap.lastWrite = slot
  copyMem(addr swap.data[slot.int][0], src, Chunk.int)
  true

proc put(memory: var LinearMemory, chunk: uint32, value: byte,
         allowIo = false): LinearMemoryStatus =
  var byteValue = value
  memory.writeAt(chunk.uint64 * Chunk, cast[ptr UncheckedArray[byte]](addr byteValue), 1, allowIo)

proc get(memory: var LinearMemory, chunk: uint32): tuple[status: LinearMemoryStatus, value: byte] =
  result.status = memory.readAt(chunk.uint64 * Chunk,
    cast[ptr UncheckedArray[byte]](addr result.value), 1)

let guestMemory = MemType(limits: Limits(min: 1, max: 2, hasMax: true))
var owner: WasmPsramFrames
var hot, cold: array[Chunk.int, byte]
let sram = cast[ptr UncheckedArray[byte]](addr hot[0])
let psram = cast[ptr UncheckedArray[byte]](addr cold[0])
doAssert not owner.reserveEmulatedPsramFrames(sram, sram, Chunk, Chunk, 2, 8)
doAssert owner.reserveEmulatedPsramFrames(sram, psram, Chunk, Chunk, 2, 8)

block:
  var memory = wasmPsramMemoryFactory(addr owner, guestMemory)
  doAssert memory != nil and wasmPsramMemoryFactory(addr owner, guestMemory) == nil
  doAssert not owner.reserveEmulatedPsramFrames(sram, psram, Chunk, Chunk, 2, 8)
  doAssert memory[].put(0, 0xAA) == lmOk
  # Preload another chunk directly into SRAM, demoting the hot victim.
  doAssert memory[].pinRange(Chunk, 1, writable = true) == lmOk
  doAssert hot[0] == 0 and cold[0] == 0xAA
  doAssert memory[].put(1, 0xBB) == lmOk
  doAssert memory[].pinRange(0, 1, writable = true) == lmNoFrame
  memory[].unpinRange(Chunk, 1)
  # With both tiers occupied, pinning swaps their bytes and frame bindings.
  doAssert memory[].pinRange(0, 1, writable = true) == lmOk
  doAssert hot[0] == 0xAA and cold[0] == 0xBB
  doAssert memory[].get(0) == (lmOk, byte 0xAA) and memory[].get(1) == (lmOk, byte 0xBB)
  doAssert memory[].stats().sramResidentChunks == 1 and memory[].stats().psramResidentChunks == 1
  doAssert not memory[].hardResidentReady()
  doAssert memory[].put(2, 0xCC) == lmCommitLimit
  var previous: uint32
  doAssert memory[].grow(1, previous) == lmOk and previous == 1
  doAssert memory[].grow(1, previous) == lmPageLimit and previous == 2
  var retained = memory
  memory = nil
  doAssert wasmPsramMemoryFactory(addr owner, guestMemory) == nil
  doAssert retained[].get(0) == (lmOk, byte 0xAA)
  retained = nil

block:
  let empty = wasmPsramMemoryFactory(addr owner, MemType(limits: Limits(hasMax: true)))
  doAssert empty != nil and empty[].byteLen() == 0
  var previous: uint32
  doAssert empty[].grow(0, previous) == lmOk and previous == 0
  doAssert empty[].grow(1, previous) == lmPageLimit
  let memory = wasmPsramMemoryFactory(addr owner, guestMemory)
  doAssert memory != nil and memory[].get(0) == (lmOk, byte 0)

block:
  doAssert owner.reserveEmulatedPsramFrames(sram, psram, Chunk, Chunk, 2, 1)
  doAssert wasmPsramMemoryFactory(addr owner, MemType(limits: Limits(min: 3))) == nil
  let memory = wasmPsramMemoryFactory(addr owner, guestMemory)
  doAssert memory != nil and memory[].pinRange(0, 1, writable = true) == lmOk
  doAssert memory[].hardResidentReady()
  doAssert memory[].stats().sramResidentChunks == 1 and memory[].stats().psramResidentChunks == 0

block:
  var swap: Swap
  let backing = LinearMemoryBacking(ctx: addr swap, slots: swap.data.len.uint32,
    readPage: readSwap, writePage: writeSwap)
  doAssert not owner.reserveEmulatedPsramFrames(sram, psram, Chunk, Chunk, 2, 4,
    backing, firstSlot = 3, swapSlots = 2)
  doAssert owner.reserveEmulatedPsramFrames(sram, psram, Chunk, Chunk, 2, 4,
    backing, firstSlot = 2, swapSlots = 1)
  let memory = wasmPsramMemoryFactory(addr owner, guestMemory)
  doAssert memory[].put(0, 0x11) == lmOk and memory[].put(1, 0x22) == lmOk
  doAssert memory[].pinRange(0, 1, writable = true) == lmOk
  doAssert memory[].put(2, 0x33) == lmWouldBlock
  swap.failWrite = true
  doAssert memory[].servicePendingFault() == lmBackingWriteFailed
  doAssert memory[].pendingFault().pending and cold[0] == 0x22
  swap.failWrite = false
  doAssert memory[].servicePendingFault() == lmOk and swap.lastWrite == 2
  doAssert swap.data[2][0] == 0x22 and swap.data[0][0] == 0 and swap.data[1][0] == 0
  # The only backing slot is already used. Reading the old chunk can still
  # succeed because the new resident frame has not yet been written.
  doAssert memory[].get(1).status == lmWouldBlock
  swap.failRead = true
  doAssert memory[].servicePendingFault() == lmBackingReadFailed
  swap.failRead = false
  doAssert memory[].servicePendingFault() == lmOk and swap.lastRead == 2
  doAssert memory[].get(1) == (lmOk, byte 0x22)
  doAssert memory[].put(2, 0x33, allowIo = true) == lmOk
  doAssert memory[].put(3, 0x44, allowIo = true) == lmCommitLimit
  doAssert memory[].get(1).status == lmWouldBlock
  doAssert memory[].servicePendingFault() == lmBackingFull and cold[0] == 0x33

doAssert owner.reserveEmulatedPsramFrames(sram, psram, Chunk, Chunk, 2, 2)
resetWasmScheduler()
doAssert runPsramFrameTask(owner) and hot[^1] == 0x78 and cold[0 .. 2] == [0x56'u8, 0x34, 0x12]
doAssert runPsramFrameTask(owner)
echo "WASM SRAM/PSRAM frames PASS: pinned promotion, exact swap, bounded reuse and scheduler"
