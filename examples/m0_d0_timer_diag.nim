## M0 reporter for the D0 machine-timer diagnostic (d0_timer_diag).

import bl808/startup
import bl808/core, bl808/mmio, bl808/memmap
import bl808/glb, bl808/gpio, bl808/uart
import bl808/panicoverride
import bl808/kernel/alloc

const
  ConsoleBaud {.intdefine.} = 230_400'u32
  ConsoleClkHz {.intdefine.} = 40_000_000'u32
  Ready = XramBase + 0x3F44'u
  ReadyMagic = 0xD1A6_0002'u32

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

  regWrite(Ready, 0); regWrite(XramBase + 0x3F18'u, 0xFF); dcacheFlushAll(); fenceIo()
  delayUs(400_000)
  line("")
  line("=== BL808 D0 Machine-Timer Diagnostic (M0 reporter) ===")
  mmPowerOn(); line("[M0] Releasing D0"); releaseD0()

  var ok = false
  for _ in 0 ..< 600:
    delayUs(10_000)
    if shRead(Ready) == ReadyMagic: ok = true; break
  if not ok: line("[M0] D0 did not finish (check phase)")
  kv("[D0] phase reached  = ", 0x3F18)
  kv("[D0] time CSR A     = ", 0x3F1C)
  kv("[D0] time CSR B     = ", 0x3F20)
  kv("[D0] mie readback   = ", 0x3F24)
  kv("[D0] mtvec (vectored)= ", 0x3F3C)
  kv("[D0] MTIP asserted  = ", 0x3F28)
  kv("[D0] poll iters     = ", 0x3F2C)
  kv("[D0] mip at end     = ", 0x3F30)
  kv("[D0] timer trap cnt = ", 0x3F38)
  kv("[D0] SOFT trap cnt  = ", 0x3F40)
  kv("[D0] mapbaddr 0xfc1 = ", 0x3F48)
  kv("[D0] timer2(mapbase)= ", 0x3F4C)
  kv("[D0] time after rtc C= ", 0x3F50)
  kv("[D0] time after rtc D= ", 0x3F54)
  kv("[D0] future deadline = ", 0x3F58)
  kv("[D0] timer3(SDK rtc) = ", 0x3F5C)
  kv("[D0] rate t0         = ", 0x3F60)
  kv("[D0] rate t1 (2M dl) = ", 0x3F64)
  kv("[D0] WFI loop marker  = ", 0x3F70)
  kv("[D0] PERIODIC fires  = ", 0x3F68)
  kv("[D0] time at end     = ", 0x3F6C)
  kv("[D0] mstatus        = ", 0x3F34)
  line("=== Diagnostic Complete ===")
  while true: wfi()
