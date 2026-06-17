## Focused BL808 BLAI/NPU CPU instruction parser smoke test.
##
## This validates recovered DSP/CPU model instruction decoding and typed
## sidecar projection on-device without touching the larger NPU smoke image.

import bl808/startup
import bl808/glb
import bl808/gpio
import bl808/uart
import bl808/npu
import bl808/panicoverride
import bl808/kernel/alloc
import bl808/kernel/jtaglog

const
  ConsoleUartTxPin = 14'u32
  ConsoleUartRxPin = 15'u32
  ConsoleBaud {.intdefine.} = 230_400'u32
  ConsoleClkHz {.intdefine.} = 40_000_000'u32

var
  console: Uart
  failed = 0

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

proc checkFloatBits(label: string, got, expected: float32) =
  checkEq(label, cast[uint32](got), cast[uint32](expected))

proc sameFetchDescriptorOperands(a, b: BlaiFetchDescriptorOperands): bool =
  a.kind == b.kind and
    a.layerType == b.layerType and
    a.multiInputC2 == b.multiInputC2 and
    a.alignedFirstInputChannels == b.alignedFirstInputChannels and
    a.c2 == b.c2 and
    a.maxPoolLinePatchExtra == b.maxPoolLinePatchExtra and
    a.weightPatchExtra == b.weightPatchExtra and
    a.linePatchExtra == b.linePatchExtra and
    a.groupedExtra == b.groupedExtra and
    a.strideExtra == b.strideExtra and
    a.dilationExtra == b.dilationExtra and
    a.includeExtra == b.includeExtra

proc sameLinePatchPlan(a, b: BlaiMemAllocLinePatchPlan): bool =
  if a.fits != b.fits or
      a.start.layerType != b.start.layerType or
      a.start.routed != b.start.routed or
      a.start.routeChannels != b.start.routeChannels or
      a.start.inputWidth != b.start.inputWidth or
      a.start.outputWidth != b.start.outputWidth or
      a.start.outputChannels != b.start.outputChannels or
      a.start.shortcutDoubleInput != b.start.shortcutDoubleInput or
      a.start.suppressConvOutput != b.start.suppressConvOutput or
      a.start.inputBytes != b.start.inputBytes or
      a.start.outputBytes != b.start.outputBytes or
      a.start.inputPatchCount != b.start.inputPatchCount or
      a.start.outputPatchCount != b.start.outputPatchCount or
      a.start.startPatchCount != b.start.startPatchCount or
      a.startPatchCount != b.startPatchCount or
      a.linePatchCount != b.linePatchCount or
      a.inputLineBytes != b.inputLineBytes or
      a.outputLineBytes != b.outputLineBytes:
    return false
  for i in 0 ..< a.linePatchW.len:
    if a.linePatchW[i] != b.linePatchW[i]:
      return false
  true

proc checkParseResultLifecycle() =
  var parsed: BlaiCpuModelParseResult
  blaiInitCpuModelParseResult(parsed)
  check("NPU parse lifecycle init malformed",
    parsed.firstMalformedRecord == -1)
  check("NPU parse lifecycle init unsupported",
    parsed.firstUnsupportedRecord == -1)

  blaiMarkCpuModelParseUnsupported(parsed, 4, blaiCpuYoloInfo)
  blaiMarkCpuModelParseUnsupported(parsed, 6, blaiCpuExtraLayer)
  checkEq("NPU parse lifecycle unsupported count",
    parsed.unsupportedRecordCount, 2)
  checkEq("NPU parse lifecycle unsupported first",
    parsed.firstUnsupportedRecord.uint32, 4)
  checkEq("NPU parse lifecycle unsupported kind",
    ord(parsed.firstUnsupportedKind).uint32, ord(blaiCpuYoloInfo).uint32)

  blaiMarkCpuModelParseMalformed(parsed, 9)
  blaiMarkCpuModelParseMalformed(parsed, 10)
  blaiFinishCpuModelParseResult(parsed, true, 11)
  check("NPU parse lifecycle malformed", parsed.malformed)
  checkEq("NPU parse lifecycle malformed first",
    parsed.firstMalformedRecord.uint32, 9)
  check("NPU parse lifecycle blocked", not parsed.complete)

  var complete: BlaiCpuModelParseResult
  blaiInitCpuModelParseResult(complete)
  complete.hasHeader = true
  complete.declaredLayerCount = 1
  complete.parsedLayerCount = 1
  blaiFinishCpuModelParseResult(complete, false, 5)
  check("NPU parse lifecycle complete", complete.complete)

proc fakeForwardLayerExecutor(
    plan: BlaiForwardNpuRunPlan,
    layerIndex: uint32): BlaiForwardNpuExecuteResult =
  discard layerIndex
  result.runnable = plan.runnable
  result.configurable = plan.configurable
  result.cacheApplied = plan.configurable
  result.cache = BlaiForwardNpuCacheApplyResult(
    runnable: plan.runnable,
    configurable: plan.configurable,
    fits: plan.configurable,
    applied: plan.configurable)
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

proc baseHeader(layerCount: uint32): BlaiInstruction =
  blaiPutBits(result, 0, 5, ord(blaiCpuDspHeader).uint32)
  blaiPutBits(result, 5, 8, 1)
  blaiPutBits(result, 13, 6, 10)
  blaiPutBits(result, 19, 7, 12)
  blaiPutBits(result, 26, 1, 1)
  blaiPutBits(result, 27, 5, 6)
  blaiPutBits(result, 32, 1, 1)
  blaiPutBits(result, 33, 10, layerCount)
  blaiPutBits(result, 43, 5, 7)
  blaiPutBits(result, 48, 1, 1)

