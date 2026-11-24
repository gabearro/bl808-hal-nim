## RAM-loaded, reversible AGC constant-input combiner experiment.

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
  AgcBenchTimer {.intdefine.} = 50'u32
  CaseCount = 68
  Terminal = CaseCount * 7
  AgcResetBit = 0x1000'u32
  RiuBank00Both = 0x00010001'u32
  ProbeHeader = 0x4800008F'u32 or (AgcBenchTimer shl 15)
  MarkerHeader = 0x2800008F'u32 or (AgcBenchTimer shl 15)

var console: Uart
var savedAgc: array[512, uint32]
var probeCounts: array[CaseCount, uint32]
var trueCounts: array[CaseCount, uint32]
var falseCounts: array[CaseCount, uint32]

proc printHex(value: uint32) =
  console.sendHex32(value)

proc buildBench() =
  for index in 0 ..< 512:
    savedAgc[index] = agcmem[index]
    agcmem[index] = 0'u32
  for caseIndex in 0 ..< CaseCount:
    let start = caseIndex * 7
    var a, b, c, combiner: uint32
    if caseIndex == 0 or caseIndex == 66:
      b = 1'u32
    elif caseIndex == 1 or caseIndex == 67:
      discard
    else:
      let matrixIndex = caseIndex - 2
      combiner = (matrixIndex div 8).uint32
      let row = (matrixIndex mod 8).uint32
      a = (row shr 2) and 1'u32
      b = (row shr 1) and 1'u32
      c = row and 1'u32
    let testWord = (a shl 26) or (b shl 20) or (c shl 14) or
      (combiner shl 10)
    agcmem[start] = ProbeHeader
    agcmem[start + 1] = testWord or (start + 3).uint32
    agcmem[start + 2] = 0x08000000'u32 or (start + 5).uint32
    agcmem[start + 3] = MarkerHeader
    agcmem[start + 4] = 0x08000000'u32 or (start + 7).uint32
    agcmem[start + 5] = MarkerHeader
    agcmem[start + 6] = 0x08000000'u32 or (start + 7).uint32
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
  discard console.sendLine("AGC COMBINER START")
  discard console.sendString("AGC COMBINER TIMER ")
  printHex(AgcBenchTimer)
  discard console.sendLine("")
  console.flushTx()

  rfc_init(40_000_000'u32)
  discard console.sendLine("AGC COMBINER RF READY")
  console.flushTx()
  let savedRiu = regRead(0x24900078'u)
  let savedPd = regRead(0x24C0B390'u)
  regWrite(0x24900078'u, RiuBank00Both)
  buildBench()
  wifi_fw.phy_init(nil)
  discard console.sendLine("AGC COMBINER IMAGE LOADED")
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
      let caseIndex = (address div 7'u32).int
      case address mod 7'u32
      of 0'u32, 1'u32, 2'u32: inc probeCounts[caseIndex]
      of 3'u32, 4'u32: inc trueCounts[caseIndex]
      of 5'u32, 6'u32: inc falseCounts[caseIndex]
      else: discard

  regWrite(0x24C0B390'u, savedPd or AgcResetBit)
  for index in 0 ..< 512:
    agcmem[index] = savedAgc[index]
  wifi_fw.phy_init(nil)
  regWrite(0x24C0B390'u, savedPd and not AgcResetBit)
  regWrite(0x24900078'u, savedRiu)
  discard console.sendLine("AGC COMBINER IMAGE RESTORED")
  discard console.sendString("AGC COMBINER TRACE ")
  printHex(firstAddress)
  discard console.sendString(" ")
  printHex(lastAddress)
  discard console.sendString(" ")
  printHex(terminalCount)
  discard console.sendLine("")
  for caseIndex in 0 ..< CaseCount:
    discard console.sendString("AGC COMBINER CASE ")
    printHex(caseIndex.uint32)
    discard console.sendString(" ")
    printHex(probeCounts[caseIndex])
    discard console.sendString(" ")
    printHex(trueCounts[caseIndex])
    discard console.sendString(" ")
    printHex(falseCounts[caseIndex])
    discard console.sendLine("")
  discard console.sendLine("AGC COMBINER END")
  console.flushTx()
  while true:
    {.emit: "__asm__ volatile(\"wfi\");".}
