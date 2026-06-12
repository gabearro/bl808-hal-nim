## M0 HBN deep-hibernate + RTC-wake reset cycle (S5) — faithful vendor entry.
##
## Boot 1: arm a short HBN RTC wake and enter the faithful LEVEL_0 hibernate
## (pds.hbnEnterRtcWake — full vendor HBN_Mode_Enter+HBN_Enable: 0.90 V AON LDO,
## SRAM retention, RC32M root clk, plus the warm-boot-magic defang so the wake POR
## cold-boots instead of fast-pathing into an unset resume pointer). The chip powers
## down; UART goes silent. ~SleepSeconds later the RTC comparator POR-resets it.
## Boot 2: a clean cold boot. We detect the round-trip via a marker in HbnRsv2 (which
## survives the wake POR; RSV3's low half does not, and HBN_IRQ_STAT bit 16 is reset).
##
## RECOVERY: boot 1 prints a ~20 s countdown before sleeping. If this bricks (deep
## HBN, no wake), power-cycle ONCE; the chip re-prints the countdown, and a JTAG flash
## of a benign image during that window halts the core before it sleeps — no BOOT pin.
##
## Required markers include BOTH boot-1 and boot-2 lines, so it only passes on a
## genuine sleep->wake round-trip.

import bl808/startup
import bl808/core, bl808/mmio, bl808/memmap
import bl808/glb, bl808/gpio, bl808/uart
import bl808/pds
import bl808/panicoverride
import bl808/kernel/alloc

const
  ConsoleBaud {.intdefine.} = 230_400'u32
  ConsoleClkHz {.intdefine.} = 40_000_000'u32
  Marker       = 0x48424652'u32        # "RFBH" fresh marker (not EHBN/WHBN)
  MarkerSlot   = 2                      # HbnRsv2 — survives the wake POR cleanly
  SleepSeconds = 5'u32
  HbnRtcStatBit = 1'u32 shl 16
  WindowTicks  = 40                     # ~20 s recovery countdown (delayUs runs fast)

var console: Uart
proc line(s: string) = discard console.sendLine(s)
proc kv(label: string, v: uint32) =
  discard console.sendString(label); console.sendHex32(v); discard console.sendLine("")

proc initConsole() =
  enableAllPeriphClocks(); enablePeriphClock(periphUart0)
  setMcuXclkSource(mcuXclkXtal); setUartClock(true, uartClkXclk, 0)
  gpioSetupUart(14, 15)
  console = initUart(uart0, UartConfig(
    baudRate: ConsoleBaud, dataBits: data8, stopBits: stop1, parity: parityNone), ConsoleClkHz)

proc main() {.exportc, cdecl.} =
  systemInit(); heapInit()
  initConsole()
  delayUs(200_000)
  line("")
  line("=== BL808 M0 HBN RTC Wake ===")

  let stat = regRead(HbnIrqStat)
  let mark = hbnReadRetention(MarkerSlot)
  kv("[boot] retained marker = ", mark)
  kv("[boot] HBN_IRQ_STAT    = ", stat)
  if mark == Marker:
    # ---- Boot 2: we came back from HBN via the RTC POR ----
    line("[boot2] survived HBN deep sleep - cold boot after RTC POR")
    hbnWriteRetention(MarkerSlot, 0)
    hbnClearIrq()
    line("[PASS] HBN RTC wake survived reset")
    line("=== Test Complete ===")
    while true: wfi()
  else:
    # ---- Boot 1: arm the wake and hibernate ----
    line("[boot1] faithful HBN test - safety window open (power-cycle to abort/reflash)")
    var i = 0
    while i < WindowTicks:
      discard console.sendString(".")
      delayMs(500)
      inc i
    line("")
    line("[boot1] window closed - arming 5 s HBN RTC wake, entering hibernation")
    hbnClearIrq()
    hbnWriteRetention(MarkerSlot, Marker)
    dcacheFlushAll(); fenceIo()
    delayMs(50)
    hbnEnterRtcWake(SleepSeconds)        # {.noreturn.} — chip powers down here
