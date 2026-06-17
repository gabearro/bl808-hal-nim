## RISC-V core utilities: CSR access, core detection, barriers, WFI.
##
## Supports all three BL808 cores: D0 (C906), M0 (E907), LP (E902).

import mmio, memmap

# =============================================================================
# CSR access — shared header included by all compilation units
# =============================================================================
{.passC: "-include src/bl808/riscv_csr.h".}

# =============================================================================
# D0-only: S-mode CSR access and T-Head mxstatus
# =============================================================================
when defined(bl808d0):
  {.emit: """/*TYPESECTION*/
  static inline unsigned long __csr_read_sstatus(void) {
    unsigned long v; asm volatile("csrr %0, sstatus" : "=r"(v)); return v;
  }
  static inline void __csr_write_sstatus(unsigned long v) {
    asm volatile("csrw sstatus, %0" :: "r"(v));
  }
  static inline unsigned long __csr_read_stvec(void) {
    unsigned long v; asm volatile("csrr %0, stvec" : "=r"(v)); return v;
  }
  static inline void __csr_write_stvec(unsigned long v) {
    asm volatile("csrw stvec, %0" :: "r"(v));
  }
  static inline unsigned long __csr_read_sie(void) {
    unsigned long v; asm volatile("csrr %0, sie" : "=r"(v)); return v;
  }
  static inline void __csr_write_sie(unsigned long v) {
    asm volatile("csrw sie, %0" :: "r"(v));
  }
  static inline unsigned long __csr_read_sip(void) {
    unsigned long v; asm volatile("csrr %0, sip" : "=r"(v)); return v;
  }
  static inline unsigned long __csr_read_scause(void) {
    unsigned long v; asm volatile("csrr %0, scause" : "=r"(v)); return v;
  }
  static inline unsigned long __csr_read_stval(void) {
    unsigned long v; asm volatile("csrr %0, stval" : "=r"(v)); return v;
  }
  static inline unsigned long __csr_read_sepc(void) {
    unsigned long v; asm volatile("csrr %0, sepc" : "=r"(v)); return v;
  }
  static inline unsigned long __csr_read_satp(void) {
    unsigned long v; asm volatile("csrr %0, satp" : "=r"(v)); return v;
  }
  static inline void __csr_write_satp(unsigned long v) {
    asm volatile("csrw satp, %0" :: "r"(v));
  }
  static inline void __csr_set_sstatus_sie(void) {
    asm volatile("csrsi sstatus, 0x2");
  }
  static inline void __csr_clear_sstatus_sie(void) {
    asm volatile("csrci sstatus, 0x2");
  }
  /* T-Head mxstatus CSR (0x7C0) */
  static inline unsigned long __csr_read_mxstatus(void) {
    unsigned long v; asm volatile("csrr %0, 0x7C0" : "=r"(v)); return v;
  }
  static inline void __csr_write_mxstatus(unsigned long v) {
    asm volatile("csrw 0x7C0, %0" :: "r"(v));
  }
  """.}

  proc csrReadSstatus*(): uint {.importc: "__csr_read_sstatus", nodecl.}
  proc csrWriteSstatus*(v: uint) {.importc: "__csr_write_sstatus", nodecl.}
  proc csrReadStvec*(): uint {.importc: "__csr_read_stvec", nodecl.}
  proc csrWriteStvec*(v: uint) {.importc: "__csr_write_stvec", nodecl.}
  proc csrReadSie*(): uint {.importc: "__csr_read_sie", nodecl.}
  proc csrWriteSie*(v: uint) {.importc: "__csr_write_sie", nodecl.}
  proc csrReadSip*(): uint {.importc: "__csr_read_sip", nodecl.}
  proc csrReadScause*(): uint {.importc: "__csr_read_scause", nodecl.}
  proc csrReadStval*(): uint {.importc: "__csr_read_stval", nodecl.}
  proc csrReadSepc*(): uint {.importc: "__csr_read_sepc", nodecl.}
  proc csrReadSatp*(): uint {.importc: "__csr_read_satp", nodecl.}
  proc csrWriteSatp*(v: uint) {.importc: "__csr_write_satp", nodecl.}
  proc enableSupervisorInterrupts*() {.importc: "__csr_set_sstatus_sie", nodecl.}
    ## Set SIE bit in sstatus — globally enable S-mode interrupts.
  proc disableSupervisorInterrupts*() {.importc: "__csr_clear_sstatus_sie", nodecl.}
    ## Clear SIE bit in sstatus — globally disable S-mode interrupts.
  proc csrReadMxstatus*(): uint {.importc: "__csr_read_mxstatus", nodecl.}
    ## Read T-Head mxstatus CSR (0x7C0) — controls ISA extensions and cache behavior.
  proc csrWriteMxstatus*(v: uint) {.importc: "__csr_write_mxstatus", nodecl.}
    ## Write T-Head mxstatus CSR (0x7C0).

proc csrReadMhartid*(): uint {.importc: "__csr_read_mhartid", nodecl.}
proc csrReadMstatus*(): uint {.importc: "__csr_read_mstatus", nodecl.}
proc csrWriteMstatus*(v: uint) {.importc: "__csr_write_mstatus", nodecl.}
proc csrReadMie*(): uint {.importc: "__csr_read_mie", nodecl.}
proc csrWriteMie*(v: uint) {.importc: "__csr_write_mie", nodecl.}
proc csrReadMtvec*(): uint {.importc: "__csr_read_mtvec", nodecl.}
proc csrWriteMtvec*(v: uint) {.importc: "__csr_write_mtvec", nodecl.}
proc csrReadMepc*(): uint {.importc: "__csr_read_mepc", nodecl.}
proc csrReadMcause*(): uint {.importc: "__csr_read_mcause", nodecl.}
proc csrReadMtval*(): uint {.importc: "__csr_read_mtval", nodecl.}
proc csrReadMscratch*(): uint {.importc: "__csr_read_mscratch", nodecl.}
proc csrWriteMscratch*(v: uint) {.importc: "__csr_write_mscratch", nodecl.}
proc csrReadMip*(): uint {.importc: "__csr_read_mip", nodecl.}
proc csrReadTime*(): uint {.importc: "__csr_read_time", nodecl.}

