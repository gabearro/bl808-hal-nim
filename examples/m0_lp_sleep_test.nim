## LP timed sleep/wake validation (low-power core).
##
## M0 releases the E902 (Low Power core) running lp_sleep_probe, which sleeps on
## its own CORET/mtimer (WFI) and bumps an XRAM counter every 100 ms. M0 stays
## alive and polls the counter: if it advances at ~the expected rate, the LP is
## doing genuine timed sleep/wake on the low-power domain's timer. M0 supervising
## means a misbehaving LP just fails the assertion — no hang, no brick.

import bl808/startup
import bl808/core, bl808/mmio, bl808/memmap
import bl808/glb, bl808/gpio, bl808/uart
import bl808/panicoverride
import bl808/kernel/alloc

const
  ConsoleBaud {.intdefine.} = 230_400'u32
  ConsoleClkHz {.intdefine.} = 40_000_000'u32
  LpSleepCounter = XramBase + 0x3F10'u
  LpMtimeDebug   = XramBase + 0x3F14'u
  IntervalMs     = 100          # LP sleep interval
  SampleMs       = 1500         # observation window
  ExpectedTicks  = SampleMs div IntervalMs   # ~15

var
  console: Uart
  passed = 0
  failed = 0

proc line(s: string) = discard console.sendLine(s)
proc kv(label: string, v: uint32) =
  discard console.sendString(label); console.sendHex32(v); discard console.sendLine("")
proc check(label: string, ok: bool) =
  discard console.sendString(if ok: "[PASS] " else: "[FAIL] ")
  discard console.sendLine(label)
  if ok: inc passed else: inc failed

proc shRead(a: uint): uint32 =
  dcacheFlushAll(); dcacheInvalidateAll(); fenceIo(); regRead(a)
proc shWrite(a: uint, v: uint32) =
  regWrite(a, v); dcacheFlushAll(); fenceIo()

proc main() {.exportc, cdecl.} =
  systemInit(); heapInit()
  enableAllPeriphClocks(); enablePeriphClock(periphUart0)
  setMcuXclkSource(mcuXclkXtal); setUartClock(true, uartClkXclk, 0)
  gpioSetupUart(14, 15)
  console = initUart(uart0, UartConfig(
    baudRate: ConsoleBaud, dataBits: data8, stopBits: stop1, parity: parityNone), ConsoleClkHz)

  delayUs(400_000)
  line("")
  line("=== BL808 LP Timed Operation ===")

  shWrite(LpSleepCounter, 0xFFFFFFFF'u32)   # sentinel: LP overwrites with 0,1,2,...
  mmPowerOn()
  line("[M0] Releasing LP (E902) sleep firmware")
  releaseLP()

  # Wait for the LP to boot and start counting.
  var booted = false
  for _ in 0 ..< 200:
    delayUs(10_000)
    if shRead(LpSleepCounter) != 0xFFFFFFFF'u32: booted = true; break
  check("LP booted and started its sleep loop", booted)

  # Diagnostic: is the LP CORET mtime ticking at all? Sample it twice.
  let mt0 = shRead(LpMtimeDebug)
  delayUs(50_000)
  let mt1 = shRead(LpMtimeDebug)
  kv("[M0] LP mtime sample 0 = ", mt0)
  kv("[M0] LP mtime sample 1 = ", mt1)
  check("LP CORET mtime is ticking", mt1 != mt0)

  let cStart = shRead(LpSleepCounter)
  kv("[M0] counter at window start = ", cStart)
  for _ in 0 ..< (SampleMs div 10):
    delayUs(10_000)
  let cEnd = shRead(LpSleepCounter)
  kv("[M0] counter at window end   = ", cEnd)

  let advanced = cEnd - cStart
  kv("[M0] timed periods in window = ", advanced)
  # ~100 ms/period over 1500 ms => ~15; allow generous timer-rate slack.
  check("LP completed >= 6 timed periods on its CORET timer", advanced >= 6'u32)
  check("LP period rate is plausible (<= 40 in 1.5s)", advanced <= 40'u32)

  discard console.sendString("Result: ")
  console.sendHex32(passed.uint32)
  discard console.sendString(" passed, ")
  console.sendHex32(failed.uint32)
  discard console.sendLine(" failed")
  if failed == 0: line("=== Test Complete ===")
  else: line("=== Test Failed ===")
  while true: wfi()
