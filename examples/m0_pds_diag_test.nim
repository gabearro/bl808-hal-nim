## PDS timer-wake diagnostic: does the PDS timer fire a wake event at all?

import bl808/startup, bl808/core, bl808/mmio
import bl808/glb, bl808/gpio, bl808/uart, bl808/pds
import bl808/kernel/alloc
import bl808/panicoverride

const
  ConsoleBaud {.intdefine.} = 230_400'u32
  ConsoleClkHz {.intdefine.} = 40_000_000'u32

var console: Uart
proc line(s: string) = discard console.sendLine(s)
proc kv(label: string, v: uint32) =
  discard console.sendString(label); console.sendHex32(v); discard console.sendLine("")

proc main() {.exportc, cdecl.} =
  systemInit(); heapInit()
  enableAllPeriphClocks(); enablePeriphClock(periphUart0)
  setMcuXclkSource(mcuXclkXtal); setUartClock(true, uartClkXclk, 0)
  gpioSetupUart(14, 15)
  console = initUart(uart0, UartConfig(
    baudRate: ConsoleBaud, dataBits: data8, stopBits: stop1, parity: parityNone), ConsoleClkHz)
  delayUs(400_000)
  line("")
  line("=== BL808 PDS Timer Diagnostic ===")

  let (fired, polls) = pdsDiagTimerWake(100)
  kv("[M0] wake event fired = ", (if fired: 1'u32 else: 0'u32))
  kv("[M0] poll iterations  = ", polls)
  if fired: line("[PASS] PDS timer raised a wake event")
  else: line("[FAIL] PDS timer never fired a wake event")
  line("=== Test Complete ===")
  while true: wfi()
