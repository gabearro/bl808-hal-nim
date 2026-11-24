## RAM-loaded selector-0x29 payload sweep against the RIU gain diagnostic.

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
  DiagnosticBank {.intdefine.} = 3'u32
  DisableEvt2 {.intdefine.} = 1
  AgcResetBit = 0x1000'u32
  ExternalEvt2Reg = 0x24C0B388'u
  RiuBank00AndOther = 0x00010001'u32 or (DiagnosticBank shl 24)
  DeadBranch = 0x08100400'u32 # C1(02,01,00), always false.
  PhaseCount = 13
  SampleCount = 5000
  ExtensionWords: array[PhaseCount, uint32] = [
    0'u32, 0x29000000'u32, 0x29000300'u32, 0x29000100'u32,
    0x29000301'u32, 0x29000101'u32, 0x29000001'u32,
    0x29030002'u32, 0x29000302'u32, 0x29010002'u32,
    0x29000102'u32, 0x29000002'u32, 0'u32]

var console: Uart
var savedAgc: array[512, uint32]
var diagMin: array[PhaseCount, uint32]
var diagMax: array[PhaseCount, uint32]
var diagOr: array[PhaseCount, uint32]
var diagAnd: array[PhaseCount, uint32]
var firstDiag: array[PhaseCount, uint32]
var lastDiag: array[PhaseCount, uint32]
var badAddresses: array[PhaseCount, uint32]
var addressCounts: array[PhaseCount, array[512, uint16]]
var firstBadAddress: array[PhaseCount, uint32]
var lastBadAddress: array[PhaseCount, uint32]
var evt2Readback: array[PhaseCount, uint32]

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
  discard console.sendLine("AGC EXT29 START")
  discard console.sendString("AGC EXT29 DIAG BANK ")
  printHex(DiagnosticBank)
  discard console.sendLine("")
  discard console.sendString("AGC EXT29 EVT2 CLEARED ")
  printHex(DisableEvt2.uint32)
  discard console.sendLine("")
  console.flushTx()

  rfc_init(40_000_000'u32)
  discard console.sendLine("AGC EXT29 RF READY")
  console.flushTx()
  let savedRiu = regRead(0x24900078'u)
  let savedPd = regRead(0x24C0B390'u)
  let savedEvt2 = regRead(ExternalEvt2Reg)
  discard console.sendString("AGC EXT29 EVT2 ORIGINAL ")
  printHex(savedEvt2)
  discard console.sendLine("")
  for index in 0 ..< 512:
    savedAgc[index] = agcmem[index]
    agcmem[index] = 0'u32
  agcmem[511] = savedAgc[511]

  for phase in 0 ..< PhaseCount:
    let word = ExtensionWords[phase]
    if word == 0'u32:
      agcmem[0] = 0x2000030F'u32 # One branch, no extension.
      agcmem[1] = DeadBranch
      agcmem[2] = 0'u32
    else:
      agcmem[0] = 0x3000030F'u32 # One extension, one branch.
      agcmem[1] = word
      agcmem[2] = DeadBranch
    wifi_fw.phy_init(nil)
    when DisableEvt2 != 0:
      regWrite(ExternalEvt2Reg, 0'u32)
    evt2Readback[phase] = regRead(ExternalEvt2Reg)
    regWrite(0x24900078'u, RiuBank00AndOther)
    regWrite(0x24C0B390'u, savedPd or AgcResetBit)
    for delay in 0 ..< 1000:
      discard regRead(0x24C0B390'u)
    regWrite(0x24C0B390'u, savedPd and not AgcResetBit)
    diagMin[phase] = 0xFFFF'u32
    diagAnd[phase] = 0xFFFF'u32
    for sample in 0 ..< SampleCount:
      let address = (regRead(0x24C0C920'u) shr 23) and 0x1FF'u32
      let diag = (regRead(0x24C0C924'u) shr 16) and 0xFFFF'u32
      inc addressCounts[phase][address]
      if sample == 0:
        firstDiag[phase] = diag
      lastDiag[phase] = diag
      if diag < diagMin[phase]: diagMin[phase] = diag
      if diag > diagMax[phase]: diagMax[phase] = diag
      diagOr[phase] = diagOr[phase] or diag
      diagAnd[phase] = diagAnd[phase] and diag
      if address > (if word == 0'u32: 1'u32 else: 2'u32):
        if badAddresses[phase] == 0'u32:
          firstBadAddress[phase] = address
        lastBadAddress[phase] = address
        inc badAddresses[phase]

  regWrite(0x24C0B390'u, savedPd or AgcResetBit)
  for index in 0 ..< 512:
    agcmem[index] = savedAgc[index]
  wifi_fw.phy_init(nil)
  regWrite(ExternalEvt2Reg, savedEvt2)
  regWrite(0x24C0B390'u, savedPd and not AgcResetBit)
  regWrite(0x24900078'u, savedRiu)
  discard console.sendLine("AGC EXT29 IMAGE RESTORED")
  for phase in 0 ..< PhaseCount:
    discard console.sendString("AGC EXT29 CASE ")
    printHex(phase.uint32)
    discard console.sendString(" ")
    printHex(ExtensionWords[phase])
    discard console.sendString(" ")
    printHex(firstDiag[phase])
    discard console.sendString(" ")
    printHex(lastDiag[phase])
    discard console.sendString(" ")
    printHex(diagMin[phase])
    discard console.sendString(" ")
    printHex(diagMax[phase])
    discard console.sendString(" ")
    printHex(diagOr[phase])
    discard console.sendString(" ")
    printHex(diagAnd[phase])
    discard console.sendString(" ")
    printHex(badAddresses[phase])
    discard console.sendString(" ")
    printHex(firstBadAddress[phase])
    discard console.sendString(" ")
    printHex(lastBadAddress[phase])
    discard console.sendString(" ")
    printHex(evt2Readback[phase])
    discard console.sendLine("")
    for rank in 0 ..< 3:
      var topAddress = -1
      var topCount = 0'u16
      for address in 0 ..< 512:
        if addressCounts[phase][address] > topCount:
          topCount = addressCounts[phase][address]
          topAddress = address
      if topAddress >= 0:
        discard console.sendString("AGC EXT29 TOP ")
        printHex(phase.uint32)
        discard console.sendString(" ")
        printHex(topAddress.uint32)
        discard console.sendString(" ")
        printHex(topCount.uint32)
        discard console.sendLine("")
        addressCounts[phase][topAddress] = 0'u16
  discard console.sendLine("AGC EXT29 END")
  console.flushTx()
  while true:
    {.emit: "__asm__ volatile(\"wfi\");".}
