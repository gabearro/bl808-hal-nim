## RAM-loaded, one-bit-at-a-time AGC state-control probe.

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
  DiagnosticBank {.intdefine.} = 2'u32
  BaseControl {.intdefine.} = 0'u32
  AgcResetBit = 0x1000'u32
  ExternalEvt2Reg = 0x24C0B388'u
  DeadBranch = 0x08100400'u32 # C1(02,01,00), false with timer disabled
  ObserveTicks = 250'u32
  PhaseCount = 16

var console: Uart
var savedAgc: array[512, uint32]
var samples: array[PhaseCount, uint32]
var diagOr: array[PhaseCount, uint32]
var diagAnd: array[PhaseCount, uint32]
var diagFirst: array[PhaseCount, uint32]
var diagLast: array[PhaseCount, uint32]
var badAddress: array[PhaseCount, uint32]

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
  discard console.sendLine("AGC LOWER BIT START")
  console.flushTx()

  if DiagnosticBank > 15'u32 or BaseControl > 0x7FFF'u32:
    discard console.sendLine("AGC LOWER BIT INVALID")
    return
  rfc_init(40_000_000'u32)
  discard console.sendLine("AGC LOWER BIT RF READY")
  console.flushTx()
  let savedRiu = regRead(0x24900078'u)
  let savedPd = regRead(0x24C0B390'u)
  let savedEvt2 = regRead(ExternalEvt2Reg)
  for index in 0 ..< 512:
    savedAgc[index] = agcmem[index]
    agcmem[index] = 0'u32
  agcmem[1] = DeadBranch
  agcmem[511] = savedAgc[511]

  for phase in 0 ..< PhaseCount:
    let lowBit = (if phase == 0: 0'u32 else: 1'u32 shl (phase - 1))
    regWrite(0x24C0B390'u, savedPd or AgcResetBit)
    agcmem[0] = 0x20000000'u32 or (BaseControl xor lowBit)
    wifi_fw.phy_init(nil)
    regWrite(ExternalEvt2Reg, 0'u32)
    regWrite(0x24900078'u, 0x00010001'u32 or
      (DiagnosticBank shl 24))
    regWrite(0x24C0B390'u, savedPd or AgcResetBit)
    for delay in 0 ..< 1000:
      discard regRead(0x24C0B390'u)
    regWrite(0x24C0B390'u, savedPd and not AgcResetBit)
    diagAnd[phase] = 0xFFFF'u32
    let startTick = regRead(0xE000BFF8'u)
    while regRead(0xE000BFF8'u) - startTick < ObserveTicks:
      let address = (regRead(0x24C0C920'u) shr 23) and 0x1FF'u32
      let diag = (regRead(0x24C0C924'u) shr 16) and 0xFFFF'u32
      if samples[phase] == 0'u32:
        diagFirst[phase] = diag
      diagLast[phase] = diag
      diagOr[phase] = diagOr[phase] or diag
      diagAnd[phase] = diagAnd[phase] and diag
      inc samples[phase]
      if address > 1'u32:
        inc badAddress[phase]

  regWrite(0x24C0B390'u, savedPd or AgcResetBit)
  for index in 0 ..< 512:
    agcmem[index] = savedAgc[index]
  wifi_fw.phy_init(nil)
  regWrite(ExternalEvt2Reg, savedEvt2)
  regWrite(0x24C0B390'u, savedPd and not AgcResetBit)
  regWrite(0x24900078'u, savedRiu)
  discard console.sendLine("AGC LOWER BIT IMAGE RESTORED")
  discard console.sendString("AGC LOWER BIT CONFIG ")
  printHex(DiagnosticBank)
  discard console.sendString(" ")
  printHex(BaseControl)
  discard console.sendString(" ")
  printHex(savedEvt2)
  discard console.sendLine("")
  for phase in 0 ..< PhaseCount:
    discard console.sendString("AGC LOWER BIT CASE ")
    printHex(phase.uint32)
    discard console.sendString(" ")
    printHex(BaseControl xor
      (if phase == 0: 0'u32 else: 1'u32 shl (phase - 1)))
    discard console.sendString(" ")
    printHex(samples[phase])
    discard console.sendString(" ")
    printHex(diagOr[phase])
    discard console.sendString(" ")
    printHex(diagAnd[phase])
    discard console.sendString(" ")
    printHex(diagFirst[phase])
    discard console.sendString(" ")
    printHex(diagLast[phase])
    discard console.sendString(" ")
    printHex(badAddress[phase])
    discard console.sendLine("")
  discard console.sendLine("AGC LOWER BIT END")
  console.flushTx()
  while true:
    {.emit: "__asm__ volatile(\"wfi\");".}
