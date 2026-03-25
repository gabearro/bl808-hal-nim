## RISC-V core utilities: CSR access, core detection, barriers, WFI.
##
## Supports all three BL808 cores: D0 (C906), M0 (E907), LP (E902).

import mmio, memmap

# =============================================================================
# CSR access (inline assembly via C emit)
# =============================================================================
{.emit: """
static inline unsigned long __csr_read_mhartid(void) {
  unsigned long v; asm volatile("csrr %0, mhartid" : "=r"(v)); return v;
}
static inline unsigned long __csr_read_mstatus(void) {
  unsigned long v; asm volatile("csrr %0, mstatus" : "=r"(v)); return v;
}
static inline void __csr_write_mstatus(unsigned long v) {
  asm volatile("csrw mstatus, %0" :: "r"(v));
}
static inline unsigned long __csr_read_mie(void) {
  unsigned long v; asm volatile("csrr %0, mie" : "=r"(v)); return v;
}
static inline void __csr_write_mie(unsigned long v) {
  asm volatile("csrw mie, %0" :: "r"(v));
}
static inline unsigned long __csr_read_mtvec(void) {
  unsigned long v; asm volatile("csrr %0, mtvec" : "=r"(v)); return v;
}
static inline void __csr_write_mtvec(unsigned long v) {
  asm volatile("csrw mtvec, %0" :: "r"(v));
}
static inline unsigned long __csr_read_mepc(void) {
  unsigned long v; asm volatile("csrr %0, mepc" : "=r"(v)); return v;
}
static inline unsigned long __csr_read_mcause(void) {
  unsigned long v; asm volatile("csrr %0, mcause" : "=r"(v)); return v;
}
static inline unsigned long __csr_read_mtval(void) {
  unsigned long v; asm volatile("csrr %0, mtval" : "=r"(v)); return v;
}
static inline unsigned long __csr_read_mscratch(void) {
  unsigned long v; asm volatile("csrr %0, mscratch" : "=r"(v)); return v;
}
static inline void __csr_write_mscratch(unsigned long v) {
  asm volatile("csrw mscratch, %0" :: "r"(v));
}
static inline unsigned long __csr_read_mip(void) {
  unsigned long v; asm volatile("csrr %0, mip" : "=r"(v)); return v;
}
static inline void __do_wfi(void) {
  asm volatile("wfi");
}
static inline void __do_fence(void) {
  asm volatile("fence" ::: "memory");
}
static inline void __do_fence_io(void) {
  asm volatile("fence iorw, iorw" ::: "memory");
}
static inline void __do_fencei(void) {
  asm volatile("fence.i" ::: "memory");
}
static inline void __do_ecall(void) {
  asm volatile("ecall");
}
static inline void __do_ebreak(void) {
  asm volatile("ebreak");
}
static inline void __do_mret(void) {
  asm volatile("mret");
}
static inline void __csr_set_mstatus_mie(void) {
  asm volatile("csrsi mstatus, 0x8");
}
static inline void __csr_clear_mstatus_mie(void) {
  asm volatile("csrci mstatus, 0x8");
}
""".}

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
  {.emit: """
  static inline void __dcache_flush_all(void) {
    asm volatile(".long 0x0010000b" ::: "memory"); /* dcache.call */
  }
  static inline void __dcache_invalidate_all(void) {
    asm volatile(".long 0x0020000b" ::: "memory"); /* dcache.ciall */
  }
  static inline void __icache_invalidate_all(void) {
    asm volatile(".long 0x0100000b" ::: "memory"); /* icache.iall */
  }
  """.}
  proc dcacheFlushAll*() {.importc: "__dcache_flush_all", nodecl.}
  proc dcacheInvalidateAll*() {.importc: "__dcache_invalidate_all", nodecl.}
  proc icacheInvalidateAll*() {.importc: "__icache_invalidate_all", nodecl.}

when defined(bl808m0):
  {.emit: """
  static inline void __dcache_flush_all(void) {
    asm volatile(".long 0x0010000b" ::: "memory"); /* dcache.call */
  }
  static inline void __dcache_invalidate_all(void) {
    asm volatile(".long 0x0020000b" ::: "memory"); /* dcache.ciall */
  }
  static inline void __icache_invalidate_all(void) {
    asm volatile(".long 0x0100000b" ::: "memory"); /* icache.iall */
  }
  """.}
  proc dcacheFlushAll*() {.importc: "__dcache_flush_all", nodecl.}
  proc dcacheInvalidateAll*() {.importc: "__dcache_invalidate_all", nodecl.}
  proc icacheInvalidateAll*() {.importc: "__icache_invalidate_all", nodecl.}

when defined(bl808lp):
  # E902 has no caches — provide no-op stubs for cross-core compatibility
  proc dcacheFlushAll*() {.inline.} = fence()
  proc dcacheInvalidateAll*() {.inline.} = fence()
  proc icacheInvalidateAll*() {.inline.} = fence()

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
