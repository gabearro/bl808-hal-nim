## D0 Sv39 MMU smoke test.
##
## The M0 helper powers D0 and reports the XRAM status bits over UART. This D0
## image installs identity mappings, maps a non-identity 4 KiB virtual page,
## enables satp, enters S-mode, then validates translated memory and MMIO.

import bl808/startup
import bl808/core
import bl808/mmio, bl808/memmap, bl808/mmu
import bl808/vm

const
  StatusAddr = XramBase + 0x3E00'u
  FailCodeAddr = XramBase + 0x3D04'u
  FailGotAddr = XramBase + 0x3D08'u
  FailExpectedAddr = XramBase + 0x3D0C'u

  StatusStarted = 1'u32 shl 0
  StatusTables = 1'u32 shl 1
  StatusSatp = 1'u32 shl 2
  StatusSupervisor = 1'u32 shl 3
  StatusIdentity = 1'u32 shl 4
  StatusAlias = 1'u32 shl 5
  StatusMmio = 1'u32 shl 6
  StatusPager = 1'u32 shl 7
  StatusVmReader = 1'u32 shl 8
  StatusFailed = 1'u32 shl 30
  StatusDone = 1'u32 shl 31

  AliasVa = 0x8000_0000'u
  FaultVa = 0x8000_1000'u
  ReaderVa = 0x8000_2000'u
  AliasValue = 0xC906_5039'u32
  FaultValue = 0xC906_5040'u32
  ReaderValue = 0xC906_5041'u32
  IdentityValue = 0xD050_0001'u32

var
  pageBacking {.align: 4096.}: array[4096, uint8]
  faultBacking {.align: 4096.}: array[4096, uint8]
  readerSource {.align: 4.}: array[16, uint8]
  supervisorStack {.align: 16.}: array[4096, uint8]

proc setStatus(mask: uint32) =
  regSet(StatusAddr, mask)
  dcacheCleanRange(StatusAddr, 16)
  fenceIo()

proc failDetail(code, got, expected: uint32) =
  if regRead(FailCodeAddr) == 0:
    regWrite(FailCodeAddr, code)
    regWrite(FailGotAddr, got)
    regWrite(FailExpectedAddr, expected)
    dcacheCleanRange(FailCodeAddr, 12)
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

proc pager(fault: D0PageFault): bool {.raises: [].} =
  if alignDown(fault.address, PageSize) == FaultVa and
      (fault.kind == d0PageFaultLoad or fault.kind == d0PageFaultStore):
    return mapPage(FaultVa, physicalAddressForTestPage(addr faultBacking[0]),
                   PteKernelPage)
  false

proc reader(ctx: pointer, offset: uint64, dst: ptr UncheckedArray[byte],
            len: uint): bool {.raises: [].} =
  discard ctx
  if offset != 0'u64:
    return false
  for i in 0 ..< len.int:
    if i < readerSource.len:
      dst[i] = readerSource[i]
    else:
      dst[i] = 0
  true

proc supervisorMain() {.cdecl, exportc.} =
  setStatus(StatusSupervisor)

  check(0x5030_0001'u32, d0MmuEnabled())
  setStatus(StatusSatp)

  regWrite(StatusAddr + 0x20'u, IdentityValue)
  checkEq(0x5030_0002'u32, regRead(StatusAddr + 0x20'u), IdentityValue)
  setStatus(StatusIdentity)

  cast[ptr uint32](AliasVa)[] = AliasValue
  core.fence()
  checkEq(0x5030_0003'u32, cast[ptr uint32](addr pageBacking[0])[], AliasValue)
  cast[ptr uint32](addr pageBacking[4])[] = AliasValue xor 0xFFFF_0000'u32
  core.fence()
  checkEq(0x5030_0004'u32, cast[ptr uint32](AliasVa + 4'u)[],
          AliasValue xor 0xFFFF_0000'u32)
  setStatus(StatusAlias)

  setD0PageFaultHandler(pager)
  d0PagerStatsClear()
  cast[ptr uint32](FaultVa)[] = FaultValue
  core.fence()
  checkEq(0x5030_0007'u32, cast[ptr uint32](addr faultBacking[0])[], FaultValue)
  checkEq(0x5030_0008'u32, cast[ptr uint32](FaultVa)[], FaultValue)
  checkEq(0x5030_0009'u32, d0PagerHandledFaults(), 1)
  checkEq(0x5030_000A'u32, d0PagerStoreFaults(), 1)
  setStatus(StatusPager)

  readerSource[0] = (ReaderValue and 0xFF'u32).byte
  readerSource[1] = ((ReaderValue shr 8) and 0xFF'u32).byte
  readerSource[2] = ((ReaderValue shr 16) and 0xFF'u32).byte
  readerSource[3] = ((ReaderValue shr 24) and 0xFF'u32).byte
  d0VmInit()
  checkEq(0x5030_000B'u32,
          d0VmReserveReaderBacked(ReaderVa, PageSize, reader).ord.uint32,
          d0VmOk.ord.uint32)
  checkEq(0x5030_000C'u32, cast[ptr uint32](ReaderVa)[], ReaderValue)
  checkEq(0x5030_000D'u32, d0VmReaderPages(), 1)
  checkEq(0x5030_000E'u32, d0VmMappedPages(), 1)
  checkEq(0x5030_000F'u32, d0VmFailedFaults(), 0)
  setStatus(StatusVmReader)

  let coreId = regRead(CoreIdAddr)
  checkEq(0x5030_0005'u32, coreId, CoreIdD0)
  regWrite(StatusAddr + 0x24'u, coreId)
  checkEq(0x5030_0006'u32, regRead(StatusAddr + 0x24'u), CoreIdD0)
  setStatus(StatusMmio)

  setStatus(StatusDone)
  while true:
    wfi()

proc main() {.exportc, cdecl.} =
  systemInit()

  regWrite(StatusAddr, 0)
  regWrite(FailCodeAddr, 0)
  regWrite(FailGotAddr, 0)
  regWrite(FailExpectedAddr, 0)
  dcacheCleanRange(StatusAddr, 64)
  fenceIo()
  setStatus(StatusStarted)

  initD0KernelPageTables()
  configureD0SupervisorTraps()
  openD0SupervisorPmp()
  check(0x5030_1001'u32, mapPage(AliasVa, physicalAddressForTestPage(addr pageBacking[0]),
                                 PteKernelPage))
  setStatus(StatusTables)

  enableD0Sv39()
  check(0x5030_1002'u32, d0MmuEnabled())

  let stackTop = cast[uint](addr supervisorStack[supervisorStack.high]) + 1'u
  enterSupervisor(cast[uint](supervisorMain), stackTop and not 15'u)
