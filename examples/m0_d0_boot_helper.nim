## M0 helper that powers the MM domain and releases D0.
##
## Used by D0-only validation images so the C906 boots through the same
## hardware control path as it does on the Ox64.

import bl808/startup
import bl808/core, bl808/mmio, bl808/memmap
import bl808/glb, bl808/gpio, bl808/uart

const
  ConsoleBaud {.intdefine.} = 230_400'u32
  ConsoleClkHz {.intdefine.} = 40_000_000'u32
  D0StatusAddr = XramBase + 0x3F80'u
  JtagD0StatusAddr = XramBase + 0x3E00'u
  JtagD0RunMagic = 0x4430_5255'u32 # "D0RU"
  JtagD0RunPollLimit = 8_000_000
  D0StatusScheduler = 1'u32 shl 0
  D0StatusTaskA = 1'u32 shl 1
  D0StatusTaskB = 1'u32 shl 2
  D0StatusDone = D0StatusScheduler or D0StatusTaskA or D0StatusTaskB

var console: Uart

proc switchJtagMuxToD0() =
  const
    jtagD0Gpio = (27'u32 shl 8) or (1'u32 shl 22) or (1'u32 shl 1) or 1'u32
  regWrite(GpioConfigBase + 6'u * 4'u, jtagD0Gpio)
  regWrite(GpioConfigBase + 7'u * 4'u, jtagD0Gpio)
  regWrite(GpioConfigBase + 12'u * 4'u, jtagD0Gpio)
  regWrite(GpioConfigBase + 13'u * 4'u, jtagD0Gpio)
  fenceIo()

proc spinDelay() =
  for _ in 0 ..< 20_000:
    {.emit: """asm volatile("");""".}

proc sharedRead32(address: uint): uint32 =
  dcacheFlushAll()
  dcacheInvalidateAll()
  core.fence()
  regRead(address)

proc waitForJtagD0RunMagic() =
  for _ in 0 ..< JtagD0RunPollLimit:
    if sharedRead32(JtagD0StatusAddr) == JtagD0RunMagic:
      regWrite(JtagD0StatusAddr, 0)
      dcacheFlushAll()
      fenceIo()
      discard console.sendLine("[M0] D0 JTAG run magic observed")
      return
    spinDelay()
  discard console.sendLine("[FAIL] D0 JTAG load handshake timeout")

proc main() {.exportc, cdecl.} =
  systemInit()

  enablePeriphClock(periphUart0)
  setMcuXclkSource(mcuXclkXtal)
  setUartClock(true, uartClkXclk, 0)
  gpioSetupUart(14, 15)
  console = initUart(uart0, UartConfig(
    baudRate: ConsoleBaud, dataBits: data8,
    stopBits: stop1, parity: parityNone,
  ), ConsoleClkHz)

  discard console.sendLine("")
  discard console.sendLine("=== BL808 D0 Boot Helper (M0) ===")
  discard console.sendLine("[M0] Releasing D0")

  regWrite(D0StatusAddr, 0)
  dcacheFlushAll()
  fenceIo()

  mmPowerOn()
  when defined(bl808jtagram):
    releaseD0(forceLoad = false)
    discard console.sendLine("[M0] Switching JTAG mux to D0")
    switchJtagMuxToD0()
    discard console.sendLine("[M0] JTAG mux switched to D0")
    waitForJtagD0RunMagic()
  else:
    releaseD0()

  var printed = 0'u32
  while true:
    let status = sharedRead32(D0StatusAddr)
    if (status and D0StatusScheduler) != 0 and (printed and D0StatusScheduler) == 0:
      discard console.sendLine("[D0] Scheduler initialized")
      printed = printed or D0StatusScheduler
    if (status and D0StatusTaskA) != 0 and (printed and D0StatusTaskA) == 0:
      discard console.sendLine("[D0-A] done")
      printed = printed or D0StatusTaskA
    if (status and D0StatusTaskB) != 0 and (printed and D0StatusTaskB) == 0:
      discard console.sendLine("[D0-B] done")
      printed = printed or D0StatusTaskB
    if (printed and D0StatusDone) == D0StatusDone:
      discard console.sendLine("[M0] D0 kernel status complete")
      while true:
        wfi()
    spinDelay()
