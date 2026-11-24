## RAM-loaded probe for the proposed RIU bank-1 TimeOutReg lane.

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
  RiuBank00And01 = 0x01010001'u32
  AgcResetBit = 0x1000'u32
  TimerCount {.intdefine.} = 2000'u32
  BinTicks = 50'u32
  BinCount = 8
  DeadBranch = 0x08100400'u32 # C1(02,01,00) -> S000, always false

var console: Uart
var savedAgc: array[512, uint32]
var sampleCounts: array[2, array[BinCount, uint32]]
var timeoutCounts: array[2, array[BinCount, uint32]]
var diagOr: array[2, array[BinCount, uint32]]
var diagAnd: array[2, array[BinCount, uint32]]
var badAddressCounts: array[2, array[BinCount, uint32]]

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
  discard console.sendLine("AGC TIMEOUT DIAG START")
  console.flushTx()

  rfc_init(40_000_000'u32)
  discard console.sendLine("AGC TIMEOUT DIAG RF READY")
  console.flushTx()
  let savedRiu = regRead(0x24900078'u)
  let savedPd = regRead(0x24C0B390'u)
  for index in 0 ..< 512:
    savedAgc[index] = agcmem[index]
    agcmem[index] = 0'u32
  agcmem[1] = DeadBranch
  agcmem[511] = savedAgc[511]

  for phase in 0 ..< 2:
    regWrite(0x24C0B390'u, savedPd or AgcResetBit)
    agcmem[0] = (if phase == 0: 0x2800008F'u32 else: 0x2000008F'u32) or
      (TimerCount shl 15)
    wifi_fw.phy_init(nil)
    regWrite(0x24900078'u, RiuBank00And01)
    regWrite(0x24C0B390'u, savedPd or AgcResetBit)
    for delay in 0 ..< 1000:
      discard regRead(0x24C0B390'u)
    regWrite(0x24C0B390'u, savedPd and not AgcResetBit)
    let startTick = regRead(0xE000BFF8'u)
    for bin in 0 ..< BinCount:
      diagAnd[phase][bin] = 0xFFFF'u32
    while true:
      let nowTick = regRead(0xE000BFF8'u)
      let elapsed = nowTick - startTick
      if elapsed >= BinTicks * BinCount.uint32:
        break
      let bin = (elapsed div BinTicks).int
      let address = (regRead(0x24C0C920'u) shr 23) and 0x1FF'u32
      let diag = (regRead(0x24C0C924'u) shr 16) and 0xFFFF'u32
      inc sampleCounts[phase][bin]
      if (diag and 1'u32) != 0:
        inc timeoutCounts[phase][bin]
      diagOr[phase][bin] = diagOr[phase][bin] or diag
      diagAnd[phase][bin] = diagAnd[phase][bin] and diag
      if address > 1'u32:
        inc badAddressCounts[phase][bin]

  regWrite(0x24C0B390'u, savedPd or AgcResetBit)
  for index in 0 ..< 512:
    agcmem[index] = savedAgc[index]
  wifi_fw.phy_init(nil)
  regWrite(0x24C0B390'u, savedPd and not AgcResetBit)
  regWrite(0x24900078'u, savedRiu)
  discard console.sendLine("AGC TIMEOUT DIAG IMAGE RESTORED")
  for phase in 0 ..< 2:
    for bin in 0 ..< BinCount:
      discard console.sendString("AGC TIMEOUT DIAG CASE ")
      printHex(phase.uint32)
      discard console.sendString(" ")
      printHex(bin.uint32)
      discard console.sendString(" ")
      printHex(sampleCounts[phase][bin])
      discard console.sendString(" ")
      printHex(timeoutCounts[phase][bin])
      discard console.sendString(" ")
      printHex(diagOr[phase][bin])
      discard console.sendString(" ")
      printHex(diagAnd[phase][bin])
      discard console.sendString(" ")
      printHex(badAddressCounts[phase][bin])
      discard console.sendLine("")
  discard console.sendLine("AGC TIMEOUT DIAG END")
  console.flushTx()
  while true:
    {.emit: "__asm__ volatile(\"wfi\");".}
