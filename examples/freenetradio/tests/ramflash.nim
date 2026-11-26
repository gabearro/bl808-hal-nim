## A RAM stand-in for the flash store (`flashdev.FlashDev`) for host tests:
## NOR semantics (erase sets a sector to 0xFF, program can only clear bits),
## operation counts, injected failures and power cuts part-way through an
## operation.

import ../board, ../flashdev

type
  RamFlash* = ref object
    mem*: seq[byte]
    erases*, programs*: int
    sectorErases*: array[StoreSectors, int]
    cutAfter*: int        ## power fails during operation number `cutAfter` (0-based); -1 = never
    cutBytes*: int        ## how many bytes of that operation still happen
    dead*: bool           ## the power is off: nothing works any more
    failErase*, failProgram*, failVerify*: bool
    ops: int

proc newRamFlash*(): RamFlash =
  result = RamFlash(mem: newSeq[byte](StoreSectors * FlashSector), cutAfter: -1)
  for b in result.mem.mitems: b = 0xFF

proc cutNow(f: RamFlash): bool =
  result = f.ops == f.cutAfter
  inc f.ops

proc ramRead(ctx: pointer; offset: uint32; buf: var openArray[byte]) {.nimcall.} =
  let f = cast[RamFlash](ctx)
  for i in 0 ..< buf.len: buf[i] = f.mem[offset.int + i]

proc ramErase(ctx: pointer; offset: uint32): bool {.nimcall.} =
  let f = cast[RamFlash](ctx)
  doAssert offset.int mod FlashSector == 0, "erase must be sector-aligned"
  if f.dead or f.failErase: return false
  var n = FlashSector
  if f.cutNow():
    n = min(f.cutBytes, FlashSector)
    f.dead = true
  for i in 0 ..< n: f.mem[offset.int + i] = 0xFF
  if f.dead: return false
  inc f.erases
  inc f.sectorErases[offset.int div FlashSector]
  true

proc ramProgram(ctx: pointer; offset: uint32; data: openArray[byte]): FlashStatus {.nimcall.} =
  let f = cast[RamFlash](ctx)
  doAssert offset.int mod FlashPage == 0 and data.len <= FlashPage, "program is one page"
  if f.dead or f.failProgram: return fsWriteFailed
  var n = data.len
  if f.cutNow():
    n = min(f.cutBytes, data.len)
    f.dead = true
  for i in 0 ..< n:
    f.mem[offset.int + i] = f.mem[offset.int + i] and data[i]
  if f.dead: return fsWriteFailed
  inc f.programs
  if f.failVerify: return fsVerifyFailed
  for i in 0 ..< data.len:
    if f.mem[offset.int + i] != data[i]: return fsVerifyFailed
  fsOk

proc dev*(f: RamFlash): FlashDev =
  FlashDev(ctx: cast[pointer](f), read: ramRead, eraseSector: ramErase, program: ramProgram)

proc powerOn*(f: RamFlash) =
  ## After a cut: the contents stay as they were left.
  f.dead = false
  f.cutAfter = -1
  f.ops = 0

proc cutAt*(f: RamFlash; op, bytes: int) =
  f.ops = 0
  f.cutAfter = op
  f.cutBytes = bytes

proc opCount*(f: RamFlash): int = f.ops
