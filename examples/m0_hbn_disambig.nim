## HBN disambiguation: is the minimal-HBN "reboot loop" a real RTC wake or a crash?
##
## Reproduces the minimal-HBN entry that looped earlier (no warm-boot defang; RSV0/1
## set non-magic like the original probe), but with a LONG 20 s sleep and only a
## short settle. The cycle PERIOD is the answer:
##   * ~20+ s between boots  => genuine HBN deep-sleep + RTC POR wake.
##   * ~5 s (just boot time) => the chip is crashing/resetting, not RTC-waking.
## Each boot bumps a counter in HbnRsv2 (survives) and stamps a host-visible time
## marker so the period is measurable from the UART log.

import bl808/startup
import bl808/core, bl808/mmio, bl808/memmap
import bl808/glb, bl808/gpio, bl808/uart
import bl808/pds
import bl808/panicoverride
import bl808/kernel/alloc

const
  ConsoleBaud {.intdefine.} = 230_400'u32
  ConsoleClkHz {.intdefine.} = 40_000_000'u32
  SleepSeconds = 20'u32

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

proc enterHbnMin(seconds: uint32) {.noreturn.} =
  ## Minimal entry, NO defang (as the original looping probe). RSV0/1 set non-magic.
  disableInterrupts()
  hbnWriteRetention(0, 0x5A5A_0000'u32)
  hbnWriteRetention(1, 0x5A5A_0001'u32)
  regWrite(HbnIrqClr, 0xFFFF_FFFF'u32); regWrite(HbnIrqClr, 0); fenceIo()
  hbnPowerOnRc32k()
  regModify(pds.HbnGlb, HbnGlbF32kSelMask, 0)        # F32K_SEL = RC32K
  fenceIo()
  hbnClearRtcCounter()
  let comp = hbnReadRtc() + seconds.uint64 * Rc32kHz
  hbnSetRtcTimer(comp)
  hbnEnableRtcCounter()
  fenceIo()
  regSet(HbnCtl, 1'u32 shl HbnMode)
  while true:
    delayMs(1000)

proc main() {.exportc, cdecl.} =
  systemInit(); heapInit()
  initConsole()
  delayUs(200_000)
  let prev = hbnReadRetention(2)
  let cnt = (if (prev and 0xFFFF_FF00'u32) == 0x4242_0000'u32: prev + 1
             else: 0x4242_0000'u32)
  hbnWriteRetention(2, cnt)
  line("")
  line("=== BL808 M0 HBN Disambig ===")
  kv("[boot] counter        = ", cnt)
  kv("[boot] RTC count       = ", (hbnReadRtc() and 0xFFFF_FFFF'u64).uint32)
  line("[boot] arming 20 s HBN, sleeping now")
  delayMs(100)
  enterHbnMin(SleepSeconds)
