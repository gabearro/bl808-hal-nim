## f32k / RC32K diagnostic: is the low-power 32 kHz clock actually running?
## The PDS/HBN wake timers count on f32k; if it's dead the core never wakes.
## Powers RC32K on correctly, selects it as f32k, and watches the HBN RTC advance.

import bl808/startup, bl808/core, bl808/mmio
import bl808/glb, bl808/gpio, bl808/uart
import bl808/kernel/alloc
import bl808/panicoverride

const
  ConsoleBaud {.intdefine.} = 230_400'u32
  ConsoleClkHz {.intdefine.} = 40_000_000'u32
  HbnRc32kCtrl0 = 0x2000_F200'u   # HBN_RC32K_CTRL0
  HbnPuRc32k    = 1'u32 shl 21    # HBN_PU_RC32K
  HbnGlbReg     = 0x2000_F030'u
  HbnCtlReg     = 0x2000_F000'u
  HbnRtcTimL    = 0x2000_F00C'u
  HbnRtcTimH    = 0x2000_F010'u
  RtcLatch      = 1'u32 shl 31

var console: Uart
proc line(s: string) = discard console.sendLine(s)
proc kv(label: string, v: uint32) =
  discard console.sendString(label); console.sendHex32(v); discard console.sendLine("")

proc readRtc(): uint32 =
  regSet(HbnRtcTimH, RtcLatch); regClear(HbnRtcTimH, RtcLatch); fenceIo()
  regRead(HbnRtcTimL)

proc main() {.exportc, cdecl.} =
  systemInit(); heapInit()
  enableAllPeriphClocks(); enablePeriphClock(periphUart0)
  setMcuXclkSource(mcuXclkXtal); setUartClock(true, uartClkXclk, 0)
  gpioSetupUart(14, 15)
  console = initUart(uart0, UartConfig(
    baudRate: ConsoleBaud, dataBits: data8, stopBits: stop1, parity: parityNone), ConsoleClkHz)
  delayUs(400_000)
  line("")
  line("=== BL808 f32k / RC32K Diagnostic ===")

  regSet(HbnRc32kCtrl0, HbnPuRc32k); fenceIo()
  delayUs(900)                                      # RC32K settle (>800us)
  regModify(HbnGlbReg, 0x3'u32 shl 3, 0'u32 shl 3)  # HBN_F32K_SEL = RC32K
  regSet(HbnCtlReg, 1'u32)                           # enable HBN RTC counter
  fenceIo()

  let r0 = readRtc()
  delayUs(150_000)
  let r1 = readRtc()
  kv("[M0] RTC sample 0 = ", r0)
  kv("[M0] RTC sample 1 = ", r1)
  kv("[M0] RTC delta    = ", r1 - r0)
  if r1 != r0: line("[PASS] f32k/RC32K is running (HBN RTC advanced)")
  else: line("[FAIL] f32k/RC32K is NOT running (RTC frozen)")
  line("=== Test Complete ===")
  while true: wfi()
