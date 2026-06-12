## M0 reporter for the LP timer-interrupt debug (lp_wfi_debug).
## Releases the LP, waits for its XRAM dump, prints the timer state so we can see
## why a CORET expiry doesn't raise a takeable interrupt to wake the E902's WFI.

import bl808/startup
import bl808/core, bl808/mmio, bl808/memmap
import bl808/glb, bl808/gpio, bl808/uart
import bl808/panicoverride
import bl808/kernel/alloc

const
  ConsoleBaud {.intdefine.} = 230_400'u32
  ConsoleClkHz {.intdefine.} = 40_000_000'u32
  Ready      = XramBase + 0x3F30'u
  ReadyMagic = 0xDEB0_BEEF'u32

var console: Uart
proc line(s: string) = discard console.sendLine(s)
proc kv(label: string, off: uint) =
  discard console.sendString(label)
  dcacheFlushAll(); dcacheInvalidateAll(); fenceIo()
  console.sendHex32(regRead(XramBase + off))
  discard console.sendLine("")

proc shRead(a: uint): uint32 =
  dcacheFlushAll(); dcacheInvalidateAll(); fenceIo(); regRead(a)

proc main() {.exportc, cdecl.} =
  systemInit(); heapInit()
  enableAllPeriphClocks(); enablePeriphClock(periphUart0)
  setMcuXclkSource(mcuXclkXtal); setUartClock(true, uartClkXclk, 0)
  gpioSetupUart(14, 15)
  console = initUart(uart0, UartConfig(
    baudRate: ConsoleBaud, dataBits: data8, stopBits: stop1, parity: parityNone), ConsoleClkHz)

  regWrite(Ready, 0); dcacheFlushAll(); fenceIo()
  delayUs(400_000)
  line("")
  line("=== BL808 LP WFI Timer Debug (M0 reporter) ===")
  mmPowerOn(); releaseLP()

  var ok = false
  for _ in 0 ..< 500:
    delayUs(10_000)
    if shRead(Ready) == ReadyMagic: ok = true; break
  if not ok:
    line("[FAIL] LP did not produce a debug dump")
    while true: wfi()

  kv("[LP] mtime@BFF8 A   = ", 0x3F34)
  kv("[LP] mtime@BFF8 B   = ", 0x3F38)
  kv("[LP] mtime@BFFC A   = ", 0x3F3C)
  kv("[LP] mtime@BFFC B   = ", 0x3F40)
  kv("[LP] mtimecmp set   = ", 0x3F48)
  kv("[LP] mtimecmp rdbk  = ", 0x3F44)
  kv("[LP] reached target = ", 0x3F4C)
  kv("[LP] mip @ cross    = ", 0x3F50)
  kv("[LP] CLIC irq7 word = ", 0x3F54)
  kv("[LP] mie value      = ", 0x3F58)
  kv("[LP] TRAP hits      = ", 0x3F5C)
  kv("[LP] last mcause    = ", 0x3F60)
  kv("[LP] mstatus        = ", 0x3F64)
  kv("[LP] mtvec          = ", 0x3F68)
  kv("[LP] DIRECT mcause   = ", 0x3F6C)
  kv("[LP] cliccfg         = ", 0x3F70)
  kv("[LP] mintthresh      = ", 0x3F74)
  kv("[LP] CLIC irq7 (end) = ", 0x3F78)
  kv("[LP] cliccfg after   = ", 0x3F7C)
  kv("[LP] mtime after spin = ", 0x3F80)
  for _ in 0 ..< 100: delayUs(10_000)
  kv("[LP] WFI wake result = ", 0x3F84)
  line("=== Test Complete ===")
  while true: wfi()
