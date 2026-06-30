## D0-side NPU launch probe.
##
## This deliberately uses the typed NPU register/configuration APIs rather than
## direct register offsets. The M0 companion reports the XRAM status/diagnostic
## words over UART.

import bl808/startup
import bl808/core
import bl808/irq
import bl808/mmio, bl808/memmap
import bl808/kernel/alloc
import bl808/npu
from std/volatile import volatileLoad, volatileStore

const
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
  ProbePatchSize = 4'u32
  ProbeWaitPolls = 100_000'u32
  ProbeInputByte = 7'u8
  ProbeOutputSentinel = 0xA5'u8
  ProbeD0FirstWeightByte = 4'u8
  ProbeActiveFirstWeightByte = 2'u8
  ProbeD0WeightWord = 0x0102_0304'u32
  ProbeActiveWeightWord = 0x0102_0302'u32

type
  NpuProbeDataSlots = object
    input: array[4, uint8]
    output: array[4, uint8]

var
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
    ProbeD0WeightWord, 0'u32, 0'u32, 0'u32,
  ]
  probeBiases {.align: 4.}: array[1, uint32] = [
    0'u32,
  ]
  probeData {.align: 16.}: NpuProbeDataSlots = NpuProbeDataSlots(
    input: [ProbeInputByte, 0'u8, 0'u8, 0'u8],
    output: [ProbeOutputSentinel, ProbeOutputSentinel, ProbeOutputSentinel,
             ProbeOutputSentinel],
  )
  npuIrqCountStorage: uint32
  npuIrqIntCfgStorage: uint32
  npuIrqPendingStorage: uint32

proc loadShared(cell: ptr uint32): uint32 {.inline.} =
  volatileLoad(cell)

proc storeShared(cell: ptr uint32, value: uint32) {.inline.} =
  volatileStore(cell, value)

proc npuIrqCount(): uint32 {.inline.} =
  loadShared(cast[ptr uint32](addr npuIrqCountStorage))

proc npuIrqPendingSeen(): bool {.inline.} =
  loadShared(cast[ptr uint32](addr npuIrqPendingStorage)) != 0'u32

proc onNpuIrq() {.cdecl.} =
  let countPtr = cast[ptr uint32](addr npuIrqCountStorage)
  let intCfgPtr = cast[ptr uint32](addr npuIrqIntCfgStorage)
  let pendingPtr = cast[ptr uint32](addr npuIrqPendingStorage)
  let status = npuInterruptStatus()
  storeShared(countPtr, loadShared(countPtr) + 1'u32)
  storeShared(intCfgPtr, status.intCfg)
  if status.interruptPending:
    storeShared(pendingPtr, 1'u32)
  npuClearInterrupt()

proc hwAddr[T](value: var T): uint32 =
  ## Capture an object address for hardware registers. This is intentionally
  ## address capture only; buffer layout stays in typed Nim objects.
  cast[uint32](cast[uint](addr value))

proc diagAddr(index: uint): uint =
  DiagBase + index * 4'u

proc writeDiag(index: uint, value: uint32) =
  regWrite(diagAddr(index), value)

proc setStatus(mask: uint32) =
  regSet(StatusAddr, mask)
  fenceIo()

proc fail() =
  setStatus(StatusFailed)

proc cleanProbeBuffers() =
  dcacheCleanRange(cast[uint](addr probeInst), sizeof(probeInst).uint)
  dcacheCleanRange(cast[uint](addr probeWeights), sizeof(probeWeights).uint)
  dcacheCleanRange(cast[uint](addr probeBiases), sizeof(probeBiases).uint)
  dcacheCleanRange(cast[uint](addr probeData), sizeof(probeData).uint)
  fenceIo()

proc resetProbeOutput() =
  probeData.output = [ProbeOutputSentinel, ProbeOutputSentinel,
                      ProbeOutputSentinel, ProbeOutputSentinel]

proc storeSnapshot(baseIndex: uint, snapshot: NpuRegisterSnapshot) =
  writeDiag(baseIndex + 0'u, snapshot.generalCfg)
  writeDiag(baseIndex + 1'u, snapshot.intCfg)
  writeDiag(baseIndex + 2'u, snapshot.instAddr)
  writeDiag(baseIndex + 3'u, snapshot.weightAddr)
  writeDiag(baseIndex + 4'u, snapshot.biasAddr)
  writeDiag(baseIndex + 5'u, snapshot.imageAddr)
  writeDiag(baseIndex + 6'u, snapshot.imageSeg)
  writeDiag(baseIndex + 7'u, snapshot.tfCfg0)

proc main() {.exportc, cdecl.} =
  systemInit()
  heapInit()

  regWrite(StatusAddr, 0)
  for index in 0'u ..< 52'u:
    writeDiag(index, 0)
  setStatus(StatusStarted)

  let instAddr = hwAddr(probeInst)
  let weightAddr = hwAddr(probeWeights)
  let biasAddr = hwAddr(probeBiases)
  let dataAddr = hwAddr(probeData)
  writeDiag(0, instAddr)
  writeDiag(1, weightAddr)
  writeDiag(2, biasAddr)
  writeDiag(3, dataAddr)

  if instAddr == 0'u32 or weightAddr == 0'u32 or
      biasAddr == 0'u32 or dataAddr == 0'u32:
    fail()
  else:
    setStatus(StatusBuffersReady)

  cleanProbeBuffers()
  npuInit()
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
  storeSnapshot(8, configured)
  if configured.instAddr == instAddr and configured.weightAddr == weightAddr and
      configured.biasAddr == biasAddr and configured.imageAddr == dataAddr and
      configured.imageSeg == ProbePatchSize and configured.unsignedInput and
      configured.tensorflowMode:
    setStatus(StatusConfigured)
  else:
    fail()

  let initPlan = npuPlanInitConfig(buffers, dataAddr, ProbePatchSize, netParams)
  let d0IrqRuntime = BlaiNpuRuntimeOwnershipPlan(
    initCreatesInterruptSemaphore: false,
    initCreatesExecutionMutex: false,
    initDisablesClock: false,
    sdkInterruptWait: blaiNpuRuntimeWaitSdkCountingSemaphore,
    activeInterruptWait: blaiNpuRuntimeWaitSdkCountingSemaphore,
    sdkExecutionLock: blaiNpuRuntimeLockSdkMutex,
    activeExecutionLock: blaiNpuRuntimeLockBareMetalSingleThread,
    forwardRunTakesExecutionLock: false,
    forwardRunReleasesExecutionLock: false,
    forwardRunStopsAfterInference: false,
  )
  plicInit()
  let binding = npuInterruptBindingReadiness(
    initPlan.interrupt, d0IrqRuntime, bindingVerified = true)
  if binding.ready:
    setStatus(StatusIrqBindingReady)
  let bindingApply =
    npuApplyInterruptBindingOperationPlan(binding.operationPlan, onNpuIrq)
  if bindingApply.applied:
    setStatus(StatusIrqBindingApplied)
  plicSetThreshold(0)
  csrWriteMie(csrReadMie() or (1'u shl 11))
  enableInterrupts()

  let completion = npuWaitForCompletion(npuPlanCompletionWait(
    timeout = ProbeWaitPolls,
    configured = true,
    clearOnComplete = false,
    disableClockOnExit = false,
  ))
  if completion.started:
    setStatus(StatusStartAttempted)
  if completion.waitExitBusy.busy:
    setStatus(StatusBusyObserved)
  if completion.interruptObserved:
    setStatus(StatusInterruptObserved)
  let irqHandlerObserved = npuIrqCount() != 0'u32
  let irqPendingObserved = npuIrqPendingSeen()
  if irqHandlerObserved:
    setStatus(StatusInterruptObserved or StatusIrqHandlerObserved)
  if irqPendingObserved:
    setStatus(StatusIrqHandlerPending)

  let after = npuRegisterSnapshot()
  let command = npuBlaiCommandStatus()
  let bus = npuBusDecodeStatus()
  dcacheInvalidateRange(cast[uint](addr probeData), sizeof(probeData).uint)
  let outputByte = probeData.output[0]
  let outputMovement = npuD0ProbeOutputMovementEvidence(
    inputByte = probeData.input[0],
    expectedInputByte = ProbeInputByte,
    outputByte = outputByte,
    sentinelByte = ProbeOutputSentinel,
    command = command,
    bus = bus,
    completionObserved = completion.interruptObserved,
    cpuOracleValidated = false)
  let streamEvidence = npuD0ProbeInstructionStreamEvidence(probeInst)
  let completionEdge = npuD0ProbeCompletionEdgeEvidence(
    streamEvidence, outputMovement, completion, irqHandlerObserved,
    irqPendingObserved)
  storeSnapshot(16, after)
  writeDiag(24, completion.poll.polls)
  writeDiag(25, cast[uint32](completion.status))
  writeDiag(26, command.mmCommandCount)
  writeDiag(27, command.readCommandCount)
  writeDiag(28, command.writeCommandCount)
  writeDiag(29, bus.mmBusDecErr)
  writeDiag(30, bus.mmBusDecErrAddr)
  writeDiag(31, bus.mcuBusDecErr)
  writeDiag(32, bus.mcuBusDecErrAddr)
  writeDiag(33, probeData.input[0].uint32)
  writeDiag(34, outputByte.uint32)
  writeDiag(35, ProbeOutputSentinel.uint32)
  writeDiag(36, if outputMovement.outputMoved: 1'u32 else: 0'u32)
  writeDiag(37, if outputMovement.modelOutputStillUnvalidated: 1'u32 else: 0'u32)
  writeDiag(38, npuIrqCount())
  writeDiag(39, loadShared(cast[ptr uint32](addr npuIrqIntCfgStorage)))
  writeDiag(40, if irqPendingObserved: 1'u32 else: 0'u32)
  writeDiag(41, streamEvidence.streamLen)
  writeDiag(42, if streamEvidence.terminalStreamEndBitSet: 1'u32 else: 0'u32)
  writeDiag(43, if completionEdge.completionEdgeMissing: 1'u32 else: 0'u32)

  if command.anyCommandCount:
    setStatus(StatusCommandActivity)
  if command.valid:
    setStatus(StatusCommandIdleSampled)
  if bus.noDecodeError:
    setStatus(StatusBusDecodeClean)
  if outputMovement.movementEvidenceValid:
    setStatus(StatusOutputMoved)
  if bus.anyErrorLatched:
    fail()
  if streamEvidence.valid:
    setStatus(StatusProbeStreamTyped)
  if streamEvidence.terminalStreamEndBitSet:
    setStatus(StatusProbeTerminalEndBit)
  if completionEdge.valid:
    setStatus(StatusProbeMissingCompletionEdge)

  npuStop()
  probeWeights[0] = ProbeActiveWeightWord
  resetProbeOutput()
  cleanProbeBuffers()
  npuInit()
  npuSetCodecQos()
  npuSetBusLimiters(3, 4)
  npuConfigureNetParams(netParams)
  npuApplyLayerConfig(layerConfig)
  let activeWeightCompletion = npuWaitForCompletion(npuPlanCompletionWait(
    timeout = ProbeWaitPolls,
    configured = true,
    clearOnComplete = false,
    disableClockOnExit = false,
  ))
  let activeWeightAfter = npuRegisterSnapshot()
  let activeWeightCommand = npuBlaiCommandStatus()
  let activeWeightBus = npuBusDecodeStatus()
  dcacheInvalidateRange(cast[uint](addr probeData), sizeof(probeData).uint)
  let activeWeightOutputByte = probeData.output[0]
  let activeWeightMovement = npuD0ProbeOutputMovementEvidence(
    inputByte = probeData.input[0],
    expectedInputByte = ProbeInputByte,
    outputByte = activeWeightOutputByte,
    sentinelByte = ProbeOutputSentinel,
    command = activeWeightCommand,
    bus = activeWeightBus,
    completionObserved = activeWeightCompletion.interruptObserved,
    cpuOracleValidated = false)
  let weightExperiment = npuD0WeightByteExperimentEvidence(
    outputMovement, activeWeightMovement,
    ProbeD0FirstWeightByte, ProbeActiveFirstWeightByte,
    ProbeActiveFirstWeightByte)
  storeSnapshot(44, activeWeightAfter)
  writeDiag(50, activeWeightOutputByte.uint32)
  writeDiag(51, if weightExperiment.supportsWeightSensitiveMovement: 1'u32
                elif weightExperiment.supportsCorePathDifference: 2'u32
                else: 0'u32)
  if weightExperiment.valid:
    setStatus(StatusProbeActiveWeightClassified)
  if weightExperiment.supportsCorePathDifference:
    setStatus(StatusProbeActiveWeightMoved)
  if weightExperiment.supportsWeightSensitiveMovement:
    setStatus(StatusProbeActiveWeightGated)

  let statusBeforeDone = regRead(StatusAddr)
  let statusForTypedEvidence = statusBeforeDone or StatusDone
  let typedStatus = npuD0ProbeStatusEvidence(
    statusForTypedEvidence, StatusRequired, StatusStarted, StatusBuffersReady,
    StatusConfigured, StatusStartAttempted, StatusBusyObserved,
    StatusInterruptObserved, StatusCommandActivity, StatusCommandIdleSampled,
    StatusBusDecodeClean, StatusOutputMoved, StatusFailed, StatusDone,
    outputMovement)
  if typedStatus.valid:
    setStatus(StatusTypedEvidence)
  if typedStatus.outputMoved:
    setStatus(StatusTypedOutputMovement)
  if typedStatus.modelOutputStillUnvalidated:
    setStatus(StatusTypedModelOutputUnvalidated)
  if typedStatus.movementWithoutOracle:
    setStatus(StatusTypedMovementWithoutOracle)

  npuStop()
  setStatus(StatusDone)
  while true:
    wfi()
