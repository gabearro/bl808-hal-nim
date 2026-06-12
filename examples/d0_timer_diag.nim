## D0 (C906) machine-timer diagnostic.
##
## Isolates WHY the D0 timer ISR never fires. Reads only CSRs (time/mie/mip/
## mstatus/mcause) — never the faulting memory mtime — and arms the compare by
## writing the memory-mapped mtimecmp (0xE4004000). Then:
##   * confirms the `time` CSR advances,
##   * busy-polls mip.MTIP to see if the compare asserts a pending timer IRQ,
##   * enables global interrupts and spins to see if the trap is actually TAKEN.
## All findings go to XRAM for the M0 reporter.

import bl808/startup
import bl808/mmio, bl808/memmap, bl808/core, bl808/irq
import bl808/kernel/alloc
import bl808/panicoverride

# Vectored mtvec table (SDK-style): cause C -> base + 4*C. Every slot lands in the
# existing __trap_handler, which dispatches via mcause. The C906 only delivers the
# async machine-timer interrupt in vectored mode (mtvec[1:0]=01).
{.emit: """/*TYPESECTION*/
extern void __trap_handler(void);
__attribute__((naked, aligned(64)))
void __d0_vector_table(void) {
  __asm__ volatile(
    ".option push\n.option norvc\n"
    "j __trap_handler\n" "j __trap_handler\n" "j __trap_handler\n" "j __trap_handler\n"
    "j __trap_handler\n" "j __trap_handler\n" "j __trap_handler\n" "j __trap_handler\n"
    "j __trap_handler\n" "j __trap_handler\n" "j __trap_handler\n" "j __trap_handler\n"
    "j __trap_handler\n" "j __trap_handler\n" "j __trap_handler\n" "j __trap_handler\n"
    "j __trap_handler\n" "j __trap_handler\n"
    ".option pop\n"
  );
}
static inline void __set_mtvec_vectored(void){
  extern void __d0_vector_table(void);
  __asm__ volatile("csrw mtvec, %0" :: "r"(((unsigned long)&__d0_vector_table) | 1UL));
}
static inline unsigned long __rd_mtvec(void){ unsigned long v; __asm__ volatile("csrr %0, mtvec":"=r"(v)); return v; }
static inline unsigned long __rd_mapbaddr(void){ unsigned long v; __asm__ volatile("csrr %0, 0xfc1":"=r"(v)); return v; }
""".}
proc setMtvecVectored() {.importc: "__set_mtvec_vectored", nodecl.}
proc rdMtvec(): uint {.importc: "__rd_mtvec", nodecl.}
proc rdMapbaddr(): uint {.importc: "__rd_mapbaddr", nodecl.}

const
  Phase    = XramBase + 0x3F18'u
  TimeA    = XramBase + 0x3F1C'u
  TimeB    = XramBase + 0x3F20'u
  MieRb    = XramBase + 0x3F24'u
  MtipSeen = XramBase + 0x3F28'u
  PollIter = XramBase + 0x3F2C'u
  MipEnd   = XramBase + 0x3F30'u
  MstatRb  = XramBase + 0x3F34'u
  TrapCnt  = XramBase + 0x3F38'u
  CmpLo    = XramBase + 0x3F3C'u
  SoftCnt  = XramBase + 0x3F40'u
  MapBaddr = XramBase + 0x3F48'u
  Timer2   = XramBase + 0x3F4C'u
  Ready    = XramBase + 0x3F44'u
  ReadyMagic = 0xD1A6_0002'u32
  Mtimecmp = D0ClintMtimecmpBase   # 0xE400_4000
  Msip     = 0xE400_0000'u         # D0 CLINT MSIP0 (machine software interrupt)
  Interval = 50_000'u64

var
  trapHits: uint32
  softHits: uint32
  timer2Hits: uint32
  coret2Base: uint    # CORET base derived from mapbaddr, for the second timer test

proc rdTime(): uint64 = csrReadTime().uint64

