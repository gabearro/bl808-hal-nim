## D0 C906 Sv39 MMU support.
##
## RISC-V address translation is active for S/U-mode, not M-mode. The D0 OS
## should enter S-mode through `enterSupervisor` after installing an Sv39 page
## table here; M-mode remains the boot/trap layer.

when not defined(bl808d0):
  {.error: "bl808/mmu is currently supported only on D0 (C906)".}

import core, pmp
import kernel/fault

const
  PageSize* = 4096'u
  PageShift* = 12
  PageMask* = PageSize - 1'u
  Sv39Mode* = 8'u64
  SatpModeShift* = 60

  PteV* = 1'u64 shl 0
  PteR* = 1'u64 shl 1
  PteW* = 1'u64 shl 2
  PteX* = 1'u64 shl 3
  PteU* = 1'u64 shl 4
  PteG* = 1'u64 shl 5
  PteA* = 1'u64 shl 6
  PteD* = 1'u64 shl 7

  PteKernelPage* = PteV or PteR or PteW or PteX or PteA or PteD
  PteMmioPage* = PteV or PteR or PteW or PteA or PteD
  PteInvalid* = 0'u64

  CauseInstructionPageFault* = 12'u
  CauseLoadPageFault* = 13'u
  CauseStorePageFault* = 15'u
  SupervisorPageFaultDelegationMask* =
    (1'u shl CauseInstructionPageFault) or
    (1'u shl CauseLoadPageFault) or
    (1'u shl CauseStorePageFault)

  PagerFaultInstruction* = 1'u32 shl 0
  PagerFaultLoad* = 1'u32 shl 1
  PagerFaultStore* = 1'u32 shl 2

type
  PageTable* = array[512, uint64]

  D0PageFaultKind* = enum
    d0PageFaultInstruction
    d0PageFaultLoad
    d0PageFaultStore
    d0PageFaultOther

  D0PageFault* = object
    kind*: D0PageFaultKind
    cause*: uint
    epc*: uint
    address*: uint

  D0PageFaultHandler* = proc(fault: D0PageFault): bool {.nimcall, raises: [].}

  D0PagerStats* = object
    faults*: uint32
    handled*: uint32
    unhandled*: uint32
    instructionFaults*: uint32
    loadFaults*: uint32
    storeFaults*: uint32
    lastCause*: uint
    lastEpc*: uint
    lastAddress*: uint

var
  d0RootTable {.align: 4096.}: PageTable
  d0AliasL1 {.align: 4096.}: PageTable
  d0AliasL0 {.align: 4096.}: PageTable
  d0PageFaultHandler: D0PageFaultHandler
  d0PagerStats: D0PagerStats

proc supervisorTrapEntry(cause, epc, tval: uint): uint {.exportc: "__d0_supervisor_trap_entry", cdecl, raises: [].}
proc supervisorTrapUnhandled(cause, epc, tval: uint) {.exportc: "__d0_supervisor_trap_unhandled", cdecl, noreturn, raises: [].}

{.emit: """
__attribute__((naked, aligned(4)))
void __d0_supervisor_trap_handler(void) {
  __asm__ volatile(
    "addi sp, sp, -256\n"
    "sd ra, 0(sp)\n"
    "sd t0, 8(sp)\n"
    "sd t1, 16(sp)\n"
    "sd t2, 24(sp)\n"
    "sd a0, 32(sp)\n"
    "sd a1, 40(sp)\n"
    "sd a2, 48(sp)\n"
    "sd a3, 56(sp)\n"
    "sd a4, 64(sp)\n"
    "sd a5, 72(sp)\n"
    "sd a6, 80(sp)\n"
    "sd a7, 88(sp)\n"
    "sd t3, 96(sp)\n"
    "sd t4, 104(sp)\n"
    "sd t5, 112(sp)\n"
    "sd t6, 120(sp)\n"
    "csrr a0, scause\n"
    "csrr a1, sepc\n"
    "csrr a2, stval\n"
    "call __d0_supervisor_trap_entry\n"
    "beqz a0, 1f\n"
    "ld ra, 0(sp)\n"
    "ld t0, 8(sp)\n"
    "ld t1, 16(sp)\n"
    "ld t2, 24(sp)\n"
    "ld a0, 32(sp)\n"
    "ld a1, 40(sp)\n"
    "ld a2, 48(sp)\n"
    "ld a3, 56(sp)\n"
    "ld a4, 64(sp)\n"
    "ld a5, 72(sp)\n"
    "ld a6, 80(sp)\n"
    "ld a7, 88(sp)\n"
    "ld t3, 96(sp)\n"
    "ld t4, 104(sp)\n"
    "ld t5, 112(sp)\n"
    "ld t6, 120(sp)\n"
    "addi sp, sp, 256\n"
    "sret\n"
    "1:\n"
    "csrr a0, scause\n"
    "csrr a1, sepc\n"
    "csrr a2, stval\n"
    "call __d0_supervisor_trap_unhandled\n"
  );
}
extern void __d0_supervisor_trap_handler(void);
static inline unsigned long __d0_supervisor_trap_handler_addr(void) {
  return (unsigned long)&__d0_supervisor_trap_handler;
}
""".}

proc supervisorTrapHandlerAddress(): uint {.importc: "__d0_supervisor_trap_handler_addr", nodecl.}

proc alignDown*(value, alignment: uint): uint {.inline.} =
  value and not (alignment - 1'u)

proc isPageAligned*(value: uint): bool {.inline.} =
  (value and PageMask) == 0

proc vpn2(virtualAddress: uint): int {.inline.} =
  int((virtualAddress shr 30) and 0x1FF'u)

proc vpn1(virtualAddress: uint): int {.inline.} =
  int((virtualAddress shr 21) and 0x1FF'u)

proc vpn0(virtualAddress: uint): int {.inline.} =
  int((virtualAddress shr 12) and 0x1FF'u)

proc ppn(physicalAddress: uint): uint64 {.inline.} =
  uint64(physicalAddress shr PageShift)

proc leafPte(physicalAddress: uint, flags: uint64): uint64 {.inline.} =
  (ppn(physicalAddress) shl 10) or flags or PteV

proc tablePte(tableAddress: uint): uint64 {.inline.} =
  (ppn(tableAddress) shl 10) or PteV

proc clearTable(table: var PageTable) =
  for i in 0 ..< table.len:
    table[i] = 0

proc classifyPageFault(cause: uint): D0PageFaultKind {.inline.} =
  case cause
  of CauseInstructionPageFault: d0PageFaultInstruction
  of CauseLoadPageFault: d0PageFaultLoad
  of CauseStorePageFault: d0PageFaultStore
  else: d0PageFaultOther

proc notePageFault(kind: D0PageFaultKind) =
  inc d0PagerStats.faults
  case kind
  of d0PageFaultInstruction: inc d0PagerStats.instructionFaults
  of d0PageFaultLoad: inc d0PagerStats.loadFaults
  of d0PageFaultStore: inc d0PagerStats.storeFaults
  else: discard

proc supervisorTrapEntry(cause, epc, tval: uint): uint =
  let kind = classifyPageFault(cause)
  d0PagerStats.lastCause = cause
  d0PagerStats.lastEpc = epc
  d0PagerStats.lastAddress = tval
  if kind == d0PageFaultOther:
    inc d0PagerStats.unhandled
    return 0
  notePageFault(kind)
  if d0PageFaultHandler == nil:
    inc d0PagerStats.unhandled
    return 0
  if d0PageFaultHandler(D0PageFault(kind: kind, cause: cause, epc: epc, address: tval)):
    inc d0PagerStats.handled
    sfenceVma()
    return 1
  inc d0PagerStats.unhandled
  0

proc supervisorTrapUnhandled(cause, epc, tval: uint) =
  d0PagerStats.lastCause = cause
  d0PagerStats.lastEpc = epc
  d0PagerStats.lastAddress = tval
  inc d0PagerStats.unhandled
  faultRecord(FaultReasonTrap, cause, epc, tval)
  while true:
    wfi()

proc rootTableAddress*(): uint {.inline.} =
  cast[uint](addr d0RootTable[0])

proc rootTablePpn*(): uint {.inline.} =
  rootTableAddress() shr PageShift

proc satpForRoot*(rootPhysicalAddress: uint = rootTableAddress()): uint =
  uint((Sv39Mode shl SatpModeShift) or uint64(rootPhysicalAddress shr PageShift))

proc map1GiBIdentity(root: var PageTable, base: uint, flags: uint64) =
  root[vpn2(base)] = leafPte(base, flags or PteG)

proc mapPage*(virtualAddress, physicalAddress: uint,
              flags: uint64 = PteKernelPage): bool =
  ## Map one 4 KiB page through the built-in alias tables.
  ##
  ## This is enough for demand-paged/swap-backed aliases and can be extended to
  ## a real allocator once the OS owns page-table memory dynamically.
  if not isPageAligned(virtualAddress) or not isPageAligned(physicalAddress):
    return false
  d0RootTable[vpn2(virtualAddress)] = tablePte(cast[uint](addr d0AliasL1[0]))
  d0AliasL1[vpn1(virtualAddress)] = tablePte(cast[uint](addr d0AliasL0[0]))
  d0AliasL0[vpn0(virtualAddress)] = leafPte(physicalAddress, flags)
  dcacheCleanRange(cast[uint](addr d0RootTable[0]), PageSize)
  dcacheCleanRange(cast[uint](addr d0AliasL1[0]), PageSize)
  dcacheCleanRange(cast[uint](addr d0AliasL0[0]), PageSize)
  sfenceVma()
  true

proc unmapPage*(virtualAddress: uint) =
  if d0RootTable[vpn2(virtualAddress)] == 0:
    return
  d0AliasL0[vpn0(virtualAddress)] = PteInvalid
  dcacheCleanRange(cast[uint](addr d0AliasL0[0]), PageSize)
  sfenceVma()

proc initD0KernelPageTables*() =
  ## Install conservative boot mappings:
  ## - 0x00000000..0x3fffffff: DRAM, MM-domain peripherals, MCU peripherals
  ## - 0x40000000..0x7fffffff: XRAM, PSRAM, flash XIP
  ## - 0xc0000000..0xffffffff: D0 PLIC/CLINT and flash remap window
  clearTable(d0RootTable)
  clearTable(d0AliasL1)
  clearTable(d0AliasL0)
  map1GiBIdentity(d0RootTable, 0x0000_0000'u, PteKernelPage)
  map1GiBIdentity(d0RootTable, 0x4000_0000'u, PteKernelPage)
  map1GiBIdentity(d0RootTable, 0xC000_0000'u, PteMmioPage)
  dcacheCleanRange(cast[uint](addr d0RootTable[0]), PageSize)
  dcacheCleanRange(cast[uint](addr d0AliasL1[0]), PageSize)
  dcacheCleanRange(cast[uint](addr d0AliasL0[0]), PageSize)
  sfenceVma()

proc configureD0SupervisorTraps*() =
  ## Route S-mode page faults to stvec so the OS pager can resolve them.
  csrWriteMedeleg(csrReadMedeleg() or SupervisorPageFaultDelegationMask)
  csrWriteMcounteren(csrReadMcounteren() or 0x7'u)
  csrWriteStvec(supervisorTrapHandlerAddress())

proc setD0PageFaultHandler*(handler: D0PageFaultHandler) =
  d0PageFaultHandler = handler

proc clearD0PageFaultHandler*() =
  d0PageFaultHandler = nil

proc d0PagerStatsSnapshot*(): D0PagerStats =
  result.faults = d0PagerStats.faults
  result.handled = d0PagerStats.handled
  result.unhandled = d0PagerStats.unhandled
  result.instructionFaults = d0PagerStats.instructionFaults
  result.loadFaults = d0PagerStats.loadFaults
  result.storeFaults = d0PagerStats.storeFaults
  result.lastCause = d0PagerStats.lastCause
  result.lastEpc = d0PagerStats.lastEpc
  result.lastAddress = d0PagerStats.lastAddress

proc d0PagerHandledFaults*(): uint32 {.inline.} =
  d0PagerStats.handled

proc d0PagerLoadFaults*(): uint32 {.inline.} =
  d0PagerStats.loadFaults

proc d0PagerStoreFaults*(): uint32 {.inline.} =
  d0PagerStats.storeFaults

proc d0PagerStatsClear*() =
  d0PagerStats.faults = 0
  d0PagerStats.handled = 0
  d0PagerStats.unhandled = 0
  d0PagerStats.instructionFaults = 0
  d0PagerStats.loadFaults = 0
  d0PagerStats.storeFaults = 0
  d0PagerStats.lastCause = 0
  d0PagerStats.lastEpc = 0
  d0PagerStats.lastAddress = 0

proc openD0SupervisorPmp*() =
  ## Permit the D0 S-mode OS to access the BL808 32-bit physical address map.
  ##
  ## Virtual memory translation still controls the OS view. PMP must be opened
  ## first because S-mode fetch/load/store are checked after translation.
  pmpApplyRegion(1, PmpRegion(
    base: 0'u,
    size: 4'u * 1024'u * 1024'u * 1024'u,
    mode: pmpNapot,
    perm: {pmpR, pmpW, pmpX},
    lock: false,
  ))
  sfenceVma()

proc enableD0Sv39*() =
  dcacheCleanRange(cast[uint](addr d0RootTable[0]), PageSize)
  dcacheCleanRange(cast[uint](addr d0AliasL1[0]), PageSize)
  dcacheCleanRange(cast[uint](addr d0AliasL0[0]), PageSize)
  csrWriteSatp(satpForRoot())
  sfenceVma()
  fenceI()

proc disableD0Mmu*() =
  csrWriteSatp(0)
  sfenceVma()
  fenceI()

proc d0MmuEnabled*(): bool =
  (uint64(csrReadSatp()) shr SatpModeShift) == Sv39Mode

proc physicalAddressForTestPage*(p: pointer): uint =
  alignDown(cast[uint](p), PageSize)
