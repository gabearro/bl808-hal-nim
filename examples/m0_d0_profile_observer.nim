## UART0 observer for the D0 retire monitor. The D0 image needs no profiler code.

import bl808/[startup, core, d0profile, glb, gpio, irq, memmap, mmio, uart]

const
  ConsoleBaud {.intdefine.} = 230_400'u32
  ConsoleClkHz = 40_000_000'u32
  JtagD0Status = XramBase + 0x3E00'u
  JtagD0RunMagic = 0x4430_5255'u32
  CommandPrefix = "D0PROFILE "
  HpmCommandPrefix = "D0PROFILEHPM "

proc line(u: Uart; value: string) =
  discard u.sendLine(value)

proc hexField(u: Uart; value: uint32) =
  discard u.sendByte(32)
  u.sendHex32(value)

proc capture(u: Uart; seconds, rate: uint32; withHpm: bool) =
  var hpmStart {.noinit.}: array[D0HpmEventCount, uint64]
  var eventMask: uint32
  if withHpm and not requestD0Hpm(hpmStart, eventMask):
    u.line("BL808_D0_PROFILE_ERROR D0 did not answer the HPM start request")
    return
  discard u.sendString("BL808_D0_PROFILE_BEGIN")
  u.hexField(seconds)
  u.hexField(rate)
  u.line("")

  let duration = seconds * 1_000_000
  let period = 1_000_000'u32 div rate
  let started = clicReadMtime().uint32
  var due, count, unstable: uint32
  var random = started or 1
  var elapsed: uint32
  while true:
    elapsed = clicReadMtime().uint32 - started
    if elapsed >= duration: break
    if elapsed < due:
      delayUs(min(due - elapsed, 100'u32))
      continue

    var status, pcLow: uint32
    if readD0RetireSample(status, pcLow):
      discard u.sendString("BL808_D0_PROFILE_SAMPLE")
      u.hexField(elapsed)
      u.hexField(status)
      u.hexField(pcLow)
      u.line("")
      inc count
    else:
      inc unstable

    # Jitter the period so recurring work does not always land in the same phase.
    random = random xor (random shl 13)
    random = random xor (random shr 17)
    random = random xor (random shl 5)
    due = elapsed + period div 2 + random mod period

  if withHpm:
    var hpmEnd {.noinit.}: array[D0HpmEventCount, uint64]
    var endMask: uint32
    if not requestD0Hpm(hpmEnd, endMask):
      u.line("BL808_D0_PROFILE_ERROR D0 did not answer the HPM end request")
      return
    if eventMask != endMask:
      u.line("BL808_D0_PROFILE_ERROR D0 HPM event configuration changed")
      return
    discard u.sendString("BL808_D0_PROFILE_HPM")
    u.hexField(eventMask)
    for i in 0 ..< D0HpmEventCount:
      let delta = hpmEnd[i] - hpmStart[i]
      u.hexField((delta shr 32).uint32)
      u.hexField(delta.uint32)
    u.line("")

  discard u.sendString("BL808_D0_PROFILE_END")
  u.hexField(elapsed)
  u.hexField(count)
  u.hexField(unstable)
  u.line("")

proc matches(buffer: openArray[char]; size: int; prefix: string): bool =
  if size <= prefix.len: return false
  for i, c in prefix:
    if buffer[i] != c: return false
  true

proc serve(u: Uart) =
  var buffer: array[32, char]
  var size = 0
  var overflow = false
  while true:
    let (byteValue, available) = u.tryRecvByte()
    if not available:
      delayUs(100)
      continue
    if byteValue == 13: continue
    if byteValue != 10:
      if size == buffer.len:
        overflow = true
      else:
        buffer[size] = byteValue.char
        inc size
      continue

    if not overflow:
      let withHpm = matches(buffer, size, HpmCommandPrefix)
      if withHpm or matches(buffer, size, CommandPrefix):
        var pos = if withHpm: HpmCommandPrefix.len else: CommandPrefix.len
        var seconds, rate: uint32
        while pos < size and buffer[pos] in {'0'..'9'} and seconds <= 600:
          seconds = seconds * 10 + (ord(buffer[pos]) - ord('0')).uint32
          inc pos
        if pos < size and buffer[pos] == ' ':
          inc pos
          while pos < size and buffer[pos] in {'0'..'9'} and rate <= 200:
            rate = rate * 10 + (ord(buffer[pos]) - ord('0')).uint32
            inc pos
        if pos == size and seconds in 1'u32..600'u32 and rate in 1'u32..200'u32:
          u.capture(seconds, rate, withHpm)
        else:
          u.line("BL808_D0_PROFILE_ERROR invalid duration or rate")
    size = 0
    overflow = false

proc main() {.exportc, cdecl.} =
  systemInit()
  enablePeriphClock(periphUart0)
  setMcuXclkSource(mcuXclkXtal)
  setUartClock(true, uartClkXclk, 0)
  gpioSetupUart(14, 15)
  let console = initUart(uart0, UartConfig(baudRate: ConsoleBaud,
    dataBits: data8, stopBits: stop1, parity: parityNone), ConsoleClkHz)

  mmPowerOn()
  initD0HpmObserver()
  when defined(bl808jtagram):
    # Give D0 a valid reset-vector loop until the harness installs the ELF.
    regWrite(DramBase, 0x0000_006F)
    dcacheCleanRange(DramBase, 4)
    regWrite(JtagD0Status, 0)
    dcacheCleanRange(JtagD0Status, 4)
    core.fenceIo()
    releaseD0(forceLoad = false)
    # The harness attaches to D0 once to load the workload. All captures
    # after that go through the retire monitor and UART.
    const JtagD0Function = 27'u32
    for pin in [6'u, 7, 12, 13]:
      regWrite(GpioConfigBase + pin * 4,
               (JtagD0Function shl 8) or (1'u32 shl 22) or 3)
    core.fenceIo()
    console.line("JTAG mux switched to D0")
    let timeout = clicReadMtime() + 40_000_000
    while true:
      dcacheInvalidateRange(JtagD0Status, 4)
      if regRead(JtagD0Status) == JtagD0RunMagic: break
      if clicReadMtime() >= timeout:
        console.line("[FAIL] D0 profile observer timed out waiting for workload")
        while true: wfi()
      delayUs(500)
  else:
    if not d0FlashImageAvailable():
      console.line("[FAIL] D0 profile observer requires a DRAM-linked D0 flash image")
      while true: wfi()
    releaseD0()

  console.line("BL808_D0_PROFILE_READY")
  console.serve()