proc baseLayerInfo(inputNum = 3'u32): BlaiInstruction =
  blaiPutBits(result, 0, 5, ord(blaiCpuLayerInfo).uint32)
  blaiPutBits(result, 5, 14, 16)
  blaiPutBits(result, 19, 14, 12)
  blaiPutBits(result, 33, 13, 3)
  blaiPutBits(result, 46, 13, 9)
  blaiPutBits(result, 59, 13, 8)
  blaiPutBits(result, 72, 1, 1)
  blaiPutBits(result, 73, 7, 2)
  blaiPutBits(result, 80, 7, 3)
  blaiPutBits(result, 87, 7, 4)
  blaiPutBits(result, 94, 4, inputNum)
  blaiPutBits(result, 98, 14, 14)
  blaiPutBits(result, 112, 14, 10)

proc tfliteGeneral(layerType: BlaiLayerType): BlaiInstruction =
  blaiPutBits(result, 0, 5, ord(blaiCpuGeneralForm).uint32)
  blaiPutBits(result, 5, 5, ord(layerType).uint32)
  blaiPutBits(result, 10, 5, 2)
  blaiPutBits(result, 15, 5, 3)
  blaiPutBits(result, 20, 3, 0)
  blaiPutBits(result, 23, 3, 0)
  blaiPutBits(result, 26, 12, 1)
  blaiPutBits(result, 38, 8, 128)
  blaiPutBits(result, 46, 8, 129)
  blaiPutBits(result, 54, 6, 0b111101)
  blaiPutBits(result, 60, 6, 0b000011)
  blaiPutBits(result, 66, 8, 130)
  blaiPutBits(result, 74, 6, 0b111111)
  blaiPutBits(result, 80, 8, 2)
  blaiPutBits(result, 88, 8, 250)
  blaiPutBits(result, 96, 1, 1)
  blaiPutBits(result, 97, 6, 4)
  blaiPutBits(result, 103, 16, 0x1234)
  blaiPutBits(result, 119, 2, 2)

proc status(inputNum = 3'u32): BlaiInstruction =
  blaiPutBits(result, 0, 5, ord(blaiCpuDspStatus).uint32)
  blaiPutBits(result, 5, 1, 1)
  blaiPutBits(result, 6, 1, 0)
  blaiPutBits(result, 7, 1, 1)
  blaiPutBits(result, 8, 4, inputNum)
  blaiPutBits(result, 12, 32, 0x3F80_0000'u32)
  blaiPutBits(result, 44, 1, 1)

proc yoloInfo(): BlaiInstruction =
  blaiPutBits(result, 0, 5, ord(blaiCpuYoloInfo).uint32)
  blaiPutBits(result, 5, 7, 20)
  blaiPutBits(result, 12, 4, 5)
  blaiPutBits(result, 16, 3, 2)
  blaiPutBits(result, 19, 3, 4)
  blaiPutBits(result, 22, 3, 5)
  blaiPutBits(result, 28, 10, 101)
  blaiPutBits(result, 38, 10, 102)
  blaiPutBits(result, 48, 10, 201)
  blaiPutBits(result, 58, 10, 202)
  blaiPutBits(result, 68, 10, 301)
  blaiPutBits(result, 78, 10, 302)

proc extraLayerTflite(): BlaiInstruction =
  blaiPutBits(result, 0, 5, ord(blaiCpuExtraLayer).uint32)
  blaiPutBits(result, 5, 7, 21)
  blaiPutBits(result, 12, 7, 22)
  blaiPutBits(result, 26, 12, 55)
  blaiPutBits(result, 38, 12, 66)
  blaiPutBits(result, 62, 8, 101)
  blaiPutBits(result, 70, 8, 102)
  blaiPutBits(result, 86, 6, 0b111110)
  blaiPutBits(result, 92, 6, 0b000101)

proc extraMultiplier(): BlaiInstruction =
  blaiPutBits(result, 0, 5, ord(blaiCpuExtraMultiplier).uint32)
  blaiPutBits(result, 5, 32, 0x3132_3334'u32)
  blaiPutBits(result, 37, 32, 0x4142_4344'u32)

proc extraLayerTfliteHigh(): BlaiInstruction =
  blaiPutBits(result, 0, 5, ord(blaiCpuExtraLayer6To8).uint32)
  blaiPutBits(result, 5, 7, 31)
  blaiPutBits(result, 12, 7, 32)
  blaiPutBits(result, 19, 7, 33)
  blaiPutBits(result, 26, 12, 77)
  blaiPutBits(result, 38, 12, 88)
  blaiPutBits(result, 50, 12, 99)
  blaiPutBits(result, 62, 8, 111)
  blaiPutBits(result, 70, 8, 112)
  blaiPutBits(result, 78, 8, 113)
  blaiPutBits(result, 86, 6, 0b111111)
  blaiPutBits(result, 92, 6, 0b000110)
  blaiPutBits(result, 98, 6, 0b111100)

proc extraMultiplierHigh(): BlaiInstruction =
  blaiPutBits(result, 0, 5, ord(blaiCpuExtraMultiplier6To8).uint32)
  blaiPutBits(result, 5, 32, 0x5152_5354'u32)
  blaiPutBits(result, 37, 32, 0x6162_6364'u32)
  blaiPutBits(result, 69, 32, 0x7172_7374'u32)

proc tfliteMultiplier(): BlaiInstruction =
  blaiPutBits(result, 0, 5, ord(blaiCpuTfliteMultiplier).uint32)
  blaiPutBits(result, 5, 32, 0x0102_0304'u32)
  blaiPutBits(result, 37, 32, 0x1112_1314'u32)
  blaiPutBits(result, 69, 32, 0x2122_2324'u32)
  blaiPutBits(result, 101, 16, 0x3344'u32)

proc tfliteFloat(): BlaiInstruction =
  blaiPutBits(result, 0, 5, ord(blaiCpuTfliteFloat).uint32)
  blaiPutBits(result, 5, 32, 0x3F80_0000'u32)
  blaiPutBits(result, 37, 32, 0x4000_0000'u32)

proc ssdInfo(): BlaiInstruction =
  blaiPutBits(result, 0, 5, ord(blaiCpuSsdInfo).uint32)
  blaiPutBits(result, 5, 6, 10)
  blaiPutBits(result, 11, 6, 20)
  blaiPutBits(result, 17, 6, 30)
  blaiPutBits(result, 23, 6, 40)
  blaiPutBits(result, 29, 7, 21)
  blaiPutBits(result, 36, 3, 5)
  blaiPutBits(result, 39, 5, 17)
  blaiPutBits(result, 44, 32, 0x3F80_0000'u32)
  blaiPutBits(result, 76, 32, 0x4000_0000'u32)
  blaiPutBits(result, 108, 8, 77)

proc checkParsedBaseModel() =
  var layers: array[1, BlaiCpuInstLayer64]
  var states: array[1, BlaiCpuParsedLayerState]
  let stream = [
    baseHeader(1), baseLayerInfo(), tfliteGeneral(blaiConvolutional),
    tfliteMultiplier(), status()]
  let parsed = blaiParseCpuModelInstructions(stream, layers)
  let parsedState = blaiParseCpuModelInstructions(stream, states)
  check("NPU parse base complete", parsed.complete and parsedState.complete)
  checkEq("NPU parse base records", parsed.recordCount, 5)
  checkEq("NPU parse base layers", parsed.storedLayerCount, 1)
  check("NPU parse base tflite", parsed.useTflite)
  checkEq("NPU parse base width", layers[0].w.uint32, 16)
  checkEq("NPU parse base output channels", layers[0].outC.uint32, 8)
  checkEq("NPU parse base multiplier",
    cast[uint32](layers[0].tfInput1Multiplier), 0x0102_0304'u32)
  checkEq("NPU parse base multiplier bits",
    blaiUint32FromInt32Bits(layers[0].tfInput1Multiplier), 0x0102_0304'u32)
  checkEq("NPU parse bit reinterpret signed",
    blaiUint32FromInt32Bits(blaiInt32FromBits(0xFFFF_FFFE'u32)),
    0xFFFF_FFFE'u32)
  checkEq("NPU parse base route multiplier",
    cast[uint32](layers[0].tfRouteInputMultiplier), 0x1234_3344'u32)
  checkFloatBits("NPU parse base output scale", layers[0].outputScale, 1.0'f32)
  let params = blaiNetParams(parsed.header)
  check("NPU parse net params unsigned", params.unsignedInput)
  checkEq("NPU parse net params relu", params.reluN, 6)
  check("NPU parse net params tflite", params.tensorflowMode)
  check("NPU parse state active", states[0].active)
  checkEq("NPU parse state layer type",
    states[0].layer.layerType.uint32, ord(blaiConvolutional).uint32)

proc checkParsedYoloSidecars() =
  var states: array[1, BlaiCpuParsedLayerState]
  let parsed = blaiParseCpuModelInstructions(
    [baseHeader(1), baseLayerInfo(), tfliteGeneral(blaiYolo), yoloInfo(),
     status()],
    states)
  check("NPU parse yolo complete", parsed.complete)
  checkEq("NPU parse yolo unsupported", parsed.unsupportedRecordCount, 0)
  check("NPU parse yolo sidecar active", states[0].yolo.active)
  checkEq("NPU parse yolo classes", states[0].layer.classes.uint32, 20)
  checkEq("NPU parse yolo total", states[0].layer.total.uint32, 6)
  checkEq("NPU parse yolo mask", states[0].yolo.mask[0].uint32, 2)
  checkEq("NPU parse yolo bias", states[0].yolo.biases[11].uint32, 302)

proc checkParsedExtraSidecars() =
  var layers: array[1, BlaiCpuInstLayer64]
  var extra: array[1, BlaiCpuExtraInputStorage]
  var states: array[1, BlaiCpuParsedLayerState]
  let stream = [
    baseHeader(1), baseLayerInfo(inputNum = 4),
    tfliteGeneral(blaiRoute), extraLayerTflite(), extraMultiplier(),
    status(inputNum = 4)]
  let parsed = blaiParseCpuModelInstructions(stream, layers, extra)
  let parsedState = blaiParseCpuModelInstructions(stream, states)
  var basicLayers: array[1, BlaiCpuInstLayer64]
  let basicParsed = blaiParseCpuModelInstructions(stream, basicLayers)
  check("NPU parse extra complete", parsed.complete and parsedState.complete)
  check("NPU parse extra basic incomplete", not basicParsed.complete)
  checkEq("NPU parse extra basic unsupported count",
    basicParsed.unsupportedRecordCount, 2)
  checkEq("NPU parse extra basic unsupported record",
    basicParsed.firstUnsupportedRecord.uint32, 3)
  checkEq("NPU parse extra basic unsupported kind",
    ord(basicParsed.firstUnsupportedKind).uint32,
    ord(blaiCpuExtraLayer).uint32)
  check("NPU parse extra sidecar active", extra[0].active)
  checkEq("NPU parse extra channel 2", layers[0].cn[1].uint32, 55)
  checkEq("NPU parse extra mem 2", extra[0].inLayerMemN[0].uint32, 21)
  checkEq("NPU parse extra shift 2",
    cast[uint32](extra[0].tfInputShiftExtra[0]), cast[uint32](-2'i32))
  checkEq("NPU parse extra multiplier 3",
    cast[uint32](extra[0].tfInputMultiplierExtra[1]), 0x4142_4344'u32)
  let route2 = blaiCpuRouteInputSource(
    blaiCpuParsedLayer(layers, extra, 0), 2)
  let quant2 = blaiCpuTfliteInputQuant(states[0], 2)
  check("NPU parse extra route2 active", route2.active)
  checkEq("NPU parse extra route2 memory", route2.memorySlot.uint32, 21)
  checkEq("NPU parse extra route2 channels", route2.channels.uint32, 55)
  check("NPU parse extra quant2 active", quant2.active)
  checkEq("NPU parse extra quant2 offset", quant2.offset.uint32, 101)
  checkEq("NPU parse extra quant2 multiplier",
    cast[uint32](quant2.multiplier), 0x3132_3334'u32)
  checkEq("NPU parse extra state multiplier",
    cast[uint32](states[0].extraInputs.tfInputMultiplierExtra[1]),
    0x4142_4344'u32)

  var highStates: array[1, BlaiCpuParsedLayerState]
  let highStream = [
    baseHeader(1), baseLayerInfo(inputNum = 8),
    tfliteGeneral(blaiRoute), extraLayerTfliteHigh(),
    extraMultiplierHigh(), status(inputNum = 8)]
  let highParsed = blaiParseCpuModelInstructions(highStream, highStates)
  check("NPU parse extra high complete", highParsed.complete)
  check("NPU parse extra high active", highStates[0].extraInputs.active)
  checkEq("NPU parse extra high channel 5",
    highStates[0].layer.cn[4].uint32, 77)
  checkEq("NPU parse extra high channel 7",
    highStates[0].layer.cn[6].uint32, 99)
  checkEq("NPU parse extra high mem 7",
    highStates[0].extraInputs.inLayerMemN[5].uint32, 33)
  checkEq("NPU parse extra high shift 7",
    cast[uint32](highStates[0].extraInputs.tfInputShiftExtra[5]),
    cast[uint32](-4'i32))
  checkEq("NPU parse extra high multiplier 7",
    cast[uint32](highStates[0].extraInputs.tfInputMultiplierExtra[5]),
    0x7172_7374'u32)
  let route7 = blaiCpuRouteInputSource(highStates[0], 7)
  let quant7 = blaiCpuTfliteInputQuant(highStates[0], 7)
  check("NPU parse extra high route7 active", route7.active)
  checkEq("NPU parse extra high route7 memory",
    route7.memorySlot.uint32, 33)
  checkEq("NPU parse extra high route7 channels",
    route7.channels.uint32, 99)
  check("NPU parse extra high quant7 active", quant7.active)
  checkEq("NPU parse extra high quant7 offset", quant7.offset.uint32, 113)
  checkEq("NPU parse extra high quant7 multiplier",
    cast[uint32](quant7.multiplier), 0x7172_7374'u32)

proc checkParsedFloatAndSsd() =
  var floatLayers: array[1, BlaiCpuInstLayer64]
  let parsedFloat = blaiParseCpuModelInstructions(
    [baseHeader(1), baseLayerInfo(), tfliteGeneral(blaiConvolutional),
     tfliteFloat(), status()],
    floatLayers)
  check("NPU parse float complete", parsedFloat.complete)
  checkFloatBits("NPU parse float input scale", floatLayers[0].inputScale, 1.0'f32)
  checkFloatBits("NPU parse float output scale", floatLayers[0].outputScale, 1.0'f32)

  var ssdLayers: array[1, BlaiCpuInstLayer64]
  let parsedSsd = blaiParseCpuModelInstructions(
    [baseHeader(1), baseLayerInfo(), tfliteGeneral(blaiConvolutional),
     ssdInfo(), status()],
    ssdLayers)
  check("NPU parse ssd complete", parsedSsd.complete)
  checkFloatBits("NPU parse ssd w scale", ssdLayers[0].wScale, 10.0'f32)
  checkFloatBits("NPU parse ssd input2 scale", ssdLayers[0].input2Scale, 1.0'f32)
  checkFloatBits("NPU parse ssd input3 scale", ssdLayers[0].input3Scale, 2.0'f32)
  checkEq("NPU parse ssd classes", ssdLayers[0].classes.uint32, 21)
  checkEq("NPU parse ssd detections", ssdLayers[0].maxDetections.uint32, 17)
  checkEq("NPU parse ssd anchors", ssdLayers[0].anchorsOffset.uint32, 77)

proc checkParsedDispatchAndEligibility() =
  var routeState = BlaiCpuParsedLayerState(
    active: true,
    index: 3,
    layer: BlaiCpuInstLayer64(
      layerType: ord(blaiRoute).int32,
      inputNum: 3,
      npuOn: 1,
      dramPatchSize: 64,
      instCnt: 1),
    extraInputs: BlaiCpuExtraInputStorage(active: true),
    yolo: BlaiCpuYoloStorage(active: true))
  let dispatch = blaiEncodeDispatch(routeState)
  checkEq("NPU parse dispatch state route",
    ord(dispatch).uint32, ord(blaiEncodeRoute).uint32)
  checkEq("NPU parse dispatch state fetch",
    ord(blaiFetchKind(dispatch)).uint32, ord(blaiFetchRoute).uint32)

  var routeEligibility: BlaiNpuEligibilityResult
  blaiNpuEligibilityInto(routeState, routeEligibility)
  check("NPU parse eligibility state route",
    routeEligibility.knownLayer and routeEligibility.eligible)
  check("NPU parse eligibility state can run",
    blaiCanRunOnNpu(routeState))
  check("NPU parse eligibility state sidecars preserved",
    routeState.extraInputs.active and routeState.yolo.active)

  let readiness = blaiForwardEncodedLayerReadiness(routeState)
  check("NPU parse encoded state ready", readiness.ready)
  check("NPU parse encoded state sidecars preserved",
    routeState.extraInputs.active and routeState.yolo.active)

  let rawGeneral = blaiEncodeDispatch(BlaiCpuInstLayer64(
    layerType: ord(blaiRouteConv).int32,
    inputNum: 3))
  checkEq("NPU parse dispatch raw routeconv general",
    ord(rawGeneral).uint32, ord(blaiEncodeGeneral).uint32)

  var oddStrideState = BlaiCpuParsedLayerState(
    active: true,
    index: 4,
    layer: BlaiCpuInstLayer64(
      layerType: ord(blaiConvolutional).int32,
      w: 5,
      h: 4,
      size: 3,
      stride: 2,
      dilation: 1))
  var oddStrideEligibility: BlaiNpuEligibilityResult
  blaiNpuEligibilityInto(oddStrideState, oddStrideEligibility)
  check("NPU parse eligibility state odd stride blocked",
    not oddStrideEligibility.eligible)
  check("NPU parse eligibility state odd stride reason",
    not oddStrideEligibility.oddStrideSupported)

proc checkParsedForwardWorkspacePlanning() =
  var layers: array[1, BlaiCpuInstLayer64]
  var states: array[1, BlaiCpuParsedLayerState]
  let stream = [
    baseHeader(1), baseLayerInfo(), tfliteGeneral(blaiConvolutional), status()]
  let parsed = blaiParseCpuModelInstructions(stream, layers)
  discard blaiParseCpuModelInstructions(stream, states)

  let blocked = blaiParsedForwardModelReadiness(parsed, layers)
  check("NPU parse forward blocked parsed", blocked.parsed)
  check("NPU parse forward blocked not ready", not blocked.forwardReady)
  checkEq("NPU parse forward blocked unencoded", blocked.unencodedLayerCount, 1)
  checkEq("NPU parse forward blocked first", blocked.firstUnencodedLayer.uint32, 0)
  check("NPU parse forward blocked captured",
    blocked.firstUnencodedLayerCaptured)
  check("NPU parse forward blocked patch",
    not blocked.firstUnencodedLayerReadiness.patchReady)
  check("NPU parse forward blocked instruction",
    not blocked.firstUnencodedLayerReadiness.instructionReady)
  let blockedPlan = blaiPlanParsedForwardModelWorkspace(
    parsed, layers, baseAddress = 0x2208_0000'u32)
  check("NPU parse forward blocked unplanned", not blockedPlan.planned)
  check("NPU parse forward blocked workspace", not blockedPlan.workspaceReady)

  layers[0].dramPatchSize = 64
  layers[0].instCnt = 1
  states[0].layer.dramPatchSize = 64
  states[0].layer.instCnt = 1

  let ready = blaiParsedForwardModelReadiness(parsed, layers)
  let readyState = blaiParsedForwardModelReadiness(parsed, states)
  check("NPU parse forward ready", ready.forwardReady and readyState.forwardReady)
  checkEq("NPU parse forward ready layers", ready.readyLayerCount, 1)
  checkEq("NPU parse forward ready unencoded", ready.unencodedLayerCount, 0)
  check("NPU parse forward ready no captured",
    not ready.firstUnencodedLayerCaptured)
  checkEq("NPU parse forward ready last", ready.lastReadyLayer.uint32, 0)

  let plan = blaiPlanParsedForwardModelWorkspace(
    parsed, layers, baseAddress = 0x2208_0000'u32)
  let statePlan = blaiPlanParsedForwardModelWorkspace(
    parsed, states, baseAddress = 0x2208_0000'u32)
  check("NPU parse forward plan planned", plan.planned and statePlan.planned)
  check("NPU parse forward plan workspace", plan.workspaceReady)
  check("NPU parse forward plan state workspace", statePlan.workspaceReady)
  checkEq("NPU parse forward plan layers", plan.resources.layerCount, 1)
  checkEq("NPU parse forward plan npu layers", plan.resources.npuLayerCount, 1)
  checkEq("NPU parse forward plan base", plan.workspace.baseAddress, 0x2208_0000'u32)
  check("NPU parse forward plan instruction active",
    plan.workspace.instruction.active)
  check("NPU parse forward plan data active", plan.workspace.data.active)

  let executeReady = blaiParsedForwardModelExecuteReadiness(parsed, plan, 2048)
  check("NPU parse forward execute ready", executeReady.executable)
  check("NPU parse forward execute workspace", executeReady.workspaceFits)
  checkEq("NPU parse forward execute layers", executeReady.layerCount, 1)
  checkEq("NPU parse forward execute expected", executeReady.expectedLayerCount, 1)

  let missingLayers = blaiParsedForwardModelExecuteReadiness(
    parsed, plan, 2048, suppliedLayerCount = 0)
  check("NPU parse forward missing blocked", not missingLayers.executable)
  checkEq("NPU parse forward missing count", missingLayers.missingLayerCount, 1)

  let shortWorkspace = blaiParsedForwardModelExecuteReadiness(parsed, plan, 16)
  check("NPU parse forward short workspace blocked",
    not shortWorkspace.executable)
  check("NPU parse forward short workspace fit",
    not shortWorkspace.workspaceFits)

proc checkAssignReleaseLayers() =
  var layers = [
    BlaiCpuInstLayer64(
      layerType: ord(blaiConvMax).int32,
      graphLayer: [1'i32, 0],
      releaseNum: 7,
      releaseMidNum: 7),
    BlaiCpuInstLayer64(
      layerType: ord(blaiRoute).int32,
      inputNum: 1,
      inputLayers: [0'i32, 0, 0, 0, 0, 0, 0, 0],
      graphLayer: [2'i32, 0]),
    BlaiCpuInstLayer64(
      layerType: ord(blaiConvolutional).int32,
      inputNum: 1,
      inputLayers: [1'i32, 0, 0, 0, 0, 0, 0, 0],
      graphLayer: [3'i32, 0])]
  var graphLayerMap: array[4, int32]
  let plan = blaiAssignReleaseLayers(layers, graphLayerMap)
  check("NPU parse release complete", plan.complete)
  checkEq("NPU parse release block", ord(plan.firstBlock).uint32,
    ord(blaiReleaseLayerNoBlock).uint32)
  checkEq("NPU parse release layers", plan.layerCount, 3)
  checkEq("NPU parse release normal count", plan.releaseLayerCount, 3)
  checkEq("NPU parse release mid count", plan.releaseMidLayerCount, 1)
  check("NPU parse release stale counters reset",
    layers[0].releaseNum == 0 and layers[0].releaseMidNum == 0)
  checkEq("NPU parse release midout", layers[0].midOut.uint32, 1)
  checkEq("NPU parse release mid target", layers[1].releaseMidLayers[0].uint32, 0)
  checkEq("NPU parse release final count", layers[2].releaseNum.uint32, 3)
  checkEq("NPU parse release final first", layers[2].releaseLayers[0].uint32, 0)
  checkEq("NPU parse release final second", layers[2].releaseLayers[1].uint32, 1)
  checkEq("NPU parse release final third", layers[2].releaseLayers[2].uint32, 2)
  checkEq("NPU parse release graph zero", graphLayerMap[0].uint32, 0)
  checkEq("NPU parse release graph one", graphLayerMap[1].uint32, 0)
  checkEq("NPU parse release graph two", graphLayerMap[2].uint32, 1)
  checkEq("NPU parse release graph three", graphLayerMap[3].uint32, 2)

  var states = [
    BlaiCpuParsedLayerState(
      active: true,
      index: 0,
      layer: BlaiCpuInstLayer64(
        layerType: ord(blaiConvMax).int32,
        graphLayer: [1'i32, 0],
        releaseNum: 7,
        releaseMidNum: 7),
      extraInputs: BlaiCpuExtraInputStorage(active: true)),
    BlaiCpuParsedLayerState(
      active: true,
      index: 1,
      layer: BlaiCpuInstLayer64(
        layerType: ord(blaiRoute).int32,
        inputNum: 1,
        inputLayers: [0'i32, 0, 0, 0, 0, 0, 0, 0],
        graphLayer: [2'i32, 0])),
    BlaiCpuParsedLayerState(
      active: true,
      index: 2,
      layer: BlaiCpuInstLayer64(
        layerType: ord(blaiConvolutional).int32,
        inputNum: 1,
        inputLayers: [1'i32, 0, 0, 0, 0, 0, 0, 0],
        graphLayer: [3'i32, 0]))]
  var stateGraphLayerMap: array[4, int32]
  let statePlan = blaiAssignReleaseLayers(states, stateGraphLayerMap)
  check("NPU parse release state complete", statePlan.complete)
  checkEq("NPU parse release state normal count",
    statePlan.releaseLayerCount, 3)
  checkEq("NPU parse release state mid count",
    statePlan.releaseMidLayerCount, 1)
  check("NPU parse release state sidecar preserved",
    states[0].extraInputs.active)
  checkEq("NPU parse release state midout",
    states[0].layer.midOut.uint32, 1)
  checkEq("NPU parse release state mid target",
    states[1].layer.releaseMidLayers[0].uint32, 0)
  checkEq("NPU parse release state final count",
    states[2].layer.releaseNum.uint32, 3)
  checkEq("NPU parse release state graph three",
    stateGraphLayerMap[3].uint32, 2)

  var smallGraphLayerMap: array[2, int32]
  let smallPlan = blaiAssignReleaseLayers(layers, smallGraphLayerMap)
  check("NPU parse release overflow blocked", not smallPlan.complete)
  check("NPU parse release overflow graph", not smallPlan.graphMapFits)
  check("NPU parse release overflow keeps release", smallPlan.releaseFits)
  checkEq("NPU parse release overflow block",
    ord(smallPlan.firstBlock).uint32,
    ord(blaiReleaseLayerGraphMapOverflow).uint32)
  checkEq("NPU parse release overflow first",
    smallPlan.firstGraphMapOverflowLayer.uint32, 1)

proc checkCpuOutputShapeLater() =
  var transposeLayer = BlaiCpuInstLayer64(
    layerType: ord(blaiTranspose).int32,
    w: 5,
    h: 7,
    c: 3)
  let transposeShape = blaiApplyCpuOutputShapeLater(
    transposeLayer,
    BlaiCpuTfliteTransposeMask(
      active: true, rank: 4, hPerm: 3, wPerm: 1, cPerm: 2))
  check("NPU parse shape transpose supported", transposeShape.supported)
  check("NPU parse shape transpose updated", transposeShape.updated)
  checkEq("NPU parse shape transpose block",
    ord(transposeShape.firstBlock).uint32,
    ord(blaiOutputShapeNoBlock).uint32)
  checkEq("NPU parse shape transpose h", transposeLayer.outH.uint32, 3)
  checkEq("NPU parse shape transpose w", transposeLayer.outW.uint32, 7)
  checkEq("NPU parse shape transpose c", transposeLayer.outC.uint32, 5)

  var transposeRank3Layer = BlaiCpuInstLayer64(
    layerType: ord(blaiTranspose).int32,
    w: 5,
    h: 7,
    c: 3)
  let transposeRank3Shape = blaiApplyCpuOutputShapeLater(
    transposeRank3Layer,
    BlaiCpuTfliteTransposeMask(
      active: true, rank: 3, hPerm: 2, wPerm: 0, cPerm: 1))
  check("NPU parse shape transpose rank3", transposeRank3Shape.updated)
  checkEq("NPU parse shape transpose rank3 block",
    ord(transposeRank3Shape.firstBlock).uint32,
    ord(blaiOutputShapeNoBlock).uint32)
  checkEq("NPU parse shape transpose rank3 h",
    transposeRank3Layer.outH.uint32, 3)
  checkEq("NPU parse shape transpose rank3 w",
    transposeRank3Layer.outW.uint32, 7)
  checkEq("NPU parse shape transpose rank3 c",
    transposeRank3Layer.outC.uint32, 5)

  var transposeState = BlaiCpuParsedLayerState(
    active: true,
    index: 5,
    layer: BlaiCpuInstLayer64(
      layerType: ord(blaiTranspose).int32,
      w: 5,
      h: 7,
      c: 3),
    extraInputs: BlaiCpuExtraInputStorage(active: true))
  let transposeStateShape = blaiApplyCpuOutputShapeLater(
    transposeState,
    BlaiCpuTfliteTransposeMask(
      active: true, rank: 4, hPerm: 3, wPerm: 1, cPerm: 2))
  check("NPU parse shape state transpose updated",
    transposeStateShape.updated)
  check("NPU parse shape state sidecar preserved",
    transposeState.extraInputs.active)
  checkEq("NPU parse shape state transpose h",
    transposeState.layer.outH.uint32, 3)
  checkEq("NPU parse shape state transpose c",
    transposeState.layer.outC.uint32, 5)

  var transposeNoMaskLayer = BlaiCpuInstLayer64(
    layerType: ord(blaiTranspose).int32,
    w: 5,
    h: 7,
    c: 3)
  let transposeNoMaskShape =
    blaiApplyCpuOutputShapeLater(transposeNoMaskLayer)
  check("NPU parse shape transpose no mask supported",
    transposeNoMaskShape.supported)
  check("NPU parse shape transpose no mask blocked",
    not transposeNoMaskShape.updated)
  checkEq("NPU parse shape transpose no mask reason",
    ord(transposeNoMaskShape.firstBlock).uint32,
    ord(blaiOutputShapeMissingTransposeMask).uint32)

  var transposeLkLayer = BlaiCpuInstLayer64(
    layerType: ord(blaiTransposeLk).int32,
    w: 1,
    h: 9,
    c: 2,
    stride: 2,
    tfInput1Multiplier: 3,
    tfInput1Offset: 1,
    tfInput2Offset: 2)
  let transposeLkShape = blaiApplyCpuOutputShapeLater(transposeLkLayer)
  check("NPU parse shape transposelk supported", transposeLkShape.supported)
  check("NPU parse shape transposelk updated", transposeLkShape.updated)
  checkEq("NPU parse shape transposelk block",
    ord(transposeLkShape.firstBlock).uint32,
    ord(blaiOutputShapeNoBlock).uint32)
  checkEq("NPU parse shape transposelk size", transposeLkLayer.size.uint32, 3)
  checkEq("NPU parse shape transposelk w", transposeLkLayer.outW.uint32, 1)
  checkEq("NPU parse shape transposelk h", transposeLkLayer.outH.uint32, 3)
  checkEq("NPU parse shape transposelk c", transposeLkLayer.outC.uint32, 8)

  var padLayer = BlaiCpuInstLayer64(
    layerType: ord(blaiPad).int32,
    w: 5,
    h: 7,
    c: 3)
  let padShape = blaiApplyCpuOutputShapeLater(
    padLayer,
    padBias = BlaiCpuPadShapeBias(
      active: true, channel: 1, width: 2, height: 3))
  check("NPU parse shape pad supported", padShape.supported)
  check("NPU parse shape pad updated", padShape.updated)
  checkEq("NPU parse shape pad block",
    ord(padShape.firstBlock).uint32,
    ord(blaiOutputShapeNoBlock).uint32)
  checkEq("NPU parse shape pad h", padLayer.outH.uint32, 13)
  checkEq("NPU parse shape pad w", padLayer.outW.uint32, 9)
  checkEq("NPU parse shape pad c", padLayer.outC.uint32, 5)

  var padState = BlaiCpuParsedLayerState(
    active: true,
    index: 6,
    layer: BlaiCpuInstLayer64(
      layerType: ord(blaiPad).int32,
      w: 5,
      h: 7,
      c: 3),
    yolo: BlaiCpuYoloStorage(active: true))
  let padStateShape = blaiApplyCpuOutputShapeLater(
    padState,
    padBias = BlaiCpuPadShapeBias(
      active: true, channel: 1, width: 2, height: 3))
  check("NPU parse shape state pad updated", padStateShape.updated)
  check("NPU parse shape state yolo preserved", padState.yolo.active)
  checkEq("NPU parse shape state pad w", padState.layer.outW.uint32, 9)
  checkEq("NPU parse shape state pad h", padState.layer.outH.uint32, 13)

  var padNoBiasLayer = BlaiCpuInstLayer64(
    layerType: ord(blaiPad).int32,
    w: 5,
    h: 7,
    c: 3)
  let padNoBiasShape = blaiApplyCpuOutputShapeLater(padNoBiasLayer)
  check("NPU parse shape pad no bias supported", padNoBiasShape.supported)
  check("NPU parse shape pad no bias blocked", not padNoBiasShape.updated)
  checkEq("NPU parse shape pad no bias reason",
    ord(padNoBiasShape.firstBlock).uint32,
    ord(blaiOutputShapeMissingPadBias).uint32)

  var padInvalidLayer = BlaiCpuInstLayer64(
    layerType: ord(blaiPad).int32,
    w: 5,
    h: 7,
    c: 3)
  let padInvalidShape = blaiApplyCpuOutputShapeLater(
    padInvalidLayer,
    padBias = BlaiCpuPadShapeBias(
      active: true, channel: -2, width: 0, height: 0))
  check("NPU parse shape pad invalid supported", padInvalidShape.supported)
  check("NPU parse shape pad invalid blocked", not padInvalidShape.updated)
  check("NPU parse shape pad invalid fit", not padInvalidShape.fits)
  checkEq("NPU parse shape pad invalid reason",
    ord(padInvalidShape.firstBlock).uint32,
    ord(blaiOutputShapeInvalidDimensions).uint32)

  var unsupportedLayer = BlaiCpuInstLayer64(
    layerType: ord(blaiConvolutional).int32)
  let unsupportedShape = blaiApplyCpuOutputShapeLater(unsupportedLayer)
  check("NPU parse shape unsupported blocked", not unsupportedShape.supported)
  check("NPU parse shape unsupported unchanged", not unsupportedShape.updated)
  checkEq("NPU parse shape unsupported reason",
    ord(unsupportedShape.firstBlock).uint32,
    ord(blaiOutputShapeUnsupportedLayer).uint32)

  var transposeLkInvalidLayer = BlaiCpuInstLayer64(
    layerType: ord(blaiTransposeLk).int32,
    w: 1,
    h: 9,
    c: 2,
    stride: 0,
    tfInput1Multiplier: 3,
    tfInput1Offset: 1,
    tfInput2Offset: 2)
  let transposeLkInvalidShape =
    blaiApplyCpuOutputShapeLater(transposeLkInvalidLayer)
  check("NPU parse shape transposelk invalid supported",
    transposeLkInvalidShape.supported)
  check("NPU parse shape transposelk invalid blocked",
    not transposeLkInvalidShape.updated)
  checkEq("NPU parse shape transposelk invalid reason",
    ord(transposeLkInvalidShape.firstBlock).uint32,
    ord(blaiOutputShapeInvalidTransposeLkParams).uint32)

proc completeWorkspaceLayer(): BlaiCpuInstLayer64 =
  result = BlaiCpuInstLayer64(
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
    dramPatchSize: 256,
    instCnt: 1,
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

proc allocatorEncodeLayer(): BlaiCpuInstLayer64 =
  result = BlaiCpuInstLayer64(
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

proc checkAllocatorBackedEncode() =
  var layer = allocatorEncodeLayer()
  layer.midOut = 1
  layer.instCnt = 7
  var ctrl: BlaiPsramCtrl
  var stream: array[BlaiInstructionScratchSize div BlaiInstructionSize,
                    BlaiInstruction]
  for i in 0 ..< stream.len:
    stream[i][0] = 0xAA'u8

  let encoded = blaiEncodeCpuLayerWithAllocator(
    layer, ctrl, stream, useTflite = true, c2 = 4, includeExtra = true)
  check("NPU parse encode allocator fits", encoded.allocation.fits)
  checkEq("NPU parse encode allocator branch",
    ord(encoded.allocation.branch).uint32, ord(blaiMemAllocSinglePatch).uint32)
  check("NPU parse encode allocator runnable", encoded.encode.plan.runnable)
  check("NPU parse encode allocator scratch", encoded.encode.scratchCleared)
  check("NPU parse encode allocator encoded", encoded.encoded)
  checkEq("NPU parse encode allocator count", layer.instCnt.uint32, 3)
  checkEq("NPU parse encode allocator patches", layer.dramPatchNum.uint32, 4)
  checkEq("NPU parse encode allocator patch size",
    ctrl.psramPatchSize.uint32, 64)
  checkEq("NPU parse encode allocator patch count",
    ctrl.psramPatchCount.uint32, 1)
  checkEq("NPU parse encode allocator mid patches",
    ctrl.psramMidPatchCount.uint32, 1)
  checkEq("NPU parse encode allocator out slot", ctrl.sramOut[0].uint32, 3)
  checkEq("NPU parse encode allocator multiplier", blaiBits(stream[0], 13, 32),
    0x0102_0304'u32)
  checkEq("NPU parse encode allocator tail clear", stream[3][0].uint32, 0)

  var failLayer = BlaiCpuInstLayer64(
    layerType: ord(blaiConvolutional).int32,
    w: 1_000_000,
    h: 1,
    c: 10_000,
    outW: 1_000_000,
    outH: 1,
    outC: 4,
    groups: 1,
    stride: 1,
    dilation: 1,
    size: 3,
    inputNum: 1,
    npuOn: 1,
    instCnt: 5)
  var failCtrl: BlaiPsramCtrl
  var failStream: array[BlaiInstructionScratchSize div BlaiInstructionSize,
                        BlaiInstruction]
  failStream[0][0] = 0x55'u8
  let failed = blaiEncodeCpuLayerWithAllocator(
    failLayer, failCtrl, failStream, useTflite = false)
  check("NPU parse encode allocator fail blocked", not failed.allocation.fits)
  checkEq("NPU parse encode allocator fail branch",
    ord(failed.allocation.branch).uint32, ord(blaiMemAllocFailed).uint32)
  check("NPU parse encode allocator fail runnable",
    not failed.encode.plan.runnable)
  check("NPU parse encode allocator fail scratch",
    not failed.encode.scratchCleared)
  check("NPU parse encode allocator fail encoded", not failed.encoded)
  checkEq("NPU parse encode allocator fail npu", failLayer.npuOn.uint32, 0)
  checkEq("NPU parse encode allocator fail count",
    failLayer.instCnt.uint32, 5)
  checkEq("NPU parse encode allocator fail stream",
    failStream[0][0].uint32, 0x55)

proc checkFetchDescriptorOperands() =
  let secondInput = blaiPlanFetchDescriptorOperands(
    BlaiCpuInstLayer64(
      layerType: ord(blaiConvolutional).int32,
      n: 2,
      cn: [5'i32, 0, 0, 0, 0, 0, 0],
      groups: 1,
      stride: 1,
      dilation: 1,
      size: 3),
    BlaiPsramCtrl(weightPatchCount: 1, linePatchCount: 1),
    blaiFetchGeneral)
  var secondInputInto: BlaiFetchDescriptorOperands
  blaiPlanFetchDescriptorOperandsInto(
    BlaiCpuInstLayer64(
      layerType: ord(blaiConvolutional).int32,
      n: 2,
      cn: [5'i32, 0, 0, 0, 0, 0, 0],
      groups: 1,
      stride: 1,
      dilation: 1,
      size: 3),
    BlaiPsramCtrl(weightPatchCount: 1, linePatchCount: 1),
    blaiFetchGeneral, secondInputInto)
  check("NPU parse operands second input into",
    sameFetchDescriptorOperands(secondInputInto, secondInput))
  check("NPU parse operands second input c2",
    secondInput.multiInputC2 and secondInput.c2 == 8)
  check("NPU parse operands second input no extra",
    not secondInput.includeExtra)

  let grouped = blaiPlanFetchDescriptorOperands(
    BlaiCpuInstLayer64(
      layerType: ord(blaiConvolutional).int32,
      n: 2,
      cn: [5'i32, 0, 0, 0, 0, 0, 0],
      groups: 2,
      stride: 1,
      dilation: 1,
      size: 3),
    BlaiPsramCtrl(weightPatchCount: 1, linePatchCount: 1),
    blaiFetchGeneral)
  check("NPU parse operands grouped extra",
    grouped.groupedExtra and grouped.includeExtra and grouped.c2 == 8)

  let comboFlat = blaiPlanFetchDescriptorOperands(
    BlaiCpuInstLayer64(
      layerType: ord(blaiConvMax).int32,
      groups: 2,
      stride: 1,
      dilation: 2,
      size: 5),
    BlaiPsramCtrl(weightPatchCount: 3, linePatchCount: 1),
    blaiFetchGeneral)
  check("NPU parse operands combo flat guard",
    comboFlat.weightPatchExtra and comboFlat.groupedExtra and
      comboFlat.dilationExtra and not comboFlat.includeExtra)

  let comboLine = blaiPlanFetchDescriptorOperands(
    BlaiCpuInstLayer64(
      layerType: ord(blaiConvMax).int32,
      groups: 1,
      stride: 1,
      dilation: 1,
      size: 5),
    BlaiPsramCtrl(weightPatchCount: 1, linePatchCount: 2),
    blaiFetchGeneral)
  check("NPU parse operands combo line extra",
    comboLine.linePatchExtra and comboLine.maxPoolLinePatchExtra and
      comboLine.includeExtra)

proc checkInstructionEncodeBundle() =
  let plan = BlaiFetchMemoryPlan(
    kind: blaiFetchGeneral,
    fits: true,
    inputCount: 2,
    patchSize: 64,
    inputPatchCount: [1'u32, 1, 0, 0, 0, 0, 0, 0],
    inputSlots: [0'u32, 1, 0, 0, 0, 0, 0, 0],
    midOutputSlot: 2,
    outputSlot: 3,
    dramPatchCount: 4)
  let bundle = blaiLayerInstructionBundle(
    BlaiCpuInstLayer64(
      layerType: ord(blaiRouteConv).int32,
      w: 13,
      h: 12,
      c: 10,
      outW: 6,
      outH: 5,
      outC: 8,
      groups: 2,
      stride: 2,
      dilation: 1,
      size: 3,
      activation: 2,
      imgIn: 1,
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
      quantizedActivationMax: 255),
    plan, useTflite = true, c2 = 4, includeExtra = true)
  var count: BlaiInstructionEncodeCountResult
  blaiInstructionEncodeRequiredInto(bundle, count)
  check("NPU parse instruction bundle flags",
    bundle.useTflite == 1 and bundle.extraInfo == 1)
  checkEq("NPU parse instruction bundle count", count.emitted, 3)
  var stream: array[3, BlaiInstruction]
  let encoded = blaiEncodeInstructions(bundle, stream, 0)
  check("NPU parse instruction encode fits", encoded.fits)
  checkEq("NPU parse instruction encode end", encoded.endCount, 3)
  checkEq("NPU parse instruction encode tflite first",
    blaiBits(stream[0], 13, 32), 0x0102_0304'u32)
  let ext = decodeBlaiExternalLayerInfo(stream[1])
  let decoded = decodeBlaiLayer(stream[2], ext)
  check("NPU parse instruction encode extra", ext.valid)
  checkEq("NPU parse instruction encode layer",
    ord(decoded.layerType).uint32, ord(blaiRouteConv).uint32)
  checkEq("NPU parse instruction encode output", decoded.outLayerMem, 3)
  checkEq("NPU parse instruction encode stride", decoded.stride, 2)
  checkEq("NPU parse instruction encode groups", decoded.groups, 2)

  var shortStream: array[2, BlaiInstruction]
  shortStream[0][0] = 0x66'u8
  let blocked = blaiEncodeInstructions(bundle, shortStream, 0)
  check("NPU parse instruction encode short blocked", not blocked.fits)
  checkEq("NPU parse instruction encode short emitted", blocked.emitted, 3)
  checkEq("NPU parse instruction encode short preserved",
    shortStream[0][0].uint32, 0x66)

proc checkAllocatorBranchPlans() =
  let highWeightLayer = BlaiCpuInstLayer64(
    layerType: ord(blaiConvolutional).int32,
    w: 8,
    h: 1,
    c: 128,
    outW: 8,
    outH: 1,
    outC: 256,
    groups: 1,
    stride: 1,
    dilation: 1,
    size: 3,
    inputNum: 1)
  let highPlan = blaiPlanMemAlloc(highWeightLayer)
  check("NPU parse allocator high fits", highPlan.fits)
  checkEq("NPU parse allocator high branch",
    ord(highPlan.branch).uint32, ord(blaiMemAllocHighWeightPatch).uint32)
  checkEq("NPU parse allocator high estimate",
    highPlan.patch.estimatedWeightBytes, 32768)
  checkEq("NPU parse allocator high line count",
    highPlan.line.linePatchCount, 1)
  checkEq("NPU parse allocator high weight patches",
    highPlan.patch.weightPatchCount, 4)
  checkEq("NPU parse allocator high patch c",
    highPlan.patch.weightPatchOutC[0], 64)
  checkEq("NPU parse allocator high patch size",
    highPlan.patch.psramPatchSize, 512)
  checkEq("NPU parse allocator high patch count",
    highPlan.patch.psramPatchCount, 8)
  var highCtrl: BlaiPsramCtrl
  blaiApplyMemAllocPlan(highCtrl, highPlan)
  checkEq("NPU parse allocator high ctrl line",
    highCtrl.linePatchCount.uint32, 1)
  checkEq("NPU parse allocator high ctrl patch c",
    highCtrl.weightPatchOutC[3].uint32, 64)
  checkEq("NPU parse allocator high ctrl size",
    highCtrl.psramPatchSize.uint32, 512)

  let psramLayer = BlaiCpuInstLayer64(
    layerType: ord(blaiConvMax).int32,
    w: 8192,
    h: 1,
    c: 8,
    outW: 8192,
    outH: 1,
    outC: 8,
    groups: 1,
    stride: 1,
    dilation: 1,
    size: 1,
    inputNum: 1)
  let psramPlan = blaiPlanMemAlloc(psramLayer)
  check("NPU parse allocator psram fits", psramPlan.fits)
  checkEq("NPU parse allocator psram branch",
    ord(psramPlan.branch).uint32, ord(blaiMemAllocPsramPatch).uint32)
  checkEq("NPU parse allocator psram weight estimate",
    psramPlan.patch.estimatedWeightBytes, 8)
  checkEq("NPU parse allocator psram pressure",
    psramPlan.patch.estimatedPsramBytes, 4_194_304)
  checkEq("NPU parse allocator psram line count",
    psramPlan.line.linePatchCount, 16)
  checkEq("NPU parse allocator psram line width",
    psramPlan.line.linePatchW[0], 512)
  checkEq("NPU parse allocator psram weight patches",
    psramPlan.patch.weightPatchCount, 8)
  checkEq("NPU parse allocator psram patch c",
    psramPlan.patch.weightPatchOutC[7], 1)
  checkEq("NPU parse allocator psram patch size",
    psramPlan.patch.psramPatchSize, 8192)
  checkEq("NPU parse allocator psram patch count",
    psramPlan.patch.psramPatchCount, 16)
  var psramCtrl: BlaiPsramCtrl
  blaiApplyMemAllocPlan(psramCtrl, psramPlan)
  checkEq("NPU parse allocator psram ctrl line",
    psramCtrl.linePatchCount.uint32, 16)
  checkEq("NPU parse allocator psram ctrl width",
    psramCtrl.linePatchW[15].uint32, 512)
  checkEq("NPU parse allocator psram ctrl size",
    psramCtrl.psramPatchSize.uint32, 8192)

  let routeLineLayer = BlaiCpuInstLayer64(
    layerType: ord(blaiRouteConv).int32,
    w: 1024,
    h: 1,
    c: 4,
    cn: [4'i32, 0, 0, 0, 0, 0, 0],
    outW: 1024,
    outH: 1,
    outC: 8,
    groups: 1,
    stride: 1,
    dilation: 1,
    size: 3,
    inputNum: 2,
    midOut: 1)
  var routeLineInto: BlaiMemAllocLinePatchPlan
  blaiPlanLinePatchMemAllocInto(routeLineLayer, routeLineInto)
  let routeLinePlan = blaiPlanLinePatchMemAlloc(routeLineLayer)
  check("NPU parse allocator route line fits",
    sameLinePatchPlan(routeLineInto, routeLinePlan) and routeLinePlan.fits)
  check("NPU parse allocator route line routed",
    routeLinePlan.start.routed and routeLinePlan.start.routeChannels == 8)
  checkEq("NPU parse allocator route line start",
    routeLinePlan.startPatchCount, 2)
  checkEq("NPU parse allocator route line count",
    routeLinePlan.linePatchCount, 3)
  checkEq("NPU parse allocator route line input bytes",
    routeLinePlan.inputLineBytes, 2752)
  checkEq("NPU parse allocator route line output bytes",
    routeLinePlan.outputLineBytes, 2736)
  checkEq("NPU parse allocator route line first width",
    routeLinePlan.linePatchW[0], 342)
  checkEq("NPU parse allocator route line last width",
    routeLinePlan.linePatchW[2], 340)
  var routeLineCtrl: BlaiPsramCtrl
  blaiApplyLinePatchMemAlloc(routeLineCtrl, routeLinePlan)
  checkEq("NPU parse allocator route line ctrl count",
    routeLineCtrl.linePatchCount.uint32, 3)
  checkEq("NPU parse allocator route line ctrl last",
    routeLineCtrl.linePatchW[2].uint32, 340)

  let fetchGrowthLayer = BlaiCpuInstLayer64(
    layerType: ord(blaiConvolutional).int32,
    w: 4,
    h: 4,
    c: 3,
    cn: [5'i32, 0, 0, 0, 0, 0, 0],
    inputNum: 2)
  let fetchGrowthPlan = blaiPlanFetchMemory(
    fetchGrowthLayer,
    BlaiPsramCtrl(psramPatchSize: 1, psramPatchCount: 1),
    blaiFetchGeneral)
  check("NPU parse fetch growth fits", fetchGrowthPlan.fits)
  checkEq("NPU parse fetch growth patch size", fetchGrowthPlan.patchSize, 8)
  checkEq("NPU parse fetch growth budget",
    fetchGrowthPlan.patchBudget, BlaiFetchMaxPatchSlots)
  checkEq("NPU parse fetch growth total",
    fetchGrowthPlan.totalInputPatches, 16)
  checkEq("NPU parse fetch growth attempts",
    fetchGrowthPlan.growAttempts, 4)
  checkEq("NPU parse fetch growth count",
    fetchGrowthPlan.patchGrowCount, 3)

proc checkParsedWorkspaceExecution() =
  var parseOnlyLayers: array[1, BlaiCpuInstLayer64]
  let parsedStream = [
    baseHeader(1), baseLayerInfo(inputNum = 2),
    tfliteGeneral(blaiRouteConv), status(inputNum = 2)]
  let parsed = blaiParseCpuModelInstructions(parsedStream, parseOnlyLayers)
  var parsedLayers = [completeWorkspaceLayer()]
  var planningCtrl: BlaiPsramCtrl
  var planningStream: array[BlaiInstructionScratchSize div BlaiInstructionSize,
                            BlaiInstruction]
  let planningEncode = blaiEncodeCpuLayerWithAllocator(
    parsedLayers[0], planningCtrl, planningStream, true,
    c2 = 4, includeExtra = true)
  check("NPU parse execute preencoded", planningEncode.encoded)
  let plan = blaiPlanParsedForwardModelWorkspace(
    parsed, parsedLayers, baseAddress = 0x2208_0000'u32)
  let ready = blaiParsedForwardModelExecuteReadiness(parsed, plan, 2048)

  check("NPU parse execute parsed complete", parsed.complete)
  check("NPU parse execute plan ready", plan.planned and plan.workspaceReady)
  check("NPU parse execute readiness", ready.executable)
  checkEq("NPU parse execute workspace base", plan.workspace.baseAddress,
    0x2208_0000'u32)
  checkEq("NPU parse execute resource layers", plan.resources.layerCount, 1)
  checkEq("NPU parse execute plan layers", plan.readiness.layerCount, 1)
  checkEq("NPU parse execute ready layers", ready.layerCount, 1)

  var staleLayers = [completeWorkspaceLayer()]
  let stalePlan = blaiPlanParsedForwardModelWorkspace(
    parsed, staleLayers, baseAddress = 0x2208_0000'u32)
  var stalePlanningCtrl: BlaiPsramCtrl
  var stalePlanningStream: array[BlaiInstructionScratchSize div BlaiInstructionSize,
                                 BlaiInstruction]
  let staleEncode = blaiEncodeCpuLayerWithAllocator(
    staleLayers[0], stalePlanningCtrl, stalePlanningStream, true,
    c2 = 4, includeExtra = true)
  let staleReady = blaiParsedForwardModelExecuteReadiness(
    parsed, staleLayers, stalePlan, 2048)
  check("NPU parse execute stale encoded", staleEncode.encoded)
  check("NPU parse execute stale blocked", not staleReady.executable)
  check("NPU parse execute stale mismatch", not staleReady.planMatchesLayers)
  checkEq("NPU parse execute stale reason",
    ord(staleReady.firstBlock).uint32,
    ord(blaiParsedForwardModelExecutePlan).uint32)

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

  let execution = blaiMaterializeAndExecuteParsedForwardModelWorkspace(
    parsed, parsedLayers, plan, ctrl, stream, workspaceBytes,
    cpuWeightBytes = cpuWeights, cpuBiasBytes = cpuBiases,
    decodedWeights = decodedWeights, decodedBiases = decodedBiases,
    npuWeightBytes = npuWeights, npuBiases = npuBiases,
    temporaryWeights = temporaryWeights, executor = fakeForwardLayerExecutor,
    pack = 4, c2 = 4, includeExtra = true)
  check("NPU parse execute runnable", execution.execution.runnable)
  checkEq("NPU parse execute layer count", execution.execution.layerCount, 1)
  checkEq("NPU parse execute expected layers",
    execution.execution.expectedLayerCount, 1)
  check("NPU parse execute complete", execution.execution.allCompleted)
  checkEq("NPU parse execute materialized",
    execution.execution.materializedLayerCount, 1)
  checkEq("NPU parse execute completed",
    execution.execution.completedLayerCount, 1)
  checkEq("NPU parse execute weight cursor",
    execution.execution.nextWeightCursor.byteOffset, 288)
  checkEq("NPU parse execute bias cursor",
    execution.execution.nextBiasCursor.byteOffset, 16)
  check("NPU parse execute workspace instruction stored",
    blaiForwardWorkspaceSegmentByteEquals(
      plan.workspace.instruction, workspaceBytes, 0, stream[0][0]))
  check("NPU parse execute workspace weight stored",
    blaiForwardWorkspaceSegmentByteEquals(
      plan.workspace.weight, workspaceBytes, 0, npuWeights[0]))
  checkEq("NPU parse execute workspace bias stored",
    (if blaiForwardWorkspaceSegmentByteEquals(
      plan.workspace.bias, workspaceBytes, 0, 1'u8): 1'u32 else: 0'u32), 1)

  var parsedStates = [BlaiCpuParsedLayerState(
    active: true, index: 0, layer: completeWorkspaceLayer())]
  var statePlanningCtrl: BlaiPsramCtrl
  var statePlanningStream: array[BlaiInstructionScratchSize div BlaiInstructionSize,
                                 BlaiInstruction]
  let statePlanningEncode = blaiEncodeCpuLayerWithAllocator(
    parsedStates[0].layer, statePlanningCtrl, statePlanningStream, true,
    c2 = 4, includeExtra = true)
  check("NPU parse execute state preencoded", statePlanningEncode.encoded)
  let statePlan = blaiPlanParsedForwardModelWorkspace(
    parsed, parsedStates, baseAddress = 0x2208_0000'u32)
  var stateCtrl: BlaiPsramCtrl
  var stateStream: array[BlaiInstructionScratchSize div BlaiInstructionSize,
                         BlaiInstruction]
  var stateWorkspaceBytes: array[2048, uint8]
  var stateDecodedWeights: array[288, int32]
  var stateDecodedBiases: array[4, int32]
  var stateNpuWeights: array[288, uint8]
  var stateNpuBiases: array[4, int32]
  var stateTemporaryWeights: array[0, int32]
  let stateExecution = blaiMaterializeAndExecuteParsedForwardModelWorkspace(
    parsed, parsedStates, statePlan, stateCtrl, stateStream,
    stateWorkspaceBytes, cpuWeightBytes = cpuWeights,
    cpuBiasBytes = cpuBiases, decodedWeights = stateDecodedWeights,
    decodedBiases = stateDecodedBiases, npuWeightBytes = stateNpuWeights,
    npuBiases = stateNpuBiases, temporaryWeights = stateTemporaryWeights,
    executor = fakeForwardLayerExecutor, pack = 4, c2 = 4,
    includeExtra = true)
  check("NPU parse execute state ready", stateExecution.executable)
  check("NPU parse execute state complete",
    stateExecution.execution.allCompleted)
  checkEq("NPU parse execute state weight cursor",
    stateExecution.execution.nextWeightCursor.byteOffset, 288)

  var staleStates = [BlaiCpuParsedLayerState(
    active: true, index: 0, layer: completeWorkspaceLayer())]
  let staleStatePlan = blaiPlanParsedForwardModelWorkspace(
    parsed, staleStates, baseAddress = 0x2208_0000'u32)
  var staleStateCtrl: BlaiPsramCtrl
  var staleStateStream: array[BlaiInstructionScratchSize div BlaiInstructionSize,
                              BlaiInstruction]
  let staleStateEncode = blaiEncodeCpuLayerWithAllocator(
    staleStates[0].layer, staleStateCtrl, staleStateStream, true,
    c2 = 4, includeExtra = true)
  let staleStateReady = blaiParsedForwardModelExecuteReadiness(
    parsed, staleStates, staleStatePlan, 2048)
  check("NPU parse execute state stale encoded", staleStateEncode.encoded)
  check("NPU parse execute state stale blocked", not staleStateReady.executable)
  check("NPU parse execute state stale mismatch",
    not staleStateReady.planMatchesLayers)
  checkEq("NPU parse execute state stale reason",
    ord(staleStateReady.firstBlock).uint32,
    ord(blaiParsedForwardModelExecutePlan).uint32)

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
  let missingExecution = blaiMaterializeAndExecuteParsedForwardModelWorkspace(
    parsed, missingLayers, plan, missingCtrl, missingStream,
    missingWorkspaceBytes, cpuWeightBytes = cpuWeights,
    cpuBiasBytes = cpuBiases, decodedWeights = missingDecodedWeights,
    decodedBiases = missingDecodedBiases, npuWeightBytes = missingNpuWeights,
    npuBiases = missingNpuBiases, temporaryWeights = missingTemporaryWeights,
    executor = fakeForwardLayerExecutor, pack = 4, c2 = 4,
    includeExtra = true)
  check("NPU parse execute missing blocked", not missingExecution.executable)
  checkEq("NPU parse execute missing count",
    missingExecution.readiness.missingLayerCount, 1)
  checkEq("NPU parse execute missing layers",
    missingExecution.execution.layerCount, 0)

  let shortReady = blaiParsedForwardModelExecuteReadiness(parsed, plan, 16)
  check("NPU parse execute short workspace blocked", not shortReady.executable)
  check("NPU parse execute short workspace fit", not shortReady.workspaceFits)

proc main() {.exportc, cdecl.} =
  systemInit()
  heapInit()
  hwValidationLogReset()
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
  discard console.sendLine("=== BL808 NPU Parse Smoke Test ===")

  checkParseResultLifecycle()
  checkParsedBaseModel()
  checkParsedYoloSidecars()
  checkParsedExtraSidecars()
  checkParsedFloatAndSsd()
  checkParsedDispatchAndEligibility()
  checkParsedForwardWorkspacePlanning()
  checkAssignReleaseLayers()
  checkCpuOutputShapeLater()
  checkParsedWorkspaceExecution()
  checkAllocatorBackedEncode()
  checkFetchDescriptorOperands()
  checkInstructionEncodeBundle()
  checkAllocatorBranchPlans()

  if failed == 0:
    discard console.sendLine("[PASS] NPU parse smoke complete")
  else:
    discard console.sendString("[FAIL] NPU parse smoke failed count=")
    console.sendHex32(failed.uint32)
    discard console.sendLine("")

  while true:
    discard
