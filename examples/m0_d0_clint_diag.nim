## M0 reporter for the D0 CLINT discovery probe (d0_clint_diag).
## Releases D0, waits for its XRAM dump, prints each candidate mtime pair so we can
## see which address is a real, slowly-advancing timer.

import bl808/startup
import bl808/core, bl808/mmio, bl808/memmap
import bl808/glb, bl808/gpio, bl808/uart
import bl808/panicoverride
import bl808/kernel/alloc

const
  ConsoleBaud {.intdefine.} = 230_400'u32
  ConsoleClkHz {.intdefine.} = 40_000_000'u32
  Phase = XramBase + 0x3F18'u
  Ready = XramBase + 0x3F40'u
  ReadyMagic = 0xD1A6_0000'u32

var console: Uart
proc line(s: string) = discard console.sendLine(s)
proc shRead(a: uint): uint32 =
  dcacheFlushAll(); dcacheInvalidateAll(); fenceIo(); regRead(a)
proc kv(label: string, off: uint) =
  discard console.sendString(label); console.sendHex32(shRead(XramBase + off))
  discard console.sendLine("")

proc main() {.exportc, cdecl.} =
  systemInit(); heapInit()
  enableAllPeriphClocks(); enablePeriphClock(periphUart0)
  setMcuXclkSource(mcuXclkXtal); setUartClock(true, uartClkXclk, 0)
  gpioSetupUart(14, 15)
  console = initUart(uart0, UartConfig(
    baudRate: ConsoleBaud, dataBits: data8, stopBits: stop1, parity: parityNone), ConsoleClkHz)

  regWrite(Ready, 0); regWrite(Phase, 0xFF); dcacheFlushAll(); fenceIo()
  delayUs(400_000)
  line("")
  line("=== BL808 D0 CLINT Discovery (M0 reporter) ===")
  mmPowerOn(); line("[M0] Releasing D0"); releaseD0()

  var ok = false
  for _ in 0 ..< 500:
    delayUs(10_000)
    if shRead(Ready) == ReadyMagic: ok = true; break
  kv("[M0] phase reached    = ", 0x3F18)
  if not ok:
    line("[M0] D0 did not finish (see phase: which candidate hung)")
  kv("[D0] cand0 0xE400BFF8 A = ", 0x3F20)
  kv("[D0] cand0 0xE400BFF8 B = ", 0x3F24)
  kv("[D0] cand1 0xE0107FF8 A = ", 0x3F28)
  kv("[D0] cand1 0xE0107FF8 B = ", 0x3F2C)
  kv("[D0] cand2 0xE000BFF8 A = ", 0x3F30)
  kv("[D0] cand2 0xE000BFF8 B = ", 0x3F34)
  line("=== Diagnostic Complete ===")
  while true: wfi()