proc setMtimecmp(v: uint64) =
  regWrite(Mtimecmp + 4, 0xFFFF_FFFF'u32)
  regWrite(Mtimecmp, (v and 0xFFFF_FFFF'u64).uint32)
  regWrite(Mtimecmp + 4, ((v shr 32) and 0xFFFF_FFFF'u64).uint32)

proc spin(n: uint32) =
  var d = 0'u32
  while d < n: inc d

proc realDelay(n: uint32) =
  var i = 0'u32
  while i < n:
    fenceIo()            # volatile barrier; un-optimizable real time
    inc i

var periodic: uint64
proc onTimer3() {.cdecl.} =
  inc timer2Hits
  periodic += Interval
  regWrite(0xE400_4004'u, ((periodic shr 32) and 0xFFFF_FFFF'u64).uint32)
  regWrite(0xE400_4000'u, (periodic and 0xFFFF_FFFF'u64).uint32)
  regWrite(Timer2, timer2Hits); dcacheFlushAll(); fenceIo()

proc onTimer() {.cdecl.} =
  inc trapHits
  setMtimecmp(rdTime() + 10_000_000'u64)   # push far out so it won't refire in-window
  regWrite(TrapCnt, trapHits); dcacheFlushAll(); fenceIo()

proc onSoft() {.cdecl.} =
  inc softHits
  regWrite(Msip, 0)                         # clear the software-interrupt request
  regWrite(SoftCnt, softHits); dcacheFlushAll(); fenceIo()

proc onTimer2() {.cdecl.} =
  inc timer2Hits
  # Park mtimecmp at the mapbaddr-derived base far out so it won't refire in-window.
  regWrite(coret2Base + 0x4004, 0xFFFF_FFFF'u32)
  regWrite(coret2Base + 0x4000, 0xFFFF_FFFF'u32)
  regWrite(Timer2, timer2Hits); dcacheFlushAll(); fenceIo()

proc setPhase(v: uint32) = (regWrite(Phase, v); dcacheFlushAll(); fenceIo())

proc main() {.exportc, cdecl.} =
  systemInit(); heapInit()
  setPhase(1)

  # 1. Does the `time` CSR advance?
  let ta = rdTime(); spin(200_000); let tb = rdTime()
  regWrite(TimeA, (ta and 0xFFFF_FFFF'u64).uint32)
  regWrite(TimeB, (tb and 0xFFFF_FFFF'u64).uint32)
  setPhase(2)

  # 2. Enable MTIE, arm the compare a short time out.
  csrWriteMie(csrReadMie() or (1'u shl 7))
  regWrite(MieRb, (csrReadMie() and 0xFFFF_FFFF'u).uint32)
  let target = rdTime() + Interval
  setMtimecmp(target)
  regWrite(CmpLo, (target and 0xFFFF_FFFF'u64).uint32)
  setPhase(3)

  # 3. Busy-poll mip.MTIP (bit 7). Does the compare assert a pending timer IRQ?
  var seen = 0'u32
  var iters = 0'u32
  while iters < 5_000_000'u32:
    if (csrReadMip() and (1'u shl 7)) != 0:
      seen = 1; break
    inc iters
  regWrite(MtipSeen, seen)
  regWrite(PollIter, iters)
  regWrite(MipEnd, (csrReadMip() and 0xFFFF_FFFF'u).uint32)
  setPhase(4)

  # 4. Install VECTORED mtvec (the suspected fix), register handler, enable global
  #    interrupts, re-arm near, spin: is the trap TAKEN now?
  setMtvecVectored()
  regWrite(CmpLo, (rdMtvec() and 0xFFFF_FFFF'u).uint32)   # reuse: report mtvec readback
  registerTrapHandler(7, onTimer)
  regWrite(TrapCnt, 0)
  setMtimecmp(rdTime() + Interval)
  enableInterrupts()
  spin(5_000_000)
  regWrite(MstatRb, (csrReadMstatus() and 0xFFFF_FFFF'u).uint32)
  setPhase(5)

  # 5. Software-interrupt control: enable MSIE (bit 3), set MSIP0, spin. If THIS
  #    trap is taken, interrupt delivery works and the timer issue is MTIP-specific.
  registerTrapHandler(3, onSoft)
  regWrite(SoftCnt, 0)
  csrWriteMie(csrReadMie() or (1'u shl 3))   # MSIE
  regWrite(Msip, 1)                          # raise machine software interrupt
  fenceIo()
  spin(3_000_000)
  setPhase(6)

  # 6. The C906 derives its CLINT base from mapbaddr (csr 0xfc1). If the hardcoded
  #    0xE4000000 mtimecmp was the wrong instance, the real one (mapbaddr-derived)
  #    never compared. Write mtimecmp at the mapbaddr base to a tiny value (force an
  #    immediate match) and see if the timer trap is taken now.
  let mb = rdMapbaddr()
  regWrite(MapBaddr, (mb and 0xFFFF_FFFF'u).uint32)
  coret2Base = mb + 0x0400_0000'u            # CORET_BASE = PLIC_BASE + 0x4000000
  registerTrapHandler(7, onTimer2)
  regWrite(Timer2, 0)
  regWrite(coret2Base + 0x4004, 0'u32)       # mtimecmp high = 0
  regWrite(coret2Base + 0x4000, 0x10'u32)    # mtimecmp low = 16 -> already passed
  fenceIo()
  spin(3_000_000)
  setPhase(7)

  # 7. Reconfigure MM CPU-RTC the SDK way (clear EN, set DIV, set EN; NO bit-30
  #    pulse, which systemInit does and which seems to freeze the time counter).
  #    Then check if the `time` CSR advances and a future-deadline timer fires.
  const
    MmCpuRtc = MmMiscBase + 0x18'u
    RtcEn    = 1'u32 shl 31
    RtcDivMask = 0x3FF'u32
    Div1MHz  = 479'u32
  regClear(MmCpuRtc, RtcEn)                   # disable
  regModify(MmCpuRtc, RtcDivMask, Div1MHz)    # set divider
  regSet(MmCpuRtc, RtcEn)                      # enable
  let tc = rdTime(); spin(200_000); let td = rdTime()
  regWrite(XramBase + 0x3F50'u, (tc and 0xFFFF_FFFF'u64).uint32)
  regWrite(XramBase + 0x3F54'u, (td and 0xFFFF_FFFF'u64).uint32)
  # Future-deadline timer test at the canonical base.
  registerTrapHandler(7, onTimer2)
  regWrite(Timer2, 0)
  coret2Base = 0xE000_0000'u + 0x0400_0000'u
  let dl = rdTime() + Interval
  regWrite(coret2Base + 0x4004, ((dl shr 32) and 0xFFFF_FFFF'u64).uint32)
  regWrite(coret2Base + 0x4000, (dl and 0xFFFF_FFFF'u64).uint32)
  regWrite(XramBase + 0x3F58'u, (dl and 0xFFFF_FFFF'u64).uint32)
  fenceIo()
  spin(8_000_000)
  regWrite(XramBase + 0x3F5C'u, timer2Hits)
  setPhase(8)

  # 8. Measure the counter rate over a real (fenceIo) delay, then run a PERIODIC
  #    WFI-style timer and count how many times it fires over a fixed real delay.
  let ra = rdTime()
  realDelay(2_000_000)
  let rb = rdTime()
  regWrite(XramBase + 0x3F60'u, (ra and 0xFFFF_FFFF'u64).uint32)
  regWrite(XramBase + 0x3F64'u, (rb and 0xFFFF_FFFF'u64).uint32)
  registerTrapHandler(7, onTimer3)
  timer2Hits = 0
  regWrite(Timer2, 0)
  periodic = rdTime() + Interval
  regWrite(0xE400_4004'u, ((periodic shr 32) and 0xFFFF_FFFF'u64).uint32)
  regWrite(0xE400_4000'u, (periodic and 0xFFFF_FFFF'u64).uint32)
  fenceIo()
  # Does WFI wake on the timer? Do 5 WFIs; the per-iteration marker (0x3F70)
  # advances only if each WFI actually woke. A WFI hang freezes it mid-count.
  for k in 0'u32 ..< 5'u32:
    regWrite(XramBase + 0x3F70'u, k); dcacheFlushAll(); fenceIo()
    wfi()
  regWrite(XramBase + 0x3F70'u, 0xAA); dcacheFlushAll(); fenceIo()  # all 5 WFIs woke
  regWrite(XramBase + 0x3F68'u, timer2Hits)  # periodic fires (via WFI wakes)
  regWrite(XramBase + 0x3F6C'u, (rdTime() and 0xFFFF_FFFF'u64).uint32)
  setPhase(9)

  regWrite(Ready, ReadyMagic); dcacheFlushAll(); fenceIo()
  while true:
    wfi()
