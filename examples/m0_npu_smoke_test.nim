## Focused BL808 BLAI/CNN NPU integration smoke test.
##
## This test covers only the recovered integration surface: clock/reset, SRAM
## ownership, Codec QoS/limiters, and the explicit unsupported layer-run path.

import bl808/startup
import bl808/glb
import bl808/gpio
import bl808/uart
import bl808/panicoverride
import bl808/kernel/alloc

# This broad smoke test exercises many recovered NPU helpers that are otherwise
# internal implementation details. Include the module so Nim emits the whole
# same-unit recovery oracle instead of relying on cross-module private symbols.
include bl808/npu

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
      console.sendHex32(compare.expectedAtFirstMismatch.uint8.uint32)
    if compare.actualPresentAtFirstMismatch:
      discard console.sendString(" actual=")
      console.sendHex32(compare.actualAtFirstMismatch.uint8.uint32)
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

proc checkCursorCompare(label: string, compare: BlaiCpuStreamCursorCompareResult) =
  if compare.matched:
    check(label, true)
  else:
    discard console.sendString("[FAIL] ")
    discard console.sendString(label)
    discard console.sendString(" expectedLayer=")
    console.sendHex32(compare.expected.layerIndex.uint32)
    discard console.sendString(" actualLayer=")
    console.sendHex32(compare.actual.layerIndex.uint32)
    discard console.sendString(" expectedByte=")
    console.sendHex32(compare.expected.byteOffset)
    discard console.sendString(" actualByte=")
    console.sendHex32(compare.actual.byteOffset)
    discard console.sendLine("")
    inc failed

