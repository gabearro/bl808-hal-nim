## Focused BL808 BLAI/NPU route-family reference smoke test.
##
## This keeps recovered TFLite route sidecar dispatch out of the larger NPU
## smoke image so route-family coverage stays reliable on the M0 UART log.

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

proc checkReferenceTfliteRouteOracles() =
  var routeBiases: array[0, int32]

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
    quantizedActivationMin: 0,
    quantizedActivationMax: 255)
  let routeStorage = BlaiCpuExtraInputStorage(
    active: true,
    inLayerMemN: [2'i32, 0, 0, 0, 0, 0],
    tfInputOffsetExtra: [3'i32, 0, 0, 0, 0, 0],
    tfInputShiftExtra: [-20'i32, 0, 0, 0, 0, 0],
    tfInputMultiplierExtra: [0x4000_0000'i32, 0, 0, 0, 0, 0])
  var routeLayers = [BlaiCpuParsedLayerState(
    active: true,
    index: 0,
    layer: routeLayer,
    extraInputs: routeStorage)]
  var routeOut: array[3, uint8]
  let parsedRoute = blaiReferenceTfliteParsedLayer2d(
    routeLayers,
    layerIndex = 0,
    useTflite = true,
    input1 = [9'u8, 0, 0, 0, 12, 0, 0, 0, 15],
    input2 = [],
    cpuWeightBytes = [],
    cpuBiasBytes = [],
    weightCursor = blaiCpuStreamCursor(),
    biasCursor = blaiCpuStreamCursor(),
    decodedBiases = routeBiases,
    output = routeOut)
  check("NPU route TFLite parsed route supported", parsedRoute.supported)
  check("NPU route TFLite parsed route fits", parsedRoute.fits)
  check("NPU route TFLite parsed route streams",
    parsedRoute.streamsFit and parsedRoute.streamLayerMatches)
  checkEq("NPU route TFLite parsed route channels",
    parsedRoute.reference.outputC, 3'u32)
  checkOutputCompare("NPU route TFLite parsed route output",
    blaiCompareUint8Outputs([5'u8, 6, 6], routeOut))

  let routeMaxLayer = BlaiCpuInstLayer64(
    layerType: ord(blaiRouteMax).int32,
    w: 2, h: 2, outW: 1, outH: 1,
    c: 1,
    cn: [1'i32, 0, 0, 0, 0, 0, 0],
    outC: 2,
    inputNum: 2,
    inLayer1Mem: 0,
    inLayer2Mem: 1,
    dramPatchSize: 4,
    tfInput1Offset: 0,
    tfInput2Offset: 0,
    tfOutputOffset: 0,
    tfInput1Multiplier: 0x4000_0000'i32,
    tfInput2Multiplier: 0x4000_0000'i32,
    tfOutputMultiplier: 0x4000_0000'i32,
    tfInput1Shift: -20,
    tfInput2Shift: -20,
    tfOutputShift: 0,
    quantizedActivationMin: 0,
    quantizedActivationMax: 255,
    stride: 1)
  var routeMaxLayers = [BlaiCpuParsedLayerState(
    active: true,
    index: 0,
    layer: routeMaxLayer)]
  var routeMaxOut: array[2, uint8]
  let parsedRouteMax = blaiReferenceTfliteParsedLayer2d(
    routeMaxLayers,
    layerIndex = 0,
    useTflite = true,
    input1 = [1'u8, 5, 2, 6, 3, 7, 4, 8],
    input2 = [],
    cpuWeightBytes = [],
    cpuBiasBytes = [],
    weightCursor = blaiCpuStreamCursor(),
    biasCursor = blaiCpuStreamCursor(),
    decodedBiases = routeBiases,
    output = routeMaxOut)
  check("NPU route TFLite parsed route max supported", parsedRouteMax.supported)
  check("NPU route TFLite parsed route max fits", parsedRouteMax.fits)
  check("NPU route TFLite parsed route max streams",
    parsedRouteMax.streamsFit and parsedRouteMax.streamLayerMatches)
  checkEq("NPU route TFLite parsed route max channels",
    parsedRouteMax.reference.outputC, 2'u32)
  checkOutputCompare("NPU route TFLite parsed route max output",
    blaiCompareUint8Outputs([2'u8, 2], routeMaxOut))

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
  check("NPU route TFLite parsed route W supported", parsedRouteW.supported)
  check("NPU route TFLite parsed route W fits", parsedRouteW.fits)
  check("NPU route TFLite parsed route W streams",
    parsedRouteW.streamsFit and parsedRouteW.streamLayerMatches)
  checkEq("NPU route TFLite parsed route W channels",
    parsedRouteW.reference.outputC, 1'u32)
  checkOutputCompare("NPU route TFLite parsed route W output",
    blaiCompareUint8Outputs([11'u8, 21, 22], routeWOut))

proc checkRouteInstructionEmission() =
  var routeLayer = BlaiCpuInstLayer64(
    layerType: ord(blaiRoute).int32,
    w: 8,
    h: 7,
    c: 3,
    cn: [5'i32, 7, 0, 0, 0, 0, 0],
    outW: 8,
    outH: 7,
    outC: 15,
    inputNum: 3,
    groups: 1,
    stride: 1,
    dilation: 1,
    size: 1)
  var memory = BlaiFetchMemoryPlan(
    kind: blaiFetchRoute,
    fits: true,
    inputCount: 3,
    patchSize: 64,
    inputPatchCount: [3'u32, 5, 7, 0, 0, 0, 0, 0],
    inputSlots: [0'u32, 2, 4, 0, 0, 0, 0, 0],
    outputSlot: 5,
    dramPatchCount: 11)
  let slots = BlaiRouteSramSlotPlan(
    fits: true,
    memory: memory,
    outputSlotCount: 2,
    outputSlots: [5'u32, 9, 0, 0, 0, 0, 0, 0],
    finalPatchCursor: 11)
  var stream: array[2, BlaiInstruction]
  let emitted = blaiEmitRouteLayerInstructions(
    routeLayer, slots, stream, useTflite = false)
  check("NPU route descriptor emit fits", emitted.fits)
  checkEq("NPU route descriptor emit count", emitted.emitted, 2)
  checkEq("NPU route descriptor layer count", routeLayer.instCnt.uint32, 2)
  let first = decodeBlaiLayer(stream[0])
  let second = decodeBlaiLayer(stream[1])
  checkEq("NPU route descriptor first c", first.c, 3)
  checkEq("NPU route descriptor first c2", first.cn0, 5)
  checkEq("NPU route descriptor first output", first.outLayerMem, 5)
  checkEq("NPU route descriptor second c", second.c, 8)
  checkEq("NPU route descriptor second c2", second.cn0, 7)
  checkEq("NPU route descriptor second input", second.inLayer1Mem, 5)
  checkEq("NPU route descriptor second output", second.outLayerMem, 9)

  var shortLayer = routeLayer
  shortLayer.instCnt = 0
  var shortStream: array[1, BlaiInstruction]
  shortStream[0][0] = 0x77'u8
  let blocked = blaiEmitRouteLayerInstructions(
    shortLayer, slots, shortStream, useTflite = false)
  check("NPU route descriptor short blocked", not blocked.fits)
  checkEq("NPU route descriptor short count", blocked.emitted, 2)
  checkEq("NPU route descriptor short layer count",
    shortLayer.instCnt.uint32, 0)
  checkEq("NPU route descriptor short preserved",
    shortStream[0][0].uint32, 0x77)

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
  discard console.sendLine("=== BL808 NPU Route Smoke Test ===")

  checkReferenceTfliteRouteOracles()
  checkRouteInstructionEmission()

  if failed == 0:
    discard console.sendLine("[PASS] NPU route smoke complete")
  else:
    discard console.sendString("[FAIL] NPU route smoke failed count=")
    console.sendHex32(failed.uint32)
    discard console.sendLine("")

  while true:
    discard
