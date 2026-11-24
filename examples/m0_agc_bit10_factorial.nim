## RAM-loaded factorial test of AGC header bit 10 and bits 0–3.

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
  AgcResetBit = 0x1000'u32
  ExternalEvt2Reg = 0x24C0B388'u
  RiuBank00And01 = 0x01010001'u32
  DeadBranch = 0x08100400'u32
  ObserveTicks = 500'u32
  PhaseCount = 32

var console: Uart
var savedAgc: array[512, uint32]
var samples: array[PhaseCount, uint32]
var highCount: array[PhaseCount, uint32]
var firstHighTick: array[PhaseCount, uint32]
var lastHighTick: array[PhaseCount, uint32]
var diagOr: array[PhaseCount, uint32]
var diagAnd: array[PhaseCount, uint32]
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
  discard console.sendLine("AGC BIT10 FACTORIAL START")
  console.flushTx()

  rfc_init(40_000_000'u32)
  discard console.sendLine("AGC BIT10 FACTORIAL RF READY")
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
    let nibble = (phase shr 1).uint32
    let bit10 = (if (phase and 1) != 0: 0x400'u32 else: 0'u32)
    regWrite(0x24C0B390'u, savedPd or AgcResetBit)
    agcmem[0] = 0x20000000'u32 or nibble or bit10
    wifi_fw.phy_init(nil)
    regWrite(ExternalEvt2Reg, 0'u32)
    regWrite(0x24900078'u, RiuBank00And01)
    regWrite(0x24C0B390'u, savedPd or AgcResetBit)
    for delay in 0 ..< 1000:
      discard regRead(0x24C0B390'u)
    regWrite(0x24C0B390'u, savedPd and not AgcResetBit)
    diagAnd[phase] = 0xFFFF'u32
    firstHighTick[phase] = 0xFFFF_FFFF'u32
    let startTick = regRead(0xE000BFF8'u)
    while true:
      let elapsed = regRead(0xE000BFF8'u) - startTick
      if elapsed >= ObserveTicks: break
      let address = (regRead(0x24C0C920'u) shr 23) and 0x1FF'u32
      let diag = (regRead(0x24C0C924'u) shr 16) and 0xFFFF'u32
      inc samples[phase]
      diagOr[phase] = diagOr[phase] or diag
      diagAnd[phase] = diagAnd[phase] and diag
      if (diag and 0x200'u32) != 0'u32:
        inc highCount[phase]
        if firstHighTick[phase] == 0xFFFF_FFFF'u32:
          firstHighTick[phase] = elapsed
        lastHighTick[phase] = elapsed
      if address > 1'u32:
        inc badAddress[phase]

  regWrite(0x24C0B390'u, savedPd or AgcResetBit)
  for index in 0 ..< 512:
    agcmem[index] = savedAgc[index]
  wifi_fw.phy_init(nil)
  regWrite(ExternalEvt2Reg, savedEvt2)
  regWrite(0x24C0B390'u, savedPd and not AgcResetBit)
  regWrite(0x24900078'u, savedRiu)
  discard console.sendLine("AGC BIT10 FACTORIAL IMAGE RESTORED")
  discard console.sendString("AGC BIT10 FACTORIAL EVT2 ")
  printHex(savedEvt2)
  discard console.sendLine("")
  for phase in 0 ..< PhaseCount:
    discard console.sendString("AGC BIT10 FACTORIAL CASE ")
    printHex(phase.uint32)
    discard console.sendString(" ")
    printHex((phase shr 1).uint32 or
      (if (phase and 1) != 0: 0x400'u32 else: 0'u32))
    discard console.sendString(" ")
    printHex(samples[phase])
    discard console.sendString(" ")
    printHex(highCount[phase])
    discard console.sendString(" ")
    printHex(firstHighTick[phase])
    discard console.sendString(" ")
    printHex(lastHighTick[phase])
    discard console.sendString(" ")
    printHex(diagOr[phase])
    discard console.sendString(" ")
    printHex(diagAnd[phase])
    discard console.sendString(" ")
    printHex(badAddress[phase])
    discard console.sendLine("")
  discard console.sendLine("AGC BIT10 FACTORIAL END")
  console.flushTx()
  while true:
    {.emit: "__asm__ volatile(\"wfi\");".}
