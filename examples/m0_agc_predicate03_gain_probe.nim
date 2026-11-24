## RAM-loaded test of a gain-limit byte against one AGC predicate.

import bl808/startup, bl808/core
import bl808/glb, bl808/gpio, bl808/uart
import bl808/mmio
import bl808/panicoverride
import bl808/kernel/alloc
import bl808/wifi
import bl808/wifi_fw

const
  ConsoleBaud {.intdefine.} = 230_400'u32
  ConsoleClkHz {.intdefine.} = 40_000_000'u32
  TargetPredicate {.intdefine.} = 3'u32
  GainByteShift {.intdefine.} = 0'u32
  DefaultThreshold = (if GainByteShift == 16'u32: 62'u32 else: 4'u32)
  AgcResetBit = 0x1000'u32
  RiuBank00And01 = 0x01010001'u32
  RiuBank00And03 = 0x03010001'u32
  ExternalEvt2Reg = 0x24C0B388'u
  Rc2GainLimits = 0x24C0C85C'u
  TimerCount = 1000'u32
  ObserveTicks = 250'u32
  ProbeHeader = 0x4800008F'u32 or (TimerCount shl 15)
  MarkerHeader = 0x28FA008F'u32
  CaseCount = 9
  Thresholds: array[CaseCount, uint32] = [
    DefaultThreshold, DefaultThreshold, DefaultThreshold, 0'u32, 32, 63,
    255, DefaultThreshold, DefaultThreshold]
  Predicates: array[CaseCount, uint32] = [
    0'u32, 1, TargetPredicate, TargetPredicate, TargetPredicate,
    TargetPredicate, TargetPredicate, TargetPredicate, 0]

var console: Uart
var savedAgc: array[512, uint32]
var sourceCounts: array[CaseCount, uint32]
var trueCounts: array[CaseCount, uint32]
var falseCounts: array[CaseCount, uint32]
var badCounts: array[CaseCount, uint32]
var firstMarkerTicks: array[CaseCount, uint32]
var diagOr: array[CaseCount, uint32]
var diagAnd: array[CaseCount, uint32]
var limitReadback: array[CaseCount, uint32]
var gainReadback: array[CaseCount, uint32]

proc printHex(value: uint32) =
  console.sendHex32(value)

proc main() {.exportc, cdecl.} =
  systemInit()
  heapInit()
  enablePeriphClock(periphUart0)
  setMcuXclkSource(mcuXclkXtal)
  setUartClock(true, uartClkXclk, 0)
  gpioSetupUart(14, 15)
  console = initUart(uart0, UartConfig(
    baudRate: ConsoleBaud, dataBits: data8, stopBits: stop1,
    parity: parityNone), ConsoleClkHz)
  discard console.sendLine("AGC P03 GAIN START")
  discard console.sendString("AGC P03 GAIN CONFIG ")
  printHex(TargetPredicate)
  discard console.sendString(" ")
  printHex(GainByteShift)
  discard console.sendLine("")
  console.flushTx()

  rfc_init(40_000_000'u32)
  discard console.sendLine("AGC P03 GAIN RF READY")
  console.flushTx()
  let savedRiu = regRead(0x24900078'u)
  let savedPd = regRead(0x24C0B390'u)
  let savedEvt2 = regRead(ExternalEvt2Reg)
  let savedLimits = regRead(Rc2GainLimits)
  for index in 0 ..< 512:
    savedAgc[index] = agcmem[index]
    agcmem[index] = 0'u32
  agcmem[0] = ProbeHeader
  agcmem[2] = 0x08000005'u32
  agcmem[3] = MarkerHeader
  agcmem[4] = 0x08000003'u32
  agcmem[5] = MarkerHeader
  agcmem[6] = 0x08000005'u32
  agcmem[511] = savedAgc[511]

  for caseIndex in 0 ..< CaseCount:
    let predicate = Predicates[caseIndex]
    agcmem[1] = (predicate shl 26) or 3'u32
    wifi_fw.phy_init(nil)
    regWrite(ExternalEvt2Reg, 0'u32)
    let fieldMask = 0xFF'u32 shl GainByteShift
    regWrite(Rc2GainLimits, (regRead(Rc2GainLimits) and not fieldMask) or
      (Thresholds[caseIndex] shl GainByteShift))
    limitReadback[caseIndex] = regRead(Rc2GainLimits)
    regWrite(0x24900078'u, RiuBank00And01)
    regWrite(0x24C0B390'u, savedPd or AgcResetBit)
    for delay in 0 ..< 1000:
      discard regRead(0x24C0B390'u)
    regWrite(0x24C0B390'u, savedPd and not AgcResetBit)
    diagAnd[caseIndex] = 0xFFFF'u32
    firstMarkerTicks[caseIndex] = 0xFFFF_FFFF'u32
    let startTick = regRead(0xE000BFF8'u)
    while true:
      let elapsed = regRead(0xE000BFF8'u) - startTick
      if elapsed >= ObserveTicks: break
      let address = (regRead(0x24C0C920'u) shr 23) and 0x1FF'u32
      let diag = (regRead(0x24C0C924'u) shr 16) and 0xFFFF'u32
      diagOr[caseIndex] = diagOr[caseIndex] or diag
      diagAnd[caseIndex] = diagAnd[caseIndex] and diag
      if address <= 2'u32:
        inc sourceCounts[caseIndex]
      elif address <= 4'u32:
        inc trueCounts[caseIndex]
      elif address <= 6'u32:
        inc falseCounts[caseIndex]
      else:
        inc badCounts[caseIndex]
      if address >= 3'u32 and address <= 6'u32 and
          firstMarkerTicks[caseIndex] == 0xFFFF_FFFF'u32:
        firstMarkerTicks[caseIndex] = elapsed
    regWrite(0x24900078'u, RiuBank00And03)
    gainReadback[caseIndex] = (regRead(0x24C0C924'u) shr 16) and 0xFFFF'u32

  regWrite(0x24C0B390'u, savedPd or AgcResetBit)
  for index in 0 ..< 512:
    agcmem[index] = savedAgc[index]
  wifi_fw.phy_init(nil)
  regWrite(Rc2GainLimits, savedLimits)
  regWrite(ExternalEvt2Reg, savedEvt2)
  regWrite(0x24C0B390'u, savedPd and not AgcResetBit)
  regWrite(0x24900078'u, savedRiu)
  discard console.sendLine("AGC P03 GAIN IMAGE RESTORED")
  discard console.sendString("AGC P03 GAIN SAVED ")
  printHex(savedLimits)
  discard console.sendString(" ")
  printHex(savedEvt2)
  discard console.sendLine("")
  for caseIndex in 0 ..< CaseCount:
    discard console.sendString("AGC P03 GAIN CASE ")
    printHex(caseIndex.uint32)
    discard console.sendString(" ")
    printHex(Predicates[caseIndex])
    discard console.sendString(" ")
    printHex(Thresholds[caseIndex])
    discard console.sendString(" ")
    printHex(limitReadback[caseIndex])
    discard console.sendString(" ")
    printHex(gainReadback[caseIndex])
    discard console.sendString(" ")
    printHex(sourceCounts[caseIndex])
    discard console.sendString(" ")
    printHex(trueCounts[caseIndex])
    discard console.sendString(" ")
    printHex(falseCounts[caseIndex])
    discard console.sendString(" ")
    printHex(badCounts[caseIndex])
    discard console.sendString(" ")
    printHex(firstMarkerTicks[caseIndex])
    discard console.sendString(" ")
    printHex(diagOr[caseIndex])
    discard console.sendString(" ")
    printHex(diagAnd[caseIndex])
    discard console.sendLine("")
  discard console.sendLine("AGC P03 GAIN END")
  console.flushTx()
  while true:
    {.emit: "__asm__ volatile(\"wfi\");".}
