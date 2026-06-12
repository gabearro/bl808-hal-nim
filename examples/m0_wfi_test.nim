## M0 (E907) WFI timer-wake sleep.
##
## The lightest per-core sleep: the M0 halts in WFI (core clock-gated) and wakes
## on its CLIC machine-timer (IRQ 7). Proven by counting N timer wakes and
## confirming the elapsed mtime matches N intervals — i.e. the core really idled
## for the programmed duration each time rather than spinning.

import bl808/startup, bl808/core, bl808/irq
import bl808/glb, bl808/gpio, bl808/uart
import bl808/kernel/alloc
import bl808/panicoverride
from std/volatile import volatileLoad, volatileStore

const
  ConsoleBaud {.intdefine.} = 230_400'u32
  ConsoleClkHz {.intdefine.} = 40_000_000'u32
  MachineTimerIrq = 7'u32
  TickInterval = 50_000'u64     # mtime ticks between wakes
  Wakes = 10

var
  console: Uart
  wakeCount: uint32

proc getWakes(): uint32 = volatileLoad(addr wakeCount)

proc onTimer() {.cdecl.} =
  volatileStore(addr wakeCount, volatileLoad(addr wakeCount) + 1)
  clicSetMtimecmp(clicReadMtime() + TickInterval)   # rearm (clears MTIP)

proc line(s: string) = discard console.sendLine(s)
proc kv(label: string, v: uint32) =
  discard console.sendString(label); console.sendHex32(v); discard console.sendLine("")
proc check(label: string, ok: bool) =
  discard console.sendString(if ok: "[PASS] " else: "[FAIL] ")
  discard console.sendLine(label)

proc main() {.exportc, cdecl.} =
  systemInit(); heapInit()
  enableAllPeriphClocks(); enablePeriphClock(periphUart0)
  setMcuXclkSource(mcuXclkXtal); setUartClock(true, uartClkXclk, 0)
  gpioSetupUart(14, 15)
  console = initUart(uart0, UartConfig(
    baudRate: ConsoleBaud, dataBits: data8, stopBits: stop1, parity: parityNone), ConsoleClkHz)

  delayUs(400_000)
  line("")
  line("=== BL808 M0 WFI Timer Wake ===")

  registerTrapHandler(MachineTimerIrq, onTimer)
  clicSetMtimecmp(clicReadMtime() + TickInterval)
  clicClearPending(MachineTimerIrq)
  clicSetAttr(MachineTimerIrq, 0)          # SHV=0 -> non-vectored -> mtvec base
  clicSetLevel(MachineTimerIrq, 1)
  clicEnableIrq(MachineTimerIrq)
  {.emit: "__asm__ volatile(\"csrs mie, %0\" :: \"r\"(0x80));".}  # MTIE (bit 7)
  enableInterrupts()

  let t0 = clicReadMtime()
  var spins = 0
  while getWakes() < Wakes.uint32 and spins < 2_000_000:
    wfi()
    inc spins        # if WFI never woke, this would never reach Wakes
  let elapsed = clicReadMtime() - t0

  kv("[M0] wake count = ", getWakes())
  kv("[M0] elapsed mtime = ", (elapsed and 0xFFFFFFFF'u64).uint32)
  check("M0 woke from WFI the expected number of times", getWakes() == Wakes.uint32)
  # Elapsed should be ~Wakes*TickInterval (it actually slept each interval).
  let lo = Wakes.uint64 * TickInterval * 7 div 10
  let hi = Wakes.uint64 * TickInterval * 2
  check("elapsed time matches the programmed sleep duration",
        elapsed >= lo and elapsed <= hi)

  if getWakes() == Wakes.uint32: line("=== Test Complete ===")
  else: line("=== Test Failed ===")
  while true: wfi()
