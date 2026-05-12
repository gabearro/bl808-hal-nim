## M0 helper for the D0 MM-domain HAL register smoke test.

import bl808/startup
import bl808/core, bl808/mmio, bl808/memmap
import bl808/glb, bl808/gpio, bl808/uart
import bl808/kernel/alloc

const
  ConsoleBaud {.intdefine.} = 230_400'u32
  ConsoleClkHz {.intdefine.} = 40_000_000'u32
  StatusAddr = XramBase + 0x3E00'u
  FailCodeAddr = XramBase + 0x3E04'u
  FailGotAddr = XramBase + 0x3E08'u
  FailExpectedAddr = XramBase + 0x3E0C'u
  StatusStarted = 1'u32 shl 0
  StatusDbi = 1'u32 shl 1
  StatusDvp = 1'u32 shl 2
  StatusOsd = 1'u32 shl 3
  StatusH264 = 1'u32 shl 4
  StatusMjpeg = 1'u32 shl 5
  StatusNpu = 1'u32 shl 6
  StatusRequired = StatusStarted or StatusDbi or StatusDvp or StatusOsd or
                   StatusH264 or StatusMjpeg or StatusNpu
  StatusFailed = 1'u32 shl 30
  StatusDone = 1'u32 shl 31
  JtagD0RunMagic = 0x4430_5255'u32 # "D0RU"
  JtagD0RunPollLimit = 8_000_000
  PollLimit = 8_000_000

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
  for _ in 0 ..< 100:
    {.emit: """asm volatile("");""".}

proc sharedRead32(address: uint): uint32 =
  dcacheInvalidateAll()
  regRead(address)

proc waitForJtagD0RunMagic() =
  for _ in 0 ..< JtagD0RunPollLimit:
    if sharedRead32(StatusAddr) == JtagD0RunMagic:
      regWrite(StatusAddr, 0)
      dcacheFlushAll()
      fenceIo()
      return
    spinDelay()
  discard console.sendLine("[FAIL] D0 JTAG load handshake timeout")

proc check(label: string, ok: bool) =
  discard console.sendString(if ok: "[PASS] " else: "[FAIL] ")
  discard console.sendLine(label)

proc main() {.exportc, cdecl.} =
  systemInit()
  heapInit()

  enablePeriphClock(periphUart0)
  setMcuXclkSource(mcuXclkXtal)
  setUartClock(true, uartClkXclk, 0)
  gpioSetupUart(14, 15)
  console = initUart(uart0, UartConfig(
    baudRate: ConsoleBaud, dataBits: data8,
    stopBits: stop1, parity: parityNone,
  ), ConsoleClkHz)

  discard console.sendLine("")
  discard console.sendLine("=== BL808 D0 MM HAL Register Smoke Test ===")

  regWrite(StatusAddr, 0)
  dcacheFlushAll()
  fenceIo()
  mmPowerOn()
  when defined(bl808jtagram):
    releaseD0(forceLoad = false)
    discard console.sendLine("[INFO] Switching JTAG mux to D0")
    switchJtagMuxToD0()
    discard console.sendLine("[INFO] JTAG mux switched to D0")
    waitForJtagD0RunMagic()
  else:
    releaseD0()

  var status = 0'u32
  for _ in 0 ..< PollLimit:
    status = sharedRead32(StatusAddr)
    if (status and StatusDone) != 0:
      break
    spinDelay()

  if (status and StatusDone) == 0:
    discard console.sendLine("[FAIL] D0 MM HAL status timeout")
  elif (status and StatusFailed) != 0:
    discard console.sendString("[FAIL] first code=")
    console.sendHex32(sharedRead32(FailCodeAddr))
    discard console.sendString(" got=")
    console.sendHex32(sharedRead32(FailGotAddr))
    discard console.sendString(" expected=")
    console.sendHex32(sharedRead32(FailExpectedAddr))
    discard console.sendLine("")
    discard console.sendLine("[FAIL] D0 MM HAL reported a failed check")
  elif (status and StatusRequired) != StatusRequired:
    discard console.sendLine("[FAIL] D0 MM HAL missing required status bits")

  check("D0 started", (status and StatusStarted) != 0)
  check("DBI register API", (status and StatusDbi) != 0)
  check("DVP register API", (status and StatusDvp) != 0)
  check("OSD register API", (status and StatusOsd) != 0)
  check("H264 register API", (status and StatusH264) != 0)
  check("MJPEG register API", (status and StatusMjpeg) != 0)
  check("NPU register API", (status and StatusNpu) != 0)

  if (status and StatusFailed) == 0 and (status and StatusRequired) == StatusRequired:
    discard console.sendLine("[PASS] D0 MM HAL register smoke complete")
    discard console.sendLine("=== Test Complete ===")

  while true:
    wfi()
