## LP (E902) true WFI low-power sleep on its CLIC machine-timer (IRQ 7).
##
## Debug (m0_lp_wfi_debug) established: the CORET timer counts and the CLIC IRQ-7
## pending bit asserts when mtime crosses mtimecmp, but the E902 ignores mie.MTIE
## (mie reads 0) and its WFI only wakes when the interrupt is actually TAKEN. So:
##   * enable IRQ-7 in the CLIC, drop mintthresh, give it max level,
##   * non-vectored (SHV=0) so the trap goes to mtvec base, NOT the absent mtvt,
##   * global interrupts ON so the timer trap is taken and wakes WFI,
##   * the ISR re-arms mtimecmp + clears pending, then the core WFI-sleeps again.

import bl808/startup
import bl808/mmio, bl808/memmap, bl808/core, bl808/irq
import bl808/panicoverride
from std/volatile import volatileLoad, volatileStore

const
  LpSleepCounter  = XramBase + 0x3F10'u
  LpMtimeDebug    = XramBase + 0x3F14'u
  MachineTimerIrq = 7'u32
  IntervalTicks   = 5_000'u64  # ~45 ms at the ~112 kHz CORET -> ~33 wakes in 1.5 s
  MintThresh      = 0xE080_0008'u

{.emit: """/*TYPESECTION*/
extern void (*const __trap_vector_table[128])(void);
static inline void __set_mtie(void){ __asm__ volatile("csrs mie, %0"::"r"(0x80)); }
static inline void __set_mtvt(void){ __asm__ volatile("csrw 0x307, %0"::"r"(&__trap_vector_table[0])); }
""".}
proc setMtie() {.importc: "__set_mtie", nodecl.}
proc setMtvt() {.importc: "__set_mtvt", nodecl.}

var lpCount: uint32

proc onTimer() {.cdecl.} =
  let c = volatileLoad(addr lpCount) + 1
  volatileStore(addr lpCount, c)
  regWrite(LpSleepCounter, c)
  regWrite(LpMtimeDebug, (clicReadMtime() and 0xFFFF_FFFF'u64).uint32)
  # Move the deadline into the future FIRST (drops the timer line), THEN clear the
  # pending bit — otherwise the still-high line re-latches and the next wake stalls.
  clicSetMtimecmp(clicReadMtime() + IntervalTicks)
  clicClearPending(MachineTimerIrq)

proc main() {.exportc, cdecl.} =
  # Exact sequence the LP-observer proved works (mtvec is already CLIC mode from
  # _start; do NOT call clicInit — its auto-probe leaves cliccfg nlbits=0).
  regWrite(LpSleepCounter, 0)
  setMtie()
  setMtvt()                                 # CLIC vector table base (for SHV=1)
  clicSetAttr(MachineTimerIrq, 1)           # SHV=1: VECTORED -> __clic_interrupt_handler
                                            # (restores MIL on mret; SHV=0/__trap_handler
                                            # doesn't, so only the 1st wake worked)
  registerTrapHandler(MachineTimerIrq, onTimer)
  # THE FIX: force cliccfg nlbits>0 (bits [4:1]). nlbits=0 masks EVERY CLIC
  # interrupt at level 0 (level must be > mintthresh=0) — this was the whole bug.
  regWrite(ClicCtrlBase, (regRead(ClicCtrlBase) and not 0x1E'u32) or (4'u32 shl 1))
  regWrite(MintThresh, 0)
  clicSetLevel(MachineTimerIrq, 255)
  clicEnableIrq(MachineTimerIrq)
  enableInterrupts()

  clicClearPending(MachineTimerIrq)
  clicSetMtimecmp(clicReadMtime() + IntervalTicks)
  while true:
    wfi()                                    # low-power sleep; the timer ISR wakes us
