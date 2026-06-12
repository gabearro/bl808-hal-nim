## U-mode preemption test (M0, T3.8).
##
## A malicious/buggy U-mode app can refuse to yield (no ecall, infinite loop).
## The enclave must still be able to regain control. This drops into such a
## runaway U-mode app with the machine timer armed; the timer interrupt traps
## into the enclave entry (not the U-mode loop), the enclave ISR runs in M-mode,
## counts ticks, and after N preemptions reports PASS — proving the untrusted
## app cannot lock the core.
##
## Mechanism: the M0 machine timer is a CLIC interrupt (id 7). We mark it
## non-vectored (SHV=0) so it traps to the mtvec BASE — the enclave entry —
## rather than hardware-vectoring through mtvt to the kernel handler. The entry
## sees mcause bit 31 (interrupt) and runs the enclave ISR on the M-mode stack.
##
## The U-mode app bumps a heartbeat counter in its RW page each iteration; the
## ISR checks it advanced, proving the app really was running between ticks.

import bl808/startup, bl808/core
import bl808/mmio, bl808/memmap, bl808/irq
import bl808/glb, bl808/gpio, bl808/uart
import bl808/umode
import bl808/enclave/enclave, bl808/enclave/partition, bl808/enclave/vault
import bl808/panicoverride
import bl808/kernel/alloc
import std/volatile

const
  ConsoleBaud {.intdefine.} = 230_400'u32
  ConsoleClkHz {.intdefine.} = 40_000_000'u32
  MachineTimerIrq = 7'u32       # CLIC machine-timer interrupt id
  TickInterval = 200_000'u64    # mtime ticks between preemptions
  TargetTicks = 5
  # Heartbeat counter, in the U-mode RW page (uram base). M-mode reads it too.
  Heartbeat = 0x6202E000'u

var
  console: Uart
  tickCount = 0

proc line(s: string) = discard console.sendLine(s)
proc check(label: string, ok: bool) =
  discard console.sendString(if ok: "[PASS] " else: "[FAIL] ")
  discard console.sendLine(label)

# M handler stack the entry swaps onto (top of secure RAM, same as enclaveRunUmode).
{.emit: """/*TYPESECTION*/
extern char _sp[];
static unsigned long __irq_main_sp(void){return (unsigned long)_sp;}
""".}
proc mainSp(): uint {.importc: "__irq_main_sp", nodecl.}

proc armTimer() =
  ## Mark the machine-timer CLIC IRQ non-vectored so it reaches the enclave
  ## entry, then enable it (CLIC bit + mie.MTIE) and program the first deadline.
  clicSetMtimecmp(clicReadMtime() + TickInterval)
  clicClearPending(MachineTimerIrq)
  clicSetAttr(MachineTimerIrq, 0)          # SHV=0 -> non-vectored -> mtvec base
  clicSetLevel(MachineTimerIrq, 1)
  clicEnableIrq(MachineTimerIrq)
  {.emit: "__asm__ volatile(\"csrs mie, %0\" :: \"r\"(0x80));".}  # MTIE (bit 7)

proc onTimer(cause: uint32) {.nimcall.} =
  ## Runs in M-mode on each timer interrupt while U-mode loops.
  inc tickCount
  clicSetMtimecmp(clicReadMtime() + TickInterval)   # rearm (also clears MTIP)
  if tickCount == 1:
    line("[M0] first timer interrupt taken from U-mode (preemption works)")
  if tickCount >= TargetTicks:
    let hb = regRead(Heartbeat)
    check("timer preempted runaway U-mode app", tickCount >= TargetTicks)
    check("U-mode app was actually running (heartbeat advanced)", hb > 0)
    {.emit: "__asm__ volatile(\"csrc mstatus, %0\" :: \"r\"(0x8));".}  # mask MIE
    line("=== Test Complete ===")
    while true: wfi()

proc umodeApp() {.exportc: "umode_app", cdecl.} =
  ## Runaway untrusted app: bumps its heartbeat without ever yielding. The timer
  ## must preempt it (onTimer halts the device at TargetTicks long before this
  ## bound). The bound is a safety net: if preemption ever fails, the app
  ## eventually touches secure RAM -> PMP fault -> enclave halts cleanly, so a
  ## failed run can still be recovered (never an unbreakable flash-XIP spin).
  let hb = cast[ptr uint32](Heartbeat)
  var i: uint32 = 0
  while i < 300_000_000'u32:                     # volatile: a real spin, not optimised away
    volatileStore(hb, volatileLoad(hb) + 1)
    inc i
  let secure = cast[ptr uint32](0x62020000'u)   # PMP-denied to U-mode -> faults
  discard volatileLoad(secure)

proc umodeAppAddr(): uint =
  {.emit: "`result` = (NU)(&umode_app);".}

proc main() {.exportc, cdecl.} =
  systemInit()
  heapInit()
  enableAllPeriphClocks()
  enablePeriphClock(periphUart0)
  setMcuXclkSource(mcuXclkXtal)
  setUartClock(true, uartClkXclk, 0)
  gpioSetupUart(14, 15)
  console = initUart(uart0, UartConfig(
    baudRate: ConsoleBaud, dataBits: data8, stopBits: stop1, parity: parityNone), ConsoleClkHz)

  line("")
  line("=== BL808 U-mode Preemption Test ===")

  let ok = enclaveInit(defaultPartition(lock = false), rkSoftDev)
  check("enclaveInit", ok)
  regWrite(Heartbeat, 0)                            # clear heartbeat (M-mode, full access)
  enclaveSetIrqHook(onTimer)
  armTimer()
  line("[M0] entering runaway U-mode app (infinite loop, no ecall)...")

  # CLIC-mode mtvec base is the enclave entry; the non-vectored timer IRQ lands
  # there. Enter U-mode with interrupts enabled.
  enclaveInstallTrapVector(mainSp())
  enclaveEnterUmodeIrq(umodeAppAddr(), umodeStackTop())
