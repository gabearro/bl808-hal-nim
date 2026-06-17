## Focused BL808 BLAI/NPU parsed-model reference smoke test.
##
## This covers small sequential parsed-model fixtures that are too noisy for
## the larger NPU smoke image but should still run on-device.

import bl808/startup
import bl808/glb
import bl808/gpio
import bl808/uart
import bl808/npu
import bl808/panicoverride
import bl808/kernel/alloc

const
  ConsoleUartTxPin = 14'u32
  ConsoleUartRxPin = 15'u32
  ConsoleBaud {.intdefine.} = 230_400'u32
  ConsoleClkHz {.intdefine.} = 40_000_000'u32
  ActiveNpuWorkspaceBytes = 2048

type
  AddressFixtureResultScratch = object
    tfliteComposed: BlaiTfliteParsedWorkspaceOracleAddressFixtureResult
    tfliteReadinessInto: BlaiTfliteParsedWorkspaceOracleAddressFixtureReadiness
    tfliteReadiness: BlaiTfliteParsedWorkspaceOracleAddressFixtureReadiness
    tfliteMismatchComposed: BlaiTfliteParsedWorkspaceOracleAddressFixtureResult
    tfliteMismatchReadiness: BlaiTfliteParsedWorkspaceOracleAddressFixtureReadiness
    tfliteShortComposed: BlaiTfliteParsedWorkspaceOracleAddressFixtureResult
    tfliteShortReadiness: BlaiTfliteParsedWorkspaceOracleAddressFixtureReadiness
    fixedComposed: BlaiFixedParsedWorkspaceOracleAddressFixtureResult
    fixedReadinessInto: BlaiFixedParsedWorkspaceOracleAddressFixtureReadiness
    fixedReadiness: BlaiFixedParsedWorkspaceOracleAddressFixtureReadiness
    fixedMismatchComposed: BlaiFixedParsedWorkspaceOracleAddressFixtureResult
    fixedMismatchReadiness: BlaiFixedParsedWorkspaceOracleAddressFixtureReadiness
    fixedShortComposed: BlaiFixedParsedWorkspaceOracleAddressFixtureResult
    fixedShortReadiness: BlaiFixedParsedWorkspaceOracleAddressFixtureReadiness

var
  console: Uart
  failed = 0
  activeNpuWorkspace {.exportc: "m0_npu_model_active_npu_workspace",
                       codegenDecl: "$# $# __attribute__((section(\".npuworkspace\"), aligned(16), used))".}:
    array[ActiveNpuWorkspaceBytes, uint8]
  addressFixtureWorkspace {.exportc: "m0_npu_model_address_fixture_workspace",
                            codegenDecl: "$# $# __attribute__((section(\".npuworkspace\"), aligned(16), used))".}:
    array[2048, uint8]
  addressFixtureCpuWeights {.exportc: "m0_npu_model_address_fixture_cpu_weights",
                             codegenDecl: "$# $# __attribute__((section(\".npuworkspace\"), aligned(4), used))".}:
    array[288, uint8]
  addressFixtureStream {.exportc: "m0_npu_model_address_fixture_stream",
                         codegenDecl: "$# $# __attribute__((section(\".npuworkspace\"), aligned(16), used))".}:
    array[BlaiInstructionScratchSize div BlaiInstructionSize, BlaiInstruction]
  addressFixtureDecodedWeights {.exportc: "m0_npu_model_address_fixture_decoded_weights",
                                 codegenDecl: "$# $# __attribute__((section(\".npuworkspace\"), aligned(4), used))".}:
    array[288, int32]
  addressFixtureDecodedBiases {.exportc: "m0_npu_model_address_fixture_decoded_biases",
                                codegenDecl: "$# $# __attribute__((section(\".npuworkspace\"), aligned(4), used))".}:
    array[4, int32]
  addressFixtureNpuWeights {.exportc: "m0_npu_model_address_fixture_npu_weights",
                             codegenDecl: "$# $# __attribute__((section(\".npuworkspace\"), aligned(4), used))".}:
    array[288, uint8]
  addressFixtureNpuBiases {.exportc: "m0_npu_model_address_fixture_npu_biases",
                            codegenDecl: "$# $# __attribute__((section(\".npuworkspace\"), aligned(4), used))".}:
    array[4, int32]
  addressFixtureTemporaryWeights: array[0, int32]
  addressFixtureResults {.exportc: "m0_npu_model_address_fixture_results",
                          codegenDecl: "$# $# __attribute__((section(\".npuworkspace\"), aligned(16), used))".}:
    AddressFixtureResultScratch

proc check(label: string, ok: bool) =
  discard console.sendString(if ok: "[PASS] " else: "[FAIL] ")
  discard console.sendLine(label)
  if not ok:
    inc failed

proc checkEq(label: string, got, expected: uint32) =
  if got == expected:
    check(label, true)
  else:
    discard console.sendString("[FAIL] ")
    discard console.sendString(label)
    discard console.sendString(" got=")
    console.sendHex32(got)
    discard console.sendString(" expected=")
    console.sendHex32(expected)
    discard console.sendLine("")
    inc failed

proc logActiveMmAggregateScan(
    label: string,
    snapshot: NpuMmAggregateInterruptSnapshot,
    evidence: BlaiParsedForwardConfiguredWorkspaceActiveMmAggregateWaitExitEvidence) =
  discard console.sendString("[INFO] ")
  discard console.sendString(label)
  discard console.sendString(" status0=")
  console.sendHex32(snapshot.status0)
  discard console.sendString(" mask0=")
  console.sendHex32(snapshot.mask0)
  discard console.sendString(" status1=")
  console.sendHex32(snapshot.status1)
  discard console.sendString(" mask1=")
  console.sendHex32(snapshot.mask1)
  discard console.sendString(" raw=")
  console.sendHex32(evidence.rawPendingCount)
  discard console.sendString(" unmasked=")
  console.sendHex32(evidence.unmaskedPendingCount)
  discard console.sendString(" masked=")
  console.sendHex32(evidence.maskedOnlyCount)
  discard console.sendString(" firstRaw=")
  console.sendHex32(evidence.firstRawPendingIndex)
  discard console.sendString(" firstUnmasked=")
  console.sendHex32(evidence.firstUnmaskedPendingIndex)
  discard console.sendString(" firstMasked=")
  console.sendHex32(evidence.firstMaskedOnlyIndex)
  discard console.sendString(" class=")
  console.sendHex32(evidence.pendingClass.uint32)
  discard console.sendString(" block=")
  console.sendHex32(evidence.firstBlock.uint32)
  discard console.sendLine("")

proc logNpuRegisterSnapshot(
    label: string,
    captured: bool,
    snapshot: NpuRegisterSnapshot) =
  discard console.sendString("[INFO] ")
  discard console.sendString(label)
  discard console.sendString(" captured=")
  console.sendHex32(if captured: 1'u32 else: 0'u32)
  discard console.sendString(" general=")
  console.sendHex32(snapshot.generalCfg)
  discard console.sendString(" int=")
  console.sendHex32(snapshot.intCfg)
  discard console.sendString(" inst=")
  console.sendHex32(snapshot.instAddr)
  discard console.sendString(" weight=")
  console.sendHex32(snapshot.weightAddr)
  discard console.sendString(" bias=")
  console.sendHex32(snapshot.biasAddr)
  discard console.sendString(" data=")
  console.sendHex32(snapshot.imageAddr)
  discard console.sendString(" seg=")
  console.sendHex32(snapshot.imageSeg)
  discard console.sendString(" tf=")
  console.sendHex32(snapshot.tfCfg0)
  discard console.sendString(" busy=")
  console.sendHex32(if snapshot.busy: 1'u32 else: 0'u32)
  discard console.sendString(" writeIdle=")
  console.sendHex32(if snapshot.axiWriteIdle: 1'u32 else: 0'u32)
  discard console.sendString(" readIdle=")
  console.sendHex32(if snapshot.axiReadIdle: 1'u32 else: 0'u32)
  discard console.sendString(" intPending=")
  console.sendHex32(if snapshot.interruptPending: 1'u32 else: 0'u32)
  discard console.sendLine("")

proc logNpuWaitExitRegisters(
    label: string,
    interrupt: NpuInterruptStatusResult,
    busy: NpuBusyStatusResult,
    clock: NpuClockStatusResult) =
  discard console.sendString("[INFO] ")
  discard console.sendString(label)
  discard console.sendString(" general=")
  console.sendHex32(busy.generalCfg)
  discard console.sendString(" int=")
  console.sendHex32(interrupt.intCfg)
  discard console.sendString(" busy=")
  console.sendHex32(if busy.busy: 1'u32 else: 0'u32)
  discard console.sendString(" writeIdle=")
  console.sendHex32(if busy.axiWriteIdle: 1'u32 else: 0'u32)
  discard console.sendString(" readIdle=")
  console.sendHex32(if busy.axiReadIdle: 1'u32 else: 0'u32)
  discard console.sendString(" intPending=")
  console.sendHex32(if interrupt.interruptPending: 1'u32 else: 0'u32)
  discard console.sendString(" clear=")
  console.sendHex32(if interrupt.clearRequested: 1'u32 else: 0'u32)
  discard console.sendString(" clkRaw=")
  console.sendHex32(clock.mmClkCpu)
  discard console.sendString(" clkEn=")
  console.sendHex32(if clock.enabled: 1'u32 else: 0'u32)
  discard console.sendString(" clkSrc=")
  console.sendHex32(clock.sourceBits)
  discard console.sendString(" clkDiv=")
  console.sendHex32(clock.divider)
  discard console.sendLine("")

proc logBlaiCommandStatus(
    label: string,
    status: NpuBlaiCommandStatusResult) =
  discard console.sendString("[INFO] ")
  discard console.sendString(label)
  discard console.sendString(" mmRaw=")
  console.sendHex32(status.mmCodecMisc1)
  discard console.sendString(" mmCnt=")
  console.sendHex32(status.mmCommandCount)
  discard console.sendString(" mmMode=")
  console.sendHex32(if status.mmCommandMode: 1'u32 else: 0'u32)
  discard console.sendString(" rdRaw=")
  console.sendHex32(status.codecLimiterRead)
  discard console.sendString(" rdCnt=")
  console.sendHex32(status.readCommandCount)
  discard console.sendString(" rdMode=")
  console.sendHex32(if status.readCommandMode: 1'u32 else: 0'u32)
  discard console.sendString(" wrRaw=")
  console.sendHex32(status.codecLimiterWrite)
  discard console.sendString(" wrCnt=")
  console.sendHex32(status.writeCommandCount)
  discard console.sendString(" wrMode=")
  console.sendHex32(if status.writeCommandMode: 1'u32 else: 0'u32)
  discard console.sendString(" anyCnt=")
  console.sendHex32(if status.anyCommandCount: 1'u32 else: 0'u32)
  discard console.sendString(" anyMode=")
  console.sendHex32(if status.anyCommandMode: 1'u32 else: 0'u32)
  discard console.sendLine("")

proc instructionWord(inst: BlaiInstruction, wordIndex: uint32): uint32 =
  let base = wordIndex.int * 4
  if base + 3 >= inst.len:
    return 0
  inst[base].uint32 or
    (inst[base + 1].uint32 shl 8) or
    (inst[base + 2].uint32 shl 16) or
    (inst[base + 3].uint32 shl 24)

proc workspaceByteAt(
    workspaceBytes: openArray[uint8],
    offset: uint32,
    present: var bool): uint32 =
  present = offset < workspaceBytes.len.uint32
  if present:
    workspaceBytes[offset.int].uint32
  else:
    0'u32

proc logActiveFetchSurface(
    label: string,
    workspace: BlaiForwardModelWorkspacePlan,
    workspaceBytes: openArray[uint8],
    stream: openArray[BlaiInstruction],
    instructionCount: uint32,
    dataSlots: BlaiForwardWorkspaceDataSlotEvidence,
    weightAddr: uint32,
    biasAddr: uint32,
    weightBytes: uint32,
    biasBytes: uint32,
    weights: openArray[uint8],
    biases: openArray[int32]) =
  var inputPresent = false
  var outputPresent = false
  let inputByte = workspaceByteAt(workspaceBytes, dataSlots.inputOffset, inputPresent)
  let outputByte = workspaceByteAt(workspaceBytes, dataSlots.outputOffset, outputPresent)
  discard console.sendString("[INFO] ")
  discard console.sendString(label)
  discard console.sendString(" instAddr=")
  console.sendHex32(workspace.instruction.address)
  discard console.sendString(" dataAddr=")
  console.sendHex32(workspace.data.address)
  discard console.sendString(" weightAddr=")
  console.sendHex32(weightAddr)
  discard console.sendString(" biasAddr=")
  console.sendHex32(biasAddr)
  discard console.sendString(" instCount=")
  console.sendHex32(instructionCount)
  discard console.sendString(" weightBytes=")
  console.sendHex32(weightBytes)
  discard console.sendString(" biasBytes=")
  console.sendHex32(biasBytes)
  discard console.sendString(" inputSlot=")
  console.sendHex32(dataSlots.inputSlot)
  discard console.sendString(" outputSlot=")
  console.sendHex32(dataSlots.outputSlot)
  discard console.sendString(" inputOffset=")
  console.sendHex32(dataSlots.inputOffset)
  discard console.sendString(" outputOffset=")
  console.sendHex32(dataSlots.outputOffset)
  discard console.sendString(" inputPresent=")
  console.sendHex32(if inputPresent: 1'u32 else: 0'u32)
  discard console.sendString(" inputByte=")
  console.sendHex32(inputByte)
  discard console.sendString(" outputPresent=")
  console.sendHex32(if outputPresent: 1'u32 else: 0'u32)
  discard console.sendString(" outputByte=")
  console.sendHex32(outputByte)
  if stream.len > 0:
    discard console.sendString(" inst0w0=")
    console.sendHex32(instructionWord(stream[0], 0))
    discard console.sendString(" inst0w1=")
    console.sendHex32(instructionWord(stream[0], 1))
    discard console.sendString(" inst0w2=")
    console.sendHex32(instructionWord(stream[0], 2))
    discard console.sendString(" inst0w3=")
    console.sendHex32(instructionWord(stream[0], 3))
  if stream.len > 1:
    discard console.sendString(" inst1w0=")
    console.sendHex32(instructionWord(stream[1], 0))
    discard console.sendString(" inst1w1=")
    console.sendHex32(instructionWord(stream[1], 1))
    discard console.sendString(" inst1w2=")
    console.sendHex32(instructionWord(stream[1], 2))
    discard console.sendString(" inst1w3=")
    console.sendHex32(instructionWord(stream[1], 3))
  discard console.sendString(" weight0=")
  console.sendHex32(if weights.len > 0: weights[0].uint32 else: 0'u32)
  discard console.sendString(" weight1=")
  console.sendHex32(if weights.len > 1: weights[1].uint32 else: 0'u32)
  discard console.sendString(" bias0=")
  console.sendHex32(if biases.len > 0: cast[uint32](biases[0]) else: 0'u32)
  discard console.sendLine("")

proc logActiveTimeoutOutputProbe(
    label: string,
    workspaceBytes: openArray[uint8],
    dataSlots: BlaiForwardWorkspaceDataSlotEvidence,
    invalidate: BlaiCacheRangeApplyResult) =
  var outputPresent = false
  let outputByte =
    workspaceByteAt(workspaceBytes, dataSlots.outputOffset, outputPresent)
  discard console.sendString("[INFO] ")
  discard console.sendString(label)
  discard console.sendString(" invActive=")
  console.sendHex32(if invalidate.active: 1'u32 else: 0'u32)
  discard console.sendString(" invFits=")
  console.sendHex32(if invalidate.fits: 1'u32 else: 0'u32)
  discard console.sendString(" invApplied=")
  console.sendHex32(if invalidate.applied: 1'u32 else: 0'u32)
  discard console.sendString(" invAddr=")
  console.sendHex32(invalidate.address)
  discard console.sendString(" invBytes=")
  console.sendHex32(invalidate.bytes)
  discard console.sendString(" outputSlot=")
  console.sendHex32(dataSlots.outputSlot)
  discard console.sendString(" outputOffset=")
  console.sendHex32(dataSlots.outputOffset)
  discard console.sendString(" outputPresent=")
  console.sendHex32(if outputPresent: 1'u32 else: 0'u32)
  discard console.sendString(" outputByte=")
  console.sendHex32(outputByte)
  discard console.sendLine("")

proc resetAddressFixtureScratch() =
  for i in 0 ..< addressFixtureWorkspace.len:
    addressFixtureWorkspace[i] = 0
  for i in 0 ..< addressFixtureCpuWeights.len:
    addressFixtureCpuWeights[i] = i.uint8
  for i in 0 ..< addressFixtureStream.len:
    addressFixtureStream[i] = default(BlaiInstruction)
  for i in 0 ..< addressFixtureDecodedWeights.len:
    addressFixtureDecodedWeights[i] = 0
  for i in 0 ..< addressFixtureDecodedBiases.len:
    addressFixtureDecodedBiases[i] = 0
  for i in 0 ..< addressFixtureNpuWeights.len:
    addressFixtureNpuWeights[i] = 0
  for i in 0 ..< addressFixtureNpuBiases.len:
    addressFixtureNpuBiases[i] = 0
  addressFixtureResults = default(AddressFixtureResultScratch)

proc checkOutputCompare(label: string, compare: BlaiInt8OutputCompareResult) =
  if compare.matched:
    check(label, true)
  else:
    discard console.sendString("[FAIL] ")
    discard console.sendString(label)
    discard console.sendString(" expectedLen=")
    console.sendHex32(compare.expectedElements)
    discard console.sendString(" actualLen=")
    console.sendHex32(compare.actualElements)
    discard console.sendString(" trailing=")
    console.sendHex32(compare.trailingElements)
    discard console.sendString(" mismatches=")
    console.sendHex32(compare.mismatchCount)
    discard console.sendString(" first=")
    console.sendHex32(compare.firstMismatch.uint32)
    if compare.expectedPresentAtFirstMismatch:
      discard console.sendString(" expected=")
      console.sendHex32(compare.expectedAtFirstMismatch.uint32)
    if compare.actualPresentAtFirstMismatch:
      discard console.sendString(" actual=")
      console.sendHex32(compare.actualAtFirstMismatch.uint32)
    discard console.sendLine("")
    inc failed

proc checkOutputCompare(label: string, compare: BlaiUint8OutputCompareResult) =
  if compare.matched:
    check(label, true)
  else:
    discard console.sendString("[FAIL] ")
    discard console.sendString(label)
    discard console.sendString(" expectedLen=")
    console.sendHex32(compare.expectedElements)
    discard console.sendString(" actualLen=")
    console.sendHex32(compare.actualElements)
    discard console.sendString(" trailing=")
    console.sendHex32(compare.trailingElements)
    discard console.sendString(" mismatches=")
    console.sendHex32(compare.mismatchCount)
    discard console.sendString(" first=")
    console.sendHex32(compare.firstMismatch.uint32)
    if compare.expectedPresentAtFirstMismatch:
      discard console.sendString(" expected=")
      console.sendHex32(compare.expectedAtFirstMismatch.uint32)
    if compare.actualPresentAtFirstMismatch:
      discard console.sendString(" actual=")
      console.sendHex32(compare.actualAtFirstMismatch.uint32)
    discard console.sendLine("")
    inc failed

proc fakeForwardLayerExecutor(
    plan: BlaiForwardNpuRunPlan,
    layerIndex: uint32): BlaiForwardNpuExecuteResult =
  discard layerIndex
  result.runnable = plan.runnable
  result.configurable = plan.configurable
  result.cacheApplied = plan.configurable
  result.waitPlan = blaiPlanForwardNpuCompletionWait(plan)
  result.cache = BlaiForwardNpuCacheApplyResult(
    runnable: plan.runnable,
    configurable: plan.configurable,
    fits: plan.configurable,
    applied: plan.configurable,
    cacheRangeCount: plan.cacheRangeCount)
  result.started = plan.configurable
  result.completed = plan.configurable
  result.status = if result.completed: npuOk else: npuTimeout
  result.completion = BlaiNpuCompletionWaitResult(
    configured: plan.configurable,
    started: plan.configurable,
    interruptObserved: result.completed,
    interruptCleared: result.completed,
    clockDisabled: plan.configurable,
    statusDecision: BlaiNpuCompletionStatusResult(
      configured: plan.configurable,
      interruptObserved: result.completed,
      completed: result.completed,
      status: result.status),
    status: result.status)
  result.outcome = BlaiForwardNpuExecuteOutcome(
    runnable: result.runnable,
    configurable: result.configurable,
    cacheFits: result.cache.fits,
    started: result.started,
    waitCompleted: result.completion.statusDecision.completed,
    completed: result.completed,
    status: result.status)

proc failingForwardLayerExecutor(
    plan: BlaiForwardNpuRunPlan,
    layerIndex: uint32): BlaiForwardNpuExecuteResult =
  discard layerIndex
  result.runnable = plan.runnable
  result.configurable = plan.configurable
  result.waitPlan = blaiPlanForwardNpuCompletionWait(plan)
  result.cache = BlaiForwardNpuCacheApplyResult(
    runnable: plan.runnable,
    configurable: plan.configurable,
    fits: plan.configurable,
    cacheRangeCount: plan.cacheRangeCount)
  result.started = plan.configurable
  result.status = npuTimeout
  result.completion = BlaiNpuCompletionWaitResult(
    configured: plan.configurable,
    started: plan.configurable,
    interruptObserved: false,
    interruptCleared: false,
    clockDisabled: plan.configurable,
    statusDecision: BlaiNpuCompletionStatusResult(
      configured: plan.configurable,
      interruptObserved: false,
      timedOut: plan.configurable,
      status: npuTimeout),
    status: npuTimeout)
  result.outcome = BlaiForwardNpuExecuteOutcome(
    runnable: result.runnable,
    configurable: result.configurable,
    cacheFits: result.cache.fits,
    started: result.started,
    waitCompleted: false,
    completed: false,
    status: result.status)

proc checkSequentialParsedModels() =
  var fixedLayers = [
    BlaiCpuParsedLayerState(
      active: true,
      index: 0,
      layer: BlaiCpuInstLayer64(
        layerType: ord(blaiConvolutional).int32,
        activation: ord(blaiActLinear).int32,
        dspOn: 1,
        dataType: 1,
        w: 2, h: 2, c: 1, outC: 1,
        size: 1, stride: 1, dilation: 1, groups: 1)),
    BlaiCpuParsedLayerState(
      active: true,
      index: 1,
      layer: BlaiCpuInstLayer64(
        layerType: ord(blaiMaxpool).int32,
        w: 2, h: 2, c: 1,
        size: 1, stride: 1, dilation: 1))]
  let fixedPlan = blaiReferenceFixedParsedBufferPlan(fixedLayers)
  check("NPU model fixed plan supported", fixedPlan.support.supported)
  checkEq("NPU model fixed plan layers", fixedPlan.activeLayerCount, 2)
  checkEq("NPU model fixed plan weight bytes",
    fixedPlan.cpuWeightStreamBytes, 1)
  checkEq("NPU model fixed plan bias bytes",
    fixedPlan.cpuBiasStreamBytes, 1)
  checkEq("NPU model fixed plan scratch", fixedPlan.scratchElements, 4)
  checkEq("NPU model fixed plan output", fixedPlan.outputElements, 4)
  var fixedWeights: array[1, int8]
  var fixedBiases: array[1, int8]
  var fixedScratchA: array[4, int8]
  var fixedScratchB: array[4, int8]
  var fixedOut: array[4, int8]
  let fixedChecked = blaiReferenceFixedParsedCheckedModel2d(
    fixedLayers,
    useTflite = false,
    input = [1'i8, 2, 3, 4],
    cpuWeightBytes = [2'u8],
    cpuBiasBytes = [0'u8],
    decodedWeights = fixedWeights,
    decodedBiases = fixedBiases,
    scratchA = fixedScratchA,
    scratchB = fixedScratchB,
    output = fixedOut)
  check("NPU model fixed sequential preflight",
    fixedChecked.preflight.fit.fits)
  check("NPU model fixed sequential executed", fixedChecked.executed)
  check("NPU model fixed sequential valid",
    fixedChecked.model.modelValid)
  checkEq("NPU model fixed sequential completed",
    fixedChecked.model.completedLayerCount, 2)
  checkEq("NPU model fixed sequential weight cursor",
    fixedChecked.model.nextWeightCursor.byteOffset, 1)
  checkEq("NPU model fixed sequential bias cursor",
    fixedChecked.model.nextBiasCursor.byteOffset, 1)
  checkOutputCompare("NPU model fixed sequential scratch",
    blaiCompareInt8Outputs([2'i8, 4, 6, 8], fixedScratchA))
  let fixedOutputCompare = blaiCompareInt8Outputs([2'i8, 4, 6, 8], fixedOut)
  checkOutputCompare("NPU model fixed sequential output",
    fixedOutputCompare)
  let fixedEndToEnd = blaiReferenceFixedParsedEndToEnd(
    fixedChecked, fixedOutputCompare)
  check("NPU model fixed e2e valid", fixedEndToEnd.valid)
  checkEq("NPU model fixed e2e first block",
    ord(fixedEndToEnd.firstBlock).uint32,
    ord(blaiRefFixedCheckedNoBlock).uint32)
  checkEq("NPU model fixed e2e completed",
    fixedEndToEnd.completedLayerCount, 2)
  check("NPU model fixed e2e streams",
    fixedEndToEnd.allWeightsConsumed and fixedEndToEnd.allBiasesConsumed)
  let fixedShortCompare = blaiCompareInt8Outputs([2'i8, 4, 6, 8], [2'i8, 4])
  checkEq("NPU model fixed compare compared",
    fixedShortCompare.comparedElements, 2)
  checkEq("NPU model fixed compare trailing",
    fixedShortCompare.trailingElements, 2)

  var shortFixedOut: array[4, int8]
  let shortFixed = blaiReferenceFixedParsedCheckedModel2d(
    fixedLayers,
    useTflite = false,
    input = [1'i8, 2],
    cpuWeightBytes = [2'u8],
    cpuBiasBytes = [0'u8],
    decodedWeights = fixedWeights,
    decodedBiases = fixedBiases,
    scratchA = fixedScratchA,
    scratchB = fixedScratchB,
    output = shortFixedOut)
  check("NPU model fixed sequential short blocked",
    not shortFixed.preflight.fit.modelInputFit and
      not shortFixed.readiness.execute and not shortFixed.executed)

  var tfliteLayers = [
    BlaiCpuParsedLayerState(
      active: true,
      index: 0,
      layer: BlaiCpuInstLayer64(
        layerType: ord(blaiConvolutional).int32,
        dspOn: 1,
        w: 2, h: 2, c: 1, outC: 1,
        outW: 2, outH: 2,
        size: 1, stride: 1, dilation: 1, groups: 1,
        tfInput1Offset: 0,
        tfInput2Offset: 0,
        tfOutputOffset: 0,
        tfOutputMultiplier: high(int32),
        tfOutputShift: 0,
        quantizedActivationMin: 0,
        quantizedActivationMax: 255)),
    BlaiCpuParsedLayerState(
      active: true,
      index: 1,
      layer: BlaiCpuInstLayer64(
        layerType: ord(blaiAvgpool).int32,
        w: 2, h: 2, c: 1, outC: 1,
        stride: 1,
        quantizedActivationMin: 0,
        quantizedActivationMax: 255))]
  let tflitePlan = blaiReferenceTfliteParsedBufferPlan(tfliteLayers)
  check("NPU model TFLite plan supported", tflitePlan.support.supported)
  checkEq("NPU model TFLite plan layers", tflitePlan.activeLayerCount, 2)
  checkEq("NPU model TFLite plan weight bytes",
    tflitePlan.cpuWeightStreamBytes, 1)
  checkEq("NPU model TFLite plan bias bytes",
    tflitePlan.cpuBiasStreamBytes, 4)
  checkEq("NPU model TFLite plan scratch", tflitePlan.scratchElements, 4)
  checkEq("NPU model TFLite plan output", tflitePlan.outputElements, 1)
  var tfliteBiases: array[1, int32]
  var tfliteScratchA: array[4, uint8]
  var tfliteScratchB: array[4, uint8]
  var tfliteOut: array[1, uint8]
  let tfliteChecked = blaiReferenceTfliteParsedCheckedModel2d(
    tfliteLayers,
    useTflite = true,
    input = [1'u8, 2, 3, 4],
    cpuWeightBytes = [2'u8],
    cpuBiasBytes = [0'u8, 0, 0, 0],
    decodedBiases = tfliteBiases,
    scratchA = tfliteScratchA,
    scratchB = tfliteScratchB,
    output = tfliteOut)
  check("NPU model TFLite sequential preflight",
    tfliteChecked.preflight.fit.fits)
  check("NPU model TFLite sequential executed", tfliteChecked.executed)
  check("NPU model TFLite sequential valid",
    tfliteChecked.model.modelValid)
  checkEq("NPU model TFLite sequential completed",
    tfliteChecked.model.completedLayerCount, 2)
  checkEq("NPU model TFLite sequential weight cursor",
    tfliteChecked.model.nextWeightCursor.byteOffset, 1)
  checkEq("NPU model TFLite sequential bias cursor",
    tfliteChecked.model.nextBiasCursor.byteOffset, 4)
  checkOutputCompare("NPU model TFLite sequential scratch",
    blaiCompareUint8Outputs([2'u8, 4, 6, 8], tfliteScratchA))
  let tfliteOutputCompare = blaiCompareUint8Outputs([5'u8], tfliteOut)
  checkOutputCompare("NPU model TFLite sequential output",
    tfliteOutputCompare)
  let tfliteEndToEnd = blaiReferenceTfliteParsedEndToEnd(
    tfliteChecked, tfliteOutputCompare)
  check("NPU model TFLite e2e valid", tfliteEndToEnd.valid)
  checkEq("NPU model TFLite e2e first block",
    ord(tfliteEndToEnd.firstBlock).uint32,
    ord(blaiRefTfliteCheckedNoBlock).uint32)
  checkEq("NPU model TFLite e2e completed",
    tfliteEndToEnd.completedLayerCount, 2)
  check("NPU model TFLite e2e streams",
    tfliteEndToEnd.allWeightsConsumed and tfliteEndToEnd.allBiasesConsumed)
  let tfliteShortCompare = blaiCompareUint8Outputs([5'u8], [])
  checkEq("NPU model TFLite compare compared",
    tfliteShortCompare.comparedElements, 0)
  checkEq("NPU model TFLite compare trailing",
    tfliteShortCompare.trailingElements, 1)

  var shortTfliteOut: array[1, uint8]
  let shortTflite = blaiReferenceTfliteParsedCheckedModel2d(
    tfliteLayers,
    useTflite = true,
    input = [1'u8, 2],
    cpuWeightBytes = [2'u8],
    cpuBiasBytes = [0'u8, 0, 0, 0],
    decodedBiases = tfliteBiases,
    scratchA = tfliteScratchA,
    scratchB = tfliteScratchB,
    output = shortTfliteOut)
  check("NPU model TFLite sequential short blocked",
    not shortTflite.preflight.fit.modelInputFit and
      not shortTflite.readiness.execute and not shortTflite.executed)

proc checkParsedSingleLayerDiagnostics() =
  let fixedLayer = BlaiCpuInstLayer64(
    layerType: ord(blaiConvolutional).int32,
    activation: ord(blaiActLinear).int32,
    dspOn: 1,
    dataType: 1,
    w: 1, h: 1, c: 1, outC: 1,
    size: 1, stride: 1, dilation: 1, groups: 1)
  var fixedWeights: array[1, int8]
  var fixedBiases: array[1, int8]
  var fixedOutput: array[1, int8]
  let fixed = blaiReferenceFixedParsedSingleLayer2d(
    fixedLayer,
    BlaiCpuExtraInputStorage(),
    layerIndex = 0,
    active = true,
    useTflite = false,
    input1 = [12'i8],
    input2 = [],
    cpuWeightBytes = [2'u8],
    cpuBiasBytes = [0'u8],
    weightCursor = blaiCpuStreamCursor(),
    biasCursor = blaiCpuStreamCursor(),
    decodedWeights = fixedWeights,
    decodedBiases = fixedBiases,
    output = fixedOutput)
  check("NPU model parsed single fixed diagnostics valid",
    fixed.active and fixed.supported and fixed.fits and
      fixed.weightStorageSupported and fixed.readiness.executed and
      fixed.referenceFirstBlock == blaiFixedLayerNoBlock and
      fixed.referenceConvBlock == blaiConvNoBlock)
  check("NPU model parsed single fixed diagnostics readiness block",
    fixed.readiness.referenceFirstBlock == fixed.referenceFirstBlock)
  checkEq("NPU model parsed single fixed diagnostics value",
    fixedOutput[0].uint32, 24)

  var fixedParsedLayers = [BlaiCpuParsedLayerState(
    active: true,
    index: 0,
    layer: fixedLayer)]
  var fixedParsedWeights: array[1, int8]
  var fixedParsedBiases: array[1, int8]
  var fixedParsedOutput: array[1, int8]
  let fixedParsed = blaiReferenceFixedParsedLayer2d(
    fixedParsedLayers,
    layerIndex = 0,
    useTflite = false,
    input1 = [12'i8],
    input2 = [],
    cpuWeightBytes = [2'u8],
    cpuBiasBytes = [0'u8],
    weightCursor = blaiCpuStreamCursor(),
    biasCursor = blaiCpuStreamCursor(),
    decodedWeights = fixedParsedWeights,
    decodedBiases = fixedParsedBiases,
    output = fixedParsedOutput)
  check("NPU model parsed layer fixed diagnostics valid",
    fixedParsed.active and fixedParsed.supported and fixedParsed.fits and
      fixedParsed.weightStorageSupported and
      fixedParsed.referenceFirstBlock == blaiFixedLayerNoBlock and
      fixedParsed.referenceConvBlock == blaiConvNoBlock)
  check("NPU model parsed layer fixed diagnostics reference block",
    fixedParsed.referenceFirstBlock == fixedParsed.reference.firstBlock and
      fixedParsed.referenceConvBlock == fixedParsed.reference.convBlock)

  var fixedShortWeights: array[1, int8]
  var fixedShortBiases: array[1, int8]
  var fixedShortOutput: array[1, int8]
  let fixedShort = blaiReferenceFixedParsedSingleLayer2d(
    fixedLayer,
    BlaiCpuExtraInputStorage(),
    layerIndex = 0,
    active = true,
    useTflite = false,
    input1 = [12'i8],
    input2 = [],
    cpuWeightBytes = [],
    cpuBiasBytes = [0'u8],
    weightCursor = blaiCpuStreamCursor(),
    biasCursor = blaiCpuStreamCursor(),
    decodedWeights = fixedShortWeights,
    decodedBiases = fixedShortBiases,
    output = fixedShortOutput)
  check("NPU model parsed single fixed diagnostics stream block",
    fixedShort.active and not fixedShort.streamsFit and
      not fixedShort.readiness.executed and
      fixedShort.readiness.referenceFirstBlock == blaiFixedLayerNoBlock)

  let tfliteLayer = BlaiCpuInstLayer64(
    layerType: ord(blaiConvolutional).int32,
    dspOn: 1,
    w: 1, h: 1, c: 1, outC: 1,
    size: 1, stride: 1, dilation: 1, groups: 1,
    tfOutputMultiplier: high(int32),
    quantizedActivationMax: 255)
  var tfliteBiases: array[1, int32]
  var tfliteOutput: array[1, uint8]
  let tflite = blaiReferenceTfliteParsedSingleLayer2d(
    tfliteLayer,
    BlaiCpuExtraInputStorage(),
    layerIndex = 0,
    active = true,
    useTflite = true,
    input1 = [3'u8],
    input2 = [],
    cpuWeightBytes = [4'u8],
    cpuBiasBytes = [0'u8, 0, 0, 0],
    weightCursor = blaiCpuStreamCursor(),
    biasCursor = blaiCpuStreamCursor(),
    decodedBiases = tfliteBiases,
    output = tfliteOutput)
  check("NPU model parsed single TFLite diagnostics valid",
    tflite.active and tflite.supported and tflite.fits and
      tflite.readiness.executed and
      tflite.referenceFirstBlock == blaiTfliteLayerNoBlock and
      tflite.referenceConvBlock == blaiTfliteScalarConvNoBlock)
  check("NPU model parsed single TFLite diagnostics readiness block",
    tflite.readiness.referenceFirstBlock == tflite.referenceFirstBlock)
  checkEq("NPU model parsed single TFLite diagnostics value",
    tfliteOutput[0].uint32, 12)

  var tfliteParsedLayers = [BlaiCpuParsedLayerState(
    active: true,
    index: 0,
    layer: tfliteLayer)]
  var tfliteParsedBiases: array[1, int32]
  var tfliteParsedOutput: array[1, uint8]
  let tfliteParsed = blaiReferenceTfliteParsedLayer2d(
    tfliteParsedLayers,
    layerIndex = 0,
    useTflite = true,
    input1 = [3'u8],
    input2 = [],
    cpuWeightBytes = [4'u8],
    cpuBiasBytes = [0'u8, 0, 0, 0],
    weightCursor = blaiCpuStreamCursor(),
    biasCursor = blaiCpuStreamCursor(),
    decodedBiases = tfliteParsedBiases,
    output = tfliteParsedOutput)
  check("NPU model parsed layer TFLite diagnostics valid",
    tfliteParsed.active and tfliteParsed.supported and tfliteParsed.fits and
      tfliteParsed.referenceFirstBlock == blaiTfliteLayerNoBlock and
      tfliteParsed.referenceConvBlock == blaiTfliteScalarConvNoBlock)
  check("NPU model parsed layer TFLite diagnostics reference block",
    tfliteParsed.referenceFirstBlock == tfliteParsed.reference.firstBlock and
      tfliteParsed.referenceConvBlock == tfliteParsed.reference.convBlock)

  var tfliteShortBiases: array[1, int32]
  var tfliteShortOutput: array[1, uint8]
  let tfliteShort = blaiReferenceTfliteParsedSingleLayer2d(
    tfliteLayer,
    BlaiCpuExtraInputStorage(),
    layerIndex = 0,
    active = true,
    useTflite = true,
    input1 = [3'u8],
    input2 = [],
    cpuWeightBytes = [],
    cpuBiasBytes = [0'u8, 0, 0, 0],
    weightCursor = blaiCpuStreamCursor(),
    biasCursor = blaiCpuStreamCursor(),
    decodedBiases = tfliteShortBiases,
    output = tfliteShortOutput)
  check("NPU model parsed single TFLite diagnostics stream block",
    tfliteShort.active and not tfliteShort.streamsFit and
      not tfliteShort.readiness.executed and
      tfliteShort.readiness.referenceFirstBlock == blaiTfliteLayerNoBlock)

proc checkFixedPreviousActivationShortcut() =
  var layers = [
    BlaiCpuParsedLayerState(
      active: true,
      index: 0,
      layer: BlaiCpuInstLayer64(
        layerType: ord(blaiConvolutional).int32,
        activation: ord(blaiActLinear).int32,
        dspOn: 1,
        dataType: 1,
        w: 2, h: 1, c: 1, outC: 1,
        size: 1, stride: 1, dilation: 1, groups: 1)),
    BlaiCpuParsedLayerState(
      active: true,
      index: 1,
      layer: BlaiCpuInstLayer64(
        layerType: ord(blaiShortcut).int32,
        activation: ord(blaiActLinear).int32,
        w: 2, h: 1, c: 1,
        froute1: 0, froute2: 0, fout: 0))]
  let inputs = [
    BlaiReferenceFixedParsedModelInput(),
    BlaiReferenceFixedParsedModelInput(secondInput: blaiRefFixedInputPrevious)]
  var weights: array[1, int8]
  var biases: array[1, int8]
  var scratchA: array[2, int8]
  var scratchB: array[2, int8]
  var output: array[2, int8]
  let checked = blaiReferenceFixedParsedCheckedModel2d(
    layers,
    useTflite = false,
    input = [1'i8, 2],
    layerInputs = inputs,
    cpuWeightBytes = [2'u8],
    cpuBiasBytes = [0'u8],
    decodedWeights = weights,
    decodedBiases = biases,
    scratchA = scratchA,
    scratchB = scratchB,
    output = output)
  check("NPU model fixed previous shortcut preflight",
    checked.preflight.fit.fits)
  check("NPU model fixed previous shortcut executed", checked.executed)
  check("NPU model fixed previous shortcut valid",
    checked.model.modelValid)
  checkEq("NPU model fixed previous shortcut completed",
    checked.model.completedLayerCount, 2)
  check("NPU model fixed previous shortcut streams",
    checked.model.allWeightsConsumed and checked.model.allBiasesConsumed)
  checkOutputCompare("NPU model fixed previous shortcut scratch",
    blaiCompareInt8Outputs([2'i8, 4], scratchA))
  checkOutputCompare("NPU model fixed previous shortcut output",
    blaiCompareInt8Outputs([4'i8, 8], output))

proc checkTflitePreviousActivationShortcut() =
  var layers = [
    BlaiCpuParsedLayerState(
      active: true,
      index: 0,
      layer: BlaiCpuInstLayer64(
        layerType: ord(blaiConvolutional).int32,
        dspOn: 1,
        w: 2, h: 1, c: 1, outC: 1,
        outW: 2, outH: 1,
        size: 1, stride: 1, dilation: 1, groups: 1,
        tfInput1Offset: 0,
        tfInput2Offset: 0,
        tfOutputOffset: 0,
        tfOutputMultiplier: high(int32),
        tfOutputShift: 0,
        quantizedActivationMin: 0,
        quantizedActivationMax: 255)),
    BlaiCpuParsedLayerState(
      active: true,
      index: 1,
      layer: BlaiCpuInstLayer64(
        layerType: ord(blaiShortcut).int32,
        w: 2, h: 1, c: 1,
        tfInput1Offset: 0,
        tfInput2Offset: 0,
        tfOutputOffset: 0,
        tfInput1Multiplier: high(int32),
        tfInput2Multiplier: high(int32),
        tfOutputMultiplier: high(int32),
        tfInput1Shift: -20,
        tfInput2Shift: -20,
        tfOutputShift: 0,
        quantizedActivationMin: 0,
        quantizedActivationMax: 255))]
  let inputs = [
    BlaiReferenceTfliteParsedModelInput(),
    BlaiReferenceTfliteParsedModelInput(secondInput: blaiRefInputPrevious)]
  var biases: array[1, int32]
  var scratchA: array[2, uint8]
  var scratchB: array[2, uint8]
  var output: array[2, uint8]
  let checked = blaiReferenceTfliteParsedCheckedModel2d(
    layers,
    useTflite = true,
    input = [1'u8, 2],
    layerInputs = inputs,
    cpuWeightBytes = [2'u8],
    cpuBiasBytes = [0'u8, 0, 0, 0],
    decodedBiases = biases,
    scratchA = scratchA,
    scratchB = scratchB,
    output = output)
  check("NPU model TFLite previous shortcut preflight",
    checked.preflight.fit.fits)
  check("NPU model TFLite previous shortcut executed", checked.executed)
  check("NPU model TFLite previous shortcut valid",
    checked.model.modelValid)
  checkEq("NPU model TFLite previous shortcut completed",
    checked.model.completedLayerCount, 2)
  check("NPU model TFLite previous shortcut streams",
    checked.model.allWeightsConsumed and checked.model.allBiasesConsumed)
  checkOutputCompare("NPU model TFLite previous shortcut scratch",
    blaiCompareUint8Outputs([2'u8, 4], scratchA))
  checkOutputCompare("NPU model TFLite previous shortcut output",
    blaiCompareUint8Outputs([4'u8, 8], output))

proc checkForwardRunSequence() =
  var preparedLayer = BlaiCpuInstLayer64(
    layerType: ord(blaiRouteConv).int32,
    w: 4,
    h: 4,
    c: 4,
    cn: [4'i32, 0, 0, 0, 0, 0, 0],
    outW: 4,
    outH: 4,
    outC: 4,
    inputNum: 2,
    groups: 1,
    stride: 1,
    dilation: 1,
    size: 3,
    activation: 2,
    midOut: 1,
    npuOn: 1,
    dramNWeight: 4,
    dramNBias: 4,
    tfInput1Offset: 120,
    tfInput2Offset: 121,
    tfOutputOffset: 122,
    tfOutputShift: -2,
    tfInput1Shift: -1,
    tfInput2Shift: 1,
    tfInput1Multiplier: 0x0102_0304'i32,
    tfInput2Multiplier: 0x1112_1314'i32,
    tfOutputMultiplier: 0x2122_2324'i32,
    quantizedActivationMin: 0,
    quantizedActivationMax: 255)
  var ctrl: BlaiPsramCtrl
  var stream: array[BlaiInstructionScratchSize div BlaiInstructionSize,
                    BlaiInstruction]
  let preparedWeightBufferBytes =
    blaiNpuPackedWeightBytes(preparedLayer, useTflite = true)
  let prepared = blaiPrepareForwardNpuLayer(
    preparedLayer, ctrl, stream, layerIndex = 0, useTflite = true,
    dataBufferBytes = 1024, instAddr = 0x2203_0000'u32,
    dataBufferAddr = 0x2204_0000'u32, weightAddr = 0x2205_0000'u32,
    biasAddr = 0x2205_0100'u32, weightBufferBytes = preparedWeightBufferBytes,
    biasBufferBytes = 16, c2 = 4, includeExtra = true)
  check("NPU model run prepared ready", prepared.ready)
  check("NPU model run prepared encoded", prepared.encoded)
  checkEq("NPU model run prepared first block none",
    ord(prepared.firstBlock).uint32, ord(blaiForwardPreparedRunNoBlock).uint32)

  var layers = [
    preparedLayer,
    BlaiCpuInstLayer64(
      layerType: ord(blaiRoute).int32,
      npuOn: 0,
      w: 1,
      h: 1,
      c: 1,
      outW: 1,
      outH: 1,
      outC: 1)]
  let resources = blaiPlanForwardModelResources(layers, useTflite = true)
  let workspace = blaiPlanForwardModelWorkspace(
    resources, baseAddress = 0x2207_0000'u32)
  let readiness = blaiForwardModelRunSequenceReadiness(resources, workspace)
  check("NPU model run readiness ready", readiness.ready)
  check("NPU model run readiness workspace", readiness.workspaceReady)

  let sequence = blaiPlanForwardModelRunSequence(
    layers, resources, workspace)
  check("NPU model run sequence configurable", sequence.allConfigurable)
  checkEq("NPU model run sequence first block none",
    ord(sequence.firstBlock).uint32, ord(blaiForwardModelRunSequenceNoBlock).uint32)
  checkEq("NPU model run sequence readiness first block none",
    ord(sequence.readinessFirstBlock).uint32,
    ord(blaiForwardModelRunSequenceReadinessNoBlock).uint32)
  checkEq("NPU model run sequence attempted", sequence.attemptedLayerCount, 1)
  checkEq("NPU model run sequence skipped", sequence.skippedLayerCount, 1)
  checkEq("NPU model run sequence cache ranges", sequence.cacheRangeCount, 4)
  checkEq("NPU model run sequence inst addr",
    sequence.lastRun.layerConfig.buffers.instAddr, workspace.instruction.address)
  checkEq("NPU model run sequence data addr",
    sequence.lastRun.layerConfig.inputBufferAddr, workspace.data.address)
  check("NPU model run sequence no blocked capture",
    not sequence.firstBlockedRunCaptured)

  var blockedWorkspace = workspace
  blockedWorkspace.weight.address = 0'u32
  let blockedSequence = blaiPlanForwardModelRunSequence(
    layers, resources, blockedWorkspace)
  check("NPU model run sequence blocked capture",
    blockedSequence.firstBlockedRunCaptured)
  check("NPU model run sequence configurability blocked capture",
    blockedSequence.configurability.firstBlockedRunCaptured)
  check("NPU model run sequence blocked not configurable",
    not blockedSequence.allConfigurable)
  check("NPU model run sequence blocked layer",
    blockedSequence.firstBlockedLayer == 0)
  check("NPU model run sequence blocked needs weights",
    blockedSequence.firstBlockedRunConfigReadiness.needsWeightBuffers)
  check("NPU model run sequence blocked missing weight",
    not blockedSequence.firstBlockedRunConfigReadiness.hasWeightBuffer)
  check("NPU model run sequence blocked bias present",
    blockedSequence.firstBlockedRunConfigReadiness.hasBiasBuffer)
  check("NPU model run sequence blocked weight readiness",
    not blockedSequence.firstBlockedRunConfigReadiness.weightBuffersReady)
  check("NPU model run sequence blocked config readiness",
    not blockedSequence.firstBlockedRunConfigReadiness.configurable)
  checkEq("NPU model run sequence blocked first block config",
    ord(blockedSequence.firstBlock).uint32,
    ord(blaiForwardModelRunSequenceRunConfig).uint32)
  checkEq("NPU model run sequence blocked config first block weight",
    ord(blockedSequence.firstBlockedRunConfigFirstBlock).uint32,
    ord(blaiForwardNpuRunConfigWeightBuffers).uint32)

  let states = [
    BlaiCpuParsedLayerState(active: true, index: 0, layer: layers[0]),
    BlaiCpuParsedLayerState(active: true, index: 1, layer: layers[1])]
  let stateSequence = blaiPlanForwardModelRunSequence(
    states, resources, workspace)
  check("NPU model run state sequence configurable",
    stateSequence.allConfigurable)
  checkEq("NPU model run state sequence attempted",
    stateSequence.attemptedLayerCount, 1)
  checkEq("NPU model run state sequence skipped",
    stateSequence.skippedLayerCount, 1)

  var weightDispatchLayer = BlaiCpuInstLayer64(
    layerType: ord(blaiConvolutional).int32,
    c: 4,
    outC: 3,
    size: 3,
    dilation: 1,
    groups: 1,
    tfInput2Offset: -7)
  var weightDispatchInput: array[512, int32]
  for i in 0 ..< weightDispatchInput.len:
    weightDispatchInput[i] = i.int32
  let weightDispatchPlan =
    blaiPlanNpuWeightLoad(weightDispatchLayer, useTflite = true)
  var weightDispatch3x3Buf: array[40, uint8]
  var weightDispatch3x3Cursor = 0'u32
  let weightDispatch3x3Ok = blaiNpuDumpWeightKernel(
    weightDispatchLayer, 0, 0, 0, 4, weightDispatchPlan, 2,
    weightBuf = weightDispatch3x3Buf,
    weightsIn = weightDispatchInput,
    weightCursor = weightDispatch3x3Cursor)
  var weightDispatchDilatedLayer = weightDispatchLayer
  weightDispatchDilatedLayer.dilation = 2
  let weightDispatchDilatedPlan =
    blaiPlanNpuWeightLoad(weightDispatchDilatedLayer, useTflite = true)
  var weightDispatchDilatedBuf: array[340, uint8]
  var weightDispatchDilatedCursor = 0'u32
  let weightDispatchDilatedOk = blaiNpuDumpWeightKernel(
    weightDispatchDilatedLayer, 0, 0, 0, 4, weightDispatchDilatedPlan, 2,
    weightBuf = weightDispatchDilatedBuf,
    weightsIn = weightDispatchInput,
    weightCursor = weightDispatchDilatedCursor)
  var weightDispatch5x5Layer = weightDispatchLayer
  weightDispatch5x5Layer.size = 5
  let weightDispatch5x5Plan =
    blaiPlanNpuWeightLoad(weightDispatch5x5Layer, useTflite = true)
  var weightDispatch5x5Buf: array[340, uint8]
  var weightDispatch5x5Cursor = 0'u32
  let weightDispatch5x5Ok = blaiNpuDumpWeightKernel(
    weightDispatch5x5Layer, 0, 0, 0, 4, weightDispatch5x5Plan, 2,
    weightBuf = weightDispatch5x5Buf,
    weightsIn = weightDispatchInput,
    weightCursor = weightDispatch5x5Cursor)
  var weightDispatch7x7Layer = weightDispatchLayer
  weightDispatch7x7Layer.size = 7
  let weightDispatch7x7Plan =
    blaiPlanNpuWeightLoad(weightDispatch7x7Layer, useTflite = true)
  var weightDispatch7x7Buf: array[340, uint8]
  var weightDispatch7x7Cursor = 0'u32
  let weightDispatch7x7Ok = blaiNpuDumpWeightKernel(
    weightDispatch7x7Layer, 0, 0, 0, 4, weightDispatch7x7Plan, 2,
    weightBuf = weightDispatch7x7Buf,
    weightsIn = weightDispatchInput,
    weightCursor = weightDispatch7x7Cursor)
  var unsupportedWeightDispatchLayer = weightDispatch5x5Layer
  unsupportedWeightDispatchLayer.dilation = 2
  let unsupportedWeightDispatchPlan =
    blaiPlanNpuWeightLoad(unsupportedWeightDispatchLayer, useTflite = true)
  var unsupportedWeightDispatchCursor = 7'u32
  let unsupportedWeightDispatchOk = blaiNpuDumpWeightKernel(
    unsupportedWeightDispatchLayer, 0, 0, 0, 4,
    unsupportedWeightDispatchPlan, 2,
    weightBuf = weightDispatch5x5Buf,
    weightsIn = weightDispatchInput,
    weightCursor = unsupportedWeightDispatchCursor)
  var zeroPackWeightDispatchCursor = 0'u32
  let zeroPackWeightDispatchOk = blaiNpuDumpWeightKernel(
    weightDispatchLayer, 0, 0, 0, 4, weightDispatchPlan, 0,
    weightBuf = weightDispatch3x3Buf,
    weightsIn = weightDispatchInput,
    weightCursor = zeroPackWeightDispatchCursor)
  var unalignedWeightDispatchCursor = 0'u32
  discard blaiNpuDumpWeightKernel(
    weightDispatch7x7Layer, 1, 0, 0, 4, weightDispatch7x7Plan, 2,
    weightBuf = weightDispatch7x7Buf,
    weightsIn = weightDispatchInput,
    weightCursor = unalignedWeightDispatchCursor)
  var shortWeightDispatchBuf: array[323, uint8]
  var shortWeightDispatchCursor = 0'u32
  let shortWeightDispatchOk = blaiNpuDumpWeightKernel(
    weightDispatch5x5Layer, 0, 0, 0, 4, weightDispatch5x5Plan, 2,
    weightBuf = shortWeightDispatchBuf,
    weightsIn = weightDispatchInput,
    weightCursor = shortWeightDispatchCursor)
  let weightKernelDispatchEvidence = blaiNpuWeightKernelDispatchEvidence(
    weightDispatch3x3Ok, weightDispatch3x3Cursor,
    weightDispatch3x3Buf[0], weightDispatch3x3Buf[35],
    weightDispatchDilatedOk, weightDispatchDilatedCursor,
    weightDispatchDilatedBuf[0], weightDispatchDilatedBuf[16],
    weightDispatch5x5Ok, weightDispatch5x5Cursor,
    weightDispatch5x5Buf[0], weightDispatch5x5Buf[323],
    weightDispatch7x7Ok, weightDispatch7x7Cursor,
    weightDispatch7x7Buf[0], weightDispatch7x7Buf[323],
    unsupportedWeightDispatchOk, unsupportedWeightDispatchCursor,
    zeroPackWeightDispatchOk, unalignedWeightDispatchCursor,
    shortWeightDispatchOk, shortWeightDispatchCursor)
  check("NPU model weight kernel dispatch evidence",
    weightKernelDispatchEvidence.valid)
  check("NPU model weight kernel dispatch 3x3",
    weightKernelDispatchEvidence.normal3x3Dispatched)
  check("NPU model weight kernel dispatch 3x3 dilated",
    weightKernelDispatchEvidence.dilated3x3Dispatched)
  check("NPU model weight kernel dispatch 5x5",
    weightKernelDispatchEvidence.kernel5x5Dispatched)
  check("NPU model weight kernel dispatch 7x7",
    weightKernelDispatchEvidence.kernel7x7Dispatched)
  check("NPU model weight kernel dispatch unsupported",
    weightKernelDispatchEvidence.unsupportedRejected)
  check("NPU model weight kernel dispatch zero pack",
    weightKernelDispatchEvidence.zeroPackRejected)
  check("NPU model weight kernel dispatch unaligned",
    weightKernelDispatchEvidence.unalignedNoCommit)
  check("NPU model weight kernel dispatch short buffer",
    weightKernelDispatchEvidence.shortBufferRejected)
  check("NPU model weight kernel dispatch first bytes",
    weightKernelDispatchEvidence.firstBytesMatch)
  check("NPU model weight kernel dispatch padding bytes",
    weightKernelDispatchEvidence.trailingPaddingMatches)
  check("NPU model weight kernel dispatch cursors",
    weightKernelDispatchEvidence.cursorPlanMatches)

  let execution = blaiExecuteForwardModelRunSequence(
    layers, resources, workspace, fakeForwardLayerExecutor)
  check("NPU model run execution runnable", execution.runnable)
  check("NPU model run execution complete", execution.allCompleted)
  checkEq("NPU model run execution attempted", execution.attemptedLayerCount, 1)
  checkEq("NPU model run execution completed",
    execution.completedLayerCount, 1)
  checkEq("NPU model run execution skipped", execution.skippedLayerCount, 1)
  check("NPU model run execution no first failure",
    not execution.firstFailedExecutionCaptured)
  checkEq("NPU model run execution first block none",
    ord(execution.firstBlock).uint32,
    ord(blaiForwardModelExecuteNoBlock).uint32)
  checkEq("NPU model run execution sequence first block none",
    ord(execution.runSequenceFirstBlock).uint32,
    ord(blaiForwardModelRunSequenceNoBlock).uint32)
  check("NPU model run execution wait configured",
    execution.lastExecution.waitPlan.configured)
  checkEq("NPU model run execution wait timeout",
    execution.lastExecution.waitPlan.timeout, 5_000_000)
  checkEq("NPU model run execution status",
    execution.lastExecution.status.uint32, npuOk.uint32)

  let stateExecution = blaiExecuteForwardModelRunSequence(
    states, resources, workspace, fakeForwardLayerExecutor)
  check("NPU model run state execution complete",
    stateExecution.allCompleted)
  checkEq("NPU model run state execution completed",
    stateExecution.completedLayerCount, 1)

  var missingLayers: array[0, BlaiCpuInstLayer64]
  let missingExecution = blaiExecuteForwardModelRunSequence(
    missingLayers, resources, workspace, fakeForwardLayerExecutor)
  check("NPU model run missing blocked", not missingExecution.runnable)
  checkEq("NPU model run missing count", missingExecution.missingLayerCount, 2)
  checkEq("NPU model run missing first block storage",
    ord(missingExecution.firstBlock).uint32,
    ord(blaiForwardModelExecuteLayerStorage).uint32)

  let failedExecution = blaiExecuteForwardModelRunSequence(
    layers, resources, workspace, failingForwardLayerExecutor)
  check("NPU model run failing incomplete", not failedExecution.allCompleted)
  checkEq("NPU model run failing count", failedExecution.failedLayerCount, 1)
  checkEq("NPU model run failing first block execution",
    ord(failedExecution.firstBlock).uint32,
    ord(blaiForwardModelExecuteLayerExecution).uint32)
  checkEq("NPU model run failing first",
    failedExecution.firstFailedLayer.uint32, 0)
  check("NPU model run failing captured",
    failedExecution.firstFailedExecutionCaptured)
  checkEq("NPU model run failing first status",
    failedExecution.firstFailedExecution.status.uint32, npuTimeout.uint32)
  check("NPU model run failing wait configured",
    failedExecution.firstFailedExecution.waitPlan.configured)
  checkEq("NPU model run failing wait timeout",
    failedExecution.firstFailedExecution.waitPlan.timeout, 5_000_000)
  checkEq("NPU model run failing status",
    failedExecution.lastExecution.status.uint32, npuTimeout.uint32)

proc checkForwardWorkspaceExecution() =
  var layer = BlaiCpuInstLayer64(
    layerType: ord(blaiRouteConv).int32,
    w: 4,
    h: 4,
    c: 4,
    cn: [4'i32, 0, 0, 0, 0, 0, 0],
    outW: 4,
    outH: 4,
    outC: 4,
    inputNum: 2,
    groups: 1,
    stride: 1,
    dilation: 1,
    size: 3,
    activation: 2,
    midOut: 1,
    npuOn: 1,
    dspOn: 1,
    dramNWeight: 288,
    dramNBias: 4,
    tfInput1Offset: 120,
    tfInput2Offset: 121,
    tfOutputOffset: 122,
    tfOutputShift: -2,
    tfInput1Shift: -1,
    tfInput2Shift: 1,
    tfInput1Multiplier: 0x0102_0304'i32,
    tfInput2Multiplier: 0x1112_1314'i32,
    tfOutputMultiplier: 0x2122_2324'i32,
    quantizedActivationMin: 0,
    quantizedActivationMax: 255)
  let resourceLayers = [layer]
  let resources = blaiPlanForwardModelResources(
    resourceLayers, useTflite = true)
  var resourceFit: BlaiForwardModelResourceFitResult
  blaiForwardModelResourcesFitInto(
    resources, resources.instructionBytes, resources.dataBufferBytes,
    resources.weightBufferBytes, resources.biasBufferBytes,
    resources.temporaryWeightElements, resources.cpuWeightStreamBytes,
    resources.cpuBiasStreamBytes, resourceFit)
  checkEq("NPU model resource first block none",
    ord(resourceFit.firstBlock).uint32,
    ord(blaiForwardModelResourceNoBlock).uint32)
  checkEq("NPU model resource readiness first block none",
    ord(resourceFit.readiness.firstBlock).uint32,
    ord(blaiForwardModelResourceNoBlock).uint32)
  var shortCpuWeightFit: BlaiForwardModelResourceFitResult
  blaiForwardModelResourcesFitInto(
    resources, resources.instructionBytes, resources.dataBufferBytes,
    resources.weightBufferBytes, resources.biasBufferBytes,
    resources.temporaryWeightElements, resources.cpuWeightStreamBytes - 1,
    resources.cpuBiasStreamBytes, shortCpuWeightFit)
  checkEq("NPU model resource first block CPU weights",
    ord(shortCpuWeightFit.firstBlock).uint32,
    ord(blaiForwardModelResourceCpuWeights).uint32)
  checkEq("NPU model resource readiness first block CPU weights",
    ord(shortCpuWeightFit.readiness.firstBlock).uint32,
    ord(blaiForwardModelResourceCpuWeights).uint32)
  let workspace = blaiPlanForwardModelWorkspace(
    resources, baseAddress = 0x2208_0000'u32)
  var workspaceFit: BlaiForwardWorkspaceFitResult
  blaiForwardWorkspaceFitsInto(workspace, workspace.totalBytes, workspaceFit)
  checkEq("NPU model workspace first block none",
    ord(workspaceFit.firstBlock).uint32,
    ord(blaiForwardWorkspaceNoBlock).uint32)
  checkEq("NPU model workspace readiness first block none",
    ord(workspaceFit.readiness.firstBlock).uint32,
    ord(blaiForwardWorkspaceNoBlock).uint32)
  var liveWorkspaceBytes {.align: 16.}: array[2048, uint8]
  var liveBindingInto: BlaiForwardWorkspaceBufferBinding
  blaiBindForwardWorkspaceBufferInto(resources, liveWorkspaceBytes,
    liveBindingInto)
  let liveBinding = blaiBindForwardWorkspaceBuffer(
    resources, liveWorkspaceBytes)
  let ocramProjection = blaiProjectHardwareAddress(0x6202_0010'u)
  let wramProjection = blaiProjectHardwareAddress(0x6203_0020'u)
  let unsupportedProjection = blaiProjectHardwareAddress(0x6201_0000'u)
  check("NPU model workspace address projection OCRAM",
    ocramProjection.projected and ocramProjection.addressFits and
      ocramProjection.alias == blaiHardwareAddressOcramCached and
      ocramProjection.hardwareAddress == 0x2202_0010'u32)
  check("NPU model workspace address projection WRAM",
    wramProjection.projected and wramProjection.addressFits and
      wramProjection.alias == blaiHardwareAddressWramCached and
      wramProjection.hardwareAddress == 0x2203_0020'u32)
  check("NPU model workspace address projection unsupported",
    not unsupportedProjection.projected and
      not unsupportedProjection.addressFits and
      unsupportedProjection.alias == blaiHardwareAddressUnsupported)
  check("NPU model workspace bind into equal", liveBindingInto == liveBinding)
  let liveAddressUsable =
    liveBinding.addressAvailable and liveBinding.addressFits
  check("NPU model workspace bind address gate",
    liveAddressUsable or
      liveBinding.firstBlock == blaiForwardWorkspaceBufferBindAddress)
  check("NPU model workspace bind state typed",
    (liveBinding.bound and liveAddressUsable) or
      ((not liveBinding.bound) and
        liveBinding.firstBlock == blaiForwardWorkspaceBufferBindAddress))
  if liveBinding.bound:
    checkEq("NPU model workspace bind first block",
      ord(liveBinding.firstBlock).uint32,
      ord(blaiForwardWorkspaceBufferBindNoBlock).uint32)
    checkEq("NPU model workspace bind fit first block",
      ord(liveBinding.workspaceFirstBlock).uint32,
      ord(blaiForwardWorkspaceNoBlock).uint32)
    checkEq("NPU model workspace bind data offset",
      liveBinding.workspace.data.offset, resources.instructionBytes)
    check("NPU model workspace bind hardware base",
      liveBinding.bound and liveBinding.firstBlock ==
        blaiForwardWorkspaceBufferBindNoBlock)
  else:
    checkEq("NPU model workspace bind first block",
      ord(liveBinding.firstBlock).uint32,
      ord(blaiForwardWorkspaceBufferBindAddress).uint32)
    check("NPU model workspace bind fit first block", true)
    check("NPU model workspace bind data offset", true)
    check("NPU model workspace bind hardware base", true)

  var shortLiveWorkspace {.align: 16.}: array[64, uint8]
  let shortBinding = blaiBindForwardWorkspaceBuffer(
    resources, shortLiveWorkspace)
  check("NPU model workspace bind short blocked",
    not shortBinding.bound)
  checkEq("NPU model workspace bind short first block",
    ord(shortBinding.firstBlock).uint32,
    (if liveAddressUsable:
      ord(blaiForwardWorkspaceBufferBindWorkspace).uint32
     else:
      ord(blaiForwardWorkspaceBufferBindAddress).uint32))

  var emptyWorkspace: array[0, uint8]
  let emptyBinding = blaiBindForwardWorkspaceBuffer(resources, emptyWorkspace)
  check("NPU model workspace bind empty blocked",
    not emptyBinding.bound and not emptyBinding.addressAvailable)
  checkEq("NPU model workspace bind empty first block",
    ord(emptyBinding.firstBlock).uint32,
    ord(blaiForwardWorkspaceBufferBindBuffer).uint32)
  var clearWorkspaceBytes: array[2048, uint8]
  let clearWorkspace = blaiClearForwardModelWorkspace(
    workspace, clearWorkspaceBytes)
  checkEq("NPU model workspace clear first block none",
    ord(clearWorkspace.firstBlock).uint32,
    ord(blaiForwardWorkspaceClearNoBlock).uint32)
  checkEq("NPU model workspace clear fit first block none",
    ord(clearWorkspace.workspaceFitFirstBlock).uint32,
    ord(blaiForwardWorkspaceNoBlock).uint32)
  var instructionStoreStream: array[2, BlaiInstruction]
  instructionStoreStream[0][0] = 0x11'u8
  instructionStoreStream[1][15] = 0x22'u8
  let instructionStore = blaiStoreForwardInstructionsInWorkspace(
    workspace, instructionStoreStream, 2, clearWorkspaceBytes)
  checkEq("NPU model instruction workspace first block none",
    ord(instructionStore.firstBlock).uint32,
    ord(blaiForwardInstructionWorkspaceNoBlock).uint32)
  checkEq("NPU model instruction workspace readiness first block none",
    ord(instructionStore.readiness.firstBlock).uint32,
    ord(blaiForwardInstructionWorkspaceNoBlock).uint32)
  let shortInstructionStoreStream = blaiStoreForwardInstructionsInWorkspace(
    workspace, instructionStoreStream, 3, clearWorkspaceBytes)
  checkEq("NPU model instruction workspace first block stream",
    ord(shortInstructionStoreStream.firstBlock).uint32,
    ord(blaiForwardInstructionWorkspaceStream).uint32)
  var shortInstructionWorkspace = workspace
  shortInstructionWorkspace.instruction.bytes = 16
  let shortInstructionStoreSegment = blaiStoreForwardInstructionsInWorkspace(
    shortInstructionWorkspace, instructionStoreStream, 2, clearWorkspaceBytes)
  checkEq("NPU model instruction workspace first block segment",
    ord(shortInstructionStoreSegment.firstBlock).uint32,
    ord(blaiForwardInstructionWorkspaceSegment).uint32)
  var shortInstructionBytes: array[16, uint8]
  let shortInstructionStoreBuffer = blaiStoreForwardInstructionsInWorkspace(
    workspace, instructionStoreStream, 1, shortInstructionBytes)
  checkEq("NPU model instruction workspace first block buffer",
    ord(shortInstructionStoreBuffer.firstBlock).uint32,
    ord(blaiForwardInstructionWorkspaceBuffer).uint32)
  var layers = [
    layer,
    BlaiCpuInstLayer64(layerType: ord(blaiRoute).int32, npuOn: 0, dspOn: 1)]
  var ctrl: BlaiPsramCtrl
  var stream: array[BlaiInstructionScratchSize div BlaiInstructionSize,
                    BlaiInstruction]
  var workspaceBytes: array[2048, uint8]
  var cpuWeights: array[288, uint8]
  for i in 0 ..< cpuWeights.len:
    cpuWeights[i] = i.uint8
  let cpuBiases = [
    1'u8, 0, 0, 0,
    2'u8, 0, 0, 0,
    3'u8, 0, 0, 0,
    4'u8, 0, 0, 0]
  var decodedWeights: array[288, int32]
  var decodedBiases: array[4, int32]
  var npuWeights: array[288, uint8]
  var npuBiases: array[4, int32]
  var temporaryWeights: array[0, int32]

  let execution = blaiMaterializeAndExecuteForwardModelWorkspace(
    layers, useTflite = true, ctrl = ctrl, stream = stream,
    modelResources = resources, workspace = workspace,
    workspaceBytes = workspaceBytes, cpuWeightBytes = cpuWeights,
    cpuBiasBytes = cpuBiases, decodedWeights = decodedWeights,
    decodedBiases = decodedBiases, npuWeightBytes = npuWeights,
    npuBiases = npuBiases, temporaryWeights = temporaryWeights,
    executor = fakeForwardLayerExecutor, pack = 4, c2 = 4,
    includeExtra = true)
  check("NPU model workspace execute runnable", execution.runnable)
  check("NPU model workspace execute complete", execution.allCompleted)
  check("NPU model workspace execute backed",
    execution.readiness.workspaceBacked)
  checkEq("NPU model workspace execute first block none",
    ord(execution.firstBlock).uint32,
    ord(blaiForwardModelWorkspaceExecuteNoBlock).uint32)
  checkEq("NPU model workspace execute readiness first block none",
    ord(execution.readinessFirstBlock).uint32,
    ord(blaiForwardModelWorkspaceExecuteReadinessNoBlock).uint32)
  checkEq("NPU model workspace execute materialized",
    execution.materializedLayerCount, 1)
  checkEq("NPU model workspace execute completed",
    execution.completedLayerCount, 1)
  checkEq("NPU model workspace execute skipped",
    execution.skippedLayerCount, 1)
  checkEq("NPU model workspace execute weight cursor",
    execution.nextWeightCursor.byteOffset, 288)
  checkEq("NPU model workspace execute bias cursor",
    execution.nextBiasCursor.byteOffset, 16)
  check("NPU model workspace execute instruction stored",
    blaiForwardWorkspaceSegmentByteEquals(
      workspace.instruction, workspaceBytes, 0, stream[0][0]))
  checkEq("NPU model layer instruction workspace first block none",
    ord(execution.lastLayer.instructions.firstBlock).uint32,
    ord(blaiForwardLayerInstructionWorkspaceNoBlock).uint32)
  checkEq("NPU model layer instruction workspace store first block none",
    ord(execution.lastLayer.instructions.instructionFirstBlock).uint32,
    ord(blaiForwardInstructionWorkspaceNoBlock).uint32)
  checkEq("NPU model layer workspace first block none",
    ord(execution.lastLayer.firstBlock).uint32,
    ord(blaiForwardLayerWorkspaceMaterializeNoBlock).uint32)
  checkEq("NPU model layer workspace instruction first block none",
    ord(execution.lastLayer.instructionFirstBlock).uint32,
    ord(blaiForwardLayerInstructionWorkspaceNoBlock).uint32)
  checkEq("NPU model layer workspace weight first block none",
    ord(execution.lastLayer.weightWorkspaceFirstBlock).uint32,
    ord(blaiForwardWeightWorkspaceNoBlock).uint32)
  checkEq("NPU model workspace materialize first block none",
    ord(execution.lastLayer.firstBlock).uint32,
    ord(blaiForwardLayerWorkspaceMaterializeNoBlock).uint32)
  check("NPU model workspace execute weight stored",
    blaiForwardWorkspaceSegmentByteEquals(
      workspace.weight, workspaceBytes, 0, npuWeights[0]))
  checkEq("NPU model workspace execute bias stored",
    (if blaiForwardWorkspaceSegmentByteEquals(
      workspace.bias, workspaceBytes, 0, 1'u8): 1'u32 else: 0'u32), 1)
  checkEq("NPU model workspace execute status",
    execution.lastExecution.status.uint32, npuOk.uint32)

  var missingLayers: array[0, BlaiCpuInstLayer64]
  var missingCtrl: BlaiPsramCtrl
  var missingStream: array[BlaiInstructionScratchSize div BlaiInstructionSize,
                           BlaiInstruction]
  var missingWorkspaceBytes: array[2048, uint8]
  var missingDecodedWeights: array[288, int32]
  var missingDecodedBiases: array[4, int32]
  var missingNpuWeights: array[288, uint8]
  var missingNpuBiases: array[4, int32]
  var missingTemporaryWeights: array[0, int32]
  let missing = blaiMaterializeAndExecuteForwardModelWorkspace(
    missingLayers, useTflite = true, ctrl = missingCtrl,
    stream = missingStream, modelResources = resources, workspace = workspace,
    workspaceBytes = missingWorkspaceBytes, cpuWeightBytes = cpuWeights,
    cpuBiasBytes = cpuBiases, decodedWeights = missingDecodedWeights,
    decodedBiases = missingDecodedBiases, npuWeightBytes = missingNpuWeights,
    npuBiases = missingNpuBiases, temporaryWeights = missingTemporaryWeights,
    executor = fakeForwardLayerExecutor, pack = 4, c2 = 4,
    includeExtra = true)
  check("NPU model workspace missing blocked", not missing.runnable)
  checkEq("NPU model workspace missing count", missing.missingLayerCount, 1)

  var failedLayers = [layer]
  var failedCtrl: BlaiPsramCtrl
  var failedStream: array[BlaiInstructionScratchSize div BlaiInstructionSize,
                          BlaiInstruction]
  var failedWorkspaceBytes: array[2048, uint8]
  var failedDecodedWeights: array[288, int32]
  var failedDecodedBiases: array[4, int32]
  var failedNpuWeights: array[288, uint8]
  var failedNpuBiases: array[4, int32]
  var failedTemporaryWeights: array[0, int32]
  let failed = blaiMaterializeAndExecuteForwardModelWorkspace(
    failedLayers, useTflite = true, ctrl = failedCtrl,
    stream = failedStream, modelResources = resources, workspace = workspace,
    workspaceBytes = failedWorkspaceBytes, cpuWeightBytes = cpuWeights,
    cpuBiasBytes = cpuBiases, decodedWeights = failedDecodedWeights,
    decodedBiases = failedDecodedBiases, npuWeightBytes = failedNpuWeights,
    npuBiases = failedNpuBiases, temporaryWeights = failedTemporaryWeights,
    executor = failingForwardLayerExecutor, pack = 4, c2 = 4,
    includeExtra = true)
  check("NPU model workspace failing incomplete", not failed.allCompleted)
  checkEq("NPU model workspace failing first block execution",
    ord(failed.firstBlock).uint32,
    ord(blaiForwardModelWorkspaceExecuteLayerExecution).uint32)
  checkEq("NPU model workspace failing materialized",
    failed.materializedLayerCount, 1)
  checkEq("NPU model workspace failing count", failed.failedLayerCount, 1)
  check("NPU model workspace failing captured",
    failed.firstFailedExecutionCaptured)
  checkEq("NPU model workspace failing first status",
    failed.firstFailedExecution.status.uint32, npuTimeout.uint32)
  check("NPU model workspace failing wait configured",
    failed.firstFailedExecution.waitPlan.configured)
  checkEq("NPU model workspace failing wait timeout",
    failed.firstFailedExecution.waitPlan.timeout, 5_000_000)
  checkEq("NPU model workspace failing status",
    failed.lastExecution.status.uint32, npuTimeout.uint32)

  var shortLayers = [layer]
  var shortCtrl: BlaiPsramCtrl
  var shortStream: array[BlaiInstructionScratchSize div BlaiInstructionSize,
                         BlaiInstruction]
  var shortWorkspaceBytes: array[16, uint8]
  var shortWorkspaceFit: BlaiForwardWorkspaceFitResult
  blaiForwardWorkspaceFitsInto(
    workspace, shortWorkspaceBytes.len.uint32, shortWorkspaceFit)
  checkEq("NPU model workspace first block instruction",
    ord(shortWorkspaceFit.firstBlock).uint32,
    ord(blaiForwardWorkspaceInstruction).uint32)
  checkEq("NPU model workspace readiness first block instruction",
    ord(shortWorkspaceFit.readiness.firstBlock).uint32,
    ord(blaiForwardWorkspaceInstruction).uint32)
  var shortClearWorkspaceBytes: array[16, uint8]
  let shortClearWorkspace = blaiClearForwardModelWorkspace(
    workspace, shortClearWorkspaceBytes)
  checkEq("NPU model workspace clear first block buffer",
    ord(shortClearWorkspace.firstBlock).uint32,
    ord(blaiForwardWorkspaceClearBuffer).uint32)
  checkEq("NPU model workspace clear fit first block instruction",
    ord(shortClearWorkspace.workspaceFitFirstBlock).uint32,
    ord(blaiForwardWorkspaceInstruction).uint32)
  var shortDecodedWeights: array[288, int32]
  var shortDecodedBiases: array[4, int32]
  var shortNpuWeights: array[288, uint8]
  var shortNpuBiases: array[4, int32]
  var shortTemporaryWeights: array[0, int32]
  let shortWorkspace = blaiMaterializeAndExecuteForwardModelWorkspace(
    shortLayers, useTflite = true, ctrl = shortCtrl, stream = shortStream,
    modelResources = resources, workspace = workspace,
    workspaceBytes = shortWorkspaceBytes, cpuWeightBytes = cpuWeights,
    cpuBiasBytes = cpuBiases, decodedWeights = shortDecodedWeights,
    decodedBiases = shortDecodedBiases, npuWeightBytes = shortNpuWeights,
    npuBiases = shortNpuBiases, temporaryWeights = shortTemporaryWeights,
    executor = fakeForwardLayerExecutor, pack = 4, c2 = 4,
    includeExtra = true)
  check("NPU model workspace short blocked", shortWorkspace.runnable)
  check("NPU model workspace short backed",
    not shortWorkspace.readiness.workspaceBacked)
  checkEq("NPU model workspace short readiness first block workspace",
    ord(shortWorkspace.readinessFirstBlock).uint32,
    ord(blaiForwardModelWorkspaceExecuteReadinessWorkspace).uint32)
  checkEq("NPU model workspace short first block materialization",
    ord(shortWorkspace.firstBlock).uint32,
    ord(blaiForwardModelWorkspaceExecuteMaterialization).uint32)
  checkEq("NPU model workspace short attempted",
    shortWorkspace.attemptedLayerCount, 1)
  checkEq("NPU model workspace short blocked count",
    shortWorkspace.blockedLayerCount, 1)
  check("NPU model workspace short blocked captured",
    shortWorkspace.firstBlockedLayerCaptured)
  check("NPU model workspace short blocked layer",
    not shortWorkspace.firstBlockedLayerReadiness.ready)
  checkEq("NPU model workspace short blocked first block",
    ord(shortWorkspace.firstBlockedLayerReadiness.firstBlock).uint32,
    ord(blaiForwardLayerWorkspaceMaterializeInstructions).uint32)
  checkEq("NPU model workspace short blocked instruction first block",
    ord(shortWorkspace.firstBlockedLayerReadiness.instructionFirstBlock).uint32,
    ord(blaiForwardLayerInstructionWorkspaceStorage).uint32)

proc checkForwardWorkspaceFixtureValidation() =
  var layer = BlaiCpuInstLayer64(
    layerType: ord(blaiRouteConv).int32,
    w: 4,
    h: 4,
    c: 4,
    cn: [4'i32, 0, 0, 0, 0, 0, 0],
    outW: 4,
    outH: 4,
    outC: 4,
    dramIn: [0'i32, 0, 0, 0, 0, 0, 0, 0],
    dramOut: [1'i32, 0, 0, 0, 0, 0, 0, 0],
    dramPatchSize: 4,
    inputNum: 2,
    groups: 1,
    stride: 1,
    dilation: 1,
    size: 3,
    activation: 2,
    midOut: 1,
    npuOn: 1,
    dspOn: 1,
    dramNWeight: 288,
    dramNBias: 4,
    tfInput1Offset: 120,
    tfInput2Offset: 121,
    tfOutputOffset: 122,
    tfOutputShift: -2,
    tfInput1Shift: -1,
    tfInput2Shift: 1,
    tfInput1Multiplier: 0x0102_0304'i32,
    tfInput2Multiplier: 0x1112_1314'i32,
    tfOutputMultiplier: 0x2122_2324'i32,
    quantizedActivationMin: 0,
    quantizedActivationMax: 255)
  var layers = [layer]
  let resources = blaiPlanForwardModelResources(layers, useTflite = true)
  let tensorLayer = BlaiCpuInstLayer64(
    layerType: ord(blaiConvolutional).int32,
    npuOn: 1,
    w: 1,
    h: 1,
    c: 1,
    outW: 1,
    outH: 1,
    outC: 1,
    dramIn: [0'i32, 0, 0, 0, 0, 0, 0, 0],
    dramOut: [1'i32, 0, 0, 0, 0, 0, 0, 0],
    dramPatchSize: 4)
  let tensorPlan = blaiPlanForwardNpu(
    tensorLayer, layerIndex = 0, dataBufferBytes = resources.dataBufferBytes)
  var workspaceBytes {.align: 16.}: array[2048, uint8]
  let binding = blaiBindForwardWorkspaceBuffer(resources, workspaceBytes)
  if binding.bound:
    discard blaiWriteForwardWorkspaceSegmentByte(
      binding.workspace.data, workspaceBytes, 4, 55)
  var explicitZeroAddressBinding: BlaiForwardWorkspaceBufferBinding
  blaiBindForwardWorkspaceAddressInto(
    resources, 0'u32, blaiBufferLenU32(workspaceBytes.len),
    explicitZeroAddressBinding)
  let explicitZeroAddress =
    blaiBindForwardWorkspaceAddress(
      resources, 0'u32, blaiBufferLenU32(workspaceBytes.len))
  check("NPU model workspace explicit address into equal",
    explicitZeroAddressBinding.bound == explicitZeroAddress.bound and
      explicitZeroAddressBinding.firstBlock == explicitZeroAddress.firstBlock)
  checkEq("NPU model workspace explicit zero address block",
    ord(explicitZeroAddress.firstBlock).uint32,
    ord(blaiForwardWorkspaceBufferBindAddress).uint32)
  var fixtureZeroAddressBinding: BlaiForwardWorkspaceBufferBinding
  blaiBindForwardWorkspaceFixtureAddressInto(
    resources, 0'u32, blaiBufferLenU32(workspaceBytes.len),
    fixtureZeroAddressBinding)
  let fixtureZeroAddress =
    blaiBindForwardWorkspaceFixtureAddress(
      resources, 0'u32, blaiBufferLenU32(workspaceBytes.len))
  let fixtureZeroAddressReadiness =
    blaiForwardWorkspaceHardwareAddressReadiness(fixtureZeroAddress)
  check("NPU model workspace fixture zero address into equal",
    fixtureZeroAddressBinding.bound == fixtureZeroAddress.bound and
      fixtureZeroAddressBinding.firstBlock == fixtureZeroAddress.firstBlock)
  check("NPU model workspace fixture zero address bound",
    fixtureZeroAddress.bound)
  checkEq("NPU model workspace fixture zero address block",
    ord(fixtureZeroAddress.firstBlock).uint32,
    ord(blaiForwardWorkspaceBufferBindNoBlock).uint32)
  check("NPU model workspace fixture zero address readiness block",
    not fixtureZeroAddressReadiness.ready and
      fixtureZeroAddressReadiness.firstBlock ==
        blaiForwardWorkspaceHardwareAddressInstruction)
  let explicitAddress = blaiBindForwardWorkspaceAddress(
    resources, 0x2202_0000'u32, blaiBufferLenU32(workspaceBytes.len))
  let explicitAddressReadiness =
    blaiForwardWorkspaceHardwareAddressReadiness(explicitAddress)
  check("NPU model workspace explicit address bound",
    explicitAddress.bound)
  checkEq("NPU model workspace explicit address first block",
    ord(explicitAddress.firstBlock).uint32,
    ord(blaiForwardWorkspaceBufferBindNoBlock).uint32)
  check("NPU model workspace explicit address readiness",
    explicitAddressReadiness.ready)

  var ctrl: BlaiPsramCtrl
  var stream: array[BlaiInstructionScratchSize div BlaiInstructionSize,
                    BlaiInstruction]
  var cpuWeights: array[288, uint8]
  for i in 0 ..< cpuWeights.len:
    cpuWeights[i] = i.uint8
  let cpuBiases = [
    1'u8, 0, 0, 0,
    2'u8, 0, 0, 0,
    3'u8, 0, 0, 0,
    4'u8, 0, 0, 0]
  var decodedWeights: array[288, int32]
  var decodedBiases: array[4, int32]
  var npuWeights: array[288, uint8]
  var npuBiases: array[4, int32]
  var temporaryWeights: array[0, int32]
  var input: array[1, uint8]
  var expectedOutput: array[1, uint8]
  input[0] = 9
  expectedOutput[0] = 55
  var output: array[1, uint8]
  var intoResult: BlaiForwardWorkspaceFixtureValidationResult
  blaiValidateForwardWorkspaceFixtureInto(
    layers, useTflite = true, modelResources = resources,
    tensorPlan = tensorPlan, inputIndex = 0, input = input,
    expectedOutput = expectedOutput, output = output, ctrl = ctrl,
    stream = stream, workspaceBytes = workspaceBytes,
    cpuWeightBytes = cpuWeights, cpuBiasBytes = cpuBiases,
    decodedWeights = decodedWeights, decodedBiases = decodedBiases,
    npuWeightBytes = npuWeights, npuBiases = npuBiases,
    temporaryWeights = temporaryWeights, executor = fakeForwardLayerExecutor,
    outResult = intoResult, pack = 4, c2 = 4, includeExtra = true)

  if binding.bound:
    discard blaiWriteForwardWorkspaceSegmentByte(
      binding.workspace.data, workspaceBytes, 4, 55)
  var wrappedOutput: array[1, uint8]
  let wrapped = blaiValidateForwardWorkspaceFixture(
    layers, useTflite = true, modelResources = resources,
    tensorPlan = tensorPlan, inputIndex = 0, input = input,
    expectedOutput = expectedOutput, output = wrappedOutput, ctrl = ctrl,
    stream = stream, workspaceBytes = workspaceBytes,
    cpuWeightBytes = cpuWeights, cpuBiasBytes = cpuBiases,
    decodedWeights = decodedWeights, decodedBiases = decodedBiases,
    npuWeightBytes = npuWeights, npuBiases = npuBiases,
    temporaryWeights = temporaryWeights, executor = fakeForwardLayerExecutor,
    pack = 4, c2 = 4, includeExtra = true)
  var rawReadinessInto:
    BlaiForwardWorkspaceFixtureValidationReadiness
  blaiForwardWorkspaceFixtureValidationReadinessInto(
    wrapped, rawReadinessInto)
  let rawReadiness =
    blaiForwardWorkspaceFixtureValidationReadiness(wrapped)
  check("NPU model workspace fixture into equal",
    intoResult.valid == wrapped.valid and
      intoResult.firstBlock == wrapped.firstBlock)
  check("NPU model workspace fixture readiness into equal",
    rawReadinessInto == rawReadiness)
  check("NPU model workspace fixture readiness matches",
    rawReadiness.valid == wrapped.valid and
      rawReadiness.firstBlock == wrapped.firstBlock)
  check("NPU model workspace fixture readiness address",
    rawReadiness.hardwareAddressFirstBlock ==
      wrapped.hardwareAddressFirstBlock)
  check("NPU model workspace fixture output readiness",
    rawReadiness.outputReadiness.valid == wrapped.output.valid and
      rawReadiness.outputReadiness.firstBlock == wrapped.output.firstBlock)
  check("NPU model workspace fixture output evidence",
    rawReadiness.outputMatched == wrapped.output.validation.outputMatched and
      rawReadiness.expectedElements ==
        rawReadiness.outputReadiness.expectedElements and
      rawReadiness.actualElements ==
        rawReadiness.outputReadiness.actualElements and
      rawReadiness.comparedElements == wrapped.output.comparedElements and
      rawReadiness.trailingElements ==
        rawReadiness.outputReadiness.trailingElements and
      rawReadiness.lengthMatches ==
        rawReadiness.outputReadiness.lengthMatches and
      rawReadiness.mismatchCount == wrapped.output.mismatchCount and
      rawReadiness.firstMismatch == wrapped.output.firstMismatch)
  check("NPU model workspace fixture classified",
    wrapped.valid or
      wrapped.firstBlock == blaiForwardWorkspaceFixtureValidationBinding or
      wrapped.firstBlock ==
        blaiForwardWorkspaceFixtureValidationHardwareAddresses)
  if wrapped.valid:
    checkEq("NPU model workspace fixture first block",
      ord(wrapped.firstBlock).uint32,
      ord(blaiForwardWorkspaceFixtureValidationNoBlock).uint32)
    checkEq("NPU model workspace fixture address block",
      ord(wrapped.hardwareAddressFirstBlock).uint32,
      ord(blaiForwardWorkspaceHardwareAddressNoBlock).uint32)
    checkEq("NPU model workspace fixture output block",
      ord(wrapped.outputFirstBlock).uint32,
      ord(blaiForwardWorkspaceOutputValidationNoBlock).uint32)
  elif wrapped.firstBlock ==
      blaiForwardWorkspaceFixtureValidationHardwareAddresses:
    checkEq("NPU model workspace fixture first block",
      ord(wrapped.firstBlock).uint32,
      ord(blaiForwardWorkspaceFixtureValidationHardwareAddresses).uint32)
    check("NPU model workspace fixture address block",
      wrapped.hardwareAddressFirstBlock !=
        blaiForwardWorkspaceHardwareAddressNoBlock)
    check("NPU model workspace fixture output block", true)
  else:
    checkEq("NPU model workspace fixture first block",
      ord(wrapped.firstBlock).uint32,
      ord(blaiForwardWorkspaceFixtureValidationBinding).uint32)
    check("NPU model workspace fixture address block", true)
    check("NPU model workspace fixture output block", true)

  var shortWorkspace {.align: 16.}: array[64, uint8]
  var shortOutput: array[1, uint8]
  let short = blaiValidateForwardWorkspaceFixture(
    layers, useTflite = true, modelResources = resources,
    tensorPlan = tensorPlan, inputIndex = 0, input = input,
    expectedOutput = expectedOutput, output = shortOutput, ctrl = ctrl,
    stream = stream, workspaceBytes = shortWorkspace,
    cpuWeightBytes = cpuWeights, cpuBiasBytes = cpuBiases,
    decodedWeights = decodedWeights, decodedBiases = decodedBiases,
    npuWeightBytes = npuWeights, npuBiases = npuBiases,
    temporaryWeights = temporaryWeights, executor = fakeForwardLayerExecutor,
    pack = 4, c2 = 4, includeExtra = true)
  checkEq("NPU model workspace fixture short first block",
    ord(short.firstBlock).uint32,
    ord(blaiForwardWorkspaceFixtureValidationBinding).uint32)

proc checkForwardWorkspaceAddressFixtureValidation() =
  var layer = BlaiCpuInstLayer64(
    layerType: ord(blaiRouteConv).int32,
    w: 4,
    h: 4,
    c: 4,
    cn: [4'i32, 0, 0, 0, 0, 0, 0],
    outW: 4,
    outH: 4,
    outC: 4,
    dramIn: [0'i32, 0, 0, 0, 0, 0, 0, 0],
    dramOut: [1'i32, 0, 0, 0, 0, 0, 0, 0],
    dramPatchSize: 4,
    inputNum: 2,
    groups: 1,
    stride: 1,
    dilation: 1,
    size: 3,
    activation: 2,
    midOut: 1,
    npuOn: 1,
    dspOn: 1,
    dramNWeight: 288,
    dramNBias: 4,
    tfInput1Offset: 120,
    tfInput2Offset: 121,
    tfOutputOffset: 122,
    tfOutputShift: -2,
    tfInput1Shift: -1,
    tfInput2Shift: 1,
    tfInput1Multiplier: 0x0102_0304'i32,
    tfInput2Multiplier: 0x1112_1314'i32,
    tfOutputMultiplier: 0x2122_2324'i32,
    quantizedActivationMin: 0,
    quantizedActivationMax: 255)
  var layers = [layer]
  let resources = blaiPlanForwardModelResources(layers, useTflite = true)
  let tensorLayer = BlaiCpuInstLayer64(
    layerType: ord(blaiConvolutional).int32,
    npuOn: 1,
    w: 1,
    h: 1,
    c: 1,
    outW: 1,
    outH: 1,
    outC: 1,
    dramIn: [0'i32, 0, 0, 0, 0, 0, 0, 0],
    dramOut: [1'i32, 0, 0, 0, 0, 0, 0, 0],
    dramPatchSize: 4)
  let tensorPlan = blaiPlanForwardNpu(
    tensorLayer, layerIndex = 0, dataBufferBytes = resources.dataBufferBytes)
  var workspaceBytes {.align: 16.}: array[2048, uint8]
  let seed = blaiBindForwardWorkspaceAddress(
    resources, 0x2202_0000'u32, blaiBufferLenU32(workspaceBytes.len))
  if seed.bound:
    discard blaiWriteForwardWorkspaceSegmentByte(
      seed.workspace.data, workspaceBytes, 4, 55)
  var ctrl: BlaiPsramCtrl
  var stream: array[BlaiInstructionScratchSize div BlaiInstructionSize,
                    BlaiInstruction]
  var cpuWeights: array[288, uint8]
  for i in 0 ..< cpuWeights.len:
    cpuWeights[i] = i.uint8
  let cpuBiases = [
    1'u8, 0, 0, 0,
    2'u8, 0, 0, 0,
    3'u8, 0, 0, 0,
    4'u8, 0, 0, 0]
  var decodedWeights: array[288, int32]
  var decodedBiases: array[4, int32]
  var npuWeights: array[288, uint8]
  var npuBiases: array[4, int32]
  var temporaryWeights: array[0, int32]
  var input: array[1, uint8]
  var expectedOutput: array[1, uint8]
  input[0] = 9
  expectedOutput[0] = 55
  var outputInto: array[1, uint8]
  var intoResult: BlaiForwardWorkspaceFixtureValidationResult
  blaiValidateForwardWorkspaceAddressFixtureInto(
    layers, useTflite = true, modelResources = resources,
    workspaceBaseAddress = 0x2202_0000'u32, tensorPlan = tensorPlan,
    inputIndex = 0, input = input, expectedOutput = expectedOutput,
    output = outputInto, ctrl = ctrl, stream = stream,
    workspaceBytes = workspaceBytes, cpuWeightBytes = cpuWeights,
    cpuBiasBytes = cpuBiases, decodedWeights = decodedWeights,
    decodedBiases = decodedBiases, npuWeightBytes = npuWeights,
    npuBiases = npuBiases, temporaryWeights = temporaryWeights,
    executor = fakeForwardLayerExecutor, outResult = intoResult,
    pack = 4, c2 = 4, includeExtra = true)
  if seed.bound:
    discard blaiWriteForwardWorkspaceSegmentByte(
      seed.workspace.data, workspaceBytes, 4, 55)
  var output: array[1, uint8]
  let fixture = blaiValidateForwardWorkspaceAddressFixture(
    layers, useTflite = true, modelResources = resources,
    workspaceBaseAddress = 0x2202_0000'u32, tensorPlan = tensorPlan,
    inputIndex = 0, input = input, expectedOutput = expectedOutput,
    output = output, ctrl = ctrl, stream = stream,
    workspaceBytes = workspaceBytes, cpuWeightBytes = cpuWeights,
    cpuBiasBytes = cpuBiases, decodedWeights = decodedWeights,
    decodedBiases = decodedBiases, npuWeightBytes = npuWeights,
    npuBiases = npuBiases, temporaryWeights = temporaryWeights,
    executor = fakeForwardLayerExecutor, pack = 4, c2 = 4,
    includeExtra = true)
  check("NPU model workspace explicit fixture into equal",
    intoResult.valid == fixture.valid and
      intoResult.firstBlock == fixture.firstBlock)
  check("NPU model workspace explicit fixture valid", fixture.valid)
  checkEq("NPU model workspace explicit fixture first block",
    ord(fixture.firstBlock).uint32,
    ord(blaiForwardWorkspaceFixtureValidationNoBlock).uint32)
  checkEq("NPU model workspace explicit fixture address block",
    ord(fixture.hardwareAddressFirstBlock).uint32,
    ord(blaiForwardWorkspaceHardwareAddressNoBlock).uint32)

proc buildFixedWorkspaceOracleReferenceWithOutput(
    outReference: var BlaiReferenceFixedParsedCheckedModelResult,
    outFixedOutput: var openArray[int8],
    outExpected: var openArray[uint8],
    outProjection: var BlaiInt8OutputRawByteProjectionResult) =
  var fixedOracleLayers = [
    BlaiCpuParsedLayerState(
      active: true,
      index: 0,
      layer: BlaiCpuInstLayer64(
        layerType: ord(blaiConvolutional).int32,
        activation: ord(blaiActLinear).int32,
        dspOn: 1,
        dataType: 1,
        w: 1, h: 1, c: 1, outC: 1,
        outW: 1, outH: 1,
        size: 1, stride: 1, dilation: 1, groups: 1))]
  var fixedOracleWeights: array[1, int8]
  var fixedOracleBiases: array[1, int8]
  var fixedOracleScratchA: array[1, int8]
  var fixedOracleScratchB: array[1, int8]
  outReference = blaiReferenceFixedParsedCheckedModel2d(
    fixedOracleLayers,
    useTflite = false,
    input = [33'i8],
    cpuWeightBytes = [2'u8],
    cpuBiasBytes = [0'u8],
    decodedWeights = fixedOracleWeights,
    decodedBiases = fixedOracleBiases,
    scratchA = fixedOracleScratchA,
    scratchB = fixedOracleScratchB,
    output = outFixedOutput)
  blaiProjectInt8OutputRawBytesInto(
    outFixedOutput, outExpected, outProjection)

proc buildFixedWorkspaceOracleReference(
    outReference: var BlaiReferenceFixedParsedCheckedModelResult,
    outExpected: var openArray[uint8],
    outProjection: var BlaiInt8OutputRawByteProjectionResult) =
  var fixedOutput: array[1, int8]
  buildFixedWorkspaceOracleReferenceWithOutput(
    outReference, fixedOutput, outExpected, outProjection)

proc checkTfliteWorkspaceRawProjection(expected, actual: openArray[uint8]) =
  var projectedInto: array[1, uint8]
  var projectionInto: BlaiUint8OutputRawByteProjectionResult
  blaiProjectUint8OutputRawBytesInto(expected, projectedInto, projectionInto)
  var projected: array[1, uint8]
  let projection = blaiProjectUint8OutputRawBytes(expected, projected)
  check("NPU model TFLite workspace raw projection valid",
    projectionInto.projected == projection.projected and
      projectionInto.firstBlock == projection.firstBlock and
      projection.projected and
      projection.firstBlock == blaiUint8OutputRawByteProjectionNoBlock and
      projection.copiedElements == expected.len.uint32 and
      projected[0] == expected[0])
  let compare = blaiCompareUint8Outputs(projected, actual)
  check("NPU model TFLite workspace raw compare valid",
    compare.matched and compare.mismatchCount == 0)
  var shortProjected: array[0, uint8]
  let shortProjection =
    blaiProjectUint8OutputRawBytes(expected, shortProjected)
  check("NPU model TFLite workspace raw projection short blocked",
    shortProjection.firstBlock ==
      blaiUint8OutputRawByteProjectionOutputTooShort and
      shortProjection.expectedElements == expected.len.uint32 and
      shortProjection.outputElements == 0 and
      shortProjection.trailingElements == expected.len.uint32)
  let mismatchCompare =
    blaiCompareUint8Outputs(projected, [expected[0] xor 0x01'u8])
  check("NPU model TFLite workspace raw mismatch diagnosed",
    mismatchCompare.firstMismatch == 0 and
      mismatchCompare.expectedAtFirstMismatch == expected[0] and
      mismatchCompare.actualAtFirstMismatch == (expected[0] xor 0x01'u8))

proc checkFixedWorkspaceRawCompare(actual: openArray[uint8]) =
  var reference: BlaiReferenceFixedParsedCheckedModelResult
  var fixedOutput: array[1, int8]
  var expected: array[1, uint8]
  var projection: BlaiInt8OutputRawByteProjectionResult
  buildFixedWorkspaceOracleReferenceWithOutput(
    reference, fixedOutput, expected, projection)
  var compareInto: BlaiInt8OutputRawByteCompareResult
  var projectedInto: array[1, uint8]
  blaiCompareInt8OutputRawBytesInto(
    fixedOutput, actual, projectedInto, compareInto)
  var projected: array[1, uint8]
  let compare = blaiCompareInt8OutputRawBytes(
    fixedOutput, actual, projected)
  check("NPU model fixed workspace raw compare into equal",
    compareInto.valid == compare.valid and
      compareInto.firstBlock == compare.firstBlock)
  check("NPU model fixed workspace raw compare valid", compare.valid)
  checkEq("NPU model fixed workspace raw compare first block",
    compare.firstBlock.uint32,
    blaiInt8OutputRawByteCompareNoBlock.uint32)
  checkEq("NPU model fixed workspace raw compare projection block",
    compare.projectionFirstBlock.uint32,
    blaiInt8OutputRawByteProjectionNoBlock.uint32)
  checkEq("NPU model fixed workspace raw compare mismatches",
    compare.mismatchCount, 0)
  var shortProjected: array[0, uint8]
  let shortCompare = blaiCompareInt8OutputRawBytes(
    fixedOutput, actual, shortProjected)
  checkEq("NPU model fixed workspace raw compare short block",
    shortCompare.firstBlock.uint32,
    blaiInt8OutputRawByteCompareProjection.uint32)
  checkEq("NPU model fixed workspace raw compare short expected",
    shortCompare.projectionExpectedElements, 1)
  checkEq("NPU model fixed workspace raw compare short output",
    shortCompare.projectionOutputElements, 0)
  checkEq("NPU model fixed workspace raw compare short trailing",
    shortCompare.projectionTrailingElements, 1)
  var negativeProjected: array[1, uint8]
  let negativeProjection = blaiProjectInt8OutputRawBytes(
    [-1'i8], negativeProjected)
  checkEq("NPU model fixed raw byte negative value",
    negativeProjected[0].uint32, 0xFF)
  checkEq("NPU model fixed raw byte negative block",
    negativeProjection.firstBlock.uint32,
    blaiInt8OutputRawByteProjectionNoBlock.uint32)
  var negativeCompareExpected: array[1, uint8]
  let negativeCompare = blaiCompareInt8OutputRawBytes(
    [-1'i8], [0xFF'u8], negativeCompareExpected)
  check("NPU model fixed raw byte negative compare", negativeCompare.valid)
  var mismatchExpected: array[1, uint8]
  let mismatchCompare = blaiCompareInt8OutputRawBytes(
    [-1'i8], [0xFE'u8], mismatchExpected)
  checkEq("NPU model fixed raw byte mismatch block",
    mismatchCompare.firstBlock.uint32,
    blaiInt8OutputRawByteCompareMismatch.uint32)
  checkEq("NPU model fixed raw byte mismatch expected",
    mismatchCompare.compare.expectedAtFirstMismatch.uint32, 0xFF)
  checkEq("NPU model fixed raw byte mismatch actual",
    mismatchCompare.compare.actualAtFirstMismatch.uint32, 0xFE)
  checkEq("NPU model fixed raw byte mismatch index",
    mismatchCompare.firstMismatch.uint32, 0)
  checkEq("NPU model fixed raw byte mismatch top expected",
    mismatchCompare.expectedAtFirstMismatch.uint32, 0xFF)
  checkEq("NPU model fixed raw byte mismatch top actual",
    mismatchCompare.actualAtFirstMismatch.uint32, 0xFE)
  var trailingExpected: array[1, uint8]
  let trailingCompare = blaiCompareInt8OutputRawBytes(
    [-1'i8], [0xFF'u8, 0'u8], trailingExpected)
  checkEq("NPU model fixed raw byte trailing block",
    trailingCompare.firstBlock.uint32,
    blaiInt8OutputRawByteCompareMismatch.uint32)
  checkEq("NPU model fixed raw byte trailing count",
    trailingCompare.trailingElements, 1)
  checkEq("NPU model fixed raw byte trailing index",
    trailingCompare.firstMismatch.uint32, 1)

proc checkParsedForwardWorkspaceExecution() =
  var layer = BlaiCpuInstLayer64(
    layerType: ord(blaiRouteConv).int32,
    w: 4,
    h: 4,
    c: 4,
    cn: [4'i32, 0, 0, 0, 0, 0, 0],
    outW: 4,
    outH: 4,
    outC: 4,
    inputNum: 2,
    groups: 1,
    stride: 1,
    dilation: 1,
    size: 3,
    activation: 2,
    midOut: 1,
    npuOn: 1,
    dspOn: 1,
    dramNWeight: 288,
    dramNBias: 4,
    tfInput1Offset: 120,
    tfInput2Offset: 121,
    tfOutputOffset: 122,
    tfOutputShift: -2,
    tfInput1Shift: -1,
    tfInput2Shift: 1,
    tfInput1Multiplier: 0x0102_0304'i32,
    tfInput2Multiplier: 0x1112_1314'i32,
    tfOutputMultiplier: 0x2122_2324'i32,
    quantizedActivationMin: 0,
    quantizedActivationMax: 255)
  var seedCtrl: BlaiPsramCtrl
  var seedStream: array[BlaiInstructionScratchSize div BlaiInstructionSize,
                        BlaiInstruction]
  let seeded = blaiEncodeCpuLayerWithAllocator(
    layer, seedCtrl, seedStream, useTflite = true, c2 = 4,
    includeExtra = true)
  if seeded.encoded:
    blaiApplyMemoryPlan(layer, seedCtrl)
  check("NPU model parsed workspace seeded", seeded.encoded)
  var states = [
    BlaiCpuParsedLayerState(active: true, index: 0, layer: layer),
    BlaiCpuParsedLayerState(
      active: true,
      index: 1,
      layer: BlaiCpuInstLayer64(
        layerType: ord(blaiRoute).int32,
        npuOn: 0,
        dspOn: 1))]
  let parsed = BlaiCpuModelParseResult(
    hasHeader: true,
    useTflite: true,
    complete: true,
    declaredLayerCount: 2,
    parsedLayerCount: 2,
    storedLayerCount: 2)
  let resources = blaiPlanForwardModelResources([layer], useTflite = true)
  let plan = blaiPlanParsedForwardModelWorkspace(
    parsed, states, baseAddress = 0x2209_0000'u32)
  var ctrl: BlaiPsramCtrl
  var stream: array[BlaiInstructionScratchSize div BlaiInstructionSize,
                    BlaiInstruction]
  var workspaceBytes: array[2048, uint8]
  var cpuWeights: array[288, uint8]
  for i in 0 ..< cpuWeights.len:
    cpuWeights[i] = i.uint8
  let cpuBiases = [
    1'u8, 0, 0, 0,
    2'u8, 0, 0, 0,
    3'u8, 0, 0, 0,
    4'u8, 0, 0, 0]
  var decodedWeights: array[288, int32]
  var decodedBiases: array[4, int32]
  var npuWeights: array[288, uint8]
  var npuBiases: array[4, int32]
  var temporaryWeights: array[0, int32]

  check("NPU model parsed workspace plan ready", plan.workspaceReady)
  checkEq("NPU model parsed workspace resources",
    resources.npuLayerCount, 1)
  let readiness = blaiParsedForwardModelExecuteReadiness(
    parsed, plan, workspaceBytes.len.uint32, states.len.uint32)
  check("NPU model parsed workspace executable", readiness.executable)
  check("NPU model parsed workspace storage", readiness.layerStorageFits)
  checkEq("NPU model parsed workspace first block none",
    readiness.firstBlock.uint32, blaiParsedForwardModelExecuteNoBlock.uint32)

  let execution = blaiMaterializeAndExecuteParsedForwardModelWorkspace(
    parsed, states, plan, ctrl, stream, workspaceBytes,
    cpuWeightBytes = cpuWeights, cpuBiasBytes = cpuBiases,
    decodedWeights = decodedWeights, decodedBiases = decodedBiases,
    npuWeightBytes = npuWeights, npuBiases = npuBiases,
    temporaryWeights = temporaryWeights, executor = fakeForwardLayerExecutor,
    pack = 4, c2 = 4, includeExtra = true)
  check("NPU model parsed workspace runnable", execution.execution.runnable)
  check("NPU model parsed workspace complete",
    execution.execution.allCompleted)
  checkEq("NPU model parsed workspace materialized",
    execution.execution.materializedLayerCount, 1)
  checkEq("NPU model parsed workspace skipped",
    execution.execution.skippedLayerCount, 1)
  checkEq("NPU model parsed workspace completed",
    execution.execution.completedLayerCount, 1)
  checkEq("NPU model parsed workspace weight cursor",
    execution.execution.nextWeightCursor.byteOffset, 288)
  checkEq("NPU model parsed workspace bias cursor",
    execution.execution.nextBiasCursor.byteOffset, 16)
  check("NPU model parsed workspace instruction stored",
    blaiForwardWorkspaceSegmentByteEquals(
      plan.workspace.instruction, workspaceBytes, 0, stream[0][0]))
  checkEq("NPU model parsed workspace status",
    execution.execution.lastExecution.status.uint32, npuOk.uint32)
  checkEq("NPU model parsed workspace execution first block none",
    execution.firstBlock.uint32, blaiParsedForwardModelExecuteNoBlock.uint32)

  let parsedTensorLayer = BlaiCpuInstLayer64(
    layerType: ord(blaiConvolutional).int32,
    npuOn: 1,
    w: 1,
    h: 1,
    c: 1,
    outW: 1,
    outH: 1,
    outC: 1,
    dramIn: [0'i32, 0, 0, 0, 0, 0, 0, 0],
    dramOut: [1'i32, 0, 0, 0, 0, 0, 0, 0],
    dramPatchSize: 4)
  let parsedTensorPlan = blaiPlanForwardNpu(
    parsedTensorLayer, layerIndex = 0,
    dataBufferBytes = plan.resources.dataBufferBytes)
  var parsedFixtureWorkspace {.align: 16.}: array[2048, uint8]
  let parsedFixtureBinding = blaiBindForwardWorkspaceBuffer(
    plan.resources, parsedFixtureWorkspace)
  if parsedFixtureBinding.bound:
    discard blaiWriteForwardWorkspaceSegmentByte(
      parsedFixtureBinding.workspace.data, parsedFixtureWorkspace, 4, 66)
  var parsedFixtureInput: array[1, uint8]
  var parsedFixtureExpected: array[1, uint8]
  var parsedFixtureOutput: array[1, uint8]
  parsedFixtureInput[0] = 7
  parsedFixtureExpected[0] = 66
  var parsedFixtureCtrl: BlaiPsramCtrl
  var parsedFixtureStream:
    array[BlaiInstructionScratchSize div BlaiInstructionSize, BlaiInstruction]
  var parsedFixtureDecodedWeights: array[288, int32]
  var parsedFixtureDecodedBiases: array[4, int32]
  var parsedFixtureNpuWeights: array[288, uint8]
  var parsedFixtureNpuBiases: array[4, int32]
  var parsedFixtureTemporaryWeights: array[0, int32]
  var parsedFixtureInto:
    BlaiParsedForwardWorkspaceFixtureValidationResult
  blaiValidateParsedForwardWorkspaceFixtureInto(
    parsed, states, plan, parsedTensorPlan, inputIndex = 0,
    input = parsedFixtureInput, expectedOutput = parsedFixtureExpected,
    output = parsedFixtureOutput, ctrl = parsedFixtureCtrl,
    stream = parsedFixtureStream, workspaceBytes = parsedFixtureWorkspace,
    cpuWeightBytes = cpuWeights, cpuBiasBytes = cpuBiases,
    decodedWeights = parsedFixtureDecodedWeights,
    decodedBiases = parsedFixtureDecodedBiases,
    npuWeightBytes = parsedFixtureNpuWeights,
    npuBiases = parsedFixtureNpuBiases,
    temporaryWeights = parsedFixtureTemporaryWeights,
    executor = fakeForwardLayerExecutor, outResult = parsedFixtureInto,
    pack = 4, c2 = 4, includeExtra = true)
  if parsedFixtureBinding.bound:
    discard blaiWriteForwardWorkspaceSegmentByte(
      parsedFixtureBinding.workspace.data, parsedFixtureWorkspace, 4, 66)
  var parsedFixtureWrappedOutput: array[1, uint8]
  let parsedFixture = blaiValidateParsedForwardWorkspaceFixture(
    parsed, states, plan, parsedTensorPlan, inputIndex = 0,
    input = parsedFixtureInput, expectedOutput = parsedFixtureExpected,
    output = parsedFixtureWrappedOutput, ctrl = parsedFixtureCtrl,
    stream = parsedFixtureStream, workspaceBytes = parsedFixtureWorkspace,
    cpuWeightBytes = cpuWeights, cpuBiasBytes = cpuBiases,
    decodedWeights = parsedFixtureDecodedWeights,
    decodedBiases = parsedFixtureDecodedBiases,
    npuWeightBytes = parsedFixtureNpuWeights,
    npuBiases = parsedFixtureNpuBiases,
    temporaryWeights = parsedFixtureTemporaryWeights,
    executor = fakeForwardLayerExecutor, pack = 4, c2 = 4,
    includeExtra = true)
  var parsedReadinessInto:
    BlaiParsedForwardWorkspaceFixtureValidationReadiness
  blaiParsedForwardWorkspaceFixtureValidationReadinessInto(
    parsedFixture, parsedReadinessInto)
  let parsedReadiness =
    blaiParsedForwardWorkspaceFixtureValidationReadiness(parsedFixture)
  check("NPU model parsed workspace fixture into equal",
    parsedFixtureInto.valid == parsedFixture.valid and
      parsedFixtureInto.firstBlock == parsedFixture.firstBlock)
  check("NPU model parsed workspace fixture readiness into equal",
    parsedReadinessInto == parsedReadiness)
  check("NPU model parsed workspace fixture readiness matches",
    parsedReadiness.valid == parsedFixture.valid and
      parsedReadiness.firstBlock == parsedFixture.firstBlock)
  check("NPU model parsed workspace fixture readiness address",
    parsedReadiness.hardwareAddressFirstBlock ==
      parsedFixture.hardwareAddressFirstBlock)
  check("NPU model parsed workspace fixture output readiness",
    parsedReadiness.outputReadiness.valid == parsedFixture.output.valid and
      parsedReadiness.outputReadiness.firstBlock == parsedFixture.output.firstBlock)
  check("NPU model parsed workspace fixture output evidence",
    parsedReadiness.outputMatched ==
      parsedFixture.output.validation.outputMatched and
      parsedReadiness.expectedElements ==
        parsedReadiness.outputReadiness.expectedElements and
      parsedReadiness.actualElements ==
        parsedReadiness.outputReadiness.actualElements and
      parsedReadiness.comparedElements == parsedFixture.output.comparedElements and
      parsedReadiness.trailingElements ==
        parsedReadiness.outputReadiness.trailingElements and
      parsedReadiness.lengthMatches ==
        parsedReadiness.outputReadiness.lengthMatches and
      parsedReadiness.mismatchCount == parsedFixture.output.mismatchCount and
      parsedReadiness.firstMismatch == parsedFixture.output.firstMismatch)
  check("NPU model parsed workspace fixture classified",
    parsedFixture.valid or
      parsedFixture.firstBlock ==
        blaiParsedForwardWorkspaceFixtureValidationBinding or
      parsedFixture.firstBlock ==
        blaiParsedForwardWorkspaceFixtureValidationHardwareAddresses)
  if parsedFixture.valid:
    checkEq("NPU model parsed workspace fixture first block",
      parsedFixture.firstBlock.uint32,
      blaiParsedForwardWorkspaceFixtureValidationNoBlock.uint32)
    checkEq("NPU model parsed workspace fixture address block",
      parsedFixture.hardwareAddressFirstBlock.uint32,
      blaiForwardWorkspaceHardwareAddressNoBlock.uint32)
  elif parsedFixture.firstBlock ==
      blaiParsedForwardWorkspaceFixtureValidationHardwareAddresses:
    checkEq("NPU model parsed workspace fixture first block",
      parsedFixture.firstBlock.uint32,
      blaiParsedForwardWorkspaceFixtureValidationHardwareAddresses.uint32)
    check("NPU model parsed workspace fixture address block",
      parsedFixture.hardwareAddressFirstBlock !=
        blaiForwardWorkspaceHardwareAddressNoBlock)
  else:
    checkEq("NPU model parsed workspace fixture first block",
      parsedFixture.firstBlock.uint32,
      blaiParsedForwardWorkspaceFixtureValidationBinding.uint32)
    check("NPU model parsed workspace fixture address block", true)

  var missingStates: array[0, BlaiCpuParsedLayerState]
  let missingReadiness = blaiParsedForwardModelExecuteReadiness(
    parsed, plan, workspaceBytes.len.uint32, missingStates.len.uint32)
  check("NPU model parsed workspace missing blocked",
    not missingReadiness.executable)
  checkEq("NPU model parsed workspace missing count",
    missingReadiness.missingLayerCount, 2)
  checkEq("NPU model parsed workspace missing first block forward",
    missingReadiness.firstBlock.uint32,
    blaiParsedForwardModelExecuteForward.uint32)

  var failedCtrl: BlaiPsramCtrl
  var failedStream: array[BlaiInstructionScratchSize div BlaiInstructionSize,
                          BlaiInstruction]
  var failedWorkspaceBytes: array[2048, uint8]
  var failedDecodedWeights: array[288, int32]
  var failedDecodedBiases: array[4, int32]
  var failedNpuWeights: array[288, uint8]
  var failedNpuBiases: array[4, int32]
  var failedTemporaryWeights: array[0, int32]
  let failed = blaiMaterializeAndExecuteParsedForwardModelWorkspace(
    parsed, states, plan, failedCtrl, failedStream, failedWorkspaceBytes,
    cpuWeightBytes = cpuWeights, cpuBiasBytes = cpuBiases,
    decodedWeights = failedDecodedWeights, decodedBiases = failedDecodedBiases,
    npuWeightBytes = failedNpuWeights, npuBiases = failedNpuBiases,
    temporaryWeights = failedTemporaryWeights,
    executor = failingForwardLayerExecutor, pack = 4, c2 = 4,
    includeExtra = true)
  check("NPU model parsed workspace failing incomplete",
    not failed.execution.allCompleted)
  checkEq("NPU model parsed workspace failing count",
    failed.execution.failedLayerCount, 1)
  check("NPU model parsed workspace failing captured",
    failed.execution.firstFailedExecutionCaptured)
  checkEq("NPU model parsed workspace failing first status",
    failed.execution.firstFailedExecution.status.uint32, npuTimeout.uint32)
  check("NPU model parsed workspace failing wait configured",
    failed.execution.firstFailedExecution.waitPlan.configured)
  checkEq("NPU model parsed workspace failing wait timeout",
    failed.execution.firstFailedExecution.waitPlan.timeout, 5_000_000)
  checkEq("NPU model parsed workspace failing status",
    failed.execution.lastExecution.status.uint32, npuTimeout.uint32)

proc checkParsedForwardWorkspaceAddressFixtureValidation() =
  var oracleLayers = [
    BlaiCpuParsedLayerState(
      active: true,
      index: 0,
      layer: BlaiCpuInstLayer64(
        layerType: ord(blaiConvolutional).int32,
        dspOn: 1,
        w: 1, h: 1, c: 1, outC: 1,
        outW: 1, outH: 1,
        size: 1, stride: 1, dilation: 1, groups: 1,
        tfInput1Offset: 0,
        tfInput2Offset: 0,
        tfOutputOffset: 0,
        tfOutputMultiplier: high(int32),
        tfOutputShift: 0,
        quantizedActivationMin: 0,
        quantizedActivationMax: 255))]
  var oracleBiases: array[1, int32]
  var oracleScratchA: array[1, uint8]
  var oracleScratchB: array[1, uint8]
  var oracleOutput: array[1, uint8]
  let oracleReference = blaiReferenceTfliteParsedCheckedModel2d(
    oracleLayers,
    useTflite = true,
    input = [33'u8],
    cpuWeightBytes = [2'u8],
    cpuBiasBytes = [0'u8, 0, 0, 0],
    decodedBiases = oracleBiases,
    scratchA = oracleScratchA,
    scratchB = oracleScratchB,
    output = oracleOutput)
  check("NPU model parsed workspace oracle reference valid",
    oracleReference.executed and oracleReference.model.modelValid)
  var fixedOracleReference: BlaiReferenceFixedParsedCheckedModelResult
  var fixedOracleExpected: array[1, uint8]
  var fixedOracleProjection: BlaiInt8OutputRawByteProjectionResult
  buildFixedWorkspaceOracleReference(
    fixedOracleReference, fixedOracleExpected, fixedOracleProjection)
  check("NPU model fixed workspace oracle reference valid",
    fixedOracleReference.executed and
      fixedOracleReference.model.modelValid)
  check("NPU model fixed workspace oracle projection valid",
    fixedOracleProjection.projected)
  checkEq("NPU model fixed workspace oracle projection block",
    fixedOracleProjection.firstBlock.uint32,
    blaiInt8OutputRawByteProjectionNoBlock.uint32)
  checkEq("NPU model fixed workspace oracle projection count",
    fixedOracleProjection.convertedElements, 1)
  checkEq("NPU model fixed workspace oracle expected byte",
    fixedOracleExpected[0].uint32, oracleOutput[0].uint32)
  var shortFixedOracleExpected: array[0, uint8]
  let shortFixedProjection = blaiProjectInt8OutputRawBytes(
    [1'i8], shortFixedOracleExpected)
  checkEq("NPU model fixed workspace oracle projection short block",
    shortFixedProjection.firstBlock.uint32,
    blaiInt8OutputRawByteProjectionOutputTooShort.uint32)

proc checkParsedForwardWorkspaceAddressFixtureOracleValidation() =
  var layer = BlaiCpuInstLayer64(
    layerType: ord(blaiRouteConv).int32,
    w: 4,
    h: 4,
    c: 4,
    cn: [4'i32, 0, 0, 0, 0, 0, 0],
    outW: 4,
    outH: 4,
    outC: 4,
    inputNum: 2,
    groups: 1,
    stride: 1,
    dilation: 1,
    size: 3,
    activation: 2,
    midOut: 1,
    npuOn: 1,
    dspOn: 1,
    dramNWeight: 288,
    dramNBias: 4,
    tfInput1Offset: 120,
    tfInput2Offset: 121,
    tfOutputOffset: 122,
    tfOutputShift: -2,
    tfInput1Shift: -1,
    tfInput2Shift: 1,
    tfInput1Multiplier: 0x0102_0304'i32,
    tfInput2Multiplier: 0x1112_1314'i32,
    tfOutputMultiplier: 0x2122_2324'i32,
    quantizedActivationMin: 0,
    quantizedActivationMax: 255)
  var seedCtrl: BlaiPsramCtrl
  var seedStream: array[BlaiInstructionScratchSize div BlaiInstructionSize,
                        BlaiInstruction]
  let seeded = blaiEncodeCpuLayerWithAllocator(
    layer, seedCtrl, seedStream, useTflite = true, c2 = 4,
    includeExtra = true)
  if seeded.encoded:
    blaiApplyMemoryPlan(layer, seedCtrl)
  var states = [
    BlaiCpuParsedLayerState(active: true, index: 0, layer: layer),
    BlaiCpuParsedLayerState(
      active: true,
      index: 1,
      layer: BlaiCpuInstLayer64(
        layerType: ord(blaiRoute).int32,
        npuOn: 0,
        dspOn: 1))]
  let parsed = BlaiCpuModelParseResult(
    hasHeader: true,
    useTflite: true,
    complete: true,
    declaredLayerCount: 2,
    parsedLayerCount: 2,
    storedLayerCount: 2)
  var oracleLayers = [
    BlaiCpuParsedLayerState(
      active: true,
      index: 0,
      layer: BlaiCpuInstLayer64(
        layerType: ord(blaiConvolutional).int32,
        dspOn: 1,
        w: 1, h: 1, c: 1, outC: 1,
        outW: 1, outH: 1,
        size: 1, stride: 1, dilation: 1, groups: 1,
        tfInput1Offset: 0,
        tfInput2Offset: 0,
        tfOutputOffset: 0,
        tfOutputMultiplier: high(int32),
        tfOutputShift: 0,
        quantizedActivationMin: 0,
        quantizedActivationMax: 255))]
  var oracleBiases: array[1, int32]
  var oracleScratchA: array[1, uint8]
  var oracleScratchB: array[1, uint8]
  var oracleOutput: array[1, uint8]
  let oracleReference = blaiReferenceTfliteParsedCheckedModel2d(
    oracleLayers,
    useTflite = true,
    input = [33'u8],
    cpuWeightBytes = [2'u8],
    cpuBiasBytes = [0'u8, 0, 0, 0],
    decodedBiases = oracleBiases,
    scratchA = oracleScratchA,
    scratchB = oracleScratchB,
    output = oracleOutput)
  var fixedOracleReference: BlaiReferenceFixedParsedCheckedModelResult
  var fixedOracleExpected: array[1, uint8]
  var fixedOracleProjection: BlaiInt8OutputRawByteProjectionResult
  buildFixedWorkspaceOracleReference(
    fixedOracleReference, fixedOracleExpected, fixedOracleProjection)
  let plan = blaiPlanParsedForwardModelWorkspace(
    parsed, states, baseAddress = 0x2209_0000'u32)
  let tensorLayer = BlaiCpuInstLayer64(
    layerType: ord(blaiConvolutional).int32,
    npuOn: 1,
    w: 1,
    h: 1,
    c: 1,
    outW: 1,
    outH: 1,
    outC: 1,
    dramIn: [0'i32, 0, 0, 0, 0, 0, 0, 0],
    dramOut: [1'i32, 0, 0, 0, 0, 0, 0, 0],
    dramPatchSize: 4)
  let tensorPlan = blaiPlanForwardNpu(
    tensorLayer, layerIndex = 0,
    dataBufferBytes = plan.resources.dataBufferBytes)
  var input: array[1, uint8]
  var expectedOutput: array[1, uint8]
  input[0] = 7
  expectedOutput[0] = fixedOracleExpected[0]
  var workspaceBytes {.align: 16.}: array[2048, uint8]
  let seed = blaiBindForwardWorkspaceAddress(
    plan.resources, 0x2209_0000'u32, blaiBufferLenU32(workspaceBytes.len))
  if seed.bound:
    discard blaiWriteForwardWorkspaceSegmentByte(
      seed.workspace.data, workspaceBytes, 4, expectedOutput[0])
  var cpuWeights: array[288, uint8]
  for i in 0 ..< cpuWeights.len:
    cpuWeights[i] = i.uint8
  let cpuBiases = [
    1'u8, 0, 0, 0,
    2'u8, 0, 0, 0,
    3'u8, 0, 0, 0,
    4'u8, 0, 0, 0]
  var ctrl: BlaiPsramCtrl
  var stream: array[BlaiInstructionScratchSize div BlaiInstructionSize,
                    BlaiInstruction]
  var decodedWeights: array[288, int32]
  var decodedBiases: array[4, int32]
  var npuWeights: array[288, uint8]
  var npuBiases: array[4, int32]
  var temporaryWeights: array[0, int32]
  var outputInto: array[1, uint8]
  var intoResult: BlaiParsedForwardWorkspaceFixtureValidationResult
  blaiValidateParsedForwardWorkspaceAddressFixtureInto(
    parsed, states, plan, workspaceBaseAddress = 0x2209_0000'u32,
    tensorPlan = tensorPlan, inputIndex = 0, input = input,
    expectedOutput = expectedOutput, output = outputInto, ctrl = ctrl,
    stream = stream, workspaceBytes = workspaceBytes,
    cpuWeightBytes = cpuWeights, cpuBiasBytes = cpuBiases,
    decodedWeights = decodedWeights, decodedBiases = decodedBiases,
    npuWeightBytes = npuWeights, npuBiases = npuBiases,
    temporaryWeights = temporaryWeights, executor = fakeForwardLayerExecutor,
    outResult = intoResult, pack = 4, c2 = 4, includeExtra = true)
  if seed.bound:
    discard blaiWriteForwardWorkspaceSegmentByte(
      seed.workspace.data, workspaceBytes, 4, expectedOutput[0])
  var output: array[1, uint8]
  var fixture: BlaiParsedForwardWorkspaceFixtureValidationResult
  blaiValidateParsedForwardWorkspaceAddressFixtureInto(
    parsed, states, plan, workspaceBaseAddress = 0x2209_0000'u32,
    tensorPlan = tensorPlan, inputIndex = 0, input = input,
    expectedOutput = expectedOutput, output = output, ctrl = ctrl,
    stream = stream, workspaceBytes = workspaceBytes,
    cpuWeightBytes = cpuWeights, cpuBiasBytes = cpuBiases,
    decodedWeights = decodedWeights, decodedBiases = decodedBiases,
    npuWeightBytes = npuWeights, npuBiases = npuBiases,
    temporaryWeights = temporaryWeights, executor = fakeForwardLayerExecutor,
    outResult = fixture, pack = 4, c2 = 4, includeExtra = true)
  check("NPU model parsed workspace explicit fixture into equal",
    intoResult.valid == fixture.valid and
      intoResult.firstBlock == fixture.firstBlock)
  check("NPU model parsed workspace explicit fixture valid", fixture.valid)
  checkEq("NPU model parsed workspace explicit fixture first block",
    fixture.firstBlock.uint32,
    blaiParsedForwardWorkspaceFixtureValidationNoBlock.uint32)
  checkEq("NPU model parsed workspace explicit fixture address block",
    fixture.hardwareAddressFirstBlock.uint32,
    blaiForwardWorkspaceHardwareAddressNoBlock.uint32)
  var oracleInto: BlaiTfliteParsedWorkspaceOracleValidationResult
  blaiTfliteParsedWorkspaceOracleValidationInto(
    oracleReference, fixture, oracleInto)
  let oracleValidation = blaiTfliteParsedWorkspaceOracleValidation(
    oracleReference, fixture)
  check("NPU model TFLite workspace oracle into equal",
    oracleInto.valid == oracleValidation.valid and
      oracleInto.firstBlock == oracleValidation.firstBlock)
  check("NPU model TFLite workspace oracle valid",
    oracleValidation.valid and oracleValidation.outputValid and
      oracleValidation.outputMatched and
      oracleValidation.comparedElements == 1 and
      oracleValidation.outputFirstBlock ==
        blaiForwardWorkspaceOutputValidationNoBlock)
  checkEq("NPU model TFLite workspace oracle first block",
    oracleValidation.firstBlock.uint32,
    blaiTfliteParsedWorkspaceOracleValidationNoBlock.uint32)
  checkEq("NPU model TFLite workspace oracle reference block",
    oracleValidation.referenceFirstBlock.uint32,
    blaiRefTfliteCheckedNoBlock.uint32)
  checkEq("NPU model TFLite workspace oracle fixture block",
    oracleValidation.fixtureFirstBlock.uint32,
    blaiParsedForwardWorkspaceFixtureValidationNoBlock.uint32)
  checkEq("NPU model TFLite workspace oracle mismatches",
    oracleValidation.mismatchCount, 0)
  checkEq("NPU model TFLite workspace oracle first mismatch",
    blaiTfliteParsedWorkspaceOracleFirstMismatch(
      oracleValidation).uint32, high(uint32))
  checkTfliteWorkspaceRawProjection(oracleOutput, output)
  var fixedOracleInto: BlaiFixedParsedWorkspaceOracleValidationResult
  blaiFixedParsedWorkspaceOracleValidationInto(
    fixedOracleReference, fixture, fixedOracleInto)
  let fixedOracleValidation = blaiFixedParsedWorkspaceOracleValidation(
    fixedOracleReference, fixture)
  check("NPU model fixed workspace oracle into equal",
    fixedOracleInto.valid == fixedOracleValidation.valid and
      fixedOracleInto.firstBlock == fixedOracleValidation.firstBlock)
  check("NPU model fixed workspace oracle valid",
    fixedOracleValidation.valid and fixedOracleValidation.outputValid and
      fixedOracleValidation.outputMatched and
      fixedOracleValidation.comparedElements == 1 and
      fixedOracleValidation.outputFirstBlock ==
        blaiForwardWorkspaceOutputValidationNoBlock)
  checkEq("NPU model fixed workspace oracle first block",
    fixedOracleValidation.firstBlock.uint32,
    blaiFixedParsedWorkspaceOracleValidationNoBlock.uint32)
  checkEq("NPU model fixed workspace oracle reference block",
    fixedOracleValidation.referenceFirstBlock.uint32,
    blaiRefFixedCheckedNoBlock.uint32)
  checkEq("NPU model fixed workspace oracle fixture block",
    fixedOracleValidation.fixtureFirstBlock.uint32,
    blaiParsedForwardWorkspaceFixtureValidationNoBlock.uint32)
  checkEq("NPU model fixed workspace oracle mismatches",
    fixedOracleValidation.mismatchCount, 0)
  checkEq("NPU model fixed workspace oracle first mismatch",
    blaiFixedParsedWorkspaceOracleFirstMismatch(
      fixedOracleValidation).uint32, high(uint32))
  checkFixedWorkspaceRawCompare(output)

proc checkTfliteParsedWorkspaceOracleAddressFixture() =
  resetAddressFixtureScratch()
  var layer = BlaiCpuInstLayer64(
    layerType: ord(blaiRouteConv).int32,
    w: 4, h: 4, c: 4,
    cn: [4'i32, 0, 0, 0, 0, 0, 0],
    outW: 4, outH: 4, outC: 4,
    inputNum: 2,
    groups: 1,
    stride: 1,
    dilation: 1,
    size: 3,
    activation: 2,
    midOut: 1,
    npuOn: 1,
    dspOn: 1,
    dramNWeight: 288,
    dramNBias: 4,
    tfInput1Offset: 120,
    tfInput2Offset: 121,
    tfOutputOffset: 122,
    tfOutputShift: -2,
    tfInput1Shift: -1,
    tfInput2Shift: 1,
    tfInput1Multiplier: 0x0102_0304'i32,
    tfInput2Multiplier: 0x1112_1314'i32,
    tfOutputMultiplier: 0x2122_2324'i32,
    quantizedActivationMin: 0,
    quantizedActivationMax: 255)
  var seedCtrl: BlaiPsramCtrl
  var seedStream: array[BlaiInstructionScratchSize div BlaiInstructionSize,
                        BlaiInstruction]
  let seeded = blaiEncodeCpuLayerWithAllocator(
    layer, seedCtrl, seedStream, useTflite = true, c2 = 4,
    includeExtra = true)
  if seeded.encoded:
    blaiApplyMemoryPlan(layer, seedCtrl)
  var states = [
    BlaiCpuParsedLayerState(active: true, index: 0, layer: layer),
    BlaiCpuParsedLayerState(
      active: true,
      index: 1,
      layer: BlaiCpuInstLayer64(
        layerType: ord(blaiRoute).int32,
        npuOn: 0,
        dspOn: 1))]
  let parsed = BlaiCpuModelParseResult(
    hasHeader: true,
    useTflite: true,
    complete: true,
    declaredLayerCount: 2,
    parsedLayerCount: 2,
    storedLayerCount: 2)
  var oracleLayers = [
    BlaiCpuParsedLayerState(
      active: true,
      index: 0,
      layer: BlaiCpuInstLayer64(
        layerType: ord(blaiConvolutional).int32,
        dspOn: 1,
        w: 1, h: 1, c: 1, outC: 1,
        outW: 1, outH: 1,
        size: 1, stride: 1, dilation: 1, groups: 1,
        tfInput1Offset: 0,
        tfInput2Offset: 0,
        tfOutputOffset: 0,
        tfOutputMultiplier: high(int32),
        tfOutputShift: 0,
        quantizedActivationMin: 0,
        quantizedActivationMax: 255))]
  var oracleBiases: array[1, int32]
  var oracleScratchA: array[1, uint8]
  var oracleScratchB: array[1, uint8]
  var oracleOutput: array[1, uint8]
  let oracleReference = blaiReferenceTfliteParsedCheckedModel2d(
    oracleLayers,
    useTflite = true,
    input = [33'u8],
    cpuWeightBytes = [2'u8],
    cpuBiasBytes = [0'u8, 0, 0, 0],
    decodedBiases = oracleBiases,
    scratchA = oracleScratchA,
    scratchB = oracleScratchB,
    output = oracleOutput)
  let plan = blaiPlanParsedForwardModelWorkspace(
    parsed, states, baseAddress = 0x220A_0000'u32)
  let tensorLayer = BlaiCpuInstLayer64(
    layerType: ord(blaiConvolutional).int32,
    npuOn: 1,
    w: 1, h: 1, c: 1,
    outW: 1, outH: 1, outC: 1,
    dramIn: [0'i32, 0, 0, 0, 0, 0, 0, 0],
    dramOut: [1'i32, 0, 0, 0, 0, 0, 0, 0],
    dramPatchSize: 4)
  let tensorPlan = blaiPlanForwardNpu(
    tensorLayer, layerIndex = 0,
    dataBufferBytes = plan.resources.dataBufferBytes)
  let seed = blaiBindForwardWorkspaceAddress(
    plan.resources, 0x220A_0000'u32,
    blaiBufferLenU32(addressFixtureWorkspace.len))
  if seed.bound:
    discard blaiWriteForwardWorkspaceSegmentByte(
      seed.workspace.data, addressFixtureWorkspace, 4, oracleOutput[0])
  let cpuBiases = [
    1'u8, 0, 0, 0,
    2'u8, 0, 0, 0,
    3'u8, 0, 0, 0,
    4'u8, 0, 0, 0]
  var ctrl: BlaiPsramCtrl
  var expected: array[1, uint8]
  var output: array[1, uint8]
  blaiValidateTfliteParsedWorkspaceOracleAddressFixtureInto(
    oracleReference, oracleOutput, parsed, states, plan,
    workspaceBaseAddress = 0x220A_0000'u32, tensorPlan = tensorPlan,
    inputIndex = 0, input = [7'u8], expectedWorkspaceOutput = expected,
    output = output, ctrl = ctrl, stream = addressFixtureStream,
    workspaceBytes = addressFixtureWorkspace,
    cpuWeightBytes = addressFixtureCpuWeights,
    cpuBiasBytes = cpuBiases, decodedWeights = addressFixtureDecodedWeights,
    decodedBiases = addressFixtureDecodedBiases,
    npuWeightBytes = addressFixtureNpuWeights,
    npuBiases = addressFixtureNpuBiases,
    temporaryWeights = addressFixtureTemporaryWeights,
    executor = fakeForwardLayerExecutor,
    outResult = addressFixtureResults.tfliteComposed,
    pack = 4, c2 = 4, includeExtra = true)
  check("NPU model TFLite workspace oracle address composed valid",
    addressFixtureResults.tfliteComposed.valid and
      addressFixtureResults.tfliteComposed.outputValid and
      addressFixtureResults.tfliteComposed.outputMatched and
      addressFixtureResults.tfliteComposed.completedLayerCount == 1 and
      addressFixtureResults.tfliteComposed.comparedElements == 1 and
      addressFixtureResults.tfliteComposed.mismatchCount == 0 and
      addressFixtureResults.tfliteComposed.outputFirstBlock ==
        blaiForwardWorkspaceOutputValidationNoBlock)
  checkEq("NPU model TFLite workspace oracle address composed first block",
    addressFixtureResults.tfliteComposed.firstBlock.uint32,
    blaiTfliteParsedWorkspaceOracleAddressFixtureNoBlock.uint32)
  checkEq("NPU model TFLite workspace oracle address projection block",
    addressFixtureResults.tfliteComposed.projectionFirstBlock.uint32,
    blaiUint8OutputRawByteProjectionNoBlock.uint32)
  checkEq("NPU model TFLite workspace oracle address validation block",
    addressFixtureResults.tfliteComposed.validationFirstBlock.uint32,
    blaiTfliteParsedWorkspaceOracleValidationNoBlock.uint32)
  checkEq("NPU model TFLite workspace oracle address first mismatch",
    blaiTfliteParsedWorkspaceOracleAddressFirstMismatch(
      addressFixtureResults.tfliteComposed).uint32, high(uint32))
  blaiTfliteParsedWorkspaceOracleAddressFixtureReadinessInto(
    addressFixtureResults.tfliteComposed, addressFixtureResults.tfliteReadinessInto)
  blaiTfliteParsedWorkspaceOracleAddressFixtureReadinessInto(
    addressFixtureResults.tfliteComposed, addressFixtureResults.tfliteReadiness)
  check("NPU model TFLite workspace oracle address readiness valid",
    addressFixtureResults.tfliteReadinessInto == addressFixtureResults.tfliteReadiness and
      addressFixtureResults.tfliteReadiness.valid and
      addressFixtureResults.tfliteReadiness.projected and
      addressFixtureResults.tfliteReadiness.fixtureValid and
      addressFixtureResults.tfliteReadiness.validationValid and
      addressFixtureResults.tfliteReadiness.outputValid and
      addressFixtureResults.tfliteReadiness.outputMatched and
      addressFixtureResults.tfliteReadiness.completedLayerCount == 1 and
      addressFixtureResults.tfliteReadiness.expectedElements == 1 and
      addressFixtureResults.tfliteReadiness.actualElements == 1 and
      addressFixtureResults.tfliteReadiness.comparedElements == 1 and
      addressFixtureResults.tfliteReadiness.trailingElements == 0 and
      addressFixtureResults.tfliteReadiness.lengthMatches and
      addressFixtureResults.tfliteReadiness.mismatchCount == 0 and
      addressFixtureResults.tfliteReadiness.outputFirstBlock ==
        blaiForwardWorkspaceOutputValidationNoBlock and
      addressFixtureResults.tfliteReadiness.fixtureReadiness.valid)
  check("NPU model TFLite workspace oracle address output readiness valid",
    addressFixtureResults.tfliteReadiness.outputReadiness.valid and
      addressFixtureResults.tfliteReadiness.outputReadiness.validation.outputMatched and
      addressFixtureResults.tfliteReadiness.outputReadiness.comparedElements == 1 and
      addressFixtureResults.tfliteReadiness.outputReadiness.mismatchCount == 0 and
      addressFixtureResults.tfliteReadiness.outputReadiness.firstBlock ==
        blaiForwardWorkspaceOutputValidationNoBlock)
  if seed.bound:
    discard blaiWriteForwardWorkspaceSegmentByte(
      seed.workspace.data, addressFixtureWorkspace, 4,
      oracleOutput[0] xor 0x01'u8)
  blaiValidateTfliteParsedWorkspaceOracleAddressFixtureInto(
    oracleReference, oracleOutput, parsed, states, plan,
    workspaceBaseAddress = 0x220A_0000'u32, tensorPlan = tensorPlan,
    inputIndex = 0, input = [7'u8], expectedWorkspaceOutput = expected,
    output = output, ctrl = ctrl, stream = addressFixtureStream,
    workspaceBytes = addressFixtureWorkspace,
    cpuWeightBytes = addressFixtureCpuWeights,
    cpuBiasBytes = cpuBiases, decodedWeights = addressFixtureDecodedWeights,
    decodedBiases = addressFixtureDecodedBiases,
    npuWeightBytes = addressFixtureNpuWeights,
    npuBiases = addressFixtureNpuBiases,
    temporaryWeights = addressFixtureTemporaryWeights,
    executor = fakeForwardLayerExecutor,
    outResult = addressFixtureResults.tfliteMismatchComposed,
    pack = 4, c2 = 4, includeExtra = true)
  check("NPU model TFLite workspace oracle address mismatch readiness",
    not addressFixtureResults.tfliteMismatchComposed.valid and
      addressFixtureResults.tfliteMismatchComposed.mismatchCount == 1 and
      addressFixtureResults.tfliteMismatchComposed.firstMismatch == 0 and
      addressFixtureResults.tfliteMismatchComposed.expectedPresentAtFirstMismatch and
      addressFixtureResults.tfliteMismatchComposed.actualPresentAtFirstMismatch)
  checkEq("NPU model TFLite workspace oracle address readiness expected",
    addressFixtureResults.tfliteMismatchComposed.expectedAtFirstMismatch.uint32,
    oracleOutput[0].uint32)
  checkEq("NPU model TFLite workspace oracle address readiness actual",
    addressFixtureResults.tfliteMismatchComposed.actualAtFirstMismatch.uint32,
    (oracleOutput[0] xor 0x01'u8).uint32)
  blaiTfliteParsedWorkspaceOracleAddressFixtureReadinessInto(
    addressFixtureResults.tfliteMismatchComposed, addressFixtureResults.tfliteMismatchReadiness)
  check("NPU model TFLite workspace oracle address readiness mismatch fields",
    addressFixtureResults.tfliteMismatchReadiness.mismatchCount == 1 and
      addressFixtureResults.tfliteMismatchReadiness.firstMismatch == 0 and
      addressFixtureResults.tfliteMismatchReadiness.expectedAtFirstMismatch ==
        oracleOutput[0] and
      addressFixtureResults.tfliteMismatchReadiness.actualAtFirstMismatch ==
        (oracleOutput[0] xor 0x01'u8))
  check("NPU model TFLite workspace oracle address output readiness mismatch",
    not addressFixtureResults.tfliteMismatchReadiness.outputReadiness.valid and
      not addressFixtureResults.tfliteMismatchReadiness.outputReadiness.validation.outputMatched and
      addressFixtureResults.tfliteMismatchReadiness.outputReadiness.firstBlock ==
        blaiForwardWorkspaceOutputValidationCompare and
      addressFixtureResults.tfliteMismatchReadiness.outputReadiness.mismatchCount == 1 and
      addressFixtureResults.tfliteMismatchReadiness.outputReadiness.firstMismatch == 0)
  if seed.bound:
    discard blaiWriteForwardWorkspaceSegmentByte(
      seed.workspace.data, addressFixtureWorkspace, 4, oracleOutput[0])
  var shortExpected: array[0, uint8]
  blaiValidateTfliteParsedWorkspaceOracleAddressFixtureInto(
    oracleReference, oracleOutput, parsed, states, plan,
    workspaceBaseAddress = 0x220A_0000'u32, tensorPlan = tensorPlan,
    inputIndex = 0, input = [7'u8], expectedWorkspaceOutput = shortExpected,
    output = output, ctrl = ctrl, stream = addressFixtureStream,
    workspaceBytes = addressFixtureWorkspace,
    cpuWeightBytes = addressFixtureCpuWeights,
    cpuBiasBytes = cpuBiases, decodedWeights = addressFixtureDecodedWeights,
    decodedBiases = addressFixtureDecodedBiases,
    npuWeightBytes = addressFixtureNpuWeights,
    npuBiases = addressFixtureNpuBiases,
    temporaryWeights = addressFixtureTemporaryWeights,
    executor = fakeForwardLayerExecutor,
    outResult = addressFixtureResults.tfliteShortComposed,
    pack = 4, c2 = 4, includeExtra = true)
  checkEq("NPU model TFLite workspace oracle address short block",
    addressFixtureResults.tfliteShortComposed.firstBlock.uint32,
    blaiTfliteParsedWorkspaceOracleAddressFixtureProjection.uint32)
  blaiTfliteParsedWorkspaceOracleAddressFixtureReadinessInto(
    addressFixtureResults.tfliteShortComposed, addressFixtureResults.tfliteShortReadiness)
  check("NPU model TFLite workspace oracle address readiness short",
    not addressFixtureResults.tfliteShortReadiness.valid and
      not addressFixtureResults.tfliteShortReadiness.projected and
      addressFixtureResults.tfliteShortReadiness.firstBlock ==
        blaiTfliteParsedWorkspaceOracleAddressFixtureProjection)
  check("NPU model TFLite workspace oracle address output readiness short",
    not addressFixtureResults.tfliteShortReadiness.outputReadiness.valid and
      addressFixtureResults.tfliteShortReadiness.outputReadiness.comparedElements == 0 and
      addressFixtureResults.tfliteShortReadiness.outputReadiness.mismatchCount == 0)

proc checkFixedParsedWorkspaceOracleAddressFixture() =
  resetAddressFixtureScratch()
  var layer = BlaiCpuInstLayer64(
    layerType: ord(blaiRouteConv).int32,
    w: 4, h: 4, c: 4,
    cn: [4'i32, 0, 0, 0, 0, 0, 0],
    outW: 4, outH: 4, outC: 4,
    inputNum: 2,
    groups: 1,
    stride: 1,
    dilation: 1,
    size: 3,
    activation: 2,
    midOut: 1,
    npuOn: 1,
    dspOn: 1,
    dramNWeight: 288,
    dramNBias: 4,
    tfInput1Offset: 120,
    tfInput2Offset: 121,
    tfOutputOffset: 122,
    tfOutputShift: -2,
    tfInput1Shift: -1,
    tfInput2Shift: 1,
    tfInput1Multiplier: 0x0102_0304'i32,
    tfInput2Multiplier: 0x1112_1314'i32,
    tfOutputMultiplier: 0x2122_2324'i32,
    quantizedActivationMin: 0,
    quantizedActivationMax: 255)
  var seedCtrl: BlaiPsramCtrl
  var seedStream: array[BlaiInstructionScratchSize div BlaiInstructionSize,
                        BlaiInstruction]
  let seeded = blaiEncodeCpuLayerWithAllocator(
    layer, seedCtrl, seedStream, useTflite = true, c2 = 4,
    includeExtra = true)
  if seeded.encoded:
    blaiApplyMemoryPlan(layer, seedCtrl)
  var states = [
    BlaiCpuParsedLayerState(active: true, index: 0, layer: layer),
    BlaiCpuParsedLayerState(
      active: true,
      index: 1,
      layer: BlaiCpuInstLayer64(
        layerType: ord(blaiRoute).int32,
        npuOn: 0,
        dspOn: 1))]
  let parsed = BlaiCpuModelParseResult(
    hasHeader: true,
    useTflite: true,
    complete: true,
    declaredLayerCount: 2,
    parsedLayerCount: 2,
    storedLayerCount: 2)
  var reference: BlaiReferenceFixedParsedCheckedModelResult
  var referenceOutput: array[1, int8]
  var referenceExpected: array[1, uint8]
  var referenceProjection: BlaiInt8OutputRawByteProjectionResult
  buildFixedWorkspaceOracleReferenceWithOutput(
    reference, referenceOutput, referenceExpected, referenceProjection)
  let plan = blaiPlanParsedForwardModelWorkspace(
    parsed, states, baseAddress = 0x220B_0000'u32)
  let tensorLayer = BlaiCpuInstLayer64(
    layerType: ord(blaiConvolutional).int32,
    npuOn: 1,
    w: 1, h: 1, c: 1,
    outW: 1, outH: 1, outC: 1,
    dramIn: [0'i32, 0, 0, 0, 0, 0, 0, 0],
    dramOut: [1'i32, 0, 0, 0, 0, 0, 0, 0],
    dramPatchSize: 4)
  let tensorPlan = blaiPlanForwardNpu(
    tensorLayer, layerIndex = 0,
    dataBufferBytes = plan.resources.dataBufferBytes)
  let seed = blaiBindForwardWorkspaceAddress(
    plan.resources, 0x220B_0000'u32,
    blaiBufferLenU32(addressFixtureWorkspace.len))
  if seed.bound:
    discard blaiWriteForwardWorkspaceSegmentByte(
      seed.workspace.data, addressFixtureWorkspace, 4, referenceExpected[0])
  let cpuBiases = [
    1'u8, 0, 0, 0,
    2'u8, 0, 0, 0,
    3'u8, 0, 0, 0,
    4'u8, 0, 0, 0]
  var ctrl: BlaiPsramCtrl
  var expected: array[1, uint8]
  var output: array[1, uint8]
  blaiValidateFixedParsedWorkspaceOracleAddressFixtureInto(
    reference, referenceOutput, parsed, states, plan,
    workspaceBaseAddress = 0x220B_0000'u32, tensorPlan = tensorPlan,
    inputIndex = 0, input = [7'u8], expectedWorkspaceOutput = expected,
    output = output, ctrl = ctrl, stream = addressFixtureStream,
    workspaceBytes = addressFixtureWorkspace,
    cpuWeightBytes = addressFixtureCpuWeights,
    cpuBiasBytes = cpuBiases, decodedWeights = addressFixtureDecodedWeights,
    decodedBiases = addressFixtureDecodedBiases,
    npuWeightBytes = addressFixtureNpuWeights,
    npuBiases = addressFixtureNpuBiases,
    temporaryWeights = addressFixtureTemporaryWeights,
    executor = fakeForwardLayerExecutor,
    outResult = addressFixtureResults.fixedComposed,
    pack = 4, c2 = 4, includeExtra = true)
  check("NPU model fixed workspace oracle address composed valid",
    addressFixtureResults.fixedComposed.valid and
      addressFixtureResults.fixedComposed.outputValid and
      addressFixtureResults.fixedComposed.outputMatched and
      addressFixtureResults.fixedComposed.completedLayerCount == 1 and
      addressFixtureResults.fixedComposed.comparedElements == 1 and
      addressFixtureResults.fixedComposed.mismatchCount == 0 and
      addressFixtureResults.fixedComposed.outputFirstBlock ==
        blaiForwardWorkspaceOutputValidationNoBlock)
  checkEq("NPU model fixed workspace oracle address composed first block",
    addressFixtureResults.fixedComposed.firstBlock.uint32,
    blaiFixedParsedWorkspaceOracleAddressFixtureNoBlock.uint32)
  checkEq("NPU model fixed workspace oracle address projection block",
    addressFixtureResults.fixedComposed.projectionFirstBlock.uint32,
    blaiInt8OutputRawByteProjectionNoBlock.uint32)
  checkEq("NPU model fixed workspace oracle address validation block",
    addressFixtureResults.fixedComposed.validationFirstBlock.uint32,
    blaiFixedParsedWorkspaceOracleValidationNoBlock.uint32)
  checkEq("NPU model fixed workspace oracle address first mismatch",
    blaiFixedParsedWorkspaceOracleAddressFirstMismatch(
      addressFixtureResults.fixedComposed).uint32, high(uint32))
  blaiFixedParsedWorkspaceOracleAddressFixtureReadinessInto(
    addressFixtureResults.fixedComposed, addressFixtureResults.fixedReadinessInto)
  blaiFixedParsedWorkspaceOracleAddressFixtureReadinessInto(
    addressFixtureResults.fixedComposed, addressFixtureResults.fixedReadiness)
  check("NPU model fixed workspace oracle address readiness valid",
    addressFixtureResults.fixedReadinessInto == addressFixtureResults.fixedReadiness and
      addressFixtureResults.fixedReadiness.valid and
      addressFixtureResults.fixedReadiness.projected and
      addressFixtureResults.fixedReadiness.fixtureValid and
      addressFixtureResults.fixedReadiness.validationValid and
      addressFixtureResults.fixedReadiness.outputValid and
      addressFixtureResults.fixedReadiness.outputMatched and
      addressFixtureResults.fixedReadiness.completedLayerCount == 1 and
      addressFixtureResults.fixedReadiness.expectedElements == 1 and
      addressFixtureResults.fixedReadiness.actualElements == 1 and
      addressFixtureResults.fixedReadiness.comparedElements == 1 and
      addressFixtureResults.fixedReadiness.trailingElements == 0 and
      addressFixtureResults.fixedReadiness.lengthMatches and
      addressFixtureResults.fixedReadiness.mismatchCount == 0 and
      addressFixtureResults.fixedReadiness.outputFirstBlock ==
        blaiForwardWorkspaceOutputValidationNoBlock and
      addressFixtureResults.fixedReadiness.fixtureReadiness.valid)
  check("NPU model fixed workspace oracle address output readiness valid",
    addressFixtureResults.fixedReadiness.outputReadiness.valid and
      addressFixtureResults.fixedReadiness.outputReadiness.validation.outputMatched and
      addressFixtureResults.fixedReadiness.outputReadiness.comparedElements == 1 and
      addressFixtureResults.fixedReadiness.outputReadiness.mismatchCount == 0 and
      addressFixtureResults.fixedReadiness.outputReadiness.firstBlock ==
        blaiForwardWorkspaceOutputValidationNoBlock)
  if seed.bound:
    discard blaiWriteForwardWorkspaceSegmentByte(
      seed.workspace.data, addressFixtureWorkspace, 4,
      referenceExpected[0] xor 0x01'u8)
  blaiValidateFixedParsedWorkspaceOracleAddressFixtureInto(
    reference, referenceOutput, parsed, states, plan,
    workspaceBaseAddress = 0x220B_0000'u32, tensorPlan = tensorPlan,
    inputIndex = 0, input = [7'u8], expectedWorkspaceOutput = expected,
    output = output, ctrl = ctrl, stream = addressFixtureStream,
    workspaceBytes = addressFixtureWorkspace,
    cpuWeightBytes = addressFixtureCpuWeights,
    cpuBiasBytes = cpuBiases, decodedWeights = addressFixtureDecodedWeights,
    decodedBiases = addressFixtureDecodedBiases,
    npuWeightBytes = addressFixtureNpuWeights,
    npuBiases = addressFixtureNpuBiases,
    temporaryWeights = addressFixtureTemporaryWeights,
    executor = fakeForwardLayerExecutor,
    outResult = addressFixtureResults.fixedMismatchComposed,
    pack = 4, c2 = 4, includeExtra = true)
  check("NPU model fixed workspace oracle address mismatch readiness",
    not addressFixtureResults.fixedMismatchComposed.valid and
      addressFixtureResults.fixedMismatchComposed.mismatchCount == 1 and
      addressFixtureResults.fixedMismatchComposed.firstMismatch == 0 and
      addressFixtureResults.fixedMismatchComposed.expectedPresentAtFirstMismatch and
      addressFixtureResults.fixedMismatchComposed.actualPresentAtFirstMismatch)
  checkEq("NPU model fixed workspace oracle address readiness expected",
    addressFixtureResults.fixedMismatchComposed.expectedAtFirstMismatch.uint32,
    referenceExpected[0].uint32)
  checkEq("NPU model fixed workspace oracle address readiness actual",
    addressFixtureResults.fixedMismatchComposed.actualAtFirstMismatch.uint32,
    (referenceExpected[0] xor 0x01'u8).uint32)
  blaiFixedParsedWorkspaceOracleAddressFixtureReadinessInto(
    addressFixtureResults.fixedMismatchComposed, addressFixtureResults.fixedMismatchReadiness)
  check("NPU model fixed workspace oracle address readiness mismatch fields",
    addressFixtureResults.fixedMismatchReadiness.mismatchCount == 1 and
      addressFixtureResults.fixedMismatchReadiness.firstMismatch == 0 and
      addressFixtureResults.fixedMismatchReadiness.expectedAtFirstMismatch ==
        referenceExpected[0] and
      addressFixtureResults.fixedMismatchReadiness.actualAtFirstMismatch ==
        (referenceExpected[0] xor 0x01'u8))
  check("NPU model fixed workspace oracle address output readiness mismatch",
    not addressFixtureResults.fixedMismatchReadiness.outputReadiness.valid and
      not addressFixtureResults.fixedMismatchReadiness.outputReadiness.validation.outputMatched and
      addressFixtureResults.fixedMismatchReadiness.outputReadiness.firstBlock ==
        blaiForwardWorkspaceOutputValidationCompare and
      addressFixtureResults.fixedMismatchReadiness.outputReadiness.mismatchCount == 1 and
      addressFixtureResults.fixedMismatchReadiness.outputReadiness.firstMismatch == 0)
  if seed.bound:
    discard blaiWriteForwardWorkspaceSegmentByte(
      seed.workspace.data, addressFixtureWorkspace, 4, referenceExpected[0])
  var shortExpected: array[0, uint8]
  blaiValidateFixedParsedWorkspaceOracleAddressFixtureInto(
    reference, referenceOutput, parsed, states, plan,
    workspaceBaseAddress = 0x220B_0000'u32, tensorPlan = tensorPlan,
    inputIndex = 0, input = [7'u8], expectedWorkspaceOutput = shortExpected,
    output = output, ctrl = ctrl, stream = addressFixtureStream,
    workspaceBytes = addressFixtureWorkspace,
    cpuWeightBytes = addressFixtureCpuWeights,
    cpuBiasBytes = cpuBiases, decodedWeights = addressFixtureDecodedWeights,
    decodedBiases = addressFixtureDecodedBiases,
    npuWeightBytes = addressFixtureNpuWeights,
    npuBiases = addressFixtureNpuBiases,
    temporaryWeights = addressFixtureTemporaryWeights,
    executor = fakeForwardLayerExecutor,
    outResult = addressFixtureResults.fixedShortComposed,
    pack = 4, c2 = 4, includeExtra = true)
  checkEq("NPU model fixed workspace oracle address short block",
    addressFixtureResults.fixedShortComposed.firstBlock.uint32,
    blaiFixedParsedWorkspaceOracleAddressFixtureProjection.uint32)
  blaiFixedParsedWorkspaceOracleAddressFixtureReadinessInto(
    addressFixtureResults.fixedShortComposed, addressFixtureResults.fixedShortReadiness)
  check("NPU model fixed workspace oracle address readiness short",
    not addressFixtureResults.fixedShortReadiness.valid and
      not addressFixtureResults.fixedShortReadiness.projected and
      addressFixtureResults.fixedShortReadiness.firstBlock ==
        blaiFixedParsedWorkspaceOracleAddressFixtureProjection)
  check("NPU model fixed workspace oracle address output readiness short",
    not addressFixtureResults.fixedShortReadiness.outputReadiness.valid and
      addressFixtureResults.fixedShortReadiness.outputReadiness.comparedElements == 0 and
      addressFixtureResults.fixedShortReadiness.outputReadiness.mismatchCount == 0)

proc checkParsedConfiguredWorkspaceAddressFixtureGuard() =
  let layer = BlaiCpuInstLayer64(
    layerType: ord(blaiConvolutional).int32,
    npuOn: 1,
    dspOn: 1,
    w: 1, h: 1, c: 1,
    outW: 1, outH: 1, outC: 1,
    size: 1, stride: 1, dilation: 1, groups: 1,
    dramNWeight: 1,
    dramNBias: 1,
    dramIn: [0'i32, 0, 0, 0, 0, 0, 0, 0],
    dramOut: [1'i32, 0, 0, 0, 0, 0, 0, 0],
    dramPatchSize: 4)
  let rawLayers = [layer]
  let resources = blaiPlanForwardModelResources(
    rawLayers, useTflite = true)
  let tensorPlan = blaiPlanForwardNpu(
    layer, layerIndex = 0,
    dataBufferBytes = resources.dataBufferBytes)
  let states = [BlaiCpuParsedLayerState(active: true, index: 0, layer: layer)]
  var workspaceBytes {.align: 16.}: array[2048, uint8]
  var output: array[1, uint8]
  var guarded: BlaiParsedForwardConfiguredWorkspaceFixtureResult
  blaiValidateParsedForwardConfiguredWorkspaceAddressFixtureInto(
    states, resources, workspaceBaseAddress = 0'u32,
    tensorPlan = tensorPlan, inputIndex = 0, input = [7'u8],
    expectedOutput = [9'u8], output = output,
    workspaceBytes = workspaceBytes, outResult = guarded, timeout = 11)
  checkEq("NPU model parsed configured workspace fixture guard block",
    guarded.firstBlock.uint32,
    blaiParsedForwardConfiguredWorkspaceFixtureHardwareAddresses.uint32)
  checkEq("NPU model parsed configured workspace fixture guard address",
    guarded.hardwareAddressFirstBlock.uint32,
    blaiForwardWorkspaceHardwareAddressInstruction.uint32)
  check("NPU model parsed configured workspace fixture guard no input",
    not guarded.input.moved)
  check("NPU model parsed configured workspace fixture guard no execution",
    not guarded.execution.runnable and guarded.execution.attemptedLayerCount == 0)
  var guardedReadinessInto:
    BlaiParsedForwardConfiguredWorkspaceFixtureReadiness
  blaiParsedForwardConfiguredWorkspaceFixtureReadinessInto(
    guarded, guardedReadinessInto)
  let guardedReadiness =
    blaiParsedForwardConfiguredWorkspaceFixtureReadiness(guarded)
  check("NPU model parsed configured workspace fixture readiness guard",
    guardedReadinessInto == guardedReadiness and
      guardedReadiness.firstBlock ==
        blaiParsedForwardConfiguredWorkspaceFixtureHardwareAddresses and
      guardedReadiness.bound and not guardedReadiness.hardwareAddressesReady and
      not guardedReadiness.inputMoved and not guardedReadiness.executed)
  var oracleLayers = [
    BlaiCpuParsedLayerState(
      active: true,
      index: 0,
      layer: BlaiCpuInstLayer64(
        layerType: ord(blaiConvolutional).int32,
        dspOn: 1,
        w: 1, h: 1, c: 1, outC: 1,
        outW: 1, outH: 1,
        size: 1, stride: 1, dilation: 1, groups: 1,
        tfInput1Offset: 0,
        tfInput2Offset: 0,
        tfOutputOffset: 0,
        tfOutputMultiplier: high(int32),
        tfOutputShift: 0,
        quantizedActivationMin: 0,
        quantizedActivationMax: 255))]
  var oracleBiases: array[1, int32]
  var oracleScratchA: array[1, uint8]
  var oracleScratchB: array[1, uint8]
  var oracleOutput: array[1, uint8]
  let oracleReference = blaiReferenceTfliteParsedCheckedModel2d(
    oracleLayers,
    useTflite = true,
    input = [33'u8],
    cpuWeightBytes = [2'u8],
    cpuBiasBytes = [0'u8, 0, 0, 0],
    decodedBiases = oracleBiases,
    scratchA = oracleScratchA,
    scratchB = oracleScratchB,
    output = oracleOutput)
  var expectedWorkspaceOutput: array[1, uint8]
  var oracleGuarded:
    BlaiTfliteParsedConfiguredWorkspaceOracleAddressFixtureResult
  blaiValidateTfliteParsedConfiguredWorkspaceOracleAddressFixtureInto(
    oracleReference, oracleOutput, states, resources,
    workspaceBaseAddress = 0'u32, tensorPlan = tensorPlan,
    inputIndex = 0, input = [7'u8],
    expectedWorkspaceOutput = expectedWorkspaceOutput, output = output,
    workspaceBytes = workspaceBytes, outResult = oracleGuarded, timeout = 11)
  checkEq("NPU model TFLite configured workspace oracle guard block",
    oracleGuarded.firstBlock.uint32,
    blaiTfliteParsedConfiguredWorkspaceOracleAddressFixtureFixture.uint32)
  checkEq("NPU model TFLite configured workspace oracle projection block",
    oracleGuarded.projectionFirstBlock.uint32,
    blaiUint8OutputRawByteProjectionNoBlock.uint32)
  checkEq("NPU model TFLite configured workspace oracle fixture block",
    oracleGuarded.fixtureFirstBlock.uint32,
    blaiParsedForwardConfiguredWorkspaceFixtureHardwareAddresses.uint32)
  var oracleGuardedReadinessInto:
    BlaiTfliteParsedConfiguredWorkspaceOracleAddressFixtureReadiness
  blaiTfliteParsedConfiguredWorkspaceOracleAddressFixtureReadinessInto(
    oracleGuarded, oracleGuardedReadinessInto)
  let oracleGuardedReadiness =
    blaiTfliteParsedConfiguredWorkspaceOracleAddressFixtureReadiness(
      oracleGuarded)
  check("NPU model TFLite configured workspace oracle readiness guard",
    oracleGuardedReadinessInto == oracleGuardedReadiness and
      oracleGuardedReadiness.firstBlock ==
        blaiTfliteParsedConfiguredWorkspaceOracleAddressFixtureFixture and
      oracleGuardedReadiness.projected and
      oracleGuardedReadiness.referenceValid and
      not oracleGuardedReadiness.fixtureValid and
      oracleGuardedReadiness.fixtureReadiness.firstBlock ==
        blaiParsedForwardConfiguredWorkspaceFixtureHardwareAddresses)
  var fixedReference: BlaiReferenceFixedParsedCheckedModelResult
  var fixedOutput: array[1, int8]
  var fixedExpected: array[1, uint8]
  var fixedProjection: BlaiInt8OutputRawByteProjectionResult
  buildFixedWorkspaceOracleReferenceWithOutput(
    fixedReference, fixedOutput, fixedExpected, fixedProjection)
  var fixedOracleGuarded:
    BlaiFixedParsedConfiguredWorkspaceOracleAddressFixtureResult
  blaiValidateFixedParsedConfiguredWorkspaceOracleAddressFixtureInto(
    fixedReference, fixedOutput, states, resources,
    workspaceBaseAddress = 0'u32, tensorPlan = tensorPlan,
    inputIndex = 0, input = [7'u8],
    expectedWorkspaceOutput = fixedExpected, output = output,
    workspaceBytes = workspaceBytes, outResult = fixedOracleGuarded,
    timeout = 11)
  checkEq("NPU model fixed configured workspace oracle guard block",
    fixedOracleGuarded.firstBlock.uint32,
    blaiFixedParsedConfiguredWorkspaceOracleAddressFixtureFixture.uint32)
  checkEq("NPU model fixed configured workspace oracle projection block",
    fixedOracleGuarded.projectionFirstBlock.uint32,
    blaiInt8OutputRawByteProjectionNoBlock.uint32)
  checkEq("NPU model fixed configured workspace oracle fixture block",
    fixedOracleGuarded.fixtureFirstBlock.uint32,
    blaiParsedForwardConfiguredWorkspaceFixtureHardwareAddresses.uint32)
  var fixedOracleGuardedReadinessInto:
    BlaiFixedParsedConfiguredWorkspaceOracleAddressFixtureReadiness
  blaiFixedParsedConfiguredWorkspaceOracleAddressFixtureReadinessInto(
    fixedOracleGuarded, fixedOracleGuardedReadinessInto)
  let fixedOracleGuardedReadiness =
    blaiFixedParsedConfiguredWorkspaceOracleAddressFixtureReadiness(
      fixedOracleGuarded)
  check("NPU model fixed configured workspace oracle readiness guard",
    fixedOracleGuardedReadinessInto == fixedOracleGuardedReadiness and
      fixedOracleGuardedReadiness.firstBlock ==
        blaiFixedParsedConfiguredWorkspaceOracleAddressFixtureFixture and
      fixedOracleGuardedReadiness.projected and
      fixedOracleGuardedReadiness.referenceValid and
      not fixedOracleGuardedReadiness.fixtureValid and
      fixedOracleGuardedReadiness.fixtureReadiness.firstBlock ==
        blaiParsedForwardConfiguredWorkspaceFixtureHardwareAddresses)
  var skipLayer = layer
  skipLayer.npuOn = 0
  var skipStates = [
    BlaiCpuParsedLayerState(active: true, index: 0, layer: skipLayer)]
  var skipWorkspace {.align: 16.}: array[2048, uint8]
  let skipBinding = blaiBindForwardWorkspaceAddress(
    resources, 0x220C_0000'u32, blaiBufferLenU32(skipWorkspace.len))
  if skipBinding.bound:
    discard blaiWriteForwardWorkspaceSegmentByte(
      skipBinding.workspace.data, skipWorkspace, 4, 9'u8)
  var skipCtrl: BlaiPsramCtrl
  var skipStream: array[0, BlaiInstruction]
  var skipCpuWeights: array[0, uint8]
  var skipCpuBiases: array[0, uint8]
  var skipDecodedWeights: array[0, int32]
  var skipDecodedBiases: array[0, int32]
  var skipNpuWeights: array[0, uint8]
  var skipNpuBiases: array[0, int32]
  var skipTemporaryWeights: array[0, int32]
  var skippedMaterialization:
    BlaiForwardModelWorkspaceMaterializeResult
  var skipOutput: array[1, uint8]
  var skipped: BlaiParsedForwardConfiguredWorkspaceFixtureResult
  blaiMaterializeAndValidateParsedForwardConfiguredWorkspaceAddressFixtureInto(
    skipStates, useTflite = true, modelResources = resources,
    workspaceBaseAddress = 0'u32, tensorPlan = tensorPlan,
    inputIndex = 0, input = [7'u8], expectedOutput = [9'u8],
    output = skipOutput, ctrl = skipCtrl, stream = skipStream,
    workspaceBytes = skipWorkspace, cpuWeightBytes = skipCpuWeights,
    cpuBiasBytes = skipCpuBiases, decodedWeights = skipDecodedWeights,
    decodedBiases = skipDecodedBiases, npuWeightBytes = skipNpuWeights,
    npuBiases = skipNpuBiases, temporaryWeights = skipTemporaryWeights,
    outMaterialization = skippedMaterialization, outFixture = skipped,
    timeout = 11)
  check("NPU model parsed configured workspace fixture materialized guard",
    not skippedMaterialization.allReady and not skipped.valid and
      skipped.firstBlock ==
        blaiParsedForwardConfiguredWorkspaceFixtureBinding and
      skipped.bindingFirstBlock == blaiForwardWorkspaceBufferBindAddress)
  blaiMaterializeAndValidateParsedForwardConfiguredWorkspaceAddressFixtureInto(
    skipStates, useTflite = true, modelResources = resources,
    workspaceBaseAddress = 0x220C_0000'u32, tensorPlan = tensorPlan,
    inputIndex = 0, input = [7'u8], expectedOutput = [9'u8],
    output = skipOutput, ctrl = skipCtrl, stream = skipStream,
    workspaceBytes = skipWorkspace, cpuWeightBytes = skipCpuWeights,
    cpuBiasBytes = skipCpuBiases, decodedWeights = skipDecodedWeights,
    decodedBiases = skipDecodedBiases, npuWeightBytes = skipNpuWeights,
    npuBiases = skipNpuBiases, temporaryWeights = skipTemporaryWeights,
    outMaterialization = skippedMaterialization, outFixture = skipped,
    timeout = 11)
  check("NPU model parsed configured workspace fixture skip valid",
    skippedMaterialization.allReady and skippedMaterialization.skippedLayerCount == 1 and
      skipped.valid)
  check("NPU model parsed configured workspace fixture skip input",
    skipped.input.moved and
      blaiForwardWorkspaceSegmentByteEquals(
        skipBinding.workspace.data, skipWorkspace, 0, 7'u8))
  check("NPU model parsed configured workspace fixture skip execution",
    skipped.execution.allCompleted and skipped.execution.skippedLayerCount == 1 and
      skipped.execution.attemptedLayerCount == 0)
  check("NPU model parsed configured workspace fixture skip output",
    skipped.output.valid and skipOutput[0] == 9'u8)
  let skippedReadiness =
    blaiParsedForwardConfiguredWorkspaceFixtureReadiness(skipped)
  check("NPU model parsed configured workspace fixture readiness skip",
    skippedReadiness.valid and skippedReadiness.bound and
      skippedReadiness.hardwareAddressesReady and skippedReadiness.inputMoved and
      skippedReadiness.executionRunnable and skippedReadiness.executed and
      skippedReadiness.outputValid)
  check("NPU model parsed configured workspace fixture output readiness skip",
    skippedReadiness.outputReadiness.valid and
      skippedReadiness.outputReadiness.validation.outputMatched and
      skippedReadiness.outputReadiness.firstBlock ==
        blaiForwardWorkspaceOutputValidationNoBlock)
  check("NPU model parsed configured workspace fixture output evidence skip",
    skippedReadiness.outputMatched and
      skippedReadiness.comparedElements == 1 and
      skippedReadiness.mismatchCount == 0 and
      skippedReadiness.firstMismatch < 0)

  var bufferWorkspace {.align: 16.}: array[2048, uint8]
  let bufferBinding = blaiBindForwardWorkspaceBuffer(resources, bufferWorkspace)
  if bufferBinding.bound:
    discard blaiWriteForwardWorkspaceSegmentByte(
      bufferBinding.workspace.data, bufferWorkspace, 4, 9'u8)
  var bufferOutput: array[1, uint8]
  var bufferConfigured:
    BlaiParsedForwardConfiguredWorkspaceFixtureResult
  blaiValidateParsedForwardConfiguredWorkspaceFixtureInto(
    skipStates, resources, tensorPlan, inputIndex = 0, input = [7'u8],
    expectedOutput = [9'u8], output = bufferOutput,
    workspaceBytes = bufferWorkspace, outResult = bufferConfigured,
    timeout = 11)
  let bufferReadiness =
    blaiParsedForwardConfiguredWorkspaceFixtureReadiness(bufferConfigured)
  check("NPU model parsed configured workspace fixture buffer classified",
    bufferReadiness.firstBlock == bufferConfigured.firstBlock and
      bufferConfigured.firstBlock in {
        blaiParsedForwardConfiguredWorkspaceFixtureNoBlock,
        blaiParsedForwardConfiguredWorkspaceFixtureBinding,
        blaiParsedForwardConfiguredWorkspaceFixtureHardwareAddresses,
        blaiParsedForwardConfiguredWorkspaceFixtureInput,
        blaiParsedForwardConfiguredWorkspaceFixtureExecution,
        blaiParsedForwardConfiguredWorkspaceFixtureOutput})
  check("NPU model parsed configured workspace fixture buffer valid",
    bufferConfigured.valid ==
      (bufferConfigured.firstBlock ==
        blaiParsedForwardConfiguredWorkspaceFixtureNoBlock))
  check("NPU model parsed configured workspace fixture buffer input",
    (bufferConfigured.firstBlock <
      blaiParsedForwardConfiguredWorkspaceFixtureInput and
      not bufferConfigured.input.moved) or
      (bufferConfigured.firstBlock >=
        blaiParsedForwardConfiguredWorkspaceFixtureInput))
  check("NPU model parsed configured workspace fixture buffer output",
    (bufferConfigured.valid and bufferConfigured.output.valid and
      bufferOutput[0] == 9'u8) or
      ((not bufferConfigured.valid) and
        bufferConfigured.output.valid ==
          (bufferConfigured.firstBlock ==
            blaiParsedForwardConfiguredWorkspaceFixtureOutput)))

  var bufferMaterializedWorkspace {.align: 16.}: array[2048, uint8]
  let bufferMaterializedBinding =
    blaiBindForwardWorkspaceBuffer(resources, bufferMaterializedWorkspace)
  if bufferMaterializedBinding.bound:
    discard blaiWriteForwardWorkspaceSegmentByte(
      bufferMaterializedBinding.workspace.data,
      bufferMaterializedWorkspace, 4, 9'u8)
  var bufferMaterializedCtrl: BlaiPsramCtrl
  var bufferMaterializedStream: array[0, BlaiInstruction]
  var bufferMaterializedCpuWeights: array[0, uint8]
  var bufferMaterializedCpuBiases: array[0, uint8]
  var bufferMaterializedDecodedWeights: array[0, int32]
  var bufferMaterializedDecodedBiases: array[0, int32]
  var bufferMaterializedNpuWeights: array[0, uint8]
  var bufferMaterializedNpuBiases: array[0, int32]
  var bufferMaterializedTemporaryWeights: array[0, int32]
  var bufferMaterializedResult:
    BlaiForwardModelWorkspaceMaterializeResult
  var bufferMaterializedFixture:
    BlaiParsedForwardConfiguredWorkspaceFixtureResult
  var bufferMaterializedOutput: array[1, uint8]
  blaiMaterializeAndValidateParsedForwardConfiguredWorkspaceFixtureInto(
    skipStates, useTflite = true, modelResources = resources,
    tensorPlan = tensorPlan, inputIndex = 0, input = [7'u8],
    expectedOutput = [9'u8], output = bufferMaterializedOutput,
    ctrl = bufferMaterializedCtrl, stream = bufferMaterializedStream,
    workspaceBytes = bufferMaterializedWorkspace,
    cpuWeightBytes = bufferMaterializedCpuWeights,
    cpuBiasBytes = bufferMaterializedCpuBiases,
    decodedWeights = bufferMaterializedDecodedWeights,
    decodedBiases = bufferMaterializedDecodedBiases,
    npuWeightBytes = bufferMaterializedNpuWeights,
    npuBiases = bufferMaterializedNpuBiases,
    temporaryWeights = bufferMaterializedTemporaryWeights,
    outMaterialization = bufferMaterializedResult,
    outFixture = bufferMaterializedFixture,
    timeout = 11)
  let bufferMaterializedReadiness =
    blaiParsedForwardConfiguredWorkspaceFixtureReadiness(
      bufferMaterializedFixture)
  check("NPU model parsed configured workspace fixture buffer materialized classified",
    bufferMaterializedReadiness.firstBlock ==
      bufferMaterializedFixture.firstBlock and
      bufferMaterializedFixture.firstBlock in {
        blaiParsedForwardConfiguredWorkspaceFixtureNoBlock,
        blaiParsedForwardConfiguredWorkspaceFixtureBinding,
        blaiParsedForwardConfiguredWorkspaceFixtureHardwareAddresses,
        blaiParsedForwardConfiguredWorkspaceFixtureInput,
        blaiParsedForwardConfiguredWorkspaceFixtureExecution,
        blaiParsedForwardConfiguredWorkspaceFixtureOutput})
  check("NPU model parsed configured workspace fixture buffer materialized valid",
    bufferMaterializedFixture.valid ==
      (bufferMaterializedFixture.firstBlock ==
        blaiParsedForwardConfiguredWorkspaceFixtureNoBlock))
  check("NPU model parsed configured workspace fixture buffer materialized output",
    (bufferMaterializedFixture.valid and
      bufferMaterializedResult.allReady and
      bufferMaterializedFixture.output.valid and
      bufferMaterializedOutput[0] == 9'u8) or
      ((not bufferMaterializedFixture.valid) and
        bufferMaterializedFixture.output.valid ==
          (bufferMaterializedFixture.firstBlock ==
            blaiParsedForwardConfiguredWorkspaceFixtureOutput)))
  if skipBinding.bound:
    discard blaiWriteForwardWorkspaceSegmentByte(
      skipBinding.workspace.data, skipWorkspace, 4, oracleOutput[0])
  var tfliteSkipExpected: array[1, uint8]
  var tfliteSkipOutput: array[1, uint8]
  var tfliteSkippedMaterialization:
    BlaiForwardModelWorkspaceMaterializeResult
  var tfliteSkipped:
    BlaiTfliteParsedConfiguredWorkspaceOracleAddressFixtureResult
  blaiMaterializeAndValidateTfliteParsedConfiguredWorkspaceOracleAddressFixtureInto(
    oracleReference, oracleOutput, skipStates, useTflite = true,
    modelResources = resources, workspaceBaseAddress = 0'u32,
    tensorPlan = tensorPlan, inputIndex = 0, input = [7'u8],
    expectedWorkspaceOutput = tfliteSkipExpected, output = tfliteSkipOutput,
    ctrl = skipCtrl, stream = skipStream, workspaceBytes = skipWorkspace,
    cpuWeightBytes = skipCpuWeights, cpuBiasBytes = skipCpuBiases,
    decodedWeights = skipDecodedWeights, decodedBiases = skipDecodedBiases,
    npuWeightBytes = skipNpuWeights, npuBiases = skipNpuBiases,
    temporaryWeights = skipTemporaryWeights,
    outMaterialization = tfliteSkippedMaterialization,
    outResult = tfliteSkipped, timeout = 11)
  check("NPU model TFLite configured workspace oracle materialized guard",
    not tfliteSkippedMaterialization.allReady and
      not tfliteSkipped.valid and tfliteSkipped.projected and
      tfliteSkipped.referenceValid and
      tfliteSkipped.firstBlock ==
        blaiTfliteParsedConfiguredWorkspaceOracleAddressFixtureFixture and
      tfliteSkipped.fixtureFirstBlock ==
        blaiParsedForwardConfiguredWorkspaceFixtureBinding)
  blaiMaterializeAndValidateTfliteParsedConfiguredWorkspaceOracleAddressFixtureInto(
    oracleReference, oracleOutput, skipStates, useTflite = true,
    modelResources = resources, workspaceBaseAddress = 0x220C_0000'u32,
    tensorPlan = tensorPlan, inputIndex = 0, input = [7'u8],
    expectedWorkspaceOutput = tfliteSkipExpected, output = tfliteSkipOutput,
    ctrl = skipCtrl, stream = skipStream, workspaceBytes = skipWorkspace,
    cpuWeightBytes = skipCpuWeights, cpuBiasBytes = skipCpuBiases,
    decodedWeights = skipDecodedWeights, decodedBiases = skipDecodedBiases,
    npuWeightBytes = skipNpuWeights, npuBiases = skipNpuBiases,
    temporaryWeights = skipTemporaryWeights,
    outMaterialization = tfliteSkippedMaterialization,
    outResult = tfliteSkipped, timeout = 11)
  check("NPU model TFLite configured workspace oracle skip valid",
    tfliteSkippedMaterialization.allReady and
      tfliteSkippedMaterialization.skippedLayerCount == 1 and
      tfliteSkipped.valid)
  let tfliteSkippedReadiness =
    blaiTfliteParsedConfiguredWorkspaceOracleAddressFixtureReadiness(
      tfliteSkipped)
  check("NPU model TFLite configured workspace oracle readiness skip",
    tfliteSkippedReadiness.valid and tfliteSkippedReadiness.projected and
      tfliteSkippedReadiness.referenceValid and
      tfliteSkippedReadiness.fixtureValid and
      tfliteSkippedReadiness.outputValid and
      tfliteSkippedReadiness.outputMatched and
      tfliteSkippedReadiness.expectedElements == 1 and
      tfliteSkippedReadiness.actualElements == 1 and
      tfliteSkippedReadiness.comparedElements == 1 and
      tfliteSkippedReadiness.trailingElements == 0 and
      tfliteSkippedReadiness.lengthMatches and
      tfliteSkippedReadiness.mismatchCount == 0 and
      tfliteSkippedReadiness.outputFirstBlock ==
        blaiForwardWorkspaceOutputValidationNoBlock and
      tfliteSkippedReadiness.fixtureReadiness.valid)
  check("NPU model TFLite configured workspace oracle output readiness skip",
    tfliteSkippedReadiness.outputReadiness.valid and
      tfliteSkippedReadiness.outputReadiness.validation.outputMatched and
      tfliteSkippedReadiness.outputReadiness.comparedElements == 1 and
      tfliteSkippedReadiness.outputReadiness.mismatchCount == 0 and
      tfliteSkippedReadiness.outputReadiness.firstBlock ==
        blaiForwardWorkspaceOutputValidationNoBlock)
  check("NPU model TFLite configured workspace oracle equivalence skip",
    tfliteSkipped.outputValid and tfliteSkipped.outputMatched and
      tfliteSkipped.completedLayerCount == 0 and
      tfliteSkipped.expectedElements == 1 and
      tfliteSkipped.actualElements == 1 and
      tfliteSkipped.comparedElements == 1 and tfliteSkipped.mismatchCount == 0 and
      tfliteSkipped.trailingElements == 0 and tfliteSkipped.lengthMatches and
      tfliteSkipped.outputFirstBlock ==
        blaiForwardWorkspaceOutputValidationNoBlock)
  checkEq("NPU model TFLite configured workspace oracle first mismatch",
    blaiTfliteParsedConfiguredWorkspaceOracleAddressFirstMismatch(
      tfliteSkipped).uint32, high(uint32))
  if skipBinding.bound:
    discard blaiWriteForwardWorkspaceSegmentByte(
      skipBinding.workspace.data, skipWorkspace, 4,
      oracleOutput[0] xor 0x01'u8)
  var tfliteMismatch:
    BlaiTfliteParsedConfiguredWorkspaceOracleAddressFixtureResult
  blaiValidateTfliteParsedConfiguredWorkspaceOracleAddressFixtureInto(
    oracleReference, oracleOutput, skipStates, resources,
    workspaceBaseAddress = 0x220C_0000'u32, tensorPlan = tensorPlan,
    inputIndex = 0, input = [7'u8],
    expectedWorkspaceOutput = tfliteSkipExpected, output = tfliteSkipOutput,
    workspaceBytes = skipWorkspace, outResult = tfliteMismatch, timeout = 11)
  checkEq("NPU model TFLite configured workspace oracle mismatch block",
    tfliteMismatch.firstBlock.uint32,
    blaiTfliteParsedConfiguredWorkspaceOracleAddressFixtureFixture.uint32)
  checkEq("NPU model TFLite configured workspace oracle mismatch fixture",
    tfliteMismatch.fixtureFirstBlock.uint32,
    blaiParsedForwardConfiguredWorkspaceFixtureOutput.uint32)
  checkEq("NPU model TFLite configured workspace oracle mismatch output",
    tfliteMismatch.outputFirstBlock.uint32,
    blaiForwardWorkspaceOutputValidationCompare.uint32)
  check("NPU model TFLite configured workspace oracle mismatch counted",
    not tfliteMismatch.valid and tfliteMismatch.projected and
      tfliteMismatch.referenceValid and not tfliteMismatch.fixtureValid and
      not tfliteMismatch.outputValid and not tfliteMismatch.outputMatched and
      tfliteMismatch.comparedElements == 1 and
      tfliteMismatch.mismatchCount == 1)
  checkEq("NPU model TFLite configured workspace oracle mismatch first",
    blaiTfliteParsedConfiguredWorkspaceOracleAddressFirstMismatch(
      tfliteMismatch).uint32, 0)
  checkEq("NPU model TFLite configured workspace oracle projected accessor",
    blaiTfliteParsedConfiguredWorkspaceOracleFirstMismatch(
      tfliteMismatch).uint32, 0)
  checkEq("NPU model TFLite configured workspace oracle mismatch expected",
    tfliteMismatch.fixture.output.compare.expectedAtFirstMismatch.uint32,
    oracleOutput[0].uint32)
  checkEq("NPU model TFLite configured workspace oracle mismatch actual",
    tfliteMismatch.fixture.output.compare.actualAtFirstMismatch.uint32,
    (oracleOutput[0] xor 0x01'u8).uint32)
  let tfliteMismatchReadiness =
    blaiTfliteParsedConfiguredWorkspaceOracleAddressFixtureReadiness(
      tfliteMismatch)
  check("NPU model TFLite configured workspace oracle mismatch readiness",
    tfliteMismatchReadiness.firstBlock ==
      blaiTfliteParsedConfiguredWorkspaceOracleAddressFixtureFixture and
      tfliteMismatchReadiness.mismatchCount == 1 and
      tfliteMismatchReadiness.firstMismatch == 0 and
      tfliteMismatchReadiness.expectedPresentAtFirstMismatch and
      tfliteMismatchReadiness.actualPresentAtFirstMismatch)
  check("NPU model TFLite configured workspace oracle mismatch output readiness",
    not tfliteMismatchReadiness.outputReadiness.valid and
      not tfliteMismatchReadiness.outputReadiness.validation.outputMatched and
      tfliteMismatchReadiness.outputReadiness.firstBlock ==
        blaiForwardWorkspaceOutputValidationCompare and
      tfliteMismatchReadiness.outputReadiness.mismatchCount == 1 and
      tfliteMismatchReadiness.outputReadiness.firstMismatch == 0)
  checkEq("NPU model TFLite configured workspace oracle readiness expected",
    tfliteMismatchReadiness.expectedAtFirstMismatch.uint32,
    oracleOutput[0].uint32)
  checkEq("NPU model TFLite configured workspace oracle readiness actual",
    tfliteMismatchReadiness.actualAtFirstMismatch.uint32,
    (oracleOutput[0] xor 0x01'u8).uint32)
  if skipBinding.bound:
    discard blaiWriteForwardWorkspaceSegmentByte(
      skipBinding.workspace.data, skipWorkspace, 4, fixedExpected[0])
  var fixedSkipOutput: array[1, uint8]
  var fixedSkippedMaterialization:
    BlaiForwardModelWorkspaceMaterializeResult
  var fixedSkipped:
    BlaiFixedParsedConfiguredWorkspaceOracleAddressFixtureResult
  blaiMaterializeAndValidateFixedParsedConfiguredWorkspaceOracleAddressFixtureInto(
    fixedReference, fixedOutput, skipStates, useTflite = true,
    modelResources = resources, workspaceBaseAddress = 0'u32,
    tensorPlan = tensorPlan, inputIndex = 0, input = [7'u8],
    expectedWorkspaceOutput = fixedExpected, output = fixedSkipOutput,
    ctrl = skipCtrl, stream = skipStream, workspaceBytes = skipWorkspace,
    cpuWeightBytes = skipCpuWeights, cpuBiasBytes = skipCpuBiases,
    decodedWeights = skipDecodedWeights, decodedBiases = skipDecodedBiases,
    npuWeightBytes = skipNpuWeights, npuBiases = skipNpuBiases,
    temporaryWeights = skipTemporaryWeights,
    outMaterialization = fixedSkippedMaterialization,
    outResult = fixedSkipped, timeout = 11)
  check("NPU model fixed configured workspace oracle materialized guard",
    not fixedSkippedMaterialization.allReady and not fixedSkipped.valid and
      fixedSkipped.projected and fixedSkipped.referenceValid and
      fixedSkipped.firstBlock ==
        blaiFixedParsedConfiguredWorkspaceOracleAddressFixtureFixture and
      fixedSkipped.fixtureFirstBlock ==
        blaiParsedForwardConfiguredWorkspaceFixtureBinding)
  blaiMaterializeAndValidateFixedParsedConfiguredWorkspaceOracleAddressFixtureInto(
    fixedReference, fixedOutput, skipStates, useTflite = true,
    modelResources = resources, workspaceBaseAddress = 0x220C_0000'u32,
    tensorPlan = tensorPlan, inputIndex = 0, input = [7'u8],
    expectedWorkspaceOutput = fixedExpected, output = fixedSkipOutput,
    ctrl = skipCtrl, stream = skipStream, workspaceBytes = skipWorkspace,
    cpuWeightBytes = skipCpuWeights, cpuBiasBytes = skipCpuBiases,
    decodedWeights = skipDecodedWeights, decodedBiases = skipDecodedBiases,
    npuWeightBytes = skipNpuWeights, npuBiases = skipNpuBiases,
    temporaryWeights = skipTemporaryWeights,
    outMaterialization = fixedSkippedMaterialization,
    outResult = fixedSkipped, timeout = 11)
  check("NPU model fixed configured workspace oracle skip valid",
    fixedSkippedMaterialization.allReady and
      fixedSkippedMaterialization.skippedLayerCount == 1 and
      fixedSkipped.valid)
  let fixedSkippedReadiness =
    blaiFixedParsedConfiguredWorkspaceOracleAddressFixtureReadiness(
      fixedSkipped)
  check("NPU model fixed configured workspace oracle readiness skip",
    fixedSkippedReadiness.valid and fixedSkippedReadiness.projected and
      fixedSkippedReadiness.referenceValid and
      fixedSkippedReadiness.fixtureValid and
      fixedSkippedReadiness.outputValid and
      fixedSkippedReadiness.outputMatched and
      fixedSkippedReadiness.expectedElements == 1 and
      fixedSkippedReadiness.actualElements == 1 and
      fixedSkippedReadiness.comparedElements == 1 and
      fixedSkippedReadiness.trailingElements == 0 and
      fixedSkippedReadiness.lengthMatches and
      fixedSkippedReadiness.mismatchCount == 0 and
      fixedSkippedReadiness.outputFirstBlock ==
        blaiForwardWorkspaceOutputValidationNoBlock and
      fixedSkippedReadiness.fixtureReadiness.valid)
  check("NPU model fixed configured workspace oracle output readiness skip",
    fixedSkippedReadiness.outputReadiness.valid and
      fixedSkippedReadiness.outputReadiness.validation.outputMatched and
      fixedSkippedReadiness.outputReadiness.comparedElements == 1 and
      fixedSkippedReadiness.outputReadiness.mismatchCount == 0 and
      fixedSkippedReadiness.outputReadiness.firstBlock ==
        blaiForwardWorkspaceOutputValidationNoBlock)
  check("NPU model fixed configured workspace oracle equivalence skip",
    fixedSkipped.outputValid and fixedSkipped.outputMatched and
      fixedSkipped.completedLayerCount == 0 and
      fixedSkipped.expectedElements == 1 and
      fixedSkipped.actualElements == 1 and
      fixedSkipped.comparedElements == 1 and fixedSkipped.mismatchCount == 0 and
      fixedSkipped.trailingElements == 0 and fixedSkipped.lengthMatches and
      fixedSkipped.outputFirstBlock ==
        blaiForwardWorkspaceOutputValidationNoBlock)
  checkEq("NPU model fixed configured workspace oracle first mismatch",
    blaiFixedParsedConfiguredWorkspaceOracleAddressFirstMismatch(
      fixedSkipped).uint32, high(uint32))
  if skipBinding.bound:
    discard blaiWriteForwardWorkspaceSegmentByte(
      skipBinding.workspace.data, skipWorkspace, 4,
      fixedExpected[0] xor 0x01'u8)
  var fixedMismatch:
    BlaiFixedParsedConfiguredWorkspaceOracleAddressFixtureResult
  blaiValidateFixedParsedConfiguredWorkspaceOracleAddressFixtureInto(
    fixedReference, fixedOutput, skipStates, resources,
    workspaceBaseAddress = 0x220C_0000'u32, tensorPlan = tensorPlan,
    inputIndex = 0, input = [7'u8],
    expectedWorkspaceOutput = fixedExpected, output = fixedSkipOutput,
    workspaceBytes = skipWorkspace, outResult = fixedMismatch, timeout = 11)
  checkEq("NPU model fixed configured workspace oracle mismatch block",
    fixedMismatch.firstBlock.uint32,
    blaiFixedParsedConfiguredWorkspaceOracleAddressFixtureFixture.uint32)
  checkEq("NPU model fixed configured workspace oracle mismatch fixture",
    fixedMismatch.fixtureFirstBlock.uint32,
    blaiParsedForwardConfiguredWorkspaceFixtureOutput.uint32)
  checkEq("NPU model fixed configured workspace oracle mismatch output",
    fixedMismatch.outputFirstBlock.uint32,
    blaiForwardWorkspaceOutputValidationCompare.uint32)
  check("NPU model fixed configured workspace oracle mismatch counted",
    not fixedMismatch.valid and fixedMismatch.projected and
      fixedMismatch.referenceValid and not fixedMismatch.fixtureValid and
      not fixedMismatch.outputValid and not fixedMismatch.outputMatched and
      fixedMismatch.comparedElements == 1 and fixedMismatch.mismatchCount == 1)
  checkEq("NPU model fixed configured workspace oracle mismatch first",
    blaiFixedParsedConfiguredWorkspaceOracleAddressFirstMismatch(
      fixedMismatch).uint32, 0)
  checkEq("NPU model fixed configured workspace oracle projected accessor",
    blaiFixedParsedConfiguredWorkspaceOracleFirstMismatch(
      fixedMismatch).uint32, 0)
  checkEq("NPU model fixed configured workspace oracle mismatch expected",
    fixedMismatch.fixture.output.compare.expectedAtFirstMismatch.uint32,
    fixedExpected[0].uint32)
  checkEq("NPU model fixed configured workspace oracle mismatch actual",
    fixedMismatch.fixture.output.compare.actualAtFirstMismatch.uint32,
    (fixedExpected[0] xor 0x01'u8).uint32)
  let fixedMismatchReadiness =
    blaiFixedParsedConfiguredWorkspaceOracleAddressFixtureReadiness(
      fixedMismatch)
  check("NPU model fixed configured workspace oracle mismatch readiness",
    fixedMismatchReadiness.firstBlock ==
      blaiFixedParsedConfiguredWorkspaceOracleAddressFixtureFixture and
      fixedMismatchReadiness.mismatchCount == 1 and
      fixedMismatchReadiness.firstMismatch == 0 and
      fixedMismatchReadiness.expectedPresentAtFirstMismatch and
      fixedMismatchReadiness.actualPresentAtFirstMismatch)
  check("NPU model fixed configured workspace oracle mismatch output readiness",
    not fixedMismatchReadiness.outputReadiness.valid and
      not fixedMismatchReadiness.outputReadiness.validation.outputMatched and
      fixedMismatchReadiness.outputReadiness.firstBlock ==
        blaiForwardWorkspaceOutputValidationCompare and
      fixedMismatchReadiness.outputReadiness.mismatchCount == 1 and
      fixedMismatchReadiness.outputReadiness.firstMismatch == 0)
  checkEq("NPU model fixed configured workspace oracle readiness expected",
    fixedMismatchReadiness.expectedAtFirstMismatch.uint32,
    fixedExpected[0].uint32)
  checkEq("NPU model fixed configured workspace oracle readiness actual",
    fixedMismatchReadiness.actualAtFirstMismatch.uint32,
    (fixedExpected[0] xor 0x01'u8).uint32)
  var missingWeightResources = resources
  missingWeightResources.weightBufferBytes = 0
  var missingWeightWorkspace {.align: 16.}: array[2048, uint8]
  var missingWeightOutput: array[1, uint8]
  var missingWeight:
    BlaiParsedForwardConfiguredWorkspaceFixtureResult
  blaiValidateParsedForwardConfiguredWorkspaceAddressFixtureInto(
    states, missingWeightResources, workspaceBaseAddress = 0x220D_0000'u32,
    tensorPlan = tensorPlan, inputIndex = 0, input = [7'u8],
    expectedOutput = [9'u8], output = missingWeightOutput,
    workspaceBytes = missingWeightWorkspace, outResult = missingWeight,
    timeout = 11)
  checkEq("NPU model parsed configured workspace fixture exec guard block",
    missingWeight.firstBlock.uint32,
    blaiParsedForwardConfiguredWorkspaceFixtureExecution.uint32)
  checkEq("NPU model parsed configured workspace fixture exec first",
    missingWeight.executionFirstBlock.uint32,
    blaiForwardModelExecuteRunSequence.uint32)
  checkEq("NPU model parsed configured workspace fixture exec sequence",
    missingWeight.execution.runSequenceFirstBlock.uint32,
    blaiForwardModelRunSequenceRunConfig.uint32)
  check("NPU model parsed configured workspace fixture exec staged",
    missingWeight.input.moved and not missingWeight.output.valid and
      not missingWeight.execution.allCompleted)
  let missingWeightReadiness =
    blaiParsedForwardConfiguredWorkspaceFixtureReadiness(missingWeight)
  check("NPU model parsed configured workspace fixture readiness exec",
    missingWeightReadiness.firstBlock ==
      blaiParsedForwardConfiguredWorkspaceFixtureExecution and
      missingWeightReadiness.bound and
      missingWeightReadiness.hardwareAddressesReady and
      missingWeightReadiness.inputMoved and
      not missingWeightReadiness.executionRunnable and
      not missingWeightReadiness.executed and
      not missingWeightReadiness.outputValid)
  check("NPU model parsed configured workspace fixture exec run config gate",
    missingWeight.executionRunSequenceFirstBlockedRunCaptured and
      missingWeight.executionRunSequenceFirstBlockedLayer == 0 and
      missingWeight.executionRunSequenceFirstBlockedRunConfigFirstBlock ==
        blaiForwardNpuRunConfigWeightBuffers and
      missingWeight.executionRunSequenceFirstBlockedRunConfigReadiness.
        needsWeightBuffers and
      not missingWeight.executionRunSequenceFirstBlockedRunConfigReadiness.
        hasWeightBuffer)
  check("NPU model parsed configured workspace fixture readiness run config gate",
    missingWeightReadiness.executionRunSequenceFirstBlockedRunCaptured and
      missingWeightReadiness.executionRunSequenceFirstBlockedLayer == 0 and
      missingWeightReadiness.executionRunSequenceFirstBlockedRunConfigFirstBlock ==
        blaiForwardNpuRunConfigWeightBuffers and
      missingWeightReadiness.executionRunSequenceFirstBlockedRunConfigReadiness.
        needsWeightBuffers and
      not missingWeightReadiness.executionRunSequenceFirstBlockedRunConfigReadiness.
        hasWeightBuffer)

proc checkTfliteConfiguredWorkspaceOracleBuffer() =
  var layer = BlaiCpuInstLayer64(
    layerType: ord(blaiConvolutional).int32,
    dspOn: 1,
    w: 1, h: 1, c: 1,
    outW: 1, outH: 1, outC: 1,
    size: 1, stride: 1, dilation: 1, groups: 1,
    dramNWeight: 1,
    dramNBias: 1,
    dramIn: [0'i32, 0, 0, 0, 0, 0, 0, 0],
    dramOut: [1'i32, 0, 0, 0, 0, 0, 0, 0],
    dramPatchSize: 4)
  let resources = blaiPlanForwardModelResources([layer], useTflite = true)
  let tensorPlan = blaiPlanForwardNpu(
    layer, layerIndex = 0, dataBufferBytes = resources.dataBufferBytes)
  layer.npuOn = 0
  let states = [BlaiCpuParsedLayerState(active: true, index: 0, layer: layer)]
  var oracleLayers = [
    BlaiCpuParsedLayerState(
      active: true,
      index: 0,
      layer: BlaiCpuInstLayer64(
        layerType: ord(blaiConvolutional).int32,
        dspOn: 1,
        w: 1, h: 1, c: 1, outC: 1,
        outW: 1, outH: 1,
        size: 1, stride: 1, dilation: 1, groups: 1,
        tfOutputMultiplier: high(int32),
        quantizedActivationMax: 255))]
  var oracleBiases: array[1, int32]
  var oracleScratchA: array[1, uint8]
  var oracleScratchB: array[1, uint8]
  var oracleOutput: array[1, uint8]
  let reference = blaiReferenceTfliteParsedCheckedModel2d(
    oracleLayers, useTflite = true, input = [33'u8],
    cpuWeightBytes = [2'u8], cpuBiasBytes = [0'u8, 0, 0, 0],
    decodedBiases = oracleBiases, scratchA = oracleScratchA,
    scratchB = oracleScratchB, output = oracleOutput)
  var workspace {.align: 16.}: array[2048, uint8]
  let binding = blaiBindForwardWorkspaceBuffer(resources, workspace)
  if binding.bound:
    discard blaiWriteForwardWorkspaceSegmentByte(
      binding.workspace.data, workspace, 4, oracleOutput[0])
  var expected: array[1, uint8]
  var output: array[1, uint8]
  var validation:
    BlaiTfliteParsedConfiguredWorkspaceOracleAddressFixtureResult
  blaiValidateTfliteParsedConfiguredWorkspaceOracleFixtureInto(
    reference, oracleOutput, states, resources, tensorPlan = tensorPlan,
    inputIndex = 0, input = [7'u8], expectedWorkspaceOutput = expected,
    output = output, workspaceBytes = workspace, outResult = validation,
    timeout = 11)
  let readiness =
    blaiTfliteParsedConfiguredWorkspaceOracleAddressFixtureReadiness(
      validation)
  check("NPU model TFLite configured workspace oracle buffer classified",
    validation.projected and validation.referenceValid and
      validation.valid ==
        (validation.firstBlock ==
          blaiTfliteParsedConfiguredWorkspaceOracleAddressFixtureNoBlock))
  check("NPU model TFLite configured workspace oracle buffer readiness",
    readiness.firstBlock == validation.firstBlock and
      readiness.valid == validation.valid and
      readiness.fixtureFirstBlock == validation.fixtureFirstBlock)
  check("NPU model TFLite configured workspace oracle buffer equivalence",
    (validation.valid and validation.outputValid and
      validation.outputMatched and validation.completedLayerCount == 0 and
      validation.comparedElements == 1 and validation.mismatchCount == 0) or
      ((not validation.valid) and validation.comparedElements == 0 and
        validation.mismatchCount == 0))
  check("NPU model TFLite configured workspace oracle buffer execution gate",
    readiness.fixtureReadiness.executionFirstBlock ==
      validation.fixture.executionFirstBlock and
      readiness.fixtureReadiness.executionRunSequenceFirstBlock ==
        validation.fixture.execution.runSequenceFirstBlock and
      readiness.fixtureReadiness.executionAttemptedLayerCount ==
        validation.fixture.execution.attemptedLayerCount and
      readiness.fixtureReadiness.executionCompletedLayerCount ==
        validation.fixture.execution.completedLayerCount and
      readiness.fixtureReadiness.executionSkippedLayerCount ==
        validation.fixture.execution.skippedLayerCount and
      readiness.fixtureReadiness.executionFailedLayerCount ==
        validation.fixture.execution.failedLayerCount)
  check("NPU model TFLite configured workspace oracle buffer terminal fields",
    readiness.executionRunnable == validation.executionRunnable and
      readiness.executed == validation.executed and
      readiness.completedLayerCount == validation.completedLayerCount and
      readiness.executionAttemptedLayerCount ==
        validation.executionAttemptedLayerCount and
      readiness.executionCompletedLayerCount ==
        validation.executionCompletedLayerCount and
      readiness.executionFailedLayerCount ==
        validation.executionFailedLayerCount and
      readiness.executionFirstFailedLayer ==
        validation.executionFirstFailedLayer and
      readiness.executionFirstFailedCaptured ==
        validation.executionFirstFailedCaptured and
      readiness.executionLastStarted == validation.executionLastStarted and
      readiness.executionLastCompleted ==
        validation.executionLastCompleted and
      readiness.executionLastTimedOut ==
        validation.executionLastTimedOut and
      readiness.executionLastInterruptObserved ==
        validation.executionLastInterruptObserved)

proc checkTfliteConfiguredWorkspaceOracleBufferMaterialized() =
  var layer = BlaiCpuInstLayer64(
    layerType: ord(blaiConvolutional).int32,
    dspOn: 1,
    w: 1, h: 1, c: 1,
    outW: 1, outH: 1, outC: 1,
    size: 1, stride: 1, dilation: 1, groups: 1,
    dramNWeight: 1,
    dramNBias: 1,
    dramIn: [0'i32, 0, 0, 0, 0, 0, 0, 0],
    dramOut: [1'i32, 0, 0, 0, 0, 0, 0, 0],
    dramPatchSize: 4)
  let resources = blaiPlanForwardModelResources([layer], useTflite = true)
  let tensorPlan = blaiPlanForwardNpu(
    layer, layerIndex = 0, dataBufferBytes = resources.dataBufferBytes)
  layer.npuOn = 0
  var states = [BlaiCpuParsedLayerState(active: true, index: 0, layer: layer)]
  var oracleLayers = [
    BlaiCpuParsedLayerState(
      active: true,
      index: 0,
      layer: BlaiCpuInstLayer64(
        layerType: ord(blaiConvolutional).int32,
        dspOn: 1,
        w: 1, h: 1, c: 1, outC: 1,
        outW: 1, outH: 1,
        size: 1, stride: 1, dilation: 1, groups: 1,
        tfOutputMultiplier: high(int32),
        quantizedActivationMax: 255))]
  var oracleBiases: array[1, int32]
  var oracleScratchA: array[1, uint8]
  var oracleScratchB: array[1, uint8]
  var oracleOutput: array[1, uint8]
  let reference = blaiReferenceTfliteParsedCheckedModel2d(
    oracleLayers, useTflite = true, input = [33'u8],
    cpuWeightBytes = [2'u8], cpuBiasBytes = [0'u8, 0, 0, 0],
    decodedBiases = oracleBiases, scratchA = oracleScratchA,
    scratchB = oracleScratchB, output = oracleOutput)
  var workspace {.align: 16.}: array[2048, uint8]
  let binding = blaiBindForwardWorkspaceBuffer(resources, workspace)
  if binding.bound:
    discard blaiWriteForwardWorkspaceSegmentByte(
      binding.workspace.data, workspace, 4, oracleOutput[0])
  var ctrl: BlaiPsramCtrl
  var stream: array[0, BlaiInstruction]
  var cpuWeights: array[0, uint8]
  var cpuBiases: array[0, uint8]
  var decodedWeights: array[0, int32]
  var decodedBiases: array[0, int32]
  var npuWeights: array[0, uint8]
  var npuBiases: array[0, int32]
  var temporaryWeights: array[0, int32]
  var expected: array[1, uint8]
  var output: array[1, uint8]
  var materialization: BlaiForwardModelWorkspaceMaterializeResult
  var validation:
    BlaiTfliteParsedConfiguredWorkspaceOracleAddressFixtureResult
  blaiMaterializeAndValidateTfliteParsedConfiguredWorkspaceOracleFixtureInto(
    reference, oracleOutput, states, useTflite = true,
    modelResources = resources, tensorPlan = tensorPlan, inputIndex = 0,
    input = [7'u8], expectedWorkspaceOutput = expected, output = output,
    ctrl = ctrl, stream = stream, workspaceBytes = workspace,
    cpuWeightBytes = cpuWeights, cpuBiasBytes = cpuBiases,
    decodedWeights = decodedWeights, decodedBiases = decodedBiases,
    npuWeightBytes = npuWeights, npuBiases = npuBiases,
    temporaryWeights = temporaryWeights, outMaterialization = materialization,
    outResult = validation, timeout = 11)
  check("NPU model TFLite configured workspace oracle buffer materialized classified",
    validation.projected and validation.referenceValid and
      validation.valid ==
        (validation.firstBlock ==
          blaiTfliteParsedConfiguredWorkspaceOracleAddressFixtureNoBlock) and
      ((validation.valid and materialization.allReady and
        materialization.skippedLayerCount == 1) or not validation.valid))
  let readiness =
    blaiTfliteParsedConfiguredWorkspaceOracleAddressFixtureReadiness(
      validation)
  check("NPU model TFLite configured workspace oracle buffer materialized execution gate",
    readiness.fixtureReadiness.executionFirstBlock ==
      validation.fixture.executionFirstBlock and
      readiness.fixtureReadiness.executionRunSequenceFirstBlock ==
        validation.fixture.execution.runSequenceFirstBlock and
      readiness.fixtureReadiness.executionSkippedLayerCount ==
        validation.fixture.execution.skippedLayerCount and
      readiness.fixtureReadiness.executionAttemptedLayerCount ==
        validation.fixture.execution.attemptedLayerCount)
  check("NPU model TFLite configured workspace oracle buffer materialized terminal fields",
    readiness.executionRunnable == validation.executionRunnable and
      readiness.executed == validation.executed and
      readiness.completedLayerCount == validation.completedLayerCount and
      readiness.executionAttemptedLayerCount ==
        validation.executionAttemptedLayerCount and
      readiness.executionCompletedLayerCount ==
        validation.executionCompletedLayerCount and
      readiness.executionFailedLayerCount ==
        validation.executionFailedLayerCount and
      readiness.executionFirstFailedLayer ==
        validation.executionFirstFailedLayer and
      readiness.executionFirstFailedCaptured ==
        validation.executionFirstFailedCaptured and
      readiness.executionLastStarted == validation.executionLastStarted and
      readiness.executionLastCompleted ==
        validation.executionLastCompleted and
      readiness.executionLastTimedOut ==
        validation.executionLastTimedOut and
      readiness.executionLastInterruptObserved ==
        validation.executionLastInterruptObserved)

proc checkFixedConfiguredWorkspaceOracleBuffer() =
  var layer = BlaiCpuInstLayer64(
    layerType: ord(blaiConvolutional).int32,
    dspOn: 1,
    w: 1, h: 1, c: 1,
    outW: 1, outH: 1, outC: 1,
    size: 1, stride: 1, dilation: 1, groups: 1,
    dramNWeight: 1,
    dramNBias: 1,
    dramIn: [0'i32, 0, 0, 0, 0, 0, 0, 0],
    dramOut: [1'i32, 0, 0, 0, 0, 0, 0, 0],
    dramPatchSize: 4)
  let resources = blaiPlanForwardModelResources([layer], useTflite = true)
  let tensorPlan = blaiPlanForwardNpu(
    layer, layerIndex = 0, dataBufferBytes = resources.dataBufferBytes)
  layer.npuOn = 0
  let states = [BlaiCpuParsedLayerState(active: true, index: 0, layer: layer)]
  var reference: BlaiReferenceFixedParsedCheckedModelResult
  var fixedOutput: array[1, int8]
  var expected: array[1, uint8]
  var projection: BlaiInt8OutputRawByteProjectionResult
  buildFixedWorkspaceOracleReferenceWithOutput(
    reference, fixedOutput, expected, projection)
  var workspace {.align: 16.}: array[2048, uint8]
  let binding = blaiBindForwardWorkspaceBuffer(resources, workspace)
  if binding.bound:
    discard blaiWriteForwardWorkspaceSegmentByte(
      binding.workspace.data, workspace, 4, expected[0])
  var output: array[1, uint8]
  var validation:
    BlaiFixedParsedConfiguredWorkspaceOracleAddressFixtureResult
  blaiValidateFixedParsedConfiguredWorkspaceOracleFixtureInto(
    reference, fixedOutput, states, resources, tensorPlan = tensorPlan,
    inputIndex = 0, input = [7'u8], expectedWorkspaceOutput = expected,
    output = output, workspaceBytes = workspace, outResult = validation,
    timeout = 11)
  let readiness =
    blaiFixedParsedConfiguredWorkspaceOracleAddressFixtureReadiness(
      validation)
  check("NPU model fixed configured workspace oracle buffer classified",
    validation.projected and validation.referenceValid and
      validation.valid ==
        (validation.firstBlock ==
          blaiFixedParsedConfiguredWorkspaceOracleAddressFixtureNoBlock))
  check("NPU model fixed configured workspace oracle buffer readiness",
    readiness.firstBlock == validation.firstBlock and
      readiness.valid == validation.valid and
      readiness.fixtureFirstBlock == validation.fixtureFirstBlock)
  check("NPU model fixed configured workspace oracle buffer equivalence",
    (validation.valid and validation.outputValid and
      validation.outputMatched and validation.completedLayerCount == 0 and
      validation.comparedElements == 1 and validation.mismatchCount == 0) or
      ((not validation.valid) and validation.comparedElements == 0 and
        validation.mismatchCount == 0))
  check("NPU model fixed configured workspace oracle buffer execution gate",
    readiness.fixtureReadiness.executionFirstBlock ==
      validation.fixture.executionFirstBlock and
      readiness.fixtureReadiness.executionRunSequenceFirstBlock ==
        validation.fixture.execution.runSequenceFirstBlock and
      readiness.fixtureReadiness.executionAttemptedLayerCount ==
        validation.fixture.execution.attemptedLayerCount and
      readiness.fixtureReadiness.executionCompletedLayerCount ==
        validation.fixture.execution.completedLayerCount and
      readiness.fixtureReadiness.executionSkippedLayerCount ==
        validation.fixture.execution.skippedLayerCount and
      readiness.fixtureReadiness.executionFailedLayerCount ==
        validation.fixture.execution.failedLayerCount)
  check("NPU model fixed configured workspace oracle buffer terminal fields",
    readiness.executionRunnable == validation.executionRunnable and
      readiness.executed == validation.executed and
      readiness.completedLayerCount == validation.completedLayerCount and
      readiness.executionAttemptedLayerCount ==
        validation.executionAttemptedLayerCount and
      readiness.executionCompletedLayerCount ==
        validation.executionCompletedLayerCount and
      readiness.executionFailedLayerCount ==
        validation.executionFailedLayerCount and
      readiness.executionFirstFailedLayer ==
        validation.executionFirstFailedLayer and
      readiness.executionFirstFailedCaptured ==
        validation.executionFirstFailedCaptured and
      readiness.executionLastStarted == validation.executionLastStarted and
      readiness.executionLastCompleted ==
        validation.executionLastCompleted and
      readiness.executionLastTimedOut ==
        validation.executionLastTimedOut and
      readiness.executionLastInterruptObserved ==
        validation.executionLastInterruptObserved)

proc checkFixedConfiguredWorkspaceOracleBufferMaterialized() =
  var layer = BlaiCpuInstLayer64(
    layerType: ord(blaiConvolutional).int32,
    dspOn: 1,
    w: 1, h: 1, c: 1,
    outW: 1, outH: 1, outC: 1,
    size: 1, stride: 1, dilation: 1, groups: 1,
    dramNWeight: 1,
    dramNBias: 1,
    dramIn: [0'i32, 0, 0, 0, 0, 0, 0, 0],
    dramOut: [1'i32, 0, 0, 0, 0, 0, 0, 0],
    dramPatchSize: 4)
  let resources = blaiPlanForwardModelResources([layer], useTflite = true)
  let tensorPlan = blaiPlanForwardNpu(
    layer, layerIndex = 0, dataBufferBytes = resources.dataBufferBytes)
  layer.npuOn = 0
  var states = [BlaiCpuParsedLayerState(active: true, index: 0, layer: layer)]
  var reference: BlaiReferenceFixedParsedCheckedModelResult
  var fixedOutput: array[1, int8]
  var expected: array[1, uint8]
  var projection: BlaiInt8OutputRawByteProjectionResult
  buildFixedWorkspaceOracleReferenceWithOutput(
    reference, fixedOutput, expected, projection)
  var workspace {.align: 16.}: array[2048, uint8]
  let binding = blaiBindForwardWorkspaceBuffer(resources, workspace)
  if binding.bound:
    discard blaiWriteForwardWorkspaceSegmentByte(
      binding.workspace.data, workspace, 4, expected[0])
  var ctrl: BlaiPsramCtrl
  var stream: array[0, BlaiInstruction]
  var cpuWeights: array[0, uint8]
  var cpuBiases: array[0, uint8]
  var decodedWeights: array[0, int32]
  var decodedBiases: array[0, int32]
  var npuWeights: array[0, uint8]
  var npuBiases: array[0, int32]
  var temporaryWeights: array[0, int32]
  var output: array[1, uint8]
  var materialization: BlaiForwardModelWorkspaceMaterializeResult
  var validation:
    BlaiFixedParsedConfiguredWorkspaceOracleAddressFixtureResult
  blaiMaterializeAndValidateFixedParsedConfiguredWorkspaceOracleFixtureInto(
    reference, fixedOutput, states, useTflite = true,
    modelResources = resources, tensorPlan = tensorPlan, inputIndex = 0,
    input = [7'u8], expectedWorkspaceOutput = expected, output = output,
    ctrl = ctrl, stream = stream, workspaceBytes = workspace,
    cpuWeightBytes = cpuWeights, cpuBiasBytes = cpuBiases,
    decodedWeights = decodedWeights, decodedBiases = decodedBiases,
    npuWeightBytes = npuWeights, npuBiases = npuBiases,
    temporaryWeights = temporaryWeights, outMaterialization = materialization,
    outResult = validation, timeout = 11)
  check("NPU model fixed configured workspace oracle buffer materialized classified",
    validation.projected and validation.referenceValid and
      validation.valid ==
        (validation.firstBlock ==
          blaiFixedParsedConfiguredWorkspaceOracleAddressFixtureNoBlock) and
      ((validation.valid and materialization.allReady and
        materialization.skippedLayerCount == 1) or not validation.valid))
  let readiness =
    blaiFixedParsedConfiguredWorkspaceOracleAddressFixtureReadiness(
      validation)
  check("NPU model fixed configured workspace oracle buffer materialized execution gate",
    readiness.fixtureReadiness.executionFirstBlock ==
      validation.fixture.executionFirstBlock and
      readiness.fixtureReadiness.executionRunSequenceFirstBlock ==
        validation.fixture.execution.runSequenceFirstBlock and
      readiness.fixtureReadiness.executionSkippedLayerCount ==
        validation.fixture.execution.skippedLayerCount and
      readiness.fixtureReadiness.executionAttemptedLayerCount ==
        validation.fixture.execution.attemptedLayerCount)
  check("NPU model fixed configured workspace oracle buffer materialized terminal fields",
    readiness.executionRunnable == validation.executionRunnable and
      readiness.executed == validation.executed and
      readiness.completedLayerCount == validation.completedLayerCount and
      readiness.executionAttemptedLayerCount ==
        validation.executionAttemptedLayerCount and
      readiness.executionCompletedLayerCount ==
        validation.executionCompletedLayerCount and
      readiness.executionFailedLayerCount ==
        validation.executionFailedLayerCount and
      readiness.executionFirstFailedLayer ==
        validation.executionFirstFailedLayer and
      readiness.executionFirstFailedCaptured ==
        validation.executionFirstFailedCaptured and
      readiness.executionLastStarted == validation.executionLastStarted and
      readiness.executionLastCompleted ==
        validation.executionLastCompleted and
      readiness.executionLastTimedOut ==
        validation.executionLastTimedOut and
      readiness.executionLastInterruptObserved ==
        validation.executionLastInterruptObserved)

proc checkParsedConfiguredWorkspaceOracleExecutionGuard() =
  let layer = BlaiCpuInstLayer64(
    layerType: ord(blaiConvolutional).int32,
    npuOn: 1,
    dspOn: 1,
    w: 1, h: 1, c: 1,
    outW: 1, outH: 1, outC: 1,
    size: 1, stride: 1, dilation: 1, groups: 1,
    dramNWeight: 1,
    dramNBias: 1,
    dramIn: [0'i32, 0, 0, 0, 0, 0, 0, 0],
    dramOut: [1'i32, 0, 0, 0, 0, 0, 0, 0],
    dramPatchSize: 4)
  let rawLayers = [layer]
  var resources = blaiPlanForwardModelResources(
    rawLayers, useTflite = true)
  resources.weightBufferBytes = 0
  let tensorPlan = blaiPlanForwardNpu(
    layer, layerIndex = 0,
    dataBufferBytes = resources.dataBufferBytes)
  let states = [BlaiCpuParsedLayerState(active: true, index: 0, layer: layer)]
  var workspaceBytes {.align: 16.}: array[2048, uint8]

  var oracleLayers = [
    BlaiCpuParsedLayerState(
      active: true,
      index: 0,
      layer: BlaiCpuInstLayer64(
        layerType: ord(blaiConvolutional).int32,
        dspOn: 1,
        w: 1, h: 1, c: 1, outC: 1,
        outW: 1, outH: 1,
        size: 1, stride: 1, dilation: 1, groups: 1,
        tfInput1Offset: 0,
        tfInput2Offset: 0,
        tfOutputOffset: 0,
        tfOutputMultiplier: high(int32),
        tfOutputShift: 0,
        quantizedActivationMin: 0,
        quantizedActivationMax: 255))]
  var oracleBiases: array[1, int32]
  var oracleScratchA: array[1, uint8]
  var oracleScratchB: array[1, uint8]
  var oracleOutput: array[1, uint8]
  let oracleReference = blaiReferenceTfliteParsedCheckedModel2d(
    oracleLayers,
    useTflite = true,
    input = [33'u8],
    cpuWeightBytes = [2'u8],
    cpuBiasBytes = [0'u8, 0, 0, 0],
    decodedBiases = oracleBiases,
    scratchA = oracleScratchA,
    scratchB = oracleScratchB,
    output = oracleOutput)
  var tfliteExpected: array[1, uint8]
  var tfliteOutput: array[1, uint8]
  var tfliteBlocked:
    BlaiTfliteParsedConfiguredWorkspaceOracleAddressFixtureResult
  blaiValidateTfliteParsedConfiguredWorkspaceOracleAddressFixtureInto(
    oracleReference, oracleOutput, states, resources,
    workspaceBaseAddress = 0x220E_0000'u32, tensorPlan = tensorPlan,
    inputIndex = 0, input = [7'u8],
    expectedWorkspaceOutput = tfliteExpected, output = tfliteOutput,
    workspaceBytes = workspaceBytes, outResult = tfliteBlocked, timeout = 11)
  checkEq("NPU model TFLite configured workspace oracle exec block",
    tfliteBlocked.firstBlock.uint32,
    blaiTfliteParsedConfiguredWorkspaceOracleAddressFixtureFixture.uint32)
  checkEq("NPU model TFLite configured workspace oracle exec fixture block",
    tfliteBlocked.fixtureFirstBlock.uint32,
    blaiParsedForwardConfiguredWorkspaceFixtureExecution.uint32)
  let tfliteReadiness =
    blaiTfliteParsedConfiguredWorkspaceOracleAddressFixtureReadiness(
      tfliteBlocked)
  check("NPU model TFLite configured workspace oracle readiness exec",
    tfliteReadiness.firstBlock ==
      blaiTfliteParsedConfiguredWorkspaceOracleAddressFixtureFixture and
      tfliteReadiness.projected and tfliteReadiness.referenceValid and
      not tfliteReadiness.fixtureValid and
      not tfliteReadiness.outputValid and
      not tfliteReadiness.outputMatched and
      tfliteReadiness.completedLayerCount == 0 and
      tfliteReadiness.expectedElements == 0 and
      tfliteReadiness.actualElements == 0 and
      tfliteReadiness.comparedElements == 0 and
      tfliteReadiness.trailingElements == 0 and
      not tfliteReadiness.lengthMatches and
      tfliteReadiness.fixtureReadiness.firstBlock ==
        blaiParsedForwardConfiguredWorkspaceFixtureExecution and
      tfliteReadiness.fixtureReadiness.inputMoved and
      not tfliteReadiness.fixtureReadiness.executionRunnable)
  check("NPU model TFLite configured workspace oracle exec terminal",
    tfliteReadiness.fixtureReadiness.executionAttemptedLayerCount == 0 and
      tfliteReadiness.fixtureReadiness.executionCompletedLayerCount == 0 and
      tfliteReadiness.fixtureReadiness.executionFailedLayerCount == 0 and
      tfliteReadiness.fixtureReadiness.executionFirstFailedLayer < 0 and
      not tfliteReadiness.fixtureReadiness.executionFirstFailedCaptured and
      not tfliteReadiness.fixtureReadiness.executionFirstFailedStarted and
      not tfliteReadiness.fixtureReadiness.executionFirstFailedTimedOut and
      not tfliteReadiness.fixtureReadiness.executionLastStarted and
      not tfliteReadiness.fixtureReadiness.executionLastCompleted and
      not tfliteReadiness.fixtureReadiness.executionLastTimedOut and
      not tfliteReadiness.fixtureReadiness.executionLastInterruptObserved)
  check("NPU model TFLite configured workspace oracle exec top terminal",
    not tfliteBlocked.executionRunnable and not tfliteBlocked.executed and
      tfliteBlocked.executionAttemptedLayerCount == 0 and
      tfliteBlocked.executionCompletedLayerCount == 0 and
      tfliteBlocked.executionFailedLayerCount == 0 and
      tfliteBlocked.executionFirstFailedLayer < 0 and
      not tfliteBlocked.executionFirstFailedCaptured and
      not tfliteBlocked.executionLastStarted and
      not tfliteBlocked.executionLastCompleted and
      not tfliteBlocked.executionLastTimedOut and
      not tfliteBlocked.executionLastInterruptObserved and
      tfliteReadiness.executionAttemptedLayerCount ==
        tfliteBlocked.executionAttemptedLayerCount and
      tfliteReadiness.executionCompletedLayerCount ==
        tfliteBlocked.executionCompletedLayerCount and
      tfliteReadiness.executionFailedLayerCount ==
        tfliteBlocked.executionFailedLayerCount and
      tfliteReadiness.executionLastStarted ==
        tfliteBlocked.executionLastStarted)
  check("NPU model TFLite configured workspace oracle output readiness exec",
    not tfliteReadiness.outputReadiness.valid and
      not tfliteReadiness.outputReadiness.validation.outputMatched and
      tfliteReadiness.outputReadiness.comparedElements == 0 and
      tfliteReadiness.outputReadiness.mismatchCount == 0)
  check("NPU model TFLite configured workspace oracle equivalence exec",
    not tfliteBlocked.outputValid and not tfliteBlocked.outputMatched and
      tfliteBlocked.completedLayerCount == 0 and
      tfliteBlocked.expectedElements == 0 and
      tfliteBlocked.actualElements == 0 and
      tfliteBlocked.comparedElements == 0 and
      tfliteBlocked.trailingElements == 0 and
      not tfliteBlocked.lengthMatches and
      tfliteBlocked.mismatchCount == 0)

  var fixedReference: BlaiReferenceFixedParsedCheckedModelResult
  var fixedOutput: array[1, int8]
  var fixedExpected: array[1, uint8]
  var fixedProjection: BlaiInt8OutputRawByteProjectionResult
  buildFixedWorkspaceOracleReferenceWithOutput(
    fixedReference, fixedOutput, fixedExpected, fixedProjection)
  var fixedReadback: array[1, uint8]
  var fixedBlocked:
    BlaiFixedParsedConfiguredWorkspaceOracleAddressFixtureResult
  blaiValidateFixedParsedConfiguredWorkspaceOracleAddressFixtureInto(
    fixedReference, fixedOutput, states, resources,
    workspaceBaseAddress = 0x220E_0000'u32, tensorPlan = tensorPlan,
    inputIndex = 0, input = [7'u8],
    expectedWorkspaceOutput = fixedExpected, output = fixedReadback,
    workspaceBytes = workspaceBytes, outResult = fixedBlocked, timeout = 11)
  checkEq("NPU model fixed configured workspace oracle exec block",
    fixedBlocked.firstBlock.uint32,
    blaiFixedParsedConfiguredWorkspaceOracleAddressFixtureFixture.uint32)
  checkEq("NPU model fixed configured workspace oracle exec fixture block",
    fixedBlocked.fixtureFirstBlock.uint32,
    blaiParsedForwardConfiguredWorkspaceFixtureExecution.uint32)
  let fixedReadiness =
    blaiFixedParsedConfiguredWorkspaceOracleAddressFixtureReadiness(
      fixedBlocked)
  check("NPU model fixed configured workspace oracle readiness exec",
    fixedReadiness.firstBlock ==
      blaiFixedParsedConfiguredWorkspaceOracleAddressFixtureFixture and
      fixedReadiness.projected and fixedReadiness.referenceValid and
      not fixedReadiness.fixtureValid and
      not fixedReadiness.outputValid and
      not fixedReadiness.outputMatched and
      fixedReadiness.completedLayerCount == 0 and
      fixedReadiness.expectedElements == 0 and
      fixedReadiness.actualElements == 0 and
      fixedReadiness.comparedElements == 0 and
      fixedReadiness.trailingElements == 0 and
      not fixedReadiness.lengthMatches and
      fixedReadiness.fixtureReadiness.firstBlock ==
        blaiParsedForwardConfiguredWorkspaceFixtureExecution and
      fixedReadiness.fixtureReadiness.inputMoved and
      not fixedReadiness.fixtureReadiness.executionRunnable)
  check("NPU model fixed configured workspace oracle exec terminal",
    fixedReadiness.fixtureReadiness.executionAttemptedLayerCount == 0 and
      fixedReadiness.fixtureReadiness.executionCompletedLayerCount == 0 and
      fixedReadiness.fixtureReadiness.executionFailedLayerCount == 0 and
      fixedReadiness.fixtureReadiness.executionFirstFailedLayer < 0 and
      not fixedReadiness.fixtureReadiness.executionFirstFailedCaptured and
      not fixedReadiness.fixtureReadiness.executionFirstFailedStarted and
      not fixedReadiness.fixtureReadiness.executionFirstFailedTimedOut and
      not fixedReadiness.fixtureReadiness.executionLastStarted and
      not fixedReadiness.fixtureReadiness.executionLastCompleted and
      not fixedReadiness.fixtureReadiness.executionLastTimedOut and
      not fixedReadiness.fixtureReadiness.executionLastInterruptObserved)
  check("NPU model fixed configured workspace oracle exec top terminal",
    not fixedBlocked.executionRunnable and not fixedBlocked.executed and
      fixedBlocked.executionAttemptedLayerCount == 0 and
      fixedBlocked.executionCompletedLayerCount == 0 and
      fixedBlocked.executionFailedLayerCount == 0 and
      fixedBlocked.executionFirstFailedLayer < 0 and
      not fixedBlocked.executionFirstFailedCaptured and
      not fixedBlocked.executionLastStarted and
      not fixedBlocked.executionLastCompleted and
      not fixedBlocked.executionLastTimedOut and
      not fixedBlocked.executionLastInterruptObserved and
      fixedReadiness.executionAttemptedLayerCount ==
        fixedBlocked.executionAttemptedLayerCount and
      fixedReadiness.executionCompletedLayerCount ==
        fixedBlocked.executionCompletedLayerCount and
      fixedReadiness.executionFailedLayerCount ==
        fixedBlocked.executionFailedLayerCount and
      fixedReadiness.executionLastStarted ==
        fixedBlocked.executionLastStarted)
  check("NPU model fixed configured workspace oracle output readiness exec",
    not fixedReadiness.outputReadiness.valid and
      not fixedReadiness.outputReadiness.validation.outputMatched and
      fixedReadiness.outputReadiness.comparedElements == 0 and
      fixedReadiness.outputReadiness.mismatchCount == 0)
  check("NPU model fixed configured workspace oracle equivalence exec",
    not fixedBlocked.outputValid and not fixedBlocked.outputMatched and
      fixedBlocked.completedLayerCount == 0 and
      fixedBlocked.expectedElements == 0 and
      fixedBlocked.actualElements == 0 and
      fixedBlocked.comparedElements == 0 and
      fixedBlocked.trailingElements == 0 and
      not fixedBlocked.lengthMatches and
      fixedBlocked.mismatchCount == 0)

proc checkParsedConfiguredWorkspaceActiveMaterializedProbe() =
  var layer = BlaiCpuInstLayer64(
    layerType: ord(blaiConvolutional).int32,
    activation: ord(blaiActLinear).int32,
    npuOn: 1,
    dspOn: 1,
    dataType: 1,
    w: 1, h: 1, c: 1,
    outW: 1, outH: 1, outC: 1,
    size: 1, stride: 1, dilation: 1, groups: 1,
    dramNWeight: 1,
    dramNBias: 1,
    dramIn: [0'i32, 0, 0, 0, 0, 0, 0, 0],
    dramOut: [1'i32, 0, 0, 0, 0, 0, 0, 0],
    dramPatchSize: 4,
    tfInput1Offset: 0,
    tfInput2Offset: 0,
    tfOutputOffset: 0,
    tfOutputMultiplier: high(int32),
    tfOutputShift: 0,
    quantizedActivationMin: 0,
    quantizedActivationMax: 255,
    halt: 1)
  var states = [BlaiCpuParsedLayerState(active: true, index: 0, layer: layer)]
  let resources = blaiPlanForwardModelResources(states, useTflite = true)
  let tensorPlan = blaiPlanForwardNpu(
    layer, layerIndex = states[0].index, dataBufferBytes = resources.dataBufferBytes)
  for byte in activeNpuWorkspace.mitems:
    byte = 0
  let activeWorkspaceProjection =
    blaiProjectWorkspaceBufferAddress(activeNpuWorkspace)
  var ctrl: BlaiPsramCtrl
  var stream: array[BlaiInstructionScratchSize div BlaiInstructionSize,
                    BlaiInstruction]
  let cpuWeights = [2'u8]
  let cpuBiases = [0'u8, 0, 0, 0]
  var decodedWeights: array[1, int32]
  var decodedBiases: array[1, int32]
  var npuWeights: array[64, uint8]
  var npuBiases: array[1, int32]
  var temporaryWeights: array[0, int32]
  var activeSdkWeightBias {.align: 16.}: array[32, uint8]
  var output: array[1, uint8]
  var materialization: BlaiForwardModelWorkspaceMaterializeResult
  var fixture: BlaiParsedForwardConfiguredWorkspaceFixtureResult
  npuInit()
  npuSetClockEnable(false)
  npuConfigureNetParams(NpuNetParams(
    unsignedInput: true,
    reluN: 0,
    tensorflowMode: true))
  let activeNoLimiterPlan = npuBusLimiterPlan(
    0'u32, 0'u32, readMode = false, writeMode = false)
  npuApplyBusLimiterPlan(activeNoLimiterPlan)
  let activeDemoLimiterStatus = npuBlaiCommandStatus()
  logBlaiCommandStatus(
    "NPU model active no limiter status",
    activeDemoLimiterStatus)
  check("NPU model parsed configured workspace fixture active no limiter status",
    activeDemoLimiterStatus.valid)
  check("NPU model parsed configured workspace fixture active no limiter read",
    activeDemoLimiterStatus.codecLimiterRead == activeNoLimiterPlan.read and
      activeDemoLimiterStatus.readCommandCount == 0'u32 and
      not activeDemoLimiterStatus.readCommandMode)
  check("NPU model parsed configured workspace fixture active no limiter write",
    activeDemoLimiterStatus.codecLimiterWrite == activeNoLimiterPlan.write and
      activeDemoLimiterStatus.writeCommandCount == 0'u32 and
      not activeDemoLimiterStatus.writeCommandMode)
  let activeInitClock = npuClockStatus()
  let activeInitReset = npuResetStatus()
  let activeInitSram = npuSramStatus()
  let activeCommandSeed =
    (6'u32 shl BlaiReluNShift) or BlaiInterruptStatusMask
  let activeRuntimeInit = npuRuntimeInitEvidence(
    activeInitClock, activeInitReset, activeInitSram, activeCommandSeed)
  check("NPU model parsed configured workspace fixture active runtime init evidence",
    activeRuntimeInit.valid)
  check("NPU model parsed configured workspace fixture active runtime clock",
    activeRuntimeInit.clockValid)
  check("NPU model parsed configured workspace fixture active runtime clock disabled",
    activeRuntimeInit.clockDisabled)
  check("NPU model parsed configured workspace fixture active runtime clock source known",
    activeRuntimeInit.clockSourceKnown)
  check("NPU model parsed configured workspace fixture active runtime clock source",
    activeRuntimeInit.clockSourceMatches)
  check("NPU model parsed configured workspace fixture active runtime clock divider",
    activeRuntimeInit.clockDividerMatches)
  check("NPU model parsed configured workspace fixture active runtime reset",
    activeRuntimeInit.resetValid)
  check("NPU model parsed configured workspace fixture active runtime reset released",
    activeRuntimeInit.resetReleased)
  check("NPU model parsed configured workspace fixture active runtime reset not asserted",
    activeRuntimeInit.resetNotAsserted)
  check("NPU model parsed configured workspace fixture active runtime SRAM",
    activeRuntimeInit.sramValid)
  check("NPU model parsed configured workspace fixture active runtime SRAM released",
    activeRuntimeInit.sramReleased)
  check("NPU model parsed configured workspace fixture active runtime SRAM set self-cleared",
    activeRuntimeInit.sysramSetSelfCleared)
  check("NPU model parsed configured workspace fixture active int cfg command RMW",
    activeRuntimeInit.intCfgCommandsValid)
  check("NPU model parsed configured workspace fixture active int cfg start command",
    activeRuntimeInit.startCommandMatches)
  check("NPU model parsed configured workspace fixture active int cfg resume command",
    activeRuntimeInit.resumeCommandMatches)
  check("NPU model parsed configured workspace fixture active int cfg stop command",
    activeRuntimeInit.stopCommandMatches)
  check("NPU model parsed configured workspace fixture active int cfg clear command",
    activeRuntimeInit.interruptClearCommandMatches)
  var activeBinding: BlaiForwardWorkspaceBufferBinding
  blaiBindForwardWorkspaceAddressInto(
    resources, activeWorkspaceProjection.hardwareAddress,
    blaiBufferLenU32(activeNpuWorkspace.len), activeBinding)
  fixture.binding = activeBinding
  if activeBinding.bound:
    blaiMaterializeForwardModelWorkspaceInto(
      states, useTflite = true, ctrl = ctrl, stream = stream,
      modelResources = resources, workspace = activeBinding.workspace,
      workspaceBytes = activeNpuWorkspace, cpuWeightBytes = cpuWeights,
      cpuBiasBytes = cpuBiases, decodedWeights = decodedWeights,
      decodedBiases = decodedBiases, npuWeightBytes = npuWeights,
      npuBiases = npuBiases, temporaryWeights = temporaryWeights,
      outResult = materialization)
  var activeSdkTemp: BlaiForwardNpuTemporaryWeightBiasBufferResult
  if materialization.allReady:
    let activeTempWeightBytes =
      materialization.lastLayer.weights.workspace.weightBytes
    let activeTempBiasBytes =
      materialization.lastLayer.weights.workspace.biasBytes
    activeSdkTemp = blaiPrepareForwardNpuTemporaryWeightBiasBuffer(
      npuWeights, activeTempWeightBytes, npuBiases, activeTempBiasBytes,
      activeSdkWeightBias)
    if activeSdkTemp.prepared:
      blaiValidateParsedForwardConfiguredWorkspaceAddressFixtureWithLayerBuffersInto(
        states, modelResources = resources,
        workspaceBaseAddress = activeWorkspaceProjection.hardwareAddress,
        tensorPlan = tensorPlan, inputIndex = 0, input = [7'u8],
        expectedOutput = [0'u8], output = output,
        workspaceBytes = activeNpuWorkspace,
        layerBuffers = NpuLayerBuffers(
          instAddr: activeBinding.workspace.instruction.address,
          weightAddr: activeSdkTemp.weightAddr,
          biasAddr: activeSdkTemp.biasAddr),
        outResult = fixture, timeout = 11)
  let activeWorkspace = blaiPlanForwardModelWorkspace(
    resources, baseAddress = activeWorkspaceProjection.hardwareAddress)
  let activeWeightPlan = blaiPlanNpuWeightLoad(states[0].layer, useTflite = true)
  let activePackedWeightBytes =
    blaiNpuPackedWeightBytes(states[0].layer, useTflite = true)
  let activeWeightTileUnits =
    blaiNpuWeightKernelTileUnits(states[0].layer, activeWeightPlan)
  let activeWorkspaceWramEvidence = blaiForwardWorkspaceWramEvidence(
    activeWorkspaceProjection, activeWorkspace)
  check("NPU model parsed configured workspace fixture active workspace WRAM evidence",
    activeWorkspaceWramEvidence.valid)
  check("NPU model parsed configured workspace fixture active workspace WRAM projected",
    activeWorkspaceWramEvidence.projectionValid)
  check("NPU model parsed configured workspace fixture active workspace WRAM address projected",
    activeWorkspaceWramEvidence.projected)
  check("NPU model parsed configured workspace fixture active workspace WRAM address fits",
    activeWorkspaceWramEvidence.addressFits)
  check("NPU model parsed configured workspace fixture active workspace WRAM alias",
    activeWorkspaceWramEvidence.aliasMatches)
  check("NPU model parsed configured workspace fixture active workspace WRAM base",
    activeWorkspaceWramEvidence.baseInWram)
  check("NPU model parsed configured workspace fixture active workspace WRAM segments",
    activeWorkspaceWramEvidence.segmentsInWram)
  check("NPU model parsed configured workspace fixture active workspace WRAM instruction",
    activeWorkspaceWramEvidence.instructionInWram)
  check("NPU model parsed configured workspace fixture active workspace WRAM data",
    activeWorkspaceWramEvidence.dataInWram)
  check("NPU model parsed configured workspace fixture active workspace WRAM weight",
    activeWorkspaceWramEvidence.weightInWram)
  check("NPU model parsed configured workspace fixture active workspace WRAM bias",
    activeWorkspaceWramEvidence.biasInWram)
  let readiness = blaiParsedForwardConfiguredWorkspaceFixtureReadiness(fixture)
  let snapshot = blaiParsedForwardConfiguredWorkspaceFixtureGateSnapshot(
    materialization, fixture)
  let activeClassification =
    blaiParsedForwardConfiguredWorkspaceClassificationEvidence(
      materialization, readiness, fixture)
  check("NPU model parsed configured workspace fixture active classification evidence",
    activeClassification.valid)
  check("NPU model parsed configured workspace fixture active materialized classified",
    activeClassification.materializationFirstBlockKnown)
  check("NPU model parsed configured workspace fixture active materialization classification valid",
    activeClassification.materializationValid)
  let activeMaterializationEvidence =
    blaiForwardModelWorkspaceMaterializeActiveEvidence(
      materialization,
      expectedStorageLayerCount = states.len.uint32,
      expectedModelLayerCount = resources.layerCount,
      expectedSkippedLayerCount = 0'u32,
      expectedAttemptedLayerCount = 1'u32,
      expectedReadyLayerCount = 1'u32,
      expectedLastReadyLayer = 0'i32)
  check("NPU model parsed configured workspace fixture active materialization evidence",
    activeMaterializationEvidence.valid)
  check("NPU model parsed configured workspace fixture active materialization storage layers",
    activeMaterializationEvidence.storageLayerCountMatches)
  check("NPU model parsed configured workspace fixture active materialization expected layers",
    activeMaterializationEvidence.expectedLayerCountMatches)
  check("NPU model parsed configured workspace fixture active materialization skipped layers",
    activeMaterializationEvidence.skippedLayerCountMatches)
  check("NPU model parsed configured workspace fixture active materialization attempted layers",
    activeMaterializationEvidence.attemptedLayerCountMatches)
  check("NPU model parsed configured workspace fixture active materialization ready layers",
    activeMaterializationEvidence.readyLayerCountMatches)
  check("NPU model parsed configured workspace fixture active materialization no missing",
    activeMaterializationEvidence.noMissingLayers)
  check("NPU model parsed configured workspace fixture active materialization no blocked",
    activeMaterializationEvidence.noBlockedLayers)
  check("NPU model parsed configured workspace fixture active materialization no first blocked",
    activeMaterializationEvidence.noFirstBlockedLayer)
  check("NPU model parsed configured workspace fixture active materialization last ready",
    activeMaterializationEvidence.lastReadyLayerMatches)
  check("NPU model parsed configured workspace fixture active materialization first none evidence",
    activeMaterializationEvidence.firstBlockNone)
  check("NPU model parsed configured workspace fixture active materialization readiness first block",
    activeMaterializationEvidence.readinessFirstBlockMatches)
  check("NPU model parsed configured workspace fixture active materialization all ready mirror",
    activeMaterializationEvidence.allReadyMatchesReadiness)
  check("NPU model parsed configured workspace fixture active materialization readiness ready",
    activeMaterializationEvidence.readinessReady)
  if materialization.allReady:
    check("NPU model parsed configured workspace fixture active materialization all ready",
      true)
  else:
    check("NPU model parsed configured workspace fixture active materialization blocked",
      true)
  let activeStreamEvidence = blaiForwardWorkspaceInstructionStreamEvidence(
    states[0].layer, ctrl, stream, useTflite = true)
  let activeStreamSemantics =
    blaiForwardWorkspaceInstructionStreamSemanticEvidence(
      activeStreamEvidence, states[0].layer, stream)
  check("NPU model parsed configured workspace fixture active stream semantic evidence",
    activeStreamSemantics.valid)
  check("NPU model parsed configured workspace fixture active stream operand plan",
    activeStreamSemantics.operandPlanMatches)
  check("NPU model parsed configured workspace fixture active operand c2 zero",
    activeStreamSemantics.operandC2ZeroMatches)
  check("NPU model parsed configured workspace fixture active operand no extra info",
    activeStreamSemantics.operandNoExtraInfoMatches)
  check("NPU model parsed configured workspace fixture active operand single input c2",
    activeStreamSemantics.operandSingleInputC2Matches)
  check("NPU model parsed configured workspace fixture active operand no weight patch extra",
    activeStreamSemantics.operandNoWeightPatchExtraMatches)
  check("NPU model parsed configured workspace fixture active operand no line patch extra",
    activeStreamSemantics.operandNoLinePatchExtraMatches)
  check("NPU model parsed configured workspace fixture active operand no grouped extra",
    activeStreamSemantics.operandNoGroupedExtraMatches)
  check("NPU model parsed configured workspace fixture active operand no stride extra",
    activeStreamSemantics.operandNoStrideExtraMatches)
  check("NPU model parsed configured workspace fixture active operand no dilation extra",
    activeStreamSemantics.operandNoDilationExtraMatches)
  check("NPU model parsed configured workspace fixture active stream one layer",
    activeStreamSemantics.oneLayer)
  check("NPU model parsed configured workspace fixture active stream instruction count",
    activeStreamSemantics.instructionCountMatches)
  check("NPU model parsed configured workspace fixture active stream decoded layer count",
    activeStreamSemantics.decodedLayerCountMatches)
  check("NPU model parsed configured workspace fixture active layer semantics",
    activeStreamSemantics.layerSemanticsMatch)
  check("NPU model parsed configured workspace fixture active layer linear activation",
    activeStreamSemantics.layerLinearActivationMatches)
  check("NPU model parsed configured workspace fixture active layer data type",
    activeStreamSemantics.layerDataTypeMatches)
  check("NPU model parsed configured workspace fixture active stream evidence",
    activeStreamSemantics.streamEvidenceValid)
  check("NPU model parsed configured workspace fixture active stream fetch plan fits",
    activeStreamSemantics.streamFetchPlanFits)
  check("NPU model parsed configured workspace fixture active stream encode fits",
    activeStreamSemantics.streamEncodeFits)
  check("NPU model parsed configured workspace fixture active stream bundle matches",
    activeStreamSemantics.streamBundleMatches)
  check("NPU model parsed configured workspace fixture active stream bundle count bounds",
    activeStreamSemantics.streamBundleEndCountInBounds)
  check("NPU model parsed configured workspace fixture active stream bundle bytes equal",
    activeStreamSemantics.streamBundleBytesEqual)
  check("NPU model parsed configured workspace fixture active stream layer index bounds",
    activeStreamSemantics.streamLayerInstructionInBounds)
  check("NPU model parsed configured workspace fixture active stream no extra",
    activeStreamSemantics.noExtra)
  check("NPU model parsed configured workspace fixture active stream no external info",
    activeStreamSemantics.noExternalLayerInfo)
  check("NPU model parsed configured workspace fixture active stream default layer index",
    activeStreamSemantics.defaultLayerInstructionIndex)
  check("NPU model parsed configured workspace fixture active stream halt",
    activeStreamSemantics.halt)
  check("NPU model parsed configured workspace fixture active stream type",
    activeStreamSemantics.typeMatches)
  check("NPU model parsed configured workspace fixture active stream w",
    activeStreamSemantics.widthMatches)
  check("NPU model parsed configured workspace fixture active stream h",
    activeStreamSemantics.heightMatches)
  check("NPU model parsed configured workspace fixture active stream c",
    activeStreamSemantics.inputChannelsMatch)
  check("NPU model parsed configured workspace fixture active stream c2",
    activeStreamSemantics.c2Matches)
  check("NPU model parsed configured workspace fixture active stream out c",
    activeStreamSemantics.outputChannelsMatch)
  check("NPU model parsed configured workspace fixture active stream size",
    activeStreamSemantics.kernelSizeMatches)
  check("NPU model parsed configured workspace fixture active stream slots",
    activeStreamSemantics.slotsMatch)
  check("NPU model parsed configured workspace fixture active stream input slot",
    activeStreamSemantics.inputSlotMatches)
  check("NPU model parsed configured workspace fixture active stream output slot",
    activeStreamSemantics.outputSlotMatches)
  check("NPU model parsed configured workspace fixture active stream stride",
    activeStreamSemantics.strideMatches)
  check("NPU model parsed configured workspace fixture active stream stride step",
    activeStreamSemantics.strideStepMatches)
  check("NPU model parsed configured workspace fixture active stream dilation",
    activeStreamSemantics.dilationMatches)
  check("NPU model parsed configured workspace fixture active stream groups",
    activeStreamSemantics.groupsMatches)
  check("NPU model parsed configured workspace fixture active stream fractions",
    activeStreamSemantics.fractionsMatch)
  check("NPU model parsed configured workspace fixture active stream fdata",
    activeStreamSemantics.fdataMatches)
  check("NPU model parsed configured workspace fixture active stream fweight",
    activeStreamSemantics.fweightMatches)
  check("NPU model parsed configured workspace fixture active stream fbias",
    activeStreamSemantics.fbiasMatches)
  check("NPU model parsed configured workspace fixture active stream fout",
    activeStreamSemantics.foutMatches)
  check("NPU model parsed configured workspace fixture active stream activation",
    activeStreamSemantics.activationMatches)
  check("NPU model parsed configured workspace fixture active stream activation kind",
    activeStreamSemantics.activationKindMatches)
  check("NPU model parsed configured workspace fixture active stream TF output offset",
    activeStreamSemantics.tfOutputOffsetMatches)
  check("NPU model parsed configured workspace fixture active decoded TFLite descriptor",
    activeStreamEvidence.decodedTfliteDescriptor.shape.layerW == layer.w.uint32 and
      activeStreamEvidence.decodedTfliteDescriptor.shape.layerO ==
        layer.outC.uint32 and
      activeStreamEvidence.decodedTfliteDescriptor.tfOutputShift ==
        layer.tfOutputShift)
  check("NPU model parsed configured workspace fixture active TFLite input offsets",
    activeStreamSemantics.tfliteInput1OffsetMatches and
      activeStreamSemantics.tfliteInput2OffsetMatches)
  check("NPU model parsed configured workspace fixture active TFLite output shift",
    activeStreamSemantics.tfliteOutputShiftMatches)
  check("NPU model parsed configured workspace fixture active quant side",
    activeStreamSemantics.quantSideMatches)
  check("NPU model parsed configured workspace fixture active decoded quant",
    activeStreamEvidence.decodedQuant.isTflite and
      activeStreamEvidence.decodedQuant.tfInput1Shift == layer.tfInput1Shift and
      activeStreamEvidence.decodedQuant.tfOutputMultiplier ==
        cast[uint32](layer.tfOutputMultiplier) and
      activeStreamEvidence.decodedQuant.quantizedActivationMax ==
        layer.quantizedActivationMax.uint32)
  check("NPU model parsed configured workspace fixture active quant TFLite flag",
    activeStreamSemantics.quantTfliteFlagMatches)
  check("NPU model parsed configured workspace fixture active quant input1 shift",
    activeStreamSemantics.quantInput1ShiftMatches)
  check("NPU model parsed configured workspace fixture active quant input2 shift",
    activeStreamSemantics.quantInput2ShiftMatches)
  check("NPU model parsed configured workspace fixture active quant multipliers",
    activeStreamSemantics.quantMultipliersMatch)
  check("NPU model parsed configured workspace fixture active quant input1 multiplier",
    activeStreamSemantics.quantInput1MultiplierMatches)
  check("NPU model parsed configured workspace fixture active quant input2 multiplier",
    activeStreamSemantics.quantInput2MultiplierMatches)
  check("NPU model parsed configured workspace fixture active quant output multiplier",
    activeStreamSemantics.quantOutputMultiplierMatches)
  check("NPU model parsed configured workspace fixture active quant clamp",
    activeStreamSemantics.quantClampMatches)
  check("NPU model parsed configured workspace fixture active quant activation min",
    activeStreamSemantics.quantActivationMinMatches)
  check("NPU model parsed configured workspace fixture active quant activation max",
    activeStreamSemantics.quantActivationMaxMatches)
  check("NPU model parsed configured workspace fixture active common control",
    activeStreamSemantics.commonControlMatches)
  check("NPU model parsed configured workspace fixture active decoded common",
    activeStreamEvidence.decodedLayer.macBit == 1'u32 and
      activeStreamEvidence.decodedLayer.midLayerMem ==
        activeStreamEvidence.fetchPlan.midOutputSlot and
      activeStreamEvidence.decodedLayer.instEndBit)
  let decodedExtraProbe = decodeBlaiExtraInstruction(
    blaiEncodeExtraDescriptor(BlaiNpuExtraDescriptor(
      isExtra: true,
      inSegW: 31,
      outSegW: 15,
      outW: 14,
      inGroupC: 4,
      outGroupC: 5,
      outSegC: 10,
      outH: 13,
      stride: 2,
      dilation: 3,
      leftShift: -2)))
  check("NPU model decoded extra instruction",
    decodedExtraProbe.isExtra and
      decodedExtraProbe.inSegW == 31'u32 and
      decodedExtraProbe.outSegW == 15'u32 and
      decodedExtraProbe.outW == 14'u32 and
      decodedExtraProbe.inGroupC == 4'u32 and
      decodedExtraProbe.outGroupC == 5'u32 and
      decodedExtraProbe.outSegC == 10'u32 and
      decodedExtraProbe.outH == 13'u32 and
      decodedExtraProbe.stride == 2'u32 and
      decodedExtraProbe.dilation == 3'u32 and
      decodedExtraProbe.leftShift == -2)
  let decodedNormalProbe = decodeBlaiNormalDescriptorInstruction(
    blaiEncodeNormalDescriptor(BlaiNpuNormalDescriptor(
      shape: BlaiNpuShapeDescriptor(layerW: 9, layerH: 8, layerC1: 7,
                                    layerC2: 6, layerO: 5),
      fdata: 1,
      fweight: 2,
      fbias: 3,
      froute1: 4,
      froute2: 5,
      fout: 6,
      convSize: 3,
      activation: 2)))
  check("NPU model decoded normal descriptor",
    decodedNormalProbe.shape.layerW == 9'u32 and
      decodedNormalProbe.shape.layerH == 8'u32 and
      decodedNormalProbe.shape.layerC1 == 7'u32 and
      decodedNormalProbe.shape.layerC2 == 6'u32 and
      decodedNormalProbe.shape.layerO == 5'u32 and
      decodedNormalProbe.fdata == 1'u32 and
      decodedNormalProbe.fweight == 2'u32 and
      decodedNormalProbe.fbias == 3'u32 and
      decodedNormalProbe.froute1 == 4'u32 and
      decodedNormalProbe.froute2 == 5'u32 and
      decodedNormalProbe.fout == 6'u32 and
      decodedNormalProbe.convSize == 3'u32 and
      decodedNormalProbe.activation == 2'u32)
  check("NPU model parsed configured workspace fixture active common img in",
    activeStreamSemantics.commonImgInMatches)
  check("NPU model parsed configured workspace fixture active common max check",
    activeStreamSemantics.commonMaxCheckMatches)
  check("NPU model parsed configured workspace fixture active common route bit",
    activeStreamSemantics.commonRouteBitMatches)
  check("NPU model parsed configured workspace fixture active common mac bit",
    activeStreamSemantics.commonMacBitMatches)
  check("NPU model parsed configured workspace fixture active common mid layer",
    activeStreamSemantics.commonMidLayerMatches)
  check("NPU model parsed configured workspace fixture active common mid out",
    activeStreamSemantics.commonMidOutMatches)
  check("NPU model parsed configured workspace fixture active common mid state",
    activeStreamSemantics.commonMidOutStateClear)
  check("NPU model parsed configured workspace fixture active common upsample",
    activeStreamSemantics.commonUpsampleClear)
  check("NPU model parsed configured workspace fixture active common mac ext",
    activeStreamSemantics.commonMacBitExtClear)
  check("NPU model parsed configured workspace fixture active common inst end",
    activeStreamSemantics.commonInstEndMatches)
  check("NPU model parsed configured workspace fixture active bundle plan",
    activeStreamSemantics.bundlePlanValid)
  check("NPU model parsed configured workspace fixture active bundle fetch fits",
    activeStreamSemantics.bundleFetchFits)
  check("NPU model parsed configured workspace fixture active bundle TFLite mode",
    activeStreamSemantics.bundleTfliteModeMatches)
  check("NPU model parsed configured workspace fixture active bundle extra info",
    activeStreamSemantics.bundleExtraInfoMatches)
  check("NPU model parsed configured workspace fixture active bundle encode fits",
    activeStreamSemantics.bundleEncodeFits)
  check("NPU model parsed configured workspace fixture active bundle end count",
    activeStreamSemantics.bundleEndCountMatches)
  check("NPU model parsed configured workspace fixture active bundle bytes",
    activeStreamSemantics.bundleBytesMatch)
  let activeRunPlan = blaiPlanForwardNpuRun(
    layer, layerIndex = states[0].index, dataBufferBytes = resources.dataBufferBytes,
    instAddr = activeWorkspace.instruction.address,
    dataBufferAddr = activeWorkspace.data.address,
    weightAddr = activeSdkTemp.weightAddr,
    biasAddr = activeSdkTemp.biasAddr)
  let activeRunEvidence = blaiForwardNpuRunPlanEvidence(
    activeRunPlan, expectedLayerIndex = states[0].index,
    expectedFirstLayer = true, expectedResetUnsignedInput = false,
    expectedInstAddr = activeWorkspace.instruction.address,
    expectedDataAddr = activeWorkspace.data.address,
    expectedWeightAddr = activeSdkTemp.weightAddr,
    expectedBiasAddr = activeSdkTemp.biasAddr,
    expectedPatchSize = states[0].layer.dramPatchSize.uint32)
  check("NPU model parsed configured workspace fixture active run plan evidence",
    activeRunEvidence.valid)
  check("NPU model parsed configured workspace fixture active config SDK index",
    activeRunEvidence.sdkPolicyMatches)
  check("NPU model parsed configured workspace fixture active config layer index",
    activeRunEvidence.sdkIndexMatches)
  check("NPU model parsed configured workspace fixture active config first layer",
    activeRunEvidence.firstLayerMatches)
  check("NPU model parsed configured workspace fixture active config reset input",
    activeRunEvidence.resetUnsignedInputMatches)
  check("NPU model parsed configured workspace fixture active config patch",
    activeRunEvidence.patchSizeMatches)
  check("NPU model parsed configured workspace fixture active config buffers",
    activeRunEvidence.bufferAddressesMatch)
  check("NPU model parsed configured workspace fixture active config instruction address",
    activeRunEvidence.instructionAddrMatches)
  check("NPU model parsed configured workspace fixture active config weight address",
    activeRunEvidence.weightAddrMatches)
  check("NPU model parsed configured workspace fixture active config bias address",
    activeRunEvidence.biasAddrMatches)
  check("NPU model parsed configured workspace fixture active config data address",
    activeRunEvidence.dataAddrMatches)
  check("NPU model parsed configured workspace fixture active config first data cache",
    activeRunEvidence.firstDataCachePlanValid)
  check("NPU model parsed configured workspace fixture active config first cache present",
    activeRunEvidence.firstCacheRangePresent)
  check("NPU model parsed configured workspace fixture active config first cache clean",
    activeRunEvidence.firstCacheRangeClean)
  check("NPU model parsed configured workspace fixture active config first cache offset",
    activeRunEvidence.firstCacheRangeOffsetMatches)
  check("NPU model parsed configured workspace fixture active config first cache bytes",
    activeRunEvidence.firstCacheRangeBytesFitPatch)
  let activeDataSlots = blaiForwardWorkspaceDataSlotEvidence(
    activeWorkspace, activeNpuWorkspace, states[0].layer, inputIndex = 0,
    expectedInputByte = 7'u8)
  check("NPU model parsed configured workspace fixture active data slot evidence",
    activeDataSlots.valid)
  check("NPU model parsed configured workspace fixture active data slots",
    activeDataSlots.slotsValid)
  check("NPU model parsed configured workspace fixture active data slots distinct",
    activeDataSlots.slotsDistinct)
  check("NPU model parsed configured workspace fixture active data input offset",
    activeDataSlots.inputOffsetMatches)
  check("NPU model parsed configured workspace fixture active data output offset",
    activeDataSlots.outputOffsetMatches)
  check("NPU model parsed configured workspace fixture active data input fits",
    activeDataSlots.inputFits)
  check("NPU model parsed configured workspace fixture active data output fits",
    activeDataSlots.outputFits)
  check("NPU model parsed configured workspace fixture active input staged present",
    activeDataSlots.stagedInputPresent)
  check("NPU model parsed configured workspace fixture active input staged byte",
    activeDataSlots.stagedInputMatches)
  let activeDataMapping =
    blaiForwardActiveDataMappingEvidence(activeRunEvidence, activeDataSlots)
  check("NPU model parsed configured workspace fixture active DATA mapping evidence",
    activeDataMapping.valid)
  check("NPU model parsed configured workspace fixture active DATA mapping run plan",
    activeDataMapping.runPlanValid)
  check("NPU model parsed configured workspace fixture active DATA mapping slots",
    activeDataMapping.dataSlotsValid)
  check("NPU model parsed configured workspace fixture active DATA mapping patch",
    activeDataMapping.patchSizeMatches)
  check("NPU model parsed configured workspace fixture active DATA mapping distinct",
    activeDataMapping.inputOutputDistinct)
  check("NPU model parsed configured workspace fixture active DATA mapping staged input",
    activeDataMapping.stagedInputReady)
  check("NPU model parsed configured workspace fixture active DATA mapping output",
    activeDataMapping.outputSlotReady)
  check("NPU model parsed configured workspace fixture active DATA mapping first cache",
    activeDataMapping.firstDataCacheReady)
  let activeInstructionCount = states[0].layer.instCnt.uint32
  let activeWeightBytes = materialization.lastLayer.weights.workspace.weightBytes
  let activeBiasBytes = materialization.lastLayer.weights.workspace.biasBytes
  logActiveFetchSurface(
    "NPU model active fetch surface",
    activeWorkspace,
    activeNpuWorkspace,
    stream,
    activeInstructionCount,
    activeDataSlots,
    activeSdkTemp.weightAddr,
    activeSdkTemp.biasAddr,
    activeWeightBytes,
    activeBiasBytes,
    npuWeights,
    npuBiases)
  let activeWorkspaceBytes = blaiForwardWorkspaceMaterializedByteEvidence(
    activeWorkspace, activeNpuWorkspace, stream, activeInstructionCount,
    npuWeights, materialization.lastLayer.weights.workspace.weightBytes,
    npuBiases, materialization.lastLayer.weights.workspace.biasBytes)
  check("NPU model parsed configured workspace fixture active workspace byte evidence",
    activeWorkspaceBytes.workspaceBytesValid)
  check("NPU model parsed configured workspace fixture active workspace stream bytes",
    activeWorkspaceBytes.streamBytesValid)
  check("NPU model parsed configured workspace fixture active workspace instruction byte count",
    activeWorkspaceBytes.instructionByteCountMatches)
  check("NPU model parsed configured workspace fixture active workspace instruction fits",
    activeWorkspaceBytes.instructionFits)
  check("NPU model parsed configured workspace fixture active workspace instruction bytes",
    activeWorkspaceBytes.instructionMatches)
  check("NPU model parsed configured workspace fixture active workspace stream trailing",
    activeWorkspaceBytes.trailingInstructionValid)
  check("NPU model parsed configured workspace fixture active workspace trailing fits",
    activeWorkspaceBytes.trailingInstructionFits)
  check("NPU model parsed configured workspace fixture active workspace trailing zero",
    activeWorkspaceBytes.trailingInstructionZero)
  check("NPU model parsed configured workspace fixture active workspace weight bytes",
    activeWorkspaceBytes.weightBytesValid)
  check("NPU model parsed configured workspace fixture active workspace weight fits",
    activeWorkspaceBytes.weightFits)
  check("NPU model parsed configured workspace fixture active workspace weight matches",
    activeWorkspaceBytes.weightMatches)
  check("NPU model parsed configured workspace fixture active workspace bias bytes",
    activeWorkspaceBytes.biasBytesValid)
  check("NPU model parsed configured workspace fixture active workspace bias aligned",
    activeWorkspaceBytes.biasAligned)
  check("NPU model parsed configured workspace fixture active workspace bias fits",
    activeWorkspaceBytes.biasFits)
  check("NPU model parsed configured workspace fixture active workspace bias matches",
    activeWorkspaceBytes.biasMatches)
  let activePackedWeightEvidence = blaiNpuPackedWeightBiasEvidence(
    activeWeightPlan, activePackedWeightBytes, activeWeightBytes,
    materialization.lastLayer.weights.weights.weights.weightCursor,
    activeWeightTileUnits, npuWeights, cpuWeights[0],
    states[0].layer.tfInput2Offset, activeBiasBytes,
    materialization.lastLayer.weights.weights.weights.biasCursor,
    npuBiases, expectedFirstBias = 0)
  check("NPU model parsed configured workspace fixture active packed weight evidence",
    activePackedWeightEvidence.valid)
  check("NPU model parsed configured workspace fixture active weight plan",
    activePackedWeightEvidence.planValid)
  check("NPU model parsed configured workspace fixture active packed weight bytes",
    activePackedWeightEvidence.packedBytesValid)
  check("NPU model parsed configured workspace fixture active packed weight byte count",
    activePackedWeightEvidence.packedWeightBytesMatch)
  check("NPU model parsed configured workspace fixture active materialized weight byte count",
    activePackedWeightEvidence.materializedWeightBytesMatch)
  check("NPU model parsed configured workspace fixture active weight cursor",
    activePackedWeightEvidence.weightCursorMatches)
  check("NPU model parsed configured workspace fixture active packed weight tile",
    activePackedWeightEvidence.tileValid)
  check("NPU model parsed configured workspace fixture active packed tile units",
    activePackedWeightEvidence.tileUnitsMatch)
  check("NPU model parsed configured workspace fixture active packed first weight present",
    activePackedWeightEvidence.firstWeightBytePresent)
  check("NPU model parsed configured workspace fixture active packed first weight byte",
    activePackedWeightEvidence.firstWeightByteMatches)
  check("NPU model parsed configured workspace fixture active packed first padding byte",
    activePackedWeightEvidence.firstPaddingByteMatches)
  check("NPU model parsed configured workspace fixture active packed last padding byte",
    activePackedWeightEvidence.lastPaddingByteMatches)
  check("NPU model parsed configured workspace fixture active bias pack",
    activePackedWeightEvidence.biasValid)
  check("NPU model parsed configured workspace fixture active bias bytes",
    activePackedWeightEvidence.biasBytesMatch)
  check("NPU model parsed configured workspace fixture active bias cursor",
    activePackedWeightEvidence.biasCursorMatches)
  check("NPU model parsed configured workspace fixture active first bias present",
    activePackedWeightEvidence.firstBiasPresent)
  check("NPU model parsed configured workspace fixture active first bias word",
    activePackedWeightEvidence.firstBiasMatches)
  let activeSdkTempEvidence = blaiForwardNpuTemporaryWeightBiasBufferEvidence(
    activeSdkTemp, activeSdkWeightBias, npuWeights, activeWeightBytes,
    npuBiases, activeBiasBytes)
  check("NPU model parsed configured workspace fixture active SDK temp evidence",
    activeSdkTempEvidence.valid)
  check("NPU model parsed configured workspace fixture active SDK temp projected",
    activeSdkTempEvidence.projectionValid)
  check("NPU model parsed configured workspace fixture active SDK temp address projected",
    activeSdkTempEvidence.projected)
  check("NPU model parsed configured workspace fixture active SDK temp address fits",
    activeSdkTempEvidence.addressFits)
  check("NPU model parsed configured workspace fixture active SDK temp address range",
    activeSdkTempEvidence.addressRangeFits)
  check("NPU model parsed configured workspace fixture active SDK temp weight aligned",
    activeSdkTempEvidence.weightAligned)
  check("NPU model parsed configured workspace fixture active SDK temp bias address",
    activeSdkTempEvidence.biasAddressMatches)
  check("NPU model parsed configured workspace fixture active SDK temp typed result",
    activeSdkTempEvidence.typedResultValid)
  check("NPU model parsed configured workspace fixture active SDK temp prepared",
    activeSdkTempEvidence.prepared)
  check("NPU model parsed configured workspace fixture active SDK temp buffer fits",
    activeSdkTempEvidence.bufferFits)
  check("NPU model parsed configured workspace fixture active SDK temp weight fits",
    activeSdkTempEvidence.weightFits)
  check("NPU model parsed configured workspace fixture active SDK temp bias aligned",
    activeSdkTempEvidence.biasAligned)
  check("NPU model parsed configured workspace fixture active SDK temp bias fits",
    activeSdkTempEvidence.biasFits)
  check("NPU model parsed configured workspace fixture active SDK temp weight bytes",
    activeSdkTempEvidence.weightBytesMatch)
  check("NPU model parsed configured workspace fixture active SDK temp bias bytes",
    activeSdkTempEvidence.biasBytesMatch)
  check("NPU model parsed configured workspace fixture active SDK temp bias offset",
    activeSdkTempEvidence.biasOffsetMatches)
  check("NPU model parsed configured workspace fixture active SDK temp bytes",
    activeSdkTempEvidence.bytesValid)
  check("NPU model parsed configured workspace fixture active SDK temp weight buffer present",
    activeSdkTempEvidence.weightBufferPresent)
  check("NPU model parsed configured workspace fixture active SDK temp weight buffer bytes",
    activeSdkTempEvidence.weightBufferMatches)
  check("NPU model parsed configured workspace fixture active SDK temp bias buffer present",
    activeSdkTempEvidence.biasBufferPresent)
  check("NPU model parsed configured workspace fixture active SDK temp bias buffer bytes",
    activeSdkTempEvidence.biasBufferMatches)
  check("NPU model parsed configured workspace fixture active SDK temp cache",
    activeSdkTempEvidence.cacheValid)
  check("NPU model parsed configured workspace fixture active SDK temp weight cache",
    activeSdkTempEvidence.weightCacheValid)
  check("NPU model parsed configured workspace fixture active SDK temp weight cache active",
    activeSdkTempEvidence.weightCacheActive)
  check("NPU model parsed configured workspace fixture active SDK temp weight cache fits",
    activeSdkTempEvidence.weightCacheFits)
  check("NPU model parsed configured workspace fixture active SDK temp weight cache applied",
    activeSdkTempEvidence.weightCacheApplied)
  check("NPU model parsed configured workspace fixture active SDK temp weight cache operation",
    activeSdkTempEvidence.weightCacheClean)
  check("NPU model parsed configured workspace fixture active SDK temp weight cache address",
    activeSdkTempEvidence.weightCacheAddressMatches)
  check("NPU model parsed configured workspace fixture active SDK temp weight cache bytes",
    activeSdkTempEvidence.weightCacheBytesMatch)
  check("NPU model parsed configured workspace fixture active SDK temp bias cache",
    activeSdkTempEvidence.biasCacheValid)
  check("NPU model parsed configured workspace fixture active SDK temp bias cache active",
    activeSdkTempEvidence.biasCacheActive)
  check("NPU model parsed configured workspace fixture active SDK temp bias cache fits",
    activeSdkTempEvidence.biasCacheFits)
  check("NPU model parsed configured workspace fixture active SDK temp bias cache applied",
    activeSdkTempEvidence.biasCacheApplied)
  check("NPU model parsed configured workspace fixture active SDK temp bias cache operation",
    activeSdkTempEvidence.biasCacheClean)
  check("NPU model parsed configured workspace fixture active SDK temp bias cache address",
    activeSdkTempEvidence.biasCacheAddressMatches)
  check("NPU model parsed configured workspace fixture active SDK temp bias cache bytes",
    activeSdkTempEvidence.biasCacheBytesMatch)
  let activeLaunchBridgeEvidence =
    blaiForwardMaterializedLaunchBridgeEvidence(
      materialization, activeWorkspace, activeRunPlan, activeRunEvidence,
      activeStreamSemantics, activeWorkspaceBytes, activeDataMapping,
      activeSdkTemp, activeSdkTempEvidence)
  check("NPU model parsed configured workspace fixture active launch bridge evidence",
    activeLaunchBridgeEvidence.valid)
  check("NPU model parsed configured workspace fixture active launch bridge materialized",
    activeLaunchBridgeEvidence.materializationReady)
  check("NPU model parsed configured workspace fixture active launch bridge stream",
    activeLaunchBridgeEvidence.streamSemanticValid)
  check("NPU model parsed configured workspace fixture active launch bridge bytes",
    activeLaunchBridgeEvidence.workspaceBytesValid)
  check("NPU model parsed configured workspace fixture active launch bridge temp",
    activeLaunchBridgeEvidence.tempWeightBiasValid)
  check("NPU model parsed configured workspace fixture active launch bridge data mapping",
    activeLaunchBridgeEvidence.dataMappingValid)
  check("NPU model parsed configured workspace fixture active launch bridge run plan",
    activeLaunchBridgeEvidence.runPlanValid)
  check("NPU model parsed configured workspace fixture active launch bridge instruction address",
    activeLaunchBridgeEvidence.instructionAddressMatchesWorkspace)
  check("NPU model parsed configured workspace fixture active launch bridge data address",
    activeLaunchBridgeEvidence.dataAddressMatchesWorkspace)
  check("NPU model parsed configured workspace fixture active launch bridge weight address",
    activeLaunchBridgeEvidence.weightAddressMatchesTemp)
  check("NPU model parsed configured workspace fixture active launch bridge bias address",
    activeLaunchBridgeEvidence.biasAddressMatchesTemp)
  check("NPU model parsed configured workspace fixture active launch bridge instruction bytes",
    activeLaunchBridgeEvidence.instructionBytesMatchMaterialization)
  check("NPU model parsed configured workspace fixture active launch bridge weight bytes",
    activeLaunchBridgeEvidence.weightBytesMatchMaterialization)
  check("NPU model parsed configured workspace fixture active launch bridge bias bytes",
    activeLaunchBridgeEvidence.biasBytesMatchMaterialization)
  check("NPU model parsed configured workspace fixture active launch bridge byte evidence",
    activeLaunchBridgeEvidence.byteEvidenceMatchesMaterialization)
  check("NPU model parsed configured workspace fixture active launch bridge cache",
    activeLaunchBridgeEvidence.cachePlanReady)
  check("NPU model parsed configured workspace fixture active launch bridge addresses",
    activeLaunchBridgeEvidence.launchAddressesCoherent)
  check("NPU model parsed configured workspace fixture active launch bridge ready",
    activeLaunchBridgeEvidence.materializedLaunchReady)
  let launchStartEvidence =
    blaiParsedForwardConfiguredWorkspaceLaunchRegisterEvidence(
      snapshot, fixture,
      expectedInstAddr = activeWorkspace.instruction.address,
      expectedWeightAddr = activeSdkTemp.weightAddr,
      expectedBiasAddr = activeSdkTemp.biasAddr,
      expectedDataAddr = activeWorkspace.data.address,
      expectedSegment = states[0].layer.dramPatchSize.uint32,
      expectedUnsignedInput = true)
  let launchEvidence = launchStartEvidence.launch
  check("NPU model parsed configured workspace fixture active launch/start register evidence",
    launchStartEvidence.valid)
  check("NPU model parsed configured workspace fixture active launch captured",
    launchStartEvidence.capturesValid)
  check("NPU model parsed configured workspace fixture active launch snapshot captured",
    launchEvidence.captured)
  check("NPU model parsed configured workspace fixture active launch register evidence",
    launchStartEvidence.launchValid)
  check("NPU model parsed configured workspace fixture active launch inst",
    launchEvidence.instAddrMatches)
  check("NPU model parsed configured workspace fixture active launch weight",
    launchEvidence.weightAddrMatches)
  check("NPU model parsed configured workspace fixture active launch bias",
    launchEvidence.biasAddrMatches)
  check("NPU model parsed configured workspace fixture active launch data",
    launchEvidence.dataAddrMatches)
  check("NPU model parsed configured workspace fixture active launch segment",
    launchEvidence.segmentMatches)
  check("NPU model parsed configured workspace fixture active launch unsigned input",
    launchEvidence.unsignedInputMatches)
  check("NPU model parsed configured workspace fixture active launch tensorflow mode",
    launchEvidence.tensorflowModeMatches)
  check("NPU model parsed configured workspace fixture active launch reluN",
    launchEvidence.reluNMatches)
  check("NPU model parsed configured workspace fixture active launch net",
    launchEvidence.netMatches)
  check("NPU model parsed configured workspace fixture active launch int cfg start clean",
    launchEvidence.startCommandClean)
  check("NPU model parsed configured workspace fixture active launch int cfg resume clean",
    launchEvidence.resumeCommandClean)
  check("NPU model parsed configured workspace fixture active launch int cfg stop clean",
    launchEvidence.stopCommandClean)
  check("NPU model parsed configured workspace fixture active launch int cfg clear clean",
    launchEvidence.interruptClearCommandClean)
  check("NPU model parsed configured workspace fixture active launch int cfg status clean",
    launchEvidence.interruptStatusClean)
  check("NPU model parsed configured workspace fixture active launch int cfg idle",
    launchEvidence.intCfgClean)
  check("NPU model parsed configured workspace fixture active start observed",
    launchStartEvidence.startObserved)
  let startedEvidence = launchStartEvidence.started
  check("NPU model parsed configured workspace fixture active started register evidence",
    launchStartEvidence.startedValid)
  check("NPU model parsed configured workspace fixture active started snapshot captured",
    startedEvidence.captured)
  check("NPU model parsed configured workspace fixture active started inst",
    startedEvidence.instAddrMatches)
  check("NPU model parsed configured workspace fixture active started weight",
    startedEvidence.weightAddrMatches)
  check("NPU model parsed configured workspace fixture active started bias",
    startedEvidence.biasAddrMatches)
  check("NPU model parsed configured workspace fixture active started data",
    startedEvidence.dataAddrMatches)
  check("NPU model parsed configured workspace fixture active started segment",
    startedEvidence.segmentMatches)
  check("NPU model parsed configured workspace fixture active started unsigned input",
    startedEvidence.unsignedInputMatches)
  check("NPU model parsed configured workspace fixture active started tensorflow mode",
    startedEvidence.tensorflowModeMatches)
  check("NPU model parsed configured workspace fixture active started reluN",
    startedEvidence.reluNMatches)
  check("NPU model parsed configured workspace fixture active started net",
    startedEvidence.netMatches)
  check("NPU model parsed configured workspace fixture active started int cfg resume clean",
    startedEvidence.resumeCommandClean)
  check("NPU model parsed configured workspace fixture active started int cfg stop clean",
    startedEvidence.stopCommandClean)
  check("NPU model parsed configured workspace fixture active started int cfg clear clean",
    startedEvidence.interruptClearCommandClean)
  check("NPU model parsed configured workspace fixture active started int cfg status clean",
    startedEvidence.interruptStatusClean)
  check("NPU model parsed configured workspace fixture active started int cfg clean",
    startedEvidence.intCfgClean)
  check("NPU model parsed configured workspace fixture active snapshot started mirror",
    launchStartEvidence.snapshotStartedMatches)
  let launchRetention =
    blaiParsedForwardConfiguredWorkspaceLaunchRetentionEvidence(
      launchStartEvidence)
  check("NPU model parsed configured workspace fixture active launch retention evidence",
    launchRetention.valid)
  check("NPU model parsed configured workspace fixture active launch retention captures",
    launchRetention.capturesValid)
  check("NPU model parsed configured workspace fixture active launch retention addresses",
    launchRetention.addressRetained)
  check("NPU model parsed configured workspace fixture active launch retention segment",
    launchRetention.segmentRetained)
  check("NPU model parsed configured workspace fixture active launch retention net",
    launchRetention.netRetained)
  check("NPU model parsed configured workspace fixture active launch retention launch commands",
    launchRetention.launchCommandsClean)
  check("NPU model parsed configured workspace fixture active launch retention started commands",
    launchRetention.startedCommandsClean)
  check("NPU model parsed configured workspace fixture active launch retention start observed",
    launchRetention.startObserved)
  check("NPU model parsed configured workspace fixture active launch retention started mirror",
    launchRetention.snapshotStartedMatches)
  let activeCacheEvidence = blaiForwardWorkspaceCacheEvidence(
    snapshot.workspaceCache, snapshot.lastExecutionCache, activeRunPlan,
    activeWorkspace, activeWorkspace.data.address)
  check("NPU model parsed configured workspace fixture active cache evidence",
    activeCacheEvidence.valid)
  check("NPU model parsed configured workspace fixture active workspace cache",
    activeCacheEvidence.workspaceCacheValid)
  check("NPU model parsed configured workspace fixture active workspace cache fits",
    activeCacheEvidence.workspaceFits)
  check("NPU model parsed configured workspace fixture active workspace cache applied",
    activeCacheEvidence.workspaceApplied)
  check("NPU model parsed configured workspace fixture active workspace cache inst",
    activeCacheEvidence.instructionCacheValid)
  check("NPU model parsed configured workspace fixture active workspace cache inst active",
    activeCacheEvidence.instructionActive)
  check("NPU model parsed configured workspace fixture active workspace cache inst fits",
    activeCacheEvidence.instructionFits)
  check("NPU model parsed configured workspace fixture active workspace cache inst applied",
    activeCacheEvidence.instructionApplied)
  check("NPU model parsed configured workspace fixture active workspace cache inst operation",
    activeCacheEvidence.instructionClean)
  check("NPU model parsed configured workspace fixture active workspace cache inst address",
    activeCacheEvidence.instructionAddressMatches)
  check("NPU model parsed configured workspace fixture active workspace cache inst bytes",
    activeCacheEvidence.instructionBytesMatches)
  check("NPU model parsed configured workspace fixture active workspace cache weight",
    activeCacheEvidence.weightCacheValid)
  check("NPU model parsed configured workspace fixture active workspace cache weight active",
    activeCacheEvidence.weightActive)
  check("NPU model parsed configured workspace fixture active workspace cache weight fits",
    activeCacheEvidence.weightFits)
  check("NPU model parsed configured workspace fixture active workspace cache weight applied",
    activeCacheEvidence.weightApplied)
  check("NPU model parsed configured workspace fixture active workspace cache weight operation",
    activeCacheEvidence.weightClean)
  check("NPU model parsed configured workspace fixture active workspace cache weight address",
    activeCacheEvidence.weightAddressMatches)
  check("NPU model parsed configured workspace fixture active workspace cache weight bytes",
    activeCacheEvidence.weightBytesMatches)
  check("NPU model parsed configured workspace fixture active workspace cache bias",
    activeCacheEvidence.biasCacheValid)
  check("NPU model parsed configured workspace fixture active workspace cache bias active",
    activeCacheEvidence.biasActive)
  check("NPU model parsed configured workspace fixture active workspace cache bias fits",
    activeCacheEvidence.biasFits)
  check("NPU model parsed configured workspace fixture active workspace cache bias applied",
    activeCacheEvidence.biasApplied)
  check("NPU model parsed configured workspace fixture active workspace cache bias operation",
    activeCacheEvidence.biasClean)
  check("NPU model parsed configured workspace fixture active workspace cache bias address",
    activeCacheEvidence.biasAddressMatches)
  check("NPU model parsed configured workspace fixture active workspace cache bias bytes",
    activeCacheEvidence.biasBytesMatches)
  check("NPU model parsed configured workspace fixture active data cache plan",
    activeRunEvidence.firstDataCachePlanValid)
  check("NPU model parsed configured workspace fixture active data cache clean",
    activeCacheEvidence.firstDataCacheValid)
  check("NPU model parsed configured workspace fixture active data cache count",
    activeCacheEvidence.dataCacheRangeCountMatches)
  check("NPU model parsed configured workspace fixture active data cache active",
    activeCacheEvidence.firstDataCacheActive)
  check("NPU model parsed configured workspace fixture active data cache fits",
    activeCacheEvidence.firstDataCacheFits)
  check("NPU model parsed configured workspace fixture active data cache applied",
    activeCacheEvidence.firstDataCacheApplied)
  check("NPU model parsed configured workspace fixture active data cache operation",
    activeCacheEvidence.firstDataCacheClean)
  check("NPU model parsed configured workspace fixture active data cache address",
    activeCacheEvidence.firstDataCacheAddressMatches)
  check("NPU model parsed configured workspace fixture active data cache bytes",
    activeCacheEvidence.firstDataCacheBytesMatches)
  let activeCacheContract =
    blaiForwardActiveCacheContractEvidence(activeCacheEvidence)
  check("NPU model parsed configured workspace fixture active cache contract evidence",
    activeCacheContract.valid)
  check("NPU model parsed configured workspace fixture active cache contract workspace active",
    activeCacheContract.workspaceSegmentsActive)
  check("NPU model parsed configured workspace fixture active cache contract workspace fits",
    activeCacheContract.workspaceSegmentsFit)
  check("NPU model parsed configured workspace fixture active cache contract workspace applied",
    activeCacheContract.workspaceSegmentsApplied)
  check("NPU model parsed configured workspace fixture active cache contract workspace clean",
    activeCacheContract.workspaceSegmentsClean)
  check("NPU model parsed configured workspace fixture active cache contract workspace addresses",
    activeCacheContract.workspaceAddressesMatch)
  check("NPU model parsed configured workspace fixture active cache contract workspace bytes",
    activeCacheContract.workspaceBytesMatch)
  check("NPU model parsed configured workspace fixture active cache contract workspace valid",
    activeCacheContract.workspaceContractValid)
  check("NPU model parsed configured workspace fixture active cache contract data count",
    activeCacheContract.dataRangeCountMatches)
  check("NPU model parsed configured workspace fixture active cache contract data clean",
    activeCacheContract.dataRangeCleanValid)
  case materialization.firstBlock
  of blaiForwardModelWorkspaceMaterializeNoBlock:
    check("NPU model parsed configured workspace fixture active materialization first none",
      true)
  of blaiForwardModelWorkspaceMaterializeLayerStorage:
    check("NPU model parsed configured workspace fixture active materialization first layer storage",
      true)
  of blaiForwardModelWorkspaceMaterializeLayer:
    check("NPU model parsed configured workspace fixture active materialization first layer",
      true)
  check("NPU model parsed configured workspace fixture active run classified",
    activeClassification.runSequenceClassificationValid)
  check("NPU model parsed configured workspace fixture active run first block known",
    activeClassification.runSequenceFirstBlockKnown)
  check("NPU model parsed configured workspace fixture active run blocked capture",
    activeClassification.runSequenceBlockedCaptureMatches)
  check("NPU model parsed configured workspace fixture active readiness run classified",
    activeClassification.readinessRunSequenceMatches)
  check("NPU model parsed configured workspace fixture active run classification valid",
    activeClassification.runSequenceValid)
  check("NPU model parsed configured workspace fixture active classified",
    activeClassification.fixtureClassificationValid)
  check("NPU model parsed configured workspace fixture active fixture first block",
    activeClassification.fixtureFirstBlockMatches)
  check("NPU model parsed configured workspace fixture active fixture first block known",
    activeClassification.fixtureFirstBlockKnown)
  check("NPU model parsed configured workspace fixture active output classified",
    activeClassification.outputClassificationValid)
  check("NPU model parsed configured workspace fixture active fixture classification valid",
    activeClassification.fixtureValid)
  let activeClassificationTerminal =
    blaiParsedForwardConfiguredWorkspaceActiveClassificationEvidence(
      materialization, readiness, fixture, activeClassification)
  check("NPU model parsed configured workspace fixture active terminal materialization none",
    activeClassificationTerminal.materializationNoBlock)
  check("NPU model parsed configured workspace fixture active terminal run sequence none",
    activeClassificationTerminal.runSequenceNoBlock)
  check("NPU model parsed configured workspace fixture active terminal run sequence not blocked",
    activeClassificationTerminal.runSequenceNotBlocked)
  check("NPU model parsed configured workspace fixture active terminal readiness run sequence none",
    activeClassificationTerminal.readinessRunSequenceNoBlock)
  check("NPU model parsed configured workspace fixture active terminal fixture execution",
    activeClassificationTerminal.fixtureExecutionBlock)
  check("NPU model parsed configured workspace fixture active terminal readiness fixture execution",
    activeClassificationTerminal.readinessFixtureExecutionBlock)
  check("NPU model parsed configured workspace fixture active terminal output deferred",
    activeClassificationTerminal.outputDeferred)
  check("NPU model parsed configured workspace fixture active terminal classification valid",
    activeClassificationTerminal.classificationValid)
  check("NPU model parsed configured workspace fixture active terminal classification evidence",
    activeClassificationTerminal.valid)
  let snapshotCoherence =
    blaiParsedForwardConfiguredWorkspaceSnapshotCoherenceEvidence(
      snapshot, materialization, fixture)
  check("NPU model parsed configured workspace fixture active snapshot coherence evidence",
    snapshotCoherence.valid)
  check("NPU model parsed configured workspace fixture active snapshot coherent",
    snapshotCoherence.coherent)
  check("NPU model parsed configured workspace fixture active snapshot state mirrors",
    snapshotCoherence.stateMirrorsValid)
  check("NPU model parsed configured workspace fixture active snapshot materialized mirror",
    snapshotCoherence.materializedMatches)
  check("NPU model parsed configured workspace fixture active snapshot bound mirror",
    snapshotCoherence.boundMatches)
  check("NPU model parsed configured workspace fixture active snapshot hardware addresses mirror",
    snapshotCoherence.hardwareAddressesReadyMatches)
  check("NPU model parsed configured workspace fixture active snapshot input mirror",
    snapshotCoherence.inputMovedMatches)
  check("NPU model parsed configured workspace fixture active snapshot run sequence mirror",
    snapshotCoherence.runSequenceReadyMatches)
  check("NPU model parsed configured workspace fixture active snapshot execution completed mirror",
    snapshotCoherence.executionCompletedMatches)
  check("NPU model parsed configured workspace fixture active snapshot output valid mirror",
    snapshotCoherence.outputValidMatches)
  check("NPU model parsed configured workspace fixture active snapshot output matched mirror",
    snapshotCoherence.outputMatchedMatches)
  check("NPU model parsed configured workspace fixture active snapshot block mirrors",
    snapshotCoherence.blockMirrorsValid)
  check("NPU model parsed configured workspace fixture active snapshot materialization block mirror",
    snapshotCoherence.materializationFirstBlockMatches)
  check("NPU model parsed configured workspace fixture active snapshot execution block mirror",
    snapshotCoherence.executionFirstBlockMatches)
  check("NPU model parsed configured workspace fixture active snapshot run sequence block mirror",
    snapshotCoherence.runSequenceFirstBlockMatches)
  check("NPU model parsed configured workspace fixture active snapshot output block mirror",
    snapshotCoherence.outputFirstBlockMatches)
  check("NPU model parsed configured workspace fixture active snapshot execution mirrors",
    snapshotCoherence.executionMirrorsValid)
  check("NPU model parsed configured workspace fixture active snapshot failed execution mirror",
    snapshotCoherence.firstFailedExecutionCapturedMatches)
  check("NPU model parsed configured workspace fixture active snapshot last execution started mirror",
    snapshotCoherence.lastExecutionStartedMatches)
  check("NPU model parsed configured workspace fixture active snapshot last execution status mirror",
    snapshotCoherence.lastExecutionStatusMatches)
  let snapshotOutputEvidence =
    blaiParsedForwardConfiguredWorkspaceSnapshotOutputEvidence(snapshot, fixture)
  check("NPU model parsed configured workspace fixture active snapshot output evidence",
    snapshotOutputEvidence.valid)
  check("NPU model parsed configured workspace fixture active snapshot counters",
    snapshotOutputEvidence.countersValid)
  check("NPU model parsed configured workspace fixture active snapshot attempted layers",
    snapshotOutputEvidence.attemptedLayerCountMatches)
  check("NPU model parsed configured workspace fixture active snapshot completed layers",
    snapshotOutputEvidence.completedLayerCountMatches)
  check("NPU model parsed configured workspace fixture active snapshot failed layers",
    snapshotOutputEvidence.failedLayerCountMatches)
  check("NPU model parsed configured workspace fixture active snapshot first failed layer",
    snapshotOutputEvidence.firstFailedLayerMatches)
  check("NPU model parsed configured workspace fixture active snapshot expected elements",
    snapshotOutputEvidence.expectedElementsMatches)
  check("NPU model parsed configured workspace fixture active snapshot actual elements",
    snapshotOutputEvidence.actualElementsMatches)
  check("NPU model parsed configured workspace fixture active snapshot compared elements",
    snapshotOutputEvidence.comparedElementsMatches)
  check("NPU model parsed configured workspace fixture active snapshot trailing elements",
    snapshotOutputEvidence.trailingElementsMatches)
  check("NPU model parsed configured workspace fixture active snapshot length match",
    snapshotOutputEvidence.lengthMatchesMatches)
  check("NPU model parsed configured workspace fixture active snapshot mismatch count",
    snapshotOutputEvidence.mismatchCountMatches)
  check("NPU model parsed configured workspace fixture active snapshot first mismatch",
    snapshotOutputEvidence.firstMismatchMatches)
  check("NPU model parsed configured workspace fixture active snapshot mismatch bytes",
    snapshotOutputEvidence.mismatchBytesValid)
  check("NPU model parsed configured workspace fixture active snapshot expected mismatch present",
    snapshotOutputEvidence.expectedPresentAtFirstMismatchMatches)
  check("NPU model parsed configured workspace fixture active snapshot actual mismatch present",
    snapshotOutputEvidence.actualPresentAtFirstMismatchMatches)
  check("NPU model parsed configured workspace fixture active snapshot expected mismatch byte",
    snapshotOutputEvidence.expectedAtFirstMismatchMatches)
  check("NPU model parsed configured workspace fixture active snapshot actual mismatch byte",
    snapshotOutputEvidence.actualAtFirstMismatchMatches)
  let deferredOutputEvidence =
    blaiParsedForwardConfiguredWorkspaceDeferredOutputEvidence(
      snapshot, fixture, snapshotOutputEvidence)
  check("NPU model parsed configured workspace fixture active deferred output execution gate",
    deferredOutputEvidence.fixtureExecutionGate)
  check("NPU model parsed configured workspace fixture active deferred output execution incomplete",
    deferredOutputEvidence.executionIncomplete)
  check("NPU model parsed configured workspace fixture active deferred output invalid",
    deferredOutputEvidence.outputInvalid)
  check("NPU model parsed configured workspace fixture active deferred output unmatched",
    deferredOutputEvidence.outputUnmatched)
  check("NPU model parsed configured workspace fixture active deferred output zero expected",
    deferredOutputEvidence.zeroExpectedElements)
  check("NPU model parsed configured workspace fixture active deferred output zero actual",
    deferredOutputEvidence.zeroActualElements)
  check("NPU model parsed configured workspace fixture active deferred output zero compared",
    deferredOutputEvidence.zeroComparedElements)
  check("NPU model parsed configured workspace fixture active deferred output zero trailing",
    deferredOutputEvidence.zeroTrailingElements)
  check("NPU model parsed configured workspace fixture active deferred output zero mismatch",
    deferredOutputEvidence.zeroMismatchCount)
  check("NPU model parsed configured workspace fixture active deferred output no first mismatch",
    deferredOutputEvidence.noFirstMismatch)
  check("NPU model parsed configured workspace fixture active deferred output no mismatch bytes",
    deferredOutputEvidence.noMismatchBytes)
  check("NPU model parsed configured workspace fixture active deferred output mirrors",
    deferredOutputEvidence.mirrorsValid)
  check("NPU model parsed configured workspace fixture active deferred output evidence",
    deferredOutputEvidence.valid)
  let activeOutputBlocked =
    blaiParsedForwardConfiguredWorkspaceActiveOutputBlockedEvidence(
      fixture, readiness, deferredOutputEvidence)
  check("NPU model parsed configured workspace fixture active output blocked fixture gate",
    activeOutputBlocked.fixtureExecutionGate)
  check("NPU model parsed configured workspace fixture active output blocked readiness gate",
    activeOutputBlocked.readinessExecutionGate)
  check("NPU model parsed configured workspace fixture active output blocked invalid",
    activeOutputBlocked.outputInvalid)
  check("NPU model parsed configured workspace fixture active output blocked unmatched",
    activeOutputBlocked.outputUnmatched)
  check("NPU model parsed configured workspace fixture active output blocked readiness invalid",
    activeOutputBlocked.outputReadinessInvalid)
  check("NPU model parsed configured workspace fixture active output blocked not moved",
    activeOutputBlocked.workspaceOutputNotMoved)
  check("NPU model parsed configured workspace fixture active output blocked workspace block",
    activeOutputBlocked.workspaceOutputFirstBlockNone)
  check("NPU model parsed configured workspace fixture active output blocked validation block",
    activeOutputBlocked.validationFirstBlockNone)
  check("NPU model parsed configured workspace fixture active output blocked model block",
    activeOutputBlocked.modelValidationFirstBlockNone)
  check("NPU model parsed configured workspace fixture active output blocked zero counters",
    activeOutputBlocked.zeroCounters)
  check("NPU model parsed configured workspace fixture active output blocked no mismatch",
    activeOutputBlocked.noMismatch)
  check("NPU model parsed configured workspace fixture active output blocked deferred",
    activeOutputBlocked.deferredOutputValid)
  check("NPU model parsed configured workspace fixture active output blocked evidence",
    activeOutputBlocked.valid)
  let snapshotTerminalDetail =
    blaiParsedForwardConfiguredWorkspaceSnapshotTerminalDetailEvidence(
      snapshot, fixture)
  check("NPU model parsed configured workspace fixture active snapshot terminal detail evidence",
    snapshotTerminalDetail.valid)
  check("NPU model parsed configured workspace fixture active snapshot terminal detail",
    snapshotTerminalDetail.terminalDetailValid)
  check("NPU model parsed configured workspace fixture active snapshot run-sequence detail",
    snapshotTerminalDetail.runSequenceDetailValid)
  check("NPU model parsed configured workspace fixture active snapshot run-sequence first block",
    snapshotTerminalDetail.runSequenceReadinessFirstBlockMatches)
  check("NPU model parsed configured workspace fixture active snapshot first blocked layer",
    snapshotTerminalDetail.runSequenceFirstBlockedLayerMatches)
  check("NPU model parsed configured workspace fixture active snapshot first blocked run captured",
    snapshotTerminalDetail.runSequenceFirstBlockedRunCapturedMatches)
  check("NPU model parsed configured workspace fixture active snapshot first blocked run config",
    snapshotTerminalDetail.runSequenceFirstBlockedRunConfigFirstBlockMatches)
  check("NPU model parsed configured workspace fixture active snapshot execution terminal",
    snapshotTerminalDetail.executionTerminalValid)
  check("NPU model parsed configured workspace fixture active snapshot first failed started",
    snapshotTerminalDetail.firstFailedExecutionStartedMatches)
  check("NPU model parsed configured workspace fixture active snapshot first failed status",
    snapshotTerminalDetail.firstFailedExecutionStatusMatches)
  check("NPU model parsed configured workspace fixture active snapshot first failed timed out",
    snapshotTerminalDetail.firstFailedExecutionTimedOutMatches)
  check("NPU model parsed configured workspace fixture active snapshot last completed",
    snapshotTerminalDetail.lastExecutionCompletedMatches)
  check("NPU model parsed configured workspace fixture active snapshot last timed out",
    snapshotTerminalDetail.lastExecutionTimedOutMatches)
  check("NPU model parsed configured workspace fixture active snapshot last interrupt observed",
    snapshotTerminalDetail.lastExecutionInterruptObservedMatches)
  let snapshotRuntime =
    blaiParsedForwardConfiguredWorkspaceSnapshotRuntimeEvidence(
      snapshot, fixture)
  check("NPU model parsed configured workspace fixture active snapshot runtime evidence",
    snapshotRuntime.valid)
  check("NPU model parsed configured workspace fixture active snapshot wait plans",
    snapshotRuntime.waitPlansValid)
  check("NPU model parsed configured workspace fixture active snapshot first failed wait plan",
    snapshotRuntime.firstFailedExecutionWaitPlanMatches)
  check("NPU model parsed configured workspace fixture active snapshot last wait plan",
    snapshotRuntime.lastExecutionWaitPlanMatches)
  check("NPU model parsed configured workspace fixture active snapshot cache results",
    snapshotRuntime.cacheResultsValid)
  check("NPU model parsed configured workspace fixture active snapshot workspace cache result",
    snapshotRuntime.workspaceCacheMatches)
  check("NPU model parsed configured workspace fixture active snapshot last execution cache result",
    snapshotRuntime.lastExecutionCacheMatches)
  check("NPU model parsed configured workspace fixture active snapshot register captures",
    snapshotRuntime.registerCapturesValid)
  check("NPU model parsed configured workspace fixture active snapshot launch registers captured",
    snapshotRuntime.launchRegistersCapturedMatches)
  check("NPU model parsed configured workspace fixture active snapshot started registers captured",
    snapshotRuntime.startedRegistersCapturedMatches)
  check("NPU model parsed configured workspace fixture active snapshot launch registers",
    snapshotRuntime.launchRegistersMatch)
  check("NPU model parsed configured workspace fixture active snapshot started registers",
    snapshotRuntime.startedRegistersMatch)
  check("NPU model parsed configured workspace fixture active snapshot wait-exit registers",
    snapshotRuntime.waitExitRegistersValid)
  check("NPU model parsed configured workspace fixture active snapshot first failed wait interrupt",
    snapshotRuntime.firstFailedExecutionWaitExitInterruptMatches)
  check("NPU model parsed configured workspace fixture active snapshot first failed wait MM aggregate",
    snapshotRuntime.firstFailedExecutionWaitExitMmAggregateMatches and
      snapshot.firstFailedExecutionWaitExitMmAggregate.valid)
  check("NPU model parsed configured workspace fixture active snapshot first failed wait busy",
    snapshotRuntime.firstFailedExecutionWaitExitBusyMatches)
  check("NPU model parsed configured workspace fixture active snapshot first failed wait clock",
    snapshotRuntime.firstFailedExecutionWaitExitClockMatches)
  check("NPU model parsed configured workspace fixture active snapshot last wait interrupt",
    snapshotRuntime.lastExecutionWaitExitInterruptMatches)
  check("NPU model parsed configured workspace fixture active snapshot last wait MM aggregate",
    snapshotRuntime.lastExecutionWaitExitMmAggregateMatches and
      snapshot.lastExecutionWaitExitMmAggregate.valid)
  check("NPU model parsed configured workspace fixture active snapshot last wait busy",
    snapshotRuntime.lastExecutionWaitExitBusyMatches)
  check("NPU model parsed configured workspace fixture active snapshot last wait clock",
    snapshotRuntime.lastExecutionWaitExitClockMatches)
  check("NPU model parsed configured workspace fixture active snapshot status decisions",
    snapshotRuntime.statusDecisionsValid)
  check("NPU model parsed configured workspace fixture active snapshot first failed status decision",
    snapshotRuntime.firstFailedExecutionStatusDecisionMatches)
  check("NPU model parsed configured workspace fixture active snapshot last status decision",
    snapshotRuntime.lastExecutionStatusDecisionMatches)
  check("NPU model parsed configured workspace fixture active snapshot completion side effects",
    snapshotRuntime.completionSideEffectsValid)
  check("NPU model parsed configured workspace fixture active snapshot first failed interrupt cleared",
    snapshotRuntime.firstFailedExecutionInterruptClearedMatches)
  check("NPU model parsed configured workspace fixture active snapshot first failed clock disabled",
    snapshotRuntime.firstFailedExecutionClockDisabledMatches)
  check("NPU model parsed configured workspace fixture active snapshot last interrupt cleared",
    snapshotRuntime.lastExecutionInterruptClearedMatches)
  check("NPU model parsed configured workspace fixture active snapshot last clock disabled",
    snapshotRuntime.lastExecutionClockDisabledMatches)
  check("NPU model parsed configured workspace fixture active snapshot run config readiness",
    snapshotRuntime.runConfigReadinessValid)
  check("NPU model parsed configured workspace fixture active snapshot run config readiness mirror",
    snapshotRuntime.runConfigReadinessMatches)
  let activeRuntimeMirror =
    blaiParsedForwardConfiguredWorkspaceActiveRuntimeMirrorEvidence(
      snapshot, snapshotRuntime)
  check("NPU model parsed configured workspace fixture active runtime mirror evidence",
    activeRuntimeMirror.valid)
  check("NPU model parsed configured workspace fixture active runtime mirror status",
    activeRuntimeMirror.statusMatches)
  check("NPU model parsed configured workspace fixture active runtime mirror timed out",
    activeRuntimeMirror.timedOutMatches)
  check("NPU model parsed configured workspace fixture active runtime mirror wait plan",
    activeRuntimeMirror.waitPlanMatches)
  check("NPU model parsed configured workspace fixture active runtime mirror wait interrupt",
    activeRuntimeMirror.waitExitInterruptMatches)
  check("NPU model parsed configured workspace fixture active runtime mirror wait MM aggregate",
    activeRuntimeMirror.waitExitMmAggregateMatches)
  check("NPU model parsed configured workspace fixture active runtime mirror wait busy",
    activeRuntimeMirror.waitExitBusyMatches)
  check("NPU model parsed configured workspace fixture active runtime mirror wait clock",
    activeRuntimeMirror.waitExitClockMatches)
  check("NPU model parsed configured workspace fixture active runtime mirror status decision",
    activeRuntimeMirror.statusDecisionMatches)
  check("NPU model parsed configured workspace fixture active runtime mirror interrupt cleared",
    activeRuntimeMirror.interruptClearedMatches)
  check("NPU model parsed configured workspace fixture active runtime mirror clock disabled",
    activeRuntimeMirror.clockDisabledMatches)
  check("NPU model parsed configured workspace fixture active runtime mirror source",
    activeRuntimeMirror.runtimeMirrorsValid)
  let activeCompletionPolicy =
    blaiParsedForwardConfiguredWorkspaceActiveCompletionPolicyEvidence(
      snapshot, fixture, expectedTimeout = 11)
  check("NPU model parsed configured workspace fixture active completion policy evidence",
    activeCompletionPolicy.valid)
  check("NPU model parsed configured workspace fixture active completion policy wait plans",
    activeCompletionPolicy.waitPlansMatch)
  check("NPU model parsed configured workspace fixture active completion policy configured",
    activeCompletionPolicy.waitConfigured)
  check("NPU model parsed configured workspace fixture active completion policy timeout",
    activeCompletionPolicy.timeoutMatches)
  check("NPU model parsed configured workspace fixture active completion policy clear enabled",
    activeCompletionPolicy.clearOnComplete)
  check("NPU model parsed configured workspace fixture active completion policy disable clock",
    activeCompletionPolicy.disableClockOnExit)
  check("NPU model parsed configured workspace fixture active completion policy started",
    activeCompletionPolicy.started)
  check("NPU model parsed configured workspace fixture active completion policy no interrupt",
    activeCompletionPolicy.noInterrupt)
  check("NPU model parsed configured workspace fixture active completion policy status configured",
    activeCompletionPolicy.statusConfigured)
  check("NPU model parsed configured workspace fixture active completion policy timed out",
    activeCompletionPolicy.statusTimedOut)
  check("NPU model parsed configured workspace fixture active completion policy incomplete",
    activeCompletionPolicy.statusIncomplete)
  check("NPU model parsed configured workspace fixture active completion policy status",
    activeCompletionPolicy.statusMatches)
  check("NPU model parsed configured workspace fixture active completion policy no interrupt clear",
    activeCompletionPolicy.interruptClearSuppressed)
  check("NPU model parsed configured workspace fixture active completion policy clock disabled",
    activeCompletionPolicy.clockDisabledOnExit)
  let activePollingWait =
    blaiNpuPollingWaitEvidence(fixture.execution.lastExecution.completion)
  check("NPU model parsed configured workspace fixture active polling wait evidence",
    activePollingWait.valid)
  checkEq("NPU model parsed configured workspace fixture active polling wait terminal",
    ord(activePollingWait.terminal).uint32,
    ord(blaiNpuPollingWaitTimeout).uint32)
  check("NPU model parsed configured workspace fixture active polling wait configured",
    activePollingWait.configured)
  checkEq("NPU model parsed configured workspace fixture active polling wait budget",
    activePollingWait.pollBudget, 11)
  checkEq("NPU model parsed configured workspace fixture active polling wait actual polls",
    activePollingWait.actualPolls, 11)
  check("NPU model parsed configured workspace fixture active polling wait started",
    activePollingWait.started)
  check("NPU model parsed configured workspace fixture active polling wait no interrupt",
    not activePollingWait.interruptObserved)
  check("NPU model parsed configured workspace fixture active polling wait final clear",
    not activePollingWait.finalInterruptPending)
  check("NPU model parsed configured workspace fixture active polling wait exhausted",
    activePollingWait.budgetExhausted)
  check("NPU model parsed configured workspace fixture active polling wait poll budget",
    activePollingWait.budgetMatchesPolls)
  check("NPU model parsed configured workspace fixture active polling wait trace",
    activePollingWait.pollTraceValid)
  check("NPU model parsed configured workspace fixture active polling wait status",
    activePollingWait.statusTimedOut)
  check("NPU model parsed configured workspace fixture active polling wait terminal evidence",
    activePollingWait.terminalMatchesStatus)
  check("NPU model parsed configured workspace fixture active completion poll telemetry",
    fixture.execution.lastExecution.completion.poll.valid)
  checkEq("NPU model parsed configured workspace fixture active completion poll count",
    fixture.execution.lastExecution.completion.poll.polls, 11)
  check("NPU model parsed configured workspace fixture active completion poll exhausted",
    fixture.execution.lastExecution.completion.poll.exhausted)
  let activeCompletionSideEffects =
    blaiNpuCompletionSideEffectEvidence(fixture.execution.lastExecution.completion)
  check("NPU model parsed configured workspace fixture active completion side effects",
    activeCompletionSideEffects.valid)
  checkEq("NPU model parsed configured workspace fixture active completion side effect path",
    ord(activeCompletionSideEffects.path).uint32,
    ord(blaiNpuCompletionSideEffectTimeout).uint32)
  check("NPU model parsed configured workspace fixture active completion side effect clear suppressed",
    activeCompletionSideEffects.interruptClearSuppressed)
  check("NPU model parsed configured workspace fixture active completion side effect clock disabled",
    activeCompletionSideEffects.clockDisabledOnExit)
  check("NPU model parsed configured workspace fixture active completion side effect timeout",
    activeCompletionSideEffects.timeoutSideEffectsApplied)
  check("NPU model parsed configured workspace fixture active completion side effect status",
    activeCompletionSideEffects.pathMatchesStatus)
  let activeClockExit =
    blaiNpuClockExitEvidence(fixture.execution.lastExecution.completion)
  check("NPU model parsed configured workspace fixture active clock exit evidence",
    activeClockExit.valid)
  checkEq("NPU model parsed configured workspace fixture active clock exit path",
    ord(activeClockExit.path).uint32,
    ord(blaiNpuClockExitDisabledAfterTimeout).uint32)
  check("NPU model parsed configured workspace fixture active clock exit retained",
    activeClockExit.retainedUntilWaitExit)
  check("NPU model parsed configured workspace fixture active clock exit source",
    activeClockExit.waitExitClockSourceKnown and
      activeClockExit.waitExitClockSource320M)
  check("NPU model parsed configured workspace fixture active clock exit divider",
    activeClockExit.waitExitClockDividerZero)
  check("NPU model parsed configured workspace fixture active clock exit disabled",
    activeClockExit.disabledAfterTimeout)
  let activeStopAfterInference =
    blaiNpuStopAfterInferenceEvidence(fixture.execution.lastExecution)
  check("NPU model parsed configured workspace fixture active stop-after-inference evidence",
    activeStopAfterInference.valid)
  checkEq("NPU model parsed configured workspace fixture active stop-after-inference path",
    ord(activeStopAfterInference.path).uint32,
    ord(blaiNpuStopAfterInferenceStoppedAfterTimeout).uint32)
  check("NPU model parsed configured workspace fixture active stop-after-inference policy",
    activeStopAfterInference.stopPolicy)
  check("NPU model parsed configured workspace fixture active stop-after-inference started",
    activeStopAfterInference.started)
  check("NPU model parsed configured workspace fixture active stop-after-inference stopped",
    activeStopAfterInference.stopped and activeStopAfterInference.outcomeStopped)
  check("NPU model parsed configured workspace fixture active stop-after-inference timeout",
    activeStopAfterInference.stoppedAfterTimeout)
  let activePostCompletionCache =
    blaiNpuPostCompletionCacheEvidence(
      activeRunPlan, fixture.execution.lastExecution)
  check("NPU model parsed configured workspace fixture active post-completion cache evidence",
    activePostCompletionCache.valid)
  checkEq("NPU model parsed configured workspace fixture active post-completion cache path",
    ord(activePostCompletionCache.path).uint32,
    ord(blaiNpuPostCompletionCacheInvalidateDeferred).uint32)
  check("NPU model parsed configured workspace fixture active post-completion cache clean",
    activePostCompletionCache.cleanAppliedBeforeWait)
  check("NPU model parsed configured workspace fixture active post-completion cache invalidate planned",
    activePostCompletionCache.plannedInvalidateCount > 0)
  check("NPU model parsed configured workspace fixture active post-completion cache invalidate deferred",
    activePostCompletionCache.invalidateDeferred)
  check("NPU model parsed configured workspace fixture active post-completion cache no invalidate",
    activePostCompletionCache.appliedInvalidateCount == 0)
  let activeTimeoutOutputInvalidate = blaiApplyCacheRange(
    activeRunPlan.layerConfig.inputBufferAddr,
    activeRunPlan.forwardPlan.outputInvalidateRange)
  logActiveTimeoutOutputProbe(
    "NPU model active timeout output probe",
    activeNpuWorkspace,
    activeDataSlots,
    activeTimeoutOutputInvalidate)
  check("NPU model parsed configured workspace fixture active timeout output probe active",
    activeTimeoutOutputInvalidate.active)
  check("NPU model parsed configured workspace fixture active timeout output probe fits",
    activeTimeoutOutputInvalidate.fits)
  check("NPU model parsed configured workspace fixture active timeout output probe applied",
    activeTimeoutOutputInvalidate.applied)
  let activeOutputCacheGate =
    blaiParsedForwardConfiguredWorkspaceActiveOutputCacheGateEvidence(
      activeOutputBlocked, deferredOutputEvidence, activePostCompletionCache)
  check("NPU model parsed configured workspace fixture active output cache gate evidence",
    activeOutputCacheGate.valid)
  check("NPU model parsed configured workspace fixture active output cache gate blocked",
    activeOutputCacheGate.outputBlockedValid)
  check("NPU model parsed configured workspace fixture active output cache gate deferred",
    activeOutputCacheGate.deferredOutputValid)
  check("NPU model parsed configured workspace fixture active output cache gate cache",
    activeOutputCacheGate.postCompletionCacheValid)
  check("NPU model parsed configured workspace fixture active output cache gate invalid",
    activeOutputCacheGate.outputInvalid)
  check("NPU model parsed configured workspace fixture active output cache gate no readback",
    activeOutputCacheGate.workspaceOutputNotMoved)
  check("NPU model parsed configured workspace fixture active output cache gate no invalidate",
    activeOutputCacheGate.noInvalidateApplied)
  check("NPU model parsed configured workspace fixture active output cache gate coherent",
    activeOutputCacheGate.gateMatchesCache)
  let activeOutputReadbackPlan =
    blaiParsedForwardConfiguredWorkspaceActiveOutputReadbackPlanEvidence(
      tensorPlan, activeOutputBlocked, deferredOutputEvidence,
      activeOutputCacheGate)
  check("NPU model parsed configured workspace fixture active output readback plan evidence",
    activeOutputReadbackPlan.valid)
  check("NPU model parsed configured workspace fixture active output readback plan runnable",
    activeOutputReadbackPlan.planRunnable)
  check("NPU model parsed configured workspace fixture active output readback plan output active",
    activeOutputReadbackPlan.primaryOutputActive)
  check("NPU model parsed configured workspace fixture active output readback plan bytes",
    activeOutputReadbackPlan.outputBytesKnown)
  check("NPU model parsed configured workspace fixture active output readback plan slot",
    activeOutputReadbackPlan.outputSlotMatchesInvalidate)
  check("NPU model parsed configured workspace fixture active output readback plan invalidate bytes",
    activeOutputReadbackPlan.outputBytesMatchInvalidate)
  check("NPU model parsed configured workspace fixture active output readback plan invalidate",
    activeOutputReadbackPlan.outputInvalidatePlanned)
  check("NPU model parsed configured workspace fixture active output readback plan deferred",
    activeOutputReadbackPlan.outputInvalidateDeferred)
  check("NPU model parsed configured workspace fixture active output readback plan no readback",
    activeOutputReadbackPlan.workspaceOutputNotMoved)
  check("NPU model parsed configured workspace fixture active output readback plan first blocks",
    activeOutputReadbackPlan.readbackFirstBlocksClear)
  check("NPU model parsed configured workspace fixture active output readback plan ready",
    activeOutputReadbackPlan.readbackPlanReady)
  check("NPU model parsed configured workspace fixture active output readback plan gated",
    activeOutputReadbackPlan.readbackDeferredByExecution)
  let activeOutputTransferScope =
    blaiParsedForwardConfiguredWorkspaceActiveOutputTransferScopeEvidence(
      tensorPlan, activeOutputReadbackPlan)
  check("NPU model parsed configured workspace fixture active output transfer scope evidence",
    activeOutputTransferScope.valid)
  check("NPU model parsed configured workspace fixture active output transfer scope runnable",
    activeOutputTransferScope.planRunnable)
  check("NPU model parsed configured workspace fixture active output transfer scope primary active",
    activeOutputTransferScope.primaryOutputActive)
  check("NPU model parsed configured workspace fixture active output transfer scope primary invalidate",
    activeOutputTransferScope.primaryInvalidateActive)
  check("NPU model parsed configured workspace fixture active output transfer scope primary bytes",
    activeOutputTransferScope.primaryBytesKnown)
  check("NPU model parsed configured workspace fixture active output transfer scope mid inactive",
    activeOutputTransferScope.midOutputInactive)
  check("NPU model parsed configured workspace fixture active output transfer scope mid invalidate inactive",
    activeOutputTransferScope.midInvalidateInactive)
  check("NPU model parsed configured workspace fixture active output transfer scope primary only",
    activeOutputTransferScope.primaryOnly)
  check("NPU model parsed configured workspace fixture active output transfer scope coherent",
    activeOutputTransferScope.scopeMatchesReadbackPlan)
  let activeExitCleanup =
    blaiParsedForwardConfiguredWorkspaceActiveExitCleanupEvidence(
      activeCompletionPolicy, activeCompletionSideEffects, activeClockExit,
      activeStopAfterInference, activePostCompletionCache, activeOutputCacheGate)
  check("NPU model parsed configured workspace fixture active exit cleanup evidence",
    activeExitCleanup.valid)
  check("NPU model parsed configured workspace fixture active exit cleanup policy",
    activeExitCleanup.completionPolicyValid)
  check("NPU model parsed configured workspace fixture active exit cleanup side effects",
    activeExitCleanup.sideEffectsValid)
  check("NPU model parsed configured workspace fixture active exit cleanup clock",
    activeExitCleanup.clockExitValid)
  check("NPU model parsed configured workspace fixture active exit cleanup stop",
    activeExitCleanup.stopValid)
  check("NPU model parsed configured workspace fixture active exit cleanup cache",
    activeExitCleanup.postCompletionCacheValid)
  check("NPU model parsed configured workspace fixture active exit cleanup output gate",
    activeExitCleanup.outputCacheGateValid)
  check("NPU model parsed configured workspace fixture active exit cleanup timeout",
    activeExitCleanup.timeoutTerminal)
  check("NPU model parsed configured workspace fixture active exit cleanup interrupt",
    activeExitCleanup.interruptClearSuppressed)
  check("NPU model parsed configured workspace fixture active exit cleanup coherent",
    activeExitCleanup.cleanupCoherent)
  let terminalGateEvidence =
    blaiParsedForwardConfiguredWorkspaceTerminalGateEvidence(snapshot, fixture)
  check("NPU model parsed configured workspace fixture active terminal gate evidence",
    terminalGateEvidence.valid)
  check("NPU model parsed configured workspace fixture active terminal classified",
    terminalGateEvidence.classified)
  check("NPU model parsed configured workspace fixture active terminal gate known",
    terminalGateEvidence.terminalGateKnown)
  check("NPU model parsed configured workspace fixture active terminal valid flag",
    terminalGateEvidence.terminalValidFlagMatches)
  check("NPU model parsed configured workspace fixture active terminal evidence",
    terminalGateEvidence.selectedGateEvidence)
  check("NPU model parsed configured workspace fixture active terminal complete evidence",
    terminalGateEvidence.completeGateEvidence ==
      (snapshot.terminalGate == blaiParsedConfiguredWorkspaceGateComplete))
  check("NPU model parsed configured workspace fixture active terminal materialization evidence",
    terminalGateEvidence.materializationGateEvidence ==
      (snapshot.terminalGate == blaiParsedConfiguredWorkspaceGateMaterialization))
  check("NPU model parsed configured workspace fixture active terminal binding evidence",
    terminalGateEvidence.bindingGateEvidence ==
      (snapshot.terminalGate == blaiParsedConfiguredWorkspaceGateBinding))
  check("NPU model parsed configured workspace fixture active terminal hardware-address evidence",
    terminalGateEvidence.hardwareAddressesGateEvidence ==
      (snapshot.terminalGate == blaiParsedConfiguredWorkspaceGateHardwareAddresses))
  check("NPU model parsed configured workspace fixture active terminal input evidence",
    terminalGateEvidence.inputGateEvidence ==
      (snapshot.terminalGate == blaiParsedConfiguredWorkspaceGateInput))
  check("NPU model parsed configured workspace fixture active terminal run-sequence evidence",
    terminalGateEvidence.runSequenceGateEvidence ==
      (snapshot.terminalGate == blaiParsedConfiguredWorkspaceGateRunSequence))
  check("NPU model parsed configured workspace fixture active terminal execution evidence",
    terminalGateEvidence.executionGateEvidence ==
      (snapshot.terminalGate == blaiParsedConfiguredWorkspaceGateExecution))
  check("NPU model parsed configured workspace fixture active terminal output evidence",
    terminalGateEvidence.outputGateEvidence ==
      (snapshot.terminalGate == blaiParsedConfiguredWorkspaceGateOutput))
  case snapshot.terminalGate
  of blaiParsedConfiguredWorkspaceGateComplete:
    check("NPU model parsed configured workspace fixture active terminal complete",
      terminalGateEvidence.completeGateEvidence)
  of blaiParsedConfiguredWorkspaceGateMaterialization:
    check("NPU model parsed configured workspace fixture active terminal materialization",
      terminalGateEvidence.materializationGateEvidence)
    case snapshot.materializationFirstBlock
    of blaiForwardModelWorkspaceMaterializeLayerStorage:
      check("NPU model parsed configured workspace fixture active materialization layer storage",
        true)
    of blaiForwardModelWorkspaceMaterializeLayer:
      check("NPU model parsed configured workspace fixture active materialization layer",
        true)
      case materialization.firstBlockedLayerFirstBlock
      of blaiForwardLayerWorkspaceMaterializeInstructions:
        check("NPU model parsed configured workspace fixture active layer instructions",
          true)
        case materialization.firstBlockedInstructionFirstBlock
        of blaiForwardLayerInstructionWorkspacePrepared:
          check("NPU model parsed configured workspace fixture active instruction prepared gate",
            true)
          case materialization.lastLayer.instructions.prepared.firstBlock
          of blaiForwardPreparedRunForwardPlan:
            check("NPU model parsed configured workspace fixture active prepared forward plan gate",
              true)
          of blaiForwardPreparedRunEncoding:
            check("NPU model parsed configured workspace fixture active prepared encoding gate",
              true)
          of blaiForwardPreparedRunResources:
            check("NPU model parsed configured workspace fixture active prepared resources gate",
              true)
          of blaiForwardPreparedRunConfig:
            check("NPU model parsed configured workspace fixture active prepared config gate",
              true)
            case materialization.lastLayer.instructions.prepared.runConfigFirstBlock
            of blaiForwardNpuRunConfigForwardPlan:
              check("NPU model parsed configured workspace fixture active config forward plan gate",
                true)
            of blaiForwardNpuRunConfigBufferFit:
              check("NPU model parsed configured workspace fixture active config buffer fit gate",
                true)
            of blaiForwardNpuRunConfigInstructionBuffer:
              check("NPU model parsed configured workspace fixture active config instruction buffer gate",
                true)
            of blaiForwardNpuRunConfigDataBuffer:
              check("NPU model parsed configured workspace fixture active config data buffer gate",
                true)
            of blaiForwardNpuRunConfigWeightBuffers:
              check("NPU model parsed configured workspace fixture active config weight buffers gate",
                true)
            of blaiForwardNpuRunConfigNoBlock:
              check("NPU model parsed configured workspace fixture active config unexpected none",
                false)
          of blaiForwardPreparedRunNoBlock:
            check("NPU model parsed configured workspace fixture active prepared unexpected none",
              false)
        of blaiForwardLayerInstructionWorkspaceStorage:
          check("NPU model parsed configured workspace fixture active instruction storage gate",
            true)
        of blaiForwardLayerInstructionWorkspaceNoBlock:
          check("NPU model parsed configured workspace fixture active instruction unexpected none",
            false)
      of blaiForwardLayerWorkspaceMaterializeWeights:
        check("NPU model parsed configured workspace fixture active layer weights",
          true)
        case materialization.firstBlockedWeightWorkspaceFirstBlock
        of blaiForwardWeightWorkspaceWorkspace:
          check("NPU model parsed configured workspace fixture active weight workspace gate",
            true)
        of blaiForwardWeightWorkspaceWeight:
          check("NPU model parsed configured workspace fixture active weight fit gate",
            true)
        of blaiForwardWeightWorkspaceBias:
          check("NPU model parsed configured workspace fixture active bias fit gate",
            true)
        of blaiForwardWeightWorkspaceBuffer:
          check("NPU model parsed configured workspace fixture active weight buffer gate",
            true)
        of blaiForwardWeightWorkspaceNoBlock:
          check("NPU model parsed configured workspace fixture active weight unexpected none",
            false)
      of blaiForwardLayerWorkspaceMaterializeNoBlock:
        check("NPU model parsed configured workspace fixture active layer unexpected none",
          false)
    of blaiForwardModelWorkspaceMaterializeNoBlock:
      check("NPU model parsed configured workspace fixture active materialization unexpected none",
        false)
  of blaiParsedConfiguredWorkspaceGateBinding:
    check("NPU model parsed configured workspace fixture active terminal binding",
      terminalGateEvidence.bindingGateEvidence)
  of blaiParsedConfiguredWorkspaceGateHardwareAddresses:
    check("NPU model parsed configured workspace fixture active terminal hardware addresses",
      terminalGateEvidence.hardwareAddressesGateEvidence)
    case snapshot.hardwareAddressFirstBlock
    of blaiForwardWorkspaceHardwareAddressInstruction:
      check("NPU model parsed configured workspace fixture active hardware address instruction gate",
        true)
      if not fixture.binding.workspace.instruction.active:
        check("NPU model parsed configured workspace fixture active hardware instruction inactive",
          true)
      elif fixture.binding.workspace.instruction.address == 0'u32:
        check("NPU model parsed configured workspace fixture active hardware instruction zero",
          true)
        check("NPU model parsed configured workspace fixture active projection ready",
          activeWorkspaceProjection.projected and
            activeWorkspaceProjection.addressFits)
      else:
        check("NPU model parsed configured workspace fixture active hardware instruction unexplained",
          false)
    of blaiForwardWorkspaceHardwareAddressData:
      check("NPU model parsed configured workspace fixture active hardware address data gate",
        true)
    of blaiForwardWorkspaceHardwareAddressWeight:
      check("NPU model parsed configured workspace fixture active hardware address weight gate",
        true)
    of blaiForwardWorkspaceHardwareAddressBias:
      check("NPU model parsed configured workspace fixture active hardware address bias gate",
        true)
    of blaiForwardWorkspaceHardwareAddressBinding:
      check("NPU model parsed configured workspace fixture active hardware address binding gate",
        true)
    of blaiForwardWorkspaceHardwareAddressNoBlock:
      check("NPU model parsed configured workspace fixture active hardware address unexpected none",
        false)
  of blaiParsedConfiguredWorkspaceGateInput:
    check("NPU model parsed configured workspace fixture active terminal input",
      terminalGateEvidence.inputGateEvidence)
  of blaiParsedConfiguredWorkspaceGateRunSequence:
    check("NPU model parsed configured workspace fixture active terminal run sequence",
      terminalGateEvidence.runSequenceGateEvidence)
  of blaiParsedConfiguredWorkspaceGateExecution:
    logNpuRegisterSnapshot(
      "NPU model active launch BLAI registers",
      snapshot.launchRegistersCaptured,
      snapshot.launchRegisters)
    logNpuRegisterSnapshot(
      "NPU model active post-start BLAI registers",
      snapshot.startedRegistersCaptured,
      snapshot.startedRegisters)
    logNpuWaitExitRegisters(
      "NPU model active wait-exit BLAI registers",
      snapshot.lastExecutionWaitExitInterrupt,
      snapshot.lastExecutionWaitExitBusy,
      snapshot.lastExecutionWaitExitClock)
    let activeBlaiCommandStatus = npuBlaiCommandStatus()
    logBlaiCommandStatus(
      "NPU model active BLAI command status",
      activeBlaiCommandStatus)
    check("NPU model parsed configured workspace fixture active BLAI command status",
      activeBlaiCommandStatus.valid)
    let executionGateEvidence =
      blaiParsedForwardConfiguredWorkspaceExecutionGateEvidence(snapshot)
    check("NPU model parsed configured workspace fixture active execution gate evidence",
      executionGateEvidence.valid)
    check("NPU model parsed configured workspace fixture active terminal execution gate",
      terminalGateEvidence.executionGateEvidence)
    check("NPU model parsed configured workspace fixture active terminal execution",
      executionGateEvidence.terminalExecutionEvidence)
    check("NPU model parsed configured workspace fixture active execution attempted",
      executionGateEvidence.oneLayerAttempted)
    check("NPU model parsed configured workspace fixture active execution failed captured",
      executionGateEvidence.failedExecutionCaptured)
    check("NPU model parsed configured workspace fixture active execution started",
      executionGateEvidence.executionStarted)
    check("NPU model parsed configured workspace fixture active execution incomplete",
      executionGateEvidence.executionIncomplete)
    check("NPU model parsed configured workspace fixture active execution status evidence",
      executionGateEvidence.statusEvidence)
    check("NPU model parsed configured workspace fixture active execution timeout status",
      executionGateEvidence.timeoutStatus ==
        (snapshot.lastExecutionStatus == npuTimeout))
    check("NPU model parsed configured workspace fixture active execution timeout timed out",
      executionGateEvidence.timeoutTimedOut ==
        (snapshot.lastExecutionStatus == npuTimeout))
    check("NPU model parsed configured workspace fixture active execution unsupported status",
      executionGateEvidence.unsupportedStatus ==
        (snapshot.lastExecutionStatus == npuUnsupported))
    check("NPU model parsed configured workspace fixture active execution busy status",
      executionGateEvidence.busyStatus ==
        (snapshot.lastExecutionStatus == npuBusy))
    check("NPU model parsed configured workspace fixture active execution ok status",
      executionGateEvidence.unexpectedOkStatus ==
        (snapshot.lastExecutionStatus == npuOk))
    check("NPU model parsed configured workspace fixture active execution non-ok status",
      executionGateEvidence.okStatusEvidence)
    let activeEngineProgressEvidence =
      blaiParsedForwardConfiguredWorkspaceActiveEngineProgressEvidence(
        snapshot, fixture, executionGateEvidence)
    check("NPU model parsed configured workspace fixture active engine progress evidence",
      activeEngineProgressEvidence.valid)
    check("NPU model parsed configured workspace fixture active engine progress terminal gate",
      activeEngineProgressEvidence.terminalExecutionGate)
    check("NPU model parsed configured workspace fixture active engine progress run sequence",
      activeEngineProgressEvidence.runSequenceReady)
    check("NPU model parsed configured workspace fixture active engine progress counters",
      activeEngineProgressEvidence.countersMatch)
    check("NPU model parsed configured workspace fixture active engine progress attempted",
      activeEngineProgressEvidence.oneLayerAttempted)
    check("NPU model parsed configured workspace fixture active engine progress no complete",
      activeEngineProgressEvidence.noLayerCompleted)
    check("NPU model parsed configured workspace fixture active engine progress failed",
      activeEngineProgressEvidence.oneLayerFailed)
    check("NPU model parsed configured workspace fixture active engine progress first failed",
      activeEngineProgressEvidence.firstFailedLayerZero)
    check("NPU model parsed configured workspace fixture active engine progress captured",
      activeEngineProgressEvidence.failedExecutionCaptured)
    check("NPU model parsed configured workspace fixture active engine progress started",
      activeEngineProgressEvidence.executionStarted)
    check("NPU model parsed configured workspace fixture active engine progress incomplete",
      activeEngineProgressEvidence.executionIncomplete)
    check("NPU model parsed configured workspace fixture active engine progress timeout",
      activeEngineProgressEvidence.timeoutTerminal)
    case snapshot.lastExecutionStatus
    of npuTimeout:
      let activeTimeoutEvidence =
        blaiParsedForwardConfiguredWorkspaceActiveTimeoutEvidence(
          executionGateEvidence)
      check("NPU model parsed configured workspace fixture active timeout evidence",
        activeTimeoutEvidence.valid)
      check("NPU model parsed configured workspace fixture active timeout status evidence",
        activeTimeoutEvidence.timeoutStatus)
      check("NPU model parsed configured workspace fixture active timeout timed out evidence",
        activeTimeoutEvidence.timedOut)
      check("NPU model parsed configured workspace fixture active timeout no interrupt evidence",
        activeTimeoutEvidence.noInterrupt)
      check("NPU model parsed configured workspace fixture active timeout raw clear evidence",
        activeTimeoutEvidence.interruptRawClear)
      check("NPU model parsed configured workspace fixture active timeout command clean evidence",
        activeTimeoutEvidence.commandBitsClean)
      check("NPU model parsed configured workspace fixture active timeout busy or idle evidence",
        activeTimeoutEvidence.busyOrIdleKnown)
      check("NPU model parsed configured workspace fixture active timeout busy raw evidence",
        activeTimeoutEvidence.busyRawMatches)
      check("NPU model parsed configured workspace fixture active timeout clock retained evidence",
        activeTimeoutEvidence.clockRetained)
      check("NPU model parsed configured workspace fixture active timeout status valid evidence",
        activeTimeoutEvidence.statusValid)
      let activeWaitExitEvidence =
        blaiParsedForwardConfiguredWorkspaceActiveWaitExitEvidence(
          executionGateEvidence, activeTimeoutEvidence)
      check("NPU model parsed configured workspace fixture active wait-exit evidence",
        activeWaitExitEvidence.valid)
      check("NPU model parsed configured workspace fixture active wait-exit timeout",
        activeWaitExitEvidence.timeoutValid)
      check("NPU model parsed configured workspace fixture active wait-exit no interrupt",
        activeWaitExitEvidence.noCompletionInterrupt)
      check("NPU model parsed configured workspace fixture active wait-exit commands",
        activeWaitExitEvidence.commandBitsClean)
      check("NPU model parsed configured workspace fixture active wait-exit busy known",
        activeWaitExitEvidence.busyOrIdleKnown)
      check("NPU model parsed configured workspace fixture active wait-exit AXI activity",
        activeWaitExitEvidence.axiActivityKnown)
      check("NPU model parsed configured workspace fixture active wait-exit clock",
        activeWaitExitEvidence.clockRetained)
      check("NPU model parsed configured workspace fixture active wait-exit status",
        activeWaitExitEvidence.statusValid)
      check("NPU model parsed configured workspace fixture active wait-exit mode bits",
        activeWaitExitEvidence.modeMatchesBusyBits)
      check("NPU model parsed configured workspace fixture active wait-exit mode known",
        activeWaitExitEvidence.idleMode or
          activeWaitExitEvidence.writeActiveMode or
          activeWaitExitEvidence.readActiveMode or
          activeWaitExitEvidence.readWriteActiveMode)
      var activeWaitExitModeEvidenceInto:
        BlaiParsedForwardConfiguredWorkspaceActiveWaitExitModeEvidence
      blaiParsedForwardConfiguredWorkspaceActiveWaitExitModeEvidenceInto(
        activeWaitExitEvidence, activeWaitExitModeEvidenceInto)
      let activeWaitExitModeEvidence =
        blaiParsedForwardConfiguredWorkspaceActiveWaitExitModeEvidence(
          activeWaitExitEvidence)
      check("NPU model parsed configured workspace fixture active wait-exit mode into matches",
        activeWaitExitModeEvidenceInto == activeWaitExitModeEvidence)
      check("NPU model parsed configured workspace fixture active wait-exit mode evidence",
        activeWaitExitModeEvidence.valid)
      check("NPU model parsed configured workspace fixture active wait-exit mode classified",
        activeWaitExitModeEvidence.idleMode or
          activeWaitExitModeEvidence.writeActiveMode or
          activeWaitExitModeEvidence.readActiveMode or
          activeWaitExitModeEvidence.readWriteActive)
      check("NPU model parsed configured workspace fixture active wait-exit mode timeout",
        activeWaitExitModeEvidence.timeoutTerminal)
      check("NPU model parsed configured workspace fixture active wait-exit mode no interrupt",
        activeWaitExitModeEvidence.noCompletionInterrupt)
      check("NPU model parsed configured workspace fixture active wait-exit mode clock",
        activeWaitExitModeEvidence.clockRetained)
      check("NPU model parsed configured workspace fixture active wait-exit mode evidence bits",
        activeWaitExitModeEvidence.modeMatchesBits)
      let activeCompletionWaitBudget =
        blaiParsedForwardConfiguredWorkspaceActiveCompletionWaitBudgetEvidence(
          activeCompletionPolicy, activePollingWait, activeTimeoutEvidence,
          activeWaitExitEvidence)
      check("NPU model parsed configured workspace fixture active completion wait budget evidence",
        activeCompletionWaitBudget.valid)
      check("NPU model parsed configured workspace fixture active completion wait budget policy",
        activeCompletionWaitBudget.policyValid)
      check("NPU model parsed configured workspace fixture active completion wait budget polling",
        activeCompletionWaitBudget.pollingValid)
      check("NPU model parsed configured workspace fixture active completion wait budget timeout",
        activeCompletionWaitBudget.timeoutValid)
      check("NPU model parsed configured workspace fixture active completion wait budget wait-exit",
        activeCompletionWaitBudget.waitExitValid)
      check("NPU model parsed configured workspace fixture active completion wait budget configured",
        activeCompletionWaitBudget.waitConfigured)
      check("NPU model parsed configured workspace fixture active completion wait budget matches",
        activeCompletionWaitBudget.budgetMatchesPolicy)
      check("NPU model parsed configured workspace fixture active completion wait budget terminal",
        activeCompletionWaitBudget.terminalTimeout)
      check("NPU model parsed configured workspace fixture active completion wait budget exhausted",
        activeCompletionWaitBudget.pollBudgetExhausted)
      check("NPU model parsed configured workspace fixture active completion wait budget no interrupt",
        activeCompletionWaitBudget.noInterruptObserved)
      check("NPU model parsed configured workspace fixture active completion wait budget status",
        activeCompletionWaitBudget.statusTimedOut)
      check("NPU model parsed configured workspace fixture active completion wait budget wait no interrupt",
        activeCompletionWaitBudget.waitExitNoInterrupt)
      check("NPU model parsed configured workspace fixture active completion wait budget wait known",
        activeCompletionWaitBudget.waitExitKnown)
      check("NPU model parsed configured workspace fixture active completion wait budget commands",
        activeCompletionWaitBudget.commandBitsClean)
      check("NPU model parsed configured workspace fixture active completion wait budget clock",
        activeCompletionWaitBudget.clockRetained)
      check("NPU model parsed configured workspace fixture active completion wait budget deterministic",
        activeCompletionWaitBudget.deterministicTimeout)
      let activeCompletionBoundary =
        blaiParsedForwardConfiguredWorkspaceActiveCompletionBoundaryEvidence(
          activeCompletionPolicy, activeEngineProgressEvidence,
          activeTimeoutEvidence, deferredOutputEvidence)
      check("NPU model parsed configured workspace fixture active completion boundary evidence",
        activeCompletionBoundary.valid)
      check("NPU model parsed configured workspace fixture active completion boundary policy",
        activeCompletionBoundary.completionPolicyValid)
      check("NPU model parsed configured workspace fixture active completion boundary engine",
        activeCompletionBoundary.engineProgressValid)
      check("NPU model parsed configured workspace fixture active completion boundary timeout",
        activeCompletionBoundary.timeoutEvidenceValid)
      check("NPU model parsed configured workspace fixture active completion boundary deferred output",
        activeCompletionBoundary.deferredOutputValid)
      check("NPU model parsed configured workspace fixture active completion boundary no interrupt",
        activeCompletionBoundary.noCompletionInterrupt)
      check("NPU model parsed configured workspace fixture active completion boundary busy known",
        activeCompletionBoundary.busyOrIdleKnown)
      check("NPU model parsed configured workspace fixture active completion boundary output deferred",
        activeCompletionBoundary.outputDeferred)
      check("NPU model parsed configured workspace fixture active completion boundary remaining progress",
        activeCompletionBoundary.remainingCompletionProgress)
      let activeCompletionGap =
        blaiParsedForwardConfiguredWorkspaceActiveCompletionGapEvidence(
          activeCompletionBoundary, activeWaitExitEvidence, activeOutputBlocked)
      check("NPU model parsed configured workspace fixture active completion gap evidence",
        activeCompletionGap.valid)
      check("NPU model parsed configured workspace fixture active completion gap boundary",
        activeCompletionGap.boundaryValid)
      check("NPU model parsed configured workspace fixture active completion gap wait-exit",
        activeCompletionGap.waitExitValid)
      check("NPU model parsed configured workspace fixture active completion gap output blocked",
        activeCompletionGap.outputBlockedValid)
      check("NPU model parsed configured workspace fixture active completion gap no interrupt",
        activeCompletionGap.noCompletionInterrupt)
      check("NPU model parsed configured workspace fixture active completion gap wait-exit known",
        activeCompletionGap.waitExitKnown)
      check("NPU model parsed configured workspace fixture active completion gap output gate",
        activeCompletionGap.outputGateKnown)
      checkEq("NPU model parsed configured workspace fixture active completion gap reason",
        ord(activeCompletionGap.reason).uint32,
        ord(blaiParsedConfiguredActiveGapCompletionSignal).uint32)
      check("NPU model parsed configured workspace fixture active completion gap completion signal",
        activeCompletionGap.completionSignalMissing)
      check("NPU model parsed configured workspace fixture active completion gap output pending",
        not activeCompletionGap.outputEquivalencePending)
      check("NPU model parsed configured workspace fixture active completion gap reason evidence",
        activeCompletionGap.reasonMatchesEvidence)
      check("NPU model parsed configured workspace fixture active completion gap remaining progress",
        activeCompletionGap.remainingCompletionProgress)
      let activeRuntimeOwnership = blaiNpuRuntimeOwnershipPlan()
      let activeInitPlanForInterrupt = npuPlanInitConfig(
        NpuLayerBuffers(), inputBufferAddr = 0x2204_1000'u32, patchSize = 1'u32,
        netParams = NpuNetParams(tensorflowMode: true))
      let activeInterruptBinding = npuInterruptBindingReadiness(
        activeInitPlanForInterrupt.interrupt, activeRuntimeOwnership)
      let activeCompletionSignal =
        blaiParsedForwardConfiguredWorkspaceCompletionSignalEvidence(
          activeRuntimeOwnership, activeInterruptBinding, activeCompletionPolicy,
          activeWaitExitEvidence, activeCompletionGap)
      check("NPU model parsed configured workspace fixture active completion signal evidence",
        activeCompletionSignal.valid)
      check("NPU model parsed configured workspace fixture active completion signal source",
        activeCompletionSignal.source ==
          blaiParsedConfiguredCompletionSignalBareMetalPolling)
      check("NPU model parsed configured workspace fixture active completion signal SDK semaphore",
        activeCompletionSignal.sdkSemaphoreExpected)
      check("NPU model parsed configured workspace fixture active completion signal IRQ request",
        activeCompletionSignal.sdkCnnIrqRequested)
      check("NPU model parsed configured workspace fixture active completion signal IRQ priority",
        activeCompletionSignal.sdkPriorityMatched)
      check("NPU model parsed configured workspace fixture active completion signal D0 APU line",
        activeCompletionSignal.d0ApuLineCandidate)
      check("NPU model parsed configured workspace fixture active completion signal M0 alias",
        activeCompletionSignal.m0LineConflict)
      check("NPU model parsed configured workspace fixture active completion signal M0 unsafe",
        not activeCompletionSignal.m0BindingSafe)
      check("NPU model parsed configured workspace fixture active completion signal policy",
        activeCompletionSignal.coreBindingPolicyValid)
      check("NPU model parsed configured workspace fixture active completion signal policy evidence",
        activeCompletionSignal.coreBindingDecisionMatches)
      check("NPU model parsed configured workspace fixture active completion signal M0 polling required",
        activeCompletionSignal.m0PollingRequired)
      check("NPU model parsed configured workspace fixture active completion signal D0 binding candidate",
        activeCompletionSignal.d0BindingCandidate)
      check("NPU model parsed configured workspace fixture active completion signal operation plan",
        activeCompletionSignal.operationPlanValid)
      check("NPU model parsed configured workspace fixture active completion signal operations suppressed",
        activeCompletionSignal.operationPlanSuppressed)
      check("NPU model parsed configured workspace fixture active completion signal operation polling",
        activeCompletionSignal.operationPlanPreservesPolling)
      check("NPU model parsed configured workspace fixture active completion signal GLB route",
        activeCompletionSignal.glbRouteValid)
      check("NPU model parsed configured workspace fixture active completion signal MM aggregate",
        activeCompletionSignal.mmAggregateRouteValid and
          activeCompletionSignal.mmAggregateSurfaceKnown)
      check("NPU model parsed configured workspace fixture active completion signal MM subroute",
        activeCompletionSignal.mmAggregateSubrouteUnknown)
      check("NPU model parsed configured workspace fixture active completion signal MM polling",
        activeCompletionSignal.mmAggregatePollingPreserved)
      check("NPU model parsed configured workspace fixture active completion signal binding",
        activeCompletionSignal.bindingBlocksIrq)
      check("NPU model parsed configured workspace fixture active completion signal polling",
        activeCompletionSignal.activePolling)
      check("NPU model parsed configured workspace fixture active completion signal missing",
        activeCompletionSignal.completionSignalMissing)
      check("NPU model parsed configured workspace fixture active completion signal observed",
        activeCompletionSignal.pollingObservedMissingSignal)
      check("NPU model parsed configured workspace fixture active completion signal source evidence",
        activeCompletionSignal.sourceMatchesRuntime)
      let activeMmAggregateWaitExit =
        blaiParsedForwardConfiguredWorkspaceActiveMmAggregateWaitExitEvidence(
          activeCompletionSignal, snapshot.lastExecutionWaitExitMmAggregate)
      logActiveMmAggregateScan(
        "NPU model active MM aggregate raw scan",
        snapshot.lastExecutionWaitExitMmAggregate,
        activeMmAggregateWaitExit)
      check("NPU model parsed configured workspace fixture active MM aggregate wait-exit evidence",
        activeMmAggregateWaitExit.valid)
      check("NPU model parsed configured workspace fixture active MM aggregate wait-exit route",
        activeMmAggregateWaitExit.routeValid)
      check("NPU model parsed configured workspace fixture active MM aggregate wait-exit catalog",
        activeMmAggregateWaitExit.catalogValid)
      check("NPU model parsed configured workspace fixture active MM aggregate wait-exit snapshot",
        activeMmAggregateWaitExit.snapshotValid)
      check("NPU model parsed configured workspace fixture active MM aggregate wait-exit banks",
        activeMmAggregateWaitExit.bank0Known and
          activeMmAggregateWaitExit.bank1E907Known)
      check("NPU model parsed configured workspace fixture active MM aggregate wait-exit bitmaps",
        activeMmAggregateWaitExit.rawBitmapBanksKnown)
      check("NPU model parsed configured workspace fixture active MM aggregate wait-exit clear plan",
        activeMmAggregateWaitExit.clearPlanMatchesRaw)
      check("NPU model parsed configured workspace fixture active MM aggregate wait-exit no BLAI",
        activeMmAggregateWaitExit.noBlaiInterrupt)
      check("NPU model parsed configured workspace fixture active MM aggregate wait-exit pending class",
        activeMmAggregateWaitExit.pendingClassificationKnown)
      check("NPU model parsed configured workspace fixture active MM aggregate wait-exit pending enum",
        activeMmAggregateWaitExit.pendingClassMatchesSnapshot)
      check("NPU model parsed configured workspace fixture active MM aggregate wait-exit pending scan",
        activeMmAggregateWaitExit.pendingScanValid)
      checkEq("NPU model parsed configured workspace fixture active MM aggregate wait-exit scanned",
        activeMmAggregateWaitExit.pendingScan.scannedCount, 64)
      check("NPU model parsed configured workspace fixture active MM aggregate wait-exit scan counts",
        activeMmAggregateWaitExit.pendingScan.countsMatchSnapshot)
      check("NPU model parsed configured workspace fixture active MM aggregate wait-exit scan mirrors",
        activeMmAggregateWaitExit.rawPendingCount ==
          activeMmAggregateWaitExit.pendingScan.rawPendingCount and
          activeMmAggregateWaitExit.unmaskedPendingCount ==
            activeMmAggregateWaitExit.pendingScan.unmaskedPendingCount and
          activeMmAggregateWaitExit.maskedOnlyCount ==
            activeMmAggregateWaitExit.pendingScan.maskedOnlyCount and
          activeMmAggregateWaitExit.firstRawPendingIndex ==
            activeMmAggregateWaitExit.pendingScan.firstRawPendingIndex and
          activeMmAggregateWaitExit.firstUnmaskedPendingIndex ==
            activeMmAggregateWaitExit.pendingScan.firstUnmaskedPendingIndex and
          activeMmAggregateWaitExit.firstMaskedOnlyIndex ==
            activeMmAggregateWaitExit.pendingScan.firstMaskedOnlyIndex)
      check("NPU model parsed configured workspace fixture active MM aggregate wait-exit no named subroute",
        activeMmAggregateWaitExit.noNamedNpuSubroute)
      check("NPU model parsed configured workspace fixture active MM aggregate wait-exit subroute",
        activeMmAggregateWaitExit.subrouteUnknown)
      check("NPU model parsed configured workspace fixture active MM aggregate wait-exit polling",
        activeMmAggregateWaitExit.pollingPreserved)
      let activePollingSignal =
        blaiParsedForwardConfiguredWorkspaceActivePollingSignalEvidence(
          activeCompletionSignal, activeCompletionWaitBudget, activePollingWait)
      check("NPU model parsed configured workspace fixture active polling signal evidence",
        activePollingSignal.valid)
      check("NPU model parsed configured workspace fixture active polling signal signal",
        activePollingSignal.signalValid)
      check("NPU model parsed configured workspace fixture active polling signal budget",
        activePollingSignal.waitBudgetValid)
      check("NPU model parsed configured workspace fixture active polling signal polling",
        activePollingSignal.pollingValid)
      check("NPU model parsed configured workspace fixture active polling signal active",
        activePollingSignal.activePolling)
      check("NPU model parsed configured workspace fixture active polling signal source",
        activePollingSignal.pollingSource)
      check("NPU model parsed configured workspace fixture active polling signal full budget",
        activePollingSignal.fullBudgetConsumed)
      check("NPU model parsed configured workspace fixture active polling signal final clear",
        activePollingSignal.finalSampleClear)
      check("NPU model parsed configured workspace fixture active polling signal no interrupt",
        activePollingSignal.noInterruptObserved)
      check("NPU model parsed configured workspace fixture active polling signal timeout",
        activePollingSignal.timeoutTerminal)
      check("NPU model parsed configured workspace fixture active polling signal missing",
        activePollingSignal.missingSignal)
      check("NPU model parsed configured workspace fixture active polling signal deferred",
        activePollingSignal.bindingStillDeferred)
      check("NPU model parsed configured workspace fixture active polling signal coherent",
        activePollingSignal.signalMatchesPollTrace)
      let activeRecoveryFrontier =
        blaiParsedForwardConfiguredWorkspaceActiveRecoveryFrontierEvidence(
          activeExitCleanup, activeCompletionGap, activeCompletionSignal)
      check("NPU model parsed configured workspace fixture active recovery frontier evidence",
        activeRecoveryFrontier.valid)
      check("NPU model parsed configured workspace fixture active recovery frontier cleanup",
        activeRecoveryFrontier.cleanupComplete)
      check("NPU model parsed configured workspace fixture active recovery frontier signal",
        activeRecoveryFrontier.completionSignalMissing)
      check("NPU model parsed configured workspace fixture active recovery frontier polling",
        activeRecoveryFrontier.activePolling)
      check("NPU model parsed configured workspace fixture active recovery frontier M0 polling",
        activeRecoveryFrontier.m0PollingRequired)
      check("NPU model parsed configured workspace fixture active recovery frontier output",
        activeRecoveryFrontier.outputEquivalenceNotPending)
      check("NPU model parsed configured workspace fixture active recovery frontier coherent",
        activeRecoveryFrontier.frontierMatchesEvidence)
      let activeCompletionRouteTarget =
        blaiParsedForwardConfiguredWorkspaceCompletionRouteTargetEvidence(
          activeRecoveryFrontier, activeCompletionSignal, activeInterruptBinding)
      check("NPU model parsed configured workspace fixture active completion route target evidence",
        activeCompletionRouteTarget.valid)
      check("NPU model parsed configured workspace fixture active completion route target API contract",
        activeCompletionRouteTarget.apiContractValid)
      check("NPU model parsed configured workspace fixture active completion route target SDK route",
        activeCompletionRouteTarget.sdkRouteRequested)
      check("NPU model parsed configured workspace fixture active completion route target D0 route",
        activeCompletionRouteTarget.d0RoutePreserved)
      check("NPU model parsed configured workspace fixture active completion route target M0 polling",
        activeCompletionRouteTarget.m0PollingPreserved)
      check("NPU model parsed configured workspace fixture active completion route target deferred",
        activeCompletionRouteTarget.localBindingDeferred)
      check("NPU model parsed configured workspace fixture active completion route target API deferred",
        activeCompletionRouteTarget.apiCallsDeferred)
      check("NPU model parsed configured workspace fixture active completion route target operations suppressed",
        activeCompletionRouteTarget.activeOperationsSuppressed)
      check("NPU model parsed configured workspace fixture active completion route target GLB route",
        activeCompletionRouteTarget.glbRouteValid)
      check("NPU model parsed configured workspace fixture active completion route target MM aggregate",
        activeCompletionRouteTarget.mmAggregateRouteValid)
      check("NPU model parsed configured workspace fixture active completion route target MM subroute",
        activeCompletionRouteTarget.mmAggregateSubrouteUnknown)
      check("NPU model parsed configured workspace fixture active completion route target MM polling",
        activeCompletionRouteTarget.mmAggregatePollingPreserved)
      check("NPU model parsed configured workspace fixture active completion route target operations deferred",
        activeCompletionRouteTarget.routeOperationsDeferred)
      check("NPU model parsed configured workspace fixture active completion route target coherent",
        activeCompletionRouteTarget.routeMatchesFrontier)
      let activeRouteAggregate =
        blaiParsedForwardConfiguredWorkspaceActiveCompletionRouteAggregateEvidence(
          activeRecoveryFrontier, activeCompletionSignal, activeMmAggregateWaitExit,
          activeCompletionRouteTarget)
      check("NPU model parsed configured workspace fixture active route aggregate evidence",
        activeRouteAggregate.valid)
      check("NPU model parsed configured workspace fixture active route aggregate live",
        activeRouteAggregate.liveAggregateSnapshotValid)
      check("NPU model parsed configured workspace fixture active route aggregate no BLAI",
        activeRouteAggregate.noBlaiInterrupt)
      check("NPU model parsed configured workspace fixture active route aggregate subroute",
        activeRouteAggregate.subrouteUnknown)
      check("NPU model parsed configured workspace fixture active route aggregate polling",
        activeRouteAggregate.pollingPreserved)
      check("NPU model parsed configured workspace fixture active route aggregate deferred",
        activeRouteAggregate.routeTargetDeferred)
      check("NPU model parsed configured workspace fixture active route aggregate coherent",
        activeRouteAggregate.routeMatchesLiveAggregate)
      let activeOutputEquivalenceFrontier =
        blaiParsedForwardConfiguredWorkspaceOutputEquivalenceFrontierEvidence(
          activeCompletionRouteTarget, activeRouteAggregate, activeCompletionGap,
          activeOutputBlocked)
      check("NPU model parsed configured workspace fixture active output equivalence frontier evidence",
        activeOutputEquivalenceFrontier.valid)
      check("NPU model parsed configured workspace fixture active output equivalence frontier route",
        activeOutputEquivalenceFrontier.completionRouteDeferred)
      check("NPU model parsed configured workspace fixture active output equivalence frontier route aggregate",
        activeOutputEquivalenceFrontier.routeAggregateValid)
      check("NPU model parsed configured workspace fixture active output equivalence frontier live route",
        activeOutputEquivalenceFrontier.liveRouteDeferred)
      check("NPU model parsed configured workspace fixture active output equivalence frontier gap",
        activeOutputEquivalenceFrontier.currentGapIsCompletionSignal)
      check("NPU model parsed configured workspace fixture active output equivalence frontier gate",
        activeOutputEquivalenceFrontier.outputGateKnown)
      check("NPU model parsed configured workspace fixture active output equivalence frontier readback",
        activeOutputEquivalenceFrontier.outputReadbackNotStarted)
      check("NPU model parsed configured workspace fixture active output equivalence frontier compare",
        activeOutputEquivalenceFrontier.compareNotStarted)
      check("NPU model parsed configured workspace fixture active output equivalence frontier mismatch",
        activeOutputEquivalenceFrontier.noOutputMismatchObserved)
      check("NPU model parsed configured workspace fixture active output equivalence frontier deferred",
        activeOutputEquivalenceFrontier.outputEquivalenceDeferred)
      check("NPU model parsed configured workspace fixture active output equivalence frontier next",
        activeOutputEquivalenceFrontier.outputEquivalenceNextAfterCompletion)
      check("NPU model parsed configured workspace fixture active output equivalence frontier coherent",
        activeOutputEquivalenceFrontier.frontierMatchesEvidence)
      let activeCompletionToOutputHandoff =
        blaiParsedForwardConfiguredWorkspaceActiveCompletionToOutputHandoffEvidence(
          activeCompletionRouteTarget, activeRouteAggregate, activeOutputTransferScope,
          activeOutputEquivalenceFrontier)
      check("NPU model parsed configured workspace fixture active completion-output handoff evidence",
        activeCompletionToOutputHandoff.valid)
      check("NPU model parsed configured workspace fixture active completion-output handoff route",
        activeCompletionToOutputHandoff.routeDeferred)
      check("NPU model parsed configured workspace fixture active completion-output handoff route aggregate",
        activeCompletionToOutputHandoff.routeAggregateValid)
      check("NPU model parsed configured workspace fixture active completion-output handoff live route",
        activeCompletionToOutputHandoff.liveRouteAggregate)
      check("NPU model parsed configured workspace fixture active completion-output handoff output scope",
        activeCompletionToOutputHandoff.primaryOnlyOutput)
      check("NPU model parsed configured workspace fixture active completion-output handoff readback",
        activeCompletionToOutputHandoff.readbackReady)
      check("NPU model parsed configured workspace fixture active completion-output handoff deferred",
        activeCompletionToOutputHandoff.outputEquivalenceDeferred)
      check("NPU model parsed configured workspace fixture active completion-output handoff next",
        activeCompletionToOutputHandoff.outputNextAfterCompletion)
      check("NPU model parsed configured workspace fixture active completion-output handoff coherent",
        activeCompletionToOutputHandoff.handoffMatchesEvidence)
      let activePostBudgetOutputGate =
        blaiParsedForwardConfiguredWorkspaceActivePostBudgetOutputGateEvidence(
          activeCompletionWaitBudget, activeOutputTransferScope,
          activeOutputEquivalenceFrontier, activeCompletionToOutputHandoff)
      check("NPU model parsed configured workspace fixture active post-budget output gate evidence",
        activePostBudgetOutputGate.valid)
      check("NPU model parsed configured workspace fixture active post-budget output gate budget",
        activePostBudgetOutputGate.waitBudgetValid)
      check("NPU model parsed configured workspace fixture active post-budget output gate scope",
        activePostBudgetOutputGate.outputScopeValid)
      check("NPU model parsed configured workspace fixture active post-budget output gate frontier",
        activePostBudgetOutputGate.outputFrontierValid)
      check("NPU model parsed configured workspace fixture active post-budget output gate handoff",
        activePostBudgetOutputGate.handoffValid)
      check("NPU model parsed configured workspace fixture active post-budget output gate timeout",
        activePostBudgetOutputGate.deterministicTimeout)
      check("NPU model parsed configured workspace fixture active post-budget output gate no interrupt",
        activePostBudgetOutputGate.noCompletionInterrupt)
      check("NPU model parsed configured workspace fixture active post-budget output gate live route",
        activePostBudgetOutputGate.liveRouteBackedHandoff)
      check("NPU model parsed configured workspace fixture active post-budget output gate plan",
        activePostBudgetOutputGate.outputPlanReady)
      check("NPU model parsed configured workspace fixture active post-budget output gate readback",
        activePostBudgetOutputGate.outputReadbackDeferred)
      check("NPU model parsed configured workspace fixture active post-budget output gate compare",
        activePostBudgetOutputGate.compareDeferred)
      check("NPU model parsed configured workspace fixture active post-budget output gate primary",
        activePostBudgetOutputGate.primaryOnlyOutput)
      check("NPU model parsed configured workspace fixture active post-budget output gate order",
        activePostBudgetOutputGate.completionBeforeOutput)
      check("NPU model parsed configured workspace fixture active post-budget output gate next",
        activePostBudgetOutputGate.nextStageOutputEquivalence)
      check("NPU model parsed configured workspace fixture active post-budget output gate coherent",
        activePostBudgetOutputGate.gateMatchesEvidence)
      let activeGapOutputRoute =
        blaiParsedForwardConfiguredWorkspaceActiveGapOutputRouteEvidence(
          activeCompletionGap, activePostBudgetOutputGate)
      check("NPU model parsed configured workspace fixture active gap output route evidence",
        activeGapOutputRoute.valid)
      check("NPU model parsed configured workspace fixture active gap output route gap",
        activeGapOutputRoute.gapValid)
      check("NPU model parsed configured workspace fixture active gap output route gate",
        activeGapOutputRoute.postBudgetGateValid)
      check("NPU model parsed configured workspace fixture active gap output route live",
        activeGapOutputRoute.liveRouteBackedOutputGate)
      check("NPU model parsed configured workspace fixture active gap output route reason",
        activeGapOutputRoute.reasonStillCompletionSignal)
      check("NPU model parsed configured workspace fixture active gap output route deferred",
        activeGapOutputRoute.outputPendingDeferred)
      check("NPU model parsed configured workspace fixture active gap output route coherent",
        activeGapOutputRoute.gapMatchesRouteGate)
      let activeRecoveryRouteFrontier =
        blaiParsedForwardConfiguredWorkspaceActiveRecoveryRouteFrontierEvidence(
          activeRecoveryFrontier, activeRouteAggregate, activeGapOutputRoute)
      check("NPU model parsed configured workspace fixture active recovery route frontier evidence",
        activeRecoveryRouteFrontier.valid)
      check("NPU model parsed configured workspace fixture active recovery route frontier route",
        activeRecoveryRouteFrontier.routeAggregateValid)
      check("NPU model parsed configured workspace fixture active recovery route frontier gap route",
        activeRecoveryRouteFrontier.gapOutputRouteValid)
      check("NPU model parsed configured workspace fixture active recovery route frontier signal",
        activeRecoveryRouteFrontier.completionSignalMissing)
      check("NPU model parsed configured workspace fixture active recovery route frontier live route",
        activeRecoveryRouteFrontier.liveRouteDeferred)
      check("NPU model parsed configured workspace fixture active recovery route frontier output gate",
        activeRecoveryRouteFrontier.outputGateLiveRouteBacked)
      check("NPU model parsed configured workspace fixture active recovery route frontier coherent",
        activeRecoveryRouteFrontier.frontierMatchesLiveRoute)
      let activeCompletionRouteResolution =
        blaiParsedForwardConfiguredWorkspaceActiveCompletionRouteResolutionEvidence(
          activeCompletionRouteTarget, activeRecoveryRouteFrontier)
      check("NPU model parsed configured workspace fixture active completion route resolution evidence",
        activeCompletionRouteResolution.valid)
      check("NPU model parsed configured workspace fixture active completion route resolution SDK route",
        activeCompletionRouteResolution.sdkRoutePreserved)
      check("NPU model parsed configured workspace fixture active completion route resolution deferred",
        activeCompletionRouteResolution.localBindingDeferred)
      check("NPU model parsed configured workspace fixture active completion route resolution operations",
        activeCompletionRouteResolution.routeOperationsDeferred)
      check("NPU model parsed configured workspace fixture active completion route resolution polling",
        activeCompletionRouteResolution.pollingPreserved)
      check("NPU model parsed configured workspace fixture active completion route resolution live frontier",
        activeCompletionRouteResolution.liveRouteFrontier)
      check("NPU model parsed configured workspace fixture active completion route resolution output gate",
        activeCompletionRouteResolution.outputGateDeferred)
      check("NPU model parsed configured workspace fixture active completion route resolution coherent",
        activeCompletionRouteResolution.resolutionMatchesFrontier)
      let activeOutputEquivalenceReadiness =
        blaiParsedForwardConfiguredWorkspaceOutputEquivalenceReadinessEvidence(
          activeCompletionRouteResolution, activeCompletionToOutputHandoff,
          activePostBudgetOutputGate, activeOutputEquivalenceFrontier)
      check("NPU model parsed configured workspace fixture active output equivalence readiness evidence",
        activeOutputEquivalenceReadiness.valid)
      check("NPU model parsed configured workspace fixture active output equivalence readiness route",
        activeOutputEquivalenceReadiness.routeResolutionValid)
      check("NPU model parsed configured workspace fixture active output equivalence readiness handoff",
        activeOutputEquivalenceReadiness.handoffValid)
      check("NPU model parsed configured workspace fixture active output equivalence readiness post-budget",
        activeOutputEquivalenceReadiness.postBudgetGateValid)
      check("NPU model parsed configured workspace fixture active output equivalence readiness deferred route",
        activeOutputEquivalenceReadiness.routeStillDeferred)
      check("NPU model parsed configured workspace fixture active output equivalence readiness completion",
        activeOutputEquivalenceReadiness.completionStillMissing)
      check("NPU model parsed configured workspace fixture active output equivalence readiness plan",
        activeOutputEquivalenceReadiness.outputPlanReady)
      check("NPU model parsed configured workspace fixture active output equivalence readiness readback",
        activeOutputEquivalenceReadiness.readbackReadyAfterCompletion)
      check("NPU model parsed configured workspace fixture active output equivalence readiness compare",
        activeOutputEquivalenceReadiness.compareReadyAfterCompletion)
      check("NPU model parsed configured workspace fixture active output equivalence readiness blocked",
        activeOutputEquivalenceReadiness.outputEquivalenceBlockedByCompletion)
      check("NPU model parsed configured workspace fixture active output equivalence readiness next",
        activeOutputEquivalenceReadiness.nextStageOutputEquivalence)
      check("NPU model parsed configured workspace fixture active output equivalence readiness coherent",
        activeOutputEquivalenceReadiness.readinessMatchesEvidence)
      check("NPU model parsed configured workspace fixture active execution timeout",
        executionGateEvidence.timeoutWaitEvidence)
      check("NPU model parsed configured workspace fixture active wait no interrupt",
        executionGateEvidence.waitNoInterrupt)
      check("NPU model parsed configured workspace fixture active wait int raw clear",
        executionGateEvidence.waitInterruptRawClear)
      check("NPU model parsed configured workspace fixture active wait int cfg resume clean",
        executionGateEvidence.waitResumeCommandClean)
      check("NPU model parsed configured workspace fixture active wait int cfg stop clean",
        executionGateEvidence.waitStopCommandClean)
      check("NPU model parsed configured workspace fixture active wait int cfg clear clean",
        executionGateEvidence.waitInterruptClearCommandClean)
      check("NPU model parsed configured workspace fixture active wait int cfg status clean",
        executionGateEvidence.waitInterruptStatusClean)
      check("NPU model parsed configured workspace fixture active wait int cfg clean",
        executionGateEvidence.waitInterruptConfigClean)
      if executionGateEvidence.waitBusy:
        check("NPU model parsed configured workspace fixture active wait busy",
          true)
        check("NPU model parsed configured workspace fixture active wait axi write state",
          executionGateEvidence.waitAxiWriteActive ==
            (not snapshot.lastExecutionWaitExitBusy.axiWriteIdle))
        check("NPU model parsed configured workspace fixture active wait axi read state",
          executionGateEvidence.waitAxiReadActive ==
            (not snapshot.lastExecutionWaitExitBusy.axiReadIdle))
        check("NPU model parsed configured workspace fixture active wait busy raw",
          executionGateEvidence.waitBusyRawActive)
      else:
        check("NPU model parsed configured workspace fixture active wait idle",
          executionGateEvidence.waitIdle)
      check("NPU model parsed configured workspace fixture active wait clock enabled",
        executionGateEvidence.waitClockEnabled)
      check("NPU model parsed configured workspace fixture active wait clock source known",
        executionGateEvidence.waitClockSourceKnown)
      check("NPU model parsed configured workspace fixture active wait clock source 320M",
        executionGateEvidence.waitClockSource320M)
      check("NPU model parsed configured workspace fixture active wait clock divider zero",
        executionGateEvidence.waitClockDividerZero)
      check("NPU model parsed configured workspace fixture active wait clock source",
        executionGateEvidence.waitClockSourceMatches)
    of npuOk:
      check("NPU model parsed configured workspace fixture active execution unexpected ok",
        executionGateEvidence.okStatusEvidence)
    of npuUnsupported:
      check("NPU model parsed configured workspace fixture active execution unsupported",
        executionGateEvidence.unsupportedStatus)
    of npuBusy:
      check("NPU model parsed configured workspace fixture active execution busy",
        executionGateEvidence.busyStatus)
  of blaiParsedConfiguredWorkspaceGateOutput:
    check("NPU model parsed configured workspace fixture active terminal output",
      terminalGateEvidence.outputGateEvidence)

proc checkConfiguredExecutionGuards() =
  let composedClock = npuMmClkCpuWithClock(
    0xA5A5_0001'u32, enable = true, source = npuClk320M, divider = 9'u32)
  let composedClockStatus = npuClockStatusFromMmClkCpu(composedClock)
  check("NPU model clock compose enabled",
    composedClockStatus.enabled)
  check("NPU model clock compose source",
    composedClockStatus.sourceKnown and composedClockStatus.source == npuClk320M)
  checkEq("NPU model clock compose divider",
    composedClockStatus.divider, 1'u32)
  var clockConfigPlanInto: NpuClockConfigPlan
  npuClockConfigPlanInto(
    0xA5A5_0001'u32, enable = true, source = npuClk320M, divider = 9'u32,
    clockConfigPlanInto)
  let clockConfigPlan =
    npuClockConfigPlan(
      0xA5A5_0001'u32, enable = true, source = npuClk320M, divider = 9'u32)
  check("NPU model clock config plan into matches",
    clockConfigPlanInto == clockConfigPlan)
  check("NPU model clock config plan valid",
    clockConfigPlan.valid and clockConfigPlan.status.enabled)
  check("NPU model clock config plan source",
    clockConfigPlan.status.sourceKnown and
      clockConfigPlan.status.source == npuClk320M)
  checkEq("NPU model clock config plan divider",
    clockConfigPlan.status.divider, 1'u32)
  check("NPU model clock config plan preserves",
    (clockConfigPlan.encoded and not (
      CnnClkDivEnMask or CnnClkSelMask or CnnClkDivMask)) ==
      (0xA5A5_0001'u32 and not (
        CnnClkDivEnMask or CnnClkSelMask or CnnClkDivMask)))
  let gateOnlyClock =
    npuMmClkCpuWithClockEnable(composedClock, false)
  let gateOnlyClockStatus = npuClockStatusFromMmClkCpu(gateOnlyClock)
  check("NPU model clock compose gate disabled",
    not gateOnlyClockStatus.enabled)
  check("NPU model clock compose gate preserves",
    gateOnlyClockStatus.source == npuClk320M and
      gateOnlyClockStatus.divider == 1'u32)
  var clockGatePlanInto: NpuClockGatePlan
  npuClockGatePlanInto(composedClock, enable = false, clockGatePlanInto)
  let clockGatePlan = npuClockGatePlan(composedClock, enable = false)
  check("NPU model clock gate plan into matches",
    clockGatePlanInto == clockGatePlan)
  check("NPU model clock gate plan disables",
    clockGatePlan.valid and not clockGatePlan.status.enabled)
  check("NPU model clock gate plan preserves",
    clockGatePlan.preservesSource and clockGatePlan.preservesDivider and
      clockGatePlan.status.source == npuClk320M and
      clockGatePlan.status.divider == 1'u32)
  var clockEnablePlanInto: NpuClockEnableRegisterPlan
  npuClockEnableRegisterPlanInto(composedClock, enable = false,
    clockEnablePlanInto)
  let clockEnablePlan =
    npuClockEnableRegisterPlan(composedClock, enable = false)
  check("NPU model clock enable register plan into matches",
    clockEnablePlanInto == clockEnablePlan)
  check("NPU model clock enable register plan disables",
    clockEnablePlan.valid and not clockEnablePlan.gatePlan.status.enabled)
  check("NPU model clock enable register plan preserves",
    clockEnablePlan.preservesSource and clockEnablePlan.preservesDivider and
      clockEnablePlan.gatePlan.status.source == npuClk320M and
      clockEnablePlan.gatePlan.status.divider == 1'u32)
  let decodedClock = npuClockStatusFromMmClkCpu(
    CnnClkDivEnMask or (ord(npuClk240M).uint32 shl CnnClkSelShift) or
      (3'u32 shl CnnClkDivShift))
  check("NPU model clock status enabled", decodedClock.enabled)
  check("NPU model clock status source known", decodedClock.sourceKnown)
  checkEq("NPU model clock status source",
    ord(decodedClock.source).uint32, ord(npuClk240M).uint32)
  checkEq("NPU model clock status divider", decodedClock.divider, 3)
  let unknownClock = npuClockStatusFromMmClkCpu(
    CnnClkDivEnMask or (3'u32 shl CnnClkSelShift))
  check("NPU model clock status unknown source",
    not unknownClock.sourceKnown)
  checkEq("NPU model clock status source bits", unknownClock.sourceBits, 3)
  let releasedVramCtrl =
    npuVramCtrlWithSysramSet(npuVramCtrlWithBlaiSramRelease(0'u32))
  let releasedVramStatus = npuSramStatusFromVramCtrl(releasedVramCtrl)
  check("NPU model SRAM compose release",
    releasedVramStatus.blaiSramReleased)
  check("NPU model SRAM compose set latch",
    releasedVramStatus.sysramSetLatched)
  var sramReleasePlanInto: NpuSramReleasePlan
  npuSramReleasePlanInto(0x1234_0000'u32, sramReleasePlanInto)
  let sramReleasePlan = npuSramReleasePlan(0x1234_0000'u32)
  check("NPU model SRAM release plan into matches",
    sramReleasePlanInto == sramReleasePlan)
  check("NPU model SRAM release plan first write",
    sramReleasePlan.valid and
      sramReleasePlan.releaseStatus.blaiSramReleased and
      not sramReleasePlan.releaseStatus.sysramSetLatched)
  check("NPU model SRAM release plan latch write",
    sramReleasePlan.latchStatus.blaiSramReleased and
      sramReleasePlan.latchStatus.sysramSetLatched)
  var initClockSelectPlanInto: NpuInitClockSelectRegisterPlan
  npuInitClockSelectRegisterPlanInto(
    CnnClkDivEnMask or (ord(npuClk240M).uint32 shl CnnClkSelShift) or
      (3'u32 shl CnnClkDivShift),
    initClockSelectPlanInto)
  let initClockSelectPlan = npuInitClockSelectRegisterPlan(
    CnnClkDivEnMask or (ord(npuClk240M).uint32 shl CnnClkSelShift) or
      (3'u32 shl CnnClkDivShift))
  check("NPU model init clock select plan into matches",
    initClockSelectPlanInto == initClockSelectPlan)
  check("NPU model init clock select plan source",
    initClockSelectPlan.valid and
      initClockSelectPlan.status.source == npuClk320M)
  check("NPU model init clock select plan preserves",
    initClockSelectPlan.preservesGate and
      initClockSelectPlan.preservesDivider and
      initClockSelectPlan.status.enabled and
      initClockSelectPlan.status.divider == 3'u32)
  var runtimeInitPlanInto: NpuRuntimeInitRegisterPlan
  npuRuntimeInitRegisterPlanInto(
    mmClkCpu = 0xA5A5_0001'u32,
    swResetCodecSub = 0x1234_0000'u32,
    vramCtrl = 0x55AA_0000'u32,
    runtimeInitPlanInto)
  let runtimeInitPlan =
    npuRuntimeInitRegisterPlan(
      0xA5A5_0001'u32, 0x1234_0000'u32, 0x55AA_0000'u32)
  check("NPU model runtime init register plan into matches",
    runtimeInitPlanInto == runtimeInitPlan)
  check("NPU model runtime init register plan source select",
    runtimeInitPlan.initClockSelect.valid and
      runtimeInitPlan.initClockSelect.status.source == npuClk320M and
      runtimeInitPlan.clock.initialMmClkCpu ==
        runtimeInitPlan.initClockSelect.encoded)
  check("NPU model runtime init register plan clock",
    runtimeInitPlan.valid and runtimeInitPlan.clock.status.enabled and
      runtimeInitPlan.clock.status.source == npuClk320M)
  check("NPU model runtime init register plan SRAM",
    runtimeInitPlan.sram.valid and
      runtimeInitPlan.sram.latchStatus.blaiSramReleased)
  check("NPU model runtime init register plan final gate",
    runtimeInitPlan.disablesClock and
      not runtimeInitPlan.finalClockGate.status.enabled)
  let qosCtrl = npuCodecQosCtrlWithCnnQos(0x1234_0000'u32, aw = true, ar = false)
  check("NPU model codec qos compose aw",
    (qosCtrl and CnnAwqosMask) != 0'u32)
  check("NPU model codec qos compose ar clear",
    (qosCtrl and CnnArqosMask) == 0'u32)
  var qosPlanInto: NpuCodecQosPlan
  npuCodecQosPlanInto(0x1234_0000'u32, aw = true, ar = false, qosPlanInto)
  let qosPlan = npuCodecQosPlan(0x1234_0000'u32, aw = true, ar = false)
  check("NPU model codec qos plan into matches",
    qosPlanInto == qosPlan)
  check("NPU model codec qos plan encoded",
    qosPlan.aw and not qosPlan.ar and
      qosPlan.encoded == qosCtrl)
  let qosClearPlan =
    npuCodecQosPlan(CnnAwqosMask or CnnArqosMask or 0x55AA_0000'u32,
      aw = false, ar = true)
  check("NPU model codec qos plan preserves",
    (qosClearPlan.encoded and CnnAwqosMask) == 0'u32 and
      (qosClearPlan.encoded and CnnArqosMask) != 0'u32 and
      (qosClearPlan.encoded and not (CnnAwqosMask or CnnArqosMask)) ==
        0x55AA_0000'u32)
  var limiterPlanInto: NpuBusLimiterPlan
  npuBusLimiterPlanInto(
    readCount = 0x1_2345'u32, writeCount = 0x2_4567'u32,
    readMode = true, writeMode = false, limiterPlanInto)
  let limiterPlan = npuBusLimiterPlan(
    readCount = 0x1_2345'u32, writeCount = 0x2_4567'u32,
    readMode = true, writeMode = false)
  check("NPU model bus limiter plan into matches",
    limiterPlanInto == limiterPlan)
  check("NPU model bus limiter compose read",
    limiterPlan.read == (BlaiLimiterModeMask or 0x2345'u32))
  check("NPU model bus limiter compose write",
    limiterPlan.write == 0x4567'u32)
  let resetWord = npuSwResetCodecSubWithCnnReset(0'u32, asserted = true)
  check("NPU model reset compose asserted",
    npuResetStatusFromSwResetCodecSub(resetWord).resetAsserted)
  let releaseWord = npuSwResetCodecSubWithCnnReset(resetWord, asserted = false)
  check("NPU model reset compose released",
    npuResetStatusFromSwResetCodecSub(releaseWord).resetReleased)
  var resetLinePlanInto: NpuResetLinePlan
  npuResetLinePlanInto(0x1234_0000'u32, asserted = true, resetLinePlanInto)
  let resetLinePlan = npuResetLinePlan(0x1234_0000'u32, asserted = true)
  check("NPU model reset line plan into matches",
    resetLinePlanInto == resetLinePlan)
  check("NPU model reset line plan asserted",
    resetLinePlan.valid and resetLinePlan.status.resetAsserted and
      resetLinePlan.encoded == (0x1234_0000'u32 or CnnResetMask))
  let resetLineReleasePlan =
    npuResetLinePlan(0x1234_0000'u32 or CnnResetMask, asserted = false)
  check("NPU model reset line plan released",
    resetLineReleasePlan.valid and
      resetLineReleasePlan.status.resetReleased and
      resetLineReleasePlan.encoded == 0x1234_0000'u32)
  var resetPulsePlanInto: NpuResetPulsePlan
  npuResetPulsePlanInto(0x1234_0000'u32, resetPulsePlanInto)
  let resetPulsePlan = npuResetPulsePlan(0x1234_0000'u32)
  check("NPU model reset pulse plan into matches",
    resetPulsePlanInto == resetPulsePlan)
  check("NPU model reset pulse plan asserted",
    resetPulsePlan.assertStatus.resetAsserted and
      resetPulsePlan.assertWrite == (0x1234_0000'u32 or CnnResetMask))
  check("NPU model reset pulse plan released",
    resetPulsePlan.releaseStatus.resetReleased and
      resetPulsePlan.releaseWrite == 0x1234_0000'u32)
  checkEq("NPU model reset pulse plan delay",
    resetPulsePlan.settleReadCount, NpuResetSettleReads)
  let blockedSram = npuSramStatusFromVramCtrl(0'u32)
  check("NPU model SRAM status blocked",
    not blockedSram.blaiSramReleased)
  check("NPU model SRAM status set clear",
    not blockedSram.sysramSetLatched)
  let releasedSram =
    npuSramStatusFromVramCtrl(BlaiSramRelMask or SysramSetMask)
  check("NPU model SRAM status released",
    releasedSram.blaiSramReleased)
  check("NPU model SRAM status set latched",
    releasedSram.sysramSetLatched)
  let resetAsserted = npuResetStatusFromSwResetCodecSub(CnnResetMask)
  check("NPU model reset status asserted",
    resetAsserted.resetAsserted)
  check("NPU model reset status not released",
    not resetAsserted.resetReleased)
  let resetReleased = npuResetStatusFromSwResetCodecSub(0'u32)
  check("NPU model reset status released",
    resetReleased.resetReleased)
  check("NPU model reset status not asserted",
    not resetReleased.resetAsserted)
  let idleWrapper = npuWrapperStateFromFlags(false, false)
  check("NPU model wrapper state idle",
    not idleWrapper.started and not idleWrapper.instructionStreamConfigured)
  check("NPU model wrapper state idle blocked", not idleWrapper.runnable)
  let configuredWrapper = npuWrapperStateFromFlags(false, true)
  check("NPU model wrapper state configured",
    configuredWrapper.instructionStreamConfigured)
  check("NPU model wrapper state configured runnable",
    configuredWrapper.runnable)
  let startedWrapper = npuWrapperStateFromFlags(true, true)
  check("NPU model wrapper state started", startedWrapper.started)
  check("NPU model wrapper state started runnable", startedWrapper.runnable)
  let emptyInterrupt = npuInterruptStatusFromIntCfg(0'u32)
  check("NPU model interrupt status clear",
    not emptyInterrupt.interruptPending)
  check("NPU model interrupt clear request absent",
    not emptyInterrupt.clearRequested)
  let pendingInterrupt =
    npuInterruptStatusFromIntCfg(BlaiInterruptStatusMask)
  check("NPU model interrupt status pending",
    pendingInterrupt.interruptPending)
  check("NPU model interrupt pending no clear",
    not pendingInterrupt.clearRequested)
  let clearInterrupt =
    npuInterruptStatusFromIntCfg(BlaiInterruptClearMask)
  check("NPU model interrupt clear requested",
    clearInterrupt.clearRequested)
  check("NPU model interrupt clear no pending",
    not clearInterrupt.interruptPending)
  let intCfgDecode =
    npuIntCfgDecodeFromRaw(
      BlaiStartMask or BlaiStopMask or BlaiResumeMask or
        BlaiInterruptClearMask or BlaiInterruptStatusMask or
        (7'u32 shl BlaiReluNShift))
  check("NPU model int cfg decode commands",
    intCfgDecode.startRequested and intCfgDecode.stopRequested and
      intCfgDecode.resumeRequested)
  check("NPU model int cfg decode interrupt bits",
    intCfgDecode.interruptPending and intCfgDecode.clearRequested)
  checkEq("NPU model int cfg decode relu",
    intCfgDecode.reluN, 7'u32)
  var intCommandPlanInto: NpuIntCfgCommandPlan
  npuPlanIntCfgCommandInto(
    BlaiInterruptStatusMask, npuIntCommandInterruptClear, intCommandPlanInto)
  let intCommandPlan =
    npuPlanIntCfgCommand(BlaiInterruptStatusMask, npuIntCommandInterruptClear)
  check("NPU model int cfg command plan into matches",
    intCommandPlanInto == intCommandPlan)
  check("NPU model int cfg command plan clear",
    intCommandPlan.commandMask == BlaiInterruptClearMask and
      intCommandPlan.encoded ==
        (BlaiInterruptStatusMask or BlaiInterruptClearMask))
  var interruptAckPlanInto: NpuInterruptAckRegisterPlan
  npuInterruptAckRegisterPlanInto(
    BlaiInterruptStatusMask or (7'u32 shl BlaiReluNShift),
    interruptAckPlanInto)
  let interruptAckPlan =
    npuInterruptAckRegisterPlan(
      BlaiInterruptStatusMask or (7'u32 shl BlaiReluNShift))
  check("NPU model interrupt ack plan into matches",
    interruptAckPlanInto == interruptAckPlan)
  check("NPU model interrupt ack plan clear",
    interruptAckPlan.valid and interruptAckPlan.clearRequested and
      (interruptAckPlan.commandPlan.encoded and BlaiInterruptClearMask) != 0'u32)
  check("NPU model interrupt ack plan preserves",
    interruptAckPlan.preservesInterruptStatus and
      interruptAckPlan.preservesReluN)
  check("NPU model int cfg command masks",
    npuIntCfgCommandMask(npuIntCommandStart) == BlaiStartMask and
      npuIntCfgCommandMask(npuIntCommandResume) == BlaiResumeMask and
      npuIntCfgCommandMask(npuIntCommandStop) == BlaiStopMask)
  var startTransitionInto: NpuStartTransitionPlan
  npuPlanStartTransitionInto(
    BlaiInterruptStatusMask, alreadyStarted = false, startTransitionInto)
  let startTransition =
    npuPlanStartTransition(BlaiInterruptStatusMask, alreadyStarted = false)
  check("NPU model start transition plan into matches",
    startTransitionInto == startTransition)
  check("NPU model start transition plan first start",
    startTransition.startsFirstRun and
      startTransition.commandPlan.command == npuIntCommandStart and
      startTransition.commandPlan.encoded ==
        (BlaiInterruptStatusMask or BlaiStartMask))
  let resumeTransition =
    npuPlanStartTransition(BlaiInterruptStatusMask, alreadyStarted = true)
  check("NPU model start transition plan resume",
    resumeTransition.resumesExistingRun and
      resumeTransition.commandPlan.command == npuIntCommandResume and
      resumeTransition.commandPlan.encoded ==
        (BlaiInterruptStatusMask or BlaiResumeMask))
  check("NPU model start transition plan valid",
    startTransition.valid and resumeTransition.valid and
      startTransition.resultingStarted and resumeTransition.resultingStarted)
  var stopTransitionInto: NpuStopTransitionPlan
  npuPlanStopTransitionInto(
    BlaiInterruptStatusMask, alreadyStarted = true, stopTransitionInto)
  let stopTransition =
    npuPlanStopTransition(BlaiInterruptStatusMask, alreadyStarted = true)
  check("NPU model stop transition plan into matches",
    stopTransitionInto == stopTransition)
  check("NPU model stop transition plan command",
    stopTransition.stopsExecution and
      stopTransition.commandPlan.command == npuIntCommandStop and
      stopTransition.commandPlan.encoded ==
        (BlaiInterruptStatusMask or BlaiStopMask))
  check("NPU model stop transition plan clears state",
    stopTransition.valid and stopTransition.initialStarted and
      not stopTransition.resultingStarted)
  let tfCfgDecode = npuTfCfgDecodeFromRaw(BlaiTensorflowEnableMask)
  check("NPU model tf cfg decode enabled",
    tfCfgDecode.tensorflowMode)
  let disabledTfCfg =
    npuTfCfgWithTensorflowMode(0x1234'u32 or BlaiTensorflowEnableMask, false)
  check("NPU model tf cfg compose disabled",
    npuTfCfgDecodeFromRaw(disabledTfCfg).tensorflowMode == false and
      disabledTfCfg == 0x1234'u32)
  let enabledTfCfg =
    npuTfCfgWithTensorflowMode(0x1234'u32, true)
  check("NPU model tf cfg compose enabled",
    npuTfCfgDecodeFromRaw(enabledTfCfg).tensorflowMode and
      (enabledTfCfg and not BlaiTensorflowEnableMask) == 0x1234'u32)
  let imageModeGeneralCfg =
    npuGeneralCfgWithImageInputMode(0x1234_0001'u32, npuInputYuv422)
  check("NPU model general cfg compose image mode",
    npuGeneralCfgDecodeFromRaw(imageModeGeneralCfg).imageInputMode ==
      npuInputYuv422 and
      (imageModeGeneralCfg and BlaiImgiUnsignMask) != 0'u32)
  let unsignedGeneralCfg =
    npuGeneralCfgWithUnsignedInput(0x1234_0100'u32, true)
  check("NPU model general cfg compose unsigned",
    npuGeneralCfgDecodeFromRaw(unsignedGeneralCfg).unsignedInput)
  let reluIntCfg = npuIntCfgWithReluN(BlaiInterruptStatusMask, 0x3F'u32)
  check("NPU model int cfg compose relu clamp",
    npuIntCfgDecodeFromRaw(reluIntCfg).reluN == 0x1F'u32 and
      npuIntCfgDecodeFromRaw(reluIntCfg).interruptPending)
  var imageModeFieldInto: NpuNetParamFieldPlan
  npuPlanImageInputModeFieldInto(
    0x1234_0001'u32, npuInputYuv422, imageModeFieldInto)
  let imageModeField =
    npuPlanImageInputModeField(0x1234_0001'u32, npuInputYuv422)
  check("NPU model net param field image mode into matches",
    imageModeFieldInto == imageModeField)
  check("NPU model net param field image mode valid",
    imageModeField.valid and
      imageModeField.generalDecode.imageInputMode == npuInputYuv422)
  let unsignedField =
    npuPlanUnsignedInputField(0x1234_0100'u32, enabled = true)
  check("NPU model net param field unsigned valid",
    unsignedField.valid and unsignedField.generalDecode.unsignedInput)
  let reluField =
    npuPlanReluNField(BlaiInterruptStatusMask, 0x3F'u32)
  check("NPU model net param field relu clamp",
    reluField.valid and reluField.reluN == 0x1F'u32 and
      reluField.intDecode.interruptPending)
  let tensorflowField =
    npuPlanTensorflowModeField(0x2345'u32, enabled = true)
  check("NPU model net param field tensorflow valid",
    tensorflowField.valid and tensorflowField.tfDecode.tensorflowMode and
      (tensorflowField.encoded and not BlaiTensorflowEnableMask) == 0x2345'u32)
  var netParamPlanInto: NpuNetParamRegisterPlan
  npuPlanNetParamRegistersInto(
    NpuNetParams(unsignedInput: true, reluN: 0x3F'u32,
                 tensorflowMode: true),
    generalCfg = 0x1234_0100'u32,
    intCfg = BlaiInterruptStatusMask,
    tfCfg0 = 0x2345'u32,
    netParamPlanInto)
  let netParamPlan = npuPlanNetParamRegisters(
    NpuNetParams(unsignedInput: true, reluN: 0x3F'u32,
                 tensorflowMode: true),
    generalCfg = 0x1234_0100'u32,
    intCfg = BlaiInterruptStatusMask,
    tfCfg0 = 0x2345'u32)
  check("NPU model net param register plan into matches",
    netParamPlanInto == netParamPlan)
  check("NPU model net param register plan valid",
    netParamPlan.valid)
  check("NPU model net param register plan unsigned",
    netParamPlan.generalDecode.unsignedInput)
  check("NPU model net param register plan relu clamp",
    netParamPlan.intDecode.interruptPending and
      netParamPlan.intDecode.reluN == 0x1F'u32)
  check("NPU model net param register plan tensorflow",
    netParamPlan.tfDecode.tensorflowMode and
      (netParamPlan.tfCfg0 and not BlaiTensorflowEnableMask) == 0x2345'u32)
  let netParamClearPlan = npuPlanNetParamRegisters(
    NpuNetParams(unsignedInput: false, reluN: 3'u32,
                 tensorflowMode: false),
    generalCfg = BlaiImgiUnsignMask or 0x1200'u32,
    intCfg = BlaiInterruptStatusMask or (0x1F'u32 shl BlaiReluNShift),
    tfCfg0 = BlaiTensorflowEnableMask or 0x456'u32)
  check("NPU model net param register plan clear",
    netParamClearPlan.valid and
      not netParamClearPlan.generalDecode.unsignedInput and
      netParamClearPlan.intDecode.interruptPending and
      netParamClearPlan.intDecode.reluN == 3'u32 and
      not netParamClearPlan.tfDecode.tensorflowMode and
      (netParamClearPlan.tfCfg0 and not BlaiTensorflowEnableMask) == 0x456'u32)
  var activationTableBasesInto: NpuActivationTableBasePlan
  npuPlanActivationTableBasesInto(0x12'u32, 0x2A'u32,
    activationTableBasesInto)
  let activationTableBases = npuPlanActivationTableBases(0x12'u32, 0x2A'u32)
  check("NPU model activation table base into matches",
    activationTableBasesInto == activationTableBases)
  check("NPU model activation table base fits",
    activationTableBases.valid and activationTableBases.indexBaseFits and
      activationTableBases.dataBaseFits)
  checkEq("NPU model activation table base encoded",
    activationTableBases.encoded, 0x2A12_0000'u32)
  let generalWithActivationTables =
    npuGeneralCfgWithActivationTableBases(
      BlaiImgiUnsignMask or BlaiImageModeMask or BlaiAxiWriteIdleMask,
      activationTableBases)
  checkEq("NPU model activation table base preserves flags",
    generalWithActivationTables and
      (BlaiImgiUnsignMask or BlaiImageModeMask or BlaiAxiWriteIdleMask),
    BlaiImgiUnsignMask or BlaiImageModeMask or BlaiAxiWriteIdleMask)
  let decodedActivationTables =
    npuActivationTableBasePlanFromGeneralCfg(generalWithActivationTables)
  check("NPU model activation table base decode valid",
    decodedActivationTables.valid)
  checkEq("NPU model activation table index decode",
    decodedActivationTables.indexBase, 0x12'u32)
  checkEq("NPU model activation table data decode",
    decodedActivationTables.dataBase, 0x2A'u32)
  var activationBaseRegisterInto: NpuActivationTableBaseRegisterPlan
  npuActivationTableBaseRegisterPlanInto(
    BlaiImgiUnsignMask or BlaiImageModeMask or BlaiAxiWriteIdleMask,
    activationTableBases, activationBaseRegisterInto)
  let activationBaseRegister =
    npuActivationTableBaseRegisterPlan(
      BlaiImgiUnsignMask or BlaiImageModeMask or BlaiAxiWriteIdleMask,
      activationTableBases)
  check("NPU model activation table base register into matches",
    activationBaseRegisterInto == activationBaseRegister)
  check("NPU model activation table base register valid",
    activationBaseRegister.valid and
      activationBaseRegister.decoded.activationTableIndexBase == 0x12'u32 and
      activationBaseRegister.decoded.activationTableDataBase == 0x2A'u32)
  check("NPU model activation table base register preserves",
    activationBaseRegister.preservesOtherFields and
      (activationBaseRegister.encodedGeneralCfg and
        (BlaiImgiUnsignMask or BlaiImageModeMask or BlaiAxiWriteIdleMask)) ==
        (BlaiImgiUnsignMask or BlaiImageModeMask or BlaiAxiWriteIdleMask))
  let invalidActivationTables =
    npuPlanActivationTableBases(0x40'u32, 0x3F'u32)
  check("NPU model activation table base rejects overflow",
    not invalidActivationTables.valid and
      not invalidActivationTables.indexBaseFits and
      invalidActivationTables.dataBaseFits)
  let knownModeGeneralCfg =
    npuGeneralCfgWithActivationTableBases(
      BlaiImgiUnsignMask or
        (ord(npuInputYuv422).uint32 shl BlaiImageModeShift) or
        BlaiAxiWriteIdleMask,
      activationTableBases)
  let generalCfgDecode =
    npuGeneralCfgDecodeFromRaw(
      knownModeGeneralCfg or BlaiAxiReadIdleMask)
  check("NPU model general cfg decode unsigned",
    generalCfgDecode.unsignedInput)
  check("NPU model general cfg decode image mode known",
    generalCfgDecode.imageInputModeKnown)
  checkEq("NPU model general cfg decode image mode",
    ord(generalCfgDecode.imageInputMode).uint32,
    ord(npuInputYuv422).uint32)
  checkEq("NPU model general cfg decode activation index",
    generalCfgDecode.activationTableIndexBase, 0x12'u32)
  checkEq("NPU model general cfg decode activation data",
    generalCfgDecode.activationTableDataBase, 0x2A'u32)
  check("NPU model general cfg decode idle",
    generalCfgDecode.axiWriteIdle and generalCfgDecode.axiReadIdle and
      not generalCfgDecode.busy)
  let unknownGeneralCfgDecode =
    npuGeneralCfgDecodeFromRaw(BlaiImageModeMask)
  check("NPU model general cfg decode image mode unknown",
    not unknownGeneralCfgDecode.imageInputModeKnown and
      unknownGeneralCfgDecode.imageInputModeBits == 3'u32)
  var activationWordInto: NpuActivationTableWordPlan
  npuPlanActivationTableWordInto(3'u32, 0x11'u8, 0x22'u8, 0x33'u8,
    0x44'u8, activationWordInto)
  let activationWord =
    npuPlanActivationTableWord(3'u32, 0x11'u8, 0x22'u8, 0x33'u8, 0x44'u8)
  check("NPU model activation table word into matches",
    activationWordInto == activationWord)
  check("NPU model activation table word valid",
    activationWord.valid and activationWord.wordIndexFits)
  checkEq("NPU model activation table word first entry",
    activationWord.firstEntryIndex, 12'u32)
  checkEq("NPU model activation table word register offset",
    activationWord.registerOffset, 0x10C'u32)
  checkEq("NPU model activation table word register address",
    activationWord.registerAddress, BlaiActTableBase.uint32 + 12'u32)
  checkEq("NPU model activation table word encoded",
    activationWord.encoded, 0x4433_2211'u32)
  let decodedActivationWord =
    npuActivationTableWordFromRaw(3'u32, activationWord.encoded)
  check("NPU model activation table word decode valid",
    decodedActivationWord.valid)
  checkEq("NPU model activation table word decode entry0",
    decodedActivationWord.entries[0].uint32, 0x11'u32)
  checkEq("NPU model activation table word decode entry3",
    decodedActivationWord.entries[3].uint32, 0x44'u32)
  let invalidActivationWord =
    npuPlanActivationTableWord(64'u32, 0'u8, 1'u8, 2'u8, 3'u8)
  check("NPU model activation table word rejects overflow",
    not invalidActivationWord.valid and not invalidActivationWord.wordIndexFits)
  checkEq("NPU model activation table word overflow offset",
    invalidActivationWord.registerOffset, 0x200'u32)
  let snapshotGeneralCfg =
    npuGeneralCfgWithActivationTableBases(
      BlaiImgiUnsignMask or
        (ord(npuInputYuv422).uint32 shl BlaiImageModeShift) or
        BlaiAxiWriteIdleMask or BlaiAxiReadIdleMask,
      activationTableBases)
  let activationSnapshot =
    npuRegisterSnapshotFromRegs(
      snapshotGeneralCfg,
      (5'u32 shl BlaiReluNShift) or BlaiInterruptStatusMask,
      weightAddr = 0x2200_1000'u32,
      biasAddr = 0x2200_2000'u32,
      instAddr = 0x2200_3000'u32,
      imageAddr = 0x2200_4000'u32,
      imageSeg = 7'u32,
      tfCfg0 = BlaiTensorflowEnableMask)
  check("NPU model register snapshot image mode known",
    activationSnapshot.imageInputModeKnown)
  checkEq("NPU model register snapshot image mode",
    ord(activationSnapshot.imageInputMode).uint32,
    ord(npuInputYuv422).uint32)
  checkEq("NPU model register snapshot activation index",
    activationSnapshot.activationTableIndexBase, 0x12'u32)
  checkEq("NPU model register snapshot activation data",
    activationSnapshot.activationTableDataBase, 0x2A'u32)
  check("NPU model register snapshot int commands",
    not activationSnapshot.startRequested and
      not activationSnapshot.stopRequested and
      not activationSnapshot.resumeRequested)
  check("NPU model register snapshot interrupt pending",
    activationSnapshot.interruptPending)
  checkEq("NPU model register snapshot relu decode",
    activationSnapshot.reluN, 5'u32)
  check("NPU model register snapshot tensorflow decode",
    activationSnapshot.tensorflowMode)
  check("NPU model register snapshot not busy",
    not activationSnapshot.busy)
  let unknownImageSnapshot =
    npuRegisterSnapshotFromRegs(
      BlaiImageModeMask, 0'u32, 0'u32, 0'u32, 0'u32, 0'u32, 0'u32, 0'u32)
  check("NPU model register snapshot image mode unknown",
    not unknownImageSnapshot.imageInputModeKnown and
      unknownImageSnapshot.imageInputModeBits == 3'u32)

  var instructionStreamPlanInto: NpuInstructionStreamRegisterPlan
  npuPlanInstructionStreamRegistersInto(
    instAddr = 0x2204_1000'u32,
    weightAddr = 0'u32,
    biasAddr = 0'u32,
    instructionStreamPlanInto)
  let instructionStreamPlan = npuPlanInstructionStreamRegisters(
    instAddr = 0x2204_1000'u32,
    weightAddr = 0'u32,
    biasAddr = 0'u32)
  check("NPU model instruction stream register plan into matches",
    instructionStreamPlanInto == instructionStreamPlan)
  check("NPU model instruction stream register plan configured",
    instructionStreamPlan.streamConfigured and
      instructionStreamPlan.instAddr == 0x2204_1000'u32)
  check("NPU model instruction stream register plan zero buffers",
    instructionStreamPlan.weightAddr == 0'u32 and
      instructionStreamPlan.biasAddr == 0'u32)
  let emptyInstructionStreamPlan =
    npuPlanInstructionStreamRegisters(0'u32, 0x2204_2000'u32, 0x2204_3000'u32)
  check("NPU model instruction stream register plan empty stream",
    not emptyInstructionStreamPlan.streamConfigured and
      emptyInstructionStreamPlan.weightAddr == 0x2204_2000'u32 and
      emptyInstructionStreamPlan.biasAddr == 0x2204_3000'u32)

  var layerBufferPlanInto: NpuLayerBufferRegisterPlan
  npuPlanLayerBufferRegistersInto(
    NpuLayerBuffers(
      instAddr: 0x2204_1000'u32,
      weightAddr: 0'u32,
      biasAddr: 0x2204_3000'u32),
    layerBufferPlanInto)
  let layerBufferPlan =
    npuPlanLayerBufferRegisters(
      NpuLayerBuffers(
        instAddr: 0x2204_1000'u32,
        weightAddr: 0'u32,
        biasAddr: 0x2204_3000'u32))
  check("NPU model layer buffer register plan into matches",
    layerBufferPlanInto == layerBufferPlan)
  check("NPU model layer buffer register plan optional writes",
    layerBufferPlan.writeInstAddr and not layerBufferPlan.writeWeightAddr and
      layerBufferPlan.writeBiasAddr)
  check("NPU model layer buffer register plan stream configured",
    layerBufferPlan.marksStreamConfigured and layerBufferPlan.anyWrite)
  let emptyLayerBufferPlan = npuPlanLayerBufferRegisters(NpuLayerBuffers())
  check("NPU model layer buffer register plan preserves empty",
    not emptyLayerBufferPlan.anyWrite and
      not emptyLayerBufferPlan.marksStreamConfigured)

  var inputBufferPlanInto: NpuInputBufferRegisterPlan
  npuPlanInputBufferRegistersInto(
    bufferAddr = 0x2204_4000'u32, segmentCount = 11'u32,
    inputBufferPlanInto)
  let inputBufferPlan =
    npuPlanInputBufferRegisters(
      bufferAddr = 0x2204_4000'u32, segmentCount = 11'u32)
  check("NPU model input buffer register plan into matches",
    inputBufferPlanInto == inputBufferPlan)
  check("NPU model input buffer register plan writes",
    inputBufferPlan.writeInputBuffer and
      inputBufferPlan.inputBufferAddr == 0x2204_4000'u32 and
      inputBufferPlan.segmentCount == 11'u32)

  var launchPlanInto: NpuLaunchRegisterPlan
  npuPlanLaunchRegistersInto(
    NpuLayerBuffers(
      instAddr: 0x2204_1000'u32,
      weightAddr: 0'u32,
      biasAddr: 0x2204_3000'u32),
    inputBufferAddr = 0x2204_4000'u32,
    segmentCount = 11'u32,
    launchPlanInto)
  let launchPlan = npuPlanLaunchRegisters(
    NpuLayerBuffers(
      instAddr: 0x2204_1000'u32,
      weightAddr: 0'u32,
      biasAddr: 0x2204_3000'u32),
    inputBufferAddr = 0x2204_4000'u32,
    segmentCount = 11'u32)
  check("NPU model launch register plan into matches",
    launchPlanInto == launchPlan)
  check("NPU model launch register plan optional writes",
    launchPlan.writeInstAddr and not launchPlan.writeWeightAddr and
      launchPlan.writeBiasAddr)
  check("NPU model launch register plan input write",
    launchPlan.writeInputBuffer and launchPlan.inputBufferAddr == 0x2204_4000'u32 and
      launchPlan.segmentCount == 11'u32)
  let emptyLaunchPlan =
    npuPlanLaunchRegisters(
      NpuLayerBuffers(), inputBufferAddr = 0'u32, segmentCount = 0'u32)
  check("NPU model launch register plan preserves empty layer",
    not emptyLaunchPlan.anyLayerBufferWrite and emptyLaunchPlan.writeInputBuffer)

  var layerConfigRegisterPlanInto: NpuLayerConfigRegisterPlan
  let firstLayerConfig = npuPlanLayerConfig(
    NpuLayerBuffers(instAddr: 0x2204_1000'u32),
    inputBufferAddr = 0x2204_4000'u32,
    patchSize = 11'u32,
    firstLayer = true)
  npuPlanLayerConfigRegistersInto(
    firstLayerConfig, layerConfigRegisterPlanInto)
  let firstLayerRegisterPlan =
    npuPlanLayerConfigRegisters(firstLayerConfig)
  check("NPU model layer config register plan into matches",
    layerConfigRegisterPlanInto == firstLayerRegisterPlan)
  check("NPU model layer config register plan first layer",
    firstLayerRegisterPlan.valid and
      firstLayerRegisterPlan.firstLayerPreservesUnsignedInput and
      not firstLayerRegisterPlan.resetUnsignedInput)
  check("NPU model layer config register plan launch",
    firstLayerRegisterPlan.launch.writeInstAddr and
      firstLayerRegisterPlan.launch.writeInputBuffer and
      firstLayerRegisterPlan.launch.segmentCount == 11'u32)
  let nextLayerRegisterPlan =
    npuPlanLayerConfigRegisters(
      npuPlanLayerConfig(
        NpuLayerBuffers(weightAddr: 0x2204_2000'u32),
        inputBufferAddr = 0x2204_5000'u32,
        patchSize = 13'u32,
        firstLayer = false))
  check("NPU model layer config register plan reset unsigned",
    nextLayerRegisterPlan.valid and nextLayerRegisterPlan.resetUnsignedInput and
      nextLayerRegisterPlan.launch.writeWeightAddr)

  let legacyConvPlan = npuPlanConvLayerCompatibility(
    inputAddr = 0x2204_1000'u32,
    outputAddr = 0x2204_2000'u32,
    weightAddr = 0x2204_3000'u32,
    biasAddr = 0x2204_4000'u32,
    inputW = 8, inputH = 8, inputC = 1,
    outputC = 1,
    kernelW = 3, kernelH = 3,
    strideW = 1, strideH = 1,
    padW = 1, padH = 1)
  checkEq("NPU model conv facade first block stream",
    ord(legacyConvPlan.firstBlock).uint32,
    ord(npuConvCompatibilityInstructionStream).uint32)
  check("NPU model conv facade dimensions representable",
    legacyConvPlan.nonzeroDimensions and legacyConvPlan.squareKernel and
      legacyConvPlan.squareStride and legacyConvPlan.squarePadding and
      legacyConvPlan.descriptorDimensionsRepresentable and
      legacyConvPlan.status == npuConvRequiresInstructionStream)
  check("NPU model conv facade output plan only",
    legacyConvPlan.hasOutputBuffer and legacyConvPlan.outputBufferPlanOnly and
      legacyConvPlan.planOnlyAddressCount == 1'u32)
  checkEq("NPU model conv facade register address count",
    legacyConvPlan.registerBackedAddressCount, 3)
  npuConfigureInstructionStream(
    instAddr = 0x2204_5000'u32,
    weightAddr = 0x2204_6000'u32,
    biasAddr = 0x2204_7000'u32)
  let configuredStreamWrapper = npuWrapperState()
  let configuredStreamReadiness =
    npuLayerRunReadiness(npuInstructionStreamConfigured(), timeout = 23)
  let legacyConvApply = npuConfigureConvLayerResult(
    inputAddr = 0x2204_1000'u32,
    outputAddr = 0x2204_2000'u32,
    weightAddr = 0x2204_3000'u32,
    biasAddr = 0x2204_4000'u32,
    inputW = 8, inputH = 8, inputC = 1,
    outputC = 1,
    kernelW = 3, kernelH = 3,
    strideW = 1, strideH = 1,
    padW = 1, padH = 1)
  let clearedStreamWrapper = npuWrapperState()
  let clearedStreamReadiness =
    npuLayerRunReadiness(npuInstructionStreamConfigured(), timeout = 27)
  check("NPU model conv facade apply address",
    legacyConvApply.addressConfigurable)
  check("NPU model conv facade apply layer buffers",
    legacyConvApply.layerBuffersApplied)
  check("NPU model conv facade apply input",
    legacyConvApply.inputBufferApplied)
  check("NPU model conv facade apply output plan only",
    legacyConvApply.outputBufferPlanOnly and
      not legacyConvApply.outputBufferApplied)
  check("NPU model conv facade apply stream cleared",
    legacyConvApply.instructionStreamCleared and
    not npuInstructionStreamConfigured())
  checkEq("NPU model conv facade apply first block",
    ord(legacyConvApply.firstBlock).uint32,
    ord(npuConvCompatibilityInstructionStream).uint32)
  let legacyConvEvidence =
    npuConvCompatibilityEvidence(legacyConvPlan, legacyConvApply)
  check("NPU model conv facade evidence", legacyConvEvidence.valid)
  check("NPU model conv facade evidence plan address",
    legacyConvEvidence.planAddressConfigurable)
  check("NPU model conv facade evidence apply address",
    legacyConvEvidence.applyAddressConfigurable)
  check("NPU model conv facade evidence register addresses",
    legacyConvEvidence.registerBackedAddresses)
  check("NPU model conv facade evidence output plan only",
    legacyConvEvidence.outputPlanOnly)
  check("NPU model conv facade evidence dimensions",
    legacyConvEvidence.dimensionsRepresentable)
  check("NPU model conv facade evidence stream required",
    legacyConvEvidence.instructionStreamRequired)
  check("NPU model conv facade evidence not runnable",
    legacyConvEvidence.notDirectlyRunnable)
  check("NPU model conv facade evidence stream cleared",
    legacyConvEvidence.streamStateCleared)
  check("NPU model conv facade evidence apply matches",
    legacyConvEvidence.applyMatchesPlan)
  check("NPU model conv facade evidence boundary",
    legacyConvEvidence.boundaryMatchesRecoveredHardware)
  let emptyLegacyConvPlan = npuPlanConvLayerCompatibility(
    inputAddr = 0'u32,
    outputAddr = 0'u32,
    weightAddr = 0'u32,
    biasAddr = 0'u32,
    inputW = 8, inputH = 8, inputC = 1,
    outputC = 1,
    kernelW = 3, kernelH = 3,
    strideW = 1, strideH = 1,
    padW = 1, padH = 1)
  check("NPU model conv facade empty address blocked",
    not emptyLegacyConvPlan.addressConfigurable and
    not emptyLegacyConvPlan.directlyRunnable and
    emptyLegacyConvPlan.planOnlyAddressCount == 0'u32)
  checkEq("NPU model conv facade first block address",
    ord(emptyLegacyConvPlan.firstBlock).uint32,
    ord(npuConvCompatibilityAddressSubset).uint32)
  var emptyLegacyConvApply: NpuConvCompatibilityApplyResult
  npuApplyConvLayerCompatibilityInto(emptyLegacyConvPlan, emptyLegacyConvApply)
  check("NPU model conv facade empty apply skipped",
    not emptyLegacyConvApply.applied)
  checkEq("NPU model conv facade empty apply first block",
    ord(emptyLegacyConvApply.firstBlock).uint32,
    ord(npuConvCompatibilityAddressSubset).uint32)
  let invalidLegacyConvPlan = npuPlanConvLayerCompatibility(
    inputAddr = 0x2204_1000'u32,
    outputAddr = 0x2204_2000'u32,
    weightAddr = 0x2204_3000'u32,
    biasAddr = 0x2204_4000'u32,
    inputW = 8, inputH = 8, inputC = 1,
    outputC = 1,
    kernelW = 3, kernelH = 5,
    strideW = 1, strideH = 2,
    padW = 1, padH = 0)
  check("NPU model conv facade invalid dimensions classified",
    invalidLegacyConvPlan.addressConfigurable and
      invalidLegacyConvPlan.nonzeroDimensions and
      not invalidLegacyConvPlan.squareKernel and
      not invalidLegacyConvPlan.squareStride and
      not invalidLegacyConvPlan.squarePadding and
      not invalidLegacyConvPlan.descriptorDimensionsRepresentable and
      invalidLegacyConvPlan.status == npuConvInvalidDimensions)
  checkEq("NPU model conv facade invalid first block",
    ord(invalidLegacyConvPlan.firstBlock).uint32,
    ord(npuConvCompatibilityDimensions).uint32)

  let blockedLayerRunReadiness =
    npuLayerRunReadiness(false, timeout = 19)
  checkEq("NPU model layer run readiness timeout",
    blockedLayerRunReadiness.timeout, 19)
  checkEq("NPU model layer run readiness blocked",
    ord(blockedLayerRunReadiness.firstBlock).uint32,
    ord(npuLayerRunInstructionStream).uint32)
  let runnableLayerRunReadiness =
    npuLayerRunReadiness(true, timeout = 23)
  check("NPU model layer run readiness runnable",
    runnableLayerRunReadiness.runnable)
  checkEq("NPU model layer run readiness unblocked",
    ord(runnableLayerRunReadiness.firstBlock).uint32,
    ord(npuLayerRunNoBlock).uint32)
  npuConfigureConvLayer(
    inputAddr = 0'u32,
    outputAddr = 0'u32,
    weightAddr = 0'u32,
    biasAddr = 0'u32,
    inputW = 1, inputH = 1, inputC = 1,
    outputC = 1,
    kernelW = 1, kernelH = 1,
    strideW = 1, strideH = 1,
    padW = 0, padH = 0)
  let blockedLayerRun = npuRunLayerResult(timeout = 29)
  checkEq("NPU model layer run result first block",
    ord(blockedLayerRun.firstBlock).uint32,
    ord(npuLayerRunInstructionStream).uint32)
  check("NPU model layer run result not started",
    not blockedLayerRun.started)
  checkEq("NPU model layer run result status",
    blockedLayerRun.status.uint32, npuUnsupported.uint32)
  let streamGuardEvidence =
    npuInstructionStreamGuardEvidence(
      configuredStreamWrapper, configuredStreamReadiness,
      clearedStreamWrapper, clearedStreamReadiness,
      legacyConvApply, blockedLayerRun)
  check("NPU model instruction stream guard evidence",
    streamGuardEvidence.valid)
  check("NPU model instruction stream guard configured state",
    streamGuardEvidence.configuredStateCaptured)
  check("NPU model instruction stream guard configured runnable",
    streamGuardEvidence.configuredWrapperRunnable and
      streamGuardEvidence.configuredReadinessRunnable)
  check("NPU model instruction stream guard configured first block",
    streamGuardEvidence.configuredReadinessFirstBlockClean)
  check("NPU model instruction stream guard configured timeout",
    streamGuardEvidence.configuredReadinessTimeoutCaptured)
  check("NPU model instruction stream guard configured match",
    streamGuardEvidence.configuredReadinessMatchesState)
  check("NPU model instruction stream guard facade cleared",
    streamGuardEvidence.facadeClearedStream)
  check("NPU model instruction stream guard cleared timeout",
    streamGuardEvidence.clearedReadinessTimeoutCaptured)
  check("NPU model instruction stream guard cleared blocked",
    streamGuardEvidence.clearedWrapperBlocked and
      streamGuardEvidence.clearedReadinessBlocked)
  check("NPU model instruction stream guard invalidated stream",
    streamGuardEvidence.facadeInvalidatedConfiguredStream)
  check("NPU model instruction stream guard run blocked",
    streamGuardEvidence.blockedRunNotStarted and
      streamGuardEvidence.blockedRunUnsupported)
  check("NPU model instruction stream guard wait plan",
    streamGuardEvidence.blockedRunWaitPlanNotConfigured)
  check("NPU model instruction stream guard boundary",
    streamGuardEvidence.guardMatchesRecoveredHardware)

  let busyStatus = npuBusyStatusFromGeneralCfg(0'u32)
  check("NPU model busy status write active", not busyStatus.axiWriteIdle)
  check("NPU model busy status read active", not busyStatus.axiReadIdle)
  check("NPU model busy status busy", busyStatus.busy)
  let idleStatus =
    npuBusyStatusFromGeneralCfg(BlaiAxiWriteIdleMask or BlaiAxiReadIdleMask)
  check("NPU model busy status write idle", idleStatus.axiWriteIdle)
  check("NPU model busy status read idle", idleStatus.axiReadIdle)
  check("NPU model busy status idle", not idleStatus.busy)

  let unsupportedCompletion = npuWaitForCompletion(
    npuPlanCompletionWait(timeout = 3, configured = false))
  check("NPU model configured wait unsupported",
    unsupportedCompletion.statusDecision.unsupported)
  checkEq("NPU model configured wait timeout",
    unsupportedCompletion.timeout, 3)
  check("NPU model configured wait clear",
    unsupportedCompletion.clearOnComplete)
  check("NPU model configured wait clock",
    unsupportedCompletion.disableClockOnExit)
  check("NPU model configured wait not started",
    not unsupportedCompletion.started)
  let unsupportedClockExit = blaiNpuClockExitEvidence(unsupportedCompletion)
  check("NPU model configured wait clock exit evidence",
    unsupportedClockExit.valid)
  checkEq("NPU model configured wait clock exit path",
    ord(unsupportedClockExit.path).uint32,
    ord(blaiNpuClockExitUnsupportedNoStart).uint32)
  check("NPU model configured wait clock exit no start",
    unsupportedClockExit.noStartNoClockChange)
  checkEq("NPU model configured wait status",
    unsupportedCompletion.status.uint32, npuUnsupported.uint32)

  let blockedCompletion = blaiPlanForwardNpuCompletionWait(
    BlaiForwardNpuRunPlan(), timeout = 29)
  let blockedRun = blaiExecuteForwardNpuRun(
    BlaiForwardNpuRunPlan(), blockedCompletion)
  check("NPU model configured run blocked", not blockedRun.runnable)
  check("NPU model configured run incomplete", not blockedRun.completed)
  checkEq("NPU model configured run wait timeout",
    blockedRun.waitPlan.timeout, 29)
  checkEq("NPU model configured run SDK lock",
    ord(blockedRun.runtimeOwnership.sdkExecutionLock).uint32,
    ord(blaiNpuRuntimeLockSdkMutex).uint32)
  checkEq("NPU model configured run active lock",
    ord(blockedRun.runtimeOwnership.activeExecutionLock).uint32,
    ord(blaiNpuRuntimeLockBareMetalSingleThread).uint32)
  check("NPU model configured run stop policy",
    blockedRun.runtimeOwnership.forwardRunStopsAfterInference)
  check("NPU model configured run not stopped", not blockedRun.stopped)
  let blockedStopAfterInference = blaiNpuStopAfterInferenceEvidence(blockedRun)
  check("NPU model configured run stop evidence",
    blockedStopAfterInference.valid)
  checkEq("NPU model configured run stop path",
    ord(blockedStopAfterInference.path).uint32,
    ord(blaiNpuStopAfterInferenceNoStart).uint32)
  check("NPU model configured run stop no start",
    blockedStopAfterInference.noStartNoStop)
  let blockedPostCompletionCache =
    blaiNpuPostCompletionCacheEvidence(BlaiForwardNpuRunPlan(), blockedRun)
  check("NPU model configured run post-completion cache evidence",
    blockedPostCompletionCache.valid)
  checkEq("NPU model configured run post-completion cache path",
    ord(blockedPostCompletionCache.path).uint32,
    ord(blaiNpuPostCompletionCacheNoStart).uint32)
  check("NPU model configured run post-completion cache no start",
    blockedPostCompletionCache.noStartNoCache)
  checkEq("NPU model configured run status",
    blockedRun.status.uint32, npuUnsupported.uint32)

  var invalidLayers = [
    BlaiCpuInstLayer64(npuOn: 1, layerType: ord(blaiConvolutional).int32)]
  let invalidResources = BlaiForwardModelResourcePlan(supported: true)
  let invalidWorkspace = BlaiForwardModelWorkspacePlan()
  let invalidExecution = blaiExecuteForwardModelConfigured(
    invalidLayers, invalidResources, invalidWorkspace, timeout = 31)
  check("NPU model configured invalid blocked", not invalidExecution.runnable)
  check("NPU model configured invalid incomplete",
    not invalidExecution.allCompleted)
  check("NPU model configured invalid storage",
    invalidExecution.layerStorageFits)
  checkEq("NPU model configured invalid attempted",
    invalidExecution.attemptedLayerCount, 0)
  check("NPU model configured invalid no first failure",
    not invalidExecution.firstFailedExecutionCaptured)

  var invalidStates = [
    BlaiCpuParsedLayerState(active: true, index: 0, layer: invalidLayers[0])]
  let invalidStateExecution = blaiExecuteForwardModelConfigured(
    invalidStates, invalidResources, invalidWorkspace, timeout = 37)
  check("NPU model configured state blocked",
    not invalidStateExecution.runnable)
  check("NPU model configured state incomplete",
    not invalidStateExecution.allCompleted)
  check("NPU model configured state storage",
    invalidStateExecution.layerStorageFits)
  checkEq("NPU model configured state attempted",
    invalidStateExecution.attemptedLayerCount, 0)
  check("NPU model configured state no first failure",
    not invalidStateExecution.firstFailedExecutionCaptured)

proc checkCacheAndCompletionPlans() =
  let unsupportedStatus = blaiNpuCompletionStatusResult(
    configured = false, interruptObserved = false)
  let timeoutStatus = blaiNpuCompletionStatusResult(
    configured = true, interruptObserved = false)
  let okStatus = blaiNpuCompletionStatusResult(
    configured = true, interruptObserved = true)
  check("NPU model completion unsupported", unsupportedStatus.unsupported)
  check("NPU model completion timeout", timeoutStatus.timedOut)
  check("NPU model completion ok", okStatus.completed)
  checkEq("NPU model completion ok status",
    okStatus.status.uint32, npuOk.uint32)
  let runtimeOwnership = blaiNpuRuntimeOwnershipPlan()
  check("NPU model runtime creates interrupt semaphore",
    runtimeOwnership.initCreatesInterruptSemaphore)
  check("NPU model runtime creates execution mutex",
    runtimeOwnership.initCreatesExecutionMutex)
  checkEq("NPU model runtime SDK interrupt semaphore",
    ord(runtimeOwnership.sdkInterruptWait).uint32,
    ord(blaiNpuRuntimeWaitSdkCountingSemaphore).uint32)
  checkEq("NPU model runtime active polling",
    ord(runtimeOwnership.activeInterruptWait).uint32,
    ord(blaiNpuRuntimeWaitBareMetalPolling).uint32)
  check("NPU model runtime lock release",
    runtimeOwnership.forwardRunReleasesExecutionLock)

  let initPlanForInterrupt = npuPlanInitConfig(
    NpuLayerBuffers(), inputBufferAddr = 0x2204_1000'u32, patchSize = 1'u32,
    netParams = NpuNetParams(tensorflowMode: true))
  var initRegisterPlanInto: NpuInitConfigRegisterPlan
  npuPlanInitConfigRegistersInto(
    initPlanForInterrupt,
    generalCfg = 0x1200'u32,
    intCfg = BlaiInterruptStatusMask,
    tfCfg0 = 0x456'u32,
    initRegisterPlanInto)
  let initRegisterPlan =
    npuPlanInitConfigRegisters(
      initPlanForInterrupt,
      generalCfg = 0x1200'u32,
      intCfg = BlaiInterruptStatusMask,
      tfCfg0 = 0x456'u32)
  check("NPU model init register plan into matches",
    initRegisterPlanInto == initRegisterPlan)
  check("NPU model init register plan launch",
    initRegisterPlan.valid and initRegisterPlan.launch.writeInputBuffer and
      initRegisterPlan.launch.inputBufferAddr == 0x2204_1000'u32)
  check("NPU model init register plan net params",
    initRegisterPlan.netParams.valid and
      initRegisterPlan.netParams.intDecode.interruptPending and
      initRegisterPlan.netParams.tfDecode.tensorflowMode)
  check("NPU model init register plan interrupt deferred",
    initRegisterPlan.interruptRequested and initRegisterPlan.interruptDeferred)
  let interruptBinding = npuInterruptBindingReadiness(
    initPlanForInterrupt.interrupt, runtimeOwnership)
  let interruptLineOwnership =
    npuInterruptLineOwnership(initPlanForInterrupt.interrupt)
  let interruptGlbRouteMap =
    npuInterruptGlbRouteMap(initPlanForInterrupt.interrupt)
  let mmAggregatePending =
    npuMmAggregateInterruptSnapshotFromRaw(
      0b101'u32, 0b001'u32, 0x8000_0000'u32, 0'u32)
  let mmAggregateMasked =
    npuMmAggregateInterruptSnapshotFromRaw(0x0000_00F0'u32, 0x0000_00F0'u32,
      0'u32, 0'u32)
  let mmAggregateNone =
    npuMmAggregateInterruptSnapshotFromRaw(0'u32, 0'u32, 0'u32, 0'u32)
  var mmAggregateCatalogInto: NpuMmAggregateSubrouteCatalogEvidence
  npuMmAggregateSubrouteCatalogEvidenceInto(mmAggregateCatalogInto)
  let mmAggregateCatalog = npuMmAggregateSubrouteCatalogEvidence()
  let mmAggregateRouteEvidence =
    npuMmAggregateInterruptRouteEvidence(interruptGlbRouteMap,
      mmAggregatePending)
  let interruptCorePolicy =
    npuInterruptCoreBindingPolicy(initPlanForInterrupt.interrupt, runtimeOwnership)
  check("NPU model interrupt binding requested",
    interruptBinding.requested and interruptBinding.enableRequested)
  check("NPU model interrupt binding irq",
    interruptBinding.irqMatchesSdk)
  check("NPU model interrupt binding priority",
    interruptBinding.priorityMatchesSdk)
  check("NPU model interrupt line D0 APU",
    interruptLineOwnership.matchesD0ApuLine and
      interruptBinding.d0ApuLineCandidate)
  check("NPU model interrupt line SDK CNN",
    interruptLineOwnership.sdkCnnLineKnown)
  check("NPU model interrupt line E907 APU",
    interruptLineOwnership.matchesE907ApuLine)
  check("NPU model interrupt line M0 APU excluded",
    interruptLineOwnership.m0ApuLineExcluded)
  check("NPU model interrupt line GLB I2C1 alias",
    interruptLineOwnership.glbMcuSourceAliasesI2c1)
  check("NPU model interrupt line M0 alias",
    interruptLineOwnership.aliasesM0I2c1Line and interruptBinding.m0LineConflict)
  check("NPU model interrupt line M0 unsafe",
    not interruptLineOwnership.m0BindingSafe and not interruptBinding.m0BindingSafe)
  check("NPU model interrupt line blocked",
    interruptLineOwnership.bindingBlocked)
  check("NPU model interrupt GLB route evidence",
    interruptGlbRouteMap.valid)
  check("NPU model interrupt GLB route SDK source",
    interruptGlbRouteMap.sdkCnnOffset and
      interruptGlbRouteMap.sourceOffset == NpuCnnIrqOffset)
  check("NPU model interrupt GLB route MCU aggregate",
    interruptGlbRouteMap.mcuMmAggregateAvailable and
      interruptGlbRouteMap.mcuMmAggregateSource == NpuGlbMcuMmIrqAllSource)
  check("NPU model interrupt GLB route M0 alias",
    interruptGlbRouteMap.mcuSourceAliasesI2c1)
  check("NPU model interrupt GLB route DSP reserved",
    interruptGlbRouteMap.dspSourceIsReserved39)
  check("NPU model interrupt GLB route demux required",
    interruptGlbRouteMap.requiresMmAggregateDemux)
  check("NPU model interrupt GLB route direct unsafe",
    interruptGlbRouteMap.m0DirectBindingUnsafe)
  check("NPU model interrupt GLB route polling",
    interruptGlbRouteMap.pollingRequired)
  check("NPU model interrupt MM aggregate catalog into matches",
    mmAggregateCatalogInto == mmAggregateCatalog)
  check("NPU model interrupt MM aggregate catalog banks",
    mmAggregateCatalog.valid and mmAggregateCatalog.stdBank0Known and
      not mmAggregateCatalog.stdBank1Known and
      mmAggregateCatalog.e907Bank0Known and mmAggregateCatalog.e907Bank1Known)
  check("NPU model interrupt MM aggregate catalog raw bitmaps",
    mmAggregateCatalog.rawBitmapBanksKnown and
      mmAggregateCatalog.bitmapWidth == NpuMmAggregateRawBitmapWidth)
  check("NPU model interrupt MM aggregate catalog no named subroute",
    mmAggregateCatalog.noNamedNpuSubroute and
      not mmAggregateCatalog.namedCnnSubrouteKnown and
      not mmAggregateCatalog.namedNpuSubrouteKnown and
      not mmAggregateCatalog.namedApuSubrouteKnown)
  check("NPU model interrupt MM aggregate raw decode",
    mmAggregatePending.valid and mmAggregatePending.status0 == 0b101'u32 and
      mmAggregatePending.status1 == 0x8000_0000'u32)
  check("NPU model interrupt MM aggregate pending",
    mmAggregatePending.anyRawStatus and mmAggregatePending.anyUnmaskedPending and
      mmAggregatePending.unmaskedStatus0 == 0b100'u32 and
      mmAggregatePending.unmaskedStatus1 == 0x8000_0000'u32 and
      mmAggregatePending.pendingClass == npuMmAggregatePendingUnmasked)
  check("NPU model interrupt MM aggregate masked",
    mmAggregateMasked.valid and mmAggregateMasked.allRawStatusMasked and
      not mmAggregateMasked.anyUnmaskedPending and
      mmAggregateMasked.maskedStatus0 == 0x0000_00F0'u32 and
      mmAggregateMasked.pendingClass == npuMmAggregatePendingMaskedOnly)
  check("NPU model interrupt MM aggregate none",
    mmAggregateNone.valid and not mmAggregateNone.anyRawStatus and
      not mmAggregateNone.anyUnmaskedPending and
      mmAggregateNone.pendingClass == npuMmAggregatePendingNone)
  check("NPU model interrupt MM aggregate clear plan",
    mmAggregatePending.clearWriteOne and mmAggregatePending.clear0 == 0b101'u32 and
      mmAggregatePending.clear1 == 0x8000_0000'u32)
  var mmAggregateClearPlanInto: NpuMmAggregateInterruptClearPlan
  npuMmAggregateInterruptClearPlanInto(
    mmAggregatePending, mmAggregateClearPlanInto)
  let mmAggregateClearPlan =
    npuMmAggregateInterruptClearPlan(mmAggregatePending)
  check("NPU model interrupt MM aggregate clear plan into matches",
    mmAggregateClearPlanInto == mmAggregateClearPlan)
  check("NPU model interrupt MM aggregate clear plan writes",
    mmAggregateClearPlan.valid and mmAggregateClearPlan.write0 and
      mmAggregateClearPlan.write1 and mmAggregateClearPlan.anyClear)
  check("NPU model interrupt MM aggregate clear plan preserves masks",
    mmAggregateClearPlan.preservesMask and
      mmAggregateClearPlan.clear0 == mmAggregatePending.status0 and
      mmAggregateClearPlan.clear1 == mmAggregatePending.status1)
  let mmAggregateEmptyClearPlan =
    npuMmAggregateInterruptClearPlan(mmAggregateNone)
  check("NPU model interrupt MM aggregate clear plan empty",
    mmAggregateEmptyClearPlan.valid and not mmAggregateEmptyClearPlan.anyClear and
      not mmAggregateEmptyClearPlan.write0 and not mmAggregateEmptyClearPlan.write1)
  check("NPU model interrupt MM aggregate route evidence",
    mmAggregateRouteEvidence.valid and
      mmAggregateRouteEvidence.aggregateSourceAvailable)
  check("NPU model interrupt MM aggregate route catalog",
    mmAggregateRouteEvidence.catalogValid and
      mmAggregateRouteEvidence.rawBitmapBanksKnown and
      mmAggregateRouteEvidence.noNamedNpuSubroute)
  check("NPU model interrupt MM aggregate demux unknown",
    mmAggregateRouteEvidence.subrouteUnknown and
      not mmAggregateRouteEvidence.subrouteBitKnown)
  check("NPU model interrupt MM aggregate polling preserved",
    mmAggregateRouteEvidence.pollingPreserved and
      mmAggregateRouteEvidence.directBindingUnsafe)
  check("NPU model interrupt core policy",
    interruptCorePolicy.valid and interruptBinding.corePolicy.valid)
  checkEq("NPU model interrupt core policy decision",
    ord(interruptCorePolicy.decision).uint32,
    ord(npuInterruptCoreBindingM0PollingRequired).uint32)
  check("NPU model interrupt core policy evidence",
    interruptCorePolicy.decisionMatchesEvidence and
      interruptBinding.corePolicy.decisionMatchesEvidence)
  check("NPU model interrupt core policy M0 polling",
    interruptCorePolicy.m0PollingRequired)
  check("NPU model interrupt core policy D0 candidate",
    interruptCorePolicy.d0BindingCandidate)
  check("NPU model interrupt core policy not active ready",
    not interruptCorePolicy.activeCoreReady)
  let interruptOperationPlan =
    npuInterruptBindingOperationPlan(
      initPlanForInterrupt.interrupt, interruptCorePolicy)
  check("NPU model interrupt operation plan",
    interruptOperationPlan.valid and interruptBinding.operationPlan.valid)
  checkEq("NPU model interrupt operation count",
    interruptOperationPlan.operationCount.uint32, 0)
  check("NPU model interrupt operations suppressed",
    interruptOperationPlan.activeOperationsSuppressed)
  check("NPU model interrupt operation polling preserved",
    interruptOperationPlan.m0PollingPreserved)
  check("NPU model interrupt operation D0 preserved",
    interruptOperationPlan.d0CandidatePreserved)
  check("NPU model interrupt no handler operation",
    not interruptOperationPlan.registerHandlerPlanned)
  check("NPU model interrupt no enable operation",
    not interruptOperationPlan.enableIrqPlanned)
  let interruptApiContract =
    npuInterruptBindingApiContract(
      initPlanForInterrupt.interrupt, interruptOperationPlan)
  check("NPU model interrupt API contract",
    interruptApiContract.valid and interruptBinding.apiContract.valid)
  check("NPU model interrupt API contract irq",
    interruptApiContract.irqMatchesPlan)
  check("NPU model interrupt API contract priority",
    interruptApiContract.priorityMatchesPlan and
      interruptApiContract.sdkPriorityMatches)
  check("NPU model interrupt API contract sequence",
    interruptApiContract.apiSequenceComplete)
  check("NPU model interrupt API contract deferred",
    interruptApiContract.activeCallsDeferred)
  check("NPU model interrupt API contract polling",
    interruptApiContract.m0PollingPreserved)
  check("NPU model interrupt API contract D0",
    interruptApiContract.d0RoutePreserved)
  check("NPU model interrupt binding polling",
    interruptBinding.activeWaitIsPolling)
  check("NPU model interrupt binding not ready",
    not interruptBinding.bindingVerified and not interruptBinding.ready)

  let waitPlan = npuPlanCompletionWait(
    timeout = 17, configured = true,
    clearOnComplete = false, disableClockOnExit = false)
  check("NPU model completion plan configured", waitPlan.configured)
  checkEq("NPU model completion plan timeout", waitPlan.timeout, 17)
  check("NPU model completion plan clear", not waitPlan.clearOnComplete)
  check("NPU model completion plan clock", not waitPlan.disableClockOnExit)
  var waitResult: BlaiNpuCompletionWaitResult
  npuWaitForCompletionInto(
    npuPlanCompletionWait(
      timeout = 17, configured = false,
      clearOnComplete = false, disableClockOnExit = false),
    waitResult)
  checkEq("NPU model completion result timeout", waitResult.timeout, 17)
  check("NPU model completion result clear", not waitResult.clearOnComplete)
  check("NPU model completion result clock", not waitResult.disableClockOnExit)
  let unsupportedPollingWait = blaiNpuPollingWaitEvidence(waitResult)
  check("NPU model completion polling wait evidence", unsupportedPollingWait.valid)
  checkEq("NPU model completion polling wait terminal",
    ord(unsupportedPollingWait.terminal).uint32,
    ord(blaiNpuPollingWaitUnsupported).uint32)
  check("NPU model completion polling wait unsupported",
    unsupportedPollingWait.statusUnsupported)
  check("NPU model completion polling wait not started",
    not unsupportedPollingWait.started)
  checkEq("NPU model completion polling wait no polls",
    unsupportedPollingWait.actualPolls, 0)
  check("NPU model completion polling wait trace",
    unsupportedPollingWait.pollTraceValid)
  check("NPU model completion polling wait terminal evidence",
    unsupportedPollingWait.terminalMatchesStatus)
  let unsupportedCompletionSideEffects =
    blaiNpuCompletionSideEffectEvidence(waitResult)
  check("NPU model completion side effects evidence",
    unsupportedCompletionSideEffects.valid)
  checkEq("NPU model completion side effects path",
    ord(unsupportedCompletionSideEffects.path).uint32,
    ord(blaiNpuCompletionSideEffectUnsupported).uint32)
  check("NPU model completion side effects no start",
    not unsupportedCompletionSideEffects.started)
  check("NPU model completion side effects no side effects",
    unsupportedCompletionSideEffects.noSideEffects)
  check("NPU model completion side effects status",
    unsupportedCompletionSideEffects.pathMatchesStatus)

  var transferLayer = BlaiCpuInstLayer64(
    layerType: ord(blaiRouteConv).int32,
    w: 2,
    h: 3,
    c: 3,
    cn: [5'i32, 7, 0, 0, 0, 0, 0],
    n: 3,
    inputNum: 3,
    outW: 2,
    outH: 2,
    outC: 5,
    midOut: 1,
    npuOn: 1,
    dramPatchSize: 64,
    dramIn: [1'i32, 2, 3, 0, 0, 0, 0, 0],
    dramOut: [4'i32, 0, 0, 0, 0, 0, 0, 0],
    dramMidOut: 6)
  let runPlan = blaiPlanForwardNpuRun(
    transferLayer, layerIndex = 0, dataBufferBytes = 474,
    instAddr = 0x2203_0000'u32, dataBufferAddr = 0x2204_0000'u32,
    weightAddr = 0x2205_0000'u32, biasAddr = 0x2205_0100'u32)
  check("NPU model cache run configurable", runPlan.configurable)
  checkEq("NPU model cache range count", runPlan.cacheRangeCount, 5)
  checkEq("NPU model cache clean offset", runPlan.cacheRanges[0].offset, 64)
  checkEq("NPU model cache output offset", runPlan.cacheRanges[3].offset, 256)

  let firstAddress = blaiCacheRangeAddress(
    runPlan.layerConfig.inputBufferAddr, runPlan.cacheRanges[0])
  let outputAddress = blaiCacheRangeAddress(
    runPlan.layerConfig.inputBufferAddr, runPlan.cacheRanges[3])
  let overflowAddress = blaiCacheRangeAddress(
    0xFFFF_FF00'u32, runPlan.cacheRanges[4])
  check("NPU model cache first fits", firstAddress.fits)
  checkEq("NPU model cache first address", firstAddress.address, 0x2204_0040'u32)
  checkEq("NPU model cache first bytes", firstAddress.bytes, 24)
  check("NPU model cache output fits", outputAddress.fits)
  checkEq("NPU model cache output address",
    outputAddress.address, 0x2204_0100'u32)
  check("NPU model cache overflow blocked", not overflowAddress.fits)

  let forwardWait = blaiPlanForwardNpuCompletionWait(
    runPlan, timeout = 23, clearOnComplete = false,
    disableClockOnExit = false)
  check("NPU model cache wait configured", forwardWait.configured)
  checkEq("NPU model cache wait timeout", forwardWait.timeout, 23)
  check("NPU model cache wait clear", not forwardWait.clearOnComplete)
  check("NPU model cache wait clock", not forwardWait.disableClockOnExit)

  let cacheApply = blaiApplyForwardNpuCacheRanges(runPlan)
  check("NPU model cache apply runnable", cacheApply.runnable)
  check("NPU model cache apply configurable", cacheApply.configurable)
  check("NPU model cache apply fits", cacheApply.fits)
  checkEq("NPU model cache apply count", cacheApply.cacheRangeCount, 5)
  checkEq("NPU model cache apply last address",
    cacheApply.cacheRanges[4].address, 0x2204_0180'u32)

  var overflowRun = runPlan
  overflowRun.layerConfig.inputBufferAddr = 0xFFFF_FF00'u32
  overflowRun.cacheRangeCount = 1
  overflowRun.cacheRanges[0] = BlaiCacheRange(
    active: true,
    operation: blaiCacheClean,
    offset: 0x200'u32,
    bytes: 0x200'u32)
  let overflowExecution = blaiExecuteForwardNpuRun(
    overflowRun,
    blaiPlanForwardNpuCompletionWait(overflowRun, timeout = 3))
  check("NPU model cache execute overflow blocked",
    not overflowExecution.completed)
  check("NPU model cache execute overflow fit",
    not overflowExecution.cache.fits)
  check("NPU model cache execute overflow not started",
    not overflowExecution.started)
  checkEq("NPU model cache execute overflow status",
    overflowExecution.status.uint32, npuBusy.uint32)
  checkEq("NPU model cache execute overflow count",
    overflowExecution.cache.cacheRangeCount, 1)

proc checkForwardWeightMaterialization() =
  var sourceWeights: array[512, int32]
  for i in 0 ..< sourceWeights.len:
    sourceWeights[i] = i.int32
  var biasSource: array[8, int32] = [10'i32, 20, 30, 40, 50, 60, 70, 80]
  var layer = BlaiCpuInstLayer64(
    layerType: ord(blaiConvolutional).int32,
    c: 4,
    outC: 3,
    size: 3,
    tfInput2Offset: -7,
    dramNWeight: 144,
    dramNBias: 3,
    npuOn: 1,
    dspOn: 1,
    dramPatchSize: 64)
  var weightBuf: array[144, uint8]
  var biasBuf: array[3, int32]
  var noTemporaryWeights: array[0, int32]
  let materialized = blaiMaterializeForwardNpuWeights(
    layer, layerIndex = 0, useTflite = true,
    weightBuf = weightBuf, biasBuf = biasBuf,
    weightsIn = sourceWeights, biasesIn = biasSource,
    temporaryWeights = noTemporaryWeights, pack = 2)
  check("NPU model forward weights runnable", materialized.runnable)
  check("NPU model forward weights layer", materialized.weightLayer)
  check("NPU model forward weights materialized", materialized.materialized)
  checkEq("NPU model forward weights cursor",
    materialized.weights.weightCursor, 144)
  checkEq("NPU model forward weights byte", weightBuf[36].uint32, 18)
  checkEq("NPU model forward weights bias", biasBuf[2].uint32, 30)

  var routeLayer = layer
  routeLayer.layerType = ord(blaiRoute).int32
  let routeWeights = blaiMaterializeForwardNpuWeights(
    routeLayer, layerIndex = 0, useTflite = true,
    weightBuf = weightBuf, biasBuf = biasBuf,
    weightsIn = sourceWeights, biasesIn = biasSource,
    temporaryWeights = noTemporaryWeights, pack = 2)
  check("NPU model forward route runnable", routeWeights.runnable)
  check("NPU model forward route skips weights", not routeWeights.weightLayer)
  check("NPU model forward route materialized", routeWeights.materialized)

  let weightWorkspaceResources =
    blaiPlanForwardModelResources([layer, routeLayer], useTflite = true)
  let weightWorkspace = blaiPlanForwardModelWorkspace(
    weightWorkspaceResources, baseAddress = 0x220A_0000'u32)
  var directWeightWorkspaceBytes: array[2048, uint8]
  var directWeightInput: array[144, uint8]
  for i in 0 ..< directWeightInput.len:
    directWeightInput[i] = i.uint8
  let directBiasInput = [10'i32, 20, 30]
  let directWeightStore = blaiStoreForwardWeightsInWorkspace(
    weightWorkspace, directWeightInput, 144, directBiasInput, 3,
    directWeightWorkspaceBytes)
  checkEq("NPU model weight workspace first block none",
    ord(directWeightStore.firstBlock).uint32,
    ord(blaiForwardWeightWorkspaceNoBlock).uint32)
  checkEq("NPU model weight workspace readiness first block none",
    ord(directWeightStore.readiness.firstBlock).uint32,
    ord(blaiForwardWeightWorkspaceNoBlock).uint32)
  let shortDirectWeightStore = blaiStoreForwardWeightsInWorkspace(
    weightWorkspace, directWeightInput, 145, directBiasInput, 3,
    directWeightWorkspaceBytes)
  checkEq("NPU model weight workspace first block weight",
    ord(shortDirectWeightStore.firstBlock).uint32,
    ord(blaiForwardWeightWorkspaceWeight).uint32)
  let shortDirectBiasStore = blaiStoreForwardWeightsInWorkspace(
    weightWorkspace, directWeightInput, 144, directBiasInput, 4,
    directWeightWorkspaceBytes)
  checkEq("NPU model weight workspace first block bias",
    ord(shortDirectBiasStore.firstBlock).uint32,
    ord(blaiForwardWeightWorkspaceBias).uint32)
  var shortDirectWeightWorkspaceBytes: array[32, uint8]
  let shortDirectBufferStore = blaiStoreForwardWeightsInWorkspace(
    weightWorkspace, directWeightInput, 144, directBiasInput, 3,
    shortDirectWeightWorkspaceBytes)
  checkEq("NPU model weight workspace first block buffer",
    ord(shortDirectBufferStore.firstBlock).uint32,
    ord(blaiForwardWeightWorkspaceBuffer).uint32)
  var cpuWeightBytes: array[144, uint8]
  for i in 0 ..< cpuWeightBytes.len:
    cpuWeightBytes[i] = i.uint8
  let cpuBiasBytes = [
    10'u8, 0, 0, 0,
    20'u8, 0, 0, 0,
    30'u8, 0, 0, 0]
  var decodedWorkspaceWeights: array[144, int32]
  var decodedWorkspaceBiases: array[3, int32]
  var npuWorkspaceWeights: array[144, uint8]
  var npuWorkspaceBiases: array[3, int32]
  var fullWorkspaceBytes: array[2048, uint8]
  let fullWeightWorkspace = blaiMaterializeForwardModelWeightsInWorkspace(
    [layer, routeLayer], useTflite = true,
    workspace = weightWorkspace,
    cpuWeightBytes = cpuWeightBytes,
    cpuBiasBytes = cpuBiasBytes,
    decodedWeights = decodedWorkspaceWeights,
    decodedBiases = decodedWorkspaceBiases,
    npuWeightBytes = npuWorkspaceWeights,
    npuBiases = npuWorkspaceBiases,
    temporaryWeights = noTemporaryWeights,
    workspaceBytes = fullWorkspaceBytes,
    pack = 2)
  check("NPU model weight workspace all stored",
    fullWeightWorkspace.allStored)
  check("NPU model weight workspace stream consumed",
    fullWeightWorkspace.streamsConsumed)
  check("NPU model weight workspace storage stream consumed",
    fullWeightWorkspace.storage.streamsConsumed)
  checkEq("NPU model weight workspace expected weight cursor",
    fullWeightWorkspace.expectedWeightCursor.byteOffset, 108)
  checkEq("NPU model weight workspace actual weight cursor",
    fullWeightWorkspace.storage.actualWeightCursor.byteOffset, 108)
  checkEq("NPU model weight workspace expected bias cursor",
    fullWeightWorkspace.expectedBiasCursor.byteOffset, 12)
  checkEq("NPU model weight workspace actual bias cursor",
    fullWeightWorkspace.storage.actualBiasCursor.byteOffset, 12)
  var shortWorkspaceBytes: array[32, uint8]
  let blockedWeightWorkspace = blaiMaterializeForwardModelWeightsInWorkspace(
    [layer, routeLayer], useTflite = true,
    workspace = weightWorkspace,
    cpuWeightBytes = cpuWeightBytes,
    cpuBiasBytes = cpuBiasBytes,
    decodedWeights = decodedWorkspaceWeights,
    decodedBiases = decodedWorkspaceBiases,
    npuWeightBytes = npuWorkspaceWeights,
    npuBiases = npuWorkspaceBiases,
    temporaryWeights = noTemporaryWeights,
    workspaceBytes = shortWorkspaceBytes,
    pack = 2)
  check("NPU model weight workspace blocked",
    not blockedWeightWorkspace.allStored)
  check("NPU model weight workspace blocked captured",
    blockedWeightWorkspace.firstBlockedLayerCaptured)
  check("NPU model weight workspace blocked readiness",
    not blockedWeightWorkspace.firstBlockedLayerReadiness.workspaceStored)
  check("NPU model weight workspace blocked stream not consumed",
    not blockedWeightWorkspace.streamsConsumed)
  checkEq("NPU model weight workspace blocked model first block layer",
    ord(blockedWeightWorkspace.firstBlock).uint32,
    ord(blaiForwardModelWeightWorkspaceLayer).uint32)
  checkEq("NPU model weight workspace blocked first block storage",
    ord(blockedWeightWorkspace.firstBlockedLayerFirstBlock).uint32,
    ord(blaiForwardLayerWeightWorkspaceStorage).uint32)
  checkEq("NPU model weight workspace blocked workspace first block buffer",
    ord(blockedWeightWorkspace.firstBlockedWorkspaceFirstBlock).uint32,
    ord(blaiForwardWeightWorkspaceBuffer).uint32)

  var blockedLayer = layer
  blockedLayer.npuOn = 0
  let blockedWeights = blaiMaterializeForwardNpuWeights(
    blockedLayer, layerIndex = 1, useTflite = true,
    weightBuf = weightBuf, biasBuf = biasBuf,
    weightsIn = sourceWeights, biasesIn = biasSource,
    temporaryWeights = noTemporaryWeights, pack = 2)
  check("NPU model forward weights blocked", not blockedWeights.runnable)
  check("NPU model forward weights blocked materialized",
    not blockedWeights.materialized)

  var tempLayer = layer
  tempLayer.c = 8
  tempLayer.outC = 8
  tempLayer.groups = 4
  tempLayer.dramNWeight = 288
  tempLayer.dramNBias = 8
  var tempWeightBuf: array[288, uint8]
  var tempBiasBuf: array[8, int32]
  var tempScratch: array[288, int32]
  let tempMaterialized = blaiMaterializeForwardNpuWeights(
    tempLayer, layerIndex = 0, useTflite = true,
    weightBuf = tempWeightBuf, biasBuf = tempBiasBuf,
    weightsIn = sourceWeights, biasesIn = biasSource,
    temporaryWeights = tempScratch, pack = 4)
  check("NPU model forward temp materialized",
    tempMaterialized.materialized)
  checkEq("NPU model forward temp cursor",
    tempMaterialized.weights.weightCursor, 288)
  checkEq("NPU model forward temp byte", tempWeightBuf[10].uint32, 36)
  checkEq("NPU model forward temp bias", tempBiasBuf[7].uint32, 80)

proc checkSdkHelperConvShapePlan() =
  var layer = BlaiCpuInstLayer64(
    layerType: ord(blaiConvolutional).int32,
    activation: ord(blaiActRelu).int32,
    npuOn: 1,
    dspOn: 1,
    w: 8,
    h: 8,
    c: 8,
    outW: 8,
    outH: 8,
    outC: 8,
    n: 1,
    inputNum: 1,
    size: 3,
    groups: 1,
    stride: 1,
    dilation: 1,
    fdata: 7,
    fweight: 6,
    fbias: 3,
    fout: 2,
    dramNWeight: 576,
    dramNBias: 8,
    halt: 1)
  var ctrl: BlaiPsramCtrl
  var stream: array[BlaiInstructionScratchSize div BlaiInstructionSize,
                    BlaiInstruction]
  let encoded = blaiEncodeCpuLayerWithAllocator(
    layer, ctrl, stream, useTflite = false, descriptorHalt = true)
  let states = [BlaiCpuParsedLayerState(active: true, index: 1, layer: layer)]
  let resources = blaiPlanForwardModelResources(states, useTflite = false)
  let transferPlan = blaiPlanForwardNpu(
    layer, layerIndex = states[0].index, dataBufferBytes = resources.dataBufferBytes)
  let runPlan = blaiPlanForwardNpuRun(
    layer, layerIndex = states[0].index,
    dataBufferBytes = resources.dataBufferBytes,
    instAddr = 0x2203_0000'u32,
    dataBufferAddr = 0x2204_0000'u32,
    weightAddr = 0x2205_0000'u32,
    biasAddr = 0x2205_0400'u32)
  let weightPlan = blaiPlanNpuWeightLoad(layer, useTflite = false)
  var sourceWeights: array[576, int32]
  for i in 0 ..< sourceWeights.len:
    sourceWeights[i] = (i and 0x7F).int32
  var sourceBiases: array[8, int32] = [10'i32, 20, 30, 40, 50, 60, 70, 80]
  var npuWeightBytes: array[576, uint8]
  var npuBiases: array[8, int32]
  var temporaryWeights: array[0, int32]
  let materialized = blaiMaterializeForwardNpuWeights(
    layer, layerIndex = states[0].index, useTflite = false,
    weightBuf = npuWeightBytes, biasBuf = npuBiases,
    weightsIn = sourceWeights, biasesIn = sourceBiases,
    temporaryWeights = temporaryWeights)
  let convSinglePatchPlan = blaiPlanSinglePatchMemAlloc(BlaiCpuInstLayer64(
    layerType: ord(blaiConvolutional).int32,
    w: 4,
    h: 4,
    c: 3,
    outW: 2,
    outH: 2,
    outC: 5,
    midOut: 1))
  let softmaxSinglePatchPlan = blaiPlanSinglePatchMemAlloc(BlaiCpuInstLayer64(
    layerType: ord(blaiSoftmax).int32,
    w: 4,
    h: 4,
    c: 3,
    outW: 4,
    outH: 1,
    outC: 5,
    midOut: 1))

  check("NPU model SDK helper conv allocator",
    encoded.encoded and encoded.allocation.fits and
      encoded.allocation.branch == blaiMemAllocSinglePatch and
      encoded.allocation.single.psramPatchSize == 512 and
      ctrl.psramPatchSize == 512 and layer.dramPatchSize == 512)
  check("NPU model SDK helper conv allocator mid inactive",
    encoded.allocation.single.midSource == blaiMemAllocSinglePatchMidNone and
      encoded.allocation.single.midInputElements == 0 and
      encoded.allocation.single.psramMidPatchCount == 0)
  check("NPU model SDK helper conv allocator mid source",
    convSinglePatchPlan.midSource == blaiMemAllocSinglePatchMidInputChannels and
      convSinglePatchPlan.midInputElements == 48 and
      convSinglePatchPlan.psramPatchSize == 32 and
      convSinglePatchPlan.psramMidPatchCount == 2)
  check("NPU model SDK helper softmax allocator mid source",
    softmaxSinglePatchPlan.midSource ==
      blaiMemAllocSinglePatchMidSoftmaxOutputChannels and
      softmaxSinglePatchPlan.midInputElements == 80 and
      softmaxSinglePatchPlan.psramPatchSize == 32 and
      softmaxSinglePatchPlan.psramMidPatchCount == 3)
  check("NPU model SDK helper conv stream",
    layer.instCnt == 1 and blaiLayerCount(stream) == 1 and
      decodeBlaiLayer(stream[0]).activation == ord(blaiActRelu).uint32)
  check("NPU model SDK helper conv resources",
    resources.supported and resources.instructionBytes == BlaiInstructionScratchSize and
      resources.dataBufferBytes == 1024 and resources.weightBufferBytes == 576 and
      resources.biasBufferBytes == 32 and resources.temporaryWeightElements == 0 and
      resources.cpuWeightStreamBytes == 576 and resources.cpuBiasStreamBytes == 8)
  check("NPU model SDK helper conv transfer",
    transferPlan.runnable and transferPlan.bufferFits and
      transferPlan.inputs[0].bytes == 512 and
      transferPlan.output.output.bytes == 512 and
      not transferPlan.firstLayer)
  check("NPU model SDK helper conv weight plan",
    weightPlan.active and weightPlan.supportedKernel and
      weightPlan.kernel == blaiNpuWeightKernel3x3 and
      weightPlan.effectiveInputChannels == 8 and
      weightPlan.outputChannels == 8 and weightPlan.biasPack == 4 and
      blaiNpuPackedWeightBytes(layer, useTflite = false) == 576)
  check("NPU model SDK helper conv weights materialized",
    materialized.runnable and materialized.weightLayer and
      materialized.materialized and materialized.weights.weightCursor == 576 and
      materialized.weights.biasCursor == 8 and npuBiases[7] == 80)
  check("NPU model SDK helper conv run config",
    runPlan.configurable and runPlan.layerConfig.patchSize == 512 and
      not runPlan.layerConfig.firstLayer and
      runPlan.layerConfig.resetUnsignedInput)

proc checkForwardTensorIo() =
  let layer = BlaiCpuInstLayer64(
    layerType: ord(blaiConvolutional).int32,
    npuOn: 1,
    w: 1,
    h: 1,
    c: 1,
    outW: 1,
    outH: 1,
    outC: 1,
    dramIn: [0'i32, 0, 0, 0, 0, 0, 0, 0],
    dramOut: [1'i32, 0, 0, 0, 0, 0, 0, 0],
    dramPatchSize: 4)
  let plan = blaiPlanForwardNpu(layer, layerIndex = 0, dataBufferBytes = 8)
  var input = [7'u8]
  var dataBuffer: array[8, uint8]
  let staged = blaiStageForwardNpuInput(plan, 0, input, dataBuffer)
  check("NPU model tensor input runnable", staged.readiness.runnable)
  check("NPU model tensor input active", staged.readiness.active)
  check("NPU model tensor input ready", staged.readiness.ready)
  check("NPU model tensor input moved", staged.moved)
  checkEq("NPU model tensor input buffer required",
    staged.bufferFit.requiredBytes, 8)
  checkEq("NPU model tensor input tensor required",
    staged.tensorFit.requiredBytes, 1)
  checkEq("NPU model tensor input move required",
    staged.move.bufferFit.requiredBytes, 1)
  checkEq("NPU model tensor input value", dataBuffer[0].uint32, 7)

  var shortInput: array[0, uint8]
  let shortTensor = blaiStageForwardNpuInput(plan, 0, shortInput, dataBuffer)
  check("NPU model tensor input short blocked",
    not shortTensor.readiness.tensorFits and not shortTensor.moved)
  checkEq("NPU model tensor input short required",
    shortTensor.tensorFit.requiredBytes, 1)
  checkEq("NPU model tensor input short provided",
    shortTensor.tensorFit.tensorBytes, 0)

  var shortBuffer: array[7, uint8]
  let shortData = blaiStageForwardNpuInput(plan, 0, input, shortBuffer)
  check("NPU model tensor input buffer blocked",
    not shortData.readiness.bufferFits and not shortData.moved)
  checkEq("NPU model tensor input buffer required short",
    shortData.bufferFit.requiredBytes, 8)

  dataBuffer[4] = 33
  var output: array[1, uint8]
  let loaded = blaiLoadForwardNpuOutput(
    plan, blaiForwardPrimaryOutput, dataBuffer, output)
  check("NPU model tensor output runnable", loaded.readiness.runnable)
  check("NPU model tensor output active", loaded.readiness.active)
  check("NPU model tensor output ready", loaded.readiness.ready)
  check("NPU model tensor output moved", loaded.moved)
  checkEq("NPU model tensor output buffer required",
    loaded.bufferFit.requiredBytes, 8)
  checkEq("NPU model tensor output tensor required",
    loaded.tensorFit.requiredBytes, 1)
  checkEq("NPU model tensor output move required",
    loaded.move.bufferFit.requiredBytes, 8)
  checkEq("NPU model tensor output value", output[0].uint32, 33)

  var workspaceBytes: array[24, uint8]
  let workspaceBinding = BlaiForwardWorkspaceBufferBinding(
    bound: true,
    workspace: BlaiForwardModelWorkspacePlan(
      supported: true,
      fits: true,
      data: BlaiForwardModelWorkspaceSegment(
        active: true,
        fits: true,
        offset: 16,
        address: 0x2204_0010'u32,
        bytes: 8)))
  var workspaceStageInto: BlaiForwardWorkspaceTensorIoResult
  blaiStageForwardWorkspaceInputInto(
    workspaceBinding, plan, 0, input, workspaceBytes, workspaceStageInto)
  let workspaceStage = blaiStageForwardWorkspaceInput(
    workspaceBinding, plan, 0, input, workspaceBytes)
  check("NPU model workspace tensor input into equal",
    workspaceStageInto == workspaceStage)
  check("NPU model workspace tensor input moved", workspaceStage.moved)
  checkEq("NPU model workspace tensor input first block",
    ord(workspaceStage.firstBlock).uint32,
    ord(blaiForwardWorkspaceTensorIoNoBlock).uint32)
  checkEq("NPU model workspace tensor input value",
    workspaceBytes[16].uint32, 7)

  workspaceBytes[20] = 44
  var workspaceOutput: array[1, uint8]
  var workspaceOutputInto: BlaiForwardWorkspaceTensorIoResult
  blaiLoadForwardWorkspaceOutputInto(
    workspaceBinding, plan, blaiForwardPrimaryOutput, workspaceBytes,
    workspaceOutput, workspaceOutputInto)
  var workspaceOutputWrapped: array[1, uint8]
  let workspaceOutputLoad = blaiLoadForwardWorkspaceOutput(
    workspaceBinding, plan, blaiForwardPrimaryOutput, workspaceBytes,
    workspaceOutputWrapped)
  check("NPU model workspace tensor output into equal",
    workspaceOutputInto == workspaceOutputLoad)
  check("NPU model workspace tensor output moved", workspaceOutputLoad.moved)
  checkEq("NPU model workspace tensor output first block",
    ord(workspaceOutputLoad.firstBlock).uint32,
    ord(blaiForwardWorkspaceTensorIoNoBlock).uint32)
  checkEq("NPU model workspace tensor output value",
    workspaceOutputWrapped[0].uint32, 44)

  let unboundWorkspace = BlaiForwardWorkspaceBufferBinding()
  let unboundStage = blaiStageForwardWorkspaceInput(
    unboundWorkspace, plan, 0, input, workspaceBytes)
  checkEq("NPU model workspace tensor unbound first block",
    ord(unboundStage.firstBlock).uint32,
    ord(blaiForwardWorkspaceTensorIoBinding).uint32)

  let shortWorkspaceBinding = BlaiForwardWorkspaceBufferBinding(
    bound: true,
    workspace: BlaiForwardModelWorkspacePlan(
      supported: true,
      fits: true,
      data: BlaiForwardModelWorkspaceSegment(
        active: true,
        fits: true,
        offset: 20,
        address: 0x2204_0014'u32,
        bytes: 8)))
  let shortWorkspaceStage = blaiStageForwardWorkspaceInput(
    shortWorkspaceBinding, plan, 0, input, workspaceBytes)
  checkEq("NPU model workspace tensor segment first block",
    ord(shortWorkspaceStage.firstBlock).uint32,
    ord(blaiForwardWorkspaceTensorIoDataSegment).uint32)

  let outputCompare = blaiCompareUint8Outputs([33'u8], output)
  let completedExecution = BlaiForwardModelWorkspaceExecuteResult(
    allCompleted: true,
    completedLayerCount: 1,
    firstBlock: blaiForwardModelWorkspaceExecuteNoBlock)
  let outputValidation = blaiForwardModelOutputValidation(
    completedExecution, loaded, outputCompare)
  check("NPU model output validation valid", outputValidation.valid)
  check("NPU model output validation moved", outputValidation.outputMoved)
  check("NPU model output validation matched", outputValidation.outputMatched)
  checkEq("NPU model output validation completed",
    outputValidation.completedLayerCount, 1)
  checkEq("NPU model output validation slot",
    outputValidation.outputTransfer.slot, 1)
  checkEq("NPU model output validation first block",
    ord(outputValidation.executionFirstBlock).uint32,
    ord(blaiForwardModelWorkspaceExecuteNoBlock).uint32)
  checkEq("NPU model output validation reason none",
    ord(outputValidation.firstBlock).uint32,
    ord(blaiForwardModelOutputValidationNoBlock).uint32)
  checkEq("NPU model output validation compared",
    outputValidation.comparedElements, 1)
  checkEq("NPU model output validation expected elements",
    outputValidation.expectedElements, 1)
  checkEq("NPU model output validation actual elements",
    outputValidation.actualElements, 1)
  check("NPU model output validation length match",
    outputValidation.lengthMatches)
  checkEq("NPU model output validation mismatches",
    outputValidation.mismatchCount, 0)
  checkEq("NPU model output validation compare first mismatch",
    blaiForwardModelOutputFirstMismatch(outputValidation).uint32, high(uint32))
  var outputReadinessInto: BlaiForwardModelOutputValidationReadiness
  blaiForwardModelOutputValidationReadinessInto(
    outputValidation, outputReadinessInto)
  let outputReadiness =
    blaiForwardModelOutputValidationReadiness(outputValidation)
  check("NPU model output validation readiness valid",
    outputReadinessInto == outputReadiness and outputReadiness.valid and
      outputReadiness.executed and outputReadiness.outputMoved and
      outputReadiness.outputMatched and
      outputReadiness.completedLayerCount == 1 and
      outputReadiness.expectedElements == 1 and
      outputReadiness.actualElements == 1 and
      outputReadiness.lengthMatches and
      outputReadiness.comparedElements == 1 and
      outputReadiness.mismatchCount == 0 and
      outputReadiness.firstBlock == blaiForwardModelOutputValidationNoBlock)

  let configuredExecution = BlaiForwardModelExecuteResult(
    runnable: true,
    allCompleted: true,
    layerStorageFits: true,
    attemptedLayerCount: 1,
    completedLayerCount: 1,
    firstBlock: blaiForwardModelExecuteNoBlock)
  let configuredValidation = blaiForwardModelOutputValidation(
    configuredExecution, loaded, outputCompare)
  check("NPU model configured output validation valid",
    configuredValidation.valid)
  check("NPU model configured output validation length match",
    configuredValidation.lengthMatches and
      configuredValidation.expectedElements == 1 and
      configuredValidation.actualElements == 1)
  checkEq("NPU model configured output validation first block",
    ord(configuredValidation.configuredExecutionFirstBlock).uint32,
    ord(blaiForwardModelExecuteNoBlock).uint32)

  var validatedWorkspaceOut: array[1, uint8]
  var validatedWorkspaceInto: BlaiForwardModelOutputValidationResult
  blaiValidateForwardModelOutputInto(
    completedExecution, plan, blaiForwardPrimaryOutput, dataBuffer,
    [33'u8], validatedWorkspaceOut, validatedWorkspaceInto)
  let validatedWorkspace = blaiValidateForwardModelOutput(
    completedExecution, plan, blaiForwardPrimaryOutput, dataBuffer,
    [33'u8], validatedWorkspaceOut)
  check("NPU model output helper into equal",
    validatedWorkspaceInto == validatedWorkspace)
  check("NPU model output helper valid", validatedWorkspace.valid)
  check("NPU model output helper moved", validatedWorkspace.outputMoved)
  checkEq("NPU model output helper compared",
    validatedWorkspace.comparedElements, 1)
  check("NPU model output helper length match",
    validatedWorkspace.lengthMatches and
      validatedWorkspace.expectedElements == 1 and
      validatedWorkspace.actualElements == 1)

  var validatedConfiguredOut: array[1, uint8]
  var validatedConfiguredInto: BlaiForwardModelOutputValidationResult
  blaiValidateForwardModelOutputInto(
    configuredExecution, plan, blaiForwardPrimaryOutput, dataBuffer,
    [33'u8], validatedConfiguredOut, validatedConfiguredInto)
  let validatedConfigured = blaiValidateForwardModelOutput(
    configuredExecution, plan, blaiForwardPrimaryOutput, dataBuffer,
    [33'u8], validatedConfiguredOut)
  check("NPU model configured output helper into equal",
    validatedConfiguredInto == validatedConfigured)
  check("NPU model configured output helper valid", validatedConfigured.valid)
  checkEq("NPU model configured output helper first block",
    ord(validatedConfigured.configuredExecutionFirstBlock).uint32,
    ord(blaiForwardModelExecuteNoBlock).uint32)

  var validatedWorkspaceBoundOut: array[1, uint8]
  var validatedWorkspaceBoundInto:
    BlaiForwardWorkspaceOutputValidationResult
  blaiValidateForwardWorkspaceOutputInto(
    completedExecution, workspaceBinding, plan, blaiForwardPrimaryOutput,
    workspaceBytes, [44'u8], validatedWorkspaceBoundOut,
    validatedWorkspaceBoundInto)
  let validatedWorkspaceBound = blaiValidateForwardWorkspaceOutput(
    completedExecution, workspaceBinding, plan, blaiForwardPrimaryOutput,
    workspaceBytes, [44'u8], validatedWorkspaceBoundOut)
  check("NPU model workspace output helper into equal",
    validatedWorkspaceBoundInto == validatedWorkspaceBound)
  check("NPU model workspace output helper valid",
    validatedWorkspaceBound.valid)
  checkEq("NPU model workspace output helper first block",
    ord(validatedWorkspaceBound.firstBlock).uint32,
    ord(blaiForwardWorkspaceOutputValidationNoBlock).uint32)
  checkEq("NPU model workspace output helper workspace first block",
    ord(validatedWorkspaceBound.workspaceOutputFirstBlock).uint32,
    ord(blaiForwardWorkspaceTensorIoNoBlock).uint32)
  var workspaceOutputReadinessInto:
    BlaiForwardWorkspaceOutputValidationReadiness
  blaiForwardWorkspaceOutputValidationReadinessInto(
    validatedWorkspaceBound, workspaceOutputReadinessInto)
  let workspaceOutputReadiness =
    blaiForwardWorkspaceOutputValidationReadiness(validatedWorkspaceBound)
  check("NPU model workspace output helper readiness valid",
    workspaceOutputReadinessInto == workspaceOutputReadiness and
      workspaceOutputReadiness.valid and
      workspaceOutputReadiness.workspaceOutputMoved and
      workspaceOutputReadiness.validation.valid and
      workspaceOutputReadiness.validation.outputMatched and
      workspaceOutputReadiness.expectedElements == 1 and
      workspaceOutputReadiness.actualElements == 1 and
      workspaceOutputReadiness.lengthMatches and
      workspaceOutputReadiness.comparedElements == 1 and
      workspaceOutputReadiness.mismatchCount == 0 and
      workspaceOutputReadiness.firstBlock ==
        blaiForwardWorkspaceOutputValidationNoBlock)
  check("NPU model workspace output helper readiness blocks",
    workspaceOutputReadiness.workspaceOutputFirstBlock ==
      validatedWorkspaceBound.workspaceOutputFirstBlock and
      workspaceOutputReadiness.validationFirstBlock ==
        validatedWorkspaceBound.validationFirstBlock and
      workspaceOutputReadiness.validation.executionFirstBlock ==
        validatedWorkspaceBound.validation.executionFirstBlock and
      workspaceOutputReadiness.validation.outputReadiness ==
        validatedWorkspaceBound.validation.outputReadiness)

  var validatedConfiguredWorkspaceOut: array[1, uint8]
  let validatedConfiguredWorkspace = blaiValidateForwardWorkspaceOutput(
    configuredExecution, workspaceBinding, plan, blaiForwardPrimaryOutput,
    workspaceBytes, [44'u8], validatedConfiguredWorkspaceOut)
  check("NPU model configured workspace output helper valid",
    validatedConfiguredWorkspace.valid)
  checkEq("NPU model configured workspace output helper first block",
    ord(validatedConfiguredWorkspace.firstBlock).uint32,
    ord(blaiForwardWorkspaceOutputValidationNoBlock).uint32)

  var unboundValidationOut: array[1, uint8]
  let unboundValidation = blaiValidateForwardWorkspaceOutput(
    completedExecution, unboundWorkspace, plan, blaiForwardPrimaryOutput,
    workspaceBytes, [44'u8], unboundValidationOut)
  checkEq("NPU model workspace output helper unbound first block",
    ord(unboundValidation.firstBlock).uint32,
    ord(blaiForwardWorkspaceOutputValidationWorkspaceOutput).uint32)
  checkEq("NPU model workspace output helper unbound workspace block",
    ord(unboundValidation.workspaceOutputFirstBlock).uint32,
    ord(blaiForwardWorkspaceTensorIoBinding).uint32)

  var mismatchWorkspaceOut: array[1, uint8]
  let mismatchWorkspaceValidation = blaiValidateForwardWorkspaceOutput(
    completedExecution, workspaceBinding, plan, blaiForwardPrimaryOutput,
    workspaceBytes, [45'u8], mismatchWorkspaceOut)
  checkEq("NPU model workspace output helper mismatch first block",
    ord(mismatchWorkspaceValidation.firstBlock).uint32,
    ord(blaiForwardWorkspaceOutputValidationCompare).uint32)
  checkEq("NPU model workspace output helper mismatch index",
    blaiForwardWorkspaceOutputFirstMismatch(mismatchWorkspaceValidation).uint32,
    0)
  checkEq("NPU model workspace output helper mismatch expected",
    mismatchWorkspaceValidation.compare.expectedAtFirstMismatch.uint32, 45)
  checkEq("NPU model workspace output helper mismatch actual",
    mismatchWorkspaceValidation.compare.actualAtFirstMismatch.uint32, 44)
  check("NPU model workspace output helper mismatch direct",
    mismatchWorkspaceValidation.firstMismatch == 0 and
      mismatchWorkspaceValidation.expectedPresentAtFirstMismatch and
      mismatchWorkspaceValidation.actualPresentAtFirstMismatch and
      mismatchWorkspaceValidation.expectedElements == 1 and
      mismatchWorkspaceValidation.actualElements == 1 and
      mismatchWorkspaceValidation.lengthMatches and
      mismatchWorkspaceValidation.expectedAtFirstMismatch == 45'u8 and
      mismatchWorkspaceValidation.actualAtFirstMismatch == 44'u8)
  let mismatchWorkspaceReadiness =
    blaiForwardWorkspaceOutputValidationReadiness(mismatchWorkspaceValidation)
  check("NPU model workspace output helper mismatch readiness",
    not mismatchWorkspaceReadiness.valid and
      mismatchWorkspaceReadiness.workspaceOutputMoved and
      mismatchWorkspaceReadiness.validation.outputMatched == false and
      mismatchWorkspaceReadiness.firstBlock ==
        blaiForwardWorkspaceOutputValidationCompare and
      mismatchWorkspaceReadiness.expectedElements == 1 and
      mismatchWorkspaceReadiness.actualElements == 1 and
      mismatchWorkspaceReadiness.lengthMatches and
      mismatchWorkspaceReadiness.firstMismatch == 0 and
      mismatchWorkspaceReadiness.expectedAtFirstMismatch == 45'u8 and
      mismatchWorkspaceReadiness.actualAtFirstMismatch == 44'u8)

  let incompleteValidation = blaiForwardModelOutputValidation(
    BlaiForwardModelWorkspaceExecuteResult(
      allCompleted: false,
      firstBlock: blaiForwardModelWorkspaceExecuteLayerExecution),
    loaded, outputCompare)
  checkEq("NPU model output validation blocked execution",
    ord(incompleteValidation.firstBlock).uint32,
    ord(blaiForwardModelOutputValidationExecution).uint32)

  let incompleteConfiguredValidation = blaiForwardModelOutputValidation(
    BlaiForwardModelExecuteResult(
      runnable: true,
      allCompleted: false,
      layerStorageFits: true,
      failedLayerCount: 1,
      firstBlock: blaiForwardModelExecuteLayerExecution),
    loaded, outputCompare)
  checkEq("NPU model configured output validation blocked execution",
    ord(incompleteConfiguredValidation.firstBlock).uint32,
    ord(blaiForwardModelOutputValidationExecution).uint32)

  var mismatchOutput = output
  mismatchOutput[0] = 34
  let mismatchCompare = blaiCompareUint8Outputs([33'u8], mismatchOutput)
  let mismatchValidation = blaiForwardModelOutputValidation(
    completedExecution, loaded, mismatchCompare)
  checkEq("NPU model output validation blocked compare",
    ord(mismatchValidation.firstBlock).uint32,
    ord(blaiForwardModelOutputValidationCompare).uint32)
  checkEq("NPU model output validation mismatch index",
    blaiForwardModelOutputFirstMismatch(mismatchValidation).uint32, 0)
  checkEq("NPU model output validation mismatch expected",
    mismatchValidation.compare.expectedAtFirstMismatch.uint32, 33)
  checkEq("NPU model output validation mismatch actual",
    mismatchValidation.compare.actualAtFirstMismatch.uint32, 34)
  check("NPU model output validation mismatch direct",
    mismatchValidation.firstMismatch == 0 and
      mismatchValidation.expectedPresentAtFirstMismatch and
      mismatchValidation.actualPresentAtFirstMismatch and
      mismatchValidation.expectedElements == 1 and
      mismatchValidation.actualElements == 1 and
      mismatchValidation.lengthMatches and
      mismatchValidation.expectedAtFirstMismatch == 33'u8 and
      mismatchValidation.actualAtFirstMismatch == 34'u8)
  let mismatchOutputReadiness =
    blaiForwardModelOutputValidationReadiness(mismatchValidation)
  check("NPU model output validation mismatch readiness",
    not mismatchOutputReadiness.valid and mismatchOutputReadiness.executed and
      mismatchOutputReadiness.outputMoved and
      not mismatchOutputReadiness.outputMatched and
      mismatchOutputReadiness.firstBlock ==
        blaiForwardModelOutputValidationCompare and
      mismatchOutputReadiness.expectedElements == 1 and
      mismatchOutputReadiness.actualElements == 1 and
      mismatchOutputReadiness.lengthMatches and
      mismatchOutputReadiness.firstMismatch == 0 and
      mismatchOutputReadiness.expectedAtFirstMismatch == 33'u8 and
      mismatchOutputReadiness.actualAtFirstMismatch == 34'u8)

  var shortOutput: array[0, uint8]
  let shortOutputLoad = blaiLoadForwardNpuOutput(
    plan, blaiForwardPrimaryOutput, dataBuffer, shortOutput)
  check("NPU model tensor output short blocked",
    not shortOutputLoad.readiness.tensorFits and not shortOutputLoad.moved)
  checkEq("NPU model tensor output short required",
    shortOutputLoad.tensorFit.requiredBytes, 1)
  checkEq("NPU model tensor output short provided",
    shortOutputLoad.tensorFit.tensorBytes, 0)
  let readbackValidation = blaiForwardModelOutputValidation(
    completedExecution, shortOutputLoad, outputCompare)
  checkEq("NPU model output validation blocked readback",
    ord(readbackValidation.firstBlock).uint32,
    ord(blaiForwardModelOutputValidationReadback).uint32)

proc readyParsedWorkspaceFixtureValidation():
    BlaiParsedForwardWorkspaceFixtureValidationResult =
  result.binding.bound = true
  result.hardwareAddresses.ready = true
  result.input.moved = true
  result.execution.executable = true
  result.execution.execution.allCompleted = true
  result.output.valid = true
  result.output.validation.outputMatched = true
  result.output.comparedElements = 1
  result.bindingFirstBlock = blaiForwardWorkspaceBufferBindNoBlock
  result.hardwareAddressFirstBlock = blaiForwardWorkspaceHardwareAddressNoBlock
  result.inputFirstBlock = blaiForwardWorkspaceTensorIoNoBlock
  result.executionFirstBlock = blaiParsedForwardModelExecuteNoBlock
  result.workspaceExecutionFirstBlock = blaiForwardModelWorkspaceExecuteNoBlock
  result.outputFirstBlock = blaiForwardWorkspaceOutputValidationNoBlock
  result.firstBlock = blaiParsedForwardWorkspaceFixtureValidationNoBlock
  result.valid = true

proc checkParsedWorkspaceOracleValidationReadiness() =
  let fixture = readyParsedWorkspaceFixtureValidation()

  var tfliteValidation: BlaiTfliteParsedWorkspaceOracleValidationResult
  tfliteValidation.fixture = fixture
  tfliteValidation.referenceExecuted = true
  tfliteValidation.referenceValid = true
  tfliteValidation.fixtureValid = true
  tfliteValidation.outputValid = true
  tfliteValidation.outputMatched = true
  tfliteValidation.referenceFirstBlock = blaiRefTfliteCheckedNoBlock
  tfliteValidation.fixtureFirstBlock =
    blaiParsedForwardWorkspaceFixtureValidationNoBlock
  tfliteValidation.completedLayerCount = 1
  tfliteValidation.comparedElements = 1
  tfliteValidation.mismatchCount = 0
  tfliteValidation.outputFirstBlock =
    blaiForwardWorkspaceOutputValidationNoBlock
  tfliteValidation.firstBlock =
    blaiTfliteParsedWorkspaceOracleValidationNoBlock
  tfliteValidation.valid = true
  var tfliteReadiness: BlaiTfliteParsedWorkspaceOracleValidationReadiness
  blaiTfliteParsedWorkspaceOracleValidationReadinessInto(
    tfliteValidation, tfliteReadiness)
  check("NPU model TFLite workspace oracle readiness valid",
    tfliteReadiness.valid and tfliteReadiness.referenceValid and
      tfliteReadiness.fixtureValid and tfliteReadiness.outputValid and
      tfliteReadiness.outputMatched and tfliteReadiness.fixtureReadiness.valid and
      tfliteReadiness.comparedElements == 1 and
      tfliteReadiness.mismatchCount == 0)
  check("NPU model TFLite workspace oracle output readiness valid",
    tfliteReadiness.outputReadiness.valid and
      tfliteReadiness.outputReadiness.validation.outputMatched and
      tfliteReadiness.outputReadiness.comparedElements == 1 and
      tfliteReadiness.outputReadiness.mismatchCount == 0 and
      tfliteReadiness.outputReadiness.firstBlock ==
        blaiForwardWorkspaceOutputValidationNoBlock)

  var fixedValidation: BlaiFixedParsedWorkspaceOracleValidationResult
  fixedValidation.fixture = fixture
  fixedValidation.referenceExecuted = true
  fixedValidation.referenceValid = true
  fixedValidation.fixtureValid = true
  fixedValidation.outputValid = true
  fixedValidation.outputMatched = true
  fixedValidation.referenceFirstBlock = blaiRefFixedCheckedNoBlock
  fixedValidation.fixtureFirstBlock =
    blaiParsedForwardWorkspaceFixtureValidationNoBlock
  fixedValidation.completedLayerCount = 1
  fixedValidation.comparedElements = 1
  fixedValidation.mismatchCount = 0
  fixedValidation.outputFirstBlock =
    blaiForwardWorkspaceOutputValidationNoBlock
  fixedValidation.firstBlock =
    blaiFixedParsedWorkspaceOracleValidationNoBlock
  fixedValidation.valid = true
  var fixedReadiness: BlaiFixedParsedWorkspaceOracleValidationReadiness
  blaiFixedParsedWorkspaceOracleValidationReadinessInto(
    fixedValidation, fixedReadiness)
  check("NPU model fixed workspace oracle readiness valid",
    fixedReadiness.valid and fixedReadiness.referenceValid and
      fixedReadiness.fixtureValid and fixedReadiness.outputValid and
      fixedReadiness.outputMatched and fixedReadiness.fixtureReadiness.valid and
      fixedReadiness.comparedElements == 1 and
      fixedReadiness.mismatchCount == 0)
  check("NPU model fixed workspace oracle output readiness valid",
    fixedReadiness.outputReadiness.valid and
      fixedReadiness.outputReadiness.validation.outputMatched and
      fixedReadiness.outputReadiness.comparedElements == 1 and
      fixedReadiness.outputReadiness.mismatchCount == 0 and
      fixedReadiness.outputReadiness.firstBlock ==
        blaiForwardWorkspaceOutputValidationNoBlock)

proc checkTflitePadDiagnostics() =
  var output: array[16, uint8]
  let spatial = blaiReferenceTflitePad2d(
    BlaiReferenceTflitePad2d(
      inputW: 2, inputH: 1, inputC: 2,
      leftPadW: 1, rightPadW: 1, leftPadH: 1, rightPadH: 0,
      paddingValue: 9),
    [1'u8, 2, 3, 4],
    output)
  check("NPU model TFLite pad diagnostics spatial",
    spatial.supported and spatial.fits and spatial.inputFits and
      spatial.outputFits and spatial.firstBlock == blaiTflitePadNoBlock)
  checkEq("NPU model TFLite pad diagnostics value", output[10].uint32, 1)

  var channelOutput: array[4, uint8]
  let channel = blaiReferenceTflitePad2d(
    BlaiReferenceTflitePad2d(
      inputW: 1, inputH: 1, inputC: 1,
      leftPadC: 1, rightPadC: 2,
      paddingValue: 7),
    [5'u8],
    channelOutput)
  check("NPU model TFLite pad diagnostics channel block",
    channel.channelPaddingRequested and not channel.supported and
      not channel.fits and
      channel.firstBlock == blaiTflitePadChannelPadding)

  var shortOutput: BlaiReferenceTflitePadResult
  blaiReferenceTflitePadReadinessInto(
    BlaiReferenceTflitePad2d(inputW: 1, inputH: 1, inputC: 1),
    inputLen = 1, outputLen = 0, shortOutput)
  check("NPU model TFLite pad diagnostics output block",
    shortOutput.supported and shortOutput.inputFits and
      not shortOutput.outputFits and
      shortOutput.firstBlock == blaiTflitePadOutputBuffer)

proc checkTfliteTransposeDiagnostics() =
  var output: array[6, uint8]
  let transpose = blaiReferenceTfliteTranspose2d(
    BlaiReferenceTfliteTranspose2d(
      inputW: 3, inputH: 2, inputC: 1, rank: 3,
      hPerm: 1, wPerm: 0, cPerm: 2),
    [1'u8, 2, 3, 4, 5, 6],
    output)
  check("NPU model TFLite transpose diagnostics spatial",
    transpose.fits and transpose.validInputShape and transpose.validRank and
      transpose.validPermutation and transpose.outputShapeValid and
      transpose.inputFits and transpose.outputFits and
      transpose.firstBlock == blaiTfliteTransposeNoBlock)
  checkEq("NPU model TFLite transpose diagnostics value",
    output[1].uint32, 4)

  var duplicateOutput: array[4, uint8]
  let duplicate = blaiReferenceTfliteTranspose2d(
    BlaiReferenceTfliteTranspose2d(
      inputW: 2, inputH: 1, inputC: 2, rank: 3,
      hPerm: 1, wPerm: 1, cPerm: 2),
    [1'u8, 2, 3, 4],
    duplicateOutput)
  check("NPU model TFLite transpose diagnostics permutation block",
    duplicate.validInputShape and duplicate.validRank and
      not duplicate.validPermutation and not duplicate.fits and
      duplicate.firstBlock == blaiTfliteTransposePermutation)

  var shortOutput: BlaiReferenceTfliteTransposeResult
  blaiReferenceTfliteTransposeReadinessInto(
    BlaiReferenceTfliteTranspose2d(
      inputW: 2, inputH: 1, inputC: 2, rank: 3,
      hPerm: 2, wPerm: 1, cPerm: 0),
    inputLen = 4, outputLen = 3, shortOutput)
  check("NPU model TFLite transpose diagnostics output block",
    shortOutput.validInputShape and shortOutput.validRank and
      shortOutput.validPermutation and shortOutput.inputFits and
      not shortOutput.outputFits and
      shortOutput.firstBlock == blaiTfliteTransposeOutputBuffer)

proc checkMaxPoolDiagnostics() =
  var nmsisOutput: array[4, uint8]
  let nmsis = blaiReferenceMaxPool2d(
    BlaiReferenceMaxPool2d(
      inputW: 4, inputH: 4, inputC: 1,
      kernelW: 2, kernelH: 2,
      strideX: 2, strideY: 2,
      activationMin: 0,
      activationMax: 255),
    [1'u8, 2, 3, 4,
     5'u8, 6, 7, 8,
     9'u8, 10, 11, 12,
     13'u8, 14, 15, 16],
    nmsisOutput)
  check("NPU model NMSIS maxpool diagnostics valid",
    nmsis.fits and nmsis.validInputShape and nmsis.validOutputShape and
      nmsis.windowsCovered and nmsis.inputFits and nmsis.outputFits and
      nmsis.firstBlock == blaiMaxPoolNoBlock and
      nmsis.inputElements == 16 and nmsis.requiredOutputElements == 4)
  checkEq("NPU model NMSIS maxpool diagnostics value",
    nmsisOutput[3].uint32, 16)

  var nmsisBadShape: BlaiReferenceMaxPoolResult
  blaiReferenceMaxPoolReadinessInto(
    BlaiReferenceMaxPool2d(
      inputW: 0, inputH: 1, inputC: 1,
      kernelW: 1, kernelH: 1,
      strideX: 1, strideY: 1),
    inputLen = 1, outputLen = 1, nmsisBadShape)
  check("NPU model NMSIS maxpool diagnostics input shape block",
    not nmsisBadShape.validInputShape and
      nmsisBadShape.firstBlock == blaiMaxPoolInputShape)

  var nmsisBadOutput: BlaiReferenceMaxPoolResult
  blaiReferenceMaxPoolReadinessInto(
    BlaiReferenceMaxPool2d(
      inputW: 1, inputH: 1, inputC: 1,
      kernelW: 3, kernelH: 3,
      strideX: 1, strideY: 1),
    inputLen = 1, outputLen = 1, nmsisBadOutput)
  check("NPU model NMSIS maxpool diagnostics output shape block",
    nmsisBadOutput.validInputShape and
      not nmsisBadOutput.validOutputShape and
      nmsisBadOutput.firstBlock == blaiMaxPoolOutputShape)

  var nmsisBadWindow: BlaiReferenceMaxPoolResult
  blaiReferenceMaxPoolReadinessInto(
    BlaiReferenceMaxPool2d(
      inputW: 1, inputH: 1, inputC: 1,
      kernelW: 1, kernelH: 1,
      strideX: 1, strideY: 1,
      paddingX: 2, paddingY: 2),
    inputLen = 1, outputLen = 25, nmsisBadWindow)
  check("NPU model NMSIS maxpool diagnostics window block",
    nmsisBadWindow.validOutputShape and not nmsisBadWindow.windowsCovered and
      nmsisBadWindow.firstBlock == blaiMaxPoolWindowCoverage)

  var nmsisShortInput: BlaiReferenceMaxPoolResult
  blaiReferenceMaxPoolReadinessInto(
    BlaiReferenceMaxPool2d(
      inputW: 2, inputH: 2, inputC: 1,
      kernelW: 1, kernelH: 1,
      strideX: 1, strideY: 1),
    inputLen = 3, outputLen = 4, nmsisShortInput)
  check("NPU model NMSIS maxpool diagnostics input block",
    not nmsisShortInput.inputFits and
      nmsisShortInput.firstBlock == blaiMaxPoolInputBuffer)

  var nmsisShortOutput: BlaiReferenceMaxPoolResult
  blaiReferenceMaxPoolReadinessInto(
    BlaiReferenceMaxPool2d(
      inputW: 2, inputH: 1, inputC: 1,
      kernelW: 1, kernelH: 1,
      strideX: 1, strideY: 1),
    inputLen = 2, outputLen = 1, nmsisShortOutput)
  check("NPU model NMSIS maxpool diagnostics output block",
    nmsisShortOutput.inputFits and not nmsisShortOutput.outputFits and
      nmsisShortOutput.firstBlock == blaiMaxPoolOutputBuffer)

  var fixedOutput: array[9, int8]
  let fixed = blaiReferenceFixedMaxPool2d(
    BlaiReferenceFixedMaxPool2d(
      inputW: 3, inputH: 3, inputC: 1,
      kernelSize: 3, stride: 1, dilation: 1),
    [1'i8, 2, 3, 4, 5, 6, 7, 8, 9],
    fixedOutput)
  check("NPU model fixed maxpool diagnostics valid",
    fixed.fits and fixed.supported and fixed.validInputShape and
      fixed.validStride and fixed.validDilation and fixed.inputFits and
      fixed.outputFits and fixed.firstBlock == blaiFixedMaxPoolNoBlock)
  var fixedEvenOutput: array[4, int8]
  let fixedEven = blaiReferenceFixedMaxPool2d(
    BlaiReferenceFixedMaxPool2d(
      inputW: 2, inputH: 2, inputC: 1,
      kernelSize: 2, stride: 1, dilation: 1),
    [1'i8, 2, 3, 4],
    fixedEvenOutput)
  check("NPU model fixed maxpool diagnostics kernel block",
    not fixedEven.fits and not fixedEven.supported and
      fixedEven.firstBlock == blaiFixedMaxPoolKernel)
  var fixedShort: BlaiReferenceFixedMaxPoolResult
  blaiReferenceFixedMaxPoolReadinessInto(
    BlaiReferenceFixedMaxPool2d(
      inputW: 2, inputH: 2, inputC: 1,
      kernelSize: 1, stride: 1, dilation: 1),
    inputLen = 4, outputLen = 3, fixedShort)
  check("NPU model fixed maxpool diagnostics output block",
    fixedShort.inputFits and not fixedShort.outputFits and
      fixedShort.firstBlock == blaiFixedMaxPoolOutputBuffer)

  var tfliteOutput: array[9, uint8]
  let tflite = blaiReferenceTfliteScalarMaxPool2d(
    BlaiReferenceTfliteScalarMaxPool2d(
      inputW: 3, inputH: 3, inputC: 1,
      kernelSize: 3, stride: 1, dilation: 1,
      outputMultiplier: high(int32),
      activationMin: 0, activationMax: 255),
    [1'u8, 2, 3, 4, 5, 6, 7, 8, 9],
    tfliteOutput)
  check("NPU model TFLite maxpool diagnostics valid",
    tflite.fits and tflite.supported and tflite.validInputShape and
      tflite.validStride and tflite.outputShapeValid and tflite.inputFits and
      tflite.outputFits and
      tflite.firstBlock == blaiTfliteScalarMaxPoolNoBlock)
  var tfliteShort: BlaiReferenceTfliteScalarMaxPoolResult
  blaiReferenceTfliteScalarMaxPoolReadinessInto(
    BlaiReferenceTfliteScalarMaxPool2d(
      inputW: 2, inputH: 2, inputC: 1,
      kernelSize: 1, stride: 1, dilation: 1,
      outputMultiplier: high(int32),
      activationMin: 0, activationMax: 255),
    inputLen = 4, outputLen = 3, tfliteShort)
  check("NPU model TFLite maxpool diagnostics output block",
    tfliteShort.inputFits and not tfliteShort.outputFits and
      tfliteShort.firstBlock == blaiTfliteScalarMaxPoolOutputBuffer)

proc checkAvgPoolDiagnostics() =
  var output: array[4, uint8]
  let avg = blaiReferenceAvgPool2d(
    BlaiReferenceAvgPool2d(
      inputW: 2, inputH: 1, inputC: 3,
      stride: 1,
      inputStrideC: 4,
      outputStrideC: 4,
      activationMin: 0,
      activationMax: 255),
    [2'u8, 4, 6, 99, 6, 8, 10, 99],
    output)
  check("NPU model avgpool diagnostics valid",
    avg.fits and avg.validInputShape and avg.validStride and
      avg.inputStrideValid and avg.outputStrideValid and avg.inputFits and
      avg.outputFits and avg.firstBlock == blaiAvgPoolNoBlock and
      avg.inputStrideC == 4 and avg.outputStrideC == 4)
  checkEq("NPU model avgpool diagnostics padded value", output[3].uint32, 0)

  var badStride: BlaiReferenceAvgPoolResult
  blaiReferenceAvgPoolReadinessInto(
    BlaiReferenceAvgPool2d(
      inputW: 1, inputH: 1, inputC: 2,
      stride: 1,
      inputStrideC: 1,
      activationMin: 0,
      activationMax: 255),
    inputLen = 2, outputLen = 2, badStride)
  check("NPU model avgpool diagnostics input stride block",
    badStride.validInputShape and badStride.validStride and
      not badStride.inputStrideValid and
      badStride.firstBlock == blaiAvgPoolInputStride)

  var shortOutput: BlaiReferenceAvgPoolResult
  blaiReferenceAvgPoolReadinessInto(
    BlaiReferenceAvgPool2d(
      inputW: 2, inputH: 2, inputC: 1,
      stride: 1,
      activationMin: 0,
      activationMax: 255),
    inputLen = 4, outputLen = 0, shortOutput)
  check("NPU model avgpool diagnostics output block",
    shortOutput.inputFits and not shortOutput.outputFits and
      shortOutput.firstBlock == blaiAvgPoolOutputBuffer)

proc checkTfliteMeanDiagnostics() =
  var output: array[2, uint8]
  let mean = blaiReferenceTfliteMean2d(
    BlaiReferenceTfliteMean2d(
      inputW: 2, inputH: 1, inputC: 2, inputStrideC: 4,
      outputMultiplier: high(int32), outputShift: 0),
    [10'u8, 20, 99, 99, 30, 40, 99, 99],
    output)
  check("NPU model TFLite mean diagnostics valid",
    mean.fits and mean.validInputShape and mean.spatialElementsValid and
      mean.outputShiftValid and mean.inputStrideValid and mean.inputFits and
      mean.outputFits and mean.firstBlock == blaiTfliteMeanNoBlock and
      mean.inputStrideC == 4 and mean.spatialElements == 2)
  checkEq("NPU model TFLite mean diagnostics value", output[1].uint32, 30)

  var badShift: BlaiReferenceTfliteMeanResult
  blaiReferenceTfliteMeanReadinessInto(
    BlaiReferenceTfliteMean2d(
      inputW: 1, inputH: 1, inputC: 1,
      outputMultiplier: high(int32), outputShift: 31),
    inputLen = 1, outputLen = 1, badShift)
  check("NPU model TFLite mean diagnostics shift block",
    badShift.validInputShape and badShift.spatialElementsValid and
      not badShift.outputShiftValid and
      badShift.firstBlock == blaiTfliteMeanOutputShift)

  var shortOutput: BlaiReferenceTfliteMeanResult
  blaiReferenceTfliteMeanReadinessInto(
    BlaiReferenceTfliteMean2d(
      inputW: 1, inputH: 1, inputC: 2,
      outputMultiplier: high(int32), outputShift: 0),
    inputLen = 2, outputLen = 1, shortOutput)
  check("NPU model TFLite mean diagnostics output block",
    shortOutput.inputFits and not shortOutput.outputFits and
      shortOutput.firstBlock == blaiTfliteMeanOutputBuffer)

proc checkTfliteSoftmaxDiagnostics() =
  var output: array[7, uint8]
  for i in 0 ..< output.len:
    output[i] = 0xEE'u8
  let softmax = blaiReferenceTfliteSoftmax2d(
    BlaiReferenceTfliteSoftmax2d(
      width: 2, height: 1, channels: 2, inputStrideC: 4, outputStrideC: 5),
    [10'u8, 11, 99, 99, 12, 13, 99, 99],
    output)
  check("NPU model TFLite softmax diagnostics valid",
    softmax.fits and softmax.validInputShape and
      softmax.inputStrideValid and softmax.outputStrideValid and
      softmax.inputFits and softmax.outputFits and
      softmax.firstBlock == blaiTfliteSoftmaxNoBlock and
      softmax.inputStrideC == 4 and softmax.outputStrideC == 5)
  checkEq("NPU model TFLite softmax diagnostics value", output[5].uint32, 12)

  var badStride: BlaiReferenceTfliteSoftmaxResult
  blaiReferenceTfliteSoftmaxReadinessInto(
    BlaiReferenceTfliteSoftmax2d(
      width: 1, height: 1, channels: 2, inputStrideC: 1),
    inputLen = 2, outputLen = 2, badStride)
  check("NPU model TFLite softmax diagnostics input stride block",
    badStride.validInputShape and not badStride.inputStrideValid and
      badStride.firstBlock == blaiTfliteSoftmaxInputStride)

  var shortOutput: BlaiReferenceTfliteSoftmaxResult
  blaiReferenceTfliteSoftmaxReadinessInto(
    BlaiReferenceTfliteSoftmax2d(
      width: 2, height: 1, channels: 2, inputStrideC: 4, outputStrideC: 5),
    inputLen = 8, outputLen = 6, shortOutput)
  check("NPU model TFLite softmax diagnostics output block",
    shortOutput.inputFits and not shortOutput.outputFits and
      shortOutput.firstBlock == blaiTfliteSoftmaxOutputBuffer)

proc checkTfliteTransposeLkDiagnostics() =
  var output: array[12, uint8]
  let transposelk = blaiReferenceTfliteTransposeLk1d(
    BlaiReferenceTfliteTransposeLk1d(
      inputW: 1, inputH: 5, channels: 1,
      kernelSize: 3, stride: 1, dilationH: 1),
    [10'u8, 11, 12, 13, 14],
    output)
  check("NPU model TFLite transposelk diagnostics valid",
    transposelk.fits and transposelk.validInputShape and
      transposelk.validKernel and transposelk.validStride and
      transposelk.validDilation and transposelk.windowValid and
      transposelk.rollingStrideValid and transposelk.inputFits and
      transposelk.outputFits and
      transposelk.firstBlock == blaiTfliteTransposeLkNoBlock and
      transposelk.sequenceLength == 5 and transposelk.fetchSize == 3 and
      transposelk.outputElements == 12)
  checkEq("NPU model TFLite transposelk diagnostics value",
    output[3].uint32, 128)

  var shortWindow: BlaiReferenceTfliteTransposeLkResult
  blaiReferenceTfliteTransposeLkReadinessInto(
    BlaiReferenceTfliteTransposeLk1d(
      inputW: 1, inputH: 2, channels: 1,
      kernelSize: 3, stride: 1, dilationH: 1),
    inputLen = 2, outputLen = 4, shortWindow)
  check("NPU model TFLite transposelk diagnostics window block",
    shortWindow.validInputShape and shortWindow.validKernel and
      shortWindow.validStride and shortWindow.validDilation and
      not shortWindow.windowValid and
      shortWindow.firstBlock == blaiTfliteTransposeLkWindow)

  var rollingBadStride: BlaiReferenceTfliteTransposeLkResult
  blaiReferenceTfliteTransposeLkReadinessInto(
    BlaiReferenceTfliteTransposeLk1d(
      inputW: 1, inputH: 5, channels: 1,
      kernelSize: 2, stride: 3, dilationH: 1),
    inputLen = 5, outputLen = 4, rollingBadStride, rollingV2 = true)
  check("NPU model TFLite transposelk diagnostics rolling stride block",
    not rollingBadStride.rollingStrideValid and
      rollingBadStride.firstBlock == blaiTfliteTransposeLkRollingStride)

  var shortOutput: BlaiReferenceTfliteTransposeLkResult
  blaiReferenceTfliteTransposeLkReadinessInto(
    BlaiReferenceTfliteTransposeLk1d(
      inputW: 1, inputH: 5, channels: 1,
      kernelSize: 3, stride: 1, dilationH: 2),
    inputLen = 5, outputLen = 3, shortOutput)
  check("NPU model TFLite transposelk diagnostics output block",
    shortOutput.inputFits and not shortOutput.outputFits and
      shortOutput.firstBlock == blaiTfliteTransposeLkOutputBuffer)

proc checkTflitePreTransconvDiagnostics() =
  var output: array[16, uint8]
  let pre = blaiReferenceTflitePreTransconv2d(
    BlaiReferenceTflitePreTransconv2d(
      inputW: 2, inputH: 2, channels: 1,
      outputW: 4, outputH: 4, inputOffset: 9),
    [1'u8, 2, 3, 4],
    output)
  check("NPU model TFLite pretransconv diagnostics valid",
    pre.fits and pre.validInputShape and pre.outputShapeValid and
      pre.inputFits and pre.outputFits and
      pre.firstBlock == blaiTflitePreTransconvNoBlock and
      pre.outputW == 4 and pre.outputH == 4 and pre.outputC == 1)
  checkEq("NPU model TFLite pretransconv diagnostics value",
    output[5].uint32, 1)

  var badShape: BlaiReferenceTflitePreTransconvResult
  blaiReferenceTflitePreTransconvReadinessInto(
    BlaiReferenceTflitePreTransconv2d(
      inputW: 2, inputH: 1, channels: 1,
      outputW: 3, outputH: 2),
    inputLen = 2, outputLen = 3, badShape)
  check("NPU model TFLite pretransconv diagnostics shape block",
    badShape.validInputShape and not badShape.outputShapeValid and
      badShape.firstBlock == blaiTflitePreTransconvOutputShape)

  var shortOutput: BlaiReferenceTflitePreTransconvResult
  blaiReferenceTflitePreTransconvReadinessInto(
    BlaiReferenceTflitePreTransconv2d(
      inputW: 1, inputH: 1, channels: 1,
      outputW: 2, outputH: 2),
    inputLen = 1, outputLen = 3, shortOutput)
  check("NPU model TFLite pretransconv diagnostics output block",
    shortOutput.inputFits and not shortOutput.outputFits and
      shortOutput.firstBlock == blaiTflitePreTransconvOutputBuffer)

proc checkTfliteDequantizeDiagnostics() =
  var output: array[4, float32]
  let dequant = blaiReferenceTfliteDequantize2d(
    BlaiReferenceTfliteDequantize2d(
      width: 2, height: 1, channels: 2,
      inputOffset: 10, inputScale: 0.5'f32),
    [8'u8, 10, 12, 14],
    output)
  check("NPU model TFLite dequantize diagnostics valid",
    dequant.fits and dequant.validInputShape and dequant.inputFits and
      dequant.outputFits and
      dequant.firstBlock == blaiTfliteDequantizeNoBlock and
      dequant.elements == 4 and dequant.outputW == 2 and
      dequant.outputH == 1 and dequant.outputC == 2)
  check("NPU model TFLite dequantize diagnostics value",
    output[2] == 1.0'f32)

  var shortInput: BlaiReferenceTfliteDequantizeResult
  blaiReferenceTfliteDequantizeReadinessInto(
    BlaiReferenceTfliteDequantize2d(
      width: 2, height: 1, channels: 2,
      inputOffset: 10, inputScale: 0.5'f32),
    inputLen = 3, outputLen = 4, shortInput)
  check("NPU model TFLite dequantize diagnostics input block",
    not shortInput.inputFits and
      shortInput.firstBlock == blaiTfliteDequantizeInputBuffer)

  var shortOutput: BlaiReferenceTfliteDequantizeResult
  blaiReferenceTfliteDequantizeReadinessInto(
    BlaiReferenceTfliteDequantize2d(
      width: 2, height: 1, channels: 2,
      inputOffset: 10, inputScale: 0.5'f32),
    inputLen = 4, outputLen = 3, shortOutput)
  check("NPU model TFLite dequantize diagnostics output block",
    shortOutput.inputFits and not shortOutput.outputFits and
      shortOutput.firstBlock == blaiTfliteDequantizeOutputBuffer)

proc checkTfliteLogisticDiagnostics() =
  var output: array[3, uint8]
  let logistic = blaiReferenceTfliteLogistic2d(
    BlaiReferenceTfliteLogistic2d(
      width: 3, height: 1, channels: 1,
      inputOffset: 10, inputScale: 1.0'f32,
      outputScale: 1.0'f32 / 255.0'f32),
    [0'u8, 10, 27],
    output)
  check("NPU model TFLite logistic diagnostics valid",
    logistic.fits and logistic.validInputShape and
      logistic.outputScaleValid and logistic.inputFits and
      logistic.outputFits and
      logistic.firstBlock == blaiTfliteLogisticNoBlock and
      logistic.elements == 3 and logistic.outputW == 3 and
      logistic.outputH == 1 and logistic.outputC == 1)
  checkEq("NPU model TFLite logistic diagnostics value",
    output[1].uint32, 127)

  var badScale: BlaiReferenceTfliteLogisticResult
  blaiReferenceTfliteLogisticReadinessInto(
    BlaiReferenceTfliteLogistic2d(width: 1, height: 1, channels: 1),
    inputLen = 1, outputLen = 1, badScale)
  check("NPU model TFLite logistic diagnostics scale block",
    badScale.validInputShape and not badScale.outputScaleValid and
      badScale.firstBlock == blaiTfliteLogisticOutputScale)

  var shortInput: BlaiReferenceTfliteLogisticResult
  blaiReferenceTfliteLogisticReadinessInto(
    BlaiReferenceTfliteLogistic2d(
      width: 2, height: 1, channels: 2,
      outputScale: 1.0'f32 / 255.0'f32),
    inputLen = 3, outputLen = 4, shortInput)
  check("NPU model TFLite logistic diagnostics input block",
    not shortInput.inputFits and
      shortInput.firstBlock == blaiTfliteLogisticInputBuffer)

  var shortOutput: BlaiReferenceTfliteLogisticResult
  blaiReferenceTfliteLogisticReadinessInto(
    BlaiReferenceTfliteLogistic2d(
      width: 2, height: 1, channels: 2,
      outputScale: 1.0'f32 / 255.0'f32),
    inputLen = 4, outputLen = 3, shortOutput)
  check("NPU model TFLite logistic diagnostics output block",
    shortOutput.inputFits and not shortOutput.outputFits and
      shortOutput.firstBlock == blaiTfliteLogisticOutputBuffer)

proc checkUpsampleDiagnostics() =
  var output: array[8, int8]
  let upsample = blaiReferenceUpsample2d(
    BlaiReferenceUpsample2d(inputW: 2, inputH: 1, inputC: 1, stride: 2),
    [1'i8, 2],
    output)
  check("NPU model upsample diagnostics valid",
    upsample.fits and upsample.validInputShape and upsample.validStride and
      upsample.outputShapeValid and upsample.inputFits and
      upsample.outputFits and upsample.firstBlock == blaiUpsampleNoBlock and
      upsample.inputElements == 2 and upsample.requiredOutputElements == 8)
  checkEq("NPU model upsample diagnostics value", output[7].uint32, 2)

  var badShape: BlaiReferenceUpsampleResult
  blaiReferenceUpsampleReadinessInto(
    BlaiReferenceUpsample2d(
      inputW: 2, inputH: 1, inputC: 1, stride: 2,
      outputW: 3, outputH: 2, outputC: 1),
    inputLen = 2, outputLen = 6, badShape)
  check("NPU model upsample diagnostics shape block",
    badShape.validInputShape and badShape.validStride and
      not badShape.outputShapeValid and
      badShape.firstBlock == blaiUpsampleOutputShape)

  var shortOutput: BlaiReferenceUpsampleResult
  blaiReferenceUpsampleReadinessInto(
    BlaiReferenceUpsample2d(
      inputW: 1, inputH: 1, inputC: 1, stride: 2, outputC: 2),
    inputLen = 1, outputLen = 6, shortOutput)
  check("NPU model upsample diagnostics output block",
    shortOutput.inputFits and not shortOutput.outputFits and
      shortOutput.firstBlock == blaiUpsampleOutputBuffer)

proc checkRouteUpsampleDiagnostics() =
  var output: array[8, int8]
  let routeUpsample = blaiReferenceRouteUpsample2d(
    BlaiReferenceRouteUpsample2d(
      width: 1, height: 1, route1C: 1, route2C: 1, stride: 2),
    [3'i8],
    [5'i8],
    output)
  check("NPU model route upsample diagnostics valid",
    routeUpsample.fits and routeUpsample.validInputShape and
      routeUpsample.validStride and routeUpsample.routeChannelsValid and
      routeUpsample.outputShapeValid and routeUpsample.input1Fits and
      routeUpsample.input2Fits and routeUpsample.outputFits and
      routeUpsample.firstBlock == blaiRouteUpsampleNoBlock and
      routeUpsample.routeC == 2 and routeUpsample.input1Elements == 1 and
      routeUpsample.input2Elements == 1 and
      routeUpsample.requiredOutputElements == 8)
  checkEq("NPU model route upsample diagnostics value", output[7].uint32, 5)

  var badChannels: BlaiReferenceRouteUpsampleResult
  blaiReferenceRouteUpsampleReadinessInto(
    BlaiReferenceRouteUpsample2d(
      width: 1, height: 1, route1C: 1, route2C: 1, stride: 1, outputC: 3),
    input1Len = 1, input2Len = 1, outputLen = 2, badChannels)
  check("NPU model route upsample diagnostics channels block",
    badChannels.validInputShape and badChannels.validStride and
      not badChannels.routeChannelsValid and
      badChannels.firstBlock == blaiRouteUpsampleRouteChannels)

  var shortInput2: BlaiReferenceRouteUpsampleResult
  blaiReferenceRouteUpsampleReadinessInto(
    BlaiReferenceRouteUpsample2d(
      width: 1, height: 1, route1C: 1, route2C: 1, stride: 1),
    input1Len = 1, input2Len = 0, outputLen = 2, shortInput2)
  check("NPU model route upsample diagnostics input2 block",
    shortInput2.input1Fits and not shortInput2.input2Fits and
      shortInput2.firstBlock == blaiRouteUpsampleInput2Buffer)

  var shortOutput: BlaiReferenceRouteUpsampleResult
  blaiReferenceRouteUpsampleReadinessInto(
    BlaiReferenceRouteUpsample2d(
      width: 1, height: 1, route1C: 1, route2C: 1, stride: 2),
    input1Len = 1, input2Len = 1, outputLen = 6, shortOutput)
  check("NPU model route upsample diagnostics output block",
    shortOutput.input1Fits and shortOutput.input2Fits and
      not shortOutput.outputFits and
      shortOutput.firstBlock == blaiRouteUpsampleOutputBuffer)

proc checkRouteConcatDiagnostics() =
  var output: array[6, int8]
  let route = blaiReferenceRouteConcat2d(
    BlaiReferenceRouteConcat2d(
      width: 2, height: 1, inputCount: 2,
      inputs: [
        BlaiReferenceRouteInput(active: true, offset: 0, channels: 1),
        BlaiReferenceRouteInput(active: true, offset: 2, channels: 2),
        BlaiReferenceRouteInput(), BlaiReferenceRouteInput(),
        BlaiReferenceRouteInput(), BlaiReferenceRouteInput(),
        BlaiReferenceRouteInput(), BlaiReferenceRouteInput()]),
    [10'i8, 20, 1, 2, 3, 4],
    output)
  check("NPU model route concat diagnostics valid",
    route.fits and route.validInputShape and route.validInputCount and
      route.inputsActive and route.inputChannelsValid and route.inputFits and
      route.outputChannelsValid and route.outputFits and
      route.firstBlock == blaiRouteConcatNoBlock and route.outputC == 3 and
      route.firstBlockedInputElements == 6 and
      route.requiredOutputElements == 6)
  checkEq("NPU model route concat diagnostics value", output[5].uint32, 4)

  var inactiveInput: BlaiReferenceRouteConcatResult
  blaiReferenceRouteConcatReadinessInto(
    BlaiReferenceRouteConcat2d(
      width: 1, height: 1, inputCount: 1),
    inputLen = 1, outputLen = 1, inactiveInput)
  check("NPU model route concat diagnostics inactive block",
    inactiveInput.validInputShape and inactiveInput.validInputCount and
      not inactiveInput.inputsActive and inactiveInput.firstBlockedInput == 0 and
      inactiveInput.firstBlock == blaiRouteConcatInputInactive)

  var shortInput: BlaiReferenceRouteConcatResult
  blaiReferenceRouteConcatReadinessInto(
    BlaiReferenceRouteConcat2d(
      width: 2, height: 1, inputCount: 1,
      inputs: [
        BlaiReferenceRouteInput(active: true, offset: 1, channels: 1),
        BlaiReferenceRouteInput(), BlaiReferenceRouteInput(),
        BlaiReferenceRouteInput(), BlaiReferenceRouteInput(),
        BlaiReferenceRouteInput(), BlaiReferenceRouteInput(),
        BlaiReferenceRouteInput()]),
    inputLen = 2, outputLen = 2, shortInput)
  check("NPU model route concat diagnostics input block",
    shortInput.inputsActive and shortInput.inputChannelsValid and
      not shortInput.inputFits and shortInput.firstBlockedInput == 0 and
      shortInput.firstBlockedInputElements == 3 and
      shortInput.firstBlock == blaiRouteConcatInputBuffer)

  var shortOutput: BlaiReferenceRouteConcatResult
  blaiReferenceRouteConcatReadinessInto(
    BlaiReferenceRouteConcat2d(
      width: 2, height: 1, inputCount: 1,
      inputs: [
        BlaiReferenceRouteInput(active: true, offset: 0, channels: 1),
        BlaiReferenceRouteInput(), BlaiReferenceRouteInput(),
        BlaiReferenceRouteInput(), BlaiReferenceRouteInput(),
        BlaiReferenceRouteInput(), BlaiReferenceRouteInput(),
        BlaiReferenceRouteInput()]),
    inputLen = 2, outputLen = 1, shortOutput)
  check("NPU model route concat diagnostics output block",
    shortOutput.inputFits and shortOutput.outputChannelsValid and
      not shortOutput.outputFits and shortOutput.requiredOutputElements == 2 and
      shortOutput.firstBlock == blaiRouteConcatOutputBuffer)

proc checkRouteMaxDiagnostics() =
  var output: array[2, int8]
  let routeMax = blaiReferenceRouteMax2d(
    BlaiReferenceRouteMax2d(
      width: 2, height: 2, outputW: 1, outputH: 1, stride: 1,
      inputCount: 2,
      inputs: [
        BlaiReferenceRouteInput(active: true, offset: 0, channels: 1),
        BlaiReferenceRouteInput(active: true, offset: 4, channels: 1),
        BlaiReferenceRouteInput(), BlaiReferenceRouteInput(),
        BlaiReferenceRouteInput(), BlaiReferenceRouteInput(),
        BlaiReferenceRouteInput(), BlaiReferenceRouteInput()]),
    [1'i8, 4, 3, 2, 5, 8, 7, 6],
    output)
  check("NPU model route max diagnostics valid",
    routeMax.fits and routeMax.validInputShape and
      routeMax.validOutputShape and routeMax.validStride and
      routeMax.validInputCount and routeMax.inputsActive and
      routeMax.inputChannelsValid and routeMax.inputFits and
      routeMax.outputChannelsValid and routeMax.outputFits and
      routeMax.firstBlock == blaiRouteMaxNoBlock and routeMax.outputC == 2 and
      routeMax.firstBlockedInputElements == 8 and
      routeMax.requiredOutputElements == 2)
  checkEq("NPU model route max diagnostics value", output[1].uint32, 8)

  var badShape: BlaiReferenceRouteMaxResult
  blaiReferenceRouteMaxReadinessInto(
    BlaiReferenceRouteMax2d(
      width: 3, height: 2, outputW: 1, outputH: 1, stride: 1,
      inputCount: 1,
      inputs: [
        BlaiReferenceRouteInput(active: true, offset: 0, channels: 1),
        BlaiReferenceRouteInput(), BlaiReferenceRouteInput(),
        BlaiReferenceRouteInput(), BlaiReferenceRouteInput(),
        BlaiReferenceRouteInput(), BlaiReferenceRouteInput(),
        BlaiReferenceRouteInput()]),
    inputLen = 6, outputLen = 2, badShape)
  check("NPU model route max diagnostics shape block",
    badShape.validInputShape and not badShape.validOutputShape and
      badShape.firstBlock == blaiRouteMaxOutputShape)

  var shortInput: BlaiReferenceRouteMaxResult
  blaiReferenceRouteMaxReadinessInto(
    BlaiReferenceRouteMax2d(
      width: 2, height: 2, outputW: 1, outputH: 1, stride: 1,
      inputCount: 1,
      inputs: [
        BlaiReferenceRouteInput(active: true, offset: 1, channels: 1),
        BlaiReferenceRouteInput(), BlaiReferenceRouteInput(),
        BlaiReferenceRouteInput(), BlaiReferenceRouteInput(),
        BlaiReferenceRouteInput(), BlaiReferenceRouteInput(),
        BlaiReferenceRouteInput()]),
    inputLen = 4, outputLen = 1, shortInput)
  check("NPU model route max diagnostics input block",
    shortInput.inputsActive and shortInput.inputChannelsValid and
      not shortInput.inputFits and shortInput.firstBlockedInput == 0 and
      shortInput.firstBlockedInputElements == 5 and
      shortInput.firstBlock == blaiRouteMaxInputBuffer)

  var shortOutput: BlaiReferenceRouteMaxResult
  blaiReferenceRouteMaxReadinessInto(
    BlaiReferenceRouteMax2d(
      width: 2, height: 2, outputW: 1, outputH: 1, stride: 1,
      inputCount: 2,
      inputs: [
        BlaiReferenceRouteInput(active: true, offset: 0, channels: 1),
        BlaiReferenceRouteInput(active: true, offset: 4, channels: 1),
        BlaiReferenceRouteInput(), BlaiReferenceRouteInput(),
        BlaiReferenceRouteInput(), BlaiReferenceRouteInput(),
        BlaiReferenceRouteInput(), BlaiReferenceRouteInput()]),
    inputLen = 8, outputLen = 1, shortOutput)
  check("NPU model route max diagnostics output block",
    shortOutput.inputFits and shortOutput.outputChannelsValid and
      not shortOutput.outputFits and shortOutput.requiredOutputElements == 2 and
      shortOutput.firstBlock == blaiRouteMaxOutputBuffer)

proc checkShortcutDiagnostics() =
  var output: array[2, int8]
  let shortcut = blaiReferenceShortcut2d(
    BlaiReferenceShortcut2d(width: 2, height: 1, channels: 1),
    [7'i8, -3],
    [5'i8, 4],
    output)
  check("NPU model shortcut diagnostics valid",
    shortcut.fits and shortcut.validInputShape and shortcut.input1Fits and
      shortcut.input2Fits and shortcut.outputFits and
      shortcut.firstBlock == blaiShortcutNoBlock and
      shortcut.requiredElements == 2)
  checkEq("NPU model shortcut diagnostics value", output[0].uint32, 12)

  var badShape: BlaiReferenceShortcutResult
  blaiReferenceShortcutReadinessInto(
    BlaiReferenceShortcut2d(width: 0, height: 1, channels: 1),
    input1Len = 1, input2Len = 1, outputLen = 1, badShape)
  check("NPU model shortcut diagnostics shape block",
    not badShape.validInputShape and
      badShape.firstBlock == blaiShortcutInputShape)

  var shortInput1: BlaiReferenceShortcutResult
  blaiReferenceShortcutReadinessInto(
    BlaiReferenceShortcut2d(width: 2, height: 1, channels: 1),
    input1Len = 1, input2Len = 2, outputLen = 2, shortInput1)
  check("NPU model shortcut diagnostics input1 block",
    not shortInput1.input1Fits and
      shortInput1.firstBlock == blaiShortcutInput1Buffer)

  var shortInput2: BlaiReferenceShortcutResult
  blaiReferenceShortcutReadinessInto(
    BlaiReferenceShortcut2d(width: 2, height: 1, channels: 1),
    input1Len = 2, input2Len = 1, outputLen = 2, shortInput2)
  check("NPU model shortcut diagnostics input2 block",
    shortInput2.input1Fits and not shortInput2.input2Fits and
      shortInput2.firstBlock == blaiShortcutInput2Buffer)

  var shortOutput: BlaiReferenceShortcutResult
  blaiReferenceShortcutReadinessInto(
    BlaiReferenceShortcut2d(width: 2, height: 1, channels: 1),
    input1Len = 2, input2Len = 2, outputLen = 1, shortOutput)
  check("NPU model shortcut diagnostics output block",
    shortOutput.input1Fits and shortOutput.input2Fits and
      not shortOutput.outputFits and shortOutput.requiredElements == 2 and
      shortOutput.firstBlock == blaiShortcutOutputBuffer)

proc checkTfliteShortcutDiagnostics() =
  var output: array[2, uint8]
  let shortcut = blaiReferenceTfliteShortcut2d(
    BlaiReferenceTfliteShortcut2d(
      width: 2, height: 1, channels: 1,
      input1Multiplier: high(int32),
      input2Multiplier: high(int32),
      outputMultiplier: high(int32),
      input1Shift: -20,
      input2Shift: -20,
      outputShift: 0,
      activationMax: 255),
    [7'u8, 3],
    [5'u8, 4],
    output)
  check("NPU model TFLite shortcut diagnostics valid",
    shortcut.fits and shortcut.validInputShape and shortcut.shiftsValid and
      shortcut.activationRangeValid and shortcut.input1Fits and
      shortcut.input2Fits and shortcut.outputFits and
      shortcut.firstBlock == blaiTfliteShortcutNoBlock and
      shortcut.requiredElements == 2)
  checkEq("NPU model TFLite shortcut diagnostics value", output[0].uint32, 12)

  var badShift: BlaiReferenceTfliteShortcutResult
  blaiReferenceTfliteShortcutReadinessInto(
    BlaiReferenceTfliteShortcut2d(
      width: 1, height: 1, channels: 1,
      input1Shift: 1, input2Shift: -20, outputShift: 0,
      activationMax: 255),
    input1Len = 1, input2Len = 1, outputLen = 1, badShift)
  check("NPU model TFLite shortcut diagnostics shift block",
    badShift.validInputShape and not badShift.shiftsValid and
      badShift.firstBlock == blaiTfliteShortcutShift)

  var badActivation: BlaiReferenceTfliteShortcutResult
  blaiReferenceTfliteShortcutReadinessInto(
    BlaiReferenceTfliteShortcut2d(
      width: 1, height: 1, channels: 1,
      input1Shift: -20, input2Shift: -20, outputShift: 0,
      activationMin: 20, activationMax: 10),
    input1Len = 1, input2Len = 1, outputLen = 1, badActivation)
  check("NPU model TFLite shortcut diagnostics activation block",
    badActivation.shiftsValid and not badActivation.activationRangeValid and
      badActivation.firstBlock == blaiTfliteShortcutActivationRange)

  var shortInput1: BlaiReferenceTfliteShortcutResult
  blaiReferenceTfliteShortcutReadinessInto(
    BlaiReferenceTfliteShortcut2d(
      width: 2, height: 1, channels: 1,
      input1Shift: -20, input2Shift: -20, outputShift: 0,
      activationMax: 255),
    input1Len = 1, input2Len = 2, outputLen = 2, shortInput1)
  check("NPU model TFLite shortcut diagnostics input1 block",
    shortInput1.activationRangeValid and not shortInput1.input1Fits and
      shortInput1.firstBlock == blaiTfliteShortcutInput1Buffer)

  var shortOutput: BlaiReferenceTfliteShortcutResult
  blaiReferenceTfliteShortcutReadinessInto(
    BlaiReferenceTfliteShortcut2d(
      width: 2, height: 1, channels: 1,
      input1Shift: -20, input2Shift: -20, outputShift: 0,
      activationMax: 255),
    input1Len = 2, input2Len = 2, outputLen = 1, shortOutput)
  check("NPU model TFLite shortcut diagnostics output block",
    shortOutput.input1Fits and shortOutput.input2Fits and
      not shortOutput.outputFits and shortOutput.requiredElements == 2 and
      shortOutput.firstBlock == blaiTfliteShortcutOutputBuffer)

proc checkTfliteRouteDiagnostics() =
  var output: array[2, uint8]
  let route = blaiReferenceTfliteRoute2d(
    BlaiReferenceTfliteRoute2d(
      width: 1, height: 1, outputC: 2, inputCount: 2,
      outputMultiplier: high(int32),
      outputShift: 0,
      activationMax: 255,
      inputs: [
        BlaiReferenceTfliteRouteInput(
          active: true, offset: 0, channels: 1,
          inputMultiplier: high(int32), inputShift: -20),
        BlaiReferenceTfliteRouteInput(
          active: true, offset: 1, channels: 1,
          inputMultiplier: high(int32), inputShift: -20),
        BlaiReferenceTfliteRouteInput(), BlaiReferenceTfliteRouteInput(),
        BlaiReferenceTfliteRouteInput(), BlaiReferenceTfliteRouteInput(),
        BlaiReferenceTfliteRouteInput(), BlaiReferenceTfliteRouteInput()]),
    [7'u8, 5],
    output)
  check("NPU model TFLite route diagnostics valid",
    route.fits and route.validInputShape and route.validInputCount and
      route.outputShiftValid and route.activationRangeValid and
      route.inputsActive and route.inputChannelsValid and
      route.inputShiftsValid and route.inputFits and
      route.outputChannelsValid and route.outputFits and
      route.firstBlock == blaiTfliteRouteNoBlock and
      route.firstBlockedInputElements == 2 and
      route.requiredOutputElements == 2)
  checkEq("NPU model TFLite route diagnostics value", output[1].uint32, 5)

  let routeLayer = BlaiCpuInstLayer64(
    layerType: ord(blaiRoute).int32,
    w: 1, h: 1, outW: 1,
    c: 1,
    cn: [1'i32, 1, 0, 0, 0, 0, 0],
    outC: 3,
    inputNum: 3,
    inLayer1Mem: 0,
    inLayer2Mem: 1,
    dramPatchSize: 4,
    tfInput1Offset: 1,
    tfInput2Offset: 2,
    tfOutputOffset: 3,
    tfInput1Multiplier: 0x4000_0000'i32,
    tfInput2Multiplier: 0x4000_0000'i32,
    tfOutputMultiplier: 0x4000_0000'i32,
    tfInput1Shift: -20,
    tfInput2Shift: -20,
    tfOutputShift: 0,
    quantizedActivationMax: 255)
  let routeStorage = BlaiCpuExtraInputStorage(
    active: true,
    inLayerMemN: [2'i32, 0, 0, 0, 0, 0],
    tfInputOffsetExtra: [3'i32, 0, 0, 0, 0, 0],
    tfInputShiftExtra: [-20'i32, 0, 0, 0, 0, 0],
    tfInputMultiplierExtra: [0x4000_0000'i32, 0, 0, 0, 0, 0])
  var routeDispatchOutput: array[3, uint8]
  let routeDispatch = blaiReferenceTfliteRouteLayer2d(
    routeLayer, routeStorage, patchSize = 4,
    input = [9'u8, 0, 0, 0, 12, 0, 0, 0, 15],
    output = routeDispatchOutput)
  check("NPU model TFLite route diagnostics dispatch block",
    routeDispatch.supported and routeDispatch.fits and
      routeDispatch.firstBlock == blaiTfliteLayerNoBlock and
      routeDispatch.routeBlock == blaiTfliteRouteNoBlock)

  var badShift: BlaiReferenceTfliteRouteResult
  blaiReferenceTfliteRouteReadinessInto(
    BlaiReferenceTfliteRoute2d(
      width: 1, height: 1, outputC: 1, inputCount: 1,
      outputShift: 1,
      activationMax: 255,
      inputs: [
        BlaiReferenceTfliteRouteInput(
          active: true, offset: 0, channels: 1, inputShift: -20),
        BlaiReferenceTfliteRouteInput(), BlaiReferenceTfliteRouteInput(),
        BlaiReferenceTfliteRouteInput(), BlaiReferenceTfliteRouteInput(),
        BlaiReferenceTfliteRouteInput(), BlaiReferenceTfliteRouteInput(),
        BlaiReferenceTfliteRouteInput()]),
    inputLen = 1, outputLen = 1, badShift)
  check("NPU model TFLite route diagnostics shift block",
    badShift.validInputShape and not badShift.outputShiftValid and
      badShift.firstBlock == blaiTfliteRouteOutputShift)

  var badInputShift: BlaiReferenceTfliteRouteResult
  blaiReferenceTfliteRouteReadinessInto(
    BlaiReferenceTfliteRoute2d(
      width: 1, height: 1, outputC: 1, inputCount: 1,
      activationMax: 255,
      inputs: [
        BlaiReferenceTfliteRouteInput(
          active: true, offset: 0, channels: 1, inputShift: 1),
        BlaiReferenceTfliteRouteInput(), BlaiReferenceTfliteRouteInput(),
        BlaiReferenceTfliteRouteInput(), BlaiReferenceTfliteRouteInput(),
        BlaiReferenceTfliteRouteInput(), BlaiReferenceTfliteRouteInput(),
        BlaiReferenceTfliteRouteInput()]),
    inputLen = 1, outputLen = 1, badInputShift)
  check("NPU model TFLite route diagnostics input shift block",
    badInputShift.outputShiftValid and not badInputShift.inputShiftsValid and
      badInputShift.firstBlockedInput == 0 and
      badInputShift.firstBlock == blaiTfliteRouteInputShift)

  var badChannels: BlaiReferenceTfliteRouteResult
  blaiReferenceTfliteRouteReadinessInto(
    BlaiReferenceTfliteRoute2d(
      width: 1, height: 1, outputC: 2, inputCount: 1,
      activationMax: 255,
      inputs: [
        BlaiReferenceTfliteRouteInput(
          active: true, offset: 0, channels: 1, inputShift: -20),
        BlaiReferenceTfliteRouteInput(), BlaiReferenceTfliteRouteInput(),
        BlaiReferenceTfliteRouteInput(), BlaiReferenceTfliteRouteInput(),
        BlaiReferenceTfliteRouteInput(), BlaiReferenceTfliteRouteInput(),
        BlaiReferenceTfliteRouteInput()]),
    inputLen = 1, outputLen = 2, badChannels)
  check("NPU model TFLite route diagnostics channels block",
    badChannels.inputFits and not badChannels.outputChannelsValid and
      badChannels.firstBlock == blaiTfliteRouteOutputChannels)

  var shortOutput: BlaiReferenceTfliteRouteResult
  blaiReferenceTfliteRouteReadinessInto(
    BlaiReferenceTfliteRoute2d(
      width: 1, height: 1, outputC: 1, inputCount: 1,
      activationMax: 255,
      inputs: [
        BlaiReferenceTfliteRouteInput(
          active: true, offset: 0, channels: 1, inputShift: -20),
        BlaiReferenceTfliteRouteInput(), BlaiReferenceTfliteRouteInput(),
        BlaiReferenceTfliteRouteInput(), BlaiReferenceTfliteRouteInput(),
        BlaiReferenceTfliteRouteInput(), BlaiReferenceTfliteRouteInput(),
        BlaiReferenceTfliteRouteInput()]),
    inputLen = 1, outputLen = 0, shortOutput)
  check("NPU model TFLite route diagnostics output block",
    shortOutput.inputFits and shortOutput.outputChannelsValid and
      not shortOutput.outputFits and
      shortOutput.firstBlock == blaiTfliteRouteOutputBuffer)

proc checkTfliteRouteMaxDiagnostics() =
  var output: array[2, uint8]
  let routeMax = blaiReferenceTfliteRouteMax2d(
    BlaiReferenceTfliteRouteMax2d(
      width: 2, height: 2, outputW: 1, outputH: 1, stride: 1,
      outputC: 2, inputCount: 2,
      outputMultiplier: high(int32),
      outputShift: 0,
      activationMax: 255,
      inputs: [
        BlaiReferenceTfliteRouteInput(
          active: true, offset: 0, channels: 1,
          inputMultiplier: high(int32), inputShift: -20),
        BlaiReferenceTfliteRouteInput(
          active: true, offset: 4, channels: 1,
          inputMultiplier: high(int32), inputShift: -20),
        BlaiReferenceTfliteRouteInput(), BlaiReferenceTfliteRouteInput(),
        BlaiReferenceTfliteRouteInput(), BlaiReferenceTfliteRouteInput(),
        BlaiReferenceTfliteRouteInput(), BlaiReferenceTfliteRouteInput()]),
    [1'u8, 5, 2, 6, 3, 7, 4, 8],
    output)
  check("NPU model TFLite route max diagnostics valid",
    routeMax.fits and routeMax.validInputShape and
      routeMax.validOutputShape and routeMax.validStride and
      routeMax.validInputCount and routeMax.outputShiftValid and
      routeMax.activationRangeValid and routeMax.inputsActive and
      routeMax.inputChannelsValid and routeMax.inputShiftsValid and
      routeMax.inputFits and routeMax.outputChannelsValid and
      routeMax.outputFits and routeMax.firstBlock == blaiTfliteRouteMaxNoBlock and
      routeMax.firstBlockedInputElements == 8 and
      routeMax.requiredOutputElements == 2)
  checkEq("NPU model TFLite route max diagnostics value", output[1].uint32, 8)

  var badShape: BlaiReferenceTfliteRouteMaxResult
  blaiReferenceTfliteRouteMaxReadinessInto(
    BlaiReferenceTfliteRouteMax2d(
      width: 3, height: 2, outputW: 1, outputH: 1, stride: 1,
      outputC: 1, inputCount: 1,
      activationMax: 255,
      inputs: [
        BlaiReferenceTfliteRouteInput(
          active: true, offset: 0, channels: 1, inputShift: -20),
        BlaiReferenceTfliteRouteInput(), BlaiReferenceTfliteRouteInput(),
        BlaiReferenceTfliteRouteInput(), BlaiReferenceTfliteRouteInput(),
        BlaiReferenceTfliteRouteInput(), BlaiReferenceTfliteRouteInput(),
        BlaiReferenceTfliteRouteInput()]),
    inputLen = 6, outputLen = 1, badShape)
  check("NPU model TFLite route max diagnostics shape block",
    badShape.validInputShape and not badShape.validOutputShape and
      badShape.firstBlock == blaiTfliteRouteMaxOutputShape)

  var badInputShift: BlaiReferenceTfliteRouteMaxResult
  blaiReferenceTfliteRouteMaxReadinessInto(
    BlaiReferenceTfliteRouteMax2d(
      width: 1, height: 1, outputW: 1, outputH: 1, stride: 1,
      outputC: 1, inputCount: 1,
      activationMax: 255,
      inputs: [
        BlaiReferenceTfliteRouteInput(
          active: true, offset: 0, channels: 1, inputShift: 1),
        BlaiReferenceTfliteRouteInput(), BlaiReferenceTfliteRouteInput(),
        BlaiReferenceTfliteRouteInput(), BlaiReferenceTfliteRouteInput(),
        BlaiReferenceTfliteRouteInput(), BlaiReferenceTfliteRouteInput(),
        BlaiReferenceTfliteRouteInput()]),
    inputLen = 1, outputLen = 1, badInputShift)
  check("NPU model TFLite route max diagnostics input shift block",
    badInputShift.outputShiftValid and not badInputShift.inputShiftsValid and
      badInputShift.firstBlockedInput == 0 and
      badInputShift.firstBlock == blaiTfliteRouteMaxInputShift)

  var badChannels: BlaiReferenceTfliteRouteMaxResult
  blaiReferenceTfliteRouteMaxReadinessInto(
    BlaiReferenceTfliteRouteMax2d(
      width: 1, height: 1, outputW: 1, outputH: 1, stride: 1,
      outputC: 2, inputCount: 1,
      activationMax: 255,
      inputs: [
        BlaiReferenceTfliteRouteInput(
          active: true, offset: 0, channels: 1, inputShift: -20),
        BlaiReferenceTfliteRouteInput(), BlaiReferenceTfliteRouteInput(),
        BlaiReferenceTfliteRouteInput(), BlaiReferenceTfliteRouteInput(),
        BlaiReferenceTfliteRouteInput(), BlaiReferenceTfliteRouteInput(),
        BlaiReferenceTfliteRouteInput()]),
    inputLen = 1, outputLen = 2, badChannels)
  check("NPU model TFLite route max diagnostics channels block",
    badChannels.inputFits and not badChannels.outputChannelsValid and
      badChannels.firstBlock == blaiTfliteRouteMaxOutputChannels)

  var shortOutput: BlaiReferenceTfliteRouteMaxResult
  blaiReferenceTfliteRouteMaxReadinessInto(
    BlaiReferenceTfliteRouteMax2d(
      width: 2, height: 2, outputW: 1, outputH: 1, stride: 1,
      outputC: 1, inputCount: 1,
      activationMax: 255,
      inputs: [
        BlaiReferenceTfliteRouteInput(
          active: true, offset: 0, channels: 1, inputShift: -20),
        BlaiReferenceTfliteRouteInput(), BlaiReferenceTfliteRouteInput(),
        BlaiReferenceTfliteRouteInput(), BlaiReferenceTfliteRouteInput(),
        BlaiReferenceTfliteRouteInput(), BlaiReferenceTfliteRouteInput(),
        BlaiReferenceTfliteRouteInput()]),
    inputLen = 4, outputLen = 0, shortOutput)
  check("NPU model TFLite route max diagnostics output block",
    shortOutput.inputFits and shortOutput.outputChannelsValid and
      not shortOutput.outputFits and
      shortOutput.firstBlock == blaiTfliteRouteMaxOutputBuffer)

proc checkTfliteRouteWDiagnostics() =
  var output: array[3, uint8]
  let routeW = blaiReferenceTfliteRouteW2d(
    BlaiReferenceTfliteRouteW2d(
      width: 3, height: 1, outputW: 3, outputC: 1, axis: 0,
      inputCount: 2, outputOffset: 1, activationMax: 255,
      inputs: [
        BlaiReferenceTfliteRouteInput(
          active: true, offset: 0, channels: 1, inputOffset: 7),
        BlaiReferenceTfliteRouteInput(
          active: true, offset: 4, channels: 2, inputOffset: 7),
        BlaiReferenceTfliteRouteInput(), BlaiReferenceTfliteRouteInput(),
        BlaiReferenceTfliteRouteInput(), BlaiReferenceTfliteRouteInput(),
        BlaiReferenceTfliteRouteInput(), BlaiReferenceTfliteRouteInput()]),
    [11'u8, 0, 0, 0, 21, 22],
    output)
  check("NPU model TFLite route W diagnostics valid",
    routeW.fits and routeW.easyCopy and routeW.validInputShape and
      routeW.validInputCount and routeW.axisValid and
      routeW.outputShiftValid and routeW.activationRangeValid and
      routeW.inputsActive and routeW.inputChannelsValid and
      routeW.inputShiftsValid and routeW.inputFits and
      routeW.outputExtentValid and routeW.outputFits and
      routeW.firstBlock == blaiTfliteRouteWNoBlock and
      routeW.inputExtent == 3 and routeW.firstBlockedInputElements == 6 and
      routeW.requiredOutputElements == 3)
  checkEq("NPU model TFLite route W diagnostics value", output[2].uint32, 22)

  var badAxis: BlaiReferenceTfliteRouteWResult
  blaiReferenceTfliteRouteWReadinessInto(
    BlaiReferenceTfliteRouteW2d(
      width: 1, height: 1, outputW: 1, outputC: 1, axis: 2,
      inputCount: 1, activationMax: 255,
      inputs: [
        BlaiReferenceTfliteRouteInput(active: true, channels: 1),
        BlaiReferenceTfliteRouteInput(), BlaiReferenceTfliteRouteInput(),
        BlaiReferenceTfliteRouteInput(), BlaiReferenceTfliteRouteInput(),
        BlaiReferenceTfliteRouteInput(), BlaiReferenceTfliteRouteInput(),
        BlaiReferenceTfliteRouteInput()]),
    inputLen = 1, outputLen = 1, badAxis)
  check("NPU model TFLite route W diagnostics axis block",
    badAxis.validInputShape and not badAxis.axisValid and
      badAxis.firstBlock == blaiTfliteRouteWAxis)

  var badShift: BlaiReferenceTfliteRouteWResult
  blaiReferenceTfliteRouteWReadinessInto(
    BlaiReferenceTfliteRouteW2d(
      width: 1, height: 1, outputW: 1, outputC: 1, axis: 0,
      inputCount: 1, activationMax: 255,
      inputs: [
        BlaiReferenceTfliteRouteInput(
          active: true, channels: 1, inputShift: 1),
        BlaiReferenceTfliteRouteInput(), BlaiReferenceTfliteRouteInput(),
        BlaiReferenceTfliteRouteInput(), BlaiReferenceTfliteRouteInput(),
        BlaiReferenceTfliteRouteInput(), BlaiReferenceTfliteRouteInput(),
        BlaiReferenceTfliteRouteInput()]),
    inputLen = 1, outputLen = 1, badShift)
  check("NPU model TFLite route W diagnostics input shift block",
    not badShift.easyCopy and not badShift.inputShiftsValid and
      badShift.firstBlock == blaiTfliteRouteWInputShift)

  var badExtent: BlaiReferenceTfliteRouteWResult
  blaiReferenceTfliteRouteWReadinessInto(
    BlaiReferenceTfliteRouteW2d(
      width: 2, height: 1, outputW: 2, outputC: 1, axis: 0,
      inputCount: 1, activationMax: 255,
      inputs: [
        BlaiReferenceTfliteRouteInput(
          active: true, channels: 1, inputShift: -20),
        BlaiReferenceTfliteRouteInput(), BlaiReferenceTfliteRouteInput(),
        BlaiReferenceTfliteRouteInput(), BlaiReferenceTfliteRouteInput(),
        BlaiReferenceTfliteRouteInput(), BlaiReferenceTfliteRouteInput(),
        BlaiReferenceTfliteRouteInput()]),
    inputLen = 1, outputLen = 2, badExtent)
  check("NPU model TFLite route W diagnostics extent block",
    badExtent.inputFits and not badExtent.outputExtentValid and
      badExtent.firstBlock == blaiTfliteRouteWOutputExtent)

  var shortOutput: BlaiReferenceTfliteRouteWResult
  blaiReferenceTfliteRouteWReadinessInto(
    BlaiReferenceTfliteRouteW2d(
      width: 1, height: 1, outputW: 1, outputC: 1, axis: 0,
      inputCount: 1, activationMax: 255,
      inputs: [
        BlaiReferenceTfliteRouteInput(
          active: true, channels: 1, inputShift: -20),
        BlaiReferenceTfliteRouteInput(), BlaiReferenceTfliteRouteInput(),
        BlaiReferenceTfliteRouteInput(), BlaiReferenceTfliteRouteInput(),
        BlaiReferenceTfliteRouteInput(), BlaiReferenceTfliteRouteInput(),
        BlaiReferenceTfliteRouteInput()]),
    inputLen = 1, outputLen = 0, shortOutput)
  check("NPU model TFLite route W diagnostics output block",
    shortOutput.inputFits and shortOutput.outputExtentValid and
      not shortOutput.outputFits and
      shortOutput.firstBlock == blaiTfliteRouteWOutputBuffer)

proc checkTfliteReshapeDiagnostics() =
  var output: array[6, uint8]
  let reshape = blaiReferenceTfliteReshape2d(
    BlaiReferenceTfliteReshape2d(
      width: 2, height: 1, inputC: 3, outputC: 3,
      inputStrideC: 3, outputStrideC: 3),
    [1'u8, 2, 3, 4, 5, 6],
    output)
  check("NPU model TFLite reshape diagnostics valid",
    reshape.fits and reshape.fastCopy and reshape.validInputShape and
      reshape.validInputStride and reshape.validOutputStride and
      reshape.sampleCountValid and reshape.outputShapeValid and
      reshape.inputFits and reshape.outputFits and
      reshape.firstBlock == blaiTfliteReshapeNoBlock and
      reshape.inputElements == 6 and reshape.outputElements == 6)
  checkEq("NPU model TFLite reshape diagnostics value", output[5].uint32, 6)

  var badInputStride: BlaiReferenceTfliteReshapeResult
  blaiReferenceTfliteReshapeReadinessInto(
    BlaiReferenceTfliteReshape2d(
      width: 1, height: 1, inputC: 2, outputC: 2,
      inputStrideC: 1, outputStrideC: 2),
    inputLen = 2, outputLen = 2, badInputStride)
  check("NPU model TFLite reshape diagnostics input stride block",
    badInputStride.validInputShape and not badInputStride.validInputStride and
      badInputStride.firstBlock == blaiTfliteReshapeInputStride)

  var badOutputStride: BlaiReferenceTfliteReshapeResult
  blaiReferenceTfliteReshapeReadinessInto(
    BlaiReferenceTfliteReshape2d(
      width: 1, height: 1, inputC: 2, outputC: 2,
      inputStrideC: 2, outputStrideC: 1),
    inputLen = 2, outputLen = 2, badOutputStride)
  check("NPU model TFLite reshape diagnostics output stride block",
    badOutputStride.validInputStride and
      not badOutputStride.validOutputStride and
      badOutputStride.firstBlock == blaiTfliteReshapeOutputStride)

  var shortInput: BlaiReferenceTfliteReshapeResult
  blaiReferenceTfliteReshapeReadinessInto(
    BlaiReferenceTfliteReshape2d(
      width: 2, height: 1, inputC: 2, outputC: 2,
      inputStrideC: 3, outputStrideC: 2),
    inputLen = 4, outputLen = 4, shortInput)
  check("NPU model TFLite reshape diagnostics input block",
    not shortInput.inputFits and shortInput.inputElements == 5 and
      shortInput.firstBlock == blaiTfliteReshapeInputBuffer)

  var shortOutput: BlaiReferenceTfliteReshapeResult
  blaiReferenceTfliteReshapeReadinessInto(
    BlaiReferenceTfliteReshape2d(
      width: 2, height: 1, inputC: 3, outputC: 2,
      inputStrideC: 4, outputStrideC: 4),
    inputLen = 7, outputLen = 9, shortOutput)
  check("NPU model TFLite reshape diagnostics output block",
    shortOutput.inputFits and not shortOutput.outputFits and
      shortOutput.outputElements == 10 and
      shortOutput.firstBlock == blaiTfliteReshapeOutputBuffer)

proc checkMatmulDiagnostics() =
  var output: array[4, int8]
  let matmul = blaiReferenceMatmul2d(
    BlaiReferenceMatmul2d(
      width: 1, height: 2, inputC: 2, outputC: 2,
      activation: blaiActLinear),
    [1'i8, 2, 3, 4],
    [1'i8, 1, 1, -1],
    [0'i8, 0],
    output)
  check("NPU model matmul diagnostics valid",
    matmul.fits and matmul.validInputShape and matmul.inputFits and
      matmul.weightsFit and matmul.biasFits and matmul.outputFits and
      matmul.firstBlock == blaiMatmulNoBlock and
      matmul.inputElements == 4 and matmul.weightElements == 4 and
      matmul.biasElements == 2 and matmul.requiredOutputElements == 4)
  checkEq("NPU model matmul diagnostics value", output[2].uint32, 7)

  var shortInput: BlaiReferenceMatmulResult
  blaiReferenceMatmulReadinessInto(
    BlaiReferenceMatmul2d(
      width: 1, height: 2, inputC: 2, outputC: 1,
      activation: blaiActLinear),
    inputLen = 3, weightsLen = 2, biasLen = 1, outputLen = 2, shortInput)
  check("NPU model matmul diagnostics input block",
    not shortInput.inputFits and
      shortInput.firstBlock == blaiMatmulInputBuffer)

  var shortWeight: BlaiReferenceMatmulResult
  blaiReferenceMatmulReadinessInto(
    BlaiReferenceMatmul2d(
      width: 1, height: 1, inputC: 2, outputC: 2,
      activation: blaiActLinear),
    inputLen = 2, weightsLen = 3, biasLen = 2, outputLen = 2, shortWeight)
  check("NPU model matmul diagnostics weight block",
    shortWeight.inputFits and not shortWeight.weightsFit and
      shortWeight.firstBlock == blaiMatmulWeightBuffer)

  var shortBias: BlaiReferenceMatmulResult
  blaiReferenceMatmulReadinessInto(
    BlaiReferenceMatmul2d(
      width: 1, height: 1, inputC: 2, outputC: 2,
      activation: blaiActLinear),
    inputLen = 2, weightsLen = 4, biasLen = 1, outputLen = 2, shortBias)
  check("NPU model matmul diagnostics bias block",
    shortBias.weightsFit and not shortBias.biasFits and
      shortBias.firstBlock == blaiMatmulBiasBuffer)

  var shortOutput: BlaiReferenceMatmulResult
  blaiReferenceMatmulReadinessInto(
    BlaiReferenceMatmul2d(
      width: 1, height: 2, inputC: 2, outputC: 2,
      activation: blaiActLinear),
    inputLen = 4, weightsLen = 4, biasLen = 2, outputLen = 3, shortOutput)
  check("NPU model matmul diagnostics output block",
    shortOutput.biasFits and not shortOutput.outputFits and
      shortOutput.firstBlock == blaiMatmulOutputBuffer)

proc checkDepthwiseDiagnostics() =
  var output: array[4, uint8]
  let depthwise = blaiReferenceDepthwiseConv2d(
    BlaiReferenceDepthwiseConv2d(
      inputW: 2, inputH: 2, inputC: 1,
      kernelW: 1, kernelH: 1,
      strideX: 1, strideY: 1,
      channelMultiplier: 1,
      outputMultiplier: high(int32),
      activationMin: 0,
      activationMax: 255),
    [1'u8, 2, 3, 4],
    [1'u8],
    [0'i32],
    output)
  check("NPU model depthwise diagnostics valid",
    depthwise.fits and depthwise.validInputShape and
      depthwise.validOutputShape and depthwise.inputFits and
      depthwise.kernelFits and depthwise.biasFits and depthwise.outputFits and
      depthwise.firstBlock == blaiDepthwiseConvNoBlock and
      depthwise.inputElements == 4 and depthwise.kernelElements == 1 and
      depthwise.biasElements == 1 and
      depthwise.requiredOutputElements == 4)
  checkEq("NPU model depthwise diagnostics value", output[3].uint32, 4)

  var badShape: BlaiReferenceDepthwiseConvResult
  blaiReferenceDepthwiseConvReadinessInto(
    BlaiReferenceDepthwiseConv2d(
      inputW: 0, inputH: 1, inputC: 1,
      kernelW: 1, kernelH: 1,
      strideX: 1, strideY: 1,
      channelMultiplier: 1),
    inputLen = 1, kernelLen = 1, biasLen = 1, outputLen = 1, badShape)
  check("NPU model depthwise diagnostics input shape block",
    not badShape.validInputShape and
      badShape.firstBlock == blaiDepthwiseConvInputShape)

  var badOutputShape: BlaiReferenceDepthwiseConvResult
  blaiReferenceDepthwiseConvReadinessInto(
    BlaiReferenceDepthwiseConv2d(
      inputW: 1, inputH: 1, inputC: 1,
      kernelW: 3, kernelH: 3,
      strideX: 1, strideY: 1,
      channelMultiplier: 1),
    inputLen = 1, kernelLen = 9, biasLen = 1, outputLen = 1,
    badOutputShape)
  check("NPU model depthwise diagnostics output shape block",
    badOutputShape.validInputShape and not badOutputShape.validOutputShape and
      badOutputShape.firstBlock == blaiDepthwiseConvOutputShape)

  var shortInput: BlaiReferenceDepthwiseConvResult
  blaiReferenceDepthwiseConvReadinessInto(
    BlaiReferenceDepthwiseConv2d(
      inputW: 2, inputH: 2, inputC: 1,
      kernelW: 1, kernelH: 1,
      strideX: 1, strideY: 1,
      channelMultiplier: 1),
    inputLen = 3, kernelLen = 1, biasLen = 1, outputLen = 4, shortInput)
  check("NPU model depthwise diagnostics input block",
    not shortInput.inputFits and
      shortInput.firstBlock == blaiDepthwiseConvInputBuffer)

  var shortKernel: BlaiReferenceDepthwiseConvResult
  blaiReferenceDepthwiseConvReadinessInto(
    BlaiReferenceDepthwiseConv2d(
      inputW: 1, inputH: 1, inputC: 1,
      kernelW: 1, kernelH: 1,
      strideX: 1, strideY: 1,
      channelMultiplier: 2),
    inputLen = 1, kernelLen = 1, biasLen = 2, outputLen = 2, shortKernel)
  check("NPU model depthwise diagnostics kernel block",
    shortKernel.inputFits and not shortKernel.kernelFits and
      shortKernel.firstBlock == blaiDepthwiseConvKernelBuffer)

  var shortBias: BlaiReferenceDepthwiseConvResult
  blaiReferenceDepthwiseConvReadinessInto(
    BlaiReferenceDepthwiseConv2d(
      inputW: 1, inputH: 1, inputC: 1,
      kernelW: 1, kernelH: 1,
      strideX: 1, strideY: 1,
      channelMultiplier: 2),
    inputLen = 1, kernelLen = 2, biasLen = 1, outputLen = 2, shortBias)
  check("NPU model depthwise diagnostics bias block",
    shortBias.kernelFits and not shortBias.biasFits and
      shortBias.firstBlock == blaiDepthwiseConvBiasBuffer)

  var shortOutput: BlaiReferenceDepthwiseConvResult
  blaiReferenceDepthwiseConvReadinessInto(
    BlaiReferenceDepthwiseConv2d(
      inputW: 2, inputH: 1, inputC: 1,
      kernelW: 1, kernelH: 1,
      strideX: 1, strideY: 1,
      channelMultiplier: 1),
    inputLen = 2, kernelLen = 1, biasLen = 1, outputLen = 1, shortOutput)
  check("NPU model depthwise diagnostics output block",
    shortOutput.biasFits and not shortOutput.outputFits and
      shortOutput.firstBlock == blaiDepthwiseConvOutputBuffer)

proc checkFixedConvDiagnostics() =
  var output: array[4, int8]
  let conv = blaiReferenceConv2d(
    BlaiReferenceConv2d(
      inputW: 2, inputH: 2, inputC: 1, outputC: 1,
      kernelSize: 1, stride: 1, dilation: 1, groups: 1,
      activation: blaiActLinear),
    [1'i8, 2, 3, 4],
    [2'i8],
    [0'i8],
    output)
  check("NPU model fixed conv diagnostics valid",
    conv.fits and conv.validInputShape and conv.supportedKernel and
      conv.validGroupShape and conv.inputFits and conv.weightsFit and
      conv.biasFits and conv.outputFits and conv.firstBlock == blaiConvNoBlock and
      conv.inputElements == 4 and conv.weightElements == 1 and
      conv.biasElements == 1 and conv.requiredOutputElements == 4)
  checkEq("NPU model fixed conv diagnostics value", output[3].uint32, 8)

  var badShape: BlaiReferenceConvResult
  blaiReferenceConvReadinessInto(
    BlaiReferenceConv2d(
      inputW: 0, inputH: 1, inputC: 1, outputC: 1,
      kernelSize: 1, stride: 1, dilation: 1, groups: 1),
    inputLen = 1, weightLen = 1, biasLen = 1, outputLen = 1, badShape)
  check("NPU model fixed conv diagnostics input shape block",
    not badShape.validInputShape and badShape.firstBlock == blaiConvInputShape)

  var evenKernel: BlaiReferenceConvResult
  blaiReferenceConvReadinessInto(
    BlaiReferenceConv2d(
      inputW: 2, inputH: 2, inputC: 1, outputC: 1,
      kernelSize: 2, stride: 1, dilation: 1, groups: 1),
    inputLen = 4, weightLen = 4, biasLen = 1, outputLen = 4, evenKernel)
  check("NPU model fixed conv diagnostics kernel block",
    evenKernel.validInputShape and not evenKernel.supportedKernel and
      evenKernel.firstBlock == blaiConvKernel)

  var badGroup: BlaiReferenceConvResult
  blaiReferenceConvReadinessInto(
    BlaiReferenceConv2d(
      inputW: 1, inputH: 1, inputC: 3, outputC: 2,
      kernelSize: 1, stride: 1, dilation: 1, groups: 2),
    inputLen = 3, weightLen = 2, biasLen = 2, outputLen = 2, badGroup)
  check("NPU model fixed conv diagnostics group block",
    badGroup.supportedKernel and not badGroup.validGroupShape and
      badGroup.firstBlock == blaiConvGroupShape)

  var shortInput: BlaiReferenceConvResult
  blaiReferenceConvReadinessInto(
    BlaiReferenceConv2d(
      inputW: 2, inputH: 2, inputC: 1, outputC: 1,
      kernelSize: 1, stride: 1, dilation: 1, groups: 1),
    inputLen = 3, weightLen = 1, biasLen = 1, outputLen = 4, shortInput)
  check("NPU model fixed conv diagnostics input block",
    not shortInput.inputFits and shortInput.firstBlock == blaiConvInputBuffer)

  var shortWeight: BlaiReferenceConvResult
  blaiReferenceConvReadinessInto(
    BlaiReferenceConv2d(
      inputW: 1, inputH: 1, inputC: 2, outputC: 2,
      kernelSize: 1, stride: 1, dilation: 1, groups: 1),
    inputLen = 2, weightLen = 3, biasLen = 2, outputLen = 2, shortWeight)
  check("NPU model fixed conv diagnostics weight block",
    shortWeight.inputFits and not shortWeight.weightsFit and
      shortWeight.firstBlock == blaiConvWeightBuffer)

  var shortBias: BlaiReferenceConvResult
  blaiReferenceConvReadinessInto(
    BlaiReferenceConv2d(
      inputW: 1, inputH: 1, inputC: 2, outputC: 2,
      kernelSize: 1, stride: 1, dilation: 1, groups: 1),
    inputLen = 2, weightLen = 4, biasLen = 1, outputLen = 2, shortBias)
  check("NPU model fixed conv diagnostics bias block",
    shortBias.weightsFit and not shortBias.biasFits and
      shortBias.firstBlock == blaiConvBiasBuffer)

  var shortOutput: BlaiReferenceConvResult
  blaiReferenceConvReadinessInto(
    BlaiReferenceConv2d(
      inputW: 2, inputH: 1, inputC: 1, outputC: 1,
      kernelSize: 1, stride: 1, dilation: 1, groups: 1),
    inputLen = 2, weightLen = 1, biasLen = 1, outputLen = 1, shortOutput)
  check("NPU model fixed conv diagnostics output block",
    shortOutput.biasFits and not shortOutput.outputFits and
      shortOutput.firstBlock == blaiConvOutputBuffer)

proc checkFixedConvMaxDiagnostics() =
  var output: array[4, int8]
  let convMax = blaiReferenceConvMax2d(
    BlaiReferenceConvMax2d(
      inputW: 3, inputH: 3, inputC: 1, outputC: 1,
      kernelSize: 1, stride: 1, dilation: 1, groups: 1,
      activation: blaiActLinear),
    [1'i8, 2, 3, 4, 5, 6, 7, 8, 9],
    [1'i8],
    [0'i8],
    output)
  check("NPU model fixed conv max diagnostics valid",
    convMax.fits and convMax.validInputShape and convMax.supportedKernel and
      convMax.validGroupShape and convMax.validOutputShape and
      convMax.inputFits and convMax.weightsFit and convMax.biasFits and
      convMax.outputFits and convMax.firstBlock == blaiConvMaxNoBlock and
      convMax.inputElements == 9 and convMax.weightElements == 1 and
      convMax.biasElements == 1 and convMax.requiredOutputElements == 4)
  checkEq("NPU model fixed conv max diagnostics value", output[3].uint32, 9)

  var badShape: BlaiReferenceConvMaxResult
  blaiReferenceConvMaxReadinessInto(
    BlaiReferenceConvMax2d(
      inputW: 0, inputH: 1, inputC: 1, outputC: 1,
      kernelSize: 1, stride: 1, dilation: 1, groups: 1),
    inputLen = 1, weightLen = 1, biasLen = 1, outputLen = 1, badShape)
  check("NPU model fixed conv max diagnostics input shape block",
    not badShape.validInputShape and
      badShape.firstBlock == blaiConvMaxInputShape)

  var evenKernel: BlaiReferenceConvMaxResult
  blaiReferenceConvMaxReadinessInto(
    BlaiReferenceConvMax2d(
      inputW: 2, inputH: 2, inputC: 1, outputC: 1,
      kernelSize: 2, stride: 1, dilation: 1, groups: 1),
    inputLen = 4, weightLen = 4, biasLen = 1, outputLen = 1, evenKernel)
  check("NPU model fixed conv max diagnostics kernel block",
    evenKernel.validInputShape and not evenKernel.supportedKernel and
      evenKernel.firstBlock == blaiConvMaxKernel)

  var badGroup: BlaiReferenceConvMaxResult
  blaiReferenceConvMaxReadinessInto(
    BlaiReferenceConvMax2d(
      inputW: 1, inputH: 1, inputC: 3, outputC: 2,
      kernelSize: 1, stride: 1, dilation: 1, groups: 2),
    inputLen = 3, weightLen = 2, biasLen = 2, outputLen = 2, badGroup)
  check("NPU model fixed conv max diagnostics group block",
    badGroup.supportedKernel and not badGroup.validGroupShape and
      badGroup.firstBlock == blaiConvMaxGroupShape)

  var badOutputShape: BlaiReferenceConvMaxResult
  blaiReferenceConvMaxReadinessInto(
    BlaiReferenceConvMax2d(
      inputW: 3, inputH: 3, inputC: 1, outputC: 1,
      outputW: 1, outputH: 2,
      kernelSize: 1, stride: 1, dilation: 1, groups: 1),
    inputLen = 9, weightLen = 1, biasLen = 1, outputLen = 4, badOutputShape)
  check("NPU model fixed conv max diagnostics output shape block",
    badOutputShape.validGroupShape and not badOutputShape.validOutputShape and
      badOutputShape.firstBlock == blaiConvMaxOutputShape)

  var shortInput: BlaiReferenceConvMaxResult
  blaiReferenceConvMaxReadinessInto(
    BlaiReferenceConvMax2d(
      inputW: 2, inputH: 2, inputC: 1, outputC: 1,
      kernelSize: 1, stride: 1, dilation: 1, groups: 1),
    inputLen = 3, weightLen = 1, biasLen = 1, outputLen = 1, shortInput)
  check("NPU model fixed conv max diagnostics input block",
    not shortInput.inputFits and
      shortInput.firstBlock == blaiConvMaxInputBuffer)

  var shortWeight: BlaiReferenceConvMaxResult
  blaiReferenceConvMaxReadinessInto(
    BlaiReferenceConvMax2d(
      inputW: 1, inputH: 1, inputC: 2, outputC: 2,
      kernelSize: 1, stride: 1, dilation: 1, groups: 1),
    inputLen = 2, weightLen = 3, biasLen = 2, outputLen = 2, shortWeight)
  check("NPU model fixed conv max diagnostics weight block",
    shortWeight.inputFits and not shortWeight.weightsFit and
      shortWeight.firstBlock == blaiConvMaxWeightBuffer)

  var shortBias: BlaiReferenceConvMaxResult
  blaiReferenceConvMaxReadinessInto(
    BlaiReferenceConvMax2d(
      inputW: 1, inputH: 1, inputC: 2, outputC: 2,
      kernelSize: 1, stride: 1, dilation: 1, groups: 1),
    inputLen = 2, weightLen = 4, biasLen = 1, outputLen = 2, shortBias)
  check("NPU model fixed conv max diagnostics bias block",
    shortBias.weightsFit and not shortBias.biasFits and
      shortBias.firstBlock == blaiConvMaxBiasBuffer)

  var shortOutput: BlaiReferenceConvMaxResult
  blaiReferenceConvMaxReadinessInto(
    BlaiReferenceConvMax2d(
      inputW: 3, inputH: 3, inputC: 1, outputC: 1,
      kernelSize: 1, stride: 1, dilation: 1, groups: 1),
    inputLen = 9, weightLen = 1, biasLen = 1, outputLen = 3, shortOutput)
  check("NPU model fixed conv max diagnostics output block",
    shortOutput.biasFits and not shortOutput.outputFits and
      shortOutput.firstBlock == blaiConvMaxOutputBuffer)

proc checkFixedLayerDispatchDiagnostics() =
  var output: array[1, int8]
  let conv = blaiReferenceFixedLayer2d(
    BlaiCpuInstLayer64(
      layerType: ord(blaiConvolutional).int32,
      activation: ord(blaiActLinear).int32,
      w: 1, h: 1, c: 1, outC: 1,
      size: 1, stride: 1, dilation: 1, groups: 1),
    [12'i8],
    [],
    [2'i8],
    [0'i8],
    output)
  check("NPU model fixed layer dispatch diagnostics valid",
    conv.supported and conv.fits and
      conv.firstBlock == blaiFixedLayerNoBlock and
      conv.convBlock == blaiConvNoBlock)
  checkEq("NPU model fixed layer dispatch diagnostics value",
    output[0].uint32, 24)

  var shortWeightOutput: array[2, int8]
  let shortWeight = blaiReferenceFixedLayer2d(
    BlaiCpuInstLayer64(
      layerType: ord(blaiConvolutional).int32,
      activation: ord(blaiActLinear).int32,
      w: 1, h: 1, c: 2, outC: 2,
      size: 1, stride: 1, dilation: 1, groups: 1),
    [1'i8, 2],
    [],
    [1'i8, 2, 3],
    [0'i8, 0],
    shortWeightOutput)
  check("NPU model fixed layer dispatch diagnostics conv block",
    shortWeight.supported and not shortWeight.fits and
      shortWeight.firstBlock == blaiFixedLayerConv and
      shortWeight.convBlock == blaiConvWeightBuffer)

  var unsupportedOutput: array[1, int8]
  let unsupported = blaiReferenceFixedLayer2d(
    BlaiCpuInstLayer64(layerType: ord(blaiRoute).int32),
    [], [], [], [], unsupportedOutput)
  check("NPU model fixed layer dispatch diagnostics unsupported block",
    not unsupported.supported and not unsupported.fits and
      unsupported.firstBlock == blaiFixedLayerUnsupportedLayer)

proc checkTfliteLayerDispatchDiagnostics() =
  var output: array[1, uint8]
  let conv = blaiReferenceTfliteLayer2d(
    BlaiCpuInstLayer64(
      layerType: ord(blaiConvolutional).int32,
      w: 1, h: 1, c: 1, outC: 1,
      size: 1, stride: 1, dilation: 1, groups: 1,
      tfOutputMultiplier: high(int32),
      quantizedActivationMax: 255),
    [3'u8],
    [],
    [4'u8],
    [],
    output)
  check("NPU model TFLite layer dispatch diagnostics valid",
    conv.supported and conv.fits and
      conv.firstBlock == blaiTfliteLayerNoBlock and
      conv.convBlock == blaiTfliteScalarConvNoBlock)
  checkEq("NPU model TFLite layer dispatch diagnostics value",
    output[0].uint32, 12)

  var shortKernelOutput: array[2, uint8]
  let shortKernel = blaiReferenceTfliteLayer2d(
    BlaiCpuInstLayer64(
      layerType: ord(blaiConvolutional).int32,
      w: 1, h: 1, c: 2, outC: 2,
      size: 1, stride: 1, dilation: 1, groups: 1,
      tfOutputMultiplier: high(int32),
      quantizedActivationMax: 255),
    [3'u8, 5],
    [],
    [4'u8, 6, 8],
    [],
    shortKernelOutput)
  check("NPU model TFLite layer dispatch diagnostics conv block",
    shortKernel.supported and not shortKernel.fits and
      shortKernel.firstBlock == blaiTfliteLayerConv and
      shortKernel.convBlock == blaiTfliteScalarConvKernelBuffer)

  var transformOutput: array[1, uint8]
  let transform = blaiReferenceTfliteTransformLayer2d(
    BlaiCpuInstLayer64(
      layerType: ord(blaiMean).int32,
      w: 2, h: 1, c: 1,
      tfOutputMultiplier: high(int32),
      tfOutputShift: 0),
    [10'u8, 30],
    transformOutput)
  check("NPU model TFLite layer dispatch diagnostics transform block",
    transform.supported and transform.fits and
      transform.firstBlock == blaiTfliteLayerNoBlock and
      transform.meanBlock == blaiTfliteMeanNoBlock)
  checkEq("NPU model TFLite layer dispatch diagnostics transform value",
    transformOutput[0].uint32, 20)

  var reshapeOutput: array[4, uint8]
  let reshape = blaiReferenceTfliteTransformLayer2d(
    BlaiCpuInstLayer64(
      layerType: ord(blaiReshape).int32,
      w: 2, h: 1, c: 2,
      outW: 1, outH: 1, outC: 4),
    [1'u8, 2, 3, 4],
    reshapeOutput)
  check("NPU model TFLite layer dispatch diagnostics reshape block",
    reshape.supported and reshape.fits and
      reshape.firstBlock == blaiTfliteLayerNoBlock and
      reshape.reshapeBlock == blaiTfliteReshapeNoBlock)

  var unsupportedOutput: array[1, uint8]
  let unsupported = blaiReferenceTfliteTransformLayer2d(
    BlaiCpuInstLayer64(layerType: ord(blaiDequantize).int32),
    [],
    unsupportedOutput)
  check("NPU model TFLite layer dispatch diagnostics unsupported block",
    not unsupported.supported and not unsupported.fits and
      unsupported.firstBlock == blaiTfliteLayerUnsupportedLayer)

  var dequantOutput: array[4, float32]
  let dequant = blaiReferenceTfliteDequantizeLayer2d(
    BlaiCpuInstLayer64(
      layerType: ord(blaiDequantize).int32,
      w: 2, h: 1, c: 2,
      tfInput1Offset: 10,
      inputScale: 0.5'f32),
    [8'u8, 10, 12, 14],
    dequantOutput)
  check("NPU model TFLite layer dispatch diagnostics float valid",
    dequant.supported and dequant.fits and
      dequant.firstBlock == blaiTfliteFloatLayerNoBlock and
      dequant.dequantizeBlock == blaiTfliteDequantizeNoBlock and
      dequant.outputW == 2 and dequant.outputH == 1 and dequant.outputC == 2)
  check("NPU model TFLite layer dispatch diagnostics float value",
    dequantOutput[2] == 1.0'f32)

  var floatOutput: array[1, float32]
  let wrongFloat = blaiReferenceTfliteDequantizeLayer2d(
    BlaiCpuInstLayer64(layerType: ord(blaiLogisticLayer).int32),
    [],
    floatOutput)
  check("NPU model TFLite layer dispatch diagnostics float unsupported block",
    not wrongFloat.supported and not wrongFloat.fits and
      wrongFloat.firstBlock == blaiTfliteFloatLayerUnsupportedLayer)

proc checkTfliteConvDiagnostics() =
  var output: array[4, uint8]
  let conv = blaiReferenceTfliteConv2d(
    BlaiReferenceTfliteConv2d(
      inputW: 2, inputH: 2, inputC: 1, outputC: 1,
      kernelW: 1, kernelH: 1,
      strideX: 1, strideY: 1,
      outputMultiplier: high(int32),
      activationMin: 0,
      activationMax: 255),
    [1'u8, 2, 3, 4],
    [2'u8],
    [0'i32],
    output)
  check("NPU model TFLite conv diagnostics valid",
    conv.fits and conv.validInputShape and conv.validOutputShape and
      conv.inputFits and conv.kernelFits and conv.biasFits and
      conv.outputFits and conv.firstBlock == blaiTfliteConvNoBlock and
      conv.inputElements == 4 and conv.kernelElements == 1 and
      conv.biasElements == 1 and conv.requiredOutputElements == 4)
  checkEq("NPU model TFLite conv diagnostics value", output[3].uint32, 8)

  var badShape: BlaiReferenceTfliteConvResult
  blaiReferenceTfliteConvReadinessInto(
    BlaiReferenceTfliteConv2d(
      inputW: 0, inputH: 1, inputC: 1, outputC: 1,
      kernelW: 1, kernelH: 1,
      strideX: 1, strideY: 1),
    inputLen = 1, kernelLen = 1, biasLen = 1, outputLen = 1, badShape)
  check("NPU model TFLite conv diagnostics input shape block",
    not badShape.validInputShape and
      badShape.firstBlock == blaiTfliteConvInputShape)

  var badOutputShape: BlaiReferenceTfliteConvResult
  blaiReferenceTfliteConvReadinessInto(
    BlaiReferenceTfliteConv2d(
      inputW: 1, inputH: 1, inputC: 1, outputC: 1,
      kernelW: 3, kernelH: 3,
      strideX: 1, strideY: 1),
    inputLen = 1, kernelLen = 9, biasLen = 1, outputLen = 1,
    badOutputShape)
  check("NPU model TFLite conv diagnostics output shape block",
    badOutputShape.validInputShape and not badOutputShape.validOutputShape and
      badOutputShape.firstBlock == blaiTfliteConvOutputShape)

  var shortInput: BlaiReferenceTfliteConvResult
  blaiReferenceTfliteConvReadinessInto(
    BlaiReferenceTfliteConv2d(
      inputW: 2, inputH: 2, inputC: 1, outputC: 1,
      kernelW: 1, kernelH: 1,
      strideX: 1, strideY: 1),
    inputLen = 3, kernelLen = 1, biasLen = 1, outputLen = 4, shortInput)
  check("NPU model TFLite conv diagnostics input block",
    not shortInput.inputFits and
      shortInput.firstBlock == blaiTfliteConvInputBuffer)

  var shortKernel: BlaiReferenceTfliteConvResult
  blaiReferenceTfliteConvReadinessInto(
    BlaiReferenceTfliteConv2d(
      inputW: 1, inputH: 1, inputC: 2, outputC: 2,
      kernelW: 1, kernelH: 1,
      strideX: 1, strideY: 1),
    inputLen = 2, kernelLen = 3, biasLen = 2, outputLen = 2, shortKernel)
  check("NPU model TFLite conv diagnostics kernel block",
    shortKernel.inputFits and not shortKernel.kernelFits and
      shortKernel.firstBlock == blaiTfliteConvKernelBuffer)

  var shortBias: BlaiReferenceTfliteConvResult
  blaiReferenceTfliteConvReadinessInto(
    BlaiReferenceTfliteConv2d(
      inputW: 1, inputH: 1, inputC: 2, outputC: 2,
      kernelW: 1, kernelH: 1,
      strideX: 1, strideY: 1),
    inputLen = 2, kernelLen = 4, biasLen = 1, outputLen = 2, shortBias)
  check("NPU model TFLite conv diagnostics bias block",
    shortBias.kernelFits and not shortBias.biasFits and
      shortBias.firstBlock == blaiTfliteConvBiasBuffer)

  var shortOutput: BlaiReferenceTfliteConvResult
  blaiReferenceTfliteConvReadinessInto(
    BlaiReferenceTfliteConv2d(
      inputW: 2, inputH: 1, inputC: 1, outputC: 1,
      kernelW: 1, kernelH: 1,
      strideX: 1, strideY: 1),
    inputLen = 2, kernelLen = 1, biasLen = 1, outputLen = 1, shortOutput)
  check("NPU model TFLite conv diagnostics output block",
    shortOutput.biasFits and not shortOutput.outputFits and
      shortOutput.firstBlock == blaiTfliteConvOutputBuffer)

proc checkTfliteScalarConvDiagnostics() =
  var output: array[9, uint8]
  let conv = blaiReferenceTfliteScalarConv2d(
    BlaiReferenceTfliteScalarConv2d(
      inputW: 3, inputH: 3, inputC: 1, outputC: 1,
      kernelSize: 3, stride: 1, dilation: 1, groups: 1,
      outputMultiplier: high(int32),
      activationMin: 0, activationMax: 255,
      useBias: true),
    [1'u8, 2, 3, 4, 5, 6, 7, 8, 9],
    [1'u8, 0, 0, 0, 1, 0, 0, 0, 1],
    [1'i32],
    output)
  check("NPU model TFLite scalar conv diagnostics valid",
    conv.fits and conv.supported and conv.validInputShape and
      conv.validGroupShape and conv.validOutputShape and conv.inputFits and
      conv.kernelFits and conv.biasFits and conv.outputFits and
      conv.firstBlock == blaiTfliteScalarConvNoBlock and
      conv.inputElements == 9 and conv.kernelElements == 9 and
      conv.biasElements == 1 and conv.requiredOutputElements == 9)
  checkEq("NPU model TFLite scalar conv diagnostics value", output[4].uint32, 16)

  var badKernel: BlaiReferenceTfliteScalarConvResult
  blaiReferenceTfliteScalarConvReadinessInto(
    BlaiReferenceTfliteScalarConv2d(
      inputW: 2, inputH: 2, inputC: 1, outputC: 1,
      kernelSize: 2, stride: 1, groups: 1),
    inputLen = 4, kernelLen = 4, biasLen = 0, outputLen = 4, badKernel)
  check("NPU model TFLite scalar conv diagnostics kernel support block",
    not badKernel.supported and
      badKernel.firstBlock == blaiTfliteScalarConvUnsupportedKernel)

  var badShape: BlaiReferenceTfliteScalarConvResult
  blaiReferenceTfliteScalarConvReadinessInto(
    BlaiReferenceTfliteScalarConv2d(
      inputW: 0, inputH: 1, inputC: 1, outputC: 1,
      kernelSize: 1, stride: 1, groups: 1),
    inputLen = 1, kernelLen = 1, biasLen = 0, outputLen = 1, badShape)
  check("NPU model TFLite scalar conv diagnostics input shape block",
    badShape.supported and not badShape.validInputShape and
      badShape.firstBlock == blaiTfliteScalarConvInputShape)

  var badGroup: BlaiReferenceTfliteScalarConvResult
  blaiReferenceTfliteScalarConvReadinessInto(
    BlaiReferenceTfliteScalarConv2d(
      inputW: 1, inputH: 1, inputC: 3, outputC: 2,
      kernelSize: 1, stride: 1, groups: 2),
    inputLen = 3, kernelLen = 2, biasLen = 0, outputLen = 2, badGroup)
  check("NPU model TFLite scalar conv diagnostics group block",
    badGroup.validInputShape and not badGroup.validGroupShape and
      badGroup.firstBlock == blaiTfliteScalarConvGroupShape)

  var badOutputShape: BlaiReferenceTfliteScalarConvResult
  blaiReferenceTfliteScalarConvReadinessInto(
    BlaiReferenceTfliteScalarConv2d(
      inputW: 3, inputH: 3, inputC: 1, outputC: 1,
      outputW: 2, outputH: 3,
      kernelSize: 1, stride: 1, groups: 1),
    inputLen = 9, kernelLen = 1, biasLen = 0, outputLen = 9, badOutputShape)
  check("NPU model TFLite scalar conv diagnostics output shape block",
    badOutputShape.validGroupShape and
      not badOutputShape.validOutputShape and
      badOutputShape.firstBlock == blaiTfliteScalarConvOutputShape)

  var shortInput: BlaiReferenceTfliteScalarConvResult
  blaiReferenceTfliteScalarConvReadinessInto(
    BlaiReferenceTfliteScalarConv2d(
      inputW: 2, inputH: 2, inputC: 1, outputC: 1,
      kernelSize: 1, stride: 1, groups: 1),
    inputLen = 3, kernelLen = 1, biasLen = 0, outputLen = 4, shortInput)
  check("NPU model TFLite scalar conv diagnostics input block",
    not shortInput.inputFits and
      shortInput.firstBlock == blaiTfliteScalarConvInputBuffer)

  var shortKernel: BlaiReferenceTfliteScalarConvResult
  blaiReferenceTfliteScalarConvReadinessInto(
    BlaiReferenceTfliteScalarConv2d(
      inputW: 1, inputH: 1, inputC: 2, outputC: 2,
      kernelSize: 1, stride: 1, groups: 1),
    inputLen = 2, kernelLen = 3, biasLen = 0, outputLen = 2, shortKernel)
  check("NPU model TFLite scalar conv diagnostics kernel block",
    shortKernel.inputFits and not shortKernel.kernelFits and
      shortKernel.firstBlock == blaiTfliteScalarConvKernelBuffer)

  var shortBias: BlaiReferenceTfliteScalarConvResult
  blaiReferenceTfliteScalarConvReadinessInto(
    BlaiReferenceTfliteScalarConv2d(
      inputW: 1, inputH: 1, inputC: 1, outputC: 2,
      kernelSize: 1, stride: 1, groups: 1,
      useBias: true),
    inputLen = 1, kernelLen = 2, biasLen = 1, outputLen = 2, shortBias)
  check("NPU model TFLite scalar conv diagnostics bias block",
    shortBias.kernelFits and not shortBias.biasFits and
      shortBias.firstBlock == blaiTfliteScalarConvBiasBuffer)

  var shortOutput: BlaiReferenceTfliteScalarConvResult
  blaiReferenceTfliteScalarConvReadinessInto(
    BlaiReferenceTfliteScalarConv2d(
      inputW: 2, inputH: 1, inputC: 1, outputC: 1,
      kernelSize: 1, stride: 1, groups: 1),
    inputLen = 2, kernelLen = 1, biasLen = 0, outputLen = 1, shortOutput)
  check("NPU model TFLite scalar conv diagnostics output block",
    shortOutput.biasFits and not shortOutput.outputFits and
      shortOutput.firstBlock == blaiTfliteScalarConvOutputBuffer)

proc checkTfliteScalarConvMaxDiagnostics() =
  var output: array[4, uint8]
  let convMax = blaiReferenceTfliteScalarConvMax2d(
    BlaiReferenceTfliteScalarConvMax2d(
      inputW: 3, inputH: 3, inputC: 1, outputC: 1,
      kernelSize: 1, stride: 1, dilation: 1, groups: 1,
      outputMultiplier: high(int32),
      activationMin: 0, activationMax: 255),
    [1'u8, 2, 3, 4, 5, 6, 7, 8, 9],
    [1'u8],
    [],
    output)
  check("NPU model TFLite scalar conv max diagnostics valid",
    convMax.fits and convMax.supported and convMax.validInputShape and
      convMax.validGroupShape and convMax.validOutputShape and
      convMax.inputFits and convMax.kernelFits and convMax.biasFits and
      convMax.outputFits and
      convMax.firstBlock == blaiTfliteScalarConvMaxNoBlock and
      convMax.inputElements == 9 and convMax.kernelElements == 1 and
      convMax.biasElements == 0 and convMax.requiredOutputElements == 4)
  checkEq("NPU model TFLite scalar conv max diagnostics value",
    output[3].uint32, 9)

  var badKernel: BlaiReferenceTfliteScalarConvMaxResult
  blaiReferenceTfliteScalarConvMaxReadinessInto(
    BlaiReferenceTfliteScalarConvMax2d(
      inputW: 2, inputH: 2, inputC: 1, outputC: 1,
      kernelSize: 2, stride: 1, groups: 1),
    inputLen = 4, kernelLen = 4, biasLen = 0, outputLen = 1, badKernel)
  check("NPU model TFLite scalar conv max diagnostics kernel support block",
    not badKernel.supported and
      badKernel.firstBlock == blaiTfliteScalarConvMaxUnsupportedKernel)

  var badShape: BlaiReferenceTfliteScalarConvMaxResult
  blaiReferenceTfliteScalarConvMaxReadinessInto(
    BlaiReferenceTfliteScalarConvMax2d(
      inputW: 0, inputH: 1, inputC: 1, outputC: 1,
      kernelSize: 1, stride: 1, groups: 1),
    inputLen = 1, kernelLen = 1, biasLen = 0, outputLen = 1, badShape)
  check("NPU model TFLite scalar conv max diagnostics input shape block",
    badShape.supported and not badShape.validInputShape and
      badShape.firstBlock == blaiTfliteScalarConvMaxInputShape)

  var badGroup: BlaiReferenceTfliteScalarConvMaxResult
  blaiReferenceTfliteScalarConvMaxReadinessInto(
    BlaiReferenceTfliteScalarConvMax2d(
      inputW: 1, inputH: 1, inputC: 3, outputC: 2,
      kernelSize: 1, stride: 1, groups: 2),
    inputLen = 3, kernelLen = 2, biasLen = 0, outputLen = 2, badGroup)
  check("NPU model TFLite scalar conv max diagnostics group block",
    badGroup.validInputShape and not badGroup.validGroupShape and
      badGroup.firstBlock == blaiTfliteScalarConvMaxGroupShape)

  var badOutputShape: BlaiReferenceTfliteScalarConvMaxResult
  blaiReferenceTfliteScalarConvMaxReadinessInto(
    BlaiReferenceTfliteScalarConvMax2d(
      inputW: 3, inputH: 3, inputC: 1, outputC: 1,
      outputW: 1, outputH: 2,
      kernelSize: 1, stride: 1, groups: 1),
    inputLen = 9, kernelLen = 1, biasLen = 0, outputLen = 4, badOutputShape)
  check("NPU model TFLite scalar conv max diagnostics output shape block",
    badOutputShape.validGroupShape and
      not badOutputShape.validOutputShape and
      badOutputShape.firstBlock == blaiTfliteScalarConvMaxOutputShape)

  var shortInput: BlaiReferenceTfliteScalarConvMaxResult
  blaiReferenceTfliteScalarConvMaxReadinessInto(
    BlaiReferenceTfliteScalarConvMax2d(
      inputW: 2, inputH: 2, inputC: 1, outputC: 1,
      kernelSize: 1, stride: 1, groups: 1),
    inputLen = 3, kernelLen = 1, biasLen = 0, outputLen = 1, shortInput)
  check("NPU model TFLite scalar conv max diagnostics input block",
    not shortInput.inputFits and
      shortInput.firstBlock == blaiTfliteScalarConvMaxInputBuffer)

  var shortKernel: BlaiReferenceTfliteScalarConvMaxResult
  blaiReferenceTfliteScalarConvMaxReadinessInto(
    BlaiReferenceTfliteScalarConvMax2d(
      inputW: 1, inputH: 1, inputC: 2, outputC: 2,
      kernelSize: 1, stride: 1, groups: 1),
    inputLen = 2, kernelLen = 3, biasLen = 0, outputLen = 2, shortKernel)
  check("NPU model TFLite scalar conv max diagnostics kernel block",
    shortKernel.inputFits and not shortKernel.kernelFits and
      shortKernel.firstBlock == blaiTfliteScalarConvMaxKernelBuffer)

  var shortBias: BlaiReferenceTfliteScalarConvMaxResult
  blaiReferenceTfliteScalarConvMaxReadinessInto(
    BlaiReferenceTfliteScalarConvMax2d(
      inputW: 1, inputH: 1, inputC: 1, outputC: 2,
      kernelSize: 1, stride: 1, groups: 1,
      useBias: true),
    inputLen = 1, kernelLen = 2, biasLen = 1, outputLen = 2, shortBias)
  check("NPU model TFLite scalar conv max diagnostics bias block",
    shortBias.kernelFits and not shortBias.biasFits and
      shortBias.firstBlock == blaiTfliteScalarConvMaxBiasBuffer)

  var shortOutput: BlaiReferenceTfliteScalarConvMaxResult
  blaiReferenceTfliteScalarConvMaxReadinessInto(
    BlaiReferenceTfliteScalarConvMax2d(
      inputW: 3, inputH: 3, inputC: 1, outputC: 1,
      kernelSize: 1, stride: 1, groups: 1),
    inputLen = 9, kernelLen = 1, biasLen = 0, outputLen = 3, shortOutput)
  check("NPU model TFLite scalar conv max diagnostics output block",
    shortOutput.biasFits and not shortOutput.outputFits and
      shortOutput.firstBlock == blaiTfliteScalarConvMaxOutputBuffer)

proc main() {.exportc, cdecl.} =
  systemInit()
  heapInit()
  enableAllPeriphClocks()
  mmPowerOn()

  enablePeriphClock(periphUart0)
  setMcuXclkSource(mcuXclkXtal)
  setUartClock(true, uartClkXclk, 0)
  gpioSetupUart(ConsoleUartTxPin, ConsoleUartRxPin)
  console = initUart(uart0, UartConfig(
    baudRate: ConsoleBaud,
    dataBits: data8,
    stopBits: stop1,
    parity: parityNone,
  ), ConsoleClkHz)

  discard console.sendLine("")
  discard console.sendLine("=== BL808 NPU Model Smoke Test ===")

  checkSequentialParsedModels()
  checkParsedSingleLayerDiagnostics()
  checkFixedPreviousActivationShortcut()
  checkTflitePreviousActivationShortcut()
  checkForwardRunSequence()
  checkForwardWorkspaceExecution()
  checkForwardWorkspaceFixtureValidation()
  checkForwardWorkspaceAddressFixtureValidation()
  checkParsedForwardWorkspaceExecution()
  checkParsedForwardWorkspaceAddressFixtureValidation()
  checkParsedForwardWorkspaceAddressFixtureOracleValidation()
  checkParsedWorkspaceOracleValidationReadiness()
  checkTfliteParsedWorkspaceOracleAddressFixture()
  checkFixedParsedWorkspaceOracleAddressFixture()
  checkParsedConfiguredWorkspaceAddressFixtureGuard()
  checkTfliteConfiguredWorkspaceOracleBuffer()
  checkTfliteConfiguredWorkspaceOracleBufferMaterialized()
  checkFixedConfiguredWorkspaceOracleBuffer()
  checkFixedConfiguredWorkspaceOracleBufferMaterialized()
  checkParsedConfiguredWorkspaceOracleExecutionGuard()
  checkParsedConfiguredWorkspaceActiveMaterializedProbe()
  checkConfiguredExecutionGuards()
  checkCacheAndCompletionPlans()
  checkForwardWeightMaterialization()
  checkSdkHelperConvShapePlan()
  checkTflitePadDiagnostics()
  checkTfliteTransposeDiagnostics()
  checkMaxPoolDiagnostics()
  checkAvgPoolDiagnostics()
  checkTfliteMeanDiagnostics()
  checkTfliteSoftmaxDiagnostics()
  checkTfliteTransposeLkDiagnostics()
  checkTflitePreTransconvDiagnostics()
  checkTfliteDequantizeDiagnostics()
  checkTfliteLogisticDiagnostics()
  checkUpsampleDiagnostics()
  checkRouteUpsampleDiagnostics()
  checkRouteConcatDiagnostics()
  checkRouteMaxDiagnostics()
  checkShortcutDiagnostics()
  checkTfliteShortcutDiagnostics()
  checkTfliteRouteDiagnostics()
  checkTfliteRouteMaxDiagnostics()
  checkTfliteRouteWDiagnostics()
  checkTfliteReshapeDiagnostics()
  checkMatmulDiagnostics()
  checkDepthwiseDiagnostics()
  checkFixedConvDiagnostics()
  checkFixedConvMaxDiagnostics()
  checkFixedLayerDispatchDiagnostics()
  checkTfliteLayerDispatchDiagnostics()
  checkTfliteConvDiagnostics()
  checkTfliteScalarConvDiagnostics()
  checkTfliteScalarConvMaxDiagnostics()
  checkForwardTensorIo()

  if failed == 0:
    discard console.sendLine("[PASS] NPU model smoke complete")
  else:
    discard console.sendString("[FAIL] NPU model smoke failed count=")
    console.sendHex32(failed.uint32)
    discard console.sendLine("")

  while true:
    discard
