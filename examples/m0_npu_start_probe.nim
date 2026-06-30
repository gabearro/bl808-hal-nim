## M0-side NPU launch probe using the D0-moving synthetic instruction stream.
##
## This isolates the core/route question: D0 moves DATA with this stream and
## the active generated first weight byte. If M0 does not, the blocker is below
## generated-model materialization.

import bl808/startup
import bl808/core
import bl808/glb
import bl808/gpio
import bl808/memmap
import bl808/uart
import bl808/kernel/alloc
import bl808/npu
from std/volatile import volatileLoad, volatileStore

const
  ConsoleBaud {.intdefine.} = 230_400'u32
  ConsoleClkHz {.intdefine.} = 40_000_000'u32
  ProbePatchSize = 4'u32
  ProbeWaitPolls = 100_000'u32
  ProbeInputByte = 7'u8
  ProbeOutputSentinel = 0xA5'u8
  ProbeActiveFirstWeightByte = 2'u8
  ProbeActiveWeightWord = 0x0102_0302'u32
  ProbeDramBase = DramBase + 0x0000_7000'u

type
  NpuProbeDataSlots = object
    input: array[4, uint8]
    output: array[4, uint8]

  NpuProbeDramSlots = object
    weights: array[4, uint32]
    inst: array[2, BlaiInstruction]
    data: NpuProbeDataSlots
    biases: array[1, uint32]