proc wfi*() {.importc: "__do_wfi", nodecl.}
  ## Wait For Interrupt — halts the core until an interrupt occurs.

proc fence*() {.importc: "__do_fence", nodecl.}
  ## Full memory fence.

proc fenceIo*() {.importc: "__do_fence_io", nodecl.}
  ## I/O memory fence (MMIO ordering).

proc fenceI*() {.importc: "__do_fencei", nodecl.}
  ## Instruction fence — flushes instruction pipeline.

proc ecall*() {.importc: "__do_ecall", nodecl.}
proc ebreak*() {.importc: "__do_ebreak", nodecl.}
proc mret*() {.importc: "__do_mret", nodecl.}

# =============================================================================
# Global interrupt enable/disable
# =============================================================================
proc enableInterrupts*() {.importc: "__csr_set_mstatus_mie", nodecl.}
  ## Set MIE bit in mstatus — globally enable M-mode interrupts.

proc disableInterrupts*() {.importc: "__csr_clear_mstatus_mie", nodecl.}
  ## Clear MIE bit in mstatus — globally disable M-mode interrupts.

proc interruptsEnabled*(): bool {.inline.} =
  (csrReadMstatus() and 0x8) != 0

template withInterruptsDisabled*(body: untyped) =
  ## Execute `body` with interrupts disabled, restoring previous state after.
  let prevMstatus = csrReadMstatus()
  disableInterrupts()
  body
  if (prevMstatus and 0x8) != 0:
    enableInterrupts()

# =============================================================================
# Core identification
# =============================================================================
type
  CoreId* = enum
    coreM0  ## E907, RV32IMAFC, 320 MHz
    coreD0  ## C906, RV64IMAFDC, 480 MHz
    coreLP  ## E902, RV32EMC, 150 MHz
    coreUnknown

proc detectCore*(): CoreId =
  ## Read the core ID register and return which core we're running on.
  let id = regRead(CoreIdAddr)
  case id
  of CoreIdM0: coreM0
  of CoreIdD0: coreD0
  of CoreIdLP: coreLP
  else: coreUnknown

# Compile-time core selection
when defined(bl808m0):
  const currentCore* = coreM0
elif defined(bl808d0):
  const currentCore* = coreD0
elif defined(bl808lp):
  const currentCore* = coreLP
else:
  const currentCore* = coreUnknown

# =============================================================================
# T-Head cache maintenance (C906 / E907 extensions)
# =============================================================================
when defined(bl808d0):
  # Inline functions defined in riscv_csr.h
  proc dcacheFlushAll*() {.importc: "__dcache_flush_all", nodecl.}
  proc dcacheInvalidateAll*() {.importc: "__dcache_invalidate_all", nodecl.}
  proc icacheInvalidateAll*() {.importc: "__icache_invalidate_all", nodecl.}
  proc dcacheLineSize*(): uint {.importc: "__dcache_line_size", nodecl.}
  proc dcacheCleanRange*(address, size: uint) {.importc: "__dcache_clean_range", nodecl.}
  proc dcacheInvalidateRange*(address, size: uint) {.importc: "__dcache_invalidate_range", nodecl.}
  proc dcacheCleanInvalidateRange*(address, size: uint) {.importc: "__dcache_clean_invalidate_range", nodecl.}

when defined(bl808m0):
  # Inline functions defined in riscv_csr.h
  proc dcacheFlushAll*() {.importc: "__dcache_flush_all", nodecl.}
  proc dcacheInvalidateAll*() {.importc: "__dcache_invalidate_all", nodecl.}
  proc icacheInvalidateAll*() {.importc: "__icache_invalidate_all", nodecl.}
  proc dcacheLineSize*(): uint {.importc: "__dcache_line_size", nodecl.}
  proc dcacheCleanRange*(address, size: uint) {.importc: "__dcache_clean_range", nodecl.}
  proc dcacheInvalidateRange*(address, size: uint) {.importc: "__dcache_invalidate_range", nodecl.}
  proc dcacheCleanInvalidateRange*(address, size: uint) {.importc: "__dcache_clean_invalidate_range", nodecl.}

when defined(bl808lp):
  # E902 has no caches — provide no-op stubs for cross-core compatibility
  proc dcacheFlushAll*() {.inline.} = fence()
  proc dcacheInvalidateAll*() {.inline.} = fence()
  proc icacheInvalidateAll*() {.inline.} = fence()
  proc dcacheLineSize*(): uint {.inline.} = 0
  proc dcacheCleanRange*(address, size: uint) {.inline.} = fence()
  proc dcacheInvalidateRange*(address, size: uint) {.inline.} = fence()
  proc dcacheCleanInvalidateRange*(address, size: uint) {.inline.} = fence()

# =============================================================================
# Delay utilities
# =============================================================================
proc delayUs*(us: uint32) =
  ## Rough busy-wait delay. Assumes ~32 MHz clock, ~4 cycles per loop iteration.
  var count = us * 8  # approximate
  while count > 0:
    count.dec
    fence()

proc delayMs*(ms: uint32) =
  ## Millisecond busy-wait delay.
  for i in 0 ..< ms:
    delayUs(1000)
