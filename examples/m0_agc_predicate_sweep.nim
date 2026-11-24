## RAM-loaded sweep of all 64 AGC branch predicate IDs in a fixed idle state.

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
  PredicatePage {.intdefine.} = 0'u32
  BranchPath {.intdefine.} = 0'u32
  ForceRx {.intdefine.} = 0
  ProbeControl {.intdefine.} = 0x8F'u32
  TimerCount {.intdefine.} = 1000'u32
  PhaseCount = 64
  ObserveTicks = 250'u32
  AgcResetBit = 0x1000'u32
  RiuBank00And01 = 0x01010001'u32
  ExternalEvt2Reg = 0x24C0B388'u
  RfForceReg = 0x2000126C'u
  ProbeHeader = 0x48000000'u32 or (TimerCount shl 15) or ProbeControl
  MarkerHeader = 0x28FA008F'u32 # 500-count marker dwell.

var console: Uart
var savedAgc: array[512, uint32]
var sourceCounts: array[PhaseCount, uint32]
var trueCounts: array[PhaseCount, uint32]
var falseCounts: array[PhaseCount, uint32]
var badCounts: array[PhaseCount, uint32]
var firstMarkerTicks: array[PhaseCount, uint32]
var bank1Or: array[PhaseCount, uint32]
var bank1And: array[PhaseCount, uint32]
var bank1Samples: array[PhaseCount, uint32]

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
  discard console.sendLine("AGC PREDICATE START")
  console.flushTx()

  if PredicatePage > 1'u32 or BranchPath > 1'u32 or
      ProbeControl > 0x7FFF'u32 or
      (ForceRx != 0 and ForceRx != 1):
    discard console.sendLine("AGC PREDICATE INVALID")
    return
  rfc_init(40_000_000'u32)
  discard console.sendLine("AGC PREDICATE RF READY")
  console.flushTx()
  let savedRiu = regRead(0x24900078'u)
  let savedPd = regRead(0x24C0B390'u)
  let savedEvt2 = regRead(ExternalEvt2Reg)
  let savedRfForce = regRead(RfForceReg)
  when ForceRx != 0:
    rfc_rf_fsm_force(3'u32)
  regWrite(0x24900078'u, RiuBank00And01)
  for index in 0 ..< 512:
    savedAgc[index] = agcmem[index]
    agcmem[index] = 0'u32
  agcmem[0] = ProbeHeader
  agcmem[2] = 0x08000005'u32 # Timer expiry fallback to false marker.
  agcmem[3] = MarkerHeader
  agcmem[4] = 0x08000003'u32
  agcmem[5] = MarkerHeader
  agcmem[6] = 0x08000005'u32
  agcmem[511] = savedAgc[511]

  for predicate in 0 ..< PhaseCount:
    agcmem[1] = (predicate.uint32 shl 26) or (BranchPath shl 13) or
      (PredicatePage shl 9) or 3'u32
    wifi_fw.phy_init(nil)
    when ForceRx != 0:
      rfc_rf_fsm_force(3'u32)
    regWrite(ExternalEvt2Reg, 0'u32)
    regWrite(0x24900078'u, RiuBank00And01)
    regWrite(0x24C0B390'u, savedPd or AgcResetBit)
    for delay in 0 ..< 1000:
      discard regRead(0x24C0B390'u)
    regWrite(0x24C0B390'u, savedPd and not AgcResetBit)
    firstMarkerTicks[predicate] = 0xFFFF_FFFF'u32
    bank1And[predicate] = 0xFFFF'u32
    let startTick = regRead(0xE000BFF8'u)
    while true:
      let elapsed = regRead(0xE000BFF8'u) - startTick
      if elapsed >= ObserveTicks: break
      let address = (regRead(0x24C0C920'u) shr 23) and 0x1FF'u32
      let diag = (regRead(0x24C0C924'u) shr 16) and 0xFFFF'u32
      if address <= 2'u32:
        inc sourceCounts[predicate]
        bank1Or[predicate] = bank1Or[predicate] or diag
        bank1And[predicate] = bank1And[predicate] and diag
        inc bank1Samples[predicate]
      elif address <= 4'u32:
        inc trueCounts[predicate]
      elif address <= 6'u32:
        inc falseCounts[predicate]
      else:
        inc badCounts[predicate]
      if address >= 3'u32 and address <= 6'u32 and
          firstMarkerTicks[predicate] == 0xFFFF_FFFF'u32:
        firstMarkerTicks[predicate] = elapsed

  regWrite(0x24C0B390'u, savedPd or AgcResetBit)
  for index in 0 ..< 512:
    agcmem[index] = savedAgc[index]
  wifi_fw.phy_init(nil)
  regWrite(ExternalEvt2Reg, savedEvt2)
  when ForceRx != 0:
    if (savedRfForce and 8'u32) != 0'u32:
      rfc_rf_fsm_force(savedRfForce and 7'u32)
    else:
      rfc_rf_fsm_force(15'u32)
      regModify(RfForceReg, 7'u32, savedRfForce and 7'u32)
  regWrite(0x24C0B390'u, savedPd and not AgcResetBit)
  regWrite(0x24900078'u, savedRiu)
  discard console.sendLine("AGC PREDICATE IMAGE RESTORED")
  discard console.sendString("AGC PREDICATE CONFIG ")
  printHex(PredicatePage)
  discard console.sendString(" ")
  printHex(BranchPath)
  discard console.sendString(" ")
  printHex(TimerCount)
  discard console.sendString(" ")
  printHex(savedEvt2)
  discard console.sendString(" ")
  printHex(ForceRx.uint32)
  discard console.sendString(" ")
  printHex(ProbeControl)
  discard console.sendLine("")
  for predicate in 0 ..< PhaseCount:
    discard console.sendString("AGC PREDICATE CASE ")
    printHex(predicate.uint32)
    discard console.sendString(" ")
    printHex(sourceCounts[predicate])
    discard console.sendString(" ")
    printHex(trueCounts[predicate])
    discard console.sendString(" ")
    printHex(falseCounts[predicate])
    discard console.sendString(" ")
    printHex(badCounts[predicate])
    discard console.sendString(" ")
    printHex(firstMarkerTicks[predicate])
    discard console.sendString(" ")
    printHex(bank1Samples[predicate])
    discard console.sendString(" ")
    printHex(bank1Or[predicate])
    discard console.sendString(" ")
    printHex(bank1And[predicate])
    discard console.sendLine("")
  discard console.sendLine("AGC PREDICATE END")
  console.flushTx()
  while true:
    {.emit: "__asm__ volatile(\"wfi\");".}
