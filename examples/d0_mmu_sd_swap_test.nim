## D0 Sv39 MMU SD-backed swap smoke test.
##
## D0 validates the MMU pager against real SD-backed swap through an M0-owned
## SD service. This matches the BL808 split: M0 owns FatFS/SDH, D0 owns Sv39
## virtual memory and issues page swap read/write requests over shared XRAM.

import bl808/startup
import bl808/core
import bl808/mmio, bl808/memmap, bl808/mmu
import bl808/vm

const
  StatusAddr = XramBase + 0x3E00'u
  FailCodeAddr = XramBase + 0x3D04'u
  FailGotAddr = XramBase + 0x3D08'u
  FailExpectedAddr = XramBase + 0x3D0C'u
  DiagAddr = XramBase + 0x3D20'u

  SwapBufAddr = XramBase + 0x3000'u
  SwapSeqAddr = XramBase + 0x3200'u
  SwapOpAddr = XramBase + 0x3204'u
  SwapSlotAddr = XramBase + 0x3208'u
  SwapChunkAddr = XramBase + 0x320C'u
  SwapResultAddr = XramBase + 0x3210'u
  SwapRespSeqAddr = XramBase + 0x3214'u

  SwapOpNone = 0'u32
  SwapOpRead = 1'u32
  SwapOpWrite = 2'u32
  SwapResultPending = 0'u32
  SwapResultOk = 1'u32
  SwapResultErr = 2'u32
  SwapChunkBytes = 512'u
  SwapChunksPerPage = 8

  StatusStarted = 1'u32 shl 0
  StatusTables = 1'u32 shl 1
  StatusSatp = 1'u32 shl 2
  StatusSupervisor = 1'u32 shl 3
  StatusSwapProvider = 1'u32 shl 4
  StatusVmReserved = 1'u32 shl 5
  StatusSwapOut = 1'u32 shl 6
  StatusSwapIn = 1'u32 shl 7
  StatusData = 1'u32 shl 8
  StatusFailed = 1'u32 shl 30
  StatusDone = 1'u32 shl 31

  SwapSlots = 4'u32
  VmBase = 0x8000_0000'u
  Page0 = VmBase
  Page1 = VmBase + PageSize
  Page2 = VmBase + PageSize * 2'u
  Value0 = 0xD005_D000'u32
  Value1 = 0xD005_D001'u32
  Value2 = 0xD005_D002'u32

var supervisorStack {.align: 16.}: array[4096, uint8]

proc setStatus(mask: uint32) =
  regSet(StatusAddr, mask)
  dcacheCleanRange(StatusAddr, 16)
  fenceIo()

proc writeDiag(off: uint, value: uint32) =
  regWrite(DiagAddr + off, value)
  dcacheCleanRange(DiagAddr + off, 4)
  fenceIo()

proc failDetail(code, got, expected: uint32) =
  if regRead(FailCodeAddr) == 0:
    regWrite(FailCodeAddr, code)
    regWrite(FailGotAddr, got)
    regWrite(FailExpectedAddr, expected)
    dcacheCleanRange(FailCodeAddr, 64)
    fenceIo()
  setStatus(StatusFailed or StatusDone)
  while true:
    wfi()

proc check(code: uint32, ok: bool) =
  if not ok:
    failDetail(code, 0, 1)

proc checkEq(code, got, expected: uint32) =
  if got != expected:
    failDetail(code, got, expected)

proc copyToSwapBuffer(src: ptr UncheckedArray[byte], chunk: int) =
  let offset = chunk.uint * SwapChunkBytes
  let dst = cast[ptr UncheckedArray[byte]](SwapBufAddr)
  for i in 0 ..< SwapChunkBytes.int:
    dst[i] = src[(offset + i.uint).int]
  dcacheCleanRange(SwapBufAddr, SwapChunkBytes)
  fenceIo()

proc copyFromSwapBuffer(dst: ptr UncheckedArray[byte], chunk: int) =
  dcacheInvalidateRange(SwapBufAddr, SwapChunkBytes)
  let offset = chunk.uint * SwapChunkBytes
  let src = cast[ptr UncheckedArray[byte]](SwapBufAddr)
  for i in 0 ..< SwapChunkBytes.int:
    dst[(offset + i.uint).int] = src[i]
  fenceIo()

