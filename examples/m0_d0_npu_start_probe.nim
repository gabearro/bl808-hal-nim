## M0 helper for the D0 NPU launch probe.

import bl808/startup
import bl808/core, bl808/mmio, bl808/memmap
import bl808/glb, bl808/gpio, bl808/uart
import bl808/kernel/alloc

const
  ConsoleBaud {.intdefine.} = 230_400'u32
  ConsoleClkHz {.intdefine.} = 40_000_000'u32
  StatusAddr = XramBase + 0x3E00'u
  DiagBase = XramBase + 0x3E10'u
  StatusStarted = 1'u32 shl 0
  StatusBuffersReady = 1'u32 shl 1
  StatusConfigured = 1'u32 shl 2
  StatusStartAttempted = 1'u32 shl 3
  StatusBusyObserved = 1'u32 shl 4
  StatusInterruptObserved = 1'u32 shl 5
  StatusCommandActivity = 1'u32 shl 6
  StatusCommandIdleSampled = 1'u32 shl 7
  StatusBusDecodeClean = 1'u32 shl 8
  StatusOutputMoved = 1'u32 shl 9
  StatusTypedEvidence = 1'u32 shl 10
  StatusTypedOutputMovement = 1'u32 shl 11
  StatusTypedModelOutputUnvalidated = 1'u32 shl 12
  StatusTypedMovementWithoutOracle = 1'u32 shl 13
  StatusIrqBindingReady = 1'u32 shl 14
  StatusIrqBindingApplied = 1'u32 shl 15
  StatusIrqHandlerObserved = 1'u32 shl 16
  StatusIrqHandlerPending = 1'u32 shl 17
  StatusProbeStreamTyped = 1'u32 shl 18
  StatusProbeTerminalEndBit = 1'u32 shl 19
  StatusProbeMissingCompletionEdge = 1'u32 shl 20
  StatusProbeActiveWeightClassified = 1'u32 shl 21
  StatusProbeActiveWeightMoved = 1'u32 shl 22
  StatusProbeActiveWeightGated = 1'u32 shl 23
  StatusRequired = StatusStarted or StatusBuffersReady or StatusConfigured or
                   StatusStartAttempted or StatusCommandIdleSampled or
                   StatusBusDecodeClean or StatusOutputMoved
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

proc checkRequired(label: string, ok: bool) =
  discard console.sendString(if ok: "[PASS] " else: "[INFO] missing ")
  discard console.sendLine(label)

proc infoHex(label: string, value: uint32) =
  discard console.sendString("[INFO] ")
  discard console.sendString(label)
  discard console.sendString("=")
  console.sendHex32(value)
  discard console.sendLine("")

