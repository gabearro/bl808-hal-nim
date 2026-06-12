## D0 (C906 RV64) WFI timer-wake sleep.
##
## Three C906-specific facts were needed to make the machine timer wake WFI, all
## verified on hardware and matching the vendor SDK:
##
##  1. VECTORED mtvec. The C906 only delivers the async machine-timer interrupt in
##     vectored mode (mtvec[1:0]=01); the HAL _start installs DIRECT mode, so a
##     pending MTIP is never taken. We override mtvec to a vector table whose every
##     cause-slot lands in the existing __trap_handler (which dispatches by mcause).
##
##  2. MM CPU-RTC clock. systemInit pulses bit 30 of MM_MISC CPU_RTC; the SDK's
##     CPU_Set_MTimer_CLK never touches bit 30 — it clears EN, sets the divider,
##     sets EN. We redo that so the timer counter actually runs at 1 MHz.
##
##  3. The C906 wakes on the rising edge of the timer match. The ISR parks the
##     compare; each loop iteration arms a fresh future deadline before WFI, so a
##     real edge is produced every time. "Now" comes from the `time` CSR; mtimecmp
##     is written high-then-low (the sequence the hardware honoured).
##
## D0 has no harness UART, so the ISR bumps an XRAM counter the supervising M0 reads.
## A Ready handshake lets M0 read the final wake count without racing D0.

import bl808/startup
import bl808/mmio, bl808/memmap, bl808/core, bl808/irq
import bl808/kernel/alloc
import bl808/panicoverride
from std/volatile import volatileLoad

const
  D0Counter  = XramBase + 0x3F18'u
  D0TimeDbg  = XramBase + 0x3F1C'u
  D0Ready    = XramBase + 0x3F44'u
  ReadyMagic = 0xD05E_57E5'u32
  Mtimecmp   = D0ClintMtimecmpBase   # 0xE400_4000
  MmCpuRtc   = MmMiscBase + 0x18'u
  RtcEn      = 1'u32 shl 31
  RtcDivMask = 0x3FF'u32
  Div1MHz    = 479'u32               # 480 MHz / (479+1) = 1 MHz
  Interval   = 50_000'u64            # ~50 ms per wake
  Wakes      = 40                    # bounded run (~2 s), then idle

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
""".}
proc setMtvecVectored() {.importc: "__set_mtvec_vectored", nodecl.}

var count: uint32

proc rdTime(): uint64 = csrReadTime().uint64

proc realDelay(n: uint32) =
  var i = 0'u32
  while i < n:
    fenceIo()
    inc i

proc setMtimecmp(v: uint64) =
  regWrite(Mtimecmp + 4, ((v shr 32) and 0xFFFF_FFFF'u64).uint32)
  regWrite(Mtimecmp, (v and 0xFFFF_FFFF'u64).uint32)

proc configMtimerClock() =
  ## SDK CPU_Set_MTimer_CLK: clear EN, set divider, set EN. No bit-30 pulse.
  regClear(MmCpuRtc, RtcEn)
  regModify(MmCpuRtc, RtcDivMask, Div1MHz)
  regSet(MmCpuRtc, RtcEn)

proc onTimer() {.cdecl.} =
  ## Minimal: count and park the compare. The main loop arms the next deadline and
  ## publishes the counter, keeping the ISR short so it can't straddle a deadline.
  inc count
  setMtimecmp(0xFFFF_FFFF_FFFF_FFFF'u64)             # park; main loop arms the next edge

proc main() {.exportc, cdecl.} =
  systemInit(); heapInit()
  regWrite(D0Counter, 0); regWrite(D0Ready, 0); dcacheFlushAll(); fenceIo()

  setMtvecVectored()                                 # let the C906 take the IRQ
  registerTrapHandler(7, onTimer)
  csrWriteMie(csrReadMie() or (1'u shl 7))            # MTIE
  configMtimerClock()                                # 1 MHz timer counter
  realDelay(1_000_000)                               # let the counter establish

  # Race-free tickless idiom: arm the deadline with interrupts globally disabled,
  # then WFI (RISC-V WFI wakes on any mie-enabled pending interrupt regardless of
  # mstatus.MIE). Re-enabling after the wake lets onTimer run (count++, park). The
  # counter is published here, in the main loop, so the ISR stays short.
  while volatileLoad(addr count) < Wakes.uint32:
    disableInterrupts()
    setMtimecmp(rdTime() + Interval)
    wfi()                                             # sleeps until mtime >= deadline
    enableInterrupts()                                # onTimer takes the pending IRQ
    regWrite(D0Counter, count)
    regWrite(D0TimeDbg, (rdTime() and 0xFFFF_FFFF'u64).uint32)
    dcacheFlushAll(); fenceIo()                        # publish to XRAM for M0

  regWrite(D0Ready, ReadyMagic); dcacheFlushAll(); fenceIo()
  while true:
    wfi()
