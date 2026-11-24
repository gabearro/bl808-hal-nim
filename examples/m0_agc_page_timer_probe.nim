## RAM-loaded AGC path/page-bit test with timer predicate 02.

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
  TimerCount {.intdefine.} = 1000'u32
  AgcResetBit = 0x1000'u32
  RiuBank00Both = 0x00010001'u32
  BinTicks = 50'u32
  BinCount = 6
  PhaseCount = 8

var console: Uart
var savedAgc: array[512, uint32]
var sourceCounts: array[PhaseCount, array[BinCount, uint32]]
var markerCounts: array[PhaseCount, array[BinCount, uint32]]
var badCounts: array[PhaseCount, array[BinCount, uint32]]

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
  discard console.sendLine("AGC PAGE TIMER START")
  console.flushTx()

  rfc_init(40_000_000'u32)
  discard console.sendLine("AGC PAGE TIMER RF READY")
  console.flushTx()
  let savedRiu = regRead(0x24900078'u)
  let savedPd = regRead(0x24C0B390'u)
  regWrite(0x24900078'u, RiuBank00Both)
  for index in 0 ..< 512:
    savedAgc[index] = agcmem[index]
    agcmem[index] = 0'u32
  agcmem[2] = 0x28FA008F'u32 # Marker with 500-count timer.
  agcmem[3] = 0x08000002'u32 # Remain in marker state.
  agcmem[511] = savedAgc[511]

  for phase in 0 ..< PhaseCount:
    let timerEnabled = (phase and 4) != 0
    let pathBit = ((phase shr 1) and 1).uint32
    let pageBit = (phase and 1).uint32
    agcmem[0] = (if timerEnabled: 0x2800008F'u32 else: 0x2000008F'u32) or
      (TimerCount shl 15)
    agcmem[1] = 0x08000002'u32 or (pathBit shl 13) or (pageBit shl 9)
    wifi_fw.phy_init(nil)
    regWrite(0x24C0B390'u, savedPd or AgcResetBit)
    for delay in 0 ..< 1000:
      discard regRead(0x24C0B390'u)
    regWrite(0x24C0B390'u, savedPd and not AgcResetBit)
    let startTick = regRead(0xE000BFF8'u)
    while true:
      let elapsed = regRead(0xE000BFF8'u) - startTick
      if elapsed >= BinTicks * BinCount.uint32:
        break
      let bin = (elapsed div BinTicks).int
      let address = (regRead(0x24C0C920'u) shr 23) and 0x1FF'u32
      if address <= 1'u32:
        inc sourceCounts[phase][bin]
      elif address <= 3'u32:
        inc markerCounts[phase][bin]
      else:
        inc badCounts[phase][bin]

  regWrite(0x24C0B390'u, savedPd or AgcResetBit)
  for index in 0 ..< 512:
    agcmem[index] = savedAgc[index]
  wifi_fw.phy_init(nil)
  regWrite(0x24C0B390'u, savedPd and not AgcResetBit)
  regWrite(0x24900078'u, savedRiu)
  discard console.sendLine("AGC PAGE TIMER IMAGE RESTORED")
  discard console.sendString("AGC PAGE TIMER COUNT ")
  printHex(TimerCount)
  discard console.sendLine("")
  for phase in 0 ..< PhaseCount:
    for bin in 0 ..< BinCount:
      discard console.sendString("AGC PAGE TIMER CASE ")
      printHex(phase.uint32)
      discard console.sendString(" ")
      printHex(bin.uint32)
      discard console.sendString(" ")
      printHex(sourceCounts[phase][bin])
      discard console.sendString(" ")
      printHex(markerCounts[phase][bin])
      discard console.sendString(" ")
      printHex(badCounts[phase][bin])
      discard console.sendLine("")
  discard console.sendLine("AGC PAGE TIMER END")
  console.flushTx()
  while true:
    {.emit: "__asm__ volatile(\"wfi\");".}