proc checkFetchDescriptorOperands() =
  let secondInputOperands = blaiPlanFetchDescriptorOperands(
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
  var secondInputOperandsInto: BlaiFetchDescriptorOperands
  blaiPlanFetchDescriptorOperandsInto(BlaiCpuInstLayer64(
    layerType: ord(blaiConvolutional).int32,
    n: 2,
    cn: [5'i32, 0, 0, 0, 0, 0, 0],
    groups: 1,
    stride: 1,
    dilation: 1,
    size: 3), BlaiPsramCtrl(weightPatchCount: 1, linePatchCount: 1),
    blaiFetchGeneral, secondInputOperandsInto)
  check("NPU fetch operand into equal",
    secondInputOperandsInto == secondInputOperands)
  checkEq("NPU fetch operand c2", secondInputOperands.c2, 8)
  check("NPU fetch operand no extra", not secondInputOperands.includeExtra)

  let groupedOperands = blaiPlanFetchDescriptorOperands(
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
  checkEq("NPU fetch operand grouped c2", groupedOperands.c2, 8)
  check("NPU fetch operand grouped extra", groupedOperands.includeExtra)

  let comboFlatOperands = blaiPlanFetchDescriptorOperands(
    BlaiCpuInstLayer64(
      layerType: ord(blaiConvMax).int32,
      groups: 2,
      stride: 1,
      dilation: 2,
      size: 5),
    BlaiPsramCtrl(weightPatchCount: 3, linePatchCount: 1),
    blaiFetchGeneral)
  check("NPU fetch operand combo flat", not comboFlatOperands.includeExtra)

  let comboLineOperands = blaiPlanFetchDescriptorOperands(
    BlaiCpuInstLayer64(
      layerType: ord(blaiConvMax).int32,
      groups: 1,
      stride: 1,
      dilation: 1,
      size: 5),
    BlaiPsramCtrl(weightPatchCount: 1, linePatchCount: 2),
    blaiFetchGeneral)
  var comboLineOperandsInto: BlaiFetchDescriptorOperands
  blaiPlanFetchDescriptorOperandsInto(BlaiCpuInstLayer64(
    layerType: ord(blaiConvMax).int32,
    groups: 1,
    stride: 1,
    dilation: 1,
    size: 5), BlaiPsramCtrl(weightPatchCount: 1, linePatchCount: 2),
    blaiFetchGeneral, comboLineOperandsInto)
  check("NPU fetch operand combo into equal",
    comboLineOperandsInto == comboLineOperands)
  check("NPU fetch operand combo line", comboLineOperands.includeExtra)

proc checkRouteDescriptorLoopPlan() =
  let routeLoopPlan = blaiPlanRouteDescriptorLoop(BlaiCpuInstLayer64(
    layerType: ord(blaiRoute).int32,
    c: 3,
    cn: [5'i32, 7, 11, 0, 0, 0, 0],
    inputNum: 4))
  var routeLoopPlanInto: BlaiRouteDescriptorLoopPlan
  blaiPlanRouteDescriptorLoopInto(BlaiCpuInstLayer64(
    layerType: ord(blaiRoute).int32,
    c: 3,
    cn: [5'i32, 7, 11, 0, 0, 0, 0],
    inputNum: 4), routeLoopPlanInto)
  check("NPU route loop into equal", routeLoopPlanInto == routeLoopPlan)
  check("NPU route loop fits", routeLoopPlan.fits)
  checkEq("NPU route loop count", routeLoopPlan.descriptorCount, 3)
  checkEq("NPU route loop c1 first", routeLoopPlan.steps[0].descriptorC1, 3)
  checkEq("NPU route loop c2 first", routeLoopPlan.steps[0].descriptorC2, 5)
  checkEq("NPU route loop c1 second", routeLoopPlan.steps[1].descriptorC1, 8)
  checkEq("NPU route loop c2 third", routeLoopPlan.steps[2].descriptorC2, 11)
  checkEq("NPU route loop final",
    routeLoopPlan.steps[2].cumulativeOutputChannels, 26)

  let routeLoopMinPlan = blaiPlanRouteDescriptorLoop(BlaiCpuInstLayer64(
    layerType: ord(blaiRoute).int32,
    c: 3,
    inputNum: 1))
  var routeLoopMinPlanInto: BlaiRouteDescriptorLoopPlan
  blaiPlanRouteDescriptorLoopInto(BlaiCpuInstLayer64(
    layerType: ord(blaiRoute).int32,
    c: 3,
    inputNum: 1), routeLoopMinPlanInto)
  check("NPU route loop min into equal",
    routeLoopMinPlanInto == routeLoopMinPlan)
  check("NPU route loop min fits", routeLoopMinPlan.fits)
  checkEq("NPU route loop min inputs", routeLoopMinPlan.inputCount, 2)
  checkEq("NPU route loop min count", routeLoopMinPlan.descriptorCount, 1)
  checkEq("NPU route loop min c2", routeLoopMinPlan.steps[0].descriptorC2, 0)

  let routeLoopTooWide = blaiPlanRouteDescriptorLoop(BlaiCpuInstLayer64(
    layerType: ord(blaiRoute).int32,
    c: 3,
    inputNum: 9))
  var routeLoopTooWideInto: BlaiRouteDescriptorLoopPlan
  blaiPlanRouteDescriptorLoopInto(BlaiCpuInstLayer64(
    layerType: ord(blaiRoute).int32,
    c: 3,
    inputNum: 9), routeLoopTooWideInto)
  check("NPU route loop bounds into equal",
    routeLoopTooWideInto == routeLoopTooWide)
  check("NPU route loop bounds", not routeLoopTooWide.fits)

  var routeSlotLayer = BlaiCpuInstLayer64(
    layerType: ord(blaiRoute).int32,
    w: 4,
    h: 4,
    c: 3,
    cn: [5'i32, 7, 0, 0, 0, 0, 0],
    outW: 4,
    outH: 4,
    inputNum: 3,
    groups: 0)
  var routeSlotCtrl = BlaiPsramCtrl(psramPatchSize: 32, psramPatchCount: 4)
  routeSlotCtrl.linePatchW[0] = 4
  let routeSlotPlan = blaiPlanRouteSramSlots(routeSlotLayer, routeSlotCtrl)
  check("NPU route slots fit", routeSlotPlan.fits)
  checkEq("NPU route slots patch", routeSlotPlan.memory.patchSize, 64)
  checkEq("NPU route slots out count", routeSlotPlan.outputSlotCount, 2)
  checkEq("NPU route slots out0", routeSlotPlan.outputSlots[0], 5)
  checkEq("NPU route slots out1", routeSlotPlan.outputSlots[1], 9)
  checkEq("NPU route slots final", routeSlotPlan.finalPatchCursor, 11)
  blaiApplyRouteSramSlotPlan(routeSlotCtrl, routeSlotLayer, routeSlotPlan)
  checkEq("NPU route slots ctrl in2",
    cast[uint32](routeSlotCtrl.sramIn[2]), 3)
  checkEq("NPU route slots ctrl out0",
    cast[uint32](routeSlotCtrl.sramOut[0]), 5)
  checkEq("NPU route slots ctrl out1",
    cast[uint32](routeSlotCtrl.sramOut[1]), 9)
  checkEq("NPU route slots line",
    cast[uint32](routeSlotCtrl.lineW0), 4)
  checkEq("NPU route slots groups", cast[uint32](routeSlotLayer.groups), 1)
  checkEq("NPU route slots layer patches",
    cast[uint32](routeSlotLayer.dramPatchNum), 11)

proc checkForwardTensorIo() =
  let tinyForwardLayer = BlaiCpuInstLayer64(
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
  let tinyForwardPlan = blaiPlanForwardNpu(
    tinyForwardLayer, layerIndex = 0, dataBufferBytes = 8)
  var tinyForwardInput = [7'u8]
  var tinyForwardBuffer: array[8, uint8]
  let forwardInputMove = blaiStageForwardNpuInput(
    tinyForwardPlan, 0, tinyForwardInput, tinyForwardBuffer)
  check("NPU forward input move runnable", forwardInputMove.readiness.runnable)
  check("NPU forward input move active", forwardInputMove.readiness.active)
  check("NPU forward input move fits",
    forwardInputMove.readiness.bufferFits and
      forwardInputMove.readiness.tensorFits and
      forwardInputMove.readiness.ready)
  check("NPU forward input moved", forwardInputMove.moved)
  checkEq("NPU forward input padded value", tinyForwardBuffer[0].uint32, 7)
  var shortForwardInput: array[0, uint8]
  let shortForwardInputMove = blaiStageForwardNpuInput(
    tinyForwardPlan, 0, shortForwardInput, tinyForwardBuffer)
  check("NPU forward input rejects short tensor",
    not shortForwardInputMove.readiness.tensorFits and
      not shortForwardInputMove.readiness.ready and
      not shortForwardInputMove.moved)
  var smallForwardBuffer: array[7, uint8]
  let smallForwardInputMove = blaiStageForwardNpuInput(
    tinyForwardPlan, 0, tinyForwardInput, smallForwardBuffer)
  check("NPU forward input rejects short buffer",
    not smallForwardInputMove.readiness.bufferFits and
      not smallForwardInputMove.readiness.ready and
      not smallForwardInputMove.moved)
  tinyForwardBuffer[4] = 33
  var forwardOutputTensor: array[1, uint8]
  let forwardOutputMove = blaiLoadForwardNpuOutput(
    tinyForwardPlan, blaiForwardPrimaryOutput,
    tinyForwardBuffer, forwardOutputTensor)
  check("NPU forward output move runnable", forwardOutputMove.readiness.runnable)
  check("NPU forward output move active", forwardOutputMove.readiness.active)
  check("NPU forward output move fits",
    forwardOutputMove.readiness.bufferFits and
      forwardOutputMove.readiness.tensorFits and
      forwardOutputMove.readiness.ready)
  check("NPU forward output moved", forwardOutputMove.moved)
  checkEq("NPU forward output compact value", forwardOutputTensor[0].uint32, 33)

proc checkReferenceLayerOracles() =
  var emptyFixedInput: array[0, int8]
  var emptyExtraInputs: BlaiCpuExtraInputStorage
  var fixedDecodedWeights: array[1, int8]
  var fixedDecodedBiases: array[1, int8]
  var fixedConvOut: array[4, int8]
  let fixedConvLayer = BlaiCpuInstLayer64(
    layerType: ord(blaiConvolutional).int32,
    activation: ord(blaiActLinear).int32,
    dspOn: 1,
    dataType: 1,
    w: 2, h: 2, c: 1, outC: 1,
    size: 1, stride: 1, dilation: 1, groups: 1)
  let fixedConv = blaiReferenceFixedParsedSingleLayer2d(
    fixedConvLayer,
    emptyExtraInputs,
    layerIndex = 0,
    active = true,
    useTflite = false,
    input1 = [1'i8, 2, 3, 4],
    input2 = emptyFixedInput,
    cpuWeightBytes = [2'u8],
    cpuBiasBytes = [0'u8],
    weightCursor = blaiCpuStreamCursor(),
    biasCursor = blaiCpuStreamCursor(),
    decodedWeights = fixedDecodedWeights,
    decodedBiases = fixedDecodedBiases,
    output = fixedConvOut)
  check("NPU fixed reference conv", fixedConv.readiness.executed)
  checkCursorCompare("NPU fixed reference conv weight cursor",
    blaiCompareCpuStreamCursor(
      blaiCpuStreamCursor(layerIndex = 1, byteOffset = 1),
      fixedConv.nextWeightCursor))
  checkCursorCompare("NPU fixed reference conv bias cursor",
    blaiCompareCpuStreamCursor(
      blaiCpuStreamCursor(layerIndex = 1, byteOffset = 1),
      fixedConv.nextBiasCursor))
  var fixedPoolOut: array[4, int8]
  let fixedPoolLayer = BlaiCpuInstLayer64(
    layerType: ord(blaiMaxpool).int32,
    w: 2, h: 2, c: 1,
    size: 1, stride: 1, dilation: 1)
  let fixedPool = blaiReferenceFixedParsedSingleLayer2d(
    fixedPoolLayer,
    emptyExtraInputs,
    layerIndex = 1,
    active = true,
    useTflite = false,
    input1 = fixedConvOut,
    input2 = emptyFixedInput,
    cpuWeightBytes = [2'u8],
    cpuBiasBytes = [0'u8],
    weightCursor = fixedConv.nextWeightCursor,
    biasCursor = fixedConv.nextBiasCursor,
    decodedWeights = fixedDecodedWeights,
    decodedBiases = fixedDecodedBiases,
    output = fixedPoolOut)
  check("NPU fixed reference pool", fixedPool.readiness.executed)
  checkCursorCompare("NPU fixed reference pool weight cursor",
    blaiCompareCpuStreamCursor(
      blaiCpuStreamCursor(layerIndex = 1, byteOffset = 1),
      fixedPool.nextWeightCursor))
  checkCursorCompare("NPU fixed reference pool bias cursor",
    blaiCompareCpuStreamCursor(
      blaiCpuStreamCursor(layerIndex = 1, byteOffset = 1),
      fixedPool.nextBiasCursor))
  checkOutputCompare("NPU fixed reference conv output",
    blaiCompareInt8Outputs([2'i8, 4, 6, 8], fixedConvOut))
  checkOutputCompare("NPU fixed reference pool output",
    blaiCompareInt8Outputs([2'i8, 4, 6, 8], fixedPoolOut))

  var fixedUpsampleOut: array[8, int8]
  let fixedUpsampleLayer = BlaiCpuInstLayer64(
    layerType: ord(blaiUpsample).int32,
    w: 2, h: 1, c: 1,
    stride: 2,
    fdata: 0, fout: 0)
  let fixedUpsample = blaiReferenceFixedParsedSingleLayer2d(
    fixedUpsampleLayer,
    emptyExtraInputs,
    layerIndex = 2,
    active = true,
    useTflite = false,
    input1 = [1'i8, 2],
    input2 = emptyFixedInput,
    cpuWeightBytes = [2'u8],
    cpuBiasBytes = [0'u8],
    weightCursor = fixedPool.nextWeightCursor,
    biasCursor = fixedPool.nextBiasCursor,
    decodedWeights = fixedDecodedWeights,
    decodedBiases = fixedDecodedBiases,
    output = fixedUpsampleOut)
  check("NPU fixed reference upsample", fixedUpsample.readiness.executed)
  checkEq("NPU fixed reference upsample width",
    fixedUpsample.reference.outputW, 4'u32)
  checkCursorCompare("NPU fixed reference upsample weight cursor",
    blaiCompareCpuStreamCursor(fixedPool.nextWeightCursor,
      fixedUpsample.nextWeightCursor))
  checkCursorCompare("NPU fixed reference upsample bias cursor",
    blaiCompareCpuStreamCursor(fixedPool.nextBiasCursor,
      fixedUpsample.nextBiasCursor))
  checkOutputCompare("NPU fixed reference upsample output",
    blaiCompareInt8Outputs([1'i8, 1, 2, 2, 1, 1, 2, 2], fixedUpsampleOut))

  var fixedRouteUpsampleOut: array[8, int8]
  let fixedRouteUpsample = blaiReferenceRouteUpsample2d(
    BlaiReferenceRouteUpsample2d(
      width: 1, height: 1,
      route1C: 1, route2C: 1,
      stride: 2),
    [3'i8],
    [5'i8],
    fixedRouteUpsampleOut)
  check("NPU fixed reference route upsample fits", fixedRouteUpsample.fits)
  checkEq("NPU fixed reference route upsample channels",
    fixedRouteUpsample.outputC, 2'u32)
  checkOutputCompare("NPU fixed reference route upsample output",
    blaiCompareInt8Outputs([3'i8, 5, 3, 5, 3, 5, 3, 5],
      fixedRouteUpsampleOut))

  var fixedMatmulWeights: array[4, int8]
  var fixedMatmulBiases: array[2, int8]
  var fixedMatmulOut: array[4, int8]
  let fixedMatmulLayer = BlaiCpuInstLayer64(
    layerType: ord(blaiMatmul).int32,
    activation: ord(blaiActLinear).int32,
    dataType: 1,
    w: 1, h: 2, c: 2, outC: 2,
    size: 1, groups: 1)
  let fixedMatmul = blaiReferenceFixedParsedSingleLayer2d(
    fixedMatmulLayer,
    emptyExtraInputs,
    layerIndex = 3,
    active = true,
    useTflite = false,
    input1 = [1'i8, 2, 3, 4],
    input2 = emptyFixedInput,
    cpuWeightBytes = [0'u8, 1, 1, 1, 255],
    cpuBiasBytes = [0'u8, 0, 0],
    weightCursor = fixedUpsample.nextWeightCursor,
    biasCursor = fixedUpsample.nextBiasCursor,
    decodedWeights = fixedMatmulWeights,
    decodedBiases = fixedMatmulBiases,
    output = fixedMatmulOut)
  check("NPU fixed reference matmul", fixedMatmul.readiness.executed)
  checkEq("NPU fixed reference matmul channels",
    fixedMatmul.reference.outputC, 2'u32)
  checkCursorCompare("NPU fixed reference matmul weight cursor",
    blaiCompareCpuStreamCursor(
      blaiCpuStreamCursor(layerIndex = 4, byteOffset = 5),
      fixedMatmul.nextWeightCursor))
  checkCursorCompare("NPU fixed reference matmul bias cursor",
    blaiCompareCpuStreamCursor(
      blaiCpuStreamCursor(layerIndex = 4, byteOffset = 3),
      fixedMatmul.nextBiasCursor))
  checkOutputCompare("NPU fixed reference matmul output",
    blaiCompareInt8Outputs([3'i8, -1, 7, -1], fixedMatmulOut))

  var fixedConvMaxWeights: array[1, int8]
  var fixedConvMaxBiases: array[1, int8]
  var fixedConvMaxOut: array[4, int8]
  let fixedConvMaxLayer = BlaiCpuInstLayer64(
    layerType: ord(blaiConvMax).int32,
    activation: ord(blaiActLinear).int32,
    dataType: 1,
    w: 3, h: 3, c: 1, outC: 1,
    size: 1, stride: 1, dilation: 1, groups: 1)
  let fixedConvMax = blaiReferenceFixedParsedSingleLayer2d(
    fixedConvMaxLayer,
    emptyExtraInputs,
    layerIndex = 4,
    active = true,
    useTflite = false,
    input1 = [1'i8, 2, 3, 4, 5, 6, 7, 8, 9],
    input2 = emptyFixedInput,
    cpuWeightBytes = [0'u8, 1, 1, 1, 255, 1],
    cpuBiasBytes = [0'u8, 0, 0, 0],
    weightCursor = fixedMatmul.nextWeightCursor,
    biasCursor = fixedMatmul.nextBiasCursor,
    decodedWeights = fixedConvMaxWeights,
    decodedBiases = fixedConvMaxBiases,
    output = fixedConvMaxOut)
  check("NPU fixed reference conv max", fixedConvMax.readiness.executed)
  checkEq("NPU fixed reference conv max width",
    fixedConvMax.reference.outputW, 2'u32)
  checkCursorCompare("NPU fixed reference conv max weight cursor",
    blaiCompareCpuStreamCursor(
      blaiCpuStreamCursor(layerIndex = 5, byteOffset = 6),
      fixedConvMax.nextWeightCursor))
  checkCursorCompare("NPU fixed reference conv max bias cursor",
    blaiCompareCpuStreamCursor(
      blaiCpuStreamCursor(layerIndex = 5, byteOffset = 4),
      fixedConvMax.nextBiasCursor))
  checkOutputCompare("NPU fixed reference conv max output",
    blaiCompareInt8Outputs([5'i8, 6, 8, 9], fixedConvMaxOut))

  var emptyTfliteInput: array[0, uint8]
  var tfliteBiases: array[1, int32]
  var tfliteConvOut: array[4, uint8]
  let tfliteConvLayer =
    BlaiCpuInstLayer64(
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
      quantizedActivationMax: 255)
  let tfliteConv = blaiReferenceTfliteParsedSingleLayer2d(
    tfliteConvLayer,
    emptyExtraInputs,
    layerIndex = 0,
    active = true,
    useTflite = true,
    input1 = [1'u8, 2, 3, 4],
    input2 = emptyTfliteInput,
    cpuWeightBytes = [2'u8],
    cpuBiasBytes = [0'u8, 0, 0, 0],
    weightCursor = blaiCpuStreamCursor(),
    biasCursor = blaiCpuStreamCursor(),
    decodedBiases = tfliteBiases,
    output = tfliteConvOut)
  check("NPU TFLite reference conv", tfliteConv.readiness.executed)
  checkCursorCompare("NPU TFLite reference conv weight cursor",
    blaiCompareCpuStreamCursor(
      blaiCpuStreamCursor(layerIndex = 1, byteOffset = 1),
      tfliteConv.nextWeightCursor))
  checkCursorCompare("NPU TFLite reference conv bias cursor",
    blaiCompareCpuStreamCursor(
      blaiCpuStreamCursor(layerIndex = 1, byteOffset = 4),
      tfliteConv.nextBiasCursor))
  var tflitePoolOut: array[1, uint8]
  let tflitePoolLayer = BlaiCpuInstLayer64(
    layerType: ord(blaiAvgpool).int32,
    w: 2, h: 2, c: 1, outC: 1,
    stride: 1,
    quantizedActivationMin: 0,
    quantizedActivationMax: 255)
  let tflitePool = blaiReferenceTfliteParsedSingleLayer2d(
    tflitePoolLayer,
    emptyExtraInputs,
    layerIndex = 1,
    active = true,
    useTflite = true,
    input1 = tfliteConvOut,
    input2 = emptyTfliteInput,
    cpuWeightBytes = [2'u8],
    cpuBiasBytes = [0'u8, 0, 0, 0],
    weightCursor = tfliteConv.nextWeightCursor,
    biasCursor = tfliteConv.nextBiasCursor,
    decodedBiases = tfliteBiases,
    output = tflitePoolOut)
  check("NPU TFLite reference pool", tflitePool.readiness.executed)
  checkCursorCompare("NPU TFLite reference pool weight cursor",
    blaiCompareCpuStreamCursor(
      blaiCpuStreamCursor(layerIndex = 1, byteOffset = 1),
      tflitePool.nextWeightCursor))
  checkCursorCompare("NPU TFLite reference pool bias cursor",
    blaiCompareCpuStreamCursor(
      blaiCpuStreamCursor(layerIndex = 1, byteOffset = 4),
      tflitePool.nextBiasCursor))
  checkOutputCompare("NPU TFLite reference conv output",
    blaiCompareUint8Outputs([2'u8, 4, 6, 8], tfliteConvOut))
  checkOutputCompare("NPU TFLite reference pool output",
    blaiCompareUint8Outputs([5'u8], tflitePoolOut))

  var tfliteConvMaxOut: array[4, uint8]
  let tfliteConvMaxLayer =
    BlaiCpuInstLayer64(
      layerType: ord(blaiConvMax).int32,
      w: 3, h: 3, c: 1, outC: 1,
      size: 1, stride: 1, dilation: 1, groups: 1,
      tfInput1Offset: 0,
      tfInput2Offset: 0,
      tfOutputOffset: 0,
      tfOutputMultiplier: high(int32),
      tfOutputShift: 0,
      quantizedActivationMin: 0,
      quantizedActivationMax: 255)
  let tfliteConvMax = blaiReferenceTfliteParsedSingleLayer2d(
    tfliteConvMaxLayer,
    emptyExtraInputs,
    layerIndex = 2,
    active = true,
    useTflite = true,
    input1 = [1'u8, 2, 3, 4, 5, 6, 7, 8, 9],
    input2 = emptyTfliteInput,
    cpuWeightBytes = [2'u8, 1],
    cpuBiasBytes = [0'u8, 0, 0, 0, 0, 0, 0, 0],
    weightCursor = tfliteConv.nextWeightCursor,
    biasCursor = tfliteConv.nextBiasCursor,
    decodedBiases = tfliteBiases,
    output = tfliteConvMaxOut)
  check("NPU TFLite reference conv max", tfliteConvMax.readiness.executed)
  checkEq("NPU TFLite reference conv max width",
    tfliteConvMax.reference.outputW, 2'u32)
  checkCursorCompare("NPU TFLite reference conv max weight cursor",
    blaiCompareCpuStreamCursor(
      blaiCpuStreamCursor(layerIndex = 3, byteOffset = 2),
      tfliteConvMax.nextWeightCursor))
  checkCursorCompare("NPU TFLite reference conv max bias cursor",
    blaiCompareCpuStreamCursor(
      blaiCpuStreamCursor(layerIndex = 3, byteOffset = 8),
      tfliteConvMax.nextBiasCursor))
  checkOutputCompare("NPU TFLite reference conv max output",
    blaiCompareUint8Outputs([5'u8, 6, 8, 9], tfliteConvMaxOut))

  var tfliteMaxPoolOut: array[4, uint8]
  let tfliteMaxPoolLayer =
    BlaiCpuInstLayer64(
      layerType: ord(blaiMaxpool).int32,
      w: 4, h: 4, c: 1,
      size: 1, stride: 2, dilation: 1,
      tfInput1Offset: 0,
      tfOutputMultiplier: high(int32),
      tfOutputShift: 0,
      quantizedActivationMin: 0,
      quantizedActivationMax: 255)
  let tfliteMaxPool = blaiReferenceTfliteParsedSingleLayer2d(
    tfliteMaxPoolLayer,
    emptyExtraInputs,
    layerIndex = 3,
    active = true,
    useTflite = true,
    input1 = [1'u8, 2, 3, 4,
              5'u8, 6, 7, 8,
              9'u8, 10, 11, 12,
              13'u8, 14, 15, 16],
    input2 = emptyTfliteInput,
    cpuWeightBytes = [2'u8, 1],
    cpuBiasBytes = [0'u8, 0, 0, 0, 0, 0, 0, 0],
    weightCursor = tfliteConvMax.nextWeightCursor,
    biasCursor = tfliteConvMax.nextBiasCursor,
    decodedBiases = tfliteBiases,
    output = tfliteMaxPoolOut)
  check("NPU TFLite reference maxpool", tfliteMaxPool.readiness.executed)
  checkEq("NPU TFLite reference maxpool width",
    tfliteMaxPool.reference.outputW, 2'u32)
  checkCursorCompare("NPU TFLite reference maxpool weight cursor",
    blaiCompareCpuStreamCursor(tfliteConvMax.nextWeightCursor,
      tfliteMaxPool.nextWeightCursor))
  checkCursorCompare("NPU TFLite reference maxpool bias cursor",
    blaiCompareCpuStreamCursor(tfliteConvMax.nextBiasCursor,
      tfliteMaxPool.nextBiasCursor))
  checkOutputCompare("NPU TFLite reference maxpool output",
    blaiCompareUint8Outputs([6'u8, 8, 14, 16], tfliteMaxPoolOut))

  var tfliteShortcutOut: array[2, uint8]
  let tfliteShortcutLayer =
    BlaiCpuInstLayer64(
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
      quantizedActivationMax: 255)
  let tfliteShortcut = blaiReferenceTfliteParsedSingleLayer2d(
    tfliteShortcutLayer,
    emptyExtraInputs,
    layerIndex = 4,
    active = true,
    useTflite = true,
    input1 = [7'u8, 3],
    input2 = [5'u8, 4],
    cpuWeightBytes = [2'u8, 1],
    cpuBiasBytes = [0'u8, 0, 0, 0, 0, 0, 0, 0],
    weightCursor = tfliteMaxPool.nextWeightCursor,
    biasCursor = tfliteMaxPool.nextBiasCursor,
    decodedBiases = tfliteBiases,
    output = tfliteShortcutOut)
  check("NPU TFLite reference shortcut", tfliteShortcut.readiness.executed)
  checkEq("NPU TFLite reference shortcut width",
    tfliteShortcut.reference.outputW, 2'u32)
  checkCursorCompare("NPU TFLite reference shortcut weight cursor",
    blaiCompareCpuStreamCursor(tfliteMaxPool.nextWeightCursor,
      tfliteShortcut.nextWeightCursor))
  checkCursorCompare("NPU TFLite reference shortcut bias cursor",
    blaiCompareCpuStreamCursor(tfliteMaxPool.nextBiasCursor,
      tfliteShortcut.nextBiasCursor))
  checkOutputCompare("NPU TFLite reference shortcut output",
    blaiCompareUint8Outputs([12'u8, 7], tfliteShortcutOut))

proc checkReferenceTfliteNmsisOracles() =
  var tfliteDepthwiseOut: array[4, uint8]
  let tfliteDepthwise = blaiReferenceDepthwiseConv2d(
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
    tfliteDepthwiseOut)
  check("NPU TFLite depthwise nmsis fits", tfliteDepthwise.fits)
  checkEq("NPU TFLite depthwise nmsis channels",
    tfliteDepthwise.outputC, 1'u32)
  checkOutputCompare("NPU TFLite depthwise nmsis output",
    blaiCompareUint8Outputs([1'u8, 2, 3, 4], tfliteDepthwiseOut))

  var tfliteConvNmsisOut: array[4, uint8]
  let tfliteConvNmsis = blaiReferenceTfliteConv2d(
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
    tfliteConvNmsisOut)
  check("NPU TFLite conv nmsis fits", tfliteConvNmsis.fits)
  checkEq("NPU TFLite conv nmsis channels",
    tfliteConvNmsis.outputC, 1'u32)
  checkOutputCompare("NPU TFLite conv nmsis output",
    blaiCompareUint8Outputs([2'u8, 4, 6, 8], tfliteConvNmsisOut))

  var tfliteMaxPoolNmsisOut: array[4, uint8]
  let tfliteMaxPoolNmsis = blaiReferenceMaxPool2d(
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
    tfliteMaxPoolNmsisOut)
  check("NPU TFLite maxpool nmsis fits", tfliteMaxPoolNmsis.fits)
  checkEq("NPU TFLite maxpool nmsis width",
    tfliteMaxPoolNmsis.outputW, 2'u32)
  checkOutputCompare("NPU TFLite maxpool nmsis output",
    blaiCompareUint8Outputs([6'u8, 8, 14, 16], tfliteMaxPoolNmsisOut))

proc checkReferenceParsedModelOracles() =
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
  check("NPU fixed parsed model preflight", fixedChecked.preflight.fit.fits)
  check("NPU fixed parsed model checked", fixedChecked.readiness.execute)
  checkEq("NPU fixed parsed model check block",
    ord(fixedChecked.readiness.firstBlock).uint32,
    ord(blaiRefFixedCheckedNoBlock).uint32)
  check("NPU fixed parsed model check no activation first",
    fixedChecked.readiness.firstUnsupportedActivationShapeLayer < 0)
  check("NPU fixed parsed model check no weight first",
    fixedChecked.readiness.firstUnsupportedWeightStorageLayer < 0)
  check("NPU fixed parsed model executed", fixedChecked.executed)
  check("NPU fixed parsed model valid", fixedChecked.model.modelValid)
  checkEq("NPU fixed parsed model completed",
    fixedChecked.model.completedLayerCount, 2)
  checkCursorCompare("NPU fixed parsed model weight cursor",
    blaiCompareCpuStreamCursor(
      blaiCpuStreamCursor(layerIndex = 1, byteOffset = 1),
      fixedChecked.model.nextWeightCursor))
  checkCursorCompare("NPU fixed parsed model bias cursor",
    blaiCompareCpuStreamCursor(
      blaiCpuStreamCursor(layerIndex = 1, byteOffset = 1),
      fixedChecked.model.nextBiasCursor))
  checkOutputCompare("NPU fixed parsed model output",
    blaiCompareInt8Outputs([2'i8, 4, 6, 8], fixedOut))

  var shortFixedInput: array[2, int8] = [1'i8, 2]
  var shortFixedOut: array[4, int8]
  let shortFixedChecked = blaiReferenceFixedParsedCheckedModel2d(
    fixedLayers,
    useTflite = false,
    input = shortFixedInput,
    cpuWeightBytes = [2'u8],
    cpuBiasBytes = [0'u8],
    decodedWeights = fixedWeights,
    decodedBiases = fixedBiases,
    scratchA = fixedScratchA,
    scratchB = fixedScratchB,
    output = shortFixedOut)
  check("NPU fixed parsed model rejects short input",
    not shortFixedChecked.preflight.fit.modelInputFit and
      not shortFixedChecked.readiness.execute and
      not shortFixedChecked.executed)
  checkEq("NPU fixed parsed model short block",
    ord(shortFixedChecked.readiness.firstBlock).uint32,
    ord(blaiRefFixedCheckedBuffersDoNotFit).uint32)
  check("NPU fixed parsed model short no activation first",
    shortFixedChecked.readiness.firstUnsupportedActivationShapeLayer < 0)
  check("NPU fixed parsed model short no weight first",
    shortFixedChecked.readiness.firstUnsupportedWeightStorageLayer < 0)

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
  check("NPU TFLite parsed model preflight", tfliteChecked.preflight.fit.fits)
  check("NPU TFLite parsed model checked", tfliteChecked.readiness.execute)
  checkEq("NPU TFLite parsed model check block",
    ord(tfliteChecked.readiness.firstBlock).uint32,
    ord(blaiRefTfliteCheckedNoBlock).uint32)
  check("NPU TFLite parsed model check no activation first",
    tfliteChecked.readiness.firstUnsupportedActivationShapeLayer < 0)
  check("NPU TFLite parsed model executed", tfliteChecked.executed)
  check("NPU TFLite parsed model valid", tfliteChecked.model.modelValid)
  checkEq("NPU TFLite parsed model completed",
    tfliteChecked.model.completedLayerCount, 2)
  checkCursorCompare("NPU TFLite parsed model weight cursor",
    blaiCompareCpuStreamCursor(
      blaiCpuStreamCursor(layerIndex = 1, byteOffset = 1),
      tfliteChecked.model.nextWeightCursor))
  checkCursorCompare("NPU TFLite parsed model bias cursor",
    blaiCompareCpuStreamCursor(
      blaiCpuStreamCursor(layerIndex = 1, byteOffset = 4),
      tfliteChecked.model.nextBiasCursor))
  checkOutputCompare("NPU TFLite parsed model output",
    blaiCompareUint8Outputs([5'u8], tfliteOut))

  var shortTfliteInput: array[2, uint8] = [1'u8, 2]
  var shortTfliteOut: array[1, uint8]
  let shortTfliteChecked = blaiReferenceTfliteParsedCheckedModel2d(
    tfliteLayers,
    useTflite = true,
    input = shortTfliteInput,
    cpuWeightBytes = [2'u8],
    cpuBiasBytes = [0'u8, 0, 0, 0],
    decodedBiases = tfliteBiases,
    scratchA = tfliteScratchA,
    scratchB = tfliteScratchB,
    output = shortTfliteOut)
  check("NPU TFLite parsed model rejects short input",
    not shortTfliteChecked.preflight.fit.modelInputFit and
      not shortTfliteChecked.readiness.execute and
      not shortTfliteChecked.executed)
  checkEq("NPU TFLite parsed model short block",
    ord(shortTfliteChecked.readiness.firstBlock).uint32,
    ord(blaiRefTfliteCheckedBuffersDoNotFit).uint32)
  check("NPU TFLite parsed model short no activation first",
    shortTfliteChecked.readiness.firstUnsupportedActivationShapeLayer < 0)

proc checkReferenceParsedSkipOracles() =
  var fixedLayers = [
    BlaiCpuParsedLayerState(
      active: false,
      index: 0,
      layer: BlaiCpuInstLayer64(layerType: ord(blaiMean).int32)),
    BlaiCpuParsedLayerState(
      active: true,
      index: 1,
      layer: BlaiCpuInstLayer64(
        layerType: ord(blaiConvolutional).int32,
        activation: ord(blaiActLinear).int32,
        dspOn: 1,
        dataType: 1,
        w: 2, h: 2, c: 1, outC: 1,
        size: 1, stride: 1, dilation: 1, groups: 1))]
  var fixedWeights: array[1, int8]
  var fixedBiases: array[1, int8]
  var fixedScratchA: array[4, int8]
  var fixedScratchB: array[4, int8]
  var fixedOut: array[4, int8]
  let fixedSkip = blaiReferenceFixedParsedModel2d(
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
  check("NPU fixed parsed skip valid", fixedSkip.modelValid)
  checkEq("NPU fixed parsed skip skipped",
    fixedSkip.skippedLayerCount, 1'u32)
  checkEq("NPU fixed parsed skip attempted",
    fixedSkip.attemptedLayerCount, 1'u32)
  checkEq("NPU fixed parsed skip completed",
    fixedSkip.completedLayerCount, 1'u32)
  checkEq("NPU fixed parsed skip last layer",
    cast[uint32](fixedSkip.lastCompletedLayer), 1'u32)
  checkCursorCompare("NPU fixed parsed skip weight cursor",
    blaiCompareCpuStreamCursor(
      blaiCpuStreamCursor(layerIndex = 2, byteOffset = 1),
      fixedSkip.nextWeightCursor))
  checkCursorCompare("NPU fixed parsed skip bias cursor",
    blaiCompareCpuStreamCursor(
      blaiCpuStreamCursor(layerIndex = 2, byteOffset = 1),
      fixedSkip.nextBiasCursor))
  checkOutputCompare("NPU fixed parsed skip output",
    blaiCompareInt8Outputs([2'i8, 4, 6, 8], fixedOut))

  var tfliteLayers = [
    BlaiCpuParsedLayerState(
      active: false,
      index: 0,
      layer: BlaiCpuInstLayer64(layerType: ord(blaiMean).int32)),
    BlaiCpuParsedLayerState(
      active: true,
      index: 1,
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
        quantizedActivationMax: 255))]
  var tfliteBiases: array[1, int32]
  var tfliteScratchA: array[4, uint8]
  var tfliteScratchB: array[4, uint8]
  var tfliteOut: array[4, uint8]
  let tfliteSkip = blaiReferenceTfliteParsedModel2d(
    tfliteLayers,
    useTflite = true,
    input = [1'u8, 2, 3, 4],
    cpuWeightBytes = [2'u8],
    cpuBiasBytes = [0'u8, 0, 0, 0],
    decodedBiases = tfliteBiases,
    scratchA = tfliteScratchA,
    scratchB = tfliteScratchB,
    output = tfliteOut)
  check("NPU TFLite parsed skip valid", tfliteSkip.modelValid)
  checkEq("NPU TFLite parsed skip skipped",
    tfliteSkip.skippedLayerCount, 1'u32)
  checkEq("NPU TFLite parsed skip attempted",
    tfliteSkip.attemptedLayerCount, 1'u32)
  checkEq("NPU TFLite parsed skip completed",
    tfliteSkip.completedLayerCount, 1'u32)
  checkEq("NPU TFLite parsed skip last layer",
    cast[uint32](tfliteSkip.lastCompletedLayer), 1'u32)
  checkCursorCompare("NPU TFLite parsed skip weight cursor",
    blaiCompareCpuStreamCursor(
      blaiCpuStreamCursor(layerIndex = 2, byteOffset = 1),
      tfliteSkip.nextWeightCursor))
  checkCursorCompare("NPU TFLite parsed skip bias cursor",
    blaiCompareCpuStreamCursor(
      blaiCpuStreamCursor(layerIndex = 2, byteOffset = 4),
      tfliteSkip.nextBiasCursor))
  checkOutputCompare("NPU TFLite parsed skip output",
    blaiCompareUint8Outputs([2'u8, 4, 6, 8], tfliteOut))

proc checkReferenceParsedEmptyOracles() =
  var fixedLayers: array[0, BlaiCpuParsedLayerState]
  var fixedWeights: array[0, int8]
  var fixedBiases: array[0, int8]
  var fixedScratchA: array[0, int8]
  var fixedScratchB: array[0, int8]
  var fixedOut: array[0, int8]
  let fixedEmpty = blaiReferenceFixedParsedModel2d(
    fixedLayers,
    useTflite = false,
    input = [],
    cpuWeightBytes = [],
    cpuBiasBytes = [],
    decodedWeights = fixedWeights,
    decodedBiases = fixedBiases,
    scratchA = fixedScratchA,
    scratchB = fixedScratchB,
    output = fixedOut)
  check("NPU fixed parsed empty runnable", fixedEmpty.runnable)
  check("NPU fixed parsed empty valid", fixedEmpty.modelValid)
  check("NPU fixed parsed empty completed", fixedEmpty.allCompleted)
  check("NPU fixed parsed empty consumed",
    fixedEmpty.allWeightsConsumed and fixedEmpty.allBiasesConsumed)
  checkEq("NPU fixed parsed empty failure",
    ord(fixedEmpty.modelFailure).uint32,
    ord(blaiRefFixedModelNoFailure).uint32)

  let fixedEmptyTrailing = blaiReferenceFixedParsedModel2d(
    fixedLayers,
    useTflite = false,
    input = [],
    cpuWeightBytes = [],
    cpuBiasBytes = [1'u8],
    decodedWeights = fixedWeights,
    decodedBiases = fixedBiases,
    scratchA = fixedScratchA,
    scratchB = fixedScratchB,
    output = fixedOut)
  check("NPU fixed parsed empty trailing completed",
    fixedEmptyTrailing.allCompleted)
  check("NPU fixed parsed empty trailing invalid",
    not fixedEmptyTrailing.modelValid)
  checkEq("NPU fixed parsed empty trailing failure",
    ord(fixedEmptyTrailing.modelFailure).uint32,
    ord(blaiRefFixedModelTrailingBiasStream).uint32)

  var tfliteLayers: array[0, BlaiCpuParsedLayerState]
  var tfliteBiases: array[0, int32]
  var tfliteScratchA: array[0, uint8]
  var tfliteScratchB: array[0, uint8]
  var tfliteOut: array[0, uint8]
  let tfliteEmpty = blaiReferenceTfliteParsedModel2d(
    tfliteLayers,
    useTflite = true,
    input = [],
    cpuWeightBytes = [],
    cpuBiasBytes = [],
    decodedBiases = tfliteBiases,
    scratchA = tfliteScratchA,
    scratchB = tfliteScratchB,
    output = tfliteOut)
  check("NPU TFLite parsed empty runnable", tfliteEmpty.runnable)
  check("NPU TFLite parsed empty valid", tfliteEmpty.modelValid)
  check("NPU TFLite parsed empty completed", tfliteEmpty.allCompleted)
  check("NPU TFLite parsed empty consumed",
    tfliteEmpty.allWeightsConsumed and tfliteEmpty.allBiasesConsumed)
  checkEq("NPU TFLite parsed empty failure",
    ord(tfliteEmpty.modelFailure).uint32,
    ord(blaiRefModelNoFailure).uint32)

  let tfliteEmptyTrailing = blaiReferenceTfliteParsedModel2d(
    tfliteLayers,
    useTflite = true,
    input = [],
    cpuWeightBytes = [1'u8],
    cpuBiasBytes = [],
    decodedBiases = tfliteBiases,
    scratchA = tfliteScratchA,
    scratchB = tfliteScratchB,
    output = tfliteOut)
  check("NPU TFLite parsed empty trailing completed",
    tfliteEmptyTrailing.allCompleted)
  check("NPU TFLite parsed empty trailing invalid",
    not tfliteEmptyTrailing.modelValid)
  checkEq("NPU TFLite parsed empty trailing failure",
    ord(tfliteEmptyTrailing.modelFailure).uint32,
    ord(blaiRefModelTrailingWeightStream).uint32)

proc checkReferenceParsedFixedRouteOracles() =
  let routeLayer = BlaiCpuInstLayer64(
    layerType: ord(blaiRoute).int32,
    w: 1, h: 1, outW: 1, outH: 1,
    c: 1,
    cn: [1'i32, 1, 0, 0, 0, 0, 0],
    inputNum: 3,
    inLayer1Mem: 0,
    inLayer2Mem: 1,
    dramPatchSize: 4,
    fdata: 0,
    froute1: 0,
    froute2: 0)
  let routeStorage = BlaiCpuExtraInputStorage(
    active: true,
    inLayerMemN: [2'i32, 0, 0, 0, 0, 0],
    frouten: [0'i32, 0, 0, 0, 0, 0])
  var routeLayers = [BlaiCpuParsedLayerState(
    active: true,
    index: 0,
    layer: routeLayer,
    extraInputs: routeStorage)]
  var routeWeights: array[0, int8]
  var routeBiases: array[0, int8]
  var routeOut: array[3, int8]
  let parsedRoute = blaiReferenceFixedParsedLayer2d(
    routeLayers,
    layerIndex = 0,
    useTflite = false,
    input1 = [10'i8, 0, 0, 0, 20, 0, 0, 0, 30],
    input2 = [],
    cpuWeightBytes = [],
    cpuBiasBytes = [],
    weightCursor = blaiCpuStreamCursor(),
    biasCursor = blaiCpuStreamCursor(),
    decodedWeights = routeWeights,
    decodedBiases = routeBiases,
    output = routeOut)
  check("NPU fixed parsed route supported", parsedRoute.supported)
  check("NPU fixed parsed route fits", parsedRoute.fits)
  check("NPU fixed parsed route streams",
    parsedRoute.streamsFit and parsedRoute.streamLayerMatches)
  checkEq("NPU fixed parsed route output channels",
    parsedRoute.reference.outputC, 3'u32)
  checkOutputCompare("NPU fixed parsed route output",
    blaiCompareInt8Outputs([10'i8, 20, 30], routeOut))

  let routeMaxLayer = BlaiCpuInstLayer64(
    layerType: ord(blaiRouteMax).int32,
    w: 2, h: 2, outW: 1, outH: 1,
    c: 1,
    cn: [1'i32, 0, 0, 0, 0, 0, 0],
    inputNum: 2,
    inLayer1Mem: 0,
    inLayer2Mem: 1,
    dramPatchSize: 4,
    fdata: 0,
    froute1: 0,
    froute2: 0,
    stride: 1)
  var routeMaxLayers = [BlaiCpuParsedLayerState(
    active: true,
    index: 0,
    layer: routeMaxLayer)]
  var routeMaxOut: array[2, int8]
  let parsedRouteMax = blaiReferenceFixedParsedLayer2d(
    routeMaxLayers,
    layerIndex = 0,
    useTflite = false,
    input1 = [1'i8, 5, 2, 6, 3, 7, 4, 8],
    input2 = [],
    cpuWeightBytes = [],
    cpuBiasBytes = [],
    weightCursor = blaiCpuStreamCursor(),
    biasCursor = blaiCpuStreamCursor(),
    decodedWeights = routeWeights,
    decodedBiases = routeBiases,
    output = routeMaxOut)
  check("NPU fixed parsed route max supported", parsedRouteMax.supported)
  check("NPU fixed parsed route max fits", parsedRouteMax.fits)
  check("NPU fixed parsed route max streams",
    parsedRouteMax.streamsFit and parsedRouteMax.streamLayerMatches)
  checkEq("NPU fixed parsed route max output channels",
    parsedRouteMax.reference.outputC, 2'u32)
  checkOutputCompare("NPU fixed parsed route max output",
    blaiCompareInt8Outputs([6'i8, 8], routeMaxOut))

proc checkReferenceParsedTfliteRouteOracles() =
  var routeBiases: array[0, int32]
  let routeWLayer = BlaiCpuInstLayer64(
    layerType: ord(blaiRouteW).int32,
    w: 3, h: 1, outW: 3,
    c: 1,
    cn: [2'i32, 0, 0, 0, 0, 0, 0],
    outC: 1,
    inputNum: 2,
    inLayer1Mem: 0,
    inLayer2Mem: 1,
    dramPatchSize: 4,
    tfInput1Offset: 7,
    tfInput2Offset: 7,
    tfOutputOffset: 1,
    tfInput1Multiplier: 0,
    tfInput2Multiplier: 0,
    tfOutputMultiplier: 0,
    tfInput1Shift: 0,
    tfInput2Shift: 0,
    tfOutputShift: 0,
    quantizedActivationMin: 0,
    quantizedActivationMax: 255,
    axis: 0)
  var routeWLayers = [BlaiCpuParsedLayerState(
    active: true,
    index: 0,
    layer: routeWLayer)]
  var routeWOut: array[3, uint8]
  let parsedRouteW = blaiReferenceTfliteParsedLayer2d(
    routeWLayers,
    layerIndex = 0,
    useTflite = true,
    input1 = [11'u8, 0, 0, 0, 21, 22],
    input2 = [],
    cpuWeightBytes = [],
    cpuBiasBytes = [],
    weightCursor = blaiCpuStreamCursor(),
    biasCursor = blaiCpuStreamCursor(),
    decodedBiases = routeBiases,
    output = routeWOut)
  check("NPU TFLite parsed route W supported", parsedRouteW.supported)
  check("NPU TFLite parsed route W fits", parsedRouteW.fits)
  check("NPU TFLite parsed route W streams",
    parsedRouteW.streamsFit and parsedRouteW.streamLayerMatches)
  checkEq("NPU TFLite parsed route W output channels",
    parsedRouteW.reference.outputC, 1'u32)
  checkOutputCompare("NPU TFLite parsed route W output",
    blaiCompareUint8Outputs([11'u8, 21, 22], routeWOut))

proc checkReferenceTfliteTransformOracles() =
  var meanOut: array[1, uint8]
  let mean = blaiReferenceTfliteTransformLayer2d(
    BlaiCpuInstLayer64(
      layerType: ord(blaiMean).int32,
      w: 2, h: 2, c: 1,
      tfOutputMultiplier: high(int32),
      tfOutputShift: 0),
    [10'u8, 20, 30, 40],
    meanOut)
  check("NPU TFLite transform mean supported", mean.supported)
  check("NPU TFLite transform mean fits", mean.fits)
  checkEq("NPU TFLite transform mean channels", mean.outputC, 1'u32)
  checkOutputCompare("NPU TFLite transform mean output",
    blaiCompareUint8Outputs([25'u8], meanOut))

  var softmaxOut: array[4, uint8]
  let softmax = blaiReferenceTfliteTransformLayer2d(
    BlaiCpuInstLayer64(
      layerType: ord(blaiSoftmax).int32,
      w: 2, h: 1, c: 2, outC: 2),
    [1'u8, 2, 3, 4],
    softmaxOut)
  check("NPU TFLite transform softmax supported", softmax.supported)
  check("NPU TFLite transform softmax fits", softmax.fits)
  checkEq("NPU TFLite transform softmax channels", softmax.outputC, 2'u32)
  checkOutputCompare("NPU TFLite transform softmax output",
    blaiCompareUint8Outputs([1'u8, 2, 3, 4], softmaxOut))

  var logisticOut: array[3, uint8]
  let logistic = blaiReferenceTfliteTransformLayer2d(
    BlaiCpuInstLayer64(
      layerType: ord(blaiLogisticLayer).int32,
      w: 3, h: 1, c: 1,
      tfInput1Offset: 10,
      inputScale: 1.0'f32,
      tfOutputOffset: 42,
      outputScale: 0.5'f32),
    [1'u8, 10, 30],
    logisticOut)
  check("NPU TFLite transform logistic supported", logistic.supported)
  check("NPU TFLite transform logistic fits", logistic.fits)
  checkEq("NPU TFLite transform logistic width", logistic.outputW, 3'u32)
  checkOutputCompare("NPU TFLite transform logistic output",
    blaiCompareUint8Outputs([42'u8, 43, 44], logisticOut))

  var padOut: array[16, uint8]
  let pad = blaiReferenceTfliteTransformLayer2d(
    BlaiCpuInstLayer64(
      layerType: ord(blaiPad).int32,
      w: 2, h: 1, c: 2,
      outW: 4, outH: 2,
      paddingX: 1, paddingY: 1,
      tfOutputOffset: 9),
    [1'u8, 2, 3, 4],
    padOut)
  check("NPU TFLite transform pad supported", pad.supported)
  check("NPU TFLite transform pad fits", pad.fits)
  checkEq("NPU TFLite transform pad width", pad.outputW, 4'u32)
  checkOutputCompare("NPU TFLite transform pad output",
    blaiCompareUint8Outputs([
      9'u8, 9, 9, 9, 9, 9, 9, 9,
      9, 9, 1, 2, 3, 4, 9, 9], padOut))

  var reshapeOut: array[6, uint8]
  let reshape = blaiReferenceTfliteTransformLayer2d(
    BlaiCpuInstLayer64(
      layerType: ord(blaiReshape).int32,
      w: 2, h: 1, c: 3,
      outW: 1, outH: 2, outC: 3),
    [1'u8, 2, 3, 4, 5, 6],
    reshapeOut)
  check("NPU TFLite transform reshape supported", reshape.supported)
  check("NPU TFLite transform reshape fits", reshape.fits)
  checkEq("NPU TFLite transform reshape height", reshape.outputH, 2'u32)
  checkOutputCompare("NPU TFLite transform reshape output",
    blaiCompareUint8Outputs([1'u8, 2, 3, 4, 5, 6], reshapeOut))

  var preOut: array[16, uint8]
  let pre = blaiReferenceTfliteTransformLayer2d(
    BlaiCpuInstLayer64(
      layerType: ord(blaiPreTransconv).int32,
      w: 2, h: 2, c: 1,
      outW: 4, outH: 4,
      tfInput1Offset: 9),
    [1'u8, 2, 3, 4],
    preOut)
  check("NPU TFLite transform pretrans supported", pre.supported)
  check("NPU TFLite transform pretrans fits", pre.fits)
  checkEq("NPU TFLite transform pretrans height", pre.outputH, 4'u32)
  checkOutputCompare("NPU TFLite transform pretrans output",
    blaiCompareUint8Outputs([
      9'u8, 9, 9, 9,
      9, 1, 9, 2,
      9, 9, 9, 9,
      9, 3, 9, 4], preOut))

proc checkReferenceTfliteTransposeOracles() =
  var transposeOut: array[6, uint8]
  let transpose = blaiReferenceTfliteTransposeLayer2d(
    BlaiCpuInstLayer64(
      layerType: ord(blaiTranspose).int32,
      w: 3, h: 2, c: 1),
    BlaiCpuTfliteTransposeMask(
      active: true,
      rank: 3,
      hPerm: 1,
      wPerm: 0,
      cPerm: 2),
    [1'u8, 2, 3, 4, 5, 6],
    transposeOut)
  check("NPU TFLite transpose supported", transpose.supported)
  check("NPU TFLite transpose fits", transpose.fits)
  checkEq("NPU TFLite transpose height", transpose.outputH, 3'u32)
  checkEq("NPU TFLite transpose width", transpose.outputW, 2'u32)
  checkOutputCompare("NPU TFLite transpose output",
    blaiCompareUint8Outputs([1'u8, 4, 2, 5, 3, 6], transposeOut))

  var inactiveOut: array[6, uint8]
  let inactive = blaiReferenceTfliteTransposeLayer2d(
    BlaiCpuInstLayer64(
      layerType: ord(blaiTranspose).int32,
      w: 3, h: 2, c: 1),
    BlaiCpuTfliteTransposeMask(),
    [1'u8, 2, 3, 4, 5, 6],
    inactiveOut)
  check("NPU TFLite transpose rejects missing mask",
    not inactive.supported and not inactive.fits)

  var wrongOut: array[1, uint8]
  let wrongLayer = blaiReferenceTfliteTransposeLayer2d(
    BlaiCpuInstLayer64(layerType: ord(blaiSoftmax).int32),
    BlaiCpuTfliteTransposeMask(active: true, rank: 3),
    [],
    wrongOut)
  check("NPU TFLite transpose rejects wrong layer",
    not wrongLayer.supported and not wrongLayer.fits)

proc checkReferenceTfliteTransposeLkOracles() =
  let expected = [
    10'u8, 11, 12, 128,
    11, 12, 13, 128,
    12, 13, 14, 128]

  var directOut: array[12, uint8]
  let direct = blaiReferenceTfliteTransposeLkLayer1d(
    BlaiCpuInstLayer64(
      layerType: ord(blaiTransposeLk).int32,
      w: 1, h: 5, c: 1,
      size: 3, stride: 1, dilation: 1),
    [10'u8, 11, 12, 13, 14],
    directOut)
  check("NPU TFLite transposelk direct supported", direct.supported)
  check("NPU TFLite transposelk direct fits", direct.fits)
  checkEq("NPU TFLite transposelk direct windows", direct.outputH, 3'u32)
  checkEq("NPU TFLite transposelk direct channels", direct.outputC, 4'u32)
  checkOutputCompare("NPU TFLite transposelk direct output",
    blaiCompareUint8Outputs(expected, directOut))

  var rollingOut: array[12, uint8]
  let rolling = blaiReferenceTfliteTransposeLkLayer1d(
    BlaiCpuInstLayer64(
      layerType: ord(blaiTransposeLk).int32,
      w: 1, h: 5, c: 1,
      size: 3, stride: 1, dilation: 1),
    [10'u8, 11, 12, 13, 14],
    rollingOut,
    rollingV2 = true)
  check("NPU TFLite transposelk V2 supported", rolling.supported)
  check("NPU TFLite transposelk V2 fits", rolling.fits)
  checkEq("NPU TFLite transposelk V2 windows", rolling.outputH, 3'u32)
  checkEq("NPU TFLite transposelk V2 channels", rolling.outputC, 4'u32)
  checkOutputCompare("NPU TFLite transposelk V2 output",
    blaiCompareUint8Outputs(expected, rollingOut))

  var wrongOut: array[1, uint8]
  let wrongLayer = blaiReferenceTfliteTransposeLkLayer1d(
    BlaiCpuInstLayer64(layerType: ord(blaiTranspose).int32),
    [],
    wrongOut)
  check("NPU TFLite transposelk rejects wrong layer",
    not wrongLayer.supported and not wrongLayer.fits)

proc checkReferenceTfliteDequantizeOracles() =
  var dequantOut: array[4, float32]
  let dequant = blaiReferenceTfliteDequantizeLayer2d(
    BlaiCpuInstLayer64(
      layerType: ord(blaiDequantize).int32,
      w: 2, h: 1, c: 2,
      tfInput1Offset: 10,
      inputScale: 0.5'f32),
    [8'u8, 10, 12, 14],
    dequantOut)
  check("NPU TFLite dequantize supported", dequant.supported)
  check("NPU TFLite dequantize fits", dequant.fits)
  checkEq("NPU TFLite dequantize width", dequant.outputW, 2'u32)
  checkEq("NPU TFLite dequantize channels", dequant.outputC, 2'u32)
  checkFloatBits("NPU TFLite dequantize output 0", dequantOut[0], -1.0'f32)
  checkFloatBits("NPU TFLite dequantize output 1", dequantOut[1], 0.0'f32)
  checkFloatBits("NPU TFLite dequantize output 2", dequantOut[2], 1.0'f32)
  checkFloatBits("NPU TFLite dequantize output 3", dequantOut[3], 2.0'f32)

  var wrongOut: array[1, float32]
  let wrongLayer = blaiReferenceTfliteDequantizeLayer2d(
    BlaiCpuInstLayer64(layerType: ord(blaiLogisticLayer).int32),
    [],
    wrongOut)
  check("NPU TFLite dequantize rejects wrong layer",
    not wrongLayer.supported and not wrongLayer.fits)

proc checkReferenceParsedShortcutOracles() =
  var fixedShortcutLayers = [
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
  let fixedShortcutInputs = [
    BlaiReferenceFixedParsedModelInput(),
    BlaiReferenceFixedParsedModelInput(secondInput: blaiRefFixedInputModel)]
  var fixedShortcutWeights: array[1, int8]
  var fixedShortcutBiases: array[1, int8]
  var fixedShortcutScratchA: array[2, int8]
  var fixedShortcutScratchB: array[2, int8]
  var fixedShortcutOut: array[2, int8]
  let fixedShortcutChecked = blaiReferenceFixedParsedCheckedModel2d(
    fixedShortcutLayers,
    useTflite = false,
    input = [1'i8, 2],
    layerInputs = fixedShortcutInputs,
    cpuWeightBytes = [2'u8],
    cpuBiasBytes = [0'u8],
    decodedWeights = fixedShortcutWeights,
    decodedBiases = fixedShortcutBiases,
    scratchA = fixedShortcutScratchA,
    scratchB = fixedShortcutScratchB,
    output = fixedShortcutOut)
  check("NPU fixed parsed shortcut preflight",
    fixedShortcutChecked.preflight.fit.fits)
  check("NPU fixed parsed shortcut executed", fixedShortcutChecked.executed)
  check("NPU fixed parsed shortcut valid",
    fixedShortcutChecked.model.modelValid)
  checkEq("NPU fixed parsed shortcut completed",
    fixedShortcutChecked.model.completedLayerCount, 2)
  checkOutputCompare("NPU fixed parsed shortcut output",
    blaiCompareInt8Outputs([3'i8, 6], fixedShortcutOut))

  var tfliteShortcutLayers = [
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
  let tfliteShortcutInputs = [
    BlaiReferenceTfliteParsedModelInput(),
    BlaiReferenceTfliteParsedModelInput(secondInput: blaiRefInputModel)]
  var tfliteShortcutBiases: array[1, int32]
  var tfliteShortcutScratchA: array[2, uint8]
  var tfliteShortcutScratchB: array[2, uint8]
  var tfliteShortcutOut: array[2, uint8]
  let tfliteShortcutChecked = blaiReferenceTfliteParsedCheckedModel2d(
    tfliteShortcutLayers,
    useTflite = true,
    input = [1'u8, 2],
    layerInputs = tfliteShortcutInputs,
    cpuWeightBytes = [2'u8],
    cpuBiasBytes = [0'u8, 0, 0, 0],
    decodedBiases = tfliteShortcutBiases,
    scratchA = tfliteShortcutScratchA,
    scratchB = tfliteShortcutScratchB,
    output = tfliteShortcutOut)
  check("NPU TFLite parsed shortcut preflight",
    tfliteShortcutChecked.preflight.fit.fits)
  check("NPU TFLite parsed shortcut executed", tfliteShortcutChecked.executed)
  check("NPU TFLite parsed shortcut valid",
    tfliteShortcutChecked.model.modelValid)
  checkEq("NPU TFLite parsed shortcut completed",
    tfliteShortcutChecked.model.completedLayerCount, 2)
  checkOutputCompare("NPU TFLite parsed shortcut output",
    blaiCompareUint8Outputs([3'u8, 6], tfliteShortcutOut))

proc checkReferenceParsedSecondInputFailures() =
  var fixedMissingPreviousLayers = [
    BlaiCpuParsedLayerState(
      active: true,
      index: 0,
      layer: BlaiCpuInstLayer64(
        layerType: ord(blaiShortcut).int32,
        activation: ord(blaiActLinear).int32,
        w: 2, h: 1, c: 1,
        froute1: 0, froute2: 0, fout: 0))]
  let fixedMissingPreviousInputs = [
    BlaiReferenceFixedParsedModelInput(secondInput: blaiRefFixedInputPrevious)]
  var fixedMissingWeights: array[0, int8]
  var fixedMissingBiases: array[0, int8]
  var fixedMissingScratchA: array[2, int8]
  var fixedMissingScratchB: array[2, int8]
  var fixedMissingOut: array[2, int8]
  let fixedMissing = blaiReferenceFixedParsedCheckedModel2d(
    fixedMissingPreviousLayers,
    useTflite = false,
    input = [1'i8, 2],
    layerInputs = fixedMissingPreviousInputs,
    cpuWeightBytes = [],
    cpuBiasBytes = [],
    decodedWeights = fixedMissingWeights,
    decodedBiases = fixedMissingBiases,
    scratchA = fixedMissingScratchA,
    scratchB = fixedMissingScratchB,
    output = fixedMissingOut)
  check("NPU fixed parsed missing previous preflight",
    fixedMissing.preflight.fit.fits)
  check("NPU fixed parsed missing previous executed", fixedMissing.executed)
  check("NPU fixed parsed missing previous invalid",
    not fixedMissing.model.modelValid)
  checkEq("NPU fixed parsed missing previous failed layer",
    fixedMissing.model.firstFailedLayer.uint32, 0)
  checkEq("NPU fixed parsed missing previous failure",
    ord(fixedMissing.model.firstFailure).uint32,
    ord(blaiRefFixedModelSecondInputUnavailable).uint32)

  var tfliteMissingPreviousLayers = [
    BlaiCpuParsedLayerState(
      active: true,
      index: 0,
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
  let tfliteMissingPreviousInputs = [
    BlaiReferenceTfliteParsedModelInput(secondInput: blaiRefInputPrevious)]
  var tfliteMissingBiases: array[0, int32]
  var tfliteMissingScratchA: array[2, uint8]
  var tfliteMissingScratchB: array[2, uint8]
  var tfliteMissingOut: array[2, uint8]
  let tfliteMissing = blaiReferenceTfliteParsedCheckedModel2d(
    tfliteMissingPreviousLayers,
    useTflite = true,
    input = [1'u8, 2],
    layerInputs = tfliteMissingPreviousInputs,
    cpuWeightBytes = [],
    cpuBiasBytes = [],
    decodedBiases = tfliteMissingBiases,
    scratchA = tfliteMissingScratchA,
    scratchB = tfliteMissingScratchB,
    output = tfliteMissingOut)
  check("NPU TFLite parsed missing previous preflight",
    tfliteMissing.preflight.fit.fits)
  check("NPU TFLite parsed missing previous executed", tfliteMissing.executed)
  check("NPU TFLite parsed missing previous invalid",
    not tfliteMissing.model.modelValid)
  checkEq("NPU TFLite parsed missing previous failed layer",
    tfliteMissing.model.firstFailedLayer.uint32, 0)
  checkEq("NPU TFLite parsed missing previous failure",
    ord(tfliteMissing.model.firstFailure).uint32,
    ord(blaiRefModelSecondInputUnavailable).uint32)

proc checkReferenceParsedTrailingStreamFailures() =
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
  var fixedWeights: array[1, int8]
  var fixedBiases: array[1, int8]
  var fixedScratchA: array[4, int8]
  var fixedScratchB: array[4, int8]
  var fixedOut: array[4, int8]
  let fixedTrailingWeight = blaiReferenceFixedParsedCheckedModel2d(
    fixedLayers,
    useTflite = false,
    input = [1'i8, 2, 3, 4],
    cpuWeightBytes = [2'u8, 9],
    cpuBiasBytes = [0'u8],
    decodedWeights = fixedWeights,
    decodedBiases = fixedBiases,
    scratchA = fixedScratchA,
    scratchB = fixedScratchB,
    output = fixedOut)
  check("NPU fixed parsed trailing weight executed",
    fixedTrailingWeight.executed)
  check("NPU fixed parsed trailing weight completed",
    fixedTrailingWeight.model.allCompleted)
  check("NPU fixed parsed trailing weight invalid",
    not fixedTrailingWeight.model.modelValid)
  checkEq("NPU fixed parsed trailing weight failure",
    ord(fixedTrailingWeight.model.modelFailure).uint32,
    ord(blaiRefFixedModelTrailingWeightStream).uint32)
  check("NPU fixed parsed trailing weight no failed capture",
    not fixedTrailingWeight.model.firstFailedLayerResultCaptured)

  var fixedBiasOut: array[4, int8]
  let fixedTrailingBias = blaiReferenceFixedParsedCheckedModel2d(
    fixedLayers,
    useTflite = false,
    input = [1'i8, 2, 3, 4],
    cpuWeightBytes = [2'u8],
    cpuBiasBytes = [0'u8, 7],
    decodedWeights = fixedWeights,
    decodedBiases = fixedBiases,
    scratchA = fixedScratchA,
    scratchB = fixedScratchB,
    output = fixedBiasOut)
  check("NPU fixed parsed trailing bias executed", fixedTrailingBias.executed)
  check("NPU fixed parsed trailing bias completed",
    fixedTrailingBias.model.allCompleted)
  check("NPU fixed parsed trailing bias invalid",
    not fixedTrailingBias.model.modelValid)
  checkEq("NPU fixed parsed trailing bias failure",
    ord(fixedTrailingBias.model.modelFailure).uint32,
    ord(blaiRefFixedModelTrailingBiasStream).uint32)
  check("NPU fixed parsed trailing bias no failed capture",
    not fixedTrailingBias.model.firstFailedLayerResultCaptured)

proc checkReferenceTfliteParsedTrailingStreamFailures() =
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
  var tfliteBiases: array[1, int32]
  var tfliteScratchA: array[4, uint8]
  var tfliteScratchB: array[4, uint8]
  var tfliteOut: array[1, uint8]
  let tfliteTrailingWeight = blaiReferenceTfliteParsedCheckedModel2d(
    tfliteLayers,
    useTflite = true,
    input = [1'u8, 2, 3, 4],
    cpuWeightBytes = [2'u8, 99],
    cpuBiasBytes = [0'u8, 0, 0, 0],
    decodedBiases = tfliteBiases,
    scratchA = tfliteScratchA,
    scratchB = tfliteScratchB,
    output = tfliteOut)
  check("NPU TFLite parsed trailing weight executed",
    tfliteTrailingWeight.executed)
  check("NPU TFLite parsed trailing weight completed",
    tfliteTrailingWeight.model.allCompleted)
  check("NPU TFLite parsed trailing weight invalid",
    not tfliteTrailingWeight.model.modelValid)
  checkEq("NPU TFLite parsed trailing weight failure",
    ord(tfliteTrailingWeight.model.modelFailure).uint32,
    ord(blaiRefModelTrailingWeightStream).uint32)
  check("NPU TFLite parsed trailing weight no failed capture",
    not tfliteTrailingWeight.model.firstFailedLayerResultCaptured)

  var tfliteBiasOut: array[1, uint8]
  let tfliteTrailingBias = blaiReferenceTfliteParsedCheckedModel2d(
    tfliteLayers,
    useTflite = true,
    input = [1'u8, 2, 3, 4],
    cpuWeightBytes = [2'u8],
    cpuBiasBytes = [0'u8, 0, 0, 0, 7, 0, 0, 0],
    decodedBiases = tfliteBiases,
    scratchA = tfliteScratchA,
    scratchB = tfliteScratchB,
    output = tfliteBiasOut)
  check("NPU TFLite parsed trailing bias executed", tfliteTrailingBias.executed)
  check("NPU TFLite parsed trailing bias completed",
    tfliteTrailingBias.model.allCompleted)
  check("NPU TFLite parsed trailing bias invalid",
    not tfliteTrailingBias.model.modelValid)
  checkEq("NPU TFLite parsed trailing bias failure",
    ord(tfliteTrailingBias.model.modelFailure).uint32,
    ord(blaiRefModelTrailingBiasStream).uint32)
  check("NPU TFLite parsed trailing bias no failed capture",
    not tfliteTrailingBias.model.firstFailedLayerResultCaptured)

proc checkReferenceParsedLayerFailureModes() =
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
        size: 1, stride: 1, dilation: 1, groups: 1))]
  var fixedWeights: array[1, int8]
  var fixedBiases: array[1, int8]
  var fixedScratchA: array[4, int8]
  var fixedScratchB: array[4, int8]
  var fixedOut: array[4, int8]
  let fixedShortBias = blaiReferenceFixedParsedModel2d(
    fixedLayers,
    useTflite = false,
    input = [1'i8, 2, 3, 4],
    cpuWeightBytes = [2'u8],
    cpuBiasBytes = [],
    decodedWeights = fixedWeights,
    decodedBiases = fixedBiases,
    scratchA = fixedScratchA,
    scratchB = fixedScratchB,
    output = fixedOut)
  check("NPU fixed parsed short stream incomplete",
    not fixedShortBias.allCompleted)
  check("NPU fixed parsed short stream invalid",
    not fixedShortBias.modelValid)
  checkEq("NPU fixed parsed short stream failure",
    ord(fixedShortBias.firstFailure).uint32,
    ord(blaiRefFixedModelStreamDataUnavailable).uint32)
  check("NPU fixed parsed short stream captured",
    fixedShortBias.firstFailedLayerResultCaptured)
  check("NPU fixed parsed short stream capture fit",
    not fixedShortBias.firstFailedLayerResult.streamsFit)

  var unsupportedWeightLayers = fixedLayers
  unsupportedWeightLayers[0].layer.dataType = 0
  var unsupportedWeightOut: array[4, int8]
  let unsupportedWeight = blaiReferenceFixedParsedCheckedModel2d(
    unsupportedWeightLayers,
    useTflite = false,
    input = [1'i8, 2, 3, 4],
    cpuWeightBytes = [2'u8],
    cpuBiasBytes = [0'u8],
    decodedWeights = fixedWeights,
    decodedBiases = fixedBiases,
    scratchA = fixedScratchA,
    scratchB = fixedScratchB,
    output = unsupportedWeightOut)
  check("NPU fixed parsed unsupported weight preflight",
    not unsupportedWeight.preflight.fit.weightStorageSupported)
  check("NPU fixed parsed unsupported weight blocked",
    not unsupportedWeight.executed)
  check("NPU fixed parsed unsupported weight invalid",
    not unsupportedWeight.model.modelValid)
  checkEq("NPU fixed parsed unsupported weight readiness block",
    ord(unsupportedWeight.readiness.firstBlock).uint32,
    ord(blaiRefFixedCheckedWeightStorageUnsupported).uint32)
  checkEq("NPU fixed parsed unsupported weight readiness first",
    cast[uint32](
      unsupportedWeight.readiness.firstUnsupportedWeightStorageLayer), 0)
  let unsupportedWeightPlan =
    blaiReferenceFixedParsedBufferPlan(unsupportedWeightLayers)
  checkEq("NPU fixed parsed unsupported weight first",
    cast[uint32](unsupportedWeightPlan.firstUnsupportedWeightStorageLayer), 0)
  checkEq("NPU fixed parsed unsupported weight support first",
    cast[uint32](
      unsupportedWeightPlan.support.firstUnsupportedWeightStorageLayer), 0)

  var fixedUnsupportedShapeLayers = [
    BlaiCpuParsedLayerState(
      active: true,
      index: 0,
      layer: BlaiCpuInstLayer64(
        layerType: ord(blaiDequantize).int32,
        w: 1,
        h: 1,
        c: 1))]
  let fixedUnsupportedShapePlan =
    blaiReferenceFixedParsedBufferPlan(fixedUnsupportedShapeLayers)
  check("NPU fixed parsed unsupported shape blocked",
    not fixedUnsupportedShapePlan.support.activationShapesSupported)
  checkEq("NPU fixed parsed unsupported shape first",
    cast[uint32](
      fixedUnsupportedShapePlan.firstUnsupportedActivationShapeLayer), 0)
  checkEq("NPU fixed parsed unsupported shape support first",
    cast[uint32](
      fixedUnsupportedShapePlan.support.firstUnsupportedActivationShapeLayer), 0)

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
        quantizedActivationMax: 255))]
  var tfliteBiases: array[1, int32]
  var tfliteScratchA: array[4, uint8]
  var tfliteScratchB: array[4, uint8]
  var tfliteOut: array[4, uint8]
  let tfliteShortBias = blaiReferenceTfliteParsedModel2d(
    tfliteLayers,
    useTflite = true,
    input = [1'u8, 2, 3, 4],
    cpuWeightBytes = [2'u8],
    cpuBiasBytes = [0'u8, 0, 0],
    decodedBiases = tfliteBiases,
    scratchA = tfliteScratchA,
    scratchB = tfliteScratchB,
    output = tfliteOut)
  check("NPU TFLite parsed short stream incomplete",
    not tfliteShortBias.allCompleted)
  check("NPU TFLite parsed short stream invalid",
    not tfliteShortBias.modelValid)
  checkEq("NPU TFLite parsed short stream failure",
    ord(tfliteShortBias.firstFailure).uint32,
    ord(blaiRefModelStreamDataUnavailable).uint32)

  var tfliteUnsupportedShapeLayers = [
    BlaiCpuParsedLayerState(
      active: true,
      index: 0,
      layer: BlaiCpuInstLayer64(
        layerType: ord(blaiDequantize).int32,
        w: 1,
        h: 1,
        c: 1))]
  let tfliteUnsupportedShapePlan =
    blaiReferenceTfliteParsedBufferPlan(tfliteUnsupportedShapeLayers)
  check("NPU TFLite parsed unsupported shape blocked",
    not tfliteUnsupportedShapePlan.support.activationShapesSupported)
  checkEq("NPU TFLite parsed unsupported shape first",
    cast[uint32](
      tfliteUnsupportedShapePlan.firstUnsupportedActivationShapeLayer), 0)
  checkEq("NPU TFLite parsed unsupported shape support first",
    cast[uint32](
      tfliteUnsupportedShapePlan.support.firstUnsupportedActivationShapeLayer), 0)

proc checkReferenceParsedModeAndUnsupportedFailures() =
  var fixedLayers: array[0, BlaiCpuParsedLayerState]
  var fixedWeights: array[0, int8]
  var fixedBiases: array[0, int8]
  var fixedScratchA: array[0, int8]
  var fixedScratchB: array[0, int8]
  var fixedOut: array[0, int8]
  let fixedTfliteInput = blaiReferenceFixedParsedModel2d(
    fixedLayers,
    useTflite = true,
    input = [],
    cpuWeightBytes = [],
    cpuBiasBytes = [],
    decodedWeights = fixedWeights,
    decodedBiases = fixedBiases,
    scratchA = fixedScratchA,
    scratchB = fixedScratchB,
    output = fixedOut)
  check("NPU fixed parsed rejects tflite mode",
    not fixedTfliteInput.runnable)
  checkEq("NPU fixed parsed tflite mode failure",
    ord(fixedTfliteInput.firstFailure).uint32,
    ord(blaiRefFixedModelTfliteInput).uint32)

  var tfliteLayers: array[0, BlaiCpuParsedLayerState]
  var tfliteBiases: array[0, int32]
  var tfliteScratchA: array[0, uint8]
  var tfliteScratchB: array[0, uint8]
  var tfliteOut: array[0, uint8]
  let tfliteFixedInput = blaiReferenceTfliteParsedModel2d(
    tfliteLayers,
    useTflite = false,
    input = [],
    cpuWeightBytes = [],
    cpuBiasBytes = [],
    decodedBiases = tfliteBiases,
    scratchA = tfliteScratchA,
    scratchB = tfliteScratchB,
    output = tfliteOut)
  check("NPU TFLite parsed rejects fixed mode",
    not tfliteFixedInput.runnable)
  checkEq("NPU TFLite parsed fixed mode failure",
    ord(tfliteFixedInput.firstFailure).uint32,
    ord(blaiRefModelNotTflite).uint32)

  var unsupportedLayers = [
    BlaiCpuParsedLayerState(
      active: true,
      index: 0,
      layer: BlaiCpuInstLayer64(layerType: ord(blaiDequantize).int32))]
  var unsupportedBiases: array[0, int32]
  var unsupportedScratchA: array[1, uint8]
  var unsupportedScratchB: array[1, uint8]
  var unsupportedOut: array[1, uint8]
  let unsupportedLayer = blaiReferenceTfliteParsedModel2d(
    unsupportedLayers,
    useTflite = true,
    input = [1'u8],
    cpuWeightBytes = [],
    cpuBiasBytes = [],
    decodedBiases = unsupportedBiases,
    scratchA = unsupportedScratchA,
    scratchB = unsupportedScratchB,
    output = unsupportedOut)
  check("NPU TFLite parsed unsupported layer invalid",
    not unsupportedLayer.modelValid)
  checkEq("NPU TFLite parsed unsupported layer count",
    unsupportedLayer.failedLayerCount, 1'u32)
  checkEq("NPU TFLite parsed unsupported layer index",
    cast[uint32](unsupportedLayer.firstFailedLayer), 0'u32)
  checkEq("NPU TFLite parsed unsupported layer failure",
    ord(unsupportedLayer.firstFailure).uint32,
    ord(blaiRefModelUnsupportedLayer).uint32)
  check("NPU TFLite parsed unsupported layer captured",
    unsupportedLayer.firstFailedLayerResultCaptured)
  check("NPU TFLite parsed unsupported layer capture supported",
    not unsupportedLayer.firstFailedLayerResult.supported)

proc checkAllocatorLinePatchPlans() =
  let linePatchLayer = BlaiCpuInstLayer64(
    layerType: ord(blaiConvolutional).int32,
    w: 9000,
    c: 1,
    outW: 9000,
    outC: 1)
  let linePatchPlan = blaiPlanLinePatchMemAlloc(linePatchLayer)
  var linePatchPlanInto: BlaiMemAllocLinePatchPlan
  blaiPlanLinePatchMemAllocInto(linePatchLayer, linePatchPlanInto)
  check("NPU line patch into equal", linePatchPlanInto == linePatchPlan)
  check("NPU line patch fits", linePatchPlan.fits)
  checkEq("NPU line patch start", linePatchPlan.startPatchCount, 3)
  checkEq("NPU line patch count", linePatchPlan.linePatchCount, 3)
  checkEq("NPU line patch first", linePatchPlan.linePatchW[0], 3000)
  checkEq("NPU line patch last", linePatchPlan.linePatchW[2], 3000)
  var linePatchCtrl: BlaiPsramCtrl
  blaiApplyLinePatchMemAlloc(linePatchCtrl, linePatchPlan)
  checkEq("NPU line patch ctrl count",
    cast[uint32](linePatchCtrl.linePatchCount), 3)
  checkEq("NPU line patch ctrl width",
    cast[uint32](linePatchCtrl.linePatchW[1]), 3000)

  let routeLinePatchPlan = blaiPlanLinePatchMemAlloc(BlaiCpuInstLayer64(
    layerType: ord(blaiRoute).int32,
    w: 16,
    c: 400,
    cn: [200'i32, 0, 0, 0, 0, 0, 0],
    outW: 16,
    outC: 400,
    inputNum: 2,
    size: 3,
    dilation: 1,
    midOut: 1))
  check("NPU route line patch fits", routeLinePatchPlan.fits)
  checkEq("NPU route line patch start", routeLinePatchPlan.startPatchCount, 3)
  checkEq("NPU route line patch count", routeLinePatchPlan.linePatchCount, 4)
  checkEq("NPU route line patch input bytes",
    routeLinePatchPlan.inputLineBytes, 3600)
  checkEq("NPU route line patch output bytes",
    routeLinePatchPlan.outputLineBytes, 2400)
  checkEq("NPU route line patch last", routeLinePatchPlan.linePatchW[3], 4)

proc checkAllocatorSinglePatchPlans() =
  let singlePatchLayer = BlaiCpuInstLayer64(
    layerType: ord(blaiConvolutional).int32,
    w: 4,
    h: 4,
    c: 3,
    outW: 2,
    outH: 2,
    outC: 5,
    midOut: 1)
  let singlePatchPlan = blaiPlanSinglePatchMemAlloc(singlePatchLayer)
  var singlePatchPlanInto: BlaiMemAllocSinglePatchPlan
  blaiPlanSinglePatchMemAllocInto(singlePatchLayer, singlePatchPlanInto)
  check("NPU single patch into equal", singlePatchPlanInto == singlePatchPlan)
  checkEq("NPU single patch count", singlePatchPlan.weightPatchCount, 1)
  checkEq("NPU single patch out channels",
    singlePatchPlan.firstWeightPatchOutC, 5)
  checkEq("NPU single patch size", singlePatchPlan.psramPatchSize, 32)
  checkEq("NPU single mid patches", singlePatchPlan.psramMidPatchCount, 2)
  var singlePatchCtrl: BlaiPsramCtrl
  blaiApplySinglePatchMemAlloc(singlePatchCtrl, singlePatchPlan)
  checkEq("NPU single patch ctrl size",
    cast[uint32](singlePatchCtrl.psramPatchSize), 32)

  let fullSinglePlan = blaiPlanMemAlloc(BlaiCpuInstLayer64(
    layerType: ord(blaiConvolutional).int32,
    w: 4,
    h: 4,
    c: 3,
    outW: 2,
    outH: 2,
    outC: 5,
    midOut: 1))
  check("NPU full single fits", fullSinglePlan.fits)
  checkEq("NPU full single branch", ord(fullSinglePlan.branch).uint32,
    ord(blaiMemAllocSinglePatch).uint32)
  var fullSingleCtrl: BlaiPsramCtrl
  blaiApplyMemAllocPlan(fullSingleCtrl, fullSinglePlan)
  checkEq("NPU full single ctrl size",
    cast[uint32](fullSingleCtrl.psramPatchSize), 32)

proc checkAllocatorHighWeightPlan() =
  let highWeightLayer = BlaiCpuInstLayer64(
    layerType: ord(blaiConvolutional).int32,
    w: 16,
    h: 16,
    c: 128,
    outW: 16,
    outH: 16,
    outC: 128,
    groups: 1,
    size: 3)
  let highWeightLine = blaiPlanLinePatchMemAlloc(highWeightLayer)
  let highWeightPlan = blaiPlanHighWeightPatchMemAlloc(
    highWeightLayer, highWeightLine)
  var highWeightPlanInto: BlaiMemAllocWeightPatchPlan
  blaiPlanHighWeightPatchMemAllocInto(
    highWeightLayer, highWeightLine, highWeightPlanInto)
  check("NPU high weight into equal", highWeightPlanInto == highWeightPlan)
  check("NPU high weight fits", highWeightPlan.fits)
  check("NPU high weight active", highWeightPlan.active)
  checkEq("NPU high weight estimate", highWeightPlan.estimatedWeightBytes, 16384)
  checkEq("NPU high weight out patch", highWeightPlan.outputChannelPatch, 64)
  checkEq("NPU high weight patches", highWeightPlan.weightPatchCount, 2)
  checkEq("NPU high weight patch0", highWeightPlan.weightPatchOutC[0], 64)
  checkEq("NPU high weight patch1", highWeightPlan.weightPatchOutC[1], 64)
  checkEq("NPU high weight psram size", highWeightPlan.psramPatchSize, 16384)
  checkEq("NPU high weight psram patches", highWeightPlan.psramPatchCount, 4)
  var highWeightCtrl: BlaiPsramCtrl
  blaiApplyHighWeightPatchMemAlloc(highWeightCtrl, highWeightPlan)
  checkEq("NPU high weight ctrl count",
    cast[uint32](highWeightCtrl.weightPatchCount), 2)
  checkEq("NPU high weight ctrl out1",
    cast[uint32](highWeightCtrl.weightPatchOutC[1]), 64)
  checkEq("NPU high weight ctrl psram",
    cast[uint32](highWeightCtrl.psramPatchCount), 4)
  let fullHighWeightPlan = blaiPlanMemAlloc(highWeightLayer)
  check("NPU full high weight fits", fullHighWeightPlan.fits)
  checkEq("NPU full high weight branch",
    ord(fullHighWeightPlan.branch).uint32,
    ord(blaiMemAllocHighWeightPatch).uint32)
  var fullHighWeightCtrl: BlaiPsramCtrl
  blaiApplyMemAllocPlan(fullHighWeightCtrl, fullHighWeightPlan)
  checkEq("NPU full high weight line count",
    cast[uint32](fullHighWeightCtrl.linePatchCount),
    highWeightLine.linePatchCount)
  checkEq("NPU full high weight ctrl count",
    cast[uint32](fullHighWeightCtrl.weightPatchCount), 2)

proc checkAllocatorHighWeightMidPlan() =
  let highWeightMidLayer = BlaiCpuInstLayer64(
    layerType: ord(blaiConvMax).int32,
    w: 8,
    h: 8,
    c: 128,
    outW: 8,
    outH: 8,
    outC: 128,
    groups: 1,
    size: 3,
    midOut: 1)
  let highWeightMidLine = blaiPlanLinePatchMemAlloc(highWeightMidLayer)
  let highWeightMidPlan = blaiPlanHighWeightPatchMemAlloc(
    highWeightMidLayer, highWeightMidLine)
  check("NPU high weight mid fits", highWeightMidPlan.fits)
  checkEq("NPU high weight mid patches",
    highWeightMidPlan.weightPatchCount, 2)
  checkEq("NPU high weight mid psram size",
    highWeightMidPlan.psramPatchSize, 4096)
  checkEq("NPU high weight mid psram patches",
    highWeightMidPlan.psramPatchCount, 4)
  checkEq("NPU high weight mid patches",
    highWeightMidPlan.psramMidPatchCount, 4)

proc checkAllocatorPsramPatchPlan() =
  let psramPatchLayer = BlaiCpuInstLayer64(
    layerType: ord(blaiConvMax).int32,
    w: 512,
    h: 1,
    c: 16,
    outW: 512,
    outH: 1,
    outC: 4,
    groups: 1,
    size: 3)
  let psramPatchLine = blaiPlanLinePatchMemAlloc(psramPatchLayer)
  let psramPatchPlan = blaiPlanPsramPatchMemAlloc(
    psramPatchLayer, psramPatchLine)
  var psramPatchPlanInto: BlaiMemAllocWeightPatchPlan
  blaiPlanPsramPatchMemAllocInto(
    psramPatchLayer, psramPatchLine, psramPatchPlanInto)
  check("NPU psram patch into equal", psramPatchPlanInto == psramPatchPlan)
  check("NPU psram patch line fits", psramPatchLine.fits)
  checkEq("NPU psram patch line count", psramPatchLine.linePatchCount, 2)
  check("NPU psram patch fits", psramPatchPlan.fits)
  check("NPU psram patch active", psramPatchPlan.active)
  checkEq("NPU psram patch weight estimate",
    psramPatchPlan.estimatedWeightBytes, 64)
  checkEq("NPU psram patch estimate", psramPatchPlan.estimatedPsramBytes, 131072)
  checkEq("NPU psram patch out patch", psramPatchPlan.outputChannelPatch, 1)
  checkEq("NPU psram patch count", psramPatchPlan.weightPatchCount, 4)
  checkEq("NPU psram patch size", psramPatchPlan.psramPatchSize, 512)
  checkEq("NPU psram patch patches", psramPatchPlan.psramPatchCount, 8)
  var psramPatchCtrl: BlaiPsramCtrl
  blaiApplyHighWeightPatchMemAlloc(psramPatchCtrl, psramPatchPlan)
  checkEq("NPU psram patch ctrl out3",
    cast[uint32](psramPatchCtrl.weightPatchOutC[3]), 1)
  checkEq("NPU psram patch ctrl size",
    cast[uint32](psramPatchCtrl.psramPatchSize), 512)
  let fullPsramPatchPlan = blaiPlanMemAlloc(psramPatchLayer)
  check("NPU full psram patch fits", fullPsramPatchPlan.fits)
  checkEq("NPU full psram patch branch",
    ord(fullPsramPatchPlan.branch).uint32,
    ord(blaiMemAllocPsramPatch).uint32)
  var fullPsramPatchCtrl: BlaiPsramCtrl
  blaiApplyMemAllocPlan(fullPsramPatchCtrl, fullPsramPatchPlan)
  checkEq("NPU full psram line count",
    cast[uint32](fullPsramPatchCtrl.linePatchCount), 2)
  checkEq("NPU full psram ctrl count",
    cast[uint32](fullPsramPatchCtrl.weightPatchCount), 4)

proc checkTensorTransferPlanning() =
  let transferLayer = BlaiCpuInstLayer64(
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
    dramIn: [1'i32, 2, 3, 0, 0, 0, 0, 0],
    dramOut: [4'i32, 0, 0, 0, 0, 0, 0, 0],
    dramMidOut: 6)
  let firstInputPlan = blaiNpuInputTransferPlan(transferLayer, 0, 0)
  var firstInputPlanInto: BlaiTensorTransferPlan
  blaiNpuInputTransferPlanInto(transferLayer, 0, 0, firstInputPlanInto)
  check("NPU input transfer into equal", firstInputPlanInto == firstInputPlan)
  checkEq("NPU input transfer bytes", firstInputPlan.bytes, 24)
  checkEq("NPU input transfer channels", firstInputPlan.paddedChannels, 4)
  let extraInputPlan = blaiNpuInputTransferPlan(transferLayer, 0, 1)
  var extraInputPlanInto: BlaiTensorTransferPlan
  blaiNpuInputTransferPlanInto(transferLayer, 0, 1, extraInputPlanInto)
  check("NPU extra input transfer into equal",
    extraInputPlanInto == extraInputPlan)
  checkEq("NPU extra input transfer bytes", extraInputPlan.bytes, 48)
  check("NPU extra input row padded", extraInputPlan.rowPadded)
  let outputTransferPlan = blaiNpuOutputTransferPlan(transferLayer)
  var outputTransferPlanInto: BlaiNpuOutputTransferPlan
  blaiNpuOutputTransferPlanInto(transferLayer, outputTransferPlanInto)
  check("NPU output transfer into equal",
    outputTransferPlanInto == outputTransferPlan)
  checkEq("NPU output transfer bytes", outputTransferPlan.output.bytes, 48)
  checkEq("NPU mid output transfer bytes", outputTransferPlan.midOutput.bytes, 90)
  var alignedTransferLayer = transferLayer
  alignedTransferLayer.outC = 8
  let alignedOutputPlan = blaiNpuOutputTransferPlan(alignedTransferLayer)
  checkEq("NPU aligned output transfer bytes", alignedOutputPlan.output.bytes, 32)
  let cleanRange = blaiNpuInputCleanRange(extraInputPlan, patchSize = 64)
  var cleanRangeInto: BlaiCacheRange
  blaiNpuInputCleanRangeInto(extraInputPlan, patchSize = 64, cleanRangeInto)
  check("NPU input clean range into equal", cleanRangeInto == cleanRange)
  checkEq("NPU input clean range offset", cleanRange.offset, 128)
  checkEq("NPU input clean range bytes", cleanRange.bytes, 48)
  check("NPU input clean range op", cleanRange.operation == blaiCacheClean)
  let invalidateRange = blaiNpuOutputInvalidateRange(
    outputTransferPlan.output, patchSize = 64)
  var invalidateRangeInto: BlaiCacheRange
  blaiNpuOutputInvalidateRangeInto(
    outputTransferPlan.output, patchSize = 64, invalidateRangeInto)
  check("NPU output invalidate into equal",
    invalidateRangeInto == invalidateRange)
  checkEq("NPU output invalidate offset", invalidateRange.offset, 256)
  checkEq("NPU output invalidate bytes", invalidateRange.bytes, 48)
  check("NPU output invalidate op",
    invalidateRange.operation == blaiCacheInvalidate)
  var runnableTransferLayer = transferLayer
  runnableTransferLayer.npuOn = 1
  runnableTransferLayer.dramPatchSize = 64
  runnableTransferLayer.dramNWeight = 5
  runnableTransferLayer.dramNBias = 3
  let forwardPlan = blaiPlanForwardNpu(runnableTransferLayer, layerIndex = 0)
  check("NPU forward plan runnable", forwardPlan.runnable)
  check("NPU forward plan first layer", forwardPlan.firstLayer)
  checkEq("NPU forward plan patch size", forwardPlan.patchSize, 64)
  checkEq("NPU forward plan weight bytes",
    forwardPlan.weightBuffer.alignedWeightBytes, 8)
  checkEq("NPU forward plan bias bytes", forwardPlan.weightBuffer.biasBytes, 12)
  checkEq("NPU forward plan input clean byte",
    forwardPlan.inputCleanRanges[1].bytes, 48)
  checkEq("NPU forward plan output invalidate",
    forwardPlan.outputInvalidateRange.bytes, 48)
  checkEq("NPU forward plan mid invalidate",
    forwardPlan.midOutputInvalidateRange.bytes, 90)
  let forwardDataPlan = blaiForwardNpuDataBufferPlan(forwardPlan)
  check("NPU forward data plan fits", forwardDataPlan.fits)
  checkEq("NPU forward data bytes", forwardDataPlan.bytes, 474)
  let forwardResourcePlan = blaiPlanForwardResources(
    runnableTransferLayer, layerIndex = 0, useTflite = true)
  let stagedForwardLayer = blaiStageForwardMemoryPlan(runnableTransferLayer)
  let stagedForwardPlan =
    blaiPlanForwardNpu(stagedForwardLayer, layerIndex = 0)
  let stagedForwardDataPlan =
    blaiForwardNpuDataBufferPlan(stagedForwardPlan)
  check("NPU forward resources supported", forwardResourcePlan.supported)
  checkEq("NPU forward resource inst bytes",
    forwardResourcePlan.instructionBytes, BlaiInstructionScratchSize.uint32)
  checkEq("NPU forward resource data bytes",
    forwardResourcePlan.data.bytes, stagedForwardDataPlan.bytes)
  check("NPU forward resources fit",
    blaiForwardResourcesFit(
      forwardResourcePlan, BlaiInstructionScratchSize.uint32,
      forwardResourcePlan.data.bytes, 8, 12, 0))
  check("NPU forward buffer fits",
    blaiForwardNpuBufferFits(forwardPlan, dataBufferBytes = 474))
  check("NPU forward short buffer rejected",
    not blaiForwardNpuBufferFits(forwardPlan, dataBufferBytes = 473))
  let boundedForwardPlan = blaiPlanForwardNpu(
    runnableTransferLayer, layerIndex = 0, dataBufferBytes = 474)
  check("NPU bounded forward plan fits", boundedForwardPlan.bufferFits)
  runnableTransferLayer.npuOn = 0
  let blockedForwardPlan = blaiPlanForwardNpu(runnableTransferLayer, layerIndex = 1)
  check("NPU forward plan blocked", not blockedForwardPlan.runnable)
  check("NPU blocked forward plan bounds",
    blaiForwardNpuBufferFits(blockedForwardPlan, dataBufferBytes = 0))
  checkEq("NPU compact transfer bytes",
    blaiCompactTensorBytes(extraInputPlan), 30)
  var compactTensor: array[30, uint8]
  for i in 0 ..< compactTensor.len:
    compactTensor[i] = (i + 1).uint8
  var npuTensorBuffer: array[176, uint8]
  check("NPU store padded tensor",
    blaiStoreTensorToNpuBuffer(extraInputPlan, 64, compactTensor, npuTensorBuffer))
  checkEq("NPU padded tensor value", npuTensorBuffer[128].uint32, 1)
  checkEq("NPU padded tensor zero", npuTensorBuffer[133].uint32, 0)
  var paddedOutput: array[304, uint8]
  for row in 0 ..< 6:
    for c in 0 ..< 8:
      paddedOutput[256 + row * 8 + c] = (row * 10 + c).uint8
  var compactOutput: array[30, uint8]
  check("NPU load compact tensor",
    blaiLoadTensorFromNpuBuffer(
      outputTransferPlan.output, 64, paddedOutput, compactOutput))
  checkEq("NPU compact tensor value", compactOutput[29].uint32, 54)

template readReg(reg: untyped): uint32 =
  volatileLoad(addr reg)

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
  discard console.sendLine("=== BL808 NPU Smoke Test ===")

  npuSetClock(enable = true, source = npuClk160M, divider = 1)
  check("NPU clock enabled", npuClockEnabled())
  checkEq("NPU clock divider",
    (readReg(cnnClockReset()[].mmClkCpu) and CnnClkDivMask) shr CnnClkDivShift, 1)
  npuSetClockEnable(false)
  check("NPU clock gate disabled", not npuClockEnabled())
  checkEq("NPU clock gate preserves divider",
    (readReg(cnnClockReset()[].mmClkCpu) and CnnClkDivMask) shr CnnClkDivShift, 1)
  npuSetClockEnable(true)
  check("NPU clock gate reenabled", npuClockEnabled())

  npuHoldReset()
  check("NPU reset asserted",
    (readReg(cnnClockReset()[].swResetCodecSub) and CnnResetMask) != 0)
  npuReleaseReset()
  check("NPU reset released",
    (readReg(cnnClockReset()[].swResetCodecSub) and CnnResetMask) == 0)
  npuReset()
  check("NPU reset cycle released",
    (readReg(cnnClockReset()[].swResetCodecSub) and CnnResetMask) == 0)

  npuReleaseSram()
  let vram = readReg(mmMiscVram()[].vramCtrl)
  check("NPU SRAM released", (vram and BlaiSramRelMask) != 0)
  check("NPU SRAM helper", npuSramReleased())

  npuSetCodecQos(aw = true, ar = true)
  let qos = readReg(codecMisc()[].qosCtrl)
  check("NPU AW QoS set", (qos and CnnAwqosMask) != 0)
  check("NPU AR QoS set", (qos and CnnArqosMask) != 0)

  npuSetBusLimiters(3, 4)
  checkEq("NPU read limiter", readReg(codecMisc()[].blaiLimiterRead),
    BlaiLimiterModeMask or 3'u32)
  checkEq("NPU write limiter", readReg(codecMisc()[].blaiLimiterWrite),
    BlaiLimiterModeMask or 4'u32)

  npuConfigureInstructionStream(
    instAddr = 0x2203_0000'u32,
    weightAddr = 0x2203_1000'u32,
    biasAddr = 0x2203_2000'u32)
  check("NPU instruction stream configured", npuInstructionStreamConfigured())
  checkEq("NPU instruction addr", readReg(blaiRegs()[].instAddr), 0x2203_0000'u32)
  checkEq("NPU weight addr", readReg(blaiRegs()[].weightAddr), 0x2203_1000'u32)
  checkEq("NPU bias addr", readReg(blaiRegs()[].biasAddr), 0x2203_2000'u32)
  npuConfigureLayerBuffers(NpuLayerBuffers(weightAddr: 0x2203_4000'u32))
  checkEq("NPU layer setup keeps instruction addr",
    readReg(blaiRegs()[].instAddr), 0x2203_0000'u32)
  checkEq("NPU layer setup updates weight addr",
    readReg(blaiRegs()[].weightAddr), 0x2203_4000'u32)
  checkEq("NPU layer setup keeps bias addr",
    readReg(blaiRegs()[].biasAddr), 0x2203_2000'u32)

  let firstLayerConfig = npuPlanLayerConfig(
    NpuLayerBuffers(instAddr: 0x2203_5000'u32),
    inputBufferAddr = 0x2203_6000'u32,
    patchSize = 9,
    firstLayer = true)
  check("NPU first layer config keeps unsigned", not firstLayerConfig.resetUnsignedInput)
  npuSetUnsignedInput(true)
  npuApplyLayerConfig(firstLayerConfig)
  checkEq("NPU layer config instruction",
    readReg(blaiRegs()[].instAddr), 0x2203_5000'u32)
  checkEq("NPU layer config keeps weight",
    readReg(blaiRegs()[].weightAddr), 0x2203_4000'u32)
  checkEq("NPU layer config input",
    readReg(blaiRegs()[].imageAddr), 0x2203_6000'u32)
  checkEq("NPU layer config patch", readReg(blaiRegs()[].imageSeg), 9)
  check("NPU first layer unsigned preserved",
    (readReg(blaiRegs()[].generalCfg) and BlaiImgiUnsignMask) != 0)
  let nextLayerConfig = npuPlanLayerConfig(
    NpuLayerBuffers(biasAddr: 0x2203_7000'u32),
    inputBufferAddr = 0x2203_8000'u32,
    patchSize = 11,
    firstLayer = false)
  check("NPU next layer config resets unsigned", nextLayerConfig.resetUnsignedInput)
  npuApplyLayerConfig(nextLayerConfig)
  checkEq("NPU layer config bias",
    readReg(blaiRegs()[].biasAddr), 0x2203_7000'u32)
  checkEq("NPU layer config next input",
    readReg(blaiRegs()[].imageAddr), 0x2203_8000'u32)
  checkEq("NPU layer config next patch", readReg(blaiRegs()[].imageSeg), 11)
  check("NPU next layer unsigned reset",
    (readReg(blaiRegs()[].generalCfg) and BlaiImgiUnsignMask) == 0)

  let initConfig = npuPlanInitConfig(
    NpuLayerBuffers(
      instAddr: 0x2203_9000'u32,
      weightAddr: 0x2203_A000'u32,
      biasAddr: 0x2203_B000'u32),
    inputBufferAddr = 0x2203_C000'u32,
    patchSize = 13,
    netParams = NpuNetParams(
      unsignedInput: true,
      reluN: 4,
      tensorflowMode: false))
  checkEq("NPU init IRQ", initConfig.interrupt.irq, NpuCnnIrq)
  checkEq("NPU init IRQ priority",
    initConfig.interrupt.preemptPriority.uint32, NpuCnnIrqPreemptPriority.uint32)
  checkEq("NPU init IRQ subpriority",
    initConfig.interrupt.subPriority.uint32, NpuCnnIrqSubPriority.uint32)
  check("NPU init IRQ enable requested", initConfig.interrupt.enable)
  npuApplyInitConfigRegisters(initConfig)
  checkEq("NPU init instruction",
    readReg(blaiRegs()[].instAddr), 0x2203_9000'u32)
  checkEq("NPU init weight",
    readReg(blaiRegs()[].weightAddr), 0x2203_A000'u32)
  checkEq("NPU init bias",
    readReg(blaiRegs()[].biasAddr), 0x2203_B000'u32)
  checkEq("NPU init input",
    readReg(blaiRegs()[].imageAddr), 0x2203_C000'u32)
  checkEq("NPU init patch", readReg(blaiRegs()[].imageSeg), 13)
  check("NPU init unsigned input",
    (readReg(blaiRegs()[].generalCfg) and BlaiImgiUnsignMask) != 0)
  checkEq("NPU init relu-n",
    (readReg(blaiRegs()[].intCfg) and BlaiReluNMask) shr BlaiReluNShift, 4)
  check("NPU init tensorflow off",
    (readReg(blaiRegs()[].tfCfg0) and BlaiTensorflowEnableMask) == 0)

  npuSetInputBuffer(0x2203_3000'u32, 7)
  checkEq("NPU image addr", readReg(blaiRegs()[].imageAddr), 0x2203_3000'u32)
  checkEq("NPU image segments", readReg(blaiRegs()[].imageSeg), 7)

  npuConfigureNetParams(NpuNetParams(
    unsignedInput: true,
    reluN: 6,
    tensorflowMode: true))
  npuSetImageInputMode(npuInputYuv400)
  let general = readReg(blaiRegs()[].generalCfg)
  check("NPU unsigned input set", (general and BlaiImgiUnsignMask) != 0)
  checkEq("NPU image mode",
    (general and BlaiImageModeMask) shr BlaiImageModeShift,
    npuInputYuv400.uint32)

  checkEq("NPU relu-n",
    (readReg(blaiRegs()[].intCfg) and BlaiReluNMask) shr BlaiReluNShift, 6)
  check("NPU tensorflow mode",
    (readReg(blaiRegs()[].tfCfg0) and BlaiTensorflowEnableMask) != 0)
  npuResetUnsignedInput()
  check("NPU unsigned input reset",
    (readReg(blaiRegs()[].generalCfg) and BlaiImgiUnsignMask) == 0)

  npuStop()
  check("NPU execution state stopped", not npuExecutionStarted())

  check("NPU decoded conv eligibility", blaiCanRunOnNpu(BlaiDecodedLayer(
    layerType: blaiConvolutional,
    w: 8,
    h: 8,
    size: 3,
    stride: 1,
    dilation: 1)))
  check("NPU odd stride workaround", not blaiCanRunOnNpu(BlaiDecodedLayer(
    layerType: blaiConvolutional,
    w: 9,
    h: 8,
    size: 3,
    stride: 2,
    dilation: 1)))
  check("NPU CPU layer ABI decode", blaiCanRunOnNpu(toDecodedLayer(BlaiCpuInstLayer64(
    layerType: ord(blaiConvolutional).int32,
    w: 8,
    h: 8,
    c: 4,
    outC: 8,
    size: 3,
    stride: 1,
    dilation: 1))))
  checkEq("NPU channel align", blaiChannelAlign4(5), 8)
  checkEq("NPU byte align", blaiAlign4(5), 8)
  check("NPU weight layer predicate", blaiUsesWeights(blaiMatmul))
  check("NPU multi-input predicate", blaiIsMultiInput(blaiShortcut))
  var instBundle: BlaiNpuInstructionBundle
  instBundle.instTflite[0] = 0x11
  instBundle.instExtra[0] = 0x22
  instBundle.inst[0] = 0x33
  instBundle.useTflite = 1
  instBundle.extraInfo = 1
  var instStream: array[3, BlaiInstruction]
  let encodedInst = blaiEncodeInstructions(instBundle, instStream, 0)
  check("NPU instruction encode fits", encodedInst.fits)
  checkEq("NPU instruction encode count", encodedInst.endCount, 3)
  checkEq("NPU instruction encode tflite", instStream[0][0].uint32, 0x11)
  checkEq("NPU instruction encode extra", instStream[1][0].uint32, 0x22)
  checkEq("NPU instruction encode normal", instStream[2][0].uint32, 0x33)
  let shortInst = blaiEncodeInstructions(instBundle, instStream, 1)
  check("NPU instruction encode bounds", not shortInst.fits)
  let shapeInst = blaiEncodeShapeDescriptor(BlaiNpuShapeDescriptor(
    layerW: 13,
    layerH: 11,
    layerC1: 7,
    layerC2: 5,
    layerO: 17))
  let shapeDecoded = decodeBlaiLayer(shapeInst)
  check("NPU shape descriptor layer", isBlaiLayerInstruction(shapeInst))
  checkEq("NPU shape descriptor w", shapeDecoded.w, 13)
  checkEq("NPU shape descriptor h", shapeDecoded.h, 11)
  checkEq("NPU shape descriptor c1", shapeDecoded.c, 7)
  checkEq("NPU shape descriptor c2", shapeDecoded.cn0, 5)
  checkEq("NPU shape descriptor out", shapeDecoded.outC, 17)
  let normalInst = blaiEncodeNormalDescriptor(BlaiNpuNormalDescriptor(
    shape: BlaiNpuShapeDescriptor(layerW: 9, layerH: 8, layerC1: 7,
                                  layerC2: 6, layerO: 5),
    fdata: 1,
    fweight: 2,
    fbias: 3,
    froute1: 4,
    froute2: 5,
    fout: 6,
    convSize: 3,
    activation: 2))
  let normalDecoded = decodeBlaiLayer(normalInst)
  checkEq("NPU normal descriptor fdata", normalDecoded.fdata, 1)
  checkEq("NPU normal descriptor fweight", normalDecoded.fweight, 2)
  checkEq("NPU normal descriptor fbias", normalDecoded.fbias, 3)
  checkEq("NPU normal descriptor fout", normalDecoded.fout, 6)
  checkEq("NPU normal descriptor size", normalDecoded.size, 3)
  checkEq("NPU normal descriptor activation", normalDecoded.activation, 2)
  let tfliteInst = blaiEncodeTfliteDescriptor(BlaiNpuTfliteDescriptor(
    shape: BlaiNpuShapeDescriptor(layerW: 10, layerH: 9, layerC1: 8,
                                  layerC2: 7, layerO: 6),
    tfInput1Offset: 128,
    tfInput2Offset: 129,
    tfOutputOffset: 130,
    tfOutputShift: -1,
    convSize: 3,
    activation: 2))
  let tfliteDecoded = decodeBlaiLayer(tfliteInst)
  checkEq("NPU tflite descriptor input1", blaiBits(tfliteInst, 61, 8), 128)
  checkEq("NPU tflite descriptor input2", blaiBits(tfliteInst, 69, 8), 129)
  checkEq("NPU tflite descriptor output", tfliteDecoded.tfOutputOffset, 130)
  checkEq("NPU tflite descriptor shift",
    cast[uint32](blaiSignedBits(tfliteInst, 85, 6)), 0xFFFF_FFFF'u32)
  checkEq("NPU tflite descriptor size", tfliteDecoded.size, 3)
  let tfliteQuantInst = blaiEncodeTfliteQuantDescriptor(
    BlaiNpuTfliteQuantDescriptor(
      isTflite: true,
      tfInput1Shift: -3,
      tfInput2Shift: 2,
      tfInput1Multiplier: 0x1234_5678'u32,
      tfInput2Multiplier: 0x89AB_CDEF'u32,
      tfOutputMultiplier: 0x7654_3210'u32,
      quantizedActivationMin: 3,
      quantizedActivationMax: 250))
  checkEq("NPU tflite quant marker", blaiBits(tfliteQuantInst, 0, 1), 1)
  checkEq("NPU tflite quant input1 shift",
    cast[uint32](blaiSignedBits(tfliteQuantInst, 1, 6)), 0xFFFF_FFFD'u32)
  checkEq("NPU tflite quant input2 shift",
    cast[uint32](blaiSignedBits(tfliteQuantInst, 7, 6)), 2)
  checkEq("NPU tflite quant input1 multiplier",
    blaiBits(tfliteQuantInst, 13, 32), 0x1234_5678'u32)
  checkEq("NPU tflite quant input2 multiplier",
    blaiBits(tfliteQuantInst, 45, 32), 0x89AB_CDEF'u32)
  checkEq("NPU tflite quant output multiplier",
    blaiBits(tfliteQuantInst, 77, 32), 0x7654_3210'u32)
  checkEq("NPU tflite quant min", blaiBits(tfliteQuantInst, 109, 8), 3)
  checkEq("NPU tflite quant max", blaiBits(tfliteQuantInst, 117, 8), 250)
  let extraInst = blaiEncodeExtraDescriptor(BlaiNpuExtraDescriptor(
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
    leftShift: -2))
  checkEq("NPU extra descriptor marker", blaiBits(extraInst, 0, 1), 1)
  checkEq("NPU extra descriptor in seg w", blaiBits(extraInst, 1, 12), 31)
  checkEq("NPU extra descriptor out seg w", blaiBits(extraInst, 13, 12), 15)
  checkEq("NPU extra descriptor out w", blaiBits(extraInst, 25, 12), 14)
  checkEq("NPU extra descriptor in group c", blaiBits(extraInst, 37, 12), 4)
  checkEq("NPU extra descriptor out group c", blaiBits(extraInst, 49, 12), 5)
  checkEq("NPU extra descriptor out seg c", blaiBits(extraInst, 61, 12), 10)
  checkEq("NPU extra descriptor out h", blaiBits(extraInst, 73, 12), 13)
  checkEq("NPU extra descriptor stride", blaiBits(extraInst, 85, 3), 1)
  checkEq("NPU extra descriptor dilation", blaiBits(extraInst, 88, 3), 2)
  checkEq("NPU extra descriptor left shift",
    cast[uint32](blaiSignedBits(extraInst, 91, 6)), 0xFFFF_FFFE'u32)
  let extraDecoded = decodeBlaiExternalLayerInfo(extraInst)
  let extraLayerDecoded = decodeBlaiLayer(tfliteInst, extraDecoded)
  check("NPU extra descriptor valid", extraDecoded.valid)
  checkEq("NPU extra descriptor decoded stride", extraLayerDecoded.stride, 2)
  checkEq("NPU extra descriptor decoded dilation", extraLayerDecoded.dilation, 3)
  checkEq("NPU extra descriptor decoded groups", extraLayerDecoded.groups, 2)
  let bundle = blaiTfliteInstructionBundle(
    BlaiNpuTfliteDescriptor(
      shape: BlaiNpuShapeDescriptor(layerW: 7, layerH: 6, layerC1: 5,
                                    layerC2: 4, layerO: 3),
      tfInput1Offset: 10,
      tfInput2Offset: 11,
      tfOutputOffset: 12,
      tfOutputShift: -1,
      convSize: 3,
      activation: 2),
    BlaiNpuCommonDescriptor(
      routeBit: true,
      macBit: 1,
      inLayer1Mem: 4,
      inLayer2Mem: 5,
      outLayerMem: 6,
      instEndBit: true),
    BlaiNpuTfliteQuantDescriptor(
      isTflite: true,
      tfInput1Shift: -1,
      tfInput2Shift: 1,
      tfInput1Multiplier: 0x0102_0304'u32,
      tfInput2Multiplier: 0x1112_1314'u32,
      tfOutputMultiplier: 0x2122_2324'u32,
      quantizedActivationMin: 0,
      quantizedActivationMax: 255),
    BlaiNpuExtraDescriptor(
      isExtra: true,
      inSegW: 7,
      outSegW: 6,
      outW: 6,
      inGroupC: 5,
      outGroupC: 3,
      outSegC: 3,
      outH: 6,
      stride: 2,
      dilation: 1,
      leftShift: 0))
  var bundleStream: array[3, BlaiInstruction]
  let bundleEncode = blaiEncodeInstructions(bundle, bundleStream, 0)
  let bundleExt = decodeBlaiExternalLayerInfo(bundleStream[1])
  let bundleLayer = decodeBlaiLayer(bundleStream[2], bundleExt)
  check("NPU descriptor bundle fits", bundleEncode.fits)
  checkEq("NPU descriptor bundle count", bundleEncode.endCount, 3)
  checkEq("NPU descriptor bundle tflite marker", blaiBits(bundleStream[0], 0, 1), 1)
  checkEq("NPU descriptor bundle tflite multiplier",
    blaiBits(bundleStream[0], 13, 32), 0x0102_0304'u32)
  checkEq("NPU descriptor bundle extra marker", blaiBits(bundleStream[1], 0, 1), 1)
  checkEq("NPU descriptor bundle extra stride", blaiBits(bundleStream[1], 85, 3), 1)
  checkEq("NPU descriptor bundle type", ord(bundleLayer.layerType).uint32,
    ord(blaiRouteConv).uint32)
  checkEq("NPU descriptor bundle input1", bundleLayer.inLayer1Mem, 4)
  checkEq("NPU descriptor bundle input2", bundleLayer.inLayer2Mem, 5)
  checkEq("NPU descriptor bundle output", bundleLayer.outLayerMem, 6)
  checkEq("NPU descriptor bundle stride", bundleLayer.stride, 2)
  var projectedCommonPlan: BlaiFetchMemoryPlan
  projectedCommonPlan.inputCount = 2
  projectedCommonPlan.inputSlots[0] = 9
  projectedCommonPlan.inputSlots[1] = 10
  projectedCommonPlan.outputSlot = 11
  projectedCommonPlan.midOutputSlot = 12
  let projectedCommon = blaiCommonDescriptor(
    BlaiCpuInstLayer64(
      layerType: ord(blaiRouteConv).int32,
      imgIn: 1,
      midOut: 1,
      halt: 1),
    projectedCommonPlan,
    descriptorHalt = true,
    midOutState = true)
  var projectedCommonInst = normalInst
  blaiApplyCommonDescriptor(projectedCommonInst, projectedCommon)
  let projectedCommonDecoded = decodeBlaiLayer(projectedCommonInst)
  checkEq("NPU common projection type", ord(projectedCommonDecoded.layerType).uint32,
    ord(blaiRouteConv).uint32)
  checkEq("NPU common projection img", blaiBits(projectedCommonInst, 97, 1), 1)
  checkEq("NPU common projection input1", projectedCommonDecoded.inLayer1Mem, 9)
  checkEq("NPU common projection input2", projectedCommonDecoded.inLayer2Mem, 10)
  checkEq("NPU common projection output", projectedCommonDecoded.outLayerMem, 11)
  checkEq("NPU common projection mid", blaiBits(projectedCommonInst, 117, 5), 12)
  checkEq("NPU common projection mid flag", blaiBits(projectedCommonInst, 122, 1), 1)
  checkEq("NPU common projection mid state", blaiBits(projectedCommonInst, 123, 1), 1)
  checkEq("NPU common projection halt flag", blaiBits(projectedCommonInst, 124, 1), 1)
  check("NPU common projection end", projectedCommonDecoded.halt)
  let cpuBundle = blaiLayerInstructionBundle(
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
    projectedCommonPlan,
    useTflite = true,
    c2 = 4,
    includeExtra = true)
  var cpuBundleStream: array[3, BlaiInstruction]
  let cpuBundleEncode = blaiEncodeInstructions(cpuBundle, cpuBundleStream, 0)
  let cpuBundleExt = decodeBlaiExternalLayerInfo(cpuBundleStream[1])
  let cpuBundleLayer = decodeBlaiLayer(cpuBundleStream[2], cpuBundleExt)
  check("NPU CPU descriptor bundle fits", cpuBundleEncode.fits)
  checkEq("NPU CPU descriptor bundle count", cpuBundleEncode.endCount, 3)
  checkEq("NPU CPU descriptor bundle multiplier",
    blaiBits(cpuBundleStream[0], 13, 32), 0x0102_0304'u32)
  checkEq("NPU CPU descriptor bundle in group", blaiBits(cpuBundleStream[1], 37, 12), 5)
  checkEq("NPU CPU descriptor bundle out group", blaiBits(cpuBundleStream[1], 49, 12), 4)
  checkEq("NPU CPU descriptor bundle type", ord(cpuBundleLayer.layerType).uint32,
    ord(blaiRouteConv).uint32)
  checkEq("NPU CPU descriptor bundle output offset", cpuBundleLayer.tfOutputOffset, 122)
  checkEq("NPU CPU descriptor bundle stride", cpuBundleLayer.stride, 2)
  checkEq("NPU CPU descriptor bundle groups", cpuBundleLayer.groups, 2)
  var emitLayer = BlaiCpuInstLayer64(
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
    quantizedActivationMax: 255)
  var emitStream: array[3, BlaiInstruction]
  let emitResult = blaiEmitLayerInstructions(
    emitLayer, projectedCommonPlan, emitStream,
    useTflite = true, c2 = 4, includeExtra = true)
  check("NPU CPU emit fits", emitResult.fits)
  checkEq("NPU CPU emit count", emitLayer.instCnt.uint32, 3)
  checkEq("NPU CPU emit multiplier", blaiBits(emitStream[0], 13, 32), 0x0102_0304'u32)
  checkEq("NPU CPU emit extra stride", blaiBits(emitStream[1], 85, 3), 1)
  var shortEmitStream: array[2, BlaiInstruction]
  emitLayer.instCnt = 0
  let shortEmit = blaiEmitLayerInstructions(
    emitLayer, projectedCommonPlan, shortEmitStream,
    useTflite = true, c2 = 4, includeExtra = true)
  check("NPU CPU emit bounds", not shortEmit.fits)
  checkEq("NPU CPU emit count unchanged", emitLayer.instCnt.uint32, 0)
  checkEq("NPU CPU emit short untouched0", shortEmitStream[0][0].uint32, 0)
  checkEq("NPU CPU emit short untouched1", shortEmitStream[1][0].uint32, 0)
  var fetchEmitLayer = BlaiCpuInstLayer64(
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
  var fetchEmitCtrl = BlaiPsramCtrl(
    psramPatchSize: 64,
    psramPatchCount: 1,
    psramMidPatchCount: 1)
  var fetchEmitStream: array[3, BlaiInstruction]
  let fetchEmit = blaiEmitFetchLayerInstructions(
    fetchEmitLayer, fetchEmitCtrl, fetchEmitStream, blaiFetchGeneral,
    useTflite = true, c2 = 4, includeExtra = true)
  let fetchEmitLayerDecoded = decodeBlaiLayer(
    fetchEmitStream[2], decodeBlaiExternalLayerInfo(fetchEmitStream[1]))
  check("NPU fetch emit memory fits", fetchEmit.fetchFits)
  check("NPU fetch emit fits", fetchEmit.fits)
  checkEq("NPU fetch emit count", fetchEmitLayer.instCnt.uint32, 3)
  checkEq("NPU fetch emit dram patches", fetchEmitLayer.dramPatchNum.uint32, 4)
  checkEq("NPU fetch emit input0", fetchEmitCtrl.sramIn[0].uint32, 0)
  checkEq("NPU fetch emit input1", fetchEmitCtrl.sramIn[1].uint32, 1)
  checkEq("NPU fetch emit mid", fetchEmitCtrl.sramMidOut.uint32, 2)
  checkEq("NPU fetch emit output", fetchEmitCtrl.sramOut[0].uint32, 3)
  checkEq("NPU fetch emit type", ord(fetchEmitLayerDecoded.layerType).uint32,
    ord(blaiRouteConv).uint32)
  checkEq("NPU fetch emit decoded output", fetchEmitLayerDecoded.outLayerMem, 3)
  var shortFetchLayer = fetchEmitLayer
  shortFetchLayer.instCnt = 0
  var shortFetchCtrl = fetchEmitCtrl
  shortFetchCtrl.sramIn[0] = 99
  var shortFetchStream: array[2, BlaiInstruction]
  let shortFetchEmit = blaiEmitFetchLayerInstructions(
    shortFetchLayer, shortFetchCtrl, shortFetchStream, blaiFetchGeneral,
    useTflite = true, c2 = 4, includeExtra = true)
  check("NPU fetch emit short memory fits", shortFetchEmit.fetchFits)
  check("NPU fetch emit short bounds", not shortFetchEmit.fits)
  checkEq("NPU fetch emit short count unchanged", shortFetchLayer.instCnt.uint32, 0)
  checkEq("NPU fetch emit short ctrl unchanged", shortFetchCtrl.sramIn[0].uint32, 99)
  checkEq("NPU fetch emit short stream0", shortFetchStream[0][0].uint32, 0)
  checkEq("NPU fetch emit short stream1", shortFetchStream[1][0].uint32, 0)
  var wrapperLayer = fetchEmitLayer
  wrapperLayer.instCnt = 7
  var wrapperCtrl = BlaiPsramCtrl(
    psramPatchSize: 64,
    psramPatchCount: 1,
    psramMidPatchCount: 1)
  var wrapperStream: array[BlaiInstructionScratchSize div BlaiInstructionSize,
                           BlaiInstruction]
  for i in 0 ..< wrapperStream.len:
    wrapperStream[i][0] = 0xAA'u8
  let wrapperResult = blaiEncodeCpuLayer(
    wrapperLayer, wrapperCtrl, wrapperStream,
    allocationSucceeded = true,
    useTflite = true,
    c2 = 4,
    includeExtra = true)
  check("NPU wrapper runnable", wrapperResult.plan.runnable)
  check("NPU wrapper scratch clear", wrapperResult.scratchCleared)
  check("NPU wrapper encoded", wrapperResult.encoded)
  checkEq("NPU wrapper count", wrapperLayer.instCnt.uint32, 3)
  checkEq("NPU wrapper patches", wrapperLayer.dramPatchNum.uint32, 4)
  checkEq("NPU wrapper output slot", wrapperCtrl.sramOut[0].uint32, 3)
  checkEq("NPU wrapper multiplier", blaiBits(wrapperStream[0], 13, 32),
    0x0102_0304'u32)
  checkEq("NPU wrapper cleared tail", wrapperStream[3][0].uint32, 0)
  var blockedWrapperLayer = wrapperLayer
  blockedWrapperLayer.npuOn = 1
  blockedWrapperLayer.instCnt = 5
  var blockedWrapperCtrl = wrapperCtrl
  var blockedWrapperStream: array[BlaiInstructionScratchSize div BlaiInstructionSize,
                                  BlaiInstruction]
  blockedWrapperStream[0][0] = 0x55'u8
  let blockedWrapper = blaiEncodeCpuLayer(
    blockedWrapperLayer, blockedWrapperCtrl, blockedWrapperStream,
    allocationSucceeded = false,
    useTflite = true,
    c2 = 4,
    includeExtra = true)
  check("NPU wrapper blocked", not blockedWrapper.plan.runnable)
  check("NPU wrapper blocked scratch", not blockedWrapper.scratchCleared)
  check("NPU wrapper blocked encoded", not blockedWrapper.encoded)
  checkEq("NPU wrapper blocked npu", blockedWrapperLayer.npuOn.uint32, 0)
  checkEq("NPU wrapper blocked count", blockedWrapperLayer.instCnt.uint32, 5)
  checkEq("NPU wrapper blocked stream", blockedWrapperStream[0][0].uint32, 0x55)
  var commonInst = normalInst
  blaiApplyCommonDescriptor(commonInst, BlaiNpuCommonDescriptor(
    imgIn: true,
    maxCheck: true,
    routeBit: false,
    macBit: 1,
    inLayer1Mem: 9,
    inLayer2Mem: 10,
    outLayerMem: 11,
    midLayerMem: 12,
    midOut: true,
    midOutState: true,
    halt: true,
    upsampleBit: false,
    macBitExt: false,
    instEndBit: true))
  let commonDecoded = decodeBlaiLayer(commonInst)
  checkEq("NPU common descriptor type", ord(commonDecoded.layerType).uint32,
    ord(blaiConvMax).uint32)
  checkEq("NPU common descriptor img", blaiBits(commonInst, 97, 1), 1)
  checkEq("NPU common descriptor input1", commonDecoded.inLayer1Mem, 9)
  checkEq("NPU common descriptor input2", commonDecoded.inLayer2Mem, 10)
  checkEq("NPU common descriptor output", commonDecoded.outLayerMem, 11)
  checkEq("NPU common descriptor mid", blaiBits(commonInst, 117, 5), 12)
  checkEq("NPU common descriptor mid flag", blaiBits(commonInst, 122, 1), 1)
  checkEq("NPU common descriptor mid state", blaiBits(commonInst, 123, 1), 1)
  checkEq("NPU common descriptor halt flag", blaiBits(commonInst, 124, 1), 1)
  check("NPU common descriptor end", commonDecoded.halt)
  checkFetchDescriptorOperands()
  checkRouteDescriptorLoopPlan()
  checkAllocatorSinglePatchPlans()
  checkAllocatorLinePatchPlans()
  checkAllocatorHighWeightPlan()
  checkAllocatorHighWeightMidPlan()
  checkAllocatorPsramPatchPlan()
  let softmaxPatchPlan = blaiPlanSinglePatchMemAlloc(BlaiCpuInstLayer64(
    layerType: ord(blaiSoftmax).int32,
    w: 3,
    h: 2,
    c: 4,
    outW: 1,
    outH: 1,
    outC: 5,
    midOut: 1))
  checkEq("NPU softmax mid patches", softmaxPatchPlan.psramMidPatchCount, 4)
  var fetchLayer = BlaiCpuInstLayer64(
    layerType: ord(blaiConvolutional).int32,
    w: 4,
    h: 4,
    c: 3,
    cn: [5'i32, 7, 0, 0, 0, 0, 0],
    inputNum: 2)
  var fetchCtrl = BlaiPsramCtrl(psramPatchSize: 32, psramPatchCount: 1,
                                psramMidPatchCount: 2)
  let generalFetchPlan = blaiPlanFetchMemory(
    fetchLayer, fetchCtrl, blaiFetchGeneral)
  check("NPU fetch general fits", generalFetchPlan.fits)
  checkEq("NPU fetch general input slot",
    generalFetchPlan.inputSlots[1], 2)
  checkEq("NPU fetch general output slot", generalFetchPlan.outputSlot, 7)
  checkEq("NPU fetch general dram patches",
    generalFetchPlan.dramPatchCount, 8)
  blaiApplyFetchMemoryPlan(fetchCtrl, fetchLayer, generalFetchPlan)
  checkEq("NPU fetch general ctrl out",
    cast[uint32](fetchCtrl.sramOut[0]), 7)
  checkEq("NPU fetch general layer patches",
    cast[uint32](fetchLayer.dramPatchNum), 8)
  fetchLayer.inputNum = 3
  fetchCtrl.psramPatchSize = 32
  fetchCtrl.psramPatchCount = 4
  let routeFetchPlan = blaiPlanFetchMemory(
    fetchLayer, fetchCtrl, blaiFetchRoute)
  check("NPU fetch route fits", routeFetchPlan.fits)
  checkEq("NPU fetch route grown patch", routeFetchPlan.patchSize, 64)
  checkEq("NPU fetch route input slot", routeFetchPlan.inputSlots[2], 3)
  checkEq("NPU fetch route dram patches", routeFetchPlan.dramPatchCount, 11)
  let weightPlan = blaiWeightBufferPlan(blaiConvolutional, 5, 3)
  var weightPlanInto: BlaiWeightBufferPlan
  blaiWeightBufferPlanInto(blaiConvolutional, 5, 3, weightPlanInto)
  check("NPU weight plan into equal", weightPlanInto == weightPlan)
  check("NPU weight plan active", weightPlan.usesWeights)
  checkEq("NPU weight plan aligned bytes", weightPlan.alignedWeightBytes, 8)
  checkEq("NPU weight plan bias offset", weightPlan.biasOffset, 8)
  checkEq("NPU weight plan total bytes", weightPlan.totalBytes, 20)
  check("NPU weight plan fits", blaiWeightBufferFits(weightPlan, 8, 12))
  let npuWeightLoadLayer = BlaiCpuInstLayer64(
    layerType: ord(blaiRouteConv).int32,
    c: 2,
    cn: [3'i32, 5, 0, 0, 0, 0, 0],
    inputNum: 3,
    outC: 8,
    groups: 4,
    size: 3,
    dilation: 2,
    dramNWeight: 9,
    tfInput2Offset: -7)
  let npuWeightLoadPlan = blaiPlanNpuWeightLoad(npuWeightLoadLayer, useTflite = true)
  check("NPU weight load active", npuWeightLoadPlan.active)
  checkEq("NPU weight load kernel",
    npuWeightLoadPlan.kernel.uint32, blaiNpuWeightKernel3x3Dilated.uint32)
  checkEq("NPU weight load effective channels",
    npuWeightLoadPlan.effectiveInputChannels, 10)
  checkEq("NPU weight load group limit",
    npuWeightLoadPlan.groupChannelLimit, 2)
  check("NPU weight load temp buffer", npuWeightLoadPlan.usesTemporaryGroupBuffer)
  checkEq("NPU weight load temp bytes",
    npuWeightLoadPlan.temporaryWeightBytes, 36)
  checkEq("NPU weight load padding",
    cast[uint32](npuWeightLoadPlan.weightPadding), 0xFFFF_FFF9'u32)
  checkEq("NPU weight load bias pack", npuWeightLoadPlan.biasPack, 1)
  var unsupportedNpuWeightLayer = npuWeightLoadLayer
  unsupportedNpuWeightLayer.size = 5
  unsupportedNpuWeightLayer.dilation = 2
  let unsupportedNpuWeightPlan = blaiPlanNpuWeightLoad(
    unsupportedNpuWeightLayer, useTflite = false)
  check("NPU weight load unsupported kernel",
    not unsupportedNpuWeightPlan.supportedKernel)
  checkEq("NPU weight load default bias pack",
    unsupportedNpuWeightPlan.biasPack, 4)
  var zeroWeightBuf: array[10, uint8]
  for i in 0 ..< zeroWeightBuf.len:
    zeroWeightBuf[i] = 0xA5'u8
  var zeroWeightCursor = 1'u32
  check("NPU zero weight dump",
    blaiNpuDumpZero(2, -7, 2, zeroWeightBuf, zeroWeightCursor))
  checkEq("NPU zero weight cursor", zeroWeightCursor, 9)
  checkEq("NPU zero weight padding", zeroWeightBuf[1].uint32, 0xF9)
  checkEq("NPU zero weight bound", zeroWeightBuf[9].uint32, 0xA5)
  var pixelLayer = BlaiCpuInstLayer64(
    layerType: ord(blaiConvolutional).int32,
    c: 4,
    outC: 3,
    size: 3)
  var sourceWeights: array[512, int32]
  for i in 0 ..< sourceWeights.len:
    sourceWeights[i] = i.int32
  var pixelWeightBuf: array[8, uint8]
  var pixelCursor = 0'u32
  checkEq("NPU pixel weight index",
    blaiNpuWeightSourceIndex(
      pixelLayer, outIn = 1, inputChannel = 2, weightTap = 4,
      cStart = 0, groups = 1), 58)
  check("NPU pixel weight dump",
    blaiNpuDumpWeightPixel(
      pixelLayer,
      outIn = 1, cin = 1, weightTap = 4, cStart = 0, cEnd = 3,
      weightPadding = -7, groups = 1, pack = 2,
      weightBuf = pixelWeightBuf, weightsIn = sourceWeights,
      weightCursor = pixelCursor))
  checkEq("NPU pixel weight cursor", pixelCursor, 4)
  checkEq("NPU pixel weight value 0", pixelWeightBuf[0].uint32, 49)
  checkEq("NPU pixel weight value 3", pixelWeightBuf[3].uint32, 94)
  pixelCursor = 0
  check("NPU pixel weight padding",
    blaiNpuDumpWeightPixel(
      pixelLayer,
      outIn = 2, cin = 2, weightTap = 1, cStart = 0, cEnd = 3,
      weightPadding = -7, groups = 1, pack = 2,
      weightBuf = pixelWeightBuf, weightsIn = sourceWeights,
      weightCursor = pixelCursor))
  checkEq("NPU pixel padded value", pixelWeightBuf[1].uint32, 0xF9)
  var weights3x3Buf: array[40, uint8]
  var weights3x3Cursor = 0'u32
  check("NPU 3x3 weight dump",
    blaiNpuDumpWeights3x3(
      pixelLayer, 0, 0, 0, 4, -7, 1, 2,
      weightBuf = weights3x3Buf, weightsIn = sourceWeights,
      weightCursor = weights3x3Cursor))
  checkEq("NPU 3x3 weight cursor", weights3x3Cursor, 36)
  checkEq("NPU 3x3 first input", weights3x3Buf[1].uint32, 9)
  checkEq("NPU 3x3 last output", weights3x3Buf[35].uint32, 53)
  var unaligned3x3Cursor = 0'u32
  check("NPU 3x3 unaligned skip",
    blaiNpuDumpWeights3x3(
      pixelLayer, 1, 0, 0, 4, -7, 1, 2,
      weightBuf = weights3x3Buf, weightsIn = sourceWeights,
      weightCursor = unaligned3x3Cursor))
  checkEq("NPU 3x3 unaligned cursor", unaligned3x3Cursor, 0)
  var padded3x3Cursor = 0'u32
  check("NPU 3x3 padding",
    blaiNpuDumpWeights3x3(
      pixelLayer, 2, 2, 0, 3, -7, 1, 2,
      weightBuf = weights3x3Buf, weightsIn = sourceWeights,
      weightCursor = padded3x3Cursor))
  checkEq("NPU 3x3 padded cursor", padded3x3Cursor, 36)
  checkEq("NPU 3x3 padded value", weights3x3Buf[1].uint32, 0xF9)
  var weights3x3DilBuf: array[340, uint8]
  var weights3x3DilCursor = 0'u32
  check("NPU dilated 3x3 weight dump",
    blaiNpuDumpWeights3x3Dilated(
      pixelLayer, 0, 0, 0, 4, -7, 1, 2,
      weightBuf = weights3x3DilBuf, weightsIn = sourceWeights,
      weightCursor = weights3x3DilCursor))
  checkEq("NPU dilated 3x3 cursor", weights3x3DilCursor, 324)
  checkEq("NPU dilated 3x3 first padding", weights3x3DilBuf[0].uint32, 0xF9)
  checkEq("NPU dilated 3x3 first tap", weights3x3DilBuf[16].uint32, 4)
  checkEq("NPU dilated 3x3 final tap", weights3x3DilBuf[291].uint32, 53)
  var unaligned3x3DilCursor = 0'u32
  check("NPU dilated 3x3 unaligned skip",
    blaiNpuDumpWeights3x3Dilated(
      pixelLayer, 1, 0, 0, 4, -7, 1, 2,
      weightBuf = weights3x3DilBuf, weightsIn = sourceWeights,
      weightCursor = unaligned3x3DilCursor))
  checkEq("NPU dilated 3x3 unaligned cursor", unaligned3x3DilCursor, 0)
  var weights5x5Layer = pixelLayer
  weights5x5Layer.size = 5
  var weights5x5Buf: array[340, uint8]
  var weights5x5Cursor = 0'u32
  check("NPU 5x5 weight dump",
    blaiNpuDumpWeights5x5(
      weights5x5Layer, 0, 0, 0, 4, -7, 1, 2,
      weightBuf = weights5x5Buf, weightsIn = sourceWeights,
      weightCursor = weights5x5Cursor))
  checkEq("NPU 5x5 cursor", weights5x5Cursor, 324)
  checkEq("NPU 5x5 first tap", weights5x5Buf[0].uint32, 6)
  checkEq("NPU 5x5 center tap", weights5x5Buf[68].uint32, 0)
  checkEq("NPU 5x5 final tap", weights5x5Buf[291].uint32, 149)
  checkEq("NPU 5x5 tail padding", weights5x5Buf[323].uint32, 0xF9)
  var unaligned5x5Cursor = 0'u32
  check("NPU 5x5 unaligned skip",
    blaiNpuDumpWeights5x5(
      weights5x5Layer, 1, 0, 0, 4, -7, 1, 2,
      weightBuf = weights5x5Buf, weightsIn = sourceWeights,
      weightCursor = unaligned5x5Cursor))
  checkEq("NPU 5x5 unaligned cursor", unaligned5x5Cursor, 0)
  var weights7x7Layer = pixelLayer
  weights7x7Layer.size = 7
  var weights7x7Buf: array[340, uint8]
  var weights7x7Cursor = 0'u32
  check("NPU 7x7 weight dump",
    blaiNpuDumpWeights7x7(
      weights7x7Layer, 0, 0, 0, 4, -7, 1, 2,
      weightBuf = weights7x7Buf, weightsIn = sourceWeights,
      weightCursor = weights7x7Cursor))
  checkEq("NPU 7x7 cursor", weights7x7Cursor, 324)
  checkEq("NPU 7x7 first tap", weights7x7Buf[0].uint32, 16)
  checkEq("NPU 7x7 first padding", weights7x7Buf[36].uint32, 0xF9)
  checkEq("NPU 7x7 middle tap", weights7x7Buf[172].uint32, 28)
  checkEq("NPU 7x7 final tap", weights7x7Buf[307].uint32, 37)
  checkEq("NPU 7x7 tail padding", weights7x7Buf[323].uint32, 0xF9)
  var unaligned7x7Cursor = 0'u32
  check("NPU 7x7 unaligned skip",
    blaiNpuDumpWeights7x7(
      weights7x7Layer, 1, 0, 0, 4, -7, 1, 2,
      weightBuf = weights7x7Buf, weightsIn = sourceWeights,
      weightCursor = unaligned7x7Cursor))
  checkEq("NPU 7x7 unaligned cursor", unaligned7x7Cursor, 0)
  var dispatchLayer = pixelLayer
  dispatchLayer.tfInput2Offset = -7
  let dispatchPlan = blaiPlanNpuWeightLoad(dispatchLayer, useTflite = true)
  var dispatchBuf: array[40, uint8]
  var dispatchCursor = 0'u32
  check("NPU weight kernel dispatch 3x3",
    blaiNpuDumpWeightKernel(
      dispatchLayer, 0, 0, 0, 4, dispatchPlan, 2,
      weightBuf = dispatchBuf, weightsIn = sourceWeights,
      weightCursor = dispatchCursor))
  checkEq("NPU weight kernel dispatch cursor", dispatchCursor, 36)
  checkEq("NPU weight kernel dispatch first", dispatchBuf[0].uint32, 0)
  checkEq("NPU weight kernel dispatch last", dispatchBuf[35].uint32, 53)
  var unsupportedDispatchLayer = weights5x5Layer
  unsupportedDispatchLayer.dilation = 2
  let unsupportedDispatchPlan = blaiPlanNpuWeightLoad(
    unsupportedDispatchLayer, useTflite = true)
  var unsupportedDispatchCursor = 7'u32
  check("NPU weight kernel dispatch unsupported",
    not blaiNpuDumpWeightKernel(
      unsupportedDispatchLayer, 0, 0, 0, 4, unsupportedDispatchPlan, 2,
      weightBuf = weights5x5Buf, weightsIn = sourceWeights,
      weightCursor = unsupportedDispatchCursor))
  checkEq("NPU weight kernel unsupported cursor", unsupportedDispatchCursor, 7)
  var groupedDispatchLayer = dispatchLayer
  groupedDispatchLayer.c = 8
  groupedDispatchLayer.outC = 8
  groupedDispatchLayer.groups = 2
  let groupedDispatchPlan = blaiPlanNpuWeightLoad(
    groupedDispatchLayer, useTflite = true)
  let groupedRange0 = blaiNpuWeightChannelRange(groupedDispatchPlan, 0)
  let groupedRange4 = blaiNpuWeightChannelRange(groupedDispatchPlan, 4)
  checkEq("NPU weight group range 0 start", groupedRange0.cStart, 0)
  checkEq("NPU weight group range 0 end", groupedRange0.cEnd, 4)
  checkEq("NPU weight group range 4 start", groupedRange4.cStart, 4)
  checkEq("NPU weight group range 4 end", groupedRange4.cEnd, 8)
  var biasSource: array[3, int32] = [10'i32, 20, 30]
  var packedBiasBuf: array[4, int32]
  var packedBiasCursor = 0'u32
  let nonTfliteBiasPlan = blaiPlanNpuWeightLoad(
    dispatchLayer, useTflite = false)
  check("NPU bias pack dump",
    blaiNpuDumpBiasPack(
      0, nonTfliteBiasPlan, packedBiasBuf, biasSource, packedBiasCursor))
  checkEq("NPU bias pack cursor", packedBiasCursor, 4)
  checkEq("NPU bias pack first", packedBiasBuf[0].uint32, 10)
  checkEq("NPU bias pack pad", packedBiasBuf[3].uint32, 0)
  var streamWeightBuf: array[160, uint8]
  var streamWeightCursor = 0'u32
  var streamBiasBuf: array[3, int32]
  var streamBiasCursor = 0'u32
  check("NPU weight stream dump",
    blaiNpuDumpWeightStream(
      dispatchLayer, dispatchPlan, 2,
      weightBuf = streamWeightBuf, weightsIn = sourceWeights,
      weightCursor = streamWeightCursor,
      biasBuf = streamBiasBuf, biasesIn = biasSource,
      biasCursor = streamBiasCursor))
  checkEq("NPU weight stream cursor", streamWeightCursor, 144)
  checkEq("NPU weight stream first", streamWeightBuf[0].uint32, 0)
  checkEq("NPU weight stream second tile", streamWeightBuf[36].uint32, 18)
  checkEq("NPU weight stream final pad", streamWeightBuf[143].uint32, 0xF9)
  checkEq("NPU weight stream bias cursor", streamBiasCursor, 3)
  var materializeLayer = dispatchLayer
  materializeLayer.dramNWeight = 144
  materializeLayer.dramNBias = 3
  var materializedWeightBuf: array[144, uint8]
  var materializedBiasBuf: array[3, int32]
  var noTemporaryWeights: array[0, int32]
  let materialized = blaiNpuMaterializeWeightBuffers(
    materializeLayer, useTflite = true,
    weightBuf = materializedWeightBuf, biasBuf = materializedBiasBuf,
    weightsIn = sourceWeights, biasesIn = biasSource,
    temporaryWeights = noTemporaryWeights, pack = 2)
  check("NPU materialize active", materialized.active)
  check("NPU materialize fit detail", materialized.bufferFit.fits)
  checkEq("NPU materialize weight required",
    materialized.bufferFit.requiredWeightBytes, 144)
  checkEq("NPU materialize bias required",
    materialized.bufferFit.requiredBiasBytes, 12)
  check("NPU materialize ok", materialized.materialized)
  checkEq("NPU materialize weight cursor", materialized.weightCursor, 144)
  checkEq("NPU materialize bias cursor", materialized.biasCursor, 3)
  checkEq("NPU materialize stream byte", materializedWeightBuf[36].uint32, 18)
  checkEq("NPU materialize bias", materializedBiasBuf[2].uint32, 30)
  var tempLayer = dispatchLayer
  tempLayer.c = 8
  tempLayer.outC = 8
  tempLayer.groups = 4
  tempLayer.dramNWeight = 288
  let tempPlan = blaiPlanNpuWeightLoad(tempLayer, useTflite = true)
  check("NPU temporary group plan", tempPlan.usesTemporaryGroupBuffer)
  checkEq("NPU temporary group count",
    blaiNpuTemporaryGroupCount(tempPlan, 4), 2)
  var temporaryWeights: array[288, int32]
  check("NPU temporary grouped weights",
    blaiNpuMaterializeTemporaryGroupedWeights(
      tempLayer, tempPlan, 4, sourceWeights, temporaryWeights))
  checkEq("NPU temporary grouped first",
    temporaryWeights[0].uint32, 0)
  checkEq("NPU temporary grouped copied",
    temporaryWeights[90].uint32, 36)
  checkEq("NPU temporary grouped padding",
    cast[uint32](temporaryWeights[18]), 0xFFFF_FFF9'u32)
  var tempStreamWeightBuf: array[300, uint8]
  var tempStreamWeightCursor = 0'u32
  var tempStreamBiasBuf: array[8, int32]
  var tempStreamBiases: array[8, int32] = [1'i32, 2, 3, 4, 5, 6, 7, 8]
  var tempStreamBiasCursor = 0'u32
  check("NPU weight stream temporary",
    blaiNpuDumpWeightStreamWithTemporary(
      tempLayer, tempPlan, 4,
      weightBuf = tempStreamWeightBuf, weightsIn = sourceWeights,
      temporaryWeights = temporaryWeights,
      weightCursor = tempStreamWeightCursor,
      biasBuf = tempStreamBiasBuf, biasesIn = tempStreamBiases,
      biasCursor = tempStreamBiasCursor))
  checkEq("NPU temporary stream cursor", tempStreamWeightCursor, 288)
  checkEq("NPU temporary stream first", tempStreamWeightBuf[0].uint32, 0)
  checkEq("NPU temporary stream copied", tempStreamWeightBuf[10].uint32, 36)
  checkEq("NPU temporary stream bias cursor", tempStreamBiasCursor, 8)
  var tempMaterializedWeightBuf: array[288, uint8]
  var tempMaterializedBiasBuf: array[8, int32]
  var tempMaterializedScratch: array[288, int32]
  let tempMaterialized = blaiNpuMaterializeWeightBuffers(
    tempLayer, useTflite = true,
    weightBuf = tempMaterializedWeightBuf,
    biasBuf = tempMaterializedBiasBuf,
    weightsIn = sourceWeights,
    biasesIn = tempStreamBiases,
    temporaryWeights = tempMaterializedScratch,
    pack = 4)
  check("NPU materialize temporary ok", tempMaterialized.materialized)
  checkEq("NPU materialize temporary required",
    tempMaterialized.requiredTemporaryElements, 288)
  checkEq("NPU materialize temporary provided",
    tempMaterialized.providedTemporaryElements, 288)
  checkEq("NPU materialize temporary cursor",
    tempMaterialized.weightCursor, 288)
  checkEq("NPU materialize temporary copied",
    tempMaterializedWeightBuf[10].uint32, 36)
  checkEq("NPU materialize temporary bias",
    tempMaterializedBiasBuf[7].uint32, 8)
  let cpuWeightLayer = BlaiCpuInstLayer64(
    layerType: ord(blaiConvolutional).int32,
    c: 3,
    cn: [1'i32, 0, 0, 0, 0, 0, 0],
    inputNum: 2,
    outC: 8,
    groups: 0,
    size: 3)
  checkEq("NPU CPU weight input channels",
    blaiCpuWeightInputChannels(cpuWeightLayer), 4)
  checkEq("NPU CPU weight elements",
    blaiCpuWeightElementCount(cpuWeightLayer), 288)
  checkEq("NPU CPU bias elements",
    blaiCpuBiasElementCount(cpuWeightLayer), 8)
  checkEq("NPU CPU tflite bias bytes",
    blaiCpuBiasStreamBytes(cpuWeightLayer, useTflite = true), 32)
  let streamLayers = [
    BlaiCpuInstLayer64(layerType: ord(blaiRoute).int32, dspOn: 1),
    BlaiCpuInstLayer64(
      layerType: ord(blaiSsd).int32,
      dspOn: 1,
      dataType: 1,
      w: 2,
      h: 3,
      c: 4),
    BlaiCpuInstLayer64(
      layerType: ord(blaiConvolutional).int32,
      dspOn: 1,
      c: 2,
      outC: 5,
      size: 1)
  ]
  let cpuWeightPlan = blaiCpuWeightStreamPlan(streamLayers, 0)
  var cpuWeightPlanInto: BlaiCpuWeightStreamPlan
  blaiCpuWeightStreamPlanInto(streamLayers, 0, cpuWeightPlanInto)
  check("NPU CPU weight plan into equal", cpuWeightPlanInto == cpuWeightPlan)
  check("NPU CPU weight stream active", cpuWeightPlan.active)
  checkEq("NPU CPU weight stream layer", cpuWeightPlan.layerIndex.uint32, 1)
  checkEq("NPU CPU weight stream bytes", cpuWeightPlan.streamBytes, 24)
  let cpuBiasPlan = blaiCpuBiasStreamPlan(streamLayers, 0, useTflite = true)
  var cpuBiasPlanInto: BlaiCpuBiasStreamPlan
  blaiCpuBiasStreamPlanInto(streamLayers, 0, useTflite = true, cpuBiasPlanInto)
  check("NPU CPU bias plan into equal", cpuBiasPlanInto == cpuBiasPlan)
  check("NPU CPU bias stream active", cpuBiasPlan.active)
  checkEq("NPU CPU bias stream layer", cpuBiasPlan.layerIndex.uint32, 2)
  checkEq("NPU CPU bias stream bytes", cpuBiasPlan.streamBytes, 20)
  checkEq("NPU CPU total weight bytes",
    blaiCpuWeightStreamTotalBytes(streamLayers), 34)
  checkEq("NPU CPU total bias bytes",
    blaiCpuBiasStreamTotalBytes(streamLayers, useTflite = true), 20)
  let cpuStreamTotals = blaiCpuStreamTotals(streamLayers, useTflite = true)
  checkEq("NPU CPU total first weight layer",
    cast[uint32](cpuStreamTotals.firstWeightLayer), 1)
  checkEq("NPU CPU total first bias layer",
    cast[uint32](cpuStreamTotals.firstBiasLayer), 2)
  var emptyStreamLayers: array[0, BlaiCpuInstLayer64]
  let emptyStreamTotals =
    blaiCpuStreamTotals(emptyStreamLayers, useTflite = false)
  check("NPU CPU total no first weight",
    emptyStreamTotals.firstWeightLayer < 0)
  check("NPU CPU total no first bias",
    emptyStreamTotals.firstBiasLayer < 0)
  let firstWeightSegment = blaiCpuWeightStreamSegment(
    streamLayers, blaiCpuStreamCursor(), availableBytes = 34)
  var firstWeightSegmentInto: BlaiCpuWeightStreamSegment
  blaiCpuWeightStreamSegmentInto(
    streamLayers, blaiCpuStreamCursor(), availableBytes = 34,
    firstWeightSegmentInto)
  check("NPU CPU weight segment into equal",
    firstWeightSegmentInto == firstWeightSegment)
  check("NPU CPU weight segment active", firstWeightSegment.active)
  check("NPU CPU weight segment fits", firstWeightSegment.fits)
  checkEq("NPU CPU weight segment next byte",
    firstWeightSegment.nextCursor.byteOffset, 24)
  let secondWeightSegment = blaiCpuWeightStreamSegment(
    streamLayers, firstWeightSegment.nextCursor, availableBytes = 34)
  checkEq("NPU CPU second weight segment layer",
    secondWeightSegment.plan.layerIndex.uint32, 2)
  checkEq("NPU CPU second weight segment byte",
    secondWeightSegment.nextCursor.byteOffset, 34)
  let shortWeightSegment = blaiCpuWeightStreamSegment(
    streamLayers, firstWeightSegment.nextCursor, availableBytes = 33)
  check("NPU CPU short weight segment detected", not shortWeightSegment.fits)
  let firstBiasSegment = blaiCpuBiasStreamSegment(
    streamLayers, blaiCpuStreamCursor(), availableBytes = 20, useTflite = true)
  var firstBiasSegmentInto: BlaiCpuBiasStreamSegment
  blaiCpuBiasStreamSegmentInto(
    streamLayers, blaiCpuStreamCursor(), availableBytes = 20,
    useTflite = true, outResult = firstBiasSegmentInto)
  check("NPU CPU bias segment into equal",
    firstBiasSegmentInto == firstBiasSegment)
  check("NPU CPU bias segment fits", firstBiasSegment.fits)
  checkEq("NPU CPU bias segment next byte",
    firstBiasSegment.nextCursor.byteOffset, 20)
  let biasBytes = [0x34'u8, 0x12'u8, 0x78'u8, 0x56'u8]
  checkEq("NPU CPU fixed bias read",
    blaiReadCpuBias(biasBytes, 0, useTflite = false), 0x34)
  checkEq("NPU CPU tflite bias read",
    blaiReadCpuBias(biasBytes, 0, useTflite = true), 0x5678_1234'u32)
  let i8WeightLayers = [
    BlaiCpuInstLayer64(
      layerType: ord(blaiConvolutional).int32,
      dspOn: 1,
      dataType: 1,
      c: 1,
      outC: 3,
      size: 1)
  ]
  let i8WeightPlan = blaiCpuWeightStreamPlan(i8WeightLayers, 0)
  let signedWeightBytes = [0'u8, 0x7F'u8, 0x80'u8, 0xFF'u8]
  var i8Weights: array[3, int8]
  check("NPU CPU i8 weights stored",
    blaiStoreCpuWeightsI8(i8WeightPlan, signedWeightBytes, 1, i8Weights))
  check("NPU CPU i8 weight sign",
    i8Weights[0] == 127'i8 and i8Weights[1] == -128'i8 and i8Weights[2] == -1'i8)
  let i32WeightLayers = [
    BlaiCpuInstLayer64(
      layerType: ord(blaiConvolutional).int32,
      dspOn: 1,
      c: 1,
      outC: 3,
      size: 1)
  ]
  let i32WeightPlan = blaiCpuWeightStreamPlan(i32WeightLayers, 0)
  var i32Weights: array[3, int32]
  check("NPU CPU i32 weights stored",
    blaiStoreCpuWeightsI32(i32WeightPlan, signedWeightBytes, 1, i32Weights))
  checkEq("NPU CPU i32 weight sign",
    cast[uint32](i32Weights[2]), 0xFFFF_FFFF'u32)
  let fixedBiasPlan = blaiCpuBiasStreamPlan(i32WeightLayers, 0, useTflite = false)
  var fixedBiases: array[3, int32]
  check("NPU CPU fixed biases stored",
    blaiStoreCpuBiases(fixedBiasPlan, signedWeightBytes, 1, fixedBiases))
  checkEq("NPU CPU fixed bias unsigned",
    fixedBiases[1].uint32, 0x80'u32)
  let tfliteBiasLayers = [
    BlaiCpuInstLayer64(
      layerType: ord(blaiConvolutional).int32,
      dspOn: 1,
      c: 1,
      outC: 1,
      size: 1)
  ]
  let tfliteBiasPlan = blaiCpuBiasStreamPlan(tfliteBiasLayers, 0, useTflite = true)
  var tfliteBiases: array[1, int32]
  check("NPU CPU tflite biases stored",
    blaiStoreCpuBiases(tfliteBiasPlan, biasBytes, 0, tfliteBiases))
  checkEq("NPU CPU tflite bias stored",
    cast[uint32](tfliteBiases[0]), 0x5678_1234'u32)
  checkReferenceLayerOracles()
  checkReferenceTfliteNmsisOracles()
  checkReferenceParsedModelOracles()
  checkReferenceParsedSkipOracles()
  checkReferenceParsedEmptyOracles()
  checkReferenceParsedFixedRouteOracles()
  checkReferenceParsedTfliteRouteOracles()
  checkReferenceTfliteTransformOracles()
  checkReferenceTfliteTransposeOracles()
  checkReferenceTfliteTransposeLkOracles()
  checkReferenceTfliteDequantizeOracles()
  checkReferenceParsedShortcutOracles()
  checkReferenceParsedSecondInputFailures()
  checkReferenceParsedTrailingStreamFailures()
  checkReferenceTfliteParsedTrailingStreamFailures()
  checkReferenceParsedLayerFailureModes()
  checkReferenceParsedModeAndUnsupportedFailures()
  checkTensorTransferPlanning()
  var forwardWeightLayer = materializeLayer
  forwardWeightLayer.npuOn = 1
  forwardWeightLayer.dramPatchSize = 64
  var forwardWeightBuf: array[144, uint8]
  var forwardBiasBuf: array[3, int32]
  var forwardTempWeights: array[0, int32]
  let forwardWeights = blaiMaterializeForwardNpuWeights(
    forwardWeightLayer, layerIndex = 0, useTflite = true,
    weightBuf = forwardWeightBuf, biasBuf = forwardBiasBuf,
    weightsIn = sourceWeights, biasesIn = biasSource,
    temporaryWeights = forwardTempWeights, pack = 2)
  check("NPU forward weights runnable", forwardWeights.runnable)
  check("NPU forward weights materialized", forwardWeights.materialized)
  checkEq("NPU forward weights cursor",
    forwardWeights.weights.weightCursor, 144)
  checkEq("NPU forward weights byte", forwardWeightBuf[36].uint32, 18)
  var forwardRouteLayer = forwardWeightLayer
  forwardRouteLayer.layerType = ord(blaiRoute).int32
  let forwardRouteWeights = blaiMaterializeForwardNpuWeights(
    forwardRouteLayer, layerIndex = 0, useTflite = true,
    weightBuf = forwardWeightBuf, biasBuf = forwardBiasBuf,
    weightsIn = sourceWeights, biasesIn = biasSource,
    temporaryWeights = forwardTempWeights, pack = 2)
  check("NPU forward route runnable", forwardRouteWeights.runnable)
  check("NPU forward route skips weights", not forwardRouteWeights.weightLayer)
  check("NPU forward route materialized", forwardRouteWeights.materialized)
  forwardWeightLayer.npuOn = 0
  let blockedForwardWeights = blaiMaterializeForwardNpuWeights(
    forwardWeightLayer, layerIndex = 1, useTflite = true,
    weightBuf = forwardWeightBuf, biasBuf = forwardBiasBuf,
    weightsIn = sourceWeights, biasesIn = biasSource,
    temporaryWeights = forwardTempWeights, pack = 2)
  check("NPU forward weights blocked", not blockedForwardWeights.runnable)
  checkForwardTensorIo()
  let encodePlan = blaiPlanEncode(BlaiDecodedLayer(
    layerType: blaiRoute,
    w: 8,
    h: 8,
    size: 1,
    stride: 1,
    dilation: 1), inputNum = 3, allocationSucceeded = true)
  check("NPU encode plan runnable", encodePlan.runnable)
  checkEq("NPU encode clear bytes", encodePlan.instructionClearBytes,
    BlaiInstructionScratchSize.uint32)
  checkEq("NPU encode route dispatch", encodePlan.dispatch.uint32,
    blaiEncodeRoute.uint32)
  var instScratch: array[BlaiInstructionScratchSize + 1, uint8]
  instScratch[0] = 0xA5'u8
  instScratch[BlaiInstructionScratchSize] = 0x5A'u8
  blaiClearInstructionScratch(instScratch)
  checkEq("NPU instruction scratch clear", instScratch[0].uint32, 0)
  checkEq("NPU instruction scratch bound",
    instScratch[BlaiInstructionScratchSize].uint32, 0x5A'u32)
  var plannedLayer = BlaiCpuInstLayer64(dramPatchNum: 2)
  var plannedCtrl: BlaiPsramCtrl
  plannedCtrl.sramIn[0] = 1
  plannedCtrl.sramOut[0] = 3
  plannedCtrl.sramMidOut = 4
  plannedCtrl.psramPatchSize = 64
  plannedCtrl.sramWeight = 6
  plannedCtrl.sramBias = 7
  blaiApplyMemoryPlan(plannedLayer, plannedCtrl)
  checkEq("NPU memory plan buf size", plannedLayer.bufSize.uint32, 128)
  checkEq("NPU memory plan input slot", plannedLayer.dramIn[0].uint32, 1)
  checkEq("NPU memory plan output slot", plannedLayer.dramOut[0].uint32, 3)
  checkEq("NPU memory plan patch size", plannedLayer.dramPatchSize.uint32, 64)

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
  check("NPU conv facade requires stream",
    legacyConvPlan.requiresInstructionStream and
    not legacyConvPlan.directlyRunnable and
    legacyConvPlan.status == npuConvRequiresInstructionStream)
  check("NPU conv facade address subset", legacyConvPlan.addressConfigurable)
  check("NPU conv facade output plan only",
    legacyConvPlan.outputBufferPlanOnly and
      legacyConvPlan.planOnlyAddressCount == 1'u32)
  checkEq("NPU conv facade register address count",
    legacyConvPlan.registerBackedAddressCount, 3)
  checkEq("NPU conv facade input plan",
    legacyConvPlan.layerConfig.inputBufferAddr, 0x2204_1000'u32)
  checkEq("NPU conv facade weight plan",
    legacyConvPlan.layerConfig.buffers.weightAddr, 0x2204_3000'u32)
  checkEq("NPU conv facade bias plan",
    legacyConvPlan.layerConfig.buffers.biasAddr, 0x2204_4000'u32)
  npuConfigureInstructionStream(
    instAddr = 0x2204_5000'u32,
    weightAddr = 0x2204_6000'u32,
    biasAddr = 0x2204_7000'u32)
  npuConfigureConvLayer(
    inputAddr = 0x2204_1000'u32,
    outputAddr = 0x2204_2000'u32,
    weightAddr = 0x2204_3000'u32,
    biasAddr = 0x2204_4000'u32,
    inputW = 8, inputH = 8, inputC = 1,
    outputC = 1,
    kernelW = 3, kernelH = 3,
    strideW = 1, strideH = 1,
    padW = 1, padH = 1)
  check("NPU conv facade clears stream", not npuInstructionStreamConfigured())
  checkEq("NPU conv facade input register",
    readReg(blaiRegs()[].imageAddr), 0x2204_1000'u32)
  checkEq("NPU conv facade weight register",
    readReg(blaiRegs()[].weightAddr), 0x2204_3000'u32)
  checkEq("NPU conv facade bias register",
    readReg(blaiRegs()[].biasAddr), 0x2204_4000'u32)
  checkEq("NPU configured run unsupported without stream",
    npuRunConfigured(timeout = 1).uint32, npuUnsupported.uint32)
  checkEq("NPU layer run unsupported", npuRunLayer(timeout = 1).uint32,
    npuUnsupported.uint32)
  check("NPU busy false from AXI idle bits", not npuIsBusy())

  if failed == 0:
    discard console.sendLine("[PASS] NPU smoke complete")
  else:
    discard console.sendString("[FAIL] NPU smoke failed count=")
    console.sendHex32(failed.uint32)
    discard console.sendLine("")

  while true:
    discard
