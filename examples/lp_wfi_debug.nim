## LP (E902) timer-interrupt debug probe — traces its CORET/CLINT/CLIC timer
## state to XRAM so the M0 can report it (the LP's private CLINT at 0xE000_xxxx
## isn't reachable from the M0, so the LP self-dumps). Goal: find why a CORET
## timer expiry never raises a takeable interrupt to wake WFI.

import bl808/startup
import bl808/mmio, bl808/memmap, bl808/core, bl808/irq
import bl808/panicoverride

const
  Ready      = XramBase + 0x3F30'u   # LP writes 0xDEB0BEEF when the dump is ready
  S_mt8a     = XramBase + 0x3F34'u   # mtime @0xE000BFF8 sample A
  S_mt8b     = XramBase + 0x3F38'u   # mtime @0xE000BFF8 sample B
  S_mtCa     = XramBase + 0x3F3C'u   # mtime @0xE000BFFC sample A
  S_mtCb     = XramBase + 0x3F40'u   # mtime @0xE000BFFC sample B
  S_cmpRb    = XramBase + 0x3F44'u   # mtimecmp readback after writing target
  S_target   = XramBase + 0x3F48'u   # the mtimecmp target we set
  S_reached  = XramBase + 0x3F4C'u   # 1 if busy-poll saw mtime >= target
  S_mipAt    = XramBase + 0x3F50'u   # mip CSR when mtime crossed target
  S_clic7    = XramBase + 0x3F54'u   # CLIC IRQ-7 word (0xE080101C) at cross
  S_mieVal   = XramBase + 0x3F58'u   # mie CSR
  ReadyMagic = 0xDEB0_BEEF'u32
  Clic7Word  = 0xE080_101C'u         # CLIC per-IRQ reg for IRQ 7
  CoretMt8   = 0xE000_BFF8'u
  CoretMtC   = 0xE000_BFFC'u
  Cmp        = 0xE000_4000'u
  Interval   = 8_000'u32
  MintThresh = 0xE080_0008'u

{.emit: """/*TYPESECTION*/
static inline unsigned long __rd_mip(void){ unsigned long v; __asm__ volatile("csrr %0, mip":"=r"(v)); return v; }
static inline unsigned long __rd_mie(void){ unsigned long v; __asm__ volatile("csrr %0, mie":"=r"(v)); return v; }
static inline unsigned long __rd_mcause(void){ unsigned long v; __asm__ volatile("csrr %0, mcause":"=r"(v)); return v; }
static inline unsigned long __rd_mstatus(void){ unsigned long v; __asm__ volatile("csrr %0, mstatus":"=r"(v)); return v; }
static inline unsigned long __rd_mtvec(void){ unsigned long v; __asm__ volatile("csrr %0, mtvec":"=r"(v)); return v; }
static inline unsigned long __rd_mintstatus(void){ unsigned long v; __asm__ volatile("csrr %0, 0xfb1":"=r"(v)); return v; }
static inline void __set_mtie(void){ __asm__ volatile("csrs mie, %0"::"r"(0x80)); }
""".}
proc rdMintstatus(): uint32 {.importc: "__rd_mintstatus", nodecl.}
proc rdMip(): uint32 {.importc: "__rd_mip", nodecl.}
proc rdMie(): uint32 {.importc: "__rd_mie", nodecl.}
proc rdMcause(): uint32 {.importc: "__rd_mcause", nodecl.}
proc rdMstatus(): uint32 {.importc: "__rd_mstatus", nodecl.}
proc rdMtvec(): uint32 {.importc: "__rd_mtvec", nodecl.}
proc setMtie() {.importc: "__set_mtie", nodecl.}