proc printTypedD0ProbeEvidence(status: uint32) =
  if (status and StatusTypedEvidence) != 0:
    discard console.sendLine("[PASS] D0 NPU typed status evidence")
  else:
    discard console.sendLine("[INFO] D0 NPU typed status evidence incomplete")
  if (status and StatusTypedOutputMovement) != 0:
    discard console.sendLine("[PASS] D0 NPU typed output movement")
  else:
    discard console.sendLine("[INFO] D0 NPU typed output movement missing")
  if (status and StatusTypedModelOutputUnvalidated) != 0:
    discard console.sendLine("[PASS] D0 NPU typed model output still unvalidated")
  else:
    discard console.sendLine("[INFO] D0 NPU typed model output validation changed")
  if (status and StatusTypedMovementWithoutOracle) != 0:
    discard console.sendLine("[PASS] D0 NPU typed movement without oracle")
  else:
    discard console.sendLine("[INFO] D0 NPU typed movement without oracle missing")
  if (status and StatusIrqBindingReady) != 0:
    discard console.sendLine("[PASS] D0 NPU IRQ binding ready")
  else:
    discard console.sendLine("[INFO] D0 NPU IRQ binding not ready")
  if (status and StatusIrqBindingApplied) != 0:
    discard console.sendLine("[PASS] D0 NPU IRQ binding applied")
  else:
    discard console.sendLine("[INFO] D0 NPU IRQ binding not applied")
  if (status and StatusIrqHandlerObserved) != 0:
    discard console.sendLine("[PASS] D0 NPU IRQ handler observed")
  else:
    discard console.sendLine("[INFO] D0 NPU IRQ handler not observed")
  if (status and StatusIrqHandlerPending) != 0:
    discard console.sendLine("[PASS] D0 NPU IRQ handler saw pending bit")
  else:
    discard console.sendLine("[INFO] D0 NPU IRQ handler pending bit not observed")
  if (status and StatusProbeStreamTyped) != 0:
    discard console.sendLine("[PASS] D0 NPU typed probe stream decoded")
  else:
    discard console.sendLine("[INFO] D0 NPU typed probe stream decode missing")
  if (status and StatusProbeTerminalEndBit) != 0:
    discard console.sendLine("[PASS] D0 NPU probe terminal end bit decoded")
  else:
    discard console.sendLine("[INFO] D0 NPU probe terminal end bit missing")
  if (status and StatusProbeMissingCompletionEdge) != 0:
    discard console.sendLine("[PASS] D0 NPU output moved without completion edge")
  else:
    discard console.sendLine("[INFO] D0 NPU completion edge classification changed")
  if (status and StatusProbeActiveWeightClassified) != 0:
    discard console.sendLine("[PASS] D0 NPU active-weight experiment classified")
  else:
    discard console.sendLine("[INFO] D0 NPU active-weight experiment incomplete")
  if (status and StatusProbeActiveWeightMoved) != 0:
    discard console.sendLine("[PASS] D0 NPU active-weight experiment moved DATA")
  elif (status and StatusProbeActiveWeightGated) != 0:
    discard console.sendLine("[PASS] D0 NPU active-weight experiment gated DATA")
  else:
    discard console.sendLine("[INFO] D0 NPU active-weight result unavailable")

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
  discard console.sendLine("=== BL808 D0 NPU Start Probe ===")

  regWrite(StatusAddr, 0)
  for index in 0'u ..< 52'u:
    regWrite(DiagBase + index * 4'u, 0)
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

  infoHex("d0_npu_status", status)

  if (status and StatusDone) == 0:
    discard console.sendLine("[INFO] D0 NPU start probe status timeout")
  elif (status and StatusFailed) != 0:
    discard console.sendLine("[INFO] D0 NPU start probe reported a failed check")
  elif (status and StatusRequired) != StatusRequired:
    discard console.sendLine("[INFO] D0 NPU start probe missing required status bits")

  checkRequired("D0 NPU probe started", (status and StatusStarted) != 0)
  checkRequired("D0 NPU probe buffers ready", (status and StatusBuffersReady) != 0)
  checkRequired("D0 NPU probe configured", (status and StatusConfigured) != 0)
  checkRequired("D0 NPU probe start attempted", (status and StatusStartAttempted) != 0)
  checkRequired("D0 NPU probe command idle sampled", (status and StatusCommandIdleSampled) != 0)
  checkRequired("D0 NPU probe bus decode clean", (status and StatusBusDecodeClean) != 0)
  checkRequired("D0 NPU probe output moved", (status and StatusOutputMoved) != 0)

  if (status and StatusBusyObserved) != 0:
    discard console.sendLine("[PASS] D0 NPU probe busy observed")
  else:
    discard console.sendLine("[INFO] D0 NPU probe busy not observed")
  if (status and StatusInterruptObserved) != 0:
    discard console.sendLine("[PASS] D0 NPU probe interrupt observed")
  else:
    discard console.sendLine("[INFO] D0 NPU probe interrupt not observed")
  if (status and StatusCommandActivity) != 0:
    discard console.sendLine("[PASS] D0 NPU probe command activity")
  else:
    discard console.sendLine("[INFO] D0 NPU probe command activity not observed")

  if (status and StatusDone) != 0:
    printTypedD0ProbeEvidence(status)

  if (status and StatusFailed) == 0 and (status and StatusRequired) == StatusRequired:
    discard console.sendLine("[PASS] D0 NPU start probe complete")
    discard console.sendLine("=== Test Complete ===")

  while true:
    wfi()