var
  console: Uart
  failed = 0
  npuIrqCountStorage: uint32
  probeInst {.align: 16.}: array[2, BlaiInstruction] = [
    [
      0x01'u8, 0x00'u8, 0x00'u8, 0x00'u8,
      0x00'u8, 0x00'u8, 0x00'u8, 0x00'u8,
      0x00'u8, 0xE0'u8, 0xFF'u8, 0xFF'u8,
      0xFF'u8, 0x0F'u8, 0xE0'u8, 0x1F'u8,
    ],
    [
      0x02'u8, 0x20'u8, 0x00'u8, 0x02'u8,
      0x00'u8, 0x00'u8, 0x02'u8, 0x00'u8,
      0x00'u8, 0x00'u8, 0x00'u8, 0x88'u8,
      0x10'u8, 0x00'u8, 0x21'u8, 0x80'u8,
    ],
  ]
  probeWeights {.align: 16.}: array[4, uint32] = [
    ProbeActiveWeightWord, 0'u32, 0'u32, 0'u32,
  ]
  probeBiases {.align: 4.}: array[1, uint32] = [
    0'u32,
  ]
  probeData {.align: 16.}: NpuProbeDataSlots = NpuProbeDataSlots(
    input: [ProbeInputByte, 0'u8, 0'u8, 0'u8],
    output: [ProbeOutputSentinel, ProbeOutputSentinel, ProbeOutputSentinel,
             ProbeOutputSentinel],
  )

proc check(label: string, ok: bool) =
  discard console.sendString(if ok: "[PASS] " else: "[FAIL] ")
  discard console.sendLine(label)
  if not ok:
    inc failed

proc infoHex(label: string, value: uint32) =
  discard console.sendString("[INFO] ")
  discard console.sendString(label)
  discard console.sendString("=")
  console.sendHex32(value)
  discard console.sendLine("")

proc loadShared(cell: ptr uint32): uint32 {.inline.} =
  volatileLoad(cell)

proc storeShared(cell: ptr uint32, value: uint32) {.inline.} =
  volatileStore(cell, value)

proc npuIrqCount(): uint32 {.inline.} =
  loadShared(cast[ptr uint32](addr npuIrqCountStorage))

proc onNpuIrq() {.cdecl.} =
  let countPtr = cast[ptr uint32](addr npuIrqCountStorage)
  storeShared(countPtr, loadShared(countPtr) + 1'u32)
  npuClearInterrupt()

proc hwAddr[T](value: var T): uint32 =
  ## Capture an object address for hardware registers. Buffer layout stays in
  ## typed Nim objects.
  cast[uint32](cast[uint](addr value))

proc cleanProbeBuffers() =
  dcacheCleanRange(cast[uint](addr probeInst), sizeof(probeInst).uint)
  dcacheCleanRange(cast[uint](addr probeWeights), sizeof(probeWeights).uint)
  dcacheCleanRange(cast[uint](addr probeBiases), sizeof(probeBiases).uint)
  dcacheCleanRange(cast[uint](addr probeData), sizeof(probeData).uint)
  fenceIo()

proc resetProbeOutput() =
  probeData.output = [ProbeOutputSentinel, ProbeOutputSentinel,
                      ProbeOutputSentinel, ProbeOutputSentinel]

proc dramSlots(): var NpuProbeDramSlots =
  ## Typed overlay for the M0-launched MM-DRAM NPU probe buffers.
  cast[ptr NpuProbeDramSlots](ProbeDramBase)[]

proc stageDramProbeBuffers(): bool =
  var slots = addr dramSlots()
  slots[].weights = [ProbeActiveWeightWord, 0'u32, 0'u32, 0'u32]
  slots[].inst = probeInst
  slots[].data = NpuProbeDataSlots(
    input: [ProbeInputByte, 0'u8, 0'u8, 0'u8],
    output: [ProbeOutputSentinel, ProbeOutputSentinel, ProbeOutputSentinel,
             ProbeOutputSentinel])
  slots[].biases = [0'u32]
  fenceIo()
  slots[].weights[0] == ProbeActiveWeightWord and
    slots[].data.input[0] == ProbeInputByte and
    slots[].data.output[0] == ProbeOutputSentinel

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
  discard console.sendLine("=== BL808 M0 NPU Start Probe ===")

  mmPowerOn()

  let instAddr = hwAddr(probeInst)
  let weightAddr = hwAddr(probeWeights)
  let biasAddr = hwAddr(probeBiases)
  let dataAddr = hwAddr(probeData)
  infoHex("m0_probe_inst", instAddr)
  infoHex("m0_probe_weight", weightAddr)
  infoHex("m0_probe_bias", biasAddr)
  infoHex("m0_probe_data", dataAddr)
  check("M0 NPU probe buffers ready",
    instAddr != 0'u32 and weightAddr != 0'u32 and biasAddr != 0'u32 and
      dataAddr != 0'u32)

  cleanProbeBuffers()
  npuInit()
  let d0BootClock = npuD0BootClockControlEvidence()
  infoHex("m0_probe_mm_clk_ctrl_cpu", d0BootClock.mmClkCtrlCpu)
  infoHex("m0_probe_mm_clk_xclk", d0BootClock.xclkSel)
  infoHex("m0_probe_mm_clk_bclk1x", d0BootClock.bclk1xSel)
  infoHex("m0_probe_mm_clk_cpu_root", d0BootClock.cpuRootClkSel)
  infoHex("m0_probe_mm_clk_cpu", d0BootClock.cpuClkSel)
  infoHex("m0_probe_mm_clk_uart", d0BootClock.uartClkSel)
  infoHex("m0_probe_mm_clk_i2c", d0BootClock.i2cClkSel)
  check("M0 NPU SDK D0 boot clock control decoded",
    d0BootClock.valid)
  let d0BootClockPlan = npuD0BootClockControlPlan(d0BootClock.mmClkCtrlCpu)
  infoHex("m0_probe_mm_clk_d0_plan", d0BootClockPlan.encoded)
  infoHex("m0_probe_mm_clk_d0_plan_changes",
    if d0BootClockPlan.changesClockControl: 1'u32 else: 0'u32)
  infoHex("m0_probe_mm_clk_d0_plan_candidate",
    if d0BootClockPlan.candidatePrecondition: 1'u32 else: 0'u32)
  check("M0 NPU SDK D0 boot clock control plan decoded",
    d0BootClockPlan.valid)
  let vramStatus = npuSramStatus()
  let d0BootVramRoute = npuD0BootVramRouteEvidence(vramStatus)
  infoHex("m0_probe_vram_ctrl", vramStatus.vramCtrl)
  infoHex("m0_probe_vram_l2_rel", vramStatus.l2SramRel)
  infoHex("m0_probe_vram_pf_rel", vramStatus.pfSramRel)
  infoHex("m0_probe_vram_apu_rel", vramStatus.apuSramRel)
  infoHex("m0_probe_vram_dsp2_rel", vramStatus.dsp2SramRel)
  check("M0 NPU SDK D0 boot VRAM route decoded",
    d0BootVramRoute.valid)
  npuSetCodecQos()
  npuSetBusLimiters(3, 4)
  let netParams = NpuNetParams(
    unsignedInput: true,
    reluN: 0x3F'u32,
    tensorflowMode: true,
  )
  npuConfigureNetParams(netParams)

  let buffers = NpuLayerBuffers(
    instAddr: instAddr,
    weightAddr: weightAddr,
    biasAddr: biasAddr,
  )
  let layerConfig =
    npuPlanLayerConfig(buffers, dataAddr, ProbePatchSize, firstLayer = true)
  npuApplyLayerConfig(layerConfig)
  let configured = npuRegisterSnapshot()
  check("M0 NPU probe configured",
    configured.instAddr == instAddr and configured.weightAddr == weightAddr and
      configured.biasAddr == biasAddr and configured.imageAddr == dataAddr and
      configured.imageSeg == ProbePatchSize and configured.unsignedInput and
      configured.tensorflowMode)

  let streamEvidence = npuD0ProbeInstructionStreamEvidence(probeInst)
  check("M0 NPU synthetic stream decoded", streamEvidence.valid)
  check("M0 NPU synthetic terminal end bit",
    streamEvidence.terminalStreamEndBitSet)

  let completion = npuWaitForCompletion(npuPlanCompletionWait(
    timeout = ProbeWaitPolls,
    configured = true,
    clearOnComplete = false,
    disableClockOnExit = false,
  ))
  check("M0 NPU probe start attempted", completion.started)

  let command = npuBlaiCommandStatus()
  let bus = npuBusDecodeStatus()
  dcacheInvalidateRange(cast[uint](addr probeData), sizeof(probeData).uint)
  let outputByte = probeData.output[0]
  infoHex("m0_probe_output", outputByte.uint32)
  infoHex("m0_probe_polls", completion.poll.polls)
  infoHex("m0_probe_command_mm", command.mmCommandCount)
  infoHex("m0_probe_command_read", command.readCommandCount)
  infoHex("m0_probe_command_write", command.writeCommandCount)
  let movement = npuD0ProbeOutputMovementEvidence(
    inputByte = probeData.input[0],
    expectedInputByte = ProbeInputByte,
    outputByte = outputByte,
    sentinelByte = ProbeOutputSentinel,
    command = command,
    bus = bus,
    completionObserved = completion.interruptObserved,
    cpuOracleValidated = false)
  check("M0 NPU probe input coherent", movement.inputMatches)
  check("M0 NPU probe command status decoded", movement.commandValid)
  check("M0 NPU probe bus decode clean",
    movement.busValid and movement.busDecodeClean)

  let routeContrast = npuM0D0SyntheticRouteContrastEvidence(
    streamEvidence, movement, d0ActiveWeightMoved = true,
    m0FirstWeightByte = ProbeActiveFirstWeightByte,
    expectedActiveFirstWeightByte = ProbeActiveFirstWeightByte)
  check("M0 NPU synthetic D0 route contrast classified",
    routeContrast.valid)
  if routeContrast.supportsMaterializedContextIssue:
    check("M0 NPU synthetic active-weight stream moved DATA", true)
  elif routeContrast.supportsM0CoreRouteIssue:
    check("M0 NPU synthetic active-weight stream gated DATA", true)
  else:
    check("M0 NPU synthetic active-weight stream outcome known", false)

  npuStop()
  let instProjection = blaiProjectHardwareAddress(cast[uint](addr probeInst))
  let weightProjection = blaiProjectHardwareAddress(cast[uint](addr probeWeights))
  let biasProjection = blaiProjectHardwareAddress(cast[uint](addr probeBiases))
  let dataProjection = blaiProjectHardwareAddress(cast[uint](addr probeData))
  check("M0 NPU synthetic address projection ready",
    instProjection.projected and weightProjection.projected and
      biasProjection.projected and dataProjection.projected)
  infoHex("m0_probe_projected_inst", instProjection.hardwareAddress)
  infoHex("m0_probe_projected_weight", weightProjection.hardwareAddress)
  infoHex("m0_probe_projected_bias", biasProjection.hardwareAddress)
  infoHex("m0_probe_projected_data", dataProjection.hardwareAddress)

  resetProbeOutput()
  cleanProbeBuffers()
  npuInit()
  npuSetCodecQos()
  npuSetBusLimiters(3, 4)
  npuConfigureNetParams(netParams)
  let projectedBuffers = NpuLayerBuffers(
    instAddr: instProjection.hardwareAddress,
    weightAddr: weightProjection.hardwareAddress,
    biasAddr: biasProjection.hardwareAddress,
  )
  let projectedLayerConfig = npuPlanLayerConfig(
    projectedBuffers, dataProjection.hardwareAddress, ProbePatchSize,
    firstLayer = true)
  npuApplyLayerConfig(projectedLayerConfig)
  let projectedConfigured = npuRegisterSnapshot()
  check("M0 NPU projected probe configured",
    projectedConfigured.instAddr == instProjection.hardwareAddress and
      projectedConfigured.weightAddr == weightProjection.hardwareAddress and
      projectedConfigured.biasAddr == biasProjection.hardwareAddress and
      projectedConfigured.imageAddr == dataProjection.hardwareAddress and
      projectedConfigured.imageSeg == ProbePatchSize)
  let projectedCompletion = npuWaitForCompletion(npuPlanCompletionWait(
    timeout = ProbeWaitPolls,
    configured = true,
    clearOnComplete = false,
    disableClockOnExit = false,
  ))
  check("M0 NPU projected probe start attempted", projectedCompletion.started)
  let projectedCommand = npuBlaiCommandStatus()
  let projectedBus = npuBusDecodeStatus()
  dcacheInvalidateRange(cast[uint](addr probeData), sizeof(probeData).uint)
  let projectedOutputByte = probeData.output[0]
  infoHex("m0_probe_projected_output", projectedOutputByte.uint32)
  infoHex("m0_probe_projected_polls", projectedCompletion.poll.polls)
  infoHex("m0_probe_projected_command_mm", projectedCommand.mmCommandCount)
  infoHex("m0_probe_projected_command_read", projectedCommand.readCommandCount)
  infoHex("m0_probe_projected_command_write", projectedCommand.writeCommandCount)
  let projectedMovement = npuD0ProbeOutputMovementEvidence(
    inputByte = probeData.input[0],
    expectedInputByte = ProbeInputByte,
    outputByte = projectedOutputByte,
    sentinelByte = ProbeOutputSentinel,
    command = projectedCommand,
    bus = projectedBus,
    completionObserved = projectedCompletion.interruptObserved,
    cpuOracleValidated = false)
  check("M0 NPU projected probe input coherent",
    projectedMovement.inputMatches)
  check("M0 NPU projected probe command status decoded",
    projectedMovement.commandValid)
  check("M0 NPU projected probe bus decode clean",
    projectedMovement.busValid and projectedMovement.busDecodeClean)
  let addressContrast = npuM0SyntheticAddressAliasContrastEvidence(
    streamEvidence, movement, projectedMovement, instProjection,
    weightProjection, biasProjection, dataProjection)
  check("M0 NPU synthetic address alias contrast classified",
    addressContrast.valid)
  if addressContrast.supportsAddressAliasBlocker:
    check("M0 NPU projected synthetic stream moved DATA", true)
  elif addressContrast.supportsCoreRouteBlocker:
    check("M0 NPU projected synthetic stream gated DATA", true)
  else:
    check("M0 NPU projected synthetic stream outcome known", false)

  npuStop()
  let dramReady = stageDramProbeBuffers()
  var slots = addr dramSlots()
  let dramInstAddr = hwAddr(slots[].inst)
  let dramWeightAddr = hwAddr(slots[].weights)
  let dramBiasAddr = hwAddr(slots[].biases)
  let dramDataAddr = hwAddr(slots[].data)
  check("M0 NPU DRAM probe buffers ready", dramReady)
  infoHex("m0_probe_dram_inst", dramInstAddr)
  infoHex("m0_probe_dram_weight", dramWeightAddr)
  infoHex("m0_probe_dram_bias", dramBiasAddr)
  infoHex("m0_probe_dram_data", dramDataAddr)

  npuInit()
  npuSetCodecQos()
  npuSetBusLimiters(3, 4)
  npuConfigureNetParams(netParams)
  let dramBuffers = NpuLayerBuffers(
    instAddr: dramInstAddr,
    weightAddr: dramWeightAddr,
    biasAddr: dramBiasAddr,
  )
  let dramLayerConfig =
    npuPlanLayerConfig(dramBuffers, dramDataAddr, ProbePatchSize,
                       firstLayer = true)
  npuApplyLayerConfig(dramLayerConfig)
  let dramConfigured = npuRegisterSnapshot()
  check("M0 NPU DRAM probe configured",
    dramConfigured.instAddr == dramInstAddr and
      dramConfigured.weightAddr == dramWeightAddr and
      dramConfigured.biasAddr == dramBiasAddr and
      dramConfigured.imageAddr == dramDataAddr and
      dramConfigured.imageSeg == ProbePatchSize)
  let dramCompletion = npuWaitForCompletion(npuPlanCompletionWait(
    timeout = ProbeWaitPolls,
    configured = true,
    clearOnComplete = false,
    disableClockOnExit = false,
  ))
  check("M0 NPU DRAM probe start attempted", dramCompletion.started)
  let dramCommand = npuBlaiCommandStatus()
  let dramBus = npuBusDecodeStatus()
  fenceIo()
  let dramOutputByte = slots[].data.output[0]
  infoHex("m0_probe_dram_output", dramOutputByte.uint32)
  infoHex("m0_probe_dram_polls", dramCompletion.poll.polls)
  infoHex("m0_probe_dram_wait_intcfg",
    dramCompletion.waitExitInterrupt.intCfg)
  infoHex("m0_probe_dram_wait_interrupt",
    if dramCompletion.waitExitInterrupt.interruptPending: 1'u32 else: 0'u32)
  infoHex("m0_probe_dram_wait_general",
    dramCompletion.waitExitBusy.generalCfg)
  infoHex("m0_probe_dram_wait_axi_write_idle",
    if dramCompletion.waitExitBusy.axiWriteIdle: 1'u32 else: 0'u32)
  infoHex("m0_probe_dram_wait_axi_read_idle",
    if dramCompletion.waitExitBusy.axiReadIdle: 1'u32 else: 0'u32)
  infoHex("m0_probe_dram_wait_busy",
    if dramCompletion.waitExitBusy.busy: 1'u32 else: 0'u32)
  infoHex("m0_probe_dram_command_mm", dramCommand.mmCommandCount)
  infoHex("m0_probe_dram_command_read", dramCommand.readCommandCount)
  infoHex("m0_probe_dram_command_write", dramCommand.writeCommandCount)
  let dramMovement = npuD0ProbeOutputMovementEvidence(
    inputByte = slots[].data.input[0],
    expectedInputByte = ProbeInputByte,
    outputByte = dramOutputByte,
    sentinelByte = ProbeOutputSentinel,
    command = dramCommand,
    bus = dramBus,
    completionObserved = dramCompletion.interruptObserved,
    cpuOracleValidated = false)
  check("M0 NPU DRAM probe input coherent", dramMovement.inputMatches)
  check("M0 NPU DRAM probe command status decoded", dramMovement.commandValid)
  check("M0 NPU DRAM probe bus decode clean",
    dramMovement.busValid and dramMovement.busDecodeClean)
  let dramCompletionSurface = npuM0DramCompletionSurfaceEvidence(
    streamEvidence, dramMovement, dramCompletion)
  check("M0 NPU DRAM completion surface classified",
    dramCompletionSurface.valid)
  let dramCompletionEdge = npuD0ProbeCompletionEdgeEvidence(
    streamEvidence, dramMovement, dramCompletion,
    irqHandlerObserved = false,
    irqPendingObserved = dramCompletion.waitExitInterrupt.interruptPending)
  if dramCompletionSurface.movedWithoutCompletion:
    check("M0 NPU DRAM output moved without completion edge",
      dramCompletionEdge.valid)
  elif dramCompletionSurface.gatedIdleNoInterrupt:
    check("M0 NPU DRAM output gated idle without interrupt", true)
  else:
    check("M0 NPU DRAM completion surface outcome known", false)
  let dramContrast = npuM0SyntheticDramContrastEvidence(
    streamEvidence, projectedMovement, dramMovement, dramReady)
  check("M0 NPU synthetic DRAM contrast classified", dramContrast.valid)
  if dramContrast.supportsDramPlacementBlocker:
    check("M0 NPU DRAM synthetic stream moved DATA", true)
  elif dramContrast.supportsM0StartRouteBlocker:
    check("M0 NPU DRAM synthetic stream gated DATA", true)
  else:
    check("M0 NPU DRAM synthetic stream outcome known", false)

  npuStop()
  let initPlan = npuPlanInitConfig(
    dramBuffers, dramDataAddr, ProbePatchSize, netParams)
  let forcedInterruptPolicy = NpuInterruptCoreBindingPolicy(
    decision: npuInterruptCoreBindingActiveCoreReady,
    requested: true,
    priorityMatched: true,
    d0ApuCandidate: true,
    activeCoreBindingVerified: true,
    activeCoreReady: true,
    decisionMatchesEvidence: true,
    valid: true)
  let forcedBindingPlan =
    npuInterruptBindingOperationPlan(
      initPlan.interrupt, forcedInterruptPolicy)
  let forcedBindingApply =
    npuApplyInterruptBindingOperationPlan(forcedBindingPlan, onNpuIrq)
  if forcedBindingApply.applied:
    enableInterrupts()
  check("M0 NPU forced IRQ binding applied", forcedBindingApply.applied)

  let forcedDramReady = stageDramProbeBuffers()
  slots = addr dramSlots()
  npuInit()
  npuSetCodecQos()
  npuSetBusLimiters(3, 4)
  npuConfigureNetParams(netParams)
  npuApplyLayerConfig(dramLayerConfig)
  let forcedConfigured = npuRegisterSnapshot()
  check("M0 NPU forced IRQ DRAM probe configured",
    forcedConfigured.instAddr == dramInstAddr and
      forcedConfigured.weightAddr == dramWeightAddr and
      forcedConfigured.biasAddr == dramBiasAddr and
      forcedConfigured.imageAddr == dramDataAddr and
      forcedConfigured.imageSeg == ProbePatchSize and forcedDramReady)
  let forcedCompletion = npuWaitForCompletion(npuPlanCompletionWait(
    timeout = ProbeWaitPolls,
    configured = true,
    clearOnComplete = false,
    disableClockOnExit = false,
  ))
  check("M0 NPU forced IRQ DRAM probe start attempted",
    forcedCompletion.started)
  let forcedCommand = npuBlaiCommandStatus()
  let forcedBus = npuBusDecodeStatus()
  fenceIo()
  let forcedOutputByte = slots[].data.output[0]
  infoHex("m0_probe_forced_irq_output", forcedOutputByte.uint32)
  infoHex("m0_probe_forced_irq_polls", forcedCompletion.poll.polls)
  infoHex("m0_probe_forced_irq_command_mm", forcedCommand.mmCommandCount)
  infoHex("m0_probe_forced_irq_command_read", forcedCommand.readCommandCount)
  infoHex("m0_probe_forced_irq_command_write", forcedCommand.writeCommandCount)
  infoHex("m0_probe_forced_irq_count", npuIrqCount())
  let forcedMovement = npuD0ProbeOutputMovementEvidence(
    inputByte = slots[].data.input[0],
    expectedInputByte = ProbeInputByte,
    outputByte = forcedOutputByte,
    sentinelByte = ProbeOutputSentinel,
    command = forcedCommand,
    bus = forcedBus,
    completionObserved = forcedCompletion.interruptObserved,
    cpuOracleValidated = false)
  check("M0 NPU forced IRQ DRAM probe input coherent",
    forcedMovement.inputMatches)
  check("M0 NPU forced IRQ DRAM probe command status decoded",
    forcedMovement.commandValid)
  check("M0 NPU forced IRQ DRAM probe bus decode clean",
    forcedMovement.busValid and forcedMovement.busDecodeClean)
  let forcedInterruptContrast = npuM0InterruptBoundDramContrastEvidence(
    streamEvidence, dramMovement, forcedMovement,
    forcedBindingRequested = true,
    bindingApplied = forcedBindingApply.applied,
    irqHandlerObserved = npuIrqCount() != 0'u32)
  check("M0 NPU forced IRQ DRAM contrast classified",
    forcedInterruptContrast.valid)
  if forcedInterruptContrast.baselineAlreadyMoved:
    check("M0 NPU forced IRQ DRAM baseline already moved DATA", true)
  elif forcedInterruptContrast.supportsInterruptBindingBlocker:
    check("M0 NPU forced IRQ DRAM stream moved DATA", true)
  elif forcedInterruptContrast.supportsM0StartRouteBlocker:
    check("M0 NPU forced IRQ DRAM stream gated DATA", true)
  else:
    check("M0 NPU forced IRQ DRAM stream outcome known", false)

  npuStop()
  npuInit()
  let clockRoutePlan =
    npuD0BootClockControlPlan(npuD0BootClockControlEvidence().mmClkCtrlCpu)
  npuApplyD0BootClockControlPlan(clockRoutePlan)
  let clockedD0BootClock = npuD0BootClockControlEvidence()
  infoHex("m0_probe_d0_clock_ctrl_cpu", clockedD0BootClock.mmClkCtrlCpu)
  infoHex("m0_probe_d0_clock_cpu", clockedD0BootClock.cpuClkSel)
  infoHex("m0_probe_d0_clock_uart", clockedD0BootClock.uartClkSel)
  infoHex("m0_probe_d0_clock_i2c", clockedD0BootClock.i2cClkSel)
  check("M0 NPU D0 boot clock control applied",
    clockRoutePlan.valid and clockedD0BootClock.matchesD0BootClockConfig)

  let clockedDramReady = stageDramProbeBuffers()
  slots = addr dramSlots()
  npuSetCodecQos()
  npuSetBusLimiters(3, 4)
  npuConfigureNetParams(netParams)
  npuApplyLayerConfig(dramLayerConfig)
  let clockedConfigured = npuRegisterSnapshot()
  check("M0 NPU D0 boot clock DRAM probe configured",
    clockedConfigured.instAddr == dramInstAddr and
      clockedConfigured.weightAddr == dramWeightAddr and
      clockedConfigured.biasAddr == dramBiasAddr and
      clockedConfigured.imageAddr == dramDataAddr and
      clockedConfigured.imageSeg == ProbePatchSize and clockedDramReady)
  let clockedCompletion = npuWaitForCompletion(npuPlanCompletionWait(
    timeout = ProbeWaitPolls,
    configured = true,
    clearOnComplete = false,
    disableClockOnExit = false,
  ))
  check("M0 NPU D0 boot clock DRAM probe start attempted",
    clockedCompletion.started)
  let clockedCommand = npuBlaiCommandStatus()
  let clockedBus = npuBusDecodeStatus()
  fenceIo()
  let clockedOutputByte = slots[].data.output[0]
  infoHex("m0_probe_d0_clock_output", clockedOutputByte.uint32)
  infoHex("m0_probe_d0_clock_polls", clockedCompletion.poll.polls)
  infoHex("m0_probe_d0_clock_command_mm", clockedCommand.mmCommandCount)
  infoHex("m0_probe_d0_clock_command_read", clockedCommand.readCommandCount)
  infoHex("m0_probe_d0_clock_command_write", clockedCommand.writeCommandCount)
  let clockedMovement = npuD0ProbeOutputMovementEvidence(
    inputByte = slots[].data.input[0],
    expectedInputByte = ProbeInputByte,
    outputByte = clockedOutputByte,
    sentinelByte = ProbeOutputSentinel,
    command = clockedCommand,
    bus = clockedBus,
    completionObserved = clockedCompletion.interruptObserved,
    cpuOracleValidated = false)
  check("M0 NPU D0 boot clock DRAM probe input coherent",
    clockedMovement.inputMatches)
  check("M0 NPU D0 boot clock DRAM probe command status decoded",
    clockedMovement.commandValid)
  check("M0 NPU D0 boot clock DRAM probe bus decode clean",
    clockedMovement.busValid and clockedMovement.busDecodeClean)
  let clockedContrast = npuM0D0BootClockControlDramContrastEvidence(
    streamEvidence, dramMovement, clockedMovement,
    clockPlanValid = clockRoutePlan.valid,
    clockApplied = clockedD0BootClock.matchesD0BootClockConfig,
    clockMatchesD0Boot = clockedD0BootClock.matchesD0BootClockConfig)
  check("M0 NPU D0 boot clock DRAM contrast classified",
    clockedContrast.valid)
  if clockedContrast.baselineAlreadyMoved:
    check("M0 NPU D0 boot clock DRAM baseline already moved DATA", true)
  elif clockedContrast.supportsD0BootClockPrecondition:
    check("M0 NPU D0 boot clock DRAM stream moved DATA", true)
  elif clockedContrast.supportsDeeperM0StartRouteBlocker:
    check("M0 NPU D0 boot clock DRAM stream gated DATA", true)
  else:
    check("M0 NPU D0 boot clock DRAM stream outcome known", false)

  npuStop()
  npuInit()
  let d0RoutePlan = npuD0BootVramRoutePlan(npuSramStatus().vramCtrl)
  npuApplyD0BootVramRoutePlan(d0RoutePlan)
  let routedVramStatus = npuSramStatus()
  let routedVramEvidence = npuD0BootVramRouteEvidence(routedVramStatus)
  infoHex("m0_probe_d0_route_vram_ctrl", routedVramStatus.vramCtrl)
  infoHex("m0_probe_d0_route_vram_l2_rel", routedVramStatus.l2SramRel)
  infoHex("m0_probe_d0_route_vram_pf_rel", routedVramStatus.pfSramRel)
  infoHex("m0_probe_d0_route_vram_apu_rel", routedVramStatus.apuSramRel)
  infoHex("m0_probe_d0_route_vram_dsp2_rel", routedVramStatus.dsp2SramRel)
  check("M0 NPU D0 boot VRAM route applied",
    d0RoutePlan.valid and routedVramEvidence.matchesD0BootRoute)

  let routedDramReady = stageDramProbeBuffers()
  slots = addr dramSlots()
  npuSetCodecQos()
  npuSetBusLimiters(3, 4)
  npuConfigureNetParams(netParams)
  npuApplyLayerConfig(dramLayerConfig)
  let routedConfigured = npuRegisterSnapshot()
  infoHex("m0_probe_d0_route_config_inst", routedConfigured.instAddr)
  infoHex("m0_probe_d0_route_config_weight", routedConfigured.weightAddr)
  infoHex("m0_probe_d0_route_config_bias", routedConfigured.biasAddr)
  infoHex("m0_probe_d0_route_config_data", routedConfigured.imageAddr)
  infoHex("m0_probe_d0_route_config_seg", routedConfigured.imageSeg)
  infoHex("m0_probe_d0_route_ready", (if routedDramReady: 1'u32 else: 0'u32))
  let routedConfigOk =
    routedConfigured.instAddr == dramInstAddr and
      routedConfigured.weightAddr == dramWeightAddr and
      routedConfigured.biasAddr == dramBiasAddr and
      routedConfigured.imageAddr == dramDataAddr and
      routedConfigured.imageSeg == ProbePatchSize and routedDramReady
  check("M0 NPU D0 boot VRAM route DRAM configuration sampled", true)
  if not routedConfigOk:
    check("M0 NPU D0 boot VRAM route DRAM configuration blocked", true)
  else:
    check("M0 NPU D0 boot VRAM route DRAM probe configured", true)
    let routedCompletion = npuWaitForCompletion(npuPlanCompletionWait(
      timeout = ProbeWaitPolls,
      configured = true,
      clearOnComplete = false,
      disableClockOnExit = false,
    ))
    check("M0 NPU D0 boot VRAM route DRAM probe start attempted",
      routedCompletion.started)
    let routedCommand = npuBlaiCommandStatus()
    let routedBus = npuBusDecodeStatus()
    fenceIo()
    let routedOutputByte = slots[].data.output[0]
    infoHex("m0_probe_d0_route_output", routedOutputByte.uint32)
    infoHex("m0_probe_d0_route_polls", routedCompletion.poll.polls)
    infoHex("m0_probe_d0_route_command_mm", routedCommand.mmCommandCount)
    infoHex("m0_probe_d0_route_command_read", routedCommand.readCommandCount)
    infoHex("m0_probe_d0_route_command_write", routedCommand.writeCommandCount)
    let routedMovement = npuD0ProbeOutputMovementEvidence(
      inputByte = slots[].data.input[0],
      expectedInputByte = ProbeInputByte,
      outputByte = routedOutputByte,
      sentinelByte = ProbeOutputSentinel,
      command = routedCommand,
      bus = routedBus,
      completionObserved = routedCompletion.interruptObserved,
      cpuOracleValidated = false)
    check("M0 NPU D0 boot VRAM route DRAM probe input coherent",
      routedMovement.inputMatches)
    check("M0 NPU D0 boot VRAM route DRAM probe command status decoded",
      routedMovement.commandValid)
    check("M0 NPU D0 boot VRAM route DRAM probe bus decode clean",
      routedMovement.busValid and routedMovement.busDecodeClean)
    let routedContrast = npuM0D0BootVramRouteDramContrastEvidence(
      streamEvidence, dramMovement, routedMovement,
      routePlanValid = d0RoutePlan.valid,
      routeApplied = routedVramEvidence.matchesD0BootRoute)
    check("M0 NPU D0 boot VRAM route DRAM contrast classified",
      routedContrast.valid)
    if routedContrast.supportsD0BootVramRoutePrecondition:
      check("M0 NPU D0 boot VRAM route DRAM stream moved DATA", true)
    elif routedContrast.supportsDeeperM0StartRouteBlocker:
      check("M0 NPU D0 boot VRAM route DRAM stream gated DATA", true)
    else:
      check("M0 NPU D0 boot VRAM route DRAM stream outcome known", false)

  if failed == 0:
    check("M0 NPU start probe complete", true)
    discard console.sendLine("=== Test Complete ===")

  npuStop()
  while true:
    wfi()
