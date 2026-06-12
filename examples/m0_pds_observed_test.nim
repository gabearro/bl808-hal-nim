## M0 PDS sleep, observed by the LP (E902).
##
## M0 sets up UART0, releases the LP running lp_pds_observer, hands off the UART,
## then enters PDS. The LP — alive in the low-power domain — prints the PDS
## controller state in real time so we can finally SEE whether the PDS timer
## counts / the wake event fires while the M0 is dark to JTAG.

import bl808/startup
import bl808/core, bl808/mmio, bl808/memmap, bl808/irq
import bl808/glb, bl808/gpio, bl808/uart, bl808/pds
import bl808/panicoverride
import bl808/kernel/alloc

const
  ConsoleBaud {.intdefine.} = 230_400'u32
  ConsoleClkHz {.intdefine.} = 40_000_000'u32
  GoFlag   = XramBase + 0x3F20'u
  GoMagic  = 0x600D_600D'u32
  WokeFlag = XramBase + 0x3F24'u
  SleepMs = 100'u32

var
  console: Uart
  pdsWakeCountStorage: uint32

proc onPdsWake() {.cdecl.} =
  inc pdsWakeCountStorage
  regWrite(WokeFlag, 0xA5A5_0001'u32); dcacheFlushAll(); fenceIo()
  pdsClearIrq()

proc line(s: string) = discard console.sendLine(s)

proc main() {.exportc, cdecl.} =
  systemInit(); heapInit()
  enableAllPeriphClocks(); enablePeriphClock(periphUart0)
  setMcuXclkSource(mcuXclkXtal); setUartClock(true, uartClkXclk, 0)
  gpioSetupUart(14, 15)
  console = initUart(uart0, UartConfig(
    baudRate: ConsoleBaud, dataBits: data8, stopBits: stop1, parity: parityNone), ConsoleClkHz)

  regWrite(GoFlag, 0); regWrite(WokeFlag, 0); dcacheFlushAll(); fenceIo()

  delayUs(400_000)
  line("")
  line("=== BL808 PDS LP-Observed Test ===")
  line("[M0] releasing LP observer (E902)")
  mmPowerOn()
  releaseLP()
  delayUs(150_000)               # let the LP boot and wait on GoFlag

  # Enable the PDS wake IRQ (so the M0 wakes if the timer fires at all).
  registerTrapHandler(IrqM0PdsWakeup, onPdsWake)
  clicSetLevel(IrqM0PdsWakeup, 1)
  clicEnableIrq(IrqM0PdsWakeup)
  csrWriteMie(csrReadMie() or (1'u32 shl 11))
  enableInterrupts()

  line("[M0] arming PDS now — LP takes over UART:")
  console.flushTx()
  # Hand the UART to the LP, then sleep. After this the M0 emits nothing.
  regWrite(GoFlag, GoMagic); dcacheFlushAll(); fenceIo()
  pdsEnterLightTimerWake(SleepMs)
  # If the M0 ever resumes, flag it for the LP to print.
  regWrite(WokeFlag, 0xA5A5_0002'u32); dcacheFlushAll(); fenceIo()
  while true: wfi()
