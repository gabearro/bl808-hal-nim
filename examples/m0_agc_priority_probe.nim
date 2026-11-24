## RAM-loaded, reversible AGC branch-priority experiment.

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
  AgcPrioritySlots {.intdefine.} = 2
  CaseCount = (if AgcPrioritySlots == 7: 19 else: 8)
  Stride = (if AgcPrioritySlots == 7: 12 else: 7)
  Terminal = CaseCount * Stride
  AgcResetBit = 0x1000'u32
  RiuBank00Both = 0x00010001'u32
  ProbeHeader = (if AgcPrioritySlots == 7: 0xE000008F'u32 else: 0x4000008F'u32)
  MarkerHeader = 0x28FA008F'u32 # count 500
  C0True = 0x04000000'u32       # C0(01,00,00)
  C0False = 0x00000000'u32      # C0(00,00,00)
  C1True = 0x04104400'u32       # C1(01,01,01)

var console: Uart
var savedAgc: array[512, uint32]
var probeCounts: array[CaseCount, uint32]
var markerACounts: array[CaseCount, uint32]
var markerBCounts: array[CaseCount, uint32]

proc printHex(value: uint32) =
  console.sendHex32(value)

proc buildBench() =
  for index in 0 ..< 512:
    savedAgc[index] = agcmem[index]
    agcmem[index] = 0'u32
  for caseIndex in 0 ..< CaseCount:
    let start = caseIndex * Stride
    agcmem[start] = ProbeHeader
    when AgcPrioritySlots == 7:
      let markerA = (start + 8).uint32
      let markerB = (start + 10).uint32
      for slot in 0 ..< 7:
        agcmem[start + 1 + slot] = C0False or markerB
      if caseIndex < 7:
        agcmem[start + 1 + caseIndex] = C0True or markerA
      elif caseIndex < 13:
        let slot = caseIndex - 7
        agcmem[start + 1 + slot] = C0True or markerA
        agcmem[start + 2 + slot] = C0True or markerB
      else:
        let slot = caseIndex - 13
        agcmem[start + 1 + slot] = C0True or markerB
        agcmem[start + 2 + slot] = C0True or markerA
      agcmem[start + 8] = MarkerHeader
      agcmem[start + 9] = 0x08000000'u32 or (start + Stride).uint32
      agcmem[start + 10] = MarkerHeader
      agcmem[start + 11] = 0x08000000'u32 or (start + Stride).uint32
    else:
      let markerA = (start + 3).uint32
      let markerB = (start + 5).uint32
      var firstCond = C0True
      var secondCond = C0True
      var firstTarget = markerA
      var secondTarget = markerB
      case caseIndex
      of 0: secondCond = C0False
      of 1: firstCond = C0False
      of 2: discard
      of 3:
        firstTarget = markerB
        secondTarget = markerA
      of 4: firstCond = C1True
      of 5: secondCond = C1True
      of 6:
        firstCond = C1True
        firstTarget = markerB
        secondTarget = markerA
      of 7:
        secondCond = C1True
        firstTarget = markerB
        secondTarget = markerA
      else: discard
      agcmem[start + 1] = firstCond or firstTarget
      agcmem[start + 2] = secondCond or secondTarget
      agcmem[start + 3] = MarkerHeader
      agcmem[start + 4] = 0x08000000'u32 or (start + Stride).uint32
      agcmem[start + 5] = MarkerHeader
      agcmem[start + 6] = 0x08000000'u32 or (start + Stride).uint32
  agcmem[Terminal] = MarkerHeader
  agcmem[Terminal + 1] = 0x08000000'u32 or Terminal.uint32
  agcmem[511] = savedAgc[511]

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
  discard console.sendLine("AGC PRIORITY START")
  discard console.sendString("AGC PRIORITY SLOTS ")
  printHex(AgcPrioritySlots.uint32)
  discard console.sendLine("")
  console.flushTx()

  rfc_init(40_000_000'u32)
  discard console.sendLine("AGC PRIORITY RF READY")
  console.flushTx()
  let savedRiu = regRead(0x24900078'u)
  let savedPd = regRead(0x24C0B390'u)
  regWrite(0x24900078'u, RiuBank00Both)
  buildBench()
  wifi_fw.phy_init(nil)
  discard console.sendLine("AGC PRIORITY IMAGE LOADED")
  console.flushTx()

  regWrite(0x24C0B390'u, savedPd or AgcResetBit)
  for delay in 0 ..< 1000:
    discard regRead(0x24C0B390'u)
  regWrite(0x24C0B390'u, savedPd and not AgcResetBit)
  var terminalCount = 0'u32
  var firstAddress = 0xFFFF'u32
  var lastAddress = 0'u32
  for sample in 0 ..< 5_000_000:
    let address = (regRead(0x24C0C920'u) shr 23) and 0x1FF'u32
    if firstAddress == 0xFFFF'u32:
      firstAddress = address
    lastAddress = address
    if address >= Terminal.uint32:
      inc terminalCount
    else:
      let caseIndex = (address div Stride.uint32).int
      let offset = address mod Stride.uint32
      when AgcPrioritySlots == 7:
        if offset <= 7'u32: inc probeCounts[caseIndex]
        elif offset <= 9'u32: inc markerACounts[caseIndex]
        else: inc markerBCounts[caseIndex]
      else:
        if offset <= 2'u32: inc probeCounts[caseIndex]
        elif offset <= 4'u32: inc markerACounts[caseIndex]
        else: inc markerBCounts[caseIndex]

  regWrite(0x24C0B390'u, savedPd or AgcResetBit)
  for index in 0 ..< 512:
    agcmem[index] = savedAgc[index]
  wifi_fw.phy_init(nil)
  regWrite(0x24C0B390'u, savedPd and not AgcResetBit)
  regWrite(0x24900078'u, savedRiu)
  discard console.sendLine("AGC PRIORITY IMAGE RESTORED")
  discard console.sendString("AGC PRIORITY TRACE ")
  printHex(firstAddress)
  discard console.sendString(" ")
  printHex(lastAddress)
  discard console.sendString(" ")
  printHex(terminalCount)
  discard console.sendLine("")
  for caseIndex in 0 ..< CaseCount:
    discard console.sendString("AGC PRIORITY CASE ")
    printHex(caseIndex.uint32)
    discard console.sendString(" ")
    printHex(probeCounts[caseIndex])
    discard console.sendString(" ")
    printHex(markerACounts[caseIndex])
    discard console.sendString(" ")
    printHex(markerBCounts[caseIndex])
    discard console.sendLine("")
  discard console.sendLine("AGC PRIORITY END")
  console.flushTx()
  while true:
    {.emit: "__asm__ volatile(\"wfi\");".}