proc requestSwapChunk(op, slot: uint32, chunk: int): bool {.raises: [].} =
  let seq = regRead(SwapSeqAddr) + 1'u32
  regWrite(SwapSlotAddr, slot)
  regWrite(SwapChunkAddr, chunk.uint32)
  regWrite(SwapResultAddr, SwapResultPending)
  regWrite(SwapRespSeqAddr, 0)
  regWrite(SwapOpAddr, op)
  regWrite(SwapSeqAddr, seq)
  dcacheCleanRange(SwapSeqAddr, 32)
  fenceIo()

  var countdown = 20_000_000'u32
  while countdown > 0:
    dcacheInvalidateRange(SwapResultAddr, 8)
    if regRead(SwapRespSeqAddr) == seq:
      return regRead(SwapResultAddr) == SwapResultOk
    dec countdown
  false

proc d0IpcSwapRead(ctx: pointer, slot: uint32,
                   dst: ptr UncheckedArray[byte]): bool {.raises: [].} =
  discard ctx
  for chunk in 0 ..< SwapChunksPerPage:
    if not requestSwapChunk(SwapOpRead, slot, chunk):
      return false
    copyFromSwapBuffer(dst, chunk)
  true

proc d0IpcSwapWrite(ctx: pointer, slot: uint32,
                    src: ptr UncheckedArray[byte]): bool {.raises: [].} =
  discard ctx
  for chunk in 0 ..< SwapChunksPerPage:
    copyToSwapBuffer(src, chunk)
    if not requestSwapChunk(SwapOpWrite, slot, chunk):
      return false
  true

proc supervisorMain() {.cdecl, exportc.} =
  setStatus(StatusSupervisor)
  check(0x5D50_0001'u32, d0MmuEnabled())
  setStatus(StatusSatp)

  d0VmInit()
  d0VmSetSwapProvider(D0VmSwapProvider(
    ctx: nil,
    slots: SwapSlots,
    readPage: d0IpcSwapRead,
    writePage: d0IpcSwapWrite,
  ))
  setStatus(StatusSwapProvider)

  let reserveStatus = d0VmReserveAnonymous(VmBase, PageSize * 3'u)
  writeDiag(0, reserveStatus.ord.uint32)
  checkEq(0x5D50_0002'u32, reserveStatus.ord.uint32, d0VmOk.ord.uint32)
  setStatus(StatusVmReserved)

  cast[ptr uint32](Page0)[] = Value0
  core.fence()
  cast[ptr uint32](Page1)[] = Value1
  core.fence()
  cast[ptr uint32](Page2)[] = Value2
  core.fence()

  writeDiag(4, d0VmSwapOuts())
  check(0x5D50_0003'u32, d0VmSwapOuts() >= 1)
  setStatus(StatusSwapOut)

  checkEq(0x5D50_0004'u32, cast[ptr uint32](Page0)[], Value0)
  core.fence()
  writeDiag(8, d0VmSwapIns())
  check(0x5D50_0005'u32, d0VmSwapIns() >= 1)
  setStatus(StatusSwapIn)

  checkEq(0x5D50_0006'u32, cast[ptr uint32](Page1)[], Value1)
  checkEq(0x5D50_0007'u32, cast[ptr uint32](Page2)[], Value2)
  writeDiag(12, d0VmMappedPages())
  writeDiag(16, d0VmEvictions())
  setStatus(StatusData)

  setStatus(StatusDone)
  while true:
    wfi()

proc main() {.exportc, cdecl.} =
  systemInit()

  regWrite(StatusAddr, 0)
  regWrite(FailCodeAddr, 0)
  regWrite(FailGotAddr, 0)
  regWrite(FailExpectedAddr, 0)
  for off in countup(0'u, 84'u, 4'u):
    regWrite(DiagAddr + off, 0)
  regWrite(SwapSeqAddr, 0)
  regWrite(SwapOpAddr, SwapOpNone)
  regWrite(SwapResultAddr, 0)
  regWrite(SwapRespSeqAddr, 0)
  dcacheCleanRange(StatusAddr, 512)
  dcacheCleanRange(SwapBufAddr, 0x300)
  fenceIo()
  setStatus(StatusStarted)

  initD0KernelPageTables()
  configureD0SupervisorTraps()
  openD0SupervisorPmp()
  setStatus(StatusTables)

  enableD0Sv39()
  check(0x5D50_1001'u32, d0MmuEnabled())

  let stackTop = cast[uint](addr supervisorStack[supervisorStack.high]) + 1'u
  enterSupervisor(cast[uint](supervisorMain), stackTop and not 15'u)