var trapHits: uint32
var lastCause: uint32
proc onTrap() {.cdecl.} =
  inc trapHits
  lastCause = rdMcause()
  clicSetMtimecmp(clicReadMtime() + 600'u64)         # tiny re-arm to test refire
  clicClearPending(7'u32)

proc spin(n: uint32) =
  var d = 0'u32
  while d < n: inc d

proc main() {.exportc, cdecl.} =
  # 1. Which address is the free-running timer?
  let mt8a = regRead(CoretMt8); spin(50_000)
  let mt8b = regRead(CoretMt8)
  let mtCa = regRead(CoretMtC); spin(50_000)
  let mtCb = regRead(CoretMtC)

  # 2. Set up the CLIC IRQ-7 timer + MTIE.
  setMtie()
  clicSetAttr(7'u32, 0)
  clicSetLevel(7'u32, 1)
  clicEnableIrq(7'u32)

  # 3. Arm mtimecmp = mtime + Interval and read it back.
  let now = regRead(CoretMt8)
  let target = now + Interval
  regWrite(Cmp + 4, 0xFFFF_FFFF'u32)
  regWrite(Cmp, target)
  regWrite(Cmp + 4, 0'u32)
  let cmpRb = regRead(Cmp)

  # 4. Busy-poll until the timer crosses target; capture mip + CLIC pending there.
  var reached = 0'u32
  var mipAt = 0'u32
  var iters = 0'u32
  while iters < 3_000_000'u32:
    if regRead(CoretMt8) >= target:
      reached = 1
      mipAt = rdMip()
      break
    inc iters

  let clic7 = regRead(Clic7Word)
  let mieVal = rdMie()

  # TRAP-TAKE TEST: register a handler, enable global interrupts, re-arm a near
  # deadline, busy-wait (NO wfi) and see if the CLIC timer interrupt is TAKEN.
  registerTrapHandler(7'u32, onTrap)
  # Apply the nlbits fix + force a pending IRQ-7 (don't even rely on the timer).
  regWrite(0xE080_0000'u, (regRead(0xE080_0000'u) and not 0x1E'u32) or (4'u32 shl 1))
  let cfgAfter = regRead(0xE080_0000'u)
  regWrite(MintThresh, 0)
  clicSetLevel(7'u32, 255)
  clicEnableIrq(7'u32)
  enableInterrupts()
  clicSetPending(7'u32)
  spin(12_000_000)
  let directCause = rdMcause()       # did ANY trap fire? (CSR holds last cause)
  regWrite(XramBase + 0x3F7C'u, cfgAfter)
  regWrite(XramBase + 0x3F80'u, (clicReadMtime() and 0xFFFF_FFFF'u64).uint32)  # mtime AFTER spin
  regWrite(XramBase + 0x3F5C'u, trapHits)
  regWrite(XramBase + 0x3F60'u, lastCause)
  regWrite(XramBase + 0x3F64'u, rdMstatus())
  regWrite(XramBase + 0x3F68'u, rdMtvec())
  regWrite(XramBase + 0x3F6C'u, directCause)
  regWrite(XramBase + 0x3F70'u, regRead(0xE080_0000'u))   # cliccfg
  regWrite(XramBase + 0x3F74'u, regRead(MintThresh))      # mintthresh
  regWrite(XramBase + 0x3F78'u, regRead(Clic7Word))       # CLIC irq7 at end

  regWrite(S_mt8a, mt8a); regWrite(S_mt8b, mt8b)
  regWrite(S_mtCa, mtCa); regWrite(S_mtCb, mtCb)
  regWrite(S_cmpRb, cmpRb); regWrite(S_target, target)
  regWrite(S_reached, reached); regWrite(S_mipAt, mipAt)
  regWrite(S_clic7, clic7); regWrite(S_mieVal, mieVal)
  fenceIo()
  regWrite(Ready, ReadyMagic)

  # FINAL: does the E902 WFI actually WAKE on the CLIC timer? onTrap re-arms far
  # out, so a wake leaves us here to stamp 0xBBBB; a hang leaves 0xAAAA.
  regWrite(XramBase + 0x3F84'u, 0xAAAA_0000'u32)
  clicClearPending(7'u32)
  clicSetMtimecmp(clicReadMtime() + 4000'u64)
  wfi()
  regWrite(XramBase + 0x3F84'u, 0xBBBB_0001'u32)
  while true: discard
